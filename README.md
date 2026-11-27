# tuningfork

Infrastructure as code for four air-gapped environments: **lab**, **CRGS00**, **CRGS01** and
**CRGS02**. Terraform creates the virtual machines on Proxmox VE. Ansible then hardens them (CIS)
and turns each one into its server role: registry, database, file server, Kubernetes clusters,
load balancers, and a SIEM that watches all of it.

Start here if you are new. This page explains how the pieces fit together and where to look
next. Then read the README of the tool you need: [terraform/README.md](terraform/README.md) or
[ansible/README.md](ansible/README.md).

## The environment at a glance

Every environment has the same shape. The lab names are shown in brackets where they differ.

```
                      maestro (control node + mirror)
                      /srv/tuningfork: this repository; runs Terraform and Ansible
                      /repo, served as https://maestro: every package, binary, chart, image tarball
                              |
                              | SSH (Ansible), HTTPS (mirror), Proxmox API (Terraform)
                              v
  Proxmox VE cluster (Debian 13) ------------------------------------------------------------
  |                                                                                         |
  |  registry          Harbor: container images and Helm charts for the clusters            |
  |  database          PostgreSQL                                                           |
  |  nas               NFS exports (persistent data for the clusters)                       |
  |  bastion (mgmt)    kubectl, helm, k9s for administrators                                |
  |  support (pss)     Keycloak and basemap containers (VM only; no Ansible role yet)       |
  |  siem (sentinel)   Wazuh, Prometheus, Grafana, Alertmanager, syslog and trap receiver   |
  |                                                                                         |
  |  lb-rancher (VIP) --> rancher01..03   RKE2 cluster running Rancher Server              |
  |  lb-app     (VIP) --> app nodes 1..3  RKE2 cluster for the applications                |
  |                                       (standalone, or managed by Rancher)               |
  --------------------------------------------------------------------------------------------
  iDRACs (Dell server controllers): syslog, SNMP traps and SNMP polling to the SIEM VM
  Active Directory: logins on every Linux host (sssd), LDAP for Harbor, DNS for every name
```

Every VM runs Rocky Linux 9 with SELinux enforcing and firewalld on. The only exception is the
RKE2 nodes, where firewalld is off, as RKE2 documents. Network segmentation is the compensating
control; see [ansible/docs/rancher.md](ansible/docs/rancher.md).

## The air gap

No target host ever downloads from the internet. The process:

1. On an internet machine, someone downloads every artifact on a list. The lists are in the guides
   (for example [ansible/docs/rancher.md](ansible/docs/rancher.md)), and
   `ansible/playbooks/siem_download_list.yml` prints the SIEM one.
2. They copy the files to `/repo` on maestro.
3. Ansible fetches each file from `https://maestro` and checks its **sha256 against the value
   pinned in the inventory**. A file that doesn't match stops the play.

Container images go into Harbor (the `registry` VM), and the clusters pull only from there.

## How a build runs

```
terraform/live/<ENV>/<unit>   --apply-->  VMs on Proxmox + ansible/inventories/<ENV>/terraform_<unit>.yml
                                                         |
ansible/playbooks/site.yml    --run---->  every host, layer by layer (below)
                                                         |
terraform/k8s/<ENV>/rancher-server  --apply-->  Rancher Server on the Rancher cluster
terraform/k8s/<ENV>/rancher-config  --apply-->  Rancher admin password, AD login, roles
```

1. **Terraform** ([terraform/README.md](terraform/README.md)) clones each VM from the template
   `rocky9-chrgs-template-v2` and gives it CPU, memory, data disks and a static address. It logs in
   once as root to create the `ansible` account. Then it writes the VM into the Ansible inventory
   (`terraform_<unit>.yml`), with its address, data disks and, on load balancers, the virtual IP.
2. **Ansible** ([ansible/README.md](ansible/README.md)) runs `playbooks/site.yml`, which imports one
   playbook per layer, in this order:

   | Layer | Playbooks |
   |---|---|
   | Trust and packages | `certificates`, `repositories` |
   | Disks and first boot | `filesystems`, `cloud_init_cleanup` |
   | Hardening | `cis_rhel9` (vendored CIS benchmark, with lockout safeguards) |
   | Common OS | `linux_common`, `cli_tools`, `sssd_ad`, `windows_common` |
   | Servers | `nas_server`, `database_server`, `harbor`, `kubectl`, `k8s_bastion` |
   | Kubernetes | `load_balancer`, `rke2_rancher`, `rke2_app` |
   | SIEM | `siem` (the SIEM VM), `siem_agents` (agents and exporters on every monitored host) |

3. **Rancher Server** is deployed by hand with Terraform's Helm provider, once the Rancher cluster is
   up ([terraform/modules/rancher-server](terraform/modules/rancher-server/README.md)). Then the
   `rancher2` provider configures it: admin password, AD login and roles
   ([terraform/modules/rancher-config](terraform/modules/rancher-config/README.md)).

### Building a new environment, in order

Each step needs the one before it. The Terraform units under `terraform/k8s/` need a running
cluster, so a first build alternates between Terraform and Ansible:

| Step | What | Terraform | Ansible |
|---|---|---|---|
| 1 | NAS, registry, database (and the other servers) | `live/<ENV>/nas`, `registry`, `database`, ... | `site.yml --limit` those hosts |
| 2 | Load balancer and RKE2 cluster for Rancher | `live/<ENV>/lb-rancher`, `rancher-cluster` | `site.yml --limit 'lb_rancher:rke2_rancher'` |
| 3 | Rancher Server | `k8s/<ENV>/rancher-server` | |
| 4 | Rancher's configuration (admin, AD login, roles, monitoring) and the app cluster `command-pro`, defined in Rancher. Rancher generates its join token | `k8s/<ENV>/rancher-config` | |
| 5 | Load balancer and app nodes; each node joins `command-pro` | `live/<ENV>/lb-app`, `app-cluster` | `site.yml --limit 'lb_app:rke2_app'`, which reads the join token from Rancher (in development) |
| 6 | `command-pro` post-install: the default ingress certificate, monitoring, csi-driver-nfs and its storage classes, cert-manager, trust-manager, and later dependencies | a post-install unit for `command-pro` (in development) | |
| 7 | The user workloads on `command-pro` | to be developed | |

Run before steps 3 and 4, the app-cluster play prepares the nodes and leaves the join for step 5.

```sh
# On maestro, as the operator:
cd /srv/tuningfork/terraform/live/lab && terragrunt run --all apply
cd /srv/tuningfork/ansible && ansible-playbook -i inventories/lab playbooks/site.yml --ask-vault-pass
```

## Where to change what

| I want to change... | Edit |
|---|---|
| CPU, memory or disks of a role, in every environment | `terraform/_envcommon/roles/<role>.hcl` ([table](terraform/_envcommon/roles/README.md)) |
| A host name, an address, a cluster size or a virtual IP | `terraform/live/<ENV>/<unit>/terragrunt.hcl` |
| Proxmox endpoint, storage, network or DNS of an environment | `terraform/live/<ENV>/env.hcl` |
| Domain, NTP, banner, mirror URL, cluster host names | `ansible/inventories/<ENV>/group_vars/all/main.yml` |
| Settings of one server role | `ansible/inventories/<ENV>/group_vars/<group>.yml` |
| A version or checksum of a SIEM component | `ansible/inventories/<ENV>/group_vars/all/siem_versions.yml` |
| A version or checksum of RKE2 | `ansible/inventories/<ENV>/group_vars/rke2_rancher.yml`, `rke2_app.yml` |
| A password, token or key | `ansible/inventories/<ENV>/group_vars/all/vault.yml` (`ansible-vault edit`) |
| A rule for every environment (CIS exceptions) | `ansible/playbooks/group_vars/<group>.yml` |

The full map of variables, their precedence and every vault key is in
[ansible/docs/variables.md](ansible/docs/variables.md).

## Documentation map

| Topic | Document |
|---|---|
| Assumptions, open work and known issues | [docs/status.md](docs/status.md) |
| Rules for working in this repository | [CLAUDE.md](CLAUDE.md) |
| Terraform: units, disks, generated inventory, Rancher Server | [terraform/README.md](terraform/README.md) |
| Terraform modules and role profiles | [proxmox-vm](terraform/modules/proxmox-vm/README.md), [rancher-server](terraform/modules/rancher-server/README.md), [rancher-config](terraform/modules/rancher-config/README.md), [role profiles](terraform/_envcommon/roles/README.md) |
| Ansible: layers, running, conventions, every role | [ansible/README.md](ansible/README.md) (each role has `roles/<role>/README.md`) |
| Variables and secrets | [ansible/docs/variables.md](ansible/docs/variables.md) |
| Harbor registry | [ansible/docs/harbor.md](ansible/docs/harbor.md) |
| Active Directory logins | [ansible/docs/active-directory.md](ansible/docs/active-directory.md) |
| Kubernetes clients and bastion | [ansible/docs/kubernetes-clients.md](ansible/docs/kubernetes-clients.md) |
| Rancher cluster and Rancher Server | [ansible/docs/rancher.md](ansible/docs/rancher.md) |
| Application cluster | [ansible/docs/app-cluster.md](ansible/docs/app-cluster.md) |
| SIEM and observability | [ansible/docs/siem.md](ansible/docs/siem.md), design: [ansible/docs/siem/siem_design.md](ansible/docs/siem/siem_design.md) |
| SIEM work in progress | [HANDOFF.md](HANDOFF.md) |

## Repository layout

```
terraform/     VMs on Proxmox (Terragrunt units per environment), Rancher Server (Helm)
ansible/       inventories per environment, playbooks, roles, guides
docs/          status: assumptions and open work
CLAUDE.md      working rules: hard rules, conventions, known pitfalls
HANDOFF.md     SIEM work in progress
```

`.gitattributes` (LF line endings) and `.gitignore` at the root apply to both tools.

# tuningfork: Terraform

Provisions the VMs of a self-contained Kubernetes environment on Proxmox VE, with the
[bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox) provider (pinned to 0.122.0)
and Terragrunt. Every VM is a clone of one Rocky Linux 9 template. Terraform sets its hardware,
disks, network and address, makes it reachable for Ansible, and writes an Ansible inventory file
that `ansible/` picks up directly. Ansible does everything inside the guest after that.

Environments: **lab**, **CRGS00**, **CRGS01**, **CRGS02**. Each has the same ten units.

## What gets built

| Unit | VMs | Purpose | Cores / RAM | Data disks (GB) |
|---|---|---|---|---|
| `registry` | 1 | Harbor: container images and Helm charts | 4 / 8 GB | `/var/lib/containerd` 100, `/opt` 20, `/srv` 200 |
| `nas` | 1 | NAS: NFS exports for persistent cluster data | 4 / 8 GB | `/export/pvcdata` 50, `/export/cfr` 10, `/export/testdata` 100, `/export/deliveries` 40, `/export/backups` 30 |
| `siem` | 1 | Logging and observability (Wazuh, Prometheus, Grafana) | 8 / 16 GB | `/var/lib/wazuh-indexer` 100, `/var/ossec` 40, `/var/lib/prometheus` 40, `/var/log/remote` 20, `/var/cache/tuningfork` 20 |
| `database` | 1 | PostgreSQL | 4 / 4 GB | `/dbdata` 100 |
| `rancher-cluster` | 1 or 3 | RKE2 cluster that runs Rancher Server | 4 / 8 GB per node | `/var/lib/rancher` 50, `/var/lib/kubelet` 20 |
| `bastion` | 1 | kubectl, helm and k9s for every cluster | 2 / 4 GB | none |
| `support` | 1 | Keycloak and the basemap server (Docker) | 8 / 32 GB | `/var/lib/containerd` 50, `/kcdata` 10, `/basemap` 20 |
| `app-cluster` | 1 or 3 | RKE2 cluster for the application, standalone or managed by Rancher | 8 / 32 GB per node | `/var/lib/rancher` 100, `/var/lib/kubelet` 50, `/scratch` 20 (ext4; size and filesystem set in the unit) |
| `lb-rancher` | 1 | HAProxy and keepalived for the Rancher cluster | 4 / 4 GB | none |
| `lb-app` | 1 | HAProxy and keepalived for the application cluster | 4 / 4 GB | none |

Every VM also has:

- 1 socket and CPU type `host`.
- The 40 GB OS disk from the template (`/` 20, `/boot` 1, `/tmp` 5, `/var` 10). It is not grown.
- Two more data disks, always first: `/var/log` 10 GB and `/var/log/audit` 10 GB (30 days of
  audit records).

Filesystems: ext4 on the two log disks, xfs on every other data disk.

The SIEM sizes above are the lab sizes. The CRGS units use the production sizes from
`ansible/docs/siem.md` (300, 100, 100, 50, and 20 for the audit log).

**Storage needed per environment:** about 1.8 TB with single-node clusters and 2.5 TB with
three-node clusters, on the environment's storage volume unless you move disks elsewhere.

## Layout

```
root.hcl                           shared: local state, provider block, air-gapped provider install, environment inputs
providers/                         bpg/proxmox and hashicorp/local, supplied by you (git-ignored)
modules/proxmox-vm/                generic "clone VMs from a template" module (not tied to an OS or a role); README.md
modules/rancher-server/            Rancher Server from its Helm chart, onto the Rancher RKE2 cluster; README.md
modules/rancher-config/            Rancher admin password, AD login and roles (rancher2 provider); README.md
_envcommon/rocky9.hcl              Rocky 9 settings shared by every unit: template, CPU type, inventory file
_envcommon/roles/<role>.hcl        sizing of one role: cores, memory, data disks, Ansible groups (README.md: all of them)
live/
  <ENV>/env.hcl                    Proxmox endpoint, node, storage volume, bridge, DNS, template name, SSH keys
  <ENV>/<unit>/terragrunt.hcl      host names, addresses, cluster size, per-environment overrides
k8s/                               deployments onto clusters Ansible built, applied by hand (never by run --all in live/)
  root.hcl                         shared: local state, plugin directory, environment from live/<ENV>/env.hcl
  <ENV>/rancher-server/            Rancher Server (Helm), see "Rancher Server"
  <ENV>/rancher-config/            Rancher configuration (rancher2), see "Rancher configuration"
state/                             local state, one file per unit (git-ignored; back it up)
```

How a unit is put together:

```
live/<ENV>/<unit>/terragrunt.hcl   host name + address
  + _envcommon/roles/<role>.hcl    sizing
  + _envcommon/rocky9.hcl          OS settings
  + root.hcl + live/<ENV>/env.hcl  environment
  -> modules/proxmox-vm
  -> VMs + ansible/inventories/<ENV>/terraform_<unit>.yml
```

Module and profile references: [modules/proxmox-vm](modules/proxmox-vm/README.md),
[modules/rancher-server](modules/rancher-server/README.md), [modules/rancher-config](modules/rancher-config/README.md),
[_envcommon/roles](_envcommon/roles/README.md).

A value set in one place applies everywhere below it:

| To change | Edit |
|---|---|
| The size of a role in every environment | `_envcommon/roles/<role>.hcl` |
| A host name, an address, the cluster size | `live/<ENV>/<unit>/terragrunt.hcl` |
| One VM's size, storage volume or bridge in one environment | the same unit file (see "Overrides") |
| The storage volume, bridge, gateway or DNS of an environment | `live/<ENV>/env.hcl` |
| The template or the CPU type for all Rocky 9 VMs | `live/<ENV>/env.hcl` (template name), `_envcommon/rocky9.hcl` (CPU type) |

## Requirements

- Terraform 1.5 or later, and a Terragrunt version that uses `root.hcl`
  (`find_in_parent_folders("root.hcl")`).
- The providers, placed in `providers/` in the filesystem-mirror layout. On an internet-connected
  machine, in a directory with a `.tf` file that holds the `required_providers` block from
  `modules/proxmox-vm/versions.tf`, run:

  ```sh
  terraform providers mirror -platform=linux_amd64 -platform=windows_amd64 ./providers
  ```

  Then copy the result into `terraform/providers/`. That gives
  `providers/registry.terraform.io/bpg/proxmox/0.122.0/<os_arch>/...` and the same for
  `hashicorp/local`. `terragrunt init` passes `-plugin-dir` (set in `root.hcl` and
  `k8s/root.hcl`), so nothing is downloaded from the registry.

  The `k8s/` units also need `hashicorp/helm` and `hashicorp/kubernetes` (from
  `modules/rancher-server/versions.tf`), and `rancher/rancher2` 15.x (from
  `modules/rancher-config/versions.tf`). Mirror them the same way into the same plugin directory.
- A Proxmox API token with a role on the target nodes, storage volumes and the template that
  includes `VM.Allocate`, `VM.Clone`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Audit`,
  `Datastore.AllocateSpace`, `Datastore.Audit` and `SDN.Use` (Proxmox 8). `VM.Audit` is also what
  lets Terraform find the template by name.
- SSH from the machine that runs Terraform to the new VMs (port 22), and the private key that
  matches the root key seeded in the template.

### Template requirements

The template is found by name: `rocky9_template_name` in `env.hcl`
(`rocky9-chrgs-template-v2`). The name must match exactly one template in the cluster. It must have:

- `cloud-init` and `qemu-guest-agent` installed and enabled. cloud-init sets the host name, the
  static address, the gateway and DNS. Terraform waits for the agent.
- Its OS disk on `scsi0`, and no other `scsiN` disks. Terraform adds the data disks as `scsi1`,
  `scsi2`, and so on. If the OS disk is on another interface, set `os_disk_interface`.
- A disk no larger than 40 GB (`default_os_disk_gb`). Disks can grow but not shrink.
- The `root` account with an SSH public key in `/root/.ssh/authorized_keys`, and sshd allowing
  root to log in with a key.
- A generalised state: machine-id truncated, SSH host keys removed and `cloud-init clean` run.

## How a VM becomes ready for Ansible

1. **Clone**: a full clone of the template onto the VM's storage volume, with its CPU, memory,
   data disks and network device.
2. **cloud-init** (first boot): host name (the VM name), static IPv4 address, gateway, DNS.
3. **Bootstrap**: Terraform logs in once as `root` with `bootstrap_private_key_file` and runs
   `modules/proxmox-vm/bootstrap.sh.tftpl`. It creates the `ansible` account (key-only login,
   password locked and never expiring), authorises `ssh_public_keys` for it, and writes
   `/etc/sudoers.d/90-ansible`. Nothing else is done as root.
4. **Inventory**: the host is written to `ansible/inventories/<ENV>/terraform_<unit>.yml` with
   its groups and its data disks.

The data disks are attached **empty**. The Ansible `filesystems` role partitions, formats and
mounts them by UUID, and copies existing content across (for example the current `/var/log`).
How the two sides keep track of each disk is in "Data disks".

The bootstrap runs once per VM, and again only if the VM is replaced. After the CIS play has run,
root can no longer log in over SSH, and Terraform no longer needs it. Rotate the Ansible keys on
running hosts with Ansible, not here.

### After the first Ansible run: cloud-init is gone

cloud-init is only needed for the first boot. The first `site.yml` run retires it
(`ansible/roles/cloud_init_cleanup`): it removes `cloud-user`, the account cloud-init creates, and
uninstalls cloud-init (or disables it). The network, host name and DNS it set stay in place.

From then on, **Terraform's network settings no longer reach the VM.** Changing `ipv4_cidr`,
`ipv4_gateway`, `dns_servers` or `dns_domain` only updates the cloud-init drive in Proxmox, which
nothing reads. The generated inventory does change, so Ansible would then try the new address and
fail. To change a VM's address, change it on the host first (`nmcli connection modify ...`), then
in Terraform, then apply.

## Usage

```sh
export PROXMOX_VE_API_TOKEN='terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

cd terraform/live/lab/bastion
terragrunt init      # first time, and after adding providers
terragrunt plan
terragrunt apply
```

All units of an environment: `cd terraform/live/lab && terragrunt run --all plan`
(older Terragrunt: `terragrunt run-all plan`). The units don't depend on each other, so they can
be applied in any order or one at a time.

Before the first apply in an environment, replace the placeholders in `env.hcl` and in the units.
In lab they are marked `REPLACE`; only the addresses of `registry`, `mgmt` and `sentinel` are real.
In CRGS00, CRGS01 and CRGS02 every host name and address is an example.

Commit the `.terraform.lock.hcl` file that `init` creates in each unit, and the generated
`ansible/inventories/<ENV>/terraform_<unit>.yml` files.

Then configure the new hosts (see `ansible/README.md`):

```sh
cd ansible
ansible-inventory -i inventories/lab --graph
ansible-playbook -i inventories/lab playbooks/site.yml --limit mgmt.lab.local
```

## Cluster size

The two RKE2 units build one node or three. Set it in the unit:

```hcl
# live/<ENV>/rancher-cluster/terragrunt.hcl
server_count = 3                  # 1 or 3; any other number fails the plan
name_prefix  = "rancher"          # nodes are rancher01, rancher02, rancher03
server_ipv4_cidrs = [             # one address per node, in order
  "192.168.70.81/24",
  "192.168.70.82/24",
  "192.168.70.83/24",
]
```

Lab has three Rancher nodes and one application node; the CRGS environments have three of each. Going from 1 to 3 adds
nodes 02 and 03 and leaves node 01 alone. Going from 3 to 1 destroys nodes 02 and 03; the nodes
are protected, so that fails until `protection` is turned off (see "Protection").

Every node is an RKE2 server (control plane, etcd and workload). The Rancher nodes have 4 cores
and 8 GB, enough for RKE2 plus Rancher managing a few clusters; Rancher's guidance for a small
installation (up to 150 clusters) is 4 vCPU and 16 GB per node. Change `cores` and `memory_mb` in
`_envcommon/roles/rke2-rancher.hcl` if Rancher is short of memory.

The cluster is configured by Ansible (`ansible/playbooks/rke2_rancher.yml`), and the load
balancer's endpoints follow the number of nodes automatically. Guide: `ansible/docs/rancher.md`.

## Scratch disk on the application nodes

Every application node has a local disk at `/scratch` for workloads (a `hostPath` volume; Ansible
labels it for containers). It is the last data disk, so the other disks keep their slots. Set its
size and filesystem in the unit:

```hcl
# live/<ENV>/app-cluster/terragrunt.hcl
scratch_size_gb = 500        # default 20; raise it whenever needed
scratch_fstype  = "ext4"     # or "xfs"; only applies when the disk is first formatted
```

Growing it works like any data disk: raise `scratch_size_gb` and apply, then grow the filesystem
on each node (see "Managing disks"). Changing the filesystem of an existing disk needs a new disk.
The defaults live in `_envcommon/roles/rke2-app.hcl` (`scratch_disk`). The application cluster
itself is described in `ansible/docs/app-cluster.md`.

## Load balancers

Each load balancer unit passes the keepalived virtual IP to Ansible as the host variable
`keepalived_vip`. Reserve that address: no VM has it as its own. If the Proxmox firewall's IP
filter is on for the VM, allow the virtual IP there too, or the node drops its traffic.

## Overrides

A unit merges the role profile with its own values, so any field can be changed for one VM in one
environment. Every field is described in `modules/proxmox-vm/variables.tf`.

```hcl
inputs = {
  vms = {
    "registry" = merge(local.role, {
      ipv4_cidr      = "192.168.70.71/24"   # required
      memory_mb      = 16384                # more memory than the role profile
      node_name      = "pve-lab2"           # another Proxmox node (an existing VM is migrated there)
      datastore_id   = "uxt-san-vol2"       # all of this VM's disks on another storage volume
      network_bridge = "vmbr3"              # another bridge
      vlan_id        = 120                  # a VLAN tag
      ipv4_gateway   = "192.168.71.254"     # another gateway (network settings: new VMs only, see "After the first Ansible run")
      vm_id          = 2071                 # a fixed VM ID
    })
  }
}
```

**One disk on another storage volume.** When the storage volume runs out of space, new disks can
go elsewhere. Replace the VM's `data_disks` in the unit and set `datastore_id` on the disk:

```hcl
"registry" = merge(local.role, {
  ipv4_cidr = "192.168.70.71/24"
  data_disks = concat(local.role.data_disks, [
    { size_gb = 300, mount = "/srv/archive", fstype = "xfs", datastore_id = "uxt-san-vol2" },
  ])
})
```

Changing the `datastore_id` of an existing disk moves that disk to the other storage volume.

## Data disks

### Design

Terraform and Ansible split the work, and one identifier connects them:

```
Terraform                               Ansible (roles/filesystems)
---------                               ---------------------------
data_disks list, position 0, 1, 2 ...
  -> Proxmox slot scsi1, scsi2, scsi3 ...
  -> inventory: mount + /dev/disk/by-id/...drive-scsiN + size
                                        -> finds the disk by that path
                                        -> partitions and formats it (only if blank)
                                        -> mounts it by filesystem UUID in /etc/fstab
```

- **Terraform creates the disks empty.** It gives each disk a size, a storage volume and an image
  format. `raw` is the image format, not a filesystem, and nothing is imported onto the disk.
  Terraform never looks inside a disk.
- **A disk's identity is its place in the `data_disks` list.** Position 0 is `scsi1`, position 1
  is `scsi2`, and so on. Proxmox gives each slot a fixed device name in the guest,
  `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN`, which doesn't change across reboots
  or when disks are added.
- **Terraform tells Ansible which slot holds which mount point.** A disk with a `mount` is
  written into the generated inventory with its device name, its size and its filesystem type.
  A disk without a `mount` is attached and left alone.
- **Ansible does everything inside the guest**, and only on a disk that is blank or that it set
  up itself for that mount point. See [the filesystems role](../ansible/roles/filesystems/README.md).

### The one rule

**Never reorder `data_disks`, and never remove a disk from the middle of the list.** Either one
moves every later disk to another slot, so each mount point would point at another disk.

If it happens anyway, nothing is overwritten: Ansible recognises each disk by the partition name
it gave it, sees another volume's disk in the slot, and stops. Terraform would also try to
resize the shifted disks, and a disk can't be made smaller, so the plan or the apply fails.
Restore the list order to recover.

### Managing disks

| Task | How |
|---|---|
| Add a disk to a role in every environment | Append it at the **end** of `data_disks` in `_envcommon/roles/<role>.hcl`. Apply, then run `playbooks/filesystems.yml`. |
| Add a disk to one VM only | In the unit: `data_disks = concat(local.role.data_disks, [{ size_gb = 50, mount = "/data", fstype = "xfs" }])`. Apply, then run the playbook. |
| Grow a disk | Raise `size_gb` and apply. On the host: `growpart <disk> 1`, then `xfs_growfs <mount>` or `resize2fs <partition>`. Ansible doesn't resize. |
| Shrink a disk | Not possible. Add a new disk, copy the data, and retire the old one. |
| Put a new disk on another storage volume | Set `datastore_id` on that disk (see "Overrides"). |
| Move an existing disk to another storage volume | Change its `datastore_id` and apply. The disk is moved; its slot and its content stay the same. |
| Change a mount point or a filesystem type | Not on an existing disk: `fstype` only applies when a disk is first formatted, and Ansible stops if the disk no longer matches. Add a new disk and copy the data. |
| Retire a disk | Only the **last** disk in the list can be removed without shifting others. For any other disk, leave it in the list and stop using it. Turn `protection` off first (below). Test a removal on a lab VM before relying on it: the provider's documentation doesn't say what it does with the removed disk. |

### Protection

Two settings guard against losing a VM's disks by accident.

**`protection`** is the Proxmox protection flag. While it is on, Proxmox itself refuses to remove
the VM or any of its disks, whoever asks: Terraform, the web interface or the API. It is on in the
role profiles of the VMs that hold data (`registry`, `nas`, `siem`, `database`, `support` and both
RKE2 node types) and off for the bastion and the load balancers, which hold none.

To destroy a protected VM on purpose, turn the flag off first:

```hcl
# live/<ENV>/<unit>/terragrunt.hcl
"nas" = merge(local.role, {
  ipv4_cidr  = "192.168.70.70/24"
  protection = false        # 1. add this line and apply
})                          # 2. then remove the VM, or run terragrunt destroy
```

The same applies to shrinking a cluster from 3 nodes to 1, and to removing a disk.

**`migrate`** is always on. Changing a VM's `node_name` moves the VM to the other node with its
disks. Without it the provider would destroy the VM and build a new one with empty disks.

What still destroys data, by design:

- Removing a VM from a unit, or `terragrunt destroy`, once protection is off.
- Changing a VM's name (the key in `vms`): to Terraform that is one VM removed and another added.
- Changing `vm_id` on an existing VM.

Read the plan before every apply. A line that says a VM "must be replaced" or "will be destroyed"
means its disks go with it.

## Generated inventory

`ansible/inventories/<ENV>/terraform_<unit>.yml` looks like this (Terraform quotes the keys):

```yaml
all:
  children:
    linux:
      children:
        rocky9:
          hosts:
            nas.lab.local:
              ansible_host: 192.168.70.70
              proxmox_vm_id: 105
              proxmox_node: pve-lab
              filesystems_volumes__terraform:
                - mount: /var/log
                  disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
                  min_size_gb: 10
                  fstype: ext4
                - mount: /export/pvcdata
                  disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
                  min_size_gb: 50
                  fstype: xfs
    nas_servers:
      hosts:
        nas.lab.local: {}
```

Ansible loads every file in the inventory directory, so these files merge with `hosts.yml`.
**Keep each host in only one place.** When Terraform takes over a host that is listed by hand in
`hosts.yml`, remove it there, and remove any `host_vars` file that defines its disks
(`filesystems_volumes__*`), or the disks are defined twice and the `filesystems` role stops.
`terragrunt destroy` deletes the unit's inventory file.

Inventory groups per unit:

| Unit | Groups (besides `linux` and `rocky9`) |
|---|---|
| `registry` | `registry_servers` |
| `nas` | `nas_servers` |
| `siem` | `siem_servers` |
| `database` | `db_servers` |
| `bastion` | `k8s_bastions` |
| `support` | `support_servers` |
| `rancher-cluster` | `rke2_servers`, `rke2_rancher` |
| `app-cluster` | `rke2_servers`, `rke2_app` |
| `lb-rancher` | `load_balancers`, `lb_rancher` |
| `lb-app` | `load_balancers`, `lb_app` |

`support_servers`, `rke2_*`, `load_balancers` and `lb_*` have no Ansible playbook yet. Those hosts
are still in `rocky9`, so `site.yml` applies the common layers to them (certificates,
repositories, data disks, CIS, common configuration).

## Adding things

**A VM to an existing role**: add a second entry to `vms` in the unit, with its own name and address.

**A new role**:

1. `_envcommon/roles/<role>.hcl` with a `profile` (copy an existing one).
2. `live/<ENV>/<unit>/terragrunt.hcl` in every environment (copy an existing unit, change the
   role file name, the host name and the address).
3. The inventory groups in `ansible_groups`, and the Ansible role and playbook for them.

**Another OS**: prepare a template, add its name to each `env.hcl`, and create
`_envcommon/<os>.hcl` modelled on `rocky9.hcl` (OS type, inventory group and parent). Guests that
don't use cloud-init or SSH need module options for that (`bootstrap_enabled = false` turns the
SSH bootstrap off).

## Rancher Server (`k8s/<ENV>/rancher-server`)

Rancher Server is deployed onto the Rancher RKE2 cluster with the Helm provider, by hand, after
Ansible has built the cluster. The bootstrap password is `vault_rancher_bootstrap_password` in the
vault; type it at the prompt so it stays out of the shell history:

```sh
read -rsp 'Bootstrap password: ' TF_VAR_rancher_bootstrap_password; echo
export TF_VAR_rancher_bootstrap_password
cd terraform/k8s/lab/rancher-server
terragrunt init      # first time
terragrunt apply
```

- **Cluster access:** the kubeconfig Ansible wrote on the control node,
  `~/.kube/<ENV>-rancher-cluster.yaml`, through the load balancer on 6443.
- **Chart:** read from the mirror's folder on the control node,
  `/repo/helm/charts/rancher/rancher-<version>.tgz` (`chart_path` in the unit).
- **TLS:** lb-rancher's host certificate (it covers `rancher.<domain>`) and key from the certificate tree, plus the internal root CA,
  as Kubernetes secrets. Rancher uses them directly, so no cert-manager is needed. The same
  certificate is also Traefik's default certificate (a HelmChartConfig for `rke2-traefik`).
- **Images:** from Harbor, `registry.<domain>/rancher/...`; the nodes are already logged in.
- **Replicas:** one Rancher pod per cluster node, read from the cluster (1 or 3).

Kept out of `live/` on purpose: `terragrunt run --all` there builds VMs, and this unit needs a
running cluster. **Its state holds the certificate's private key and the bootstrap password**:
protect `terraform/state/` like the Ansible vault. The bootstrap password only matters for the
first login; Rancher asks for a new one then.

All inputs: `modules/rancher-server/variables.tf`. Full procedure: `ansible/docs/rancher.md`.

## Rancher configuration (`k8s/<ENV>/rancher-config`)

Configures the running Rancher with the `rancher2` provider, by hand, after `rancher-server`:
the local `admin` password, the server URL, Active Directory login and the roles of the AD groups.
Each secret comes from the vault and is typed at a prompt (the unit's header lists the keys):

```sh
for v in rancher_bootstrap_password rancher_admin_password ad_service_account_password ad_test_password; do
  read -rsp "$v: " "TF_VAR_$v"; echo; export "TF_VAR_$v"
done
cd terraform/k8s/lab/rancher-config
terragrunt init      # first time
terragrunt apply
```

- **Two provider configurations:** one without a token logs in with the bootstrap password and sets
  the admin password (`rancher2_bootstrap`); the other uses the admin token that returns.
- **AD test account:** Rancher makes it an administrator, so it is a dedicated account, never the
  bind account.
- **State:** holds the admin password and token, and the bind and test passwords. Protect it like
  the vault.

All inputs: `modules/rancher-config/variables.tf`; what it creates: its README.

## State

State is local: `terraform/state/live/<ENV>/<unit>/terraform.tfstate`, one file per unit (and
`terraform/state/k8s/<ENV>/<unit>/` for the `k8s/` units). It is
git-ignored. Back it up, and run Terraform for an environment from one place at a time, because
local state has no locking between machines. Losing it means importing the VMs again
(`terragrunt import 'proxmox_virtual_environment_vm.this["<name>"]' <node>/<vm_id>`).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Expected exactly one template named ...` | The template name in `env.hcl` is wrong, the VM isn't marked as a template, or two templates share the name. Set `rocky9_template_vm_id` to skip the lookup. |
| `This unit defines N VM(s), but only [1,3] are allowed` | `server_count` in a cluster unit isn't 1 or 3. |
| The apply waits, then fails on the bootstrap with an SSH timeout | The VM didn't get its address (cloud-init missing or not run), port 22 isn't reachable from this machine, or `bootstrap_private_key_file` doesn't match the key in the template. |
| `Invalid index` on `server_ipv4_cidrs` | Fewer addresses than `server_count`. |
| A destroy, or removing a VM or a disk, fails with a Proxmox error about protection | The VM is protected. Set `protection = false` for it in the unit, apply, then repeat. See "Protection". |
| The plan wants to resize several data disks you didn't touch | The `data_disks` list was reordered, or a disk was removed from the middle. Restore the order. |
| Ansible stops with `is neither blank nor the disk this role set up` | The disk in that slot isn't the one expected, or holds something else. See the filesystems role README, "When the play stops". |
| Terraform waits a long time after creating a VM | The guest agent isn't running in the template. |

# Status: assumptions and open work

What the code takes for granted, what is still to do, and what this documentation review found.
Last reviewed: 2026-11-22. Update this page when an item is done or a new one appears.

The SIEM has its own detailed tracker, [HANDOFF.md](../HANDOFF.md). This page only summarises it.

## Assumptions

The code relies on these and doesn't check all of them.

**Platform**
- Proxmox VE 9 (Debian 13) hosts the VMs. Terraform uses `bpg/proxmox` 0.122.0 from a local plugin
  directory (`/root/.terraform.d/plugins` on maestro). The Proxmox API token is in
  `PROXMOX_VE_API_TOKEN`.
- The VM storage is shared LVM on a SAN (lab: `uxt-san-vol1`), set by hand on Proxmox, not by this
  repository:
  - `snapshot-as-volume-chain 1`, so disks can be `qcow2` and have snapshots. Terraform creates
    every disk as `qcow2`.
  - `saferemove 1` (set 2026-11-26), so a deleted disk is zeroed and its data can't appear in a
    later VM's disk. Space freed before that date can still hold old data. The `filesystems` role
    refuses a disk that isn't blank; wipe it with `wipefs -a` once you're sure it's the right one.
- Every Linux VM is cloned from the template `rocky9-chrgs-template-v2`. It must have root with an
  authorised SSH key, cloud-init, and no SCSI disk other than `scsi0`
  ([terraform/README.md](../terraform/README.md), "Template requirements").
- The control node `maestro` runs ansible-core 2.14 with only the vendored collections
  (ansible.posix, community.general, community.crypto, ansible.windows, community.windows).

**Network and services outside this repository**
- `maestro` serves the mirror at `https://maestro` from `/repo`, with a certificate from the
  internal CA.
- The internal CA and the host certificates exist beforehand under
  `/srv/security/certificates/files/<domain>/` on maestro (`roles/certificates`).
- Active Directory provides DNS and logins. These records must exist before the plays that check
  them:
  - `registry.<domain>`;
  - `rancher.<domain>` on lb-rancher's virtual IP;
  - `command-pro.<domain>` on lb-app's virtual IP;
  - a record for every host.
- An upstream SMTP relay exists, and email stays best effort. Today `siem_mail_to` is empty
  everywhere, so no email is sent.
- Network segmentation outside the hosts protects the RKE2 nodes, which run without firewalld. The
  flows to allow are in [ansible/docs/rancher.md](../ansible/docs/rancher.md).

**Process**
- Someone downloads every artifact by hand on an internet machine and copies it to `/repo` on
  maestro. Every artifact's version and sha256 are pinned in the inventory.
- Container images are pushed to Harbor's `rancher` project by an administrator. The clusters
  pull them with the robot `robot$k8s-pull`.
- The user edits the vault (`ansible-vault edit`) and runs every command. The code never writes
  secrets.

## Open work

Owner "user" means a decision, a download, an apply or a run on maestro. Owner "code" means a
change to this repository.

### Kubernetes

| Item | Owner | State |
|---|---|---|
| Rancher Server v2.15.3, phase 1: `terraform/k8s/lab/rancher-server` | user | Applied 2026-11-23: Rancher answers on `rancher.lab.local`, Traefik serves the `lb-rancher` certificate by default. The second plan after the annotation and `set_sensitive` fixes is still to confirm. |
| Rancher configuration, phase 2: `terraform/k8s/lab/rancher-config` (admin password, AD login, `sg-lab-admins` admins, `sg-all-users` read-only on every cluster) | user | Applied 2026-11-24 with nested AD groups on. Logins checked: `sg-lab-admins` and `svc_rancher_admin` are administrators, `sg-all-users` read-only. To close: a second plan with no changes, and an account in neither group refused. |
| Rancher configuration, phase 3: monitoring in `rancher-config` (kube-prometheus-stack 93.9.0 from the mirror, `rancher-monitoring-dashboards` 110.0.1+up0.1.4, no persistence) | user | Done 2026-11-24: admins open Grafana, Prometheus and Alertmanager from Rancher, and `sg-all-users` see the dashboards read-only (View Monitoring in the System project). Open: Alertmanager sends alerts nowhere (the chart's `null` receiver) until a receiver is chosen. |
| Rancher configuration, phase 4: the custom cluster `command-pro` in `rancher-config` (RKE2 v1.36.5+rke2r1, Canal, ACE through lb-app, Harbor robot) | user | Done 2026-11-26: 3 nodes Ready, both kubeconfig contexts work (through Rancher, and direct through lb-app with the cluster CA), and Traefik serves the `command-pro` certificate on 443 |
| Rancher configuration for CRGS00/01/02: `rancher-config` units | code | After the lab phases, once each environment's AD values are known |
| Application cluster, managed mode: lab's app nodes joined `command-pro` by hand on 2026-11-26 (registration command pasted on each node). To do: codify the join in the `rke2_server` role (token from the vault, one node at a time), as the user wants | code | CRGS00/01/02 stay standalone (`false`) |

### Environments

| Item | Owner | State |
|---|---|---|
| Lab values still marked `# REPLACE` but in use: the Proxmox endpoint and node in `env.hcl`, the RKE2 node addresses, lb-app's virtual IP | user | Confirm each one and remove the marker |
| CRGS00/01/02: every `REPLACE` and `CHANGEME`. These are the Proxmox settings, addresses (documentation ranges 192.0.2.x, 198.51.100.x, 203.0.113.x), RKE2 version and checksums, and SIEM settings. | user | Not built yet |
| `support` VM (lab: `pss`): Terraform creates it in group `support_servers`, but no Ansible role configures Keycloak or the basemap server | code | Not started |

### SIEM ([HANDOFF.md](../HANDOFF.md) has the details)

| Item | Owner |
|---|---|
| Phase 4b: hardening and logging on the monitored Linux hosts | code |
| Phase 5: Windows domain controllers (audit policy, Wazuh agent, windows_exporter) | code, after the user supplies output from the hosts |
| Phase 6: `idrac_config`. It would configure the iDRACs over Redfish: syslog, SNMPv3 traps and polling users. The `idrac` group exists, but this role doesn't yet. | code, after the user supplies a Redfish attribute dump |
| Phase 7: detection content, alert rules and Grafana dashboards. `grafana_dashboards_dir` and the rules folder are empty apart from `TargetDown`. | code |
| Phase 8: validation playbook and the remaining guide sections | code |
| Placeholders: SIEM addresses for the CRGS environments, `siem_mail_to`, the SMTP relay, the Ground Segment time source | user |

## Found in this review (not changed)

These are behaviour issues, not documentation issues, so they were recorded and not fixed.

| Finding | Where | Suggested fix |
|---|---|---|
| Lab `terraform_nas.yml` was generated before the rename from NFS to NAS server, so it puts `nas.lab.local` in group `nfs_servers`. `playbooks/nas_server.yml` targets `nas_servers` and so skips the host. | `ansible/inventories/lab/terraform_nas.yml` (generated) | Run `terragrunt apply` in `terraform/live/lab/nas` to regenerate it |
| `snmp_exporter_module` is defined but no task reads it; the Prometheus `idrac` job names `dell` itself | `ansible/roles/snmp_exporter/defaults/main.yml`, `roles/prometheus/templates/prometheus.yml.j2` | Use the variable in the template, or remove it |
| `roles/siem_artifacts/tasks/manifest.yml` is not included by anything (also in HANDOFF.md) | `ansible/roles/siem_artifacts/tasks/` | Remove it, after you confirm |

Fixed since the review:

- **NAS firewall.** NFS is now open only to `nas_server_firewall_sources`, with one rich rule per
  source and service. Lab allows `192.168.70.0/24`. The CRGS values are placeholders.
- **NAS exports.** Each environment exports the five Terraform data disks under `/export/`.
  `/export/pvcdata` goes to the app nodes with `rw,sync,no_root_squash`, for csi-driver-nfs, and to the
  Kubernetes bastion with `rw,sync,root_squash`; the
  other four go to the same networks as the firewall, with `rw,sync,root_squash`.
- **Stray folder.** The `roles/` folder at the repository root, which held only a compiled Python
  file, is removed. `.gitignore` now ignores `__pycache__/` and `*.pyc`.
- **Rancher cluster (lab) is idempotent.** On 2026-11-23 a repeat run of
  `site.yml --limit 'lb_rancher:rke2_rancher'` reported `changed=0` on all four hosts. Three fixes
  got it there: the journald folder mode now matches CIS, the CIS facts file is off, and
  `restorecon` no longer counts container files it leaves alone. The CIS world-writable files
  control is also off on RKE2 nodes.
- **Application cluster (lab) is installed and idempotent.** On 2026-11-23, in standalone mode,
  `site.yml --limit 'lb_app:rke2_app'` reported `changed=0` on all four hosts. It took three or
  four runs to get there, not two, and the cause hasn't been looked at.
- **Lint exceptions.** The `curl` exception is in `ansible/.ansible-lint-ignore`, because the task
  is inside a block. The `systemctl` one has an inline `noqa`, because its task isn't.

## How the documentation was checked

- **Generated from the code.** Each role README was written from that role's tasks, defaults and
  templates. The variable map comes from a search for every `vault_*` reference.
- **Checks run here:** `scripts/check-no-requirement-ids.sh` passes, every relative link in the
  Markdown files points at an existing file, and the commits change only comments and Markdown.
- **Checks to run on maestro.** yamllint, ansible-lint and `terraform fmt` aren't installed on the
  workstation where this was written:
  ```sh
  cd /srv/tuningfork/ansible && yamllint . && ansible-lint && bash scripts/check-no-requirement-ids.sh
  cd /srv/tuningfork/terraform && terraform fmt -check -recursive
  ```

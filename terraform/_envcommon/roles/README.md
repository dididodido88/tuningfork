# Role profiles

A role profile is the hardware and disk layout shared by every VM of one role, in every
environment. A unit (`live/<ENV>/<unit>/terragrunt.hcl`) reads its profile, then adds the hostnames
and addresses, and can override any value. `_envcommon/rocky9.hcl` adds the settings that every
Rocky 9 VM shares, such as the template, the inventory groups and the bootstrap.

To change a role in **every** environment, edit its profile here. To change it in **one**
environment, override the value in that environment's unit.

| Profile | Units | Cores | Memory | Ansible groups | Data disks (mount, size, file system) |
|---|---|---|---|---|---|
| [bastion.hcl](bastion.hcl) | `bastion` (lab: `mgmt`) | 2 | 4 GB | `k8s_bastions` | `/var/log` 10G ext4, `/var/log/audit` 10G ext4 |
| [database.hcl](database.hcl) | `database` | 4 | 4 GB | `db_servers` | logs, `/dbdata` 100G xfs |
| [loadbalancer.hcl](loadbalancer.hcl) | `lb-rancher`, `lb-app` | 4 | 4 GB | `load_balancers`, plus `lb_rancher` or `lb_app` from the unit | logs |
| [nas.hcl](nas.hcl) | `nas` | 4 | 8 GB | `nas_servers` | logs, `/export/pvcdata` 50G, `/export/cfr` 10G, `/export/testdata` 100G, `/export/deliveries` 40G, `/export/backups` 30G (xfs) |
| [registry.hcl](registry.hcl) | `registry` | 4 | 8 GB | `registry_servers` | logs, `/var/lib/containerd` 100G, `/opt` 20G, `/srv` 200G (xfs) |
| [rke2-rancher.hcl](rke2-rancher.hcl) | `rancher-cluster` (1 or 3 VMs) | 4 | 8 GB | `rke2_servers`, `rke2_rancher` | logs, `/var/lib/rancher` 50G, `/var/lib/kubelet` 20G (xfs) |
| [rke2-app.hcl](rke2-app.hcl) | `app-cluster` (1 or 3 VMs) | 8 | 32 GB | `rke2_servers`, `rke2_app` | logs, `/var/lib/rancher` 100G, `/var/lib/kubelet` 50G (xfs), then `/scratch` (size and file system set by the unit, appended last) |
| [siem.hcl](siem.hcl) | `siem` (lab: `sentinel`) | 8 | 16 GB | `siem_servers` | logs, `/var/lib/wazuh-indexer` 100G, `/var/ossec` 40G, `/var/lib/prometheus` 40G, `/var/log/remote` 20G, `/var/cache/tuningfork` 20G (xfs). The CRGS units set production sizes. |
| [support.hcl](support.hcl) | `support` (lab: `pss`) | 8 | 32 GB | `support_servers` | logs, `/var/lib/containerd` 50G, `/kcdata` 10G, `/basemap` 20G (xfs) |

"logs" means the two disks every profile has: `/var/log` 10G and `/var/log/audit` 10G, both ext4.

**Disk order is identity.** Data disks become `scsi1`, `scsi2`, ... in list order, and Ansible
finds each one by its slot. Only append disks at the end. Removing or reordering a disk changes
the slot of every disk after it. See [modules/proxmox-vm](../../modules/proxmox-vm/README.md),
"Rules that protect data".

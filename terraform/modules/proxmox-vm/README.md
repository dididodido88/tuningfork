# Module `proxmox-vm`

Creates the VMs of one role, such as the registry or the Rancher cluster nodes, on Proxmox VE. It
clones them from the Rocky 9 template and makes each one reachable for Ansible. It also writes
the role's part of the Ansible inventory. Every unit under `terraform/live/<ENV>/` calls this
module once.

Read [terraform/README.md](../../README.md) first; it explains the units, the disks and the
generated inventory in context. The input variables are documented one by one in
[variables.tf](variables.tf).

## What it creates

| Resource | What it is |
|---|---|
| `data.proxmox_virtual_environment_vms.template` | Looks up the template by `template_name` (exactly one must match), unless `template_vm_id` is set. |
| `terraform_data.preflight` | Checks that involve more than one variable. They fail the plan before anything is created. |
| `proxmox_virtual_environment_vm.this` (one per entry of `vms`) | Full clone of the template: CPU, memory, OS disk, data disks `scsi1..N`, NIC with an optional VLAN, cloud-init with a static IPv4, gateway, DNS and hostname. |
| `terraform_data.bootstrap` (one per VM) | Logs in once as root over SSH and runs [bootstrap.sh.tftpl](bootstrap.sh.tftpl). |
| `local_file.inventory` | `ansible/inventories/<ENV>/terraform_<unit>.yml`. It is written only after the bootstrap, so a host appears in the inventory only once Ansible can log in. |

## The bootstrap

The template has only root, with an SSH key already authorised. The script:

1. waits for cloud-init to finish;
2. creates `ansible_user` with a locked password and an account that never expires, which the CIS
   pre-checks need;
3. writes its `authorized_keys` from `ssh_public_keys` and restores the SELinux labels;
4. grants sudo without a password in `/etc/sudoers.d/90-<user>`, checked with `visudo` first.

It runs once per VM, and again only if the VM is replaced. Changing the keys later doesn't
re-run it, because by then the CIS play has turned root SSH off. Rotate keys with Ansible.

## The generated inventory

Every VM goes into `inventory_os_group` (for example `rocky9`, under `linux`) and into each group
of its `ansible_groups`. Its host variables are:

| Variable | From |
|---|---|
| `ansible_host` | The address of `ipv4_cidr` |
| `proxmox_vm_id`, `proxmox_node` | The created VM |
| `filesystems_volumes__terraform` | Each data disk with a `mount`: `disk` (`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi<N>`), `mount`, `min_size_gb`, and `fstype` and `label` when set. The `filesystems` role mounts these. |
| anything in `host_vars` | The unit, for example `keepalived_vip` on the load balancers |

## Rules that protect data

- **A data disk's place in `data_disks` is its identity.** Disk `i` is attached as `scsi<i+1>`,
  and Ansible finds it by that slot. Only append disks. Never reorder the list, and never remove a
  disk from the middle.
- **Sizes only grow.** `min_size_gb` makes Ansible refuse a smaller disk found in a slot.
- **A new template doesn't rebuild running VMs** (`ignore_changes = [clone]`).
- **`protection = true`** makes Proxmox refuse to remove the VM or its disks, so a destroy fails
  until it is turned off and applied.
- **Validations stop the plan** in these cases:
  - VM names that aren't valid hostnames;
  - an address without a prefix, or the same address used twice;
  - more than 29 data disks;
  - a relative or repeated mount point;
  - a file system other than xfs or ext4;
  - a VM count outside `allowed_vm_counts` (the RKE2 units allow 1 or 3).

## Outputs

| Output | Content |
|---|---|
| `vms` | `name => { vm_id, node, datastore, fqdn, ipv4 }` |
| `template` | `{ vm_id, node }` of the template used |
| `inventory_path` | Path of the generated inventory file |

## Providers

`bpg/proxmox` pinned to `0.122.0` and `hashicorp/local` (see [versions.tf](versions.tf)). They come
from the local plugin directory, because the control node has no internet access.

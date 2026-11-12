# tuningfork: Terraform

Provisions VMs on Proxmox VE with the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox)
provider. Terragrunt adds the per-environment layout. Each unit clones VMs from a prepared template, sets
their network and the Ansible account's SSH keys through cloud-init, and writes an Ansible inventory
file that `ansible/` picks up directly.

Currently: **Rocky Linux 9** in **CRGS00**, **CRGS01** and **CRGS02**.

## Layout

```
root.hcl                     shared: local state, provider block, air-gapped provider install, env inputs
providers/                   bpg/proxmox and hashicorp/local, supplied by you (git-ignored)
modules/proxmox-vm/          generic "clone VMs from a template" module (not tied to an OS)
_envcommon/rocky9.hcl        Rocky 9 settings shared by every environment
live/
  <ENV>/env.hcl              Proxmox endpoint, node, datastore, network, DNS, SSH keys, template IDs
  <ENV>/rocky9/terragrunt.hcl  the environment's Rocky 9 VMs
state/                       local state, one file per unit (git-ignored; back it up)
```

Flow: `live/<ENV>/rocky9/terragrunt.hcl` (the VM list) + `_envcommon/rocky9.hcl` (OS defaults) +
`root.hcl` (environment from `env.hcl`) → `modules/proxmox-vm` → VMs + `ansible/inventories/<ENV>/terraform_rocky9.yml`.

## Requirements

- Terraform >= 1.5 and Terragrunt (a version that uses `root.hcl` / `find_in_parent_folders("root.hcl")`).
- The providers, placed in `providers/` in the filesystem-mirror layout. On an internet-connected
  machine, with a directory containing a `.tf` file that holds the `required_providers` block from
  `modules/proxmox-vm/versions.tf`, run:

  ```sh
  terraform providers mirror -platform=linux_amd64 -platform=windows_amd64 ./providers
  ```

  Then copy the result into `terraform/providers/`. That gives
  `providers/registry.terraform.io/bpg/proxmox/<version>/<os_arch>/...` and the same for `hashicorp/local`.
  `terragrunt init` passes `-plugin-dir=terraform/providers`, so nothing is downloaded from the registry.
- A Proxmox API token, with a role on the target nodes, datastores and template that includes
  `VM.Allocate`, `VM.Clone`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Audit`, `Datastore.AllocateSpace`,
  `Datastore.Audit` and `SDN.Use` (Proxmox 8).

### Template requirements (Rocky 9)

The template whose ID is `rocky9_template_vm_id` in `env.hcl` must have:

- `cloud-init` and `qemu-guest-agent` installed and enabled. Terraform waits for the agent to report the IP.
- Its OS disk on `scsi0`, and no other `scsiN` disks (Terraform adds the data disks as `scsi1`, `scsi2`, ...).
- A disk no larger than `os_disk_gb` (default 40 GiB). Disks can grow but not shrink.
- A generalised state: machine-id truncated, SSH host keys removed and `cloud-init clean` run.
- Growpart enabled in cloud-init (the default), so the root filesystem fills the resized disk.

## Usage

```sh
export PROXMOX_VE_API_TOKEN='terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

cd terraform/live/CRGS00/rocky9
terragrunt init      # first time, and after adding providers
terragrunt plan
terragrunt apply
```

All units of an environment: `cd terraform/live/CRGS00 && terragrunt run --all plan`
(older Terragrunt: `terragrunt run-all plan`).

Commit the `.terraform.lock.hcl` file that `init` creates in each unit, and the generated
`ansible/inventories/<ENV>/terraform_rocky9.yml`.

Then configure the new hosts (see `ansible/README.md`):

```sh
cd ansible
ansible-inventory -i inventories/CRGS00 --graph
ansible-playbook -i inventories/CRGS00 playbooks/site.yml --limit crgs00-nfs01.example.internal
```

## Adding or changing VMs

Edit `vms` in `live/<ENV>/rocky9/terragrunt.hcl`. Every field is described in
`modules/proxmox-vm/variables.tf`:

```hcl
"crgs00-app01" = {
  ipv4_cidr      = "192.0.2.20/24"          # required
  cores          = 4                        # optional; defaults in _envcommon/rocky9.hcl
  memory_mb      = 8192
  os_disk_gb     = 60
  node_name      = "pve00b"                 # optional; overrides env.hcl
  vm_id          = 2020                     # optional; fixed VM ID
  ansible_groups = ["nexus_servers"]        # server-role groups (linux -> rocky9 is automatic)
  data_disks = [
    { size_gb = 50, mount = "/var/log", fstype = "xfs", label = "varlog" },
    { size_gb = 20 },                        # attached, but not formatted or mounted by Ansible
  ]
}
```

- The map key is the hostname, the Proxmox VM name and the inventory name (`<key>.<dns_domain>`).
- **Data disks** become `scsi1`, `scsi2`, ... in list order. A disk with a `mount` is written into the
  inventory as `filesystems_volumes__terraform` using
  `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN`, and the `filesystems` role partitions,
  formats and mounts it. Append new disks to the end of the list. Removing or reordering disks
  changes the slot numbers.
- Changing the template ID or the SSH keys doesn't touch existing VMs (`ignore_changes`). Rotate keys
  on running hosts with Ansible.
- Removing a VM from the map destroys it on the next apply.

## Generated inventory

`ansible/inventories/<ENV>/terraform_rocky9.yml` looks like this (Terraform quotes the keys):

```yaml
all:
  children:
    linux:
      children:
        rocky9:
          hosts:
            crgs00-nfs01.example.internal:
              ansible_host: 192.0.2.11
              proxmox_vm_id: 101
              proxmox_node: pve00
              filesystems_volumes__terraform:
                - mount: /srv/nfs
                  disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
                  fstype: xfs
    nfs_servers:
      hosts:
        crgs00-nfs01.example.internal: {}
```

Ansible loads every file in the inventory directory, so this merges with `hosts.yml`. Keep each
host in only one of the two files. `terragrunt destroy` deletes the file.

## Adding another OS

1. Prepare a template and add its ID to each `env.hcl` (e.g. `winsrv2022_template_vm_id`).
2. Create `_envcommon/<os>.hcl` modelled on `rocky9.hcl` (`os_type`, inventory group/parent, inventory
   file name). Guests that don't use cloud-init need a module option for that. Extend
   `modules/proxmox-vm` then.
3. Create `live/<ENV>/<os>/terragrunt.hcl` with the two includes (the envcommon one with
   `merge_strategy = "deep"`) and a `vms` map.

## State

State is local: `terraform/state/live/<ENV>/<os>/terraform.tfstate`. It is git-ignored. Back it up,
and run Terraform for an environment from one place at a time, because local state has no locking
between machines. Losing it means importing the VMs again
(`terragrunt import 'proxmox_virtual_environment_vm.this["<name>"]' <node>/<vm_id>`).

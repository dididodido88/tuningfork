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
| `nfs` | 1 | NFS exports for persistent cluster data | 4 / 8 GB | `/export/pvcdata` 50, `/export/cfr` 10, `/export/testdata` 100, `/export/deliveries` 40, `/export/backups` 30 |
| `siem` | 1 | Logging and observability (Wazuh, Prometheus, Grafana) | 8 / 16 GB | `/var/lib/wazuh-indexer` 100, `/var/ossec` 40, `/var/lib/prometheus` 40, `/var/log/remote` 20, `/var/cache/tuningfork` 20 |
| `database` | 1 | PostgreSQL | 4 / 4 GB | `/dbdata` 100 |
| `rancher-cluster` | 1 or 3 | RKE2 cluster that runs Rancher Server | 2 / 4 GB per node | `/var/lib/rancher` 50, `/var/lib/kubelet` 20 |
| `bastion` | 1 | kubectl, helm and k9s for every cluster | 2 / 4 GB | none |
| `support` | 1 | Keycloak and the basemap server (Docker) | 8 / 32 GB | `/var/lib/containerd` 50, `/kcdata` 10, `/basemap` 20 |
| `app-cluster` | 1 or 3 | RKE2 cluster for the application, managed by Rancher | 8 / 32 GB per node | `/var/lib/rancher` 100, `/var/lib/kubelet` 50 |
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
modules/proxmox-vm/                generic "clone VMs from a template" module (not tied to an OS or a role)
_envcommon/rocky9.hcl              Rocky 9 settings shared by every unit: template, CPU type, inventory file
_envcommon/roles/<role>.hcl        sizing of one role: cores, memory, data disks, Ansible groups
live/
  <ENV>/env.hcl                    Proxmox endpoint, node, storage volume, bridge, DNS, template name, SSH keys
  <ENV>/<unit>/terragrunt.hcl      host names, addresses, cluster size, per-environment overrides
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
  `hashicorp/local`. `terragrunt init` passes `-plugin-dir=terraform/providers`, so nothing is
  downloaded from the registry.
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

The data disks are attached **blank**. The Ansible `filesystems` role partitions, formats and
mounts them by UUID, and copies existing content across (for example the current `/var/log`).

The bootstrap runs once per VM, and again only if the VM is replaced. After the CIS play has run,
root can no longer log in over SSH, and Terraform no longer needs it. Rotate the Ansible keys on
running hosts with Ansible, not here.

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

Lab starts with one node per cluster, the CRGS environments with three. Going from 1 to 3 adds
nodes 02 and 03 and leaves node 01 alone. Going from 3 to 1 destroys nodes 02 and 03.

Every node is an RKE2 server (control plane, etcd and workload). The Rancher nodes are sized at
2 cores and 4 GB as specified; that is the RKE2 minimum, and Rancher's own guidance for a small
installation is 4 vCPU and 16 GB per node. Change `cores` and `memory_mb` in
`_envcommon/roles/rke2-rancher.hcl` if Rancher is short of memory.

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
      node_name      = "pve-lab2"           # another Proxmox node
      datastore_id   = "uxt-san-vol2"       # all of this VM's disks on another storage volume
      network_bridge = "vmbr3"              # another bridge
      vlan_id        = 120                  # a VLAN tag
      ipv4_gateway   = "192.168.71.254"     # another gateway
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

- Data disks become `scsi1`, `scsi2`, ... in list order. A disk with a `mount` is written into
  the inventory as `filesystems_volumes__terraform`, using
  `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN`, and the Ansible `filesystems` role
  does the rest. A disk without a `mount` is attached and left alone.
- **Append new disks at the end of the list.** Removing or reordering disks changes the slot
  numbers of the disks after it.
- Growing a disk: raise `size_gb` and apply, then grow the partition and the filesystem on the
  host (`growpart <disk> 1`, then `xfs_growfs` or `resize2fs`). The role doesn't resize.
- `fstype` is `xfs` or `ext4`. It only takes effect when the disk is first formatted.
- Removing a VM from a unit destroys it and its disks on the next apply.

## Generated inventory

`ansible/inventories/<ENV>/terraform_<unit>.yml` looks like this (Terraform quotes the keys):

```yaml
all:
  children:
    linux:
      children:
        rocky9:
          hosts:
            nfs.lab.local:
              ansible_host: 192.168.70.73
              proxmox_vm_id: 105
              proxmox_node: pve-lab
              filesystems_volumes__terraform:
                - mount: /var/log
                  disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
                  fstype: ext4
                - mount: /export/pvcdata
                  disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
                  fstype: xfs
    nfs_servers:
      hosts:
        nfs.lab.local: {}
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
| `nfs` | `nfs_servers` |
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

## State

State is local: `terraform/state/live/<ENV>/<unit>/terraform.tfstate`, one file per unit. It is
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
| Terraform waits a long time after creating a VM | The guest agent isn't running in the template. |

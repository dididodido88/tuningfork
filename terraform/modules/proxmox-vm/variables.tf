# --- Placement ----------------------------------------------------------------------------

variable "node_name" {
  description = "Proxmox node the VMs are created on (a VM can override it with vms[*].node_name)."
  type        = string
}

variable "datastore_id" {
  description = "Storage volume for the VM disks and the cloud-init drive. A VM (vms[*].datastore_id) or a single data disk (data_disks[*].datastore_id) can use another one."
  type        = string
}

# --- Template -----------------------------------------------------------------------------

variable "template_name" {
  description = "Name of the template VM to clone, e.g. rocky9-chrgs-template-v2. It is looked up through the Proxmox API and must match exactly one template."
  type        = string
  default     = null
}

variable "template_vm_id" {
  description = "VM ID of the template. Set it only to skip the lookup by template_name."
  type        = number
  default     = null
}

variable "template_node_name" {
  description = "Node the template lives on. Defaults to the node found by the lookup, or node_name when template_vm_id is set."
  type        = string
  default     = null
}

# --- Hardware defaults (each VM can override them) ----------------------------------------

variable "os_type" {
  description = "Proxmox OS type (l26 = Linux 2.6+ kernel)."
  type        = string
  default     = "l26"
}

variable "cpu_type" {
  description = "CPU type. host passes the node's CPU through: best performance, but live migration only works between nodes with the same CPU."
  type        = string
  default     = "host"
}

variable "cpu_sockets" {
  description = "CPU sockets for VMs that don't set sockets."
  type        = number
  default     = 1
}

variable "default_cores" {
  description = "CPU cores per socket for VMs that don't set cores."
  type        = number
  default     = 2
}

variable "default_memory_mb" {
  description = "Memory (MiB) for VMs that don't set memory_mb."
  type        = number
  default     = 4096
}

variable "default_os_disk_gb" {
  description = "OS disk size (GiB) for VMs that don't set os_disk_gb. Must be at least the template's disk size. A larger value grows the disk, not the partitions on it."
  type        = number
  default     = 40
}

variable "protection" {
  description = "Proxmox protection flag for VMs that don't set protection. While it is on, Proxmox refuses to remove the VM or any of its disks, so a destroy fails until it is turned off and applied."
  type        = bool
  default     = false
}

variable "os_disk_interface" {
  description = "Interface of the template's OS disk. Data disks are added as scsi1, scsi2, ..., so the template must not have other scsi disks."
  type        = string
  default     = "scsi0"
}

# --- Network and cloud-init ---------------------------------------------------------------

variable "network_bridge" {
  description = "Proxmox bridge for the VM NIC (a VM can override it with vms[*].network_bridge)."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the VM NIC; null for untagged (a VM can set its own with vms[*].vlan_id)."
  type        = number
  default     = null
}

variable "ipv4_gateway" {
  description = "Default IPv4 gateway (a VM can override it with vms[*].ipv4_gateway)."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers written by cloud-init."
  type        = list(string)
}

variable "dns_domain" {
  description = "DNS search domain; also used to build each host's FQDN in the Ansible inventory."
  type        = string
}

variable "tags" {
  description = "Proxmox tags added to every VM."
  type        = list(string)
  default     = []
}

# --- Bootstrap over SSH -------------------------------------------------------------------
# The template has only root, with an SSH key already authorised. Terraform logs in once as
# root and prepares the account Ansible connects as. Nothing else is done over SSH.

variable "bootstrap_enabled" {
  description = "Log in to each new VM once and create the Ansible account. With false, the VMs are created but Ansible can't reach them yet."
  type        = bool
  default     = true
}

variable "bootstrap_user" {
  description = "Account Terraform logs in as for the bootstrap. Its key is seeded in the template."
  type        = string
  default     = "root"
}

variable "bootstrap_private_key_file" {
  description = "Private key file for bootstrap_user, on the machine that runs Terraform. null: use the SSH agent."
  type        = string
  default     = null
}

variable "bootstrap_script_path" {
  description = "Where the bootstrap script is put on the VM. Not /tmp, which may be mounted noexec. %RAND% is replaced with a random number."
  type        = string
  default     = "/root/terraform-bootstrap-%RAND%.sh"
}

variable "bootstrap_timeout" {
  description = "How long to wait for SSH on a new VM."
  type        = string
  default     = "10m"
}

variable "ansible_user" {
  description = "Account the bootstrap creates for Ansible: key-only login, sudo without a password. Same as ansible_user in ansible/inventories/<ENV>/group_vars/linux.yml."
  type        = string
  default     = "ansible"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.ansible_user)) && var.ansible_user != "root"
    error_message = "ansible_user must be a valid Linux user name and not root (the CIS play refuses to run as root)."
  }
}

variable "ssh_public_keys" {
  description = "SSH public keys authorised for ansible_user."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Set at least one SSH public key, or Ansible can't log in to the new VMs."
  }
}

# --- The VMs ------------------------------------------------------------------------------

variable "vms" {
  description = <<-EOT
    VMs to create, keyed by short hostname (also the Proxmox VM name and the cloud-init hostname).
      ipv4_cidr       required; static address with prefix, e.g. 192.0.2.11/24
      ipv4_gateway    optional; overrides var.ipv4_gateway
      vm_id           optional; fixed VM ID (otherwise Proxmox picks the next free one)
      node_name       optional; overrides var.node_name
      datastore_id    optional; overrides var.datastore_id for this VM's disks
      network_bridge  optional; overrides var.network_bridge
      vlan_id         optional; overrides var.vlan_id
      sockets         optional; overrides var.cpu_sockets
      cores           optional; overrides var.default_cores (cores per socket)
      cpu_type        optional; overrides var.cpu_type
      memory_mb       optional; overrides var.default_memory_mb
      os_disk_gb      optional; overrides var.default_os_disk_gb
      protection      optional; overrides var.protection (Proxmox refuses to remove the VM or
                      its disks while it is true)
      data_disks      optional; empty disks attached as scsi1, scsi2, ... in list order. A disk's
                      place in the list is its identity: append new disks at the end, and never
                      reorder the list or remove a disk from the middle.
                        size_gb       required; can be raised later, never lowered
                        mount         optional; with it, the Ansible filesystems role partitions,
                                      formats and mounts the disk there
                        fstype        optional; xfs or ext4 (the role's default is ext4)
                        label         optional; filesystem label
                        datastore_id  optional; put this one disk on another storage volume
      ansible_groups  optional; extra inventory groups (server roles), e.g. ["nfs_servers"]
      host_vars       optional; extra variables for this host in the generated inventory
      tags            optional; extra Proxmox tags
      description     optional; Proxmox VM notes
  EOT
  type = map(object({
    ipv4_cidr      = string
    ipv4_gateway   = optional(string)
    vm_id          = optional(number)
    node_name      = optional(string)
    datastore_id   = optional(string)
    network_bridge = optional(string)
    vlan_id        = optional(number)
    sockets        = optional(number)
    cores          = optional(number)
    cpu_type       = optional(string)
    memory_mb      = optional(number)
    os_disk_gb     = optional(number)
    protection     = optional(bool)
    data_disks = optional(list(object({
      size_gb      = number
      mount        = optional(string)
      fstype       = optional(string)
      label        = optional(string)
      datastore_id = optional(string)
    })), [])
    ansible_groups = optional(list(string), [])
    host_vars      = optional(map(string), {})
    tags           = optional(list(string), [])
    description    = optional(string)
  }))

  validation {
    condition     = alltrue([for name, vm in var.vms : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "VM names must be valid short hostnames: lowercase letters, digits and hyphens, up to 63 characters."
  }

  validation {
    condition     = alltrue([for vm in var.vms : can(cidrhost(vm.ipv4_cidr, 0)) && strcontains(vm.ipv4_cidr, "/")])
    error_message = "Every VM needs ipv4_cidr as an address with prefix length, e.g. 192.0.2.11/24."
  }

  validation {
    condition     = length(distinct([for vm in var.vms : split("/", vm.ipv4_cidr)[0]])) == length(var.vms)
    error_message = "Two VMs in this unit have the same IPv4 address."
  }

  validation {
    condition     = alltrue([for vm in var.vms : length(vm.data_disks) <= 29])
    error_message = "A VM can have at most 29 data disks (scsi1-scsi29)."
  }

  validation {
    condition     = alltrue(flatten([for vm in var.vms : [for d in vm.data_disks : d.mount == null || startswith(coalesce(d.mount, "/"), "/")]]))
    error_message = "A data disk's mount must be an absolute path."
  }

  validation {
    condition = alltrue([
      for vm in var.vms : length(distinct(compact([for d in vm.data_disks : d.mount]))) == length(compact([for d in vm.data_disks : d.mount]))
    ])
    error_message = "A VM lists the same mount point on two data disks."
  }

  validation {
    condition     = alltrue(flatten([for vm in var.vms : [for d in vm.data_disks : d.fstype == null || contains(["xfs", "ext4"], coalesce(d.fstype, "xfs"))]]))
    error_message = "A data disk's fstype must be xfs or ext4 (the types the Ansible filesystems role supports)."
  }
}

variable "allowed_vm_counts" {
  description = "Numbers of VMs this unit may define; null for any. The RKE2 cluster units set [1, 3]: a single node or three."
  type        = list(number)
  default     = null
}

# --- Ansible inventory --------------------------------------------------------------------

variable "inventory_path" {
  description = "Path of the generated Ansible inventory file (e.g. ansible/inventories/lab/terraform_registry.yml)."
  type        = string
}

variable "inventory_os_group" {
  description = "Inventory group every VM is placed in (e.g. rocky9)."
  type        = string
}

variable "inventory_os_parent_group" {
  description = "Parent group of inventory_os_group (e.g. linux); null if it has none."
  type        = string
  default     = null
}

# --- Placement and template -------------------------------------------------------------

variable "node_name" {
  description = "Proxmox node the VMs are created on (a VM can override it with vms[*].node_name)."
  type        = string
}

variable "datastore_id" {
  description = "Datastore for the VM disks and the cloud-init drive."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the prepared template to clone. It must have cloud-init and qemu-guest-agent installed."
  type        = number
}

variable "template_node_name" {
  description = "Node the template lives on. Defaults to node_name."
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
  description = "Emulated CPU type. x86-64-v2-AES meets the Rocky 9 baseline and allows live migration between different host CPUs."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "default_cores" {
  description = "CPU cores for VMs that don't set cores."
  type        = number
  default     = 2
}

variable "default_memory_mb" {
  description = "Memory (MiB) for VMs that don't set memory_mb."
  type        = number
  default     = 4096
}

variable "default_os_disk_gb" {
  description = "OS disk size (GiB) for VMs that don't set os_disk_gb. Must be at least the template's disk size."
  type        = number
  default     = 40
}

# --- Network and cloud-init ---------------------------------------------------------------

variable "network_bridge" {
  description = "Proxmox bridge for the VM NIC."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the VM NIC; null for untagged."
  type        = number
  default     = null
}

variable "ipv4_gateway" {
  description = "Default IPv4 gateway."
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

variable "ci_user" {
  description = "Account cloud-init creates and authorises the SSH keys for (the Ansible account)."
  type        = string
  default     = "ansible"
}

variable "ssh_public_keys" {
  description = "SSH public keys for ci_user."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Set at least one SSH public key, or Ansible can't log in to the new VMs."
  }
}

variable "tags" {
  description = "Proxmox tags added to every VM."
  type        = list(string)
  default     = []
}

# --- The VMs ----------------------------------------------------------------------------

variable "vms" {
  description = <<-EOT
    VMs to create, keyed by short hostname (also the Proxmox VM name and the cloud-init hostname).
      vm_id          optional; fixed VM ID (otherwise Proxmox picks the next free one)
      node_name      optional; overrides var.node_name
      cores          optional; overrides var.default_cores
      memory_mb      optional; overrides var.default_memory_mb
      os_disk_gb     optional; overrides var.default_os_disk_gb
      ipv4_cidr      required; static address with prefix, e.g. 192.0.2.11/24
      data_disks     optional; blank disks attached as scsi1, scsi2, ... in list order.
                     Give a disk a mount (and optionally fstype/label) to have the Ansible
                     filesystems role partition, format and mount it.
      ansible_groups optional; extra inventory groups (server roles), e.g. ["nfs_servers"]
      tags           optional; extra Proxmox tags
      description    optional; Proxmox VM notes
  EOT
  type = map(object({
    vm_id      = optional(number)
    node_name  = optional(string)
    cores      = optional(number)
    memory_mb  = optional(number)
    os_disk_gb = optional(number)
    ipv4_cidr  = string
    data_disks = optional(list(object({
      size_gb = number
      mount   = optional(string)
      fstype  = optional(string)
      label   = optional(string)
    })), [])
    ansible_groups = optional(list(string), [])
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
    condition     = alltrue([for vm in var.vms : length(vm.data_disks) <= 29])
    error_message = "A VM can have at most 29 data disks (scsi1-scsi29)."
  }

  validation {
    condition     = alltrue(flatten([for vm in var.vms : [for d in vm.data_disks : d.mount == null || startswith(coalesce(d.mount, "/"), "/")]]))
    error_message = "A data disk's mount must be an absolute path."
  }
}

# --- Ansible inventory --------------------------------------------------------------------

variable "inventory_path" {
  description = "Path of the generated Ansible inventory file (e.g. ansible/inventories/CRGS00/terraform_rocky9.yml)."
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

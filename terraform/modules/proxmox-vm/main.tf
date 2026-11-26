# --- Template lookup ----------------------------------------------------------------------

# Find the template by name, unless its VM ID is given.
data "proxmox_virtual_environment_vms" "template" {
  count = var.template_vm_id == null && var.template_name != null ? 1 : 0

  filter {
    name   = "name"
    values = [var.template_name]
  }

  filter {
    name   = "template"
    values = [true]
  }

  lifecycle {
    postcondition {
      condition     = length(self.vms) == 1
      error_message = "Expected exactly one template named '${var.template_name}', found ${length(self.vms)}. Check the name, or set template_vm_id."
    }
  }
}

locals {
  template_found = one(data.proxmox_virtual_environment_vms.template[*].vms)

  template_vm_id = var.template_vm_id != null ? var.template_vm_id : try(local.template_found[0].vm_id, null)
  template_node_name = coalesce(
    var.template_node_name,
    try(local.template_found[0].node_name, null),
    var.node_name,
  )

  vms = {
    for name, vm in var.vms : name => merge(vm, {
      node_name      = coalesce(vm.node_name, var.node_name)
      datastore_id   = coalesce(vm.datastore_id, var.datastore_id)
      network_bridge = coalesce(vm.network_bridge, var.network_bridge)
      # Not coalesce: both may be null (untagged).
      vlan_id      = vm.vlan_id != null ? vm.vlan_id : var.vlan_id
      ipv4_gateway = coalesce(vm.ipv4_gateway, var.ipv4_gateway)
      sockets      = coalesce(vm.sockets, var.cpu_sockets)
      cores        = coalesce(vm.cores, var.default_cores)
      cpu_type     = coalesce(vm.cpu_type, var.cpu_type)
      memory_mb    = coalesce(vm.memory_mb, var.default_memory_mb)
      os_disk_gb   = coalesce(vm.os_disk_gb, var.default_os_disk_gb)
      protection   = coalesce(vm.protection, var.protection)
      fqdn         = "${name}.${var.dns_domain}"
      ipv4         = split("/", vm.ipv4_cidr)[0]
    })
  }
}

# Checks that involve more than one variable. They fail the plan before anything is created.
resource "terraform_data" "preflight" {
  lifecycle {
    precondition {
      condition     = var.template_name != null || var.template_vm_id != null
      error_message = "Set template_name (or template_vm_id): the template the VMs are cloned from."
    }

    precondition {
      condition     = var.allowed_vm_counts == null ? true : contains(var.allowed_vm_counts, length(var.vms))
      error_message = "This unit defines ${length(var.vms)} VM(s), but only ${jsonencode(var.allowed_vm_counts)} are allowed (an RKE2 cluster has 1 node or 3)."
    }
  }
}

# --- VMs ----------------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "this" {
  for_each = local.vms

  name        = each.key
  node_name   = each.value.node_name
  vm_id       = each.value.vm_id
  description = coalesce(each.value.description, "Managed by Terraform (terraform/live). Do not edit by hand.")
  tags        = sort(distinct(concat(var.tags, each.value.tags)))

  on_boot = true
  started = true
  # Power off instead of waiting for a guest shutdown that never comes if the agent is down.
  stop_on_destroy = true

  # Data safety.
  # migrate: a changed node_name moves the VM to the other node. Without it the provider
  # destroys the VM and creates a new one, with new, empty disks.
  migrate = true
  # protection: Proxmox itself refuses to remove the VM or any of its disks while this is on,
  # whoever asks (Terraform, the web interface, the API). See README.md, "Protection".
  protection = each.value.protection

  clone {
    vm_id        = local.template_vm_id
    node_name    = local.template_node_name
    datastore_id = each.value.datastore_id
    full         = true
  }

  # Terraform waits for the guest agent to report the address.
  agent {
    enabled = true
  }

  operating_system {
    type = var.os_type
  }

  cpu {
    sockets = each.value.sockets
    cores   = each.value.cores
    type    = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  # OS disk from the template.
  disk {
    interface    = var.os_disk_interface
    datastore_id = each.value.datastore_id
    size         = each.value.os_disk_gb
    file_format  = "qcow2"
    iothread     = true
    discard      = "on"
  }

  # Data disks on scsi1..N, in list order. They are created EMPTY: only a size, a storage volume
  # and an image format are given (qcow2 is the image format, not a filesystem), and nothing is
  # imported onto them. The Ansible filesystems role partitions and formats them.
  # qcow2 for every disk, OS disk included: Proxmox VE 9 takes snapshots of disks on (shared) LVM
  # only as qcow2 volume chains.
  dynamic "disk" {
    for_each = { for i, d in each.value.data_disks : i => d }
    content {
      interface    = "scsi${disk.key + 1}"
      datastore_id = coalesce(disk.value.datastore_id, each.value.datastore_id)
      size         = disk.value.size_gb
      file_format  = "qcow2"
      iothread     = true
      discard      = "on"
    }
  }

  network_device {
    bridge  = each.value.network_bridge
    vlan_id = each.value.vlan_id
    model   = "virtio"
  }

  # cloud-init: the hostname is the VM name; DNS and the static IPv4 address come from here.
  # No user_account: the template's only account is root, and its key is already in place.
  initialization {
    datastore_id = each.value.datastore_id

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ipv4_cidr
        gateway = each.value.ipv4_gateway
      }
    }
  }

  lifecycle {
    # A new template must not rebuild running VMs.
    ignore_changes = [clone]
  }

  depends_on = [terraform_data.preflight]
}

# --- Bootstrap: make each new VM reachable for Ansible --------------------------------------

locals {
  bootstrap_script = templatefile("${path.module}/bootstrap.sh.tftpl", {
    user = var.ansible_user
    keys = var.ssh_public_keys
  })
}

# Runs once per VM, and again only if the VM is replaced. Changing ssh_public_keys later does
# not re-run it: by then the CIS play has turned root SSH off. Rotate keys with Ansible.
resource "terraform_data" "bootstrap" {
  for_each = var.bootstrap_enabled ? local.vms : {}

  triggers_replace = [proxmox_virtual_environment_vm.this[each.key].id]

  connection {
    type        = "ssh"
    host        = each.value.ipv4
    user        = var.bootstrap_user
    private_key = var.bootstrap_private_key_file == null ? null : file(pathexpand(var.bootstrap_private_key_file))
    agent       = var.bootstrap_private_key_file == null
    timeout     = var.bootstrap_timeout
    script_path = var.bootstrap_script_path
  }

  provisioner "remote-exec" {
    inline = [local.bootstrap_script]
  }
}

# --- Ansible inventory --------------------------------------------------------------------

locals {
  # Per-host variables. filesystems_volumes__terraform is added only when a data disk has a
  # mount; it merges with the other filesystems_volumes__* variables (roles/filesystems).
  #
  # This is where a disk's identity is handed to Ansible. The disk at position i of data_disks
  # is attached as scsi<i+1>, and Proxmox gives that slot a fixed device name in the guest.
  # min_size_gb repeats the size, so Ansible refuses a smaller disk found in that slot.
  inventory_hostvars = {
    for name, vm in local.vms : vm.fqdn => merge(
      vm.host_vars,
      {
        ansible_host  = vm.ipv4
        proxmox_vm_id = proxmox_virtual_environment_vm.this[name].vm_id
        proxmox_node  = vm.node_name
      },
      {
        for k, v in {
          filesystems_volumes__terraform = [
            for i, d in vm.data_disks : merge(
              {
                # by-id is stable on Proxmox virtio-scsi: the name includes the drive slot (scsiN).
                mount       = d.mount
                disk        = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi${i + 1}"
                min_size_gb = d.size_gb
              },
              { for ok, ov in { fstype = d.fstype, label = d.label } : ok => ov if ov != null },
            ) if d.mount != null
          ]
        } : k => v if length(v) > 0
      },
    )
  }

  os_group = {
    (var.inventory_os_group) = { hosts = local.inventory_hostvars }
  }

  role_groups = {
    for g in sort(distinct(flatten([for vm in local.vms : vm.ansible_groups]))) : g => {
      hosts = { for vm in local.vms : vm.fqdn => {} if contains(vm.ansible_groups, g) }
    }
  }

  # Both branches are objects with different shapes; going through JSON gives the conditional one type.
  os_tree = jsondecode(var.inventory_os_parent_group == null ? jsonencode(local.os_group) : jsonencode({
    (var.inventory_os_parent_group) = { children = local.os_group }
  }))

  inventory = {
    all = {
      children = merge(local.os_tree, local.role_groups)
    }
  }
}

resource "local_file" "inventory" {
  filename        = var.inventory_path
  file_permission = "0644"
  content = join("\n", [
    "---",
    "# GENERATED by Terraform (terraform/live/<ENV>/<unit>). Do not edit: change the Terragrunt",
    "# unit and apply. Ansible reads this file together with hosts.yml because the whole",
    "# inventory directory is loaded (-i inventories/<ENV>).",
    yamlencode(local.inventory),
  ])

  lifecycle {
    precondition {
      condition = length(setintersection(
        keys(local.role_groups),
        compact([var.inventory_os_group, var.inventory_os_parent_group]),
      )) == 0
      error_message = "ansible_groups must not repeat the OS group or its parent group; every VM is already in them."
    }
  }

  # A host appears in the inventory only once Ansible can log in to it.
  depends_on = [terraform_data.bootstrap]
}

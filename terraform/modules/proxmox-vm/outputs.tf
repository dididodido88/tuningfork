output "vms" {
  description = "Created VMs: name => { vm_id, node, fqdn, ipv4 }."
  value = {
    for name, vm in local.vms : name => {
      vm_id = proxmox_virtual_environment_vm.this[name].vm_id
      node  = vm.node_name
      fqdn  = vm.fqdn
      ipv4  = vm.ipv4
    }
  }
}

output "inventory_path" {
  description = "Path of the generated Ansible inventory file."
  value       = local_file.inventory.filename
}

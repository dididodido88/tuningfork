# Outputs of the module: the created VMs, the template they were cloned from and the path of
# the generated Ansible inventory. Shown by `terragrunt output` in a unit.
output "vms" {
  description = "Created VMs: name => { vm_id, node, datastore, fqdn, ipv4 }."
  value = {
    for name, vm in local.vms : name => {
      vm_id     = proxmox_virtual_environment_vm.this[name].vm_id
      node      = vm.node_name
      datastore = vm.datastore_id
      fqdn      = vm.fqdn
      ipv4      = vm.ipv4
    }
  }
}

output "template" {
  description = "Template the VMs are cloned from: { vm_id, node }."
  value = {
    vm_id = local.template_vm_id
    node  = local.template_node_name
  }
}

output "inventory_path" {
  description = "Path of the generated Ansible inventory file."
  value       = local_file.inventory.filename
}

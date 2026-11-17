# Rocky Linux 9 settings shared by every unit in every environment. Each unit includes it:
#   include "os" {
#     path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
#     merge_strategy = "deep"
#   }
#
# The VMs are cloned from the Rocky 9 template named in env.hcl (rocky9_template_name). What the
# template must provide is in terraform/README.md, "Template requirements".

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  # Directory name of the unit that includes this file, e.g. "registry".
  unit = basename(get_terragrunt_dir())

  # Optional in env.hcl: skip the lookup by name. Left out (not passed as null) when unset.
  template_overrides = merge(
    try({ template_vm_id = local.env.rocky9_template_vm_id }, {}),
    try({ template_node_name = local.env.rocky9_template_node_name }, {}),
  )
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/proxmox-vm"
}

inputs = merge(local.template_overrides, {
  template_name = local.env.rocky9_template_name

  os_type = "l26"

  # Every VM: 1 socket, the node's own CPU type. Cores and memory come from the role profile
  # (_envcommon/roles/); these defaults apply to a VM that sets neither.
  cpu_type          = "host"
  cpu_sockets       = 1
  default_cores     = 2
  default_memory_mb = 4096

  # The template's disk is 40 GB (/ 20, /boot 1, /tmp 5, /var 10). It is not grown: more space
  # is added as data disks, which the Ansible filesystems role formats and mounts.
  default_os_disk_gb = 40

  # Same account as ansible_user in ansible/inventories/<ENV>/group_vars/linux.yml.
  ansible_user = "ansible"

  tags = ["rocky9", "terraform", lower(local.env.env_name)]

  # Generated inventory, one file per unit: hosts land in linux -> rocky9 plus their
  # ansible_groups.
  inventory_path            = "${get_repo_root()}/ansible/inventories/${local.env.env_name}/terraform_${local.unit}.yml"
  inventory_os_group        = "rocky9"
  inventory_os_parent_group = "linux"
})

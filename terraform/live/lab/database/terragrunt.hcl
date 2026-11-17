# lab: database server (PostgreSQL).
#   cd terraform/live/lab/database && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/database.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_database.yml.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/database.hcl").locals.profile
}

inputs = {
  vms = {
    "db" = merge(local.role, {
      ipv4_cidr = "192.168.70.75/24" # REPLACE
    })
  }
}

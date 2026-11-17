# lab: support services (Keycloak and the basemap server, as Docker containers).
#   cd terraform/live/lab/support && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/support.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_support.yml.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/support.hcl").locals.profile
}

inputs = {
  vms = {
    "support" = merge(local.role, {
      ipv4_cidr = "192.168.70.76/24" # REPLACE
    })
  }
}

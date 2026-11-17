# CRGS01: bastion host (kubectl, helm and k9s for every Kubernetes cluster).
#   cd terraform/live/CRGS01/bastion && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/bastion.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/CRGS01/terraform_bastion.yml.
#
# The host names and addresses are EXAMPLES (documentation addresses): replace them.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/bastion.hcl").locals.profile
}

inputs = {
  vms = {
    "crgs01-bastion01" = merge(local.role, {
      ipv4_cidr = "198.51.100.15/24"
    })
  }
}

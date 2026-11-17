# lab: artefact registry (Harbor: container images and Helm charts).
#   cd terraform/live/lab/registry && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/registry.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_registry.yml.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/registry.hcl").locals.profile
}

inputs = {
  vms = {
    "registry" = merge(local.role, {
      ipv4_cidr = "192.168.70.71/24"
    })
  }
}

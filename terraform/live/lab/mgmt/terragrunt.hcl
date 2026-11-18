# lab: bastion host (kubectl, helm and k9s for every Kubernetes cluster).
#   cd terraform/live/lab/bastion && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/bastion.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_bastion.yml.

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
    "mgmt" = merge(local.role, {
      ipv4_cidr = "192.168.70.75/24"
    })
  }
}

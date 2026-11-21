# lab: RKE2 cluster for Rancher Server (Rancher is its only workload).
#   cd terraform/live/lab/rancher-cluster && terragrunt plan
#
# Sizing per node: terraform/_envcommon/roles/rke2-rancher.hcl.
# Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_rancher-cluster.yml.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/rke2-rancher.hcl").locals.profile

  # Cluster size: 1 (single node) or 3 (highly available). Any other number fails the plan.
  # Going from 3 to 1 destroys nodes 02 and 03.
  server_count = 3

  # Nodes are named <name_prefix>01, 02, 03.
  name_prefix = "rancher"

  # One address per node, in node order. With server_count = 1 only the first is used.
  server_ipv4_cidrs = [
    "192.168.70.81/24", # REPLACE
    "192.168.70.82/24", # REPLACE
    "192.168.70.83/24", # REPLACE
  ]
}

inputs = {
  allowed_vm_counts = [1, 3]

  vms = {
    for i in range(local.server_count) :
    format("%s%02d", local.name_prefix, i + 1) => merge(local.role, {
      ipv4_cidr = local.server_ipv4_cidrs[i]
    })
  }
}

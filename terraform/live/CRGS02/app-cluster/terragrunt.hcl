# CRGS02: RKE2 cluster for the application workload (standalone or managed by Rancher Server:
# app_cluster_rancher_managed in the Ansible inventory, ansible/docs/app-cluster.md).
#   cd terraform/live/CRGS02/app-cluster && terragrunt plan
#
# Sizing per node: terraform/_envcommon/roles/rke2-app.hcl.
# Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/CRGS02/terraform_app-cluster.yml.
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
  role_config = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/rke2-app.hcl").locals
  role        = local.role_config.profile

  # Scratch disk for workloads, mounted at /scratch on every node (the last data disk). Raise the
  # size whenever needed; the filesystem (ext4 or xfs) only applies when the disk is first formatted.
  scratch_size_gb = 20
  scratch_fstype  = "ext4"
  scratch_disk = merge(local.role_config.scratch_disk, {
    size_gb = local.scratch_size_gb
    fstype  = local.scratch_fstype
  })

  # Cluster size: 1 (single node) or 3 (highly available). Any other number fails the plan.
  # Going from 3 to 1 destroys nodes 02 and 03.
  server_count = 3

  # Nodes are named <name_prefix>01, 02, 03.
  name_prefix = "crgs02-rke"

  # One address per node, in node order. With server_count = 1 only the first is used.
  server_ipv4_cidrs = [
    "203.0.113.51/24",
    "203.0.113.52/24",
    "203.0.113.53/24",
  ]
}

inputs = {
  allowed_vm_counts = [1, 3]

  vms = {
    for i in range(local.server_count) :
    format("%s%02d", local.name_prefix, i + 1) => merge(local.role, {
      ipv4_cidr = local.server_ipv4_cidrs[i]
      # Appended last, so the slots of the other disks never move.
      data_disks = concat(local.role.data_disks, [local.scratch_disk])
    })
  }
}

# CRGS00: load balancer for the Rancher RKE2 cluster (HAProxy and keepalived).
#   cd terraform/live/CRGS00/lb-rancher && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/loadbalancer.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/CRGS00/terraform_lb-rancher.yml.
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
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/loadbalancer.hcl").locals.profile
}

inputs = {
  vms = {
    "crgs00-lb-rancher01" = merge(local.role, {
      ipv4_cidr      = "192.0.2.17/24"
      ansible_groups = concat(local.role.ansible_groups, ["lb_rancher"])
      # Virtual IP keepalived holds: the address clients and nodes use for the cluster. Reserve
      # it; no VM has it as its own address. It is passed to Ansible as a host variable.
      host_vars = {
        keepalived_vip = "192.0.2.18"
      }
    })
  }
}

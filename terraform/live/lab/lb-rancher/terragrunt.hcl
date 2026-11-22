# lab: load balancer for the Rancher RKE2 cluster (HAProxy and keepalived).
#   cd terraform/live/lab/lb-rancher && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/loadbalancer.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_lb-rancher.yml.

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
    "lb-rancher" = merge(local.role, {
      ipv4_cidr      = "192.168.70.77/24"
      ansible_groups = concat(local.role.ansible_groups, ["lb_rancher"])
      # Virtual IP keepalived holds: the address clients and nodes use for the cluster. Reserve
      # it; no VM has it as its own address. It is passed to Ansible as a host variable.
      host_vars = {
        keepalived_vip = "192.168.70.80"
      }
    })
  }
}

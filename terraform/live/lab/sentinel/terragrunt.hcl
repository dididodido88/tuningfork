# lab: logging and observability VM (the SIEM: Wazuh, Prometheus, Grafana, log collectors).
#   cd terraform/live/lab/sentinel && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/siem.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/lab/terraform_sentinel.yml, which also lists the data disks.
# Don't list this host or its disks by hand in ansible/inventories/lab as well.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "os" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with the one in root.hcl instead of replacing it.
  merge_strategy = "deep"
}

locals {
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/siem.hcl").locals.profile
}

inputs = {
  vms = {
    "sentinel" = merge(local.role, {
      ipv4_cidr = "192.168.70.74/24"
    })
  }
}

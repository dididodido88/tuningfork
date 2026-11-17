# CRGS02: logging and observability VM (the SIEM: Wazuh, Prometheus, Grafana, log collectors).
#   cd terraform/live/CRGS02/siem && terragrunt plan
#
# Sizing: terraform/_envcommon/roles/siem.hcl. Every field: terraform/modules/proxmox-vm/variables.tf.
# Applying writes ansible/inventories/CRGS02/terraform_siem.yml.
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
  role = read_terragrunt_config("${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/roles/siem.hcl").locals.profile
}

inputs = {
  vms = {
    "crgs02-siem01" = merge(local.role, {
      ipv4_cidr = "203.0.113.14/24"

      # Production sizes (ansible/docs/siem.md), replacing the lab sizes of the role profile.
      # Same disks in the same order as the profile; keep it that way.
      data_disks = [
        { size_gb = 10, mount = "/var/log", fstype = "ext4" },
        { size_gb = 20, mount = "/var/log/audit", fstype = "ext4" },
        { size_gb = 300, mount = "/var/lib/wazuh-indexer", fstype = "xfs" },
        { size_gb = 100, mount = "/var/ossec", fstype = "xfs" },
        { size_gb = 100, mount = "/var/lib/prometheus", fstype = "xfs" },
        { size_gb = 50, mount = "/var/log/remote", fstype = "xfs" },
        { size_gb = 20, mount = "/var/cache/tuningfork", fstype = "xfs" },
      ]
    })
  }
}

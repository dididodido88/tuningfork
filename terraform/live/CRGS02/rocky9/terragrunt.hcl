# CRGS02 Rocky Linux 9 VMs.
#   cd terraform/live/CRGS02/rocky9 && terragrunt plan
#
# Applying writes ansible/inventories/CRGS02/terraform_rocky9.yml. The field reference for vms
# is in terraform/modules/proxmox-vm/variables.tf. The hosts below mirror the examples in
# ansible/inventories/CRGS02/hosts.yml: replace them with real ones.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rocky9.hcl"
  # deep: combine its terraform {} block with root.hcl's instead of replacing it.
  merge_strategy = "deep"
}

inputs = {
  vms = {
    "crgs02-nfs01" = {
      ipv4_cidr      = "203.0.113.11/24"
      ansible_groups = ["nfs_servers"]
      data_disks = [
        { size_gb = 200, mount = "/srv/nfs", fstype = "xfs" },
      ]
    }

    "crgs02-db01" = {
      ipv4_cidr      = "203.0.113.12/24"
      cores          = 4
      memory_mb      = 16384
      ansible_groups = ["db_servers"]
      data_disks = [
        { size_gb = 100, mount = "/var/lib/pgsql", fstype = "xfs" },
      ]
    }

    "crgs02-registry01" = {
      ipv4_cidr      = "203.0.113.13/24"
      cores          = 4
      memory_mb      = 8192
      ansible_groups = ["registry_servers"]
      data_disks = [
        { size_gb = 200, mount = "/srv/harbor", fstype = "xfs" },
      ]
    }
  }
}

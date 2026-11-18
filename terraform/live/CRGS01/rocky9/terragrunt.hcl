# CRGS01 Rocky Linux 9 VMs.
#   cd terraform/live/CRGS01/rocky9 && terragrunt plan
#
# Applying writes ansible/inventories/CRGS01/terraform_rocky9.yml. The field reference for vms
# is in terraform/modules/proxmox-vm/variables.tf. The hosts below mirror the examples in
# ansible/inventories/CRGS01/hosts.yml: replace them with real ones.

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
    "crgs01-nfs01" = {
      ipv4_cidr      = "198.51.100.11/24"
      ansible_groups = ["nfs_servers"]
      data_disks = [
        { size_gb = 200, mount = "/srv/nfs", fstype = "xfs" },
      ]
    }

    "crgs01-db01" = {
      ipv4_cidr      = "198.51.100.12/24"
      cores          = 4
      memory_mb      = 16384
      ansible_groups = ["db_servers"]
      data_disks = [
        { size_gb = 100, mount = "/var/lib/pgsql", fstype = "xfs" },
      ]
    }

    "crgs01-registry01" = {
      ipv4_cidr      = "198.51.100.13/24"
      cores          = 4
      memory_mb      = 8192
      ansible_groups = ["registry_servers"]
      data_disks = [
        { size_gb = 200, mount = "/srv/harbor", fstype = "xfs" },
      ]
    }
  }
}

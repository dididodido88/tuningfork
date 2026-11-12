# lab Rocky Linux 9 VMs.
#   cd terraform/live/lab/rocky9 && terragrunt plan
#
# Applying writes ansible/inventories/lab/terraform_rocky9.yml. The field reference for vms
# is in terraform/modules/proxmox-vm/variables.tf.

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
    "lab-registry" = {
      ipv4_cidr      = "192.168.70.71/24"
      cores          = 4
      memory_mb      = 8192
      ansible_groups = ["registry_servers"]
      # Harbor data (images, charts, database); harbor_data_dir lives under it.
      data_disks = [
        { size_gb = 200, mount = "/srv/harbor", fstype = "xfs" },
      ]
    }

    "lab-k8s-bastion" = {
      ipv4_cidr      = "192.168.70.72/24"
      ansible_groups = ["k8s_bastions"]
    }
  }
}

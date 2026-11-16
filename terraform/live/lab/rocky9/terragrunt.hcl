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
    "registry" = {
      ipv4_cidr      = "192.168.70.71/24"
      cores          = 4
      memory_mb      = 8192
      ansible_groups = ["registry_servers"]
      # Harbor data (images, charts, database); harbor_data_dir lives under it.
      data_disks = [
        { size_gb = 200, mount = "/srv/harbor", fstype = "xfs" },
      ]
    }

    "mgmt" = {
      ipv4_cidr      = "192.168.70.72/24"
      ansible_groups = ["k8s_bastions"]
    }

    # SIEM VM: Wazuh, Prometheus, Grafana and the log collectors (docs/siem.md).
    "sentinel" = {
      ipv4_cidr      = "192.168.70.74/24"
      cores          = 8
      memory_mb      = 16384
      ansible_groups = ["siem_servers"]
      # Same order (scsi1-scsi5) as a hand-built SIEM VM's host_vars.
      data_disks = [
        { size_gb = 100, mount = "/var/lib/wazuh-indexer", fstype = "xfs" },
        { size_gb = 40, mount = "/var/ossec", fstype = "xfs" },
        { size_gb = 40, mount = "/var/lib/prometheus", fstype = "xfs" },
        { size_gb = 20, mount = "/var/log/remote", fstype = "xfs" },
        { size_gb = 10, mount = "/var/log/audit", fstype = "xfs" },
      ]
    }
  }
}

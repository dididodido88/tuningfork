# One node of the RKE2 cluster that runs Rancher Server (its only workload).
# The cluster has 1 node or 3; the unit sets the count. Every node is an RKE2 server
# (control plane, etcd and workload). Ansible groups: rke2_servers, rke2_rancher.
#
# 2 cores and 4 GB is the minimum for an RKE2 server and leaves little for Rancher itself.
# The Rancher guidance for a small installation is 4 vCPU and 16 GB per node.

locals {
  profile = {
    cores          = 2
    memory_mb      = 4096
    ansible_groups = ["rke2_servers", "rke2_rancher"]
    tags           = ["rke2", "rancher"]

    # Holds data: Proxmox refuses to remove this VM or its disks until protection is turned off
    # (terraform/README.md, "Protection").
    protection = true

    data_disks = [
      # Also holds the pod logs (/var/log/pods, /var/log/containers).
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # RKE2: container images, the etcd database and its snapshots.
      { size_gb = 50, mount = "/var/lib/rancher", fstype = "xfs" },
      # Pod ephemeral storage and emptyDir volumes. Without it they fill the 10 GB /var.
      { size_gb = 20, mount = "/var/lib/kubelet", fstype = "xfs" },
    ]
  }
}

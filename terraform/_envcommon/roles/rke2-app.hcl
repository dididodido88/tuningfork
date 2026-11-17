# One node of the RKE2 cluster that runs the application workload. The cluster is managed by
# Rancher Server in the other RKE2 cluster. It has 1 node or 3; the unit sets the count.
# Every node is an RKE2 server (control plane, etcd and workload).
# Ansible groups: rke2_servers, rke2_app.

locals {
  profile = {
    cores          = 8
    memory_mb      = 32768
    ansible_groups = ["rke2_servers", "rke2_app"]
    tags           = ["rke2", "app"]

    # Holds data: Proxmox refuses to remove this VM or its disks until protection is turned off
    # (terraform/README.md, "Protection").
    protection = true

    data_disks = [
      # Also holds the pod logs (/var/log/pods, /var/log/containers).
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # RKE2: container images, the etcd database and its snapshots.
      { size_gb = 100, mount = "/var/lib/rancher", fstype = "xfs" },
      # Pod ephemeral storage and emptyDir volumes. Without it they fill the 10 GB /var.
      { size_gb = 50, mount = "/var/lib/kubelet", fstype = "xfs" },
    ]
  }
}

# One node of the RKE2 cluster that runs the application workload. The cluster is either
# standalone or managed by Rancher Server (app_cluster_rancher_managed in the Ansible inventory,
# ansible/docs/app-cluster.md). It has 1 node or 3; the unit sets the count. Every node is an
# RKE2 server (control plane, etcd and workload). Ansible groups: rke2_servers, rke2_app.

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

  # Local scratch space for workloads (hostPath /scratch), appended by the unit as the last data
  # disk. The unit sets its size and filesystem (scratch_size_gb, scratch_fstype); these are the
  # defaults. The size can be raised later; the filesystem only applies when the disk is first
  # formatted (ext4 or xfs, the types the Ansible filesystems role supports).
  scratch_disk = { mount = "/scratch", size_gb = 20, fstype = "ext4" }
}

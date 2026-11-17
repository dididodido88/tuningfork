# Bastion host: manages every Kubernetes cluster with kubectl, helm and k9s.
# Ansible: roles/kubectl and roles/k8s_bastion, group k8s_bastions.
#
# No CPU or memory was specified: 2 cores and 4 GB are enough for client tools.

locals {
  profile = {
    cores          = 2
    memory_mb      = 4096
    ansible_groups = ["k8s_bastions"]
    tags           = ["bastion"]

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
    ]
  }
}

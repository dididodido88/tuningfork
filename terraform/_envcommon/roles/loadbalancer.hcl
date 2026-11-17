# Load balancer for one RKE2 cluster: HAProxy, with keepalived holding the virtual IP.
# Used by two units: lb-rancher (Rancher cluster) and lb-app (application cluster). Each unit
# adds its own cluster group and the virtual IP. Ansible group: load_balancers.

locals {
  profile = {
    cores          = 4
    memory_mb      = 4096
    ansible_groups = ["load_balancers"]
    tags           = ["loadbalancer"]

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
    ]
  }
}

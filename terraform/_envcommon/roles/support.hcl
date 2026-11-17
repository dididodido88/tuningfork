# Support services: Docker containers for Keycloak (identity and access management, federated
# to Active Directory) and the basemap server used by the web application.
# Ansible group: support_servers.

locals {
  profile = {
    cores          = 8
    memory_mb      = 32768
    ansible_groups = ["support_servers"]
    tags           = ["support"]

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # Container images.
      { size_gb = 50, mount = "/var/lib/containerd", fstype = "xfs" },
      # Keycloak persistent data.
      { size_gb = 10, mount = "/kcdata", fstype = "xfs" },
      # Basemap data.
      { size_gb = 20, mount = "/basemap", fstype = "xfs" },
    ]
  }
}

# Database server: PostgreSQL, hosting the databases of the environment.
# Ansible: roles/database_server, group db_servers.

locals {
  profile = {
    cores          = 4
    memory_mb      = 4096
    ansible_groups = ["db_servers"]
    tags           = ["database"]

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # PostgreSQL data directory. No size was specified: 100 GB is a starting point.
      { size_gb = 100, mount = "/dbdata", fstype = "xfs" },
    ]
  }
}

# NAS server: persistent data for the clusters, exported over NFS. One disk per export.
# Ansible: roles/nas_server, group nas_servers.
#
# To add an export, append a disk here and add the export to nas_server_exports in
# ansible/inventories/<ENV>/group_vars/nas_servers.yml.

locals {
  profile = {
    cores          = 4
    memory_mb      = 8192
    ansible_groups = ["nas_servers"]
    tags           = ["nas"]

    # Holds data: Proxmox refuses to remove this VM or its disks until protection is turned off
    # (terraform/README.md, "Protection").
    protection = true

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      { size_gb = 50, mount = "/export/pvcdata", fstype = "xfs" },
      { size_gb = 10, mount = "/export/cfr", fstype = "xfs" },
      { size_gb = 100, mount = "/export/testdata", fstype = "xfs" },
      { size_gb = 40, mount = "/export/deliveries", fstype = "xfs" },
      { size_gb = 30, mount = "/export/backups", fstype = "xfs" },
    ]
  }
}

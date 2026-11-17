# Artefact registry: Harbor (container images and Helm charts) under Docker.
# Ansible: roles/harbor, group registry_servers.
#
# A role profile is read by the units (live/<ENV>/registry/terragrunt.hcl) and merged with the
# hostname and address. Data disks become scsi1, scsi2, ... in this order: append new disks at
# the end, because removing or reordering changes the slot numbers of the disks after it.

locals {
  profile = {
    cores          = 4
    memory_mb      = 8192
    ansible_groups = ["registry_servers"]
    tags           = ["registry"]

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      # 30 days of audit records.
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # Images of the Harbor containers.
      { size_gb = 100, mount = "/var/lib/containerd", fstype = "xfs" },
      # Harbor application directory (/opt/harbor): the offline installer is about 1 GB packed
      # and the same again unpacked, kept per version. 20 GB holds several versions.
      { size_gb = 20, mount = "/opt", fstype = "xfs" },
      # Images, charts, database and job logs (harbor_data_dir: /srv/harbor/data).
      { size_gb = 200, mount = "/srv", fstype = "xfs" },
    ]
  }
}

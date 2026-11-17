# Logging and observability VM: the SIEM (Wazuh indexer, manager and dashboard, Prometheus,
# Grafana, log collectors). Ansible: roles/wazuh_server and roles/postfix_relay, group
# siem_servers. Design and sizing: ansible/docs/siem.md and ansible/docs/siem/siem_design.md.
#
# The data volumes are separate so one full data store cannot stop the others. The sizes here
# are the lab sizes from ansible/docs/siem.md; the CRGS units replace data_disks with the
# production sizes from the same table. Measure a week of real ingest before fixing them.

locals {
  profile = {
    cores          = 8
    memory_mb      = 16384
    ansible_groups = ["siem_servers"]
    tags           = ["siem"]

    # Holds data: Proxmox refuses to remove this VM or its disks until protection is turned off
    # (terraform/README.md, "Protection").
    protection = true

    data_disks = [
      { size_gb = 10, mount = "/var/log", fstype = "ext4" },
      { size_gb = 10, mount = "/var/log/audit", fstype = "ext4" },
      # Indexed alerts (90 days searchable).
      { size_gb = 100, mount = "/var/lib/wazuh-indexer", fstype = "xfs" },
      # Wazuh manager: queues, logs and the archive of every received event (180 days).
      { size_gb = 40, mount = "/var/ossec", fstype = "xfs" },
      # Prometheus time series (90 days).
      { size_gb = 40, mount = "/var/lib/prometheus", fstype = "xfs" },
      # Syslog and SNMP traps received from other systems (180 days).
      { size_gb = 20, mount = "/var/log/remote", fstype = "xfs" },
      # Checked copies of the SIEM artifacts (roles/siem_artifacts: /var/cache/tuningfork/siem).
      # Without this disk they sit on the 10 GB /var of the template.
      { size_gb = 20, mount = "/var/cache/tuningfork", fstype = "xfs" },
    ]
  }
}

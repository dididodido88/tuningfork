# SIEM and observability stack

One dedicated Rocky Linux 9 VM per environment (the **SIEM VM**) runs Wazuh (indexer, manager, dashboard),
rsyslog and snmptrapd collectors, Prometheus, Alertmanager, the exporters, Grafana and a Postfix relay.
Rocky VMs, the Proxmox host, the domain controller(s) and the iDRAC report to it.

Nothing is downloaded from the internet inside the air gap. Every artifact is downloaded by hand on the
internet-connected download machine, uploaded to the mirror, and checked against its pinned SHA-256 before
installation.

This document grows with each deployment phase. Sections still to come: adding a VM,
adding a log file, restoring the SIEM VM.

---

## 1. Versions and checksums

All versions and SHA-256 checksums are in **`inventories/<ENV>/group_vars/all/siem_versions.yml`**, one file
per environment. It is also the artifact manifest: each entry of `siem_artifacts` records the artifact, its
mirror path, its checksum and its source URL.

| Variable | Pinned |
|---|---|
| `wazuh_version` | 4.14.10 (manager, indexer, dashboard and every agent; agents may never be newer than the manager) |
| `prometheus_version` | 3.15.1 |
| `alertmanager_version` | 0.35.0 |
| `node_exporter_version` | 1.12.1 |
| `snmp_exporter_version` | 0.31.0 |
| `grafana_version` | 13.3.1 (OSS RPM) |
| `windows_exporter_version` | 0.32.1 (MSI) |
| `pve_exporter_version` | 3.11.0 (wheels for Python `pve_exporter_python_version`) |
| `clamav_signatures_version` | date of the signature snapshot |

Each `siem_artifacts` entry has:

| Field | Meaning |
|---|---|
| `path` | where the file is on the mirror, relative to `siem_mirror_url` (= `env_repo_base_url`; maestro serves it from `/repo`), e.g. `prometheus/prometheus-3.15.1.linux-amd64.tar.gz` is `https://maestro/prometheus/prometheus-3.15.1.linux-amd64.tar.gz`, file `/repo/prometheus/prometheus-3.15.1.linux-amd64.tar.gz` |
| `source` | where to download it |
| `upstream_sha256` | the published checksum list to check the download against (where one exists) |
| `note` | extra steps (only for files that aren't a plain download) |
| `sha256` | the pinned checksum. **An artifact with an empty `sha256` is never installed.** |

rsyslog, net-snmp, postfix, audit, chrony and ClamAV itself come from the mirrored Rocky/EPEL and
Debian/Proxmox repositories, not from this list.

---

## 2. Getting the artifacts

### 2.1 Print the download list

On the control node, from `ansible/` (nothing is downloaded):

```sh
ansible-playbook -i inventories/lab playbooks/siem_download_list.yml
# only what still has no sha256 (new or changed versions):
ansible-playbook -i inventories/lab playbooks/siem_download_list.yml -e siem_download_list_missing_only=true
```

It prints the list and writes it to `/tmp/siem-download-list-<env>.txt`. For each file, it gives:
- the path to upload it to
- the download URL
- the upstream checksum to check it against
- any extra steps

### 2.2 Download (internet-connected download machine)

**Plain downloads:** the two Wazuh scripts, the three Wazuh agent packages, the Prometheus
stack tarballs and the windows_exporter MSI. Check each file against its `upstream_sha256` list where one
is given:

```sh
sha256sum prometheus-3.15.1.linux-amd64.tar.gz
curl -sL https://github.com/prometheus/prometheus/releases/download/v3.15.1/sha256sums.txt | grep linux-amd64.tar.gz
```

**Files that need extra steps:**

| File | How |
|---|---|
| `wazuh-offline.tar.gz` | Wazuh's documented offline method: `curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh && bash wazuh-install.sh --download-wazuh rpm`. Check it contains 4.14.10: `tar -tzf wazuh-offline.tar.gz \| grep -E 'wazuh-(manager\|indexer\|dashboard)-4.14.10'` must list all three. |
| vulnerability feed snapshot | `curl -s https://cti.wazuh.com/api/v1/catalog/contexts/vd_1.0.0/consumers/vd_4.8.0` returns JSON. Download the URL in `data.last_snapshot_link` and set `wazuh_vd_feed_file` to its file name (e.g. `4363150_1794228133.zip`). |
| Grafana RPM | grafana.com → Download → version 13.3.1, OSS edition, Linux, "Red Hat, CentOS, RHEL, and Fedora (64 Bit)". Check the SHA256 shown there. Set `grafana_build` to the build number in its name (`grafana_13.3.1_<build>_linux_amd64.rpm`). |
| `iDRAC-SMIv2.mib` | dell.com support → the server model → drivers & downloads → iDRAC9 "SNMP MIB". |
| `prometheus-pve-exporter-3.11.0-py3.12-wheels.tar.gz` | The `pip download` and `tar` commands in the list's note (wheels for Python 3.12, x86_64, with every dependency). |
| `main.cvd`, `daily.cvd`, `bytecode.cvd` | `python3 -m venv cvd && cvd/bin/pip install cvdupdate && cvd/bin/cvd config set --dbdir ./cvd-db && cvd/bin/cvd update`. The ClamAV CDN refuses plain downloads. First set `clamav_signatures_version` to the download date. |

### 2.3 snmp_exporter iDRAC module

The iDRAC is read with the **`dell` module that ships in the snmp_exporter release's own `snmp.yml`**, used
unmodified. Nothing extra is downloaded or generated. It walks the iDRAC-SMIv2 status, system and storage
subtrees: global, storage and LCD status, power state, and the power supply, cooling, temperature, voltage,
memory, processor, battery, intrusion, controller, physical disk and virtual disk tables. The release's
`dell_rac` module is for older remote access controllers and isn't used. The SNMPv3 credentials are added from
the vault in a separate file on the SIEM VM.

The module also walks the System Event Log and Lifecycle log tables, which can make a scrape slow. Phase 3 checks
`snmp_scrape_duration_seconds` against the scrape timeout.

### 2.4 Upload to the mirror

Upload every file to `/repo/<path>` on maestro, exactly as the list shows, e.g.
`/repo/prometheus/prometheus-3.15.1.linux-amd64.tar.gz`. The web server must be able to read it:

```sh
chmod 0644 /repo/<path>
restorecon -v /repo/<path>     # a file moved (not copied) in keeps its old SELinux label
```

Extracted copies and the upstream checksum files can stay next to them; only the listed paths are used.

### 2.5 Send the checksums

The end of the download list has a `cd /repo && sha256sum <every listed path>` command. Run it on the mirror
and send the output; each value goes into the `sha256` of the matching entry in `siem_versions.yml`, in every
environment that uses these files.

### 2.6 Check on the inside

From `ansible/` on the control node:

```sh
# On the SIEM VM: downloads every artifact from the mirror and checks each sha256 against
# siem_versions.yml (acceptance test 1)
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml

# Before the SIEM VM exists: on the control node, into a temporary directory
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml -e siem_artifacts_hosts=localhost \
  -e siem_artifacts_cache_dir=/var/tmp/siem-artifacts-check -K
```

Every role that installs a SIEM component runs the same check (`roles/siem_artifacts`) for the artifacts it
needs. It installs only from the checked copy in `/var/cache/tuningfork/siem/` (`C:\ProgramData\Tuningfork\siem\`
on Windows).

### 2.7 Updating a version

1. Change the version in `siem_versions.yml`, and empty the `sha256` of the entries that change.
2. Run `playbooks/siem_download_list.yml -e siem_download_list_missing_only=true`, then download and upload
   those files and send the checksums.
3. Files with the version in their name can stay on the mirror for rollback. `wazuh-install.sh`,
   `wazuh-passwords-tool.sh` and `wazuh-offline.tar.gz` have fixed names: the new ones replace the old.
4. Run the playbook of that component.

**Wazuh:** upgrade the manager first, then the agents. Agents must never be newer than the manager.

---

## 3. First deployment of the SIEM VM

### 3.1 Prerequisites

| What | Where |
|---|---|
| The VM: Rocky 9, 8 cores, 16 GB RAM, five data disks on scsi1–scsi5 | **Terraform**: the unit `terraform/live/<ENV>/siem`, which also attaches the data disks and writes them into the inventory (`terraform/README.md`). **By hand** (lab): clone the Rocky 9 template as `sentinel`, then add the disks below in this order. |
| DNS A record for `siem_server_name` | AD DNS, e.g. `sentinel.lab.local` → 192.168.70.74 |
| Host certificate covering `siem_server_name` | `/srv/security/certificates/files/<certificates_env_dir>/<short name>/` on the control node (roles/certificates) |
| Inventory | `hosts.yml`: the host in `rocky9` and `siem_servers`. A hand-built VM also needs its disks in `host_vars/<host>.yml`. A Terraform-built VM (lab: `sentinel`) is listed in `terraform_siem.yml` or `terraform_sentinel.yml` instead, with its disks: don't list it or its disks by hand as well. |
| Settings | `group_vars/all/siem.yml` (name, address, networks, email) and `group_vars/siem_servers.yml` |
| Secrets | `ansible-vault edit inventories/<ENV>/group_vars/all/vault.yml`, see 3.2 |

Data disks of a hand-built VM, in order (lab is smaller):

| Disk | Mount | CRGS | lab |
|---|---|---|---|
| scsi1 | `/var/lib/wazuh-indexer` | 300 GB | 100 GB |
| scsi2 | `/var/ossec` | 100 GB | 40 GB |
| scsi3 | `/var/lib/prometheus` | 100 GB | 40 GB |
| scsi4 | `/var/log/remote` | 50 GB | 20 GB |
| scsi5 | `/var/log/audit` | 20 GB | 10 GB |

A VM built by Terraform has the same volumes, plus `/var/log` and `/var/cache/tuningfork`, in the
order of `terraform/_envcommon/roles/siem.hcl`. It needs no `host_vars` file for its disks.

The SIEM VM gets no Wazuh agent: the manager package and the agent package can't be installed
together, and the manager already monitors its own host.

### 3.2 Vault keys

| Key | Used for |
|---|---|
| `vault_wazuh_indexer_admin_password` | `admin`: Wazuh dashboard and indexer login (break-glass administrator) |
| `vault_wazuh_api_password` | `wazuh`: Wazuh server API administrator |
| `vault_wazuh_enrollment_password` | agents enroll with it (at least 8 characters, no spaces); every agent role uses the same key |
| `vault_postfix_relay_password` | only if `siem_mail_relay_username` is set |
| `vault_grafana_admin_password` | Grafana `admin` (break-glass administrator), at least 12 characters |
| `vault_snmp_idrac_auth_password`, `vault_snmp_idrac_priv_password` | SNMPv3 user `siem_idrac_snmp_username` the SIEM VM polls the iDRACs with (set with the iDRAC configuration) |
| `vault_pve_exporter_token_value` | Proxmox API token `siem_pve_api_user`!`siem_pve_token_name` (set with the Proxmox monitoring) |

Wazuh passwords: 8 to 64 characters, only `A-Z a-z 0-9 . * + ? -`, with at least one upper-case letter, one
lower-case letter, one digit and one symbol. The role replaces the generated passwords with these right after
installation.

### 3.3 Run

From `ansible/`, on the control node:

```sh
# New SIEM VM: every layer in order (CA trust and host certificate, mirror repositories, data disks,
# CIS, common Linux config), then the SIEM plays (siem.yml)
ansible-playbook -i inventories/lab playbooks/site.yml --limit sentinel.lab.local
# Later, the SIEM plays only
ansible-playbook -i inventories/lab playbooks/siem.yml
```

`siem.yml` runs `postfix_relay.yml` and `wazuh_server.yml`. The Wazuh installation runs once and takes several
minutes; its full log is `/var/log/wazuh-install.log` on the SIEM VM (root only). A second run must report
`changed=0`.

### 3.4 Check

- Dashboard: `https://<siem_server_name>/`, log in as `admin` with `vault_wazuh_indexer_admin_password`. The
  browser must show the internal CA's certificate.
- On the SIEM VM: `systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard` (all `active`).
- Mail: `echo test | mail -s "SIEM mail test" <recipient>`, then `postqueue -p`. While no relay is set, or the
  relay is down, the message waits in the queue; nothing else is affected.

### 3.5 Collectors on the SIEM VM

| Component | Listens on | Who may connect (firewalld) | Writes to |
|---|---|---|---|
| rsyslog receiver | 514/udp, 514/tcp | `siem_log_senders`: the `proxmox_hosts` and `idrac` groups, plus `siem_log_senders_extra` | `/var/log/remote/<sender IP>/<program>.log` (kept 30 days) |
| snmptrapd | 162/udp | `siem_trap_senders`: the `idrac` group, plus `siem_log_senders_extra`; SNMPv3 users in `siem_snmp_trap_users` only | `/var/log/remote/snmptrapd/traps.log` |
| node_exporter | 127.0.0.1:9100 | local | |
| Prometheus | 127.0.0.1:9090 | local (viewed through Grafana) | `/var/lib/prometheus` (90 days or `prometheus_retention_size`) |
| Alertmanager | 127.0.0.1:9093 | local | email through Postfix to `siem_mail_to` |
| snmp_exporter | 127.0.0.1:9116 | local; polls the iDRACs (SNMPv3, stock `dell` module) once the SNMPv3 credentials are set | |
| pve-exporter | 127.0.0.1:9221 | local; reads the Proxmox API (each node, plus cluster-wide data from the first node) once the token is set | |
| Grafana | 3000/tcp (HTTPS, host certificate) | `siem_admin_networks` | `/var/lib/grafana`; dashboards from `/var/lib/grafana/dashboards/tuningfork` |

The Wazuh manager reads every file under `/var/log/remote` (`wazuh_server_localfiles`). The SIEM VM is the
environment's log host, so the CIS control "Ensure only one logging system is in use" is off for
`siem_servers` (`playbooks/group_vars/siem_servers.yml`): it would stop rsyslog on every run.

Check from the SIEM VM:

```sh
systemctl is-active rsyslog snmptrapd node_exporter prometheus alertmanager snmp_exporter pve_exporter grafana-server
curl -s 127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
logger -n 127.0.0.1 -P 514 -d -t tuningfork-test "syslog receiver test"   # from a sender: -n <SIEM VM>
ls /var/log/remote/
```

---

## 4. Writing rules

Audit requirements are referred to by **title only**, everywhere: code, comments, rule descriptions,
documents and output. `scripts/check-no-requirement-ids.sh` fails if a requirement identifier in square
brackets appears in the repository (it is part of the lint checks in `README.md`).

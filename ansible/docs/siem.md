# SIEM and observability stack

One dedicated Rocky Linux 9 VM per environment (the **SIEM VM**) runs Wazuh (indexer, manager, dashboard),
rsyslog and snmptrapd collectors, Prometheus, Alertmanager, the exporters, Grafana and a Postfix relay.
Rocky VMs, the Proxmox host, the domain controller(s) and the iDRAC report to it.

Nothing is downloaded from the internet inside the air gap. Every artifact is downloaded by hand on the
internet-connected download machine, uploaded to the mirror, and checked against its pinned SHA-256 before
installation.

This document grows with each deployment phase. Sections still to come: first deployment, adding a VM,
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

## 3. Writing rules

Audit requirements are referred to by **title only**, everywhere: code, comments, rule descriptions,
documents and output. `scripts/check-no-requirement-ids.sh` fails if a requirement identifier in square
brackets appears in the repository (it is part of the lint checks in `README.md`).

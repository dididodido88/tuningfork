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
version, its checksum and its source URL.

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
| `product`, `version`, `file` | where the file goes on the mirror: `<siem_mirror_url>/<product>/<version>/<file>`, with `siem_mirror_url` = `<env_repo_base_url>/siem` (e.g. `https://maestro/siem/prometheus/3.15.1/prometheus-3.15.1.linux-amd64.tar.gz`) |
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

**Plain downloads:** the Wazuh scripts and `config.yml`, the three Wazuh agent packages, the Prometheus
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
| `vd-feed-snapshot.zip` | `curl -s https://cti.wazuh.com/api/v1/catalog/contexts/vd_1.0.0/consumers/vd_4.8.0` returns JSON. Download the URL in `data.last_snapshot_link` and save it as `vd-feed-snapshot.zip`. |
| `grafana-13.3.1-1.x86_64.rpm` | grafana.com → Download → version 13.3.1, OSS edition, Linux, "Red Hat, CentOS, RHEL, and Fedora (64 Bit)". Check the SHA256 shown there, and rename the file to the name in the list if it differs. |
| `iDRAC-SMIv2.mib` | dell.com support → the server model → drivers & downloads → iDRAC9 "SNMP MIB". |
| `prometheus-pve-exporter-3.11.0-py3.12-wheels.tar.gz` | The `pip download` and `tar` commands in the list's note (wheels for Python 3.12, x86_64, with every dependency). |
| `main.cvd`, `daily.cvd`, `bytecode.cvd` | `python3 -m venv cvd && cvd/bin/pip install cvdupdate && cvd/bin/cvd config set --dbdir ./cvd-db && cvd/bin/cvd update`. The ClamAV CDN refuses plain downloads. First set `clamav_signatures_version` to the download date. |
| `snmp-idrac.yml` | see 2.3 |

### 2.3 snmp_exporter iDRAC module (`snmp-idrac.yml`)

snmp_exporter needs a module describing the iDRAC's SNMP objects. Only the `modules:` section is uploaded;
the SNMPv3 credentials are added from the vault on the SIEM VM.

1. Look for a stock module in the release:
   ```sh
   tar -xzf snmp_exporter-0.31.0.linux-amd64.tar.gz
   grep -nE '^  [a-z_]*(dell|idrac)[a-z_]*:' snmp_exporter-0.31.0.linux-amd64/snmp.yml
   ```
2. If there is none, which is the usual case, generate it. Use the same generator version, with
   `files/snmp_exporter/generator.yml` from this repository, the Dell MIB and the standard MIBs from net-snmp:
   ```sh
   mkdir -p gen/mibs
   cp <repo>/ansible/files/snmp_exporter/generator.yml gen/
   cp /usr/share/snmp/mibs/* iDRAC-SMIv2.mib gen/mibs/
   podman run --rm -v "$PWD/gen:/opt:Z" docker.io/prom/snmp-generator:v0.31.0 generate   # or docker run
   ```
   The generator stops and names any object the MIB doesn't define. In that case, send me the message.
3. Keep only the `modules:` section of `gen/snmp.yml`, which holds the `dell_idrac` module, and save it as
   `snmp-idrac.yml`:
   ```sh
   sed -n '/^modules:/,$p' gen/snmp.yml > snmp-idrac.yml
   ```

### 2.4 Upload to the mirror

Upload every file to `<mirror web root>/siem/<product>/<version>/<file>`, exactly as the list shows, e.g.
`siem/prometheus/3.15.1/prometheus-3.15.1.linux-amd64.tar.gz`.

### 2.5 Send the file listing

On the mirror:

```sh
cd <mirror web root>/siem && find . -type f | sort | xargs sha256sum
```

Each line is `<sha256>  ./<product>/<version>/<file>`. Each value goes into the `sha256` of the matching entry
in `siem_versions.yml`, in every environment that uses these files. Send me the listing and I'll fill them in,
or copy them yourself.

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
   those files and send the listing.
3. Older versions can stay on the mirror for rollback.
4. Run the playbook of that component.

**Wazuh:** upgrade the manager first, then the agents. Agents must never be newer than the manager.

---

## 3. Writing rules

Audit requirements are referred to by **title only**, everywhere: code, comments, rule descriptions,
documents and output. `scripts/check-no-requirement-ids.sh` fails if a requirement identifier in square
brackets appears in the repository (it is part of the lint checks in `README.md`).

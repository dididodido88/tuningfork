# SIEM and observability stack

One dedicated Rocky Linux 9 VM per environment (the **SIEM VM**) runs Wazuh (indexer, manager, dashboard),
rsyslog and snmptrapd collectors, Prometheus, Alertmanager, the exporters, Grafana and a Postfix relay.
Rocky VMs, the Proxmox host, the domain controller(s) and the iDRAC report to it.

Nothing is downloaded from the internet inside the air gap. Every artifact is carried across in a
**bundle**, copied to the mirror, and checked against its pinned SHA-256 before installation.

This document grows with each deployment phase. Sections still to come: first deployment, adding a VM,
adding a log file, restoring the SIEM VM.

---

## 1. Versions and checksums

All versions and SHA-256 checksums are in **`inventories/<ENV>/group_vars/all/siem_versions.yml`**, one file
per environment:

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

`siem_artifacts` lists every artifact with its mirror location (`product`, `version`, `file`), its `source`
and its `sha256`. **An artifact with an empty `sha256` is never installed.** rsyslog, net-snmp, postfix,
audit, chrony and ClamAV come from the mirrored Rocky/EPEL and Debian/Proxmox repositories instead.

Mirror path of each artifact: `<siem_mirror_url>/<product>/<version>/<file>`, where
`siem_mirror_url` is `<env_repo_base_url>/siem` (e.g. `https://maestro/siem/prometheus/3.15.1/...`).

---

## 2. Building the bundle (internet-connected staging machine)

### Prerequisites

A Linux machine with internet access and a checkout of this repository:

- ansible-core 2.14 or later
- python3 with pip and venv
- curl, tar, sha256sum
- net-snmp's MIB files in `/usr/share/snmp/mibs` (Rocky: `dnf install net-snmp-libs`)
- podman, or docker with `BUNDLE_CONTAINER_RUNTIME=docker`. This is only needed if the snmp_exporter
  release has no stock iDRAC module; the generator then runs from the `prom/snmp-generator` image of the
  same version.
- **`bundle/manual/iDRAC-SMIv2.mib`**: Dell's download links change, so get the iDRAC9 "SNMP MIB" package
  from dell.com and drop the MIB file there.

### Build

From `ansible/`:

```sh
# 1. Set clamav_signatures_version to today's date in siem_versions.yml (new signature snapshot).
# 2. Build
bundle/build-bundle.sh lab
```

What the script does:

1. **Checks that every artifact has a pinned version.**
2. **Downloads the artifacts:**
   - Prometheus, Alertmanager, node_exporter, snmp_exporter and windows_exporter: each download must match
     the upstream `sha256sums.txt` of its release.
   - Grafana: must match the `.sha256` file published next to the RPM.
   - Wazuh agents and the installer scripts: no upstream checksum list exists, so these are recorded on
     first download.
3. **Checks pinned values:** if an entry already has a `sha256` in `siem_versions.yml`, the download must
   match it.
4. **Builds the Wazuh offline package set** with `wazuh-install.sh --download-wazuh rpm`, then checks that
   the manager, indexer and dashboard packages are all `wazuh_version`.
5. **Downloads the latest Wazuh vulnerability detection feed snapshot** (offline update).
6. **Takes the stock iDRAC module** from snmp_exporter's `snmp.yml` if the release has one. Otherwise it
   generates one from `files/snmp_exporter/generator.yml` and the Dell MIB.
7. **Downloads the prometheus-pve-exporter wheels** (with all dependencies) for the target Python.
8. **Downloads the ClamAV signatures** with `cvdupdate`.
9. **Writes the output** (below).

Output in `bundle/out/siem-bundle-<ENV>-<date>/`:

| Path | Purpose |
|---|---|
| `siem/` | the tree to copy to the mirror |
| `siem/manifest.yml` | artifact, product, version, file, sha256, source URL for every file |
| `siem_checksums.yml` | the sha256 values to paste into `siem_versions.yml` |
| `SHA256SUMS` | checks the copy after transfer |

### Record the checksums

Copy each value from `siem_checksums.yml` into the `sha256` of the matching entry in `siem_versions.yml`, for
every environment that uses this bundle. Commit. A later build with the same versions fails if upstream
changed a file.

### Carry it across

```sh
# Inside, after the transfer
cd siem-bundle-lab-<date>
sha256sum -c SHA256SUMS
# Copy siem/ to the mirror's web root, so it is served as https://maestro/siem/
```

### Check on the inside

```sh
# From ansible/ on the control node: downloads every artifact from the mirror, checks each sha256 against
# siem_versions.yml and compares manifest.yml (acceptance test 1)
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml                       # on the SIEM VM
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml -e siem_artifacts_hosts=localhost \
  -e siem_artifacts_cache_dir=/var/tmp/siem-artifacts-check -K                         # before it exists
```

Every role that installs a SIEM component runs the same check (`roles/siem_artifacts`) for the artifacts it
needs, and installs only from the checked copy in `/var/cache/tuningfork/siem/`
(`C:\ProgramData\Tuningfork\siem\` on Windows).

### Updating a version

1. Change the version in `siem_versions.yml` and clear the old `sha256` of the changed entries.
2. Build the bundle and paste the new checksums.
3. Copy the new `siem/<product>/<version>/` directories to the mirror. Older versions can stay for rollback.
4. Run the playbook of that component.

**Wazuh:** upgrade the manager first, then the agents. Agents must never be newer than the manager.

---

## 3. Writing rules

Audit requirements are referred to by **title only**, everywhere: code, comments, rule descriptions,
documents and output. `scripts/check-no-requirement-ids.sh` fails if a requirement identifier in square
brackets appears in the repository (it is part of the lint checks in `README.md`).

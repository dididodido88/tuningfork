# pve_exporter

Installs prometheus-pve-exporter on the SIEM VM. It reads the Proxmox VE API with a read-only
token and serves the metrics (nodes, VMs, storage, quorum) to Prometheus. It is a Python program,
so it is installed into a virtualenv from a wheel bundle on the mirror, never from PyPI.

| | |
|---|---|
| Playbook | `playbooks/pve_exporter.yml` (also run by `playbooks/siem.yml`, before Prometheus) |
| Hosts | `siem_servers` (it also reads one file from the first host of `proxmox_hosts`) |
| Tag | `pve_exporter` |
| Needs first | `certificates`, `repositories` (Python from AppStream), the token from `proxmox_monitoring` |
| Set variables in | `group_vars/all/siem_versions.yml` (`pve_exporter_version`, `pve_exporter_python_version`, the wheel bundle), `group_vars/all/siem.yml`, the vault |
| Guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **Download**: `siem_artifacts` fetches the wheel bundle `pve_exporter_wheels` and checks its
   sha256. `siem_versions.yml` has the `pip download` command that builds the bundle on an internet
   machine.
2. **Python**: installs `python<pve_exporter_python_version>` (3.12) with dnf.
3. **Virtualenv**: unpacks the bundle and creates `/opt/pve-exporter/<version>`. Then runs
   `pip install --no-index --find-links` on the local wheels, so nothing is downloaded.
4. **Fix-ups the hardening needs**:
   - root's umask is 027 under CIS, so the role makes the virtualenv readable by the service user;
   - files under `/opt` are `usr_t`, so `/opt/pve-exporter/*/bin` is labelled `bin_t` and systemd
     may start the program.
5. **Trust**: copies the Proxmox cluster CA (`/etc/pve/pve-root-ca.pem`, read over SSH from the
   first Proxmox host) into the system trust store, so the exporter can check the Proxmox API
   certificates. The service uses the system bundle (`REQUESTS_CA_BUNDLE`).
6. **Token**: writes `/etc/pve-exporter/pve.yml` (0640, not logged). The file holds the user, the
   token name and `vault_pve_exporter_token_value`, or `not-set` while the vault value is empty.
7. **Service**: installs the hardened systemd unit and starts it on `127.0.0.1:9221`.

Prometheus only scrapes it once `vault_pve_exporter_token_value` is set (`prometheus_pve_enabled`).

A new version gets its own virtualenv folder, so an upgrade doesn't change the running one in
place.

## Variables

Required:

| Variable | Description |
|---|---|
| `pve_exporter_version`, `pve_exporter_python_version` | In `siem_versions.yml`, with the `pve_exporter_wheels` artifact. |
| `vault_pve_exporter_token_value` | The token secret `proxmox_monitoring` printed (vault). Until it is set, the exporter runs but Prometheus doesn't scrape it. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `pve_exporter_listen_address` | `127.0.0.1` | Listen address; Prometheus is on the same VM. |
| `pve_exporter_port` | `9221` | Port. |
| `pve_exporter_base_dir` | `/opt/pve-exporter` | One virtualenv per version below it. |
| `pve_exporter_api_user` | `siem_pve_api_user`, else `tuningfork-monitor@pve` | Proxmox user. |
| `pve_exporter_token_name` | `siem_pve_token_name`, else `prometheus` | Token name. |
| `pve_exporter_verify_ssl` | `true` | Check the Proxmox API certificate. |
| `pve_exporter_trust_cluster_ca` | `true` | Trust the Proxmox cluster CA (needed unless the nodes' certificates come from the internal CA). |
| `pve_exporter_user` | `pve-exporter` | Service account. |

Internal (`vars/main.yml`): `pve_exporter_venv` and `pve_exporter_wheel_dir`.

## Files on the host

| File | Content |
|---|---|
| `/opt/pve-exporter/<version>/` | Virtualenv |
| `/etc/pve-exporter/pve.yml` (0640) | API token (template `pve.yml.j2`) |
| `/etc/pki/ca-trust/source/anchors/proxmox-<env>-root-ca.pem` | Proxmox cluster CA |
| `/etc/systemd/system/pve_exporter.service` | Service unit (template `pve_exporter.service.j2`) |

## Checks

```sh
systemctl status pve_exporter
curl -s 'http://127.0.0.1:9221/pve?target=<proxmox host address>&cluster=1&node=0' | head
```

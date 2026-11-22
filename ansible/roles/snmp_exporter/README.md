# snmp_exporter

Installs Prometheus snmp_exporter on the SIEM VM. It polls the Dell iDRACs over SNMPv3 and turns
the answers into metrics for Prometheus, such as hardware status and the event and Lifecycle
logs. It uses the `dell` module from the release's own `snmp.yml`, unmodified. The SNMPv3
credentials go in a second configuration file.

| | |
|---|---|
| Playbook | `playbooks/snmp_exporter.yml` (also run by `playbooks/siem.yml`, before Prometheus) |
| Hosts | `siem_servers` |
| Tag | `snmp_exporter` |
| Needs first | `certificates`; the read-only SNMPv3 user on every iDRAC (iDRAC configuration) |
| Set variables in | `group_vars/all/siem.yml` (`siem_idrac_snmp_username`), the vault (both passwords), `siem_versions.yml` |
| Guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **Download and install**: `siem_artifacts` fetches the release tarball, checks its sha256 (key
   `snmp_exporter`) and installs `snmp_exporter` to `/usr/local/bin`.
2. **Module definitions**: copies the release's `snmp.yml` to `/etc/snmp_exporter/snmp.yml` as
   shipped.
3. **Credentials**: writes `/etc/snmp_exporter/auth.yml`, with the SNMPv3 user, authentication and
   privacy passwords (authPriv). It does this only when the user name and both vault passwords are
   set. Until then the exporter runs without credentials, and Prometheus doesn't poll the iDRACs.
4. **Service**: installs the systemd unit, which loads both files, and starts it on
   `127.0.0.1:9116`.

Prometheus calls it as `/snmp?module=dell&auth=idrac_v3&target=<iDRAC address>`, one target per
host of the `idrac` group (`roles/prometheus`, job `idrac`).

## Variables

Required, for the iDRACs to be polled:

| Variable | Where | Description |
|---|---|---|
| `siem_idrac_snmp_username` | `group_vars/all/siem.yml` | SNMPv3 user configured on every iDRAC. |
| `vault_snmp_idrac_auth_password` | vault | Its authentication password. |
| `vault_snmp_idrac_priv_password` | vault | Its privacy (encryption) password. |
| `snmp_exporter_version` and the `snmp_exporter` artifact | `siem_versions.yml` | Release and sha256. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `snmp_exporter_listen_address` | `127.0.0.1:9116` | Listen address; Prometheus is on the same VM. |
| `snmp_exporter_module` | `dell` | Module from `snmp.yml`. No task reads it today: the Prometheus `idrac` job names `dell` itself. |
| `snmp_exporter_auth_name` | `idrac_v3` | Name of the credential set; Prometheus passes it as `auth`. |
| `snmp_exporter_auth_protocol` | `SHA256` | Must match the iDRAC user. |
| `snmp_exporter_priv_protocol` | `AES` | Must match the iDRAC user. |
| `snmp_exporter_user` | `snmp_exporter` | Service account. |

Internal (`vars/main.yml`): `snmp_exporter_credentials_set`, true when the user and both passwords
are set.

## Files on the host

| File | Content |
|---|---|
| `/usr/local/bin/snmp_exporter` | Binary from the release tarball |
| `/etc/snmp_exporter/snmp.yml` | The release's module definitions |
| `/etc/snmp_exporter/auth.yml` (0640) | SNMPv3 credentials (template `auth.yml.j2`) |
| `/etc/systemd/system/snmp_exporter.service` | Service unit (template `snmp_exporter.service.j2`) |

## Checks

```sh
systemctl status snmp_exporter
curl -s 'http://127.0.0.1:9116/snmp?module=dell&auth=idrac_v3&target=<iDRAC address>' | head
```

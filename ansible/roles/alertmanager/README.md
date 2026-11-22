# alertmanager

Installs Prometheus Alertmanager on the SIEM VM. Prometheus sends its alerts to it, and it emails
them through the local Postfix relay. Email is best effort: if mail can't be delivered, the alerts
stay visible in Grafana and in Alertmanager.

| | |
|---|---|
| Playbook | `playbooks/alertmanager.yml` (also run by `playbooks/siem.yml`) |
| Hosts | `siem_servers` |
| Tag | `alertmanager` |
| Needs first | `certificates` (mirror trust), `postfix_relay` (for email). `siem.yml` runs it before Prometheus, which sends it the alerts. |
| Set variables in | `inventories/<ENV>/group_vars/all/siem.yml` (recipients), `siem_versions.yml` (version and checksum) |
| Guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **Download**: `siem_artifacts` fetches the release tarball from the mirror and checks it against
   the sha256 pinned in `siem_versions.yml` (key `alertmanager`).
2. **Install**: copies `alertmanager` and `amtool` to `/usr/local/bin` and restarts the service if
   the binaries changed.
3. **Configure**: creates the `alertmanager` system user, `/etc/alertmanager` and the data folder,
   and writes `/etc/alertmanager/alertmanager.yml`. `amtool check-config` validates that file
   before it is written. A configuration change reloads the service; it doesn't restart it.
4. **Service**: installs the systemd unit and starts it. Alertmanager listens on loopback only;
   Prometheus and Grafana are on the same VM.

**Routing.** All alerts go to one receiver:
- `email` when `alertmanager_email_to` has addresses, with resolved notifications too;
- `none` when the list is empty, so alerts appear on the dashboards only.

Alerts are grouped by `alertname` and `instance`. When a host is down (`TargetDown`), its other
alerts are muted.

## Variables

Required: `alertmanager_version` and the `alertmanager` artifact in
`inventories/<ENV>/group_vars/all/siem_versions.yml`.

Optional:

| Variable | Default | Description |
|---|---|---|
| `alertmanager_email_to` | `siem_mail_to` (`[]`) | Recipients. Set `siem_mail_to` in `group_vars/all/siem.yml`; empty means no email. |
| `alertmanager_email_from` | `siem_mail_from`, else `alertmanager@<env_domain>` | Sender address. |
| `alertmanager_smarthost` | `localhost:25` | Mail relay (the loopback Postfix from `postfix_relay`). |
| `alertmanager_listen_address` | `127.0.0.1:9093` | Address and port. Prometheus uses `prometheus_alertmanager` to reach it. |
| `alertmanager_data_dir` | `/var/lib/alertmanager` | Silences and notification state. |
| `alertmanager_group_by` | `[alertname, instance]` | Alerts with the same values go in one email. |
| `alertmanager_group_wait` | `30s` | Wait before the first email of a new group. |
| `alertmanager_group_interval` | `5m` | Wait before an email about new alerts in a group. |
| `alertmanager_repeat_interval` | `4h` | Re-send an alert that is still firing. |
| `alertmanager_user` | `alertmanager` | Service account. |

## Files on the host

| File | Content |
|---|---|
| `/usr/local/bin/alertmanager`, `amtool` | Binaries from the release tarball |
| `/etc/alertmanager/alertmanager.yml` (0640) | Routing, receivers, inhibition (template `alertmanager.yml.j2`) |
| `/etc/systemd/system/alertmanager.service` | Service unit (template `alertmanager.service.j2`) |
| `/var/lib/alertmanager` | Data |

## Checks

```sh
systemctl status alertmanager
amtool --alertmanager.url=http://127.0.0.1:9093 alert query      # alerts firing now
amtool check-config /etc/alertmanager/alertmanager.yml
```

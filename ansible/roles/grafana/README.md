# grafana

Installs Grafana OSS on the SIEM VM: HTTPS with the host certificate, Prometheus as its data
source, and dashboards provisioned from files. Nothing reaches the internet: update checks, news,
usage reporting, gravatar and plugin installs are turned off.

| | |
|---|---|
| Playbook | `playbooks/grafana.yml` (also run by `playbooks/siem.yml`, last) |
| Hosts | `siem_servers` |
| Tags | `grafana`; `firewall` on the firewall task |
| Needs first | `certificates` (host certificate and mirror trust), `prometheus`, `postfix_relay` (for email) |
| Set variables in | `inventories/<ENV>/group_vars/all/siem.yml` (`siem_server_name`, `siem_admin_networks`), `siem_versions.yml` (the RPM), the vault |
| Guide | [docs/siem.md](../../docs/siem.md) |

URL: `https://<siem_server_name>:3000/`. The user is `admin`, with the vault password.

## What it does

1. **Pre-check**: `vault_grafana_admin_password` must be at least 12 characters.
2. **Install**: `siem_artifacts` fetches the Grafana RPM from the mirror and checks its sha256
   (key `grafana_rpm`). dnf installs it without a GPG check, because Grafana's signing key isn't
   on the host; the pinned sha256 takes its place.
3. **Certificate**: copies the host certificate and key to `/etc/grafana/tls.crt` and `tls.key`,
   readable by the `grafana` group.
4. **grafana.ini**: sets the options listed in `vars/main.yml`:
   - HTTPS on `grafana_port`;
   - no sign-up, organisation creation or anonymous access;
   - analytics, news and plugin installs off;
   - SMTP through the local relay on `localhost:25`.
5. **Provisioning**:
   - the Prometheus data source, read-only and the default;
   - a file provider for the dashboard folder `grafana_dashboards_dir`. Dashboards appear in the
     Grafana folder "Tuningfork" and can't be edited in the UI.
6. **Firewall**: one rich rule per network in `grafana_admin_networks`, for port 3000.
7. **Admin password**: after Grafana answers on `/api/health`, logs in as `admin` with the vault
   password. If that fails (the first start, or the password was changed in the UI), it resets the
   password to the vault value with `grafana cli admin reset-admin-password`.

## Variables

Required:

| Variable | Description |
|---|---|
| `vault_grafana_admin_password` | Local `admin` password (vault, at least 12 characters). |
| `siem_server_name` | Name of the SIEM VM; the URL and the certificate use it (`group_vars/all/siem.yml`). |
| `grafana_rpm` artifact | Version and sha256 in `siem_versions.yml`. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `grafana_port` | `3000` | HTTPS port. |
| `grafana_domain` | `siem_server_name` | Name in the URL; the host certificate must cover it. |
| `grafana_certificate`, `grafana_key` | `/etc/pki/tls/certs/host.fullchain.crt`, `/etc/pki/tls/private/host.key` | Host certificate from the `certificates` role. |
| `grafana_prometheus_url` | `http://127.0.0.1:9090` | Data source. |
| `grafana_dashboards_dir` | `/var/lib/grafana/dashboards/tuningfork` | JSON dashboards provisioned from here. |
| `grafana_mail_from` | `siem_mail_from`, else `grafana@<env_domain>` | Sender of Grafana's emails. |
| `grafana_manage_firewall` | `true` | Open port 3000 to the admin networks. |
| `grafana_firewall_zone` | `rhel9cis_default_zone`, else `public` | firewalld zone. |
| `grafana_admin_networks` | `siem_admin_networks` | Networks allowed to reach Grafana. |

## Files on the host

| File | Content |
|---|---|
| `/etc/grafana/grafana.ini` | Settings above (edited in place, option by option) |
| `/etc/grafana/tls.crt`, `tls.key` (0640) | Copy of the host certificate |
| `/etc/grafana/provisioning/datasources/tuningfork.yaml` | Prometheus data source |
| `/etc/grafana/provisioning/dashboards/tuningfork.yaml` | Dashboard folder provider |

## Checks

```sh
systemctl status grafana-server
curl -s https://<siem_server_name>:3000/api/health
```

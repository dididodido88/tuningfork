# prometheus

Installs Prometheus on the SIEM VM. It scrapes every monitored host and exporter, keeps the time
series on the SIEM VM's data disk, evaluates the alert rules and sends alerts to the local
Alertmanager. Administrators look at the metrics through Grafana; Prometheus itself listens on
loopback only.

| | |
|---|---|
| Playbook | `playbooks/prometheus.yml` (also run by `playbooks/siem.yml`, after the exporters) |
| Hosts | `siem_servers` |
| Tag | `prometheus` |
| Needs first | `certificates` (mirror trust), the `/var/lib/prometheus` data disk (`filesystems`) |
| Set variables in | `inventories/<ENV>/group_vars/siem_servers.yml` (retention), `group_vars/all/siem_versions.yml` (version and checksum) |
| Guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **Download and install**: `siem_artifacts` fetches the release tarball from the mirror, checks
   its sha256 (key `prometheus`), and copies `prometheus` and `promtool` to `/usr/local/bin`. New
   binaries restart the service.
2. **Configure**: creates the `prometheus` system user, `/etc/prometheus`, `/etc/prometheus/rules`
   and the data folder. Writes two files, each checked with `promtool` before it is written:
   - the base alert rules, `rules/tuningfork.yml`;
   - the scrape configuration, `prometheus.yml`.

   A configuration change reloads Prometheus; it doesn't restart it.
3. **Service**: installs the systemd unit with the retention limits, and starts it.

**Scrape jobs**, built from the inventory on every run:

| Job | Targets | When |
|---|---|---|
| `prometheus`, `alertmanager` | Themselves, on loopback | Always |
| `node` | The SIEM VM on `127.0.0.1:9100`, and every host of `node_exporter_hosts` except `k8s_nodes` on `<ansible_host>:9100` | Always |
| `idrac` | Every host of `idrac`, through the local `snmp_exporter` (module `dell`, auth `idrac_v3`) | When the `idrac` group has hosts, `siem_idrac_snmp_username` is set and both SNMP passwords are in the vault |
| `pve-node`, `pve-cluster` | Each Proxmox host, then the cluster-wide metrics from the first one, through the local `pve_exporter` | When `proxmox_hosts` has hosts and `vault_pve_exporter_token_value` is set |

The conditions keep devices from showing as down before their access is configured. Every series
carries the label `environment: <env_name>`.

**Alert rules.** `TargetDown` fires (critical) when a target hasn't answered for 5 minutes. More
rules will come with the detection content (see [HANDOFF.md](../../../HANDOFF.md)).

## Variables

Required: `prometheus_version` and the `prometheus` artifact in `siem_versions.yml`.

Optional:

| Variable | Default | Description |
|---|---|---|
| `prometheus_listen_address` | `127.0.0.1:9090` | Listen address. Grafana uses `grafana_prometheus_url` to reach it. |
| `prometheus_data_dir` | `/var/lib/prometheus` | Time series database, on a data disk. |
| `prometheus_retention_time` | `90d` | Delete data older than this. |
| `prometheus_retention_size` | `30GB` | Delete the oldest data above this size. Keep it below the disk size. |
| `prometheus_scrape_interval` | `60s` | How often every target is scraped. |
| `prometheus_evaluation_interval` | `60s` | How often the rules are evaluated. |
| `prometheus_alertmanager` | `127.0.0.1:9093` | Alertmanager address. |
| `prometheus_user` | `prometheus` | Service account. |
| `prometheus_idrac_enabled` | computed (see the table above) | Scrape the iDRACs. |
| `prometheus_snmp_exporter` | `127.0.0.1:9116` | snmp_exporter address. |
| `prometheus_idrac_scrape_timeout` | `50s` | The `dell` module walks large tables. |
| `prometheus_pve_enabled` | computed (see the table above) | Scrape Proxmox. |
| `prometheus_pve_exporter` | `127.0.0.1:9221` | pve_exporter address. |

## Files on the host

| File | Content |
|---|---|
| `/usr/local/bin/prometheus`, `promtool` | Binaries from the release tarball |
| `/etc/prometheus/prometheus.yml` (0640) | Scrape jobs and Alertmanager (template `prometheus.yml.j2`) |
| `/etc/prometheus/rules/tuningfork.yml` (0640) | Base alert rules (template `rules.yml.j2`) |
| `/etc/systemd/system/prometheus.service` | Service unit with the retention flags (template `prometheus.service.j2`) |
| `/var/lib/prometheus` | Time series |

## Checks

```sh
systemctl status prometheus
curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | [.labels.job, .labels.instance, .health] | @tsv'
promtool check config /etc/prometheus/prometheus.yml
```

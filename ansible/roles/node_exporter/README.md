# node_exporter

Installs Prometheus node_exporter, which serves operating-system metrics (CPU, memory, disks,
network, systemd units) for Prometheus on the SIEM VM to scrape.

| | |
|---|---|
| Playbook | `playbooks/node_exporter.yml` (also run by `playbooks/siem_agents.yml`) |
| Hosts | `node_exporter_hosts` (the Rocky VMs and the Proxmox hosts), except `k8s_nodes` |
| Tags | `node_exporter`; `firewall` on the firewall task |
| Needs first | `certificates` on Rocky hosts (mirror trust) |
| Set variables in | `inventories/<ENV>/group_vars/all/siem_versions.yml` (version and checksum), `group_vars/all/siem.yml` (`siem_server_ip`) |
| Guide | [docs/siem.md](../../docs/siem.md) |

Kubernetes nodes are skipped because Rancher's own monitoring uses port 9100 there.

## What it does

1. **Download**: `siem_artifacts` fetches the release tarball from the mirror and checks its
   sha256 (key `node_exporter` in `siem_versions.yml`). On the Proxmox hosts (Debian 13) it uses
   curl, because `get_url` fails against Python 3.12 and later.
2. **Install**: copies `node_exporter` to `/usr/local/bin` and restarts the service if the binary
   changed.
3. **Configure**: creates the `node_exporter` system user and the textfile folder. Other roles drop
   `<name>.prom` files there, such as the Postfix queue size or a pending reboot.
4. **Service**: installs the systemd unit (hardened: `ProtectSystem=strict`, `NoNewPrivileges`)
   and starts it.
5. **Firewall** (Rocky hosts other than the SIEM VM): a firewalld rich rule lets only
   `siem_server_ip` reach port 9100. The Proxmox hosts have no firewalld, so
   `group_vars/proxmox_hosts.yml` sets `node_exporter_manage_firewall: false` there.

**Where it listens:**
- on the SIEM VM: `127.0.0.1`, because Prometheus scrapes it locally and no firewall rule is
  needed;
- everywhere else: every address, with the firewall limiting who can connect.

## Variables

Required: `node_exporter_version` and the `node_exporter` artifact in `siem_versions.yml`, and
`siem_server_ip` in `group_vars/all/siem.yml`, which is used for the firewall rule.

Optional:

| Variable | Default | Description |
|---|---|---|
| `node_exporter_listen_address` | `127.0.0.1` on the SIEM VM, else `0.0.0.0` | Listen address. |
| `node_exporter_port` | `9100` | Port. Prometheus' scrape jobs use the same port. |
| `node_exporter_extra_collectors` | `[systemd]` | Collectors enabled in addition to the defaults. |
| `node_exporter_textfile_dir` | `/var/lib/node_exporter/textfile` | Folder of `.prom` files written by other roles. |
| `node_exporter_user` | `node_exporter` | Service account. |
| `node_exporter_manage_firewall` | true unless it listens on loopback | Add the firewall rule. |
| `node_exporter_firewall_zone` | `rhel9cis_default_zone`, else `public` | firewalld zone. |
| `node_exporter_scrapers` | `[siem_server_ip]` | Addresses allowed to scrape. |

## Files on the host

| File | Content |
|---|---|
| `/usr/local/bin/node_exporter` | Binary from the release tarball |
| `/etc/systemd/system/node_exporter.service` | Service unit (template `node_exporter.service.j2`) |
| `/var/lib/node_exporter/textfile/` | Metrics written by other roles |

## Checks

```sh
systemctl status node_exporter
curl -s http://127.0.0.1:9100/metrics | head      # on the host itself
```

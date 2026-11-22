# proxmox_monitoring

Creates the Proxmox side of the monitoring: a read-only user with the `PVEAuditor` role and an
API token for it. `pve_exporter` on the SIEM VM uses that token to read the Proxmox API.

| | |
|---|---|
| Playbook | `playbooks/proxmox_monitoring.yml` (also run by `playbooks/siem_agents.yml`, first) |
| Hosts | `proxmox_hosts`; every task runs once, on the first host |
| Tag | `proxmox_monitoring` |
| Needs first | Nothing. Ansible reaches the Proxmox hosts as root over SSH (`ansible.cfg`), without become. |
| Set variables in | `inventories/<ENV>/group_vars/all/siem.yml` (`siem_pve_api_user`, `siem_pve_token_name`) |
| Guide | [docs/siem.md](../../docs/siem.md) |

The Proxmox cluster keeps users, permissions and tokens in `/etc/pve`, which every node shares.
That is why one host is enough.

## What it does

Each step reads the current state with `pveum ... --output-format json` first, and changes only
what is missing:

1. Creates the user `proxmox_monitoring_user`.
2. Gives it `proxmox_monitoring_role` (`PVEAuditor`, read-only) on `/`.
3. Creates the API token `proxmox_monitoring_token_name` with `--privsep 0`, so the token has
   exactly the user's read-only rights.
4. **Shows the token secret once.** Proxmox can't show it again. Save it as
   `vault_pve_exporter_token_value` with `ansible-vault edit inventories/<ENV>/group_vars/all/vault.yml`,
   then run `playbooks/pve_exporter.yml` and `playbooks/prometheus.yml`.
5. On later runs, if the token exists but the vault value is empty, prints a reminder.

**If the secret is lost**, remove the token and run the playbook again; it creates a new one:

```sh
pveum user token remove tuningfork-monitor@pve prometheus
```

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `proxmox_monitoring_user` | `siem_pve_api_user`, else `tuningfork-monitor@pve` | Proxmox user (realm `pve`). |
| `proxmox_monitoring_token_name` | `siem_pve_token_name`, else `prometheus` | Token name. |
| `proxmox_monitoring_role` | `PVEAuditor` | Proxmox role given on `/`. |

`pve_exporter` reads the same `siem_pve_*` values, so the two roles always agree.

## Checks

```sh
pveum user list | grep tuningfork-monitor
pveum acl list | grep tuningfork-monitor
pveum user token list tuningfork-monitor@pve
```

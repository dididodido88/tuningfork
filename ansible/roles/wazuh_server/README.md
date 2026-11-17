# wazuh_server

Installs the Wazuh central components on the SIEM VM: indexer, manager (with Filebeat) and
dashboard. It uses Wazuh's offline all-in-one installer with artifacts that were downloaded from
the internal mirror and checked first.

| | |
|---|---|
| Playbook | `playbooks/wazuh_server.yml` (also part of `playbooks/siem.yml`) |
| Hosts | `siem_servers` |
| Tags | `wazuh_server`, `firewall` |
| Needs first | `certificates` (host certificate covering `siem_server_name`), `repositories`, `filesystems` (the SIEM data disks) |
| Set variables in | `inventories/<ENV>/group_vars/siem_servers.yml` and `group_vars/all/siem.yml`, secrets in `group_vars/all/vault.yml` |
| Longer guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **Pre-checks**: the two vault passwords meet Wazuh's rules, the firewall networks are set, and
   the host certificate and key are in place. Installs the packages the installer expects.
2. **Artifacts**: calls the `siem_artifacts` role to download and check the installer script, the
   offline package bundle and the passwords tool.
3. **Install**: runs `wazuh-install.sh --offline-installation --all-in-one` once. A host that
   already has all three components at `wazuh_version` is left alone.
4. **Indexer**: sets the JVM heap.
5. **Passwords**: replaces the generated `admin` and API passwords with the ones from the vault,
   only when the vault password doesn't log in yet.
6. **Dashboard**: serves the host certificate (from the internal CA) instead of the installer's
   own, so browsers trust it.
7. **Firewall**: allows the dashboard from the admin networks, and agent connection (1514/tcp)
   and enrollment (1515/tcp) from the agent networks. The indexer (9200) and the API (55000)
   stay closed.
8. **Verifies**: the services run, the indexer cluster is healthy, and the dashboard answers
   with a trusted certificate.

## Variables

Required per environment:

| Variable | Where | Description |
|---|---|---|
| `siem_server_name` | `group_vars/all/siem.yml` | Name browsers and agents use for the SIEM VM. The host certificate must cover it. |
| `siem_admin_networks` | `group_vars/all/siem.yml` | Networks allowed to reach the dashboard. |
| `siem_agent_networks` | `group_vars/all/siem.yml` | Networks the Wazuh agents connect from. |
| `wazuh_version` | `group_vars/all/siem_versions.yml` | Wazuh version. Manager, indexer, dashboard and agents all use it. |
| `vault_wazuh_indexer_admin_password` | vault | Password of `admin`, the dashboard and indexer login. |
| `vault_wazuh_api_password` | vault | Password of `wazuh`, the server API administrator. |

Both passwords must be 8 to 64 characters from `A-Z a-z 0-9 . * + ? -`, with at least one
upper-case letter, one lower-case letter, one digit and one symbol.

Optional:

| Variable | Default | Description |
|---|---|---|
| `wazuh_server_indexer_heap` | `4g` | Indexer JVM heap, e.g. `4g` or `2048m`. At most half the RAM, as other services share the VM. |
| `wazuh_server_dashboard_port` | `443` | Port the dashboard listens on. |
| `wazuh_server_dashboard_certificate` | `/etc/pki/tls/certs/host.fullchain.crt` | Certificate served by the dashboard, from the `certificates` role. |
| `wazuh_server_dashboard_key` | `/etc/pki/tls/private/host.key` | Its private key. |
| `wazuh_server_manage_firewall` | `true` | Add the firewalld rules. |
| `wazuh_server_firewall_zone` | `{{ rhel9cis_default_zone }}` (else `public`) | firewalld zone the rules are added to. |
| `wazuh_server_admin_networks` | `{{ siem_admin_networks }}` | Networks allowed to reach the dashboard. |
| `wazuh_server_agent_networks` | `{{ siem_agent_networks }}` | Networks allowed to reach ports 1514 and 1515. |
| `wazuh_server_admin_password` | `{{ vault_wazuh_indexer_admin_password }}` | Set the vault value instead. |
| `wazuh_server_api_password` | `{{ vault_wazuh_api_password }}` | Set the vault value instead. |
| `wazuh_server_work_dir` | `/var/lib/tuningfork/wazuh` | Where the installer runs. It keeps `wazuh-install-files.tar` (Wazuh's internal certificates and the generated passwords), readable by root only. |
| `wazuh_server_install_timeout` | `3600` | Seconds the installation may take. |
| `wazuh_server_prerequisites` | tar, coreutils, curl, libcap, openssl, lsof, procps-ng, gnupg2 | Packages the offline installer expects. |
| `wazuh_server_artifacts` | `[wazuh_install_script, wazuh_offline, wazuh_passwords_tool]` | Keys of `siem_artifacts` this role needs. |

## Example

```yaml
# inventories/<ENV>/group_vars/all/siem.yml
siem_server_name: sentinel.lab.local
siem_agent_networks: [192.168.70.0/24]
siem_admin_networks: [192.168.70.0/24]

# inventories/<ENV>/group_vars/siem_servers.yml
wazuh_server_indexer_heap: 4g

# inventories/<ENV>/group_vars/all/vault.yml (encrypted)
vault_wazuh_indexer_admin_password: "<password>"
vault_wazuh_api_password: "<password>"
```

## Good to know

- **The installation runs once and is never overwritten.** A partial installation or another
  version stops the play, because the installer's overwrite option erases all Wazuh data. For an
  upgrade see "Updating a version" in the guide.
- The installer's output is hidden because it prints the generated admin password. The full log
  is `/var/log/wazuh-install.log` on the host, readable by root only.
- If someone changes the API password by hand, set `vault_wazuh_api_password` to the new value.
- After the play, log in to `https://<siem_server_name>/` as `admin` with
  `vault_wazuh_indexer_admin_password`.

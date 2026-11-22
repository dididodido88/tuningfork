# wazuh_agent_linux

Installs the Wazuh agent on Linux hosts: the Rocky 9 VMs (RPM) and the Proxmox hosts (DEB). The
agent reads the journal and the audit log, and sends them to the Wazuh manager on the SIEM VM over
its own encrypted connection (1514/tcp). It enrolls itself with the enrollment password.

| | |
|---|---|
| Playbook | `playbooks/wazuh_agent_linux.yml` (also run by `playbooks/siem_agents.yml`) |
| Hosts | `wazuh_agents`, except `siem_servers` (the SIEM VM is the manager) |
| Tag | `wazuh_agent` |
| Needs first | `certificates` on Rocky hosts; the Wazuh manager running (`playbooks/siem.yml`) |
| Set variables in | `group_vars/all/siem.yml` (`siem_server_ip`), `group_vars/all/siem_versions.yml` (`wazuh_version`, packages), the vault |
| Guide | [docs/siem.md](../../docs/siem.md) |

**One version.** `wazuh_version` drives both the manager and every agent. Wazuh requires an
agent to be the same version as the manager or older. If an agent on a host is newer than
`wazuh_version`, the play stops on that host: upgrade the manager first.

## What it does

1. **Pre-checks**:
   - the manager address and the enrollment password are set (8 characters or more);
   - the host isn't the SIEM VM;
   - the host doesn't have `wazuh-manager` installed;
   - any installed agent isn't newer than `wazuh_version` (Debian revisions such as `-1` are
     stripped before comparing).
2. **Download**: `siem_artifacts` fetches `wazuh_agent_rpm` or `wazuh_agent_deb` from the mirror
   and checks its sha256. On the Proxmox hosts it uses curl, because `get_url` fails against
   Python 3.12 and later.
3. **Install**, only if the agent is missing or older. dnf or apt installs the local package with
   the `WAZUH_MANAGER`, `WAZUH_REGISTRATION_PASSWORD`, `WAZUH_AGENT_GROUP` and `WAZUH_AGENT_NAME`
   variables, which the package reads on its first installation. An older agent is upgraded in
   place. The RPM is installed without a GPG check, because Wazuh's key isn't on the host; the
   pinned sha256 takes its place.
4. **Keep in line with the inventory**: those variables only apply once, so the role keeps two
   things in line on every run:
   - the `<address>` in `/var/ossec/etc/ossec.conf` stays set to the manager address;
   - `/var/ossec/etc/authd.pass` holds the enrollment password (0640, not logged).
5. **Start and verify**: starts `wazuh-agent`, applies pending restarts, then waits up to 3 minutes
   for `/var/ossec/var/run/wazuh-agentd.state` to report `connected`.

**Agent group.** Each agent joins a group on the manager, which holds its central configuration:
`proxmox` for the Proxmox hosts, `linux` for every other host.

## Variables

Required:

| Variable | Where | Description |
|---|---|---|
| `siem_server_ip` | `group_vars/all/siem.yml` | Manager address. An IP, so enrollment doesn't depend on DNS. |
| `vault_wazuh_enrollment_password` | vault | Enrollment password, the same one the manager has. |
| `wazuh_version`, `wazuh_agent_rpm`, `wazuh_agent_deb` | `siem_versions.yml` | Version and packages with their sha256. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `wazuh_agent_manager` | `siem_server_ip` | Manager address. |
| `wazuh_agent_name` | `inventory_hostname` | Agent name in Wazuh. |
| `wazuh_agent_group` | `proxmox` on `proxmox_hosts`, else `linux` | Agent group on the manager. |
| `wazuh_agent_enrollment_password` | `vault_wazuh_enrollment_password` | Enrollment password. |

Internal (`vars/main.yml`):
- `wazuh_agent_artifact`: the RPM or the DEB;
- `wazuh_agent_installed`: the installed version, without the Debian revision;
- `wazuh_agent_install_env`: the `WAZUH_*` variables.

## Files on the host

| File | Content |
|---|---|
| `/var/ossec/etc/ossec.conf` | Agent configuration from the package; only `<address>` is managed here |
| `/var/ossec/etc/authd.pass` (0640) | Enrollment password |

## Checks

```sh
systemctl status wazuh-agent
cat /var/ossec/var/run/wazuh-agentd.state | grep status
/var/ossec/bin/agent_control -l        # on the SIEM VM: every agent and its status
```

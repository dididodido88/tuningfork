# tuningfork

Ansible configuration for Rocky Linux 9, Windows Server and Windows 11 Desktop, across the
**CRGS00**, **CRGS01** and **CRGS02** environments. Built for air-gapped networks: every role
and collection it needs is vendored in this repository.

## Layers

Each host gets three layers, applied in this order by `playbooks/site.yml`:

| Layer | What | Applies to | Playbook | Role(s) |
|---|---|---|---|---|
| 1. Hardening | CIS RHEL 9 benchmark (ansible-lockdown) | `rocky9` | `cis_rhel9.yml` | `RHEL9-CIS` (vendored) |
| 2. Common OS | Settings every host of an OS family gets | `linux`, `windows`, `windows_server`, `windows_desktop` | `linux_common.yml`, `windows_common.yml` | `linux_common`, `windows_common`, `windows_server_common`, `windows_desktop_common` |
| 3. Server role | What the host is for | `nfs_servers`, `db_servers`, `nexus_servers` | `nfs_server.yml`, `database_server.yml`, `nexus_server.yml` | `nfs_server`, `database_server`, `nexus_server` |

Membership in an inventory group decides what runs; roles don't check the OS themselves.

### Common Linux configuration (`linux_common`)

| Area | Result | Main variables |
|---|---|---|
| NTP | chrony with the environment's NTP servers | `linux_common_ntp_servers` |
| Banner | `/etc/motd`, `/etc/issue`, `/etc/issue.net` | `linux_common_banner_text` |
| IPv6 | Enabled or disabled through `/etc/sysctl.d/70-tuningfork-ipv6.conf` | `linux_common_ipv6_enabled` |
| journald | Persistent logs across reboots; retention period and size limits | `linux_common_journald_storage`, `linux_common_journald_max_retention` |

Each area has an on/off switch (`linux_common_<area>_enabled`; for IPv6, `linux_common_ipv6_manage`).

### How CIS and `linux_common` share settings

The CIS role also configures chrony, banners, IPv6 and journald. To stop the two roles
overwriting each other, `playbooks/group_vars/rocky9.yml`:

- turns off CIS rules 2.3.2 (chrony config), 1.7.1–1.7.3 (banner text), 3.1.1 (IPv6 disable)
  and 6.2.1.3 (journald rotation) **while the matching `linux_common` area is enabled**, and
- sets the CIS variables that are still used (the time server list, banner text, whether IPv6 is
  required) from the `linux_common_*` values.

So each setting has one source: `inventories/<ENV>/group_vars/linux.yml`. If you disable a
`linux_common` area, CIS manages it again.

### CIS lockout safeguards

Several CIS rules can cut off SSH, sudo or console login. The CIS play
(`playbooks/cis_rhel9.yml`) protects access in three ways:

1. **Pre-checks** (`roles/cis_safeguards/tasks/preflight.yml`) run before CIS. They fix what's
   needed and **stop the host** if a risk remains.
2. **Post-checks** (`verify.yml`) run after CIS and its handlers (sshd restart, crypto policy).
   They drop the SSH connection, open a new one and run sudo.
3. **Staged rollout**: 1 host, then 25%, then the rest (`serial`). With
   `max_fail_percentage: 0`, any failure stops the remaining hosts.

| Risk | CIS rule | Protection |
|---|---|---|
| SSH limited to the Ansible account only (role default `AllowUsers <ansible user>`) | 5.1.7 | `AllowUsers` cleared. Access is controlled by `AllowGroups` = `cis_safeguards_ssh_allow_groups`. The Ansible account is added to `sshusers`. The pre-check **stops** if a local interactive user is in none of the allowed groups. |
| Leftover `AllowUsers` line (sshd then requires both lists) | 5.1.7 | Removed from `sshd_config`. The post-check confirms it's gone. |
| Root SSH disabled while Ansible connects as root | 5.1.20 | The pre-check stops if `ansible_user` is root. |
| `NOPASSWD` sudo changed to `PASSWD`, so `become` fails | 5.2.4 | The Ansible account gets `/etc/sudoers.d/90-<account>`, which is excluded from the change. |
| Automation account password expires, then is locked by the inactive lock | 5.4.1.x | The pre-check stops if the Ansible account's password can expire. New ageing limits aren't forced on existing accounts. |
| Firewall started without SSH allowed | 4.1.2 | The SSH port is added to the default zone before CIS starts firewalld. |
| Strict reverse-path filter drops traffic on multi-homed hosts | 3.3.7 | The pre-check stops on hosts with more than one IPv4 interface unless `cis_safeguards_strict_rp_filter_confirmed: true`. |
| IPv6 disabled on a host managed over IPv6 | linux_common / 3.x | `linux_common` and the pre-check stop if the host is reached over IPv6 or has no IPv4 default route. |
| SELinux goes from disabled to enforcing without relabelling, and logins fail after reboot | 1.3.1.x | That run sets permissive and schedules `/.autorelabel` instead. Reboot, then run CIS again to set enforcing. |
| PAM profile replaced, dropping features or overwriting unmanaged PAM | 5.3.2.x | Only runs when `rhel9cis_disruption_high: true` (off in every environment). If you turn it on, the pre-check stops hosts whose profile isn't plain `sssd`/`local`. |
| Root locked out at the console after failed logins | 5.3.3.1.3 | Root unlocks automatically after `rhel9cis_root_unlock_time` (60 s). |
| Host halts when the audit log disk fills | 6.3.2.3 / 6.3.2.4 | Audit logging is suspended and the event logged instead (`inventories/<ENV>/group_vars/rocky9.yml`). **This doesn't meet those two CIS controls.** Set `halt`/`single` if strict compliance matters more than uptime. |
| GRUB password blocks console recovery | 1.4.1 | Stays off. |
| Risky changes (`rhel9cis_disruption_high`) | many | Off in every environment. |

Settings CIS still applies that change how people log in (not lockouts, but plan for them):

- `DisableForwarding yes` (5.1.10): no port or agent forwarding, so a host can't be used as an SSH
  jump host. Set `rhel9cis_rule_5_1_10: false` in host_vars for jump hosts.
- `GSSAPIAuthentication no` (5.1.11): no Kerberos single sign-on over SSH. Keys and passwords still work.
- `MaxAuthTries 4` (5.1.16): clients that try many keys fail. Use `IdentitiesOnly yes` client-side.
- Crypto policy `NO-SHA1`, no CBC, no chacha20, no EtM for SSH (1.6.x): very old SSH clients can't connect.
- `su` restricted to the empty `sugroup` (5.2.7): use `sudo` instead.
- Idle shell timeout of 15 minutes (`TMOUT`, 5.4.3.2).
- Removing X11 server packages (2.1.x) ends graphical login on any host that has one.
- When IPv6 stays enabled, router advertisements are ignored (3.3.11). Hosts that get their IPv6
  address from SLAAC lose it.

**Keep console access** (hypervisor or out-of-band) to every host before the first CIS run: it's
the recovery path if something still goes wrong. CIS backs up the PAM profile before it changes it
(`authselect backup-list`).

## Layout

```
ansible.cfg                  roles_path, vendored collections_path, no default inventory
requirements.yml             record of vendored versions (used only to refresh them)
collections/                 VENDORED collections
roles/
  RHEL9-CIS/                 VENDORED ansible-lockdown role (see VENDORED.md)
  cis_safeguards/            pre-checks and post-checks around CIS (lockout protection)
  linux_common/              all Linux
  windows_common/            all Windows
  windows_server_common/     Windows Server only
  windows_desktop_common/    Windows 11 Desktop only
  nfs_server/  database_server/  nexus_server/
playbooks/
  site.yml                   runs everything in layer order
  group_vars/                settings that apply to every environment (see below)
  *.yml                      one playbook per layer / server role
inventories/
  CRGS00/ CRGS01/ CRGS02/    hosts.yml, group_vars/, host_vars/
```

## Variables

Where to put a value, from lowest to highest precedence:

| Location | Use for |
|---|---|
| `roles/<role>/defaults/main.yml` | Org-wide defaults. Every option the role has is listed here. |
| `inventories/<ENV>/group_vars/all/main.yml` | Values shared across groups in one environment: `env_ntp_servers`, `env_banner_text`, `env_mirror_base_url`. |
| `inventories/<ENV>/group_vars/<group>.yml` | Environment-specific settings for a group. |
| `inventories/<ENV>/group_vars/all/vault.yml` | Secrets (ansible-vault encrypted). |
| `inventories/<ENV>/host_vars/<host>.yml` | Per-host exceptions. |
| `playbooks/group_vars/<group>.yml` | Rules that must hold in **every** environment (the CIS ↔ `linux_common` handover, the CIS exceptions NFS servers need). Overrides inventory group_vars, so keep it small. |

Define the `linux_common_*` settings in `inventories/<ENV>/group_vars/linux.yml`, not only in
role defaults: the CIS play reads them and doesn't load the `linux_common` role.

## Control node requirements

- ansible-core 2.14 (Rocky 9 AppStream: `dnf install ansible-core`)
- For Windows hosts: Python `pywinrm` (plus `pykerberos`/`requests-kerberos` if you use Kerberos)
- Network access to the hosts: SSH (22) for Linux, WinRM HTTPS (5986) for Windows
- Nothing from the internet: the collections and the CIS role are in this repository.

## Running

Always run from the repository root (so `ansible.cfg` is used) and name the environment:

```sh
# Full run
ansible-playbook -i inventories/CRGS00 playbooks/site.yml --vault-id CRGS00@prompt

# One layer or role
ansible-playbook -i inventories/CRGS00 playbooks/linux_common.yml
ansible-playbook -i inventories/CRGS00 playbooks/site.yml --tags journald

# Only some hosts
ansible-playbook -i inventories/CRGS01 playbooks/site.yml --limit nfs_servers
```

Useful tags: `cis`, `linux_common`, `ntp`, `banner`, `ipv6`, `journald`, `windows_common`,
`nfs_server`, `database_server`, `nexus_server`, `firewall`. The CIS role also has a tag per rule
(e.g. `rule_5.1.1`) and per level (`level1-server`).

### Secrets

Each environment has `group_vars/all/vault.yml` with placeholder values. Fill it in and encrypt it
before committing:

```sh
ansible-vault encrypt --vault-id CRGS00@prompt inventories/CRGS00/group_vars/all/vault.yml
```

## Verification checklist (on the air-gapped control node)

These checks haven't been run yet. Run them on the control node:

1. `ansible-lint` and `yamllint .` (vendored content is excluded).
2. `ansible-inventory -i inventories/CRGS00 --graph` for each environment: check the group tree.
   `ansible-inventory -i inventories/CRGS00 --host <host>` shows the resolved variables.
3. `ansible-playbook -i inventories/CRGS00 playbooks/site.yml --syntax-check`
4. Connectivity: `ansible linux -i inventories/CRGS00 -m ping` and
   `ansible windows -i inventories/CRGS00 -m ansible.windows.win_ping`.
5. On a test host, `--check --diff` first, then a real run. Keep a console open to that host.
   While CIS runs, keep a second SSH session open, then log in from a third as a normal
   admin user and as the Ansible account.
6. Run again: the second run should report `changed=0` (except tasks that always run, such as CIS audit commands).
7. On a Rocky host: `chronyc sources`, `cat /etc/issue`, `sysctl net.ipv6.conf.all.disable_ipv6`,
   `systemd-analyze cat-config systemd/journald.conf`, and after a reboot `journalctl --list-boots`
   shows more than one boot.

## Adding things

**A new server role** (e.g. a web server):

1. `roles/<name>/` with `defaults/main.yml`, `tasks/main.yml`, `meta/main.yml`.
2. A group (e.g. `web_servers`) in every environment's `hosts.yml`, plus
   `inventories/<ENV>/group_vars/web_servers.yml`.
3. `playbooks/<name>.yml` targeting that group, imported from `playbooks/site.yml`.
4. If CIS would remove or mask something the role needs, set that exception in
   `playbooks/group_vars/<group>.yml` (see `nfs_servers.yml`).

**A new environment**: copy an existing `inventories/CRGSxx` directory, replace the environment
name, hosts and values, and create a new vault for it.

**A new common task**: add a task file to the right common role, import it from that role's
`tasks/main.yml` with an `<area>_enabled` switch and a tag, and add its defaults. If CIS also
manages that area, add the handover to `playbooks/group_vars/rocky9.yml`.

## Updating vendored content

On an internet-connected machine:

- **Collections**: edit the versions in `requirements.yml`, then
  `rm -rf collections/ansible_collections && ansible-galaxy collection install -r requirements.yml -p collections`.
  Each version must support ansible-core 2.14 (see `requires_ansible` in the collection's `meta/runtime.yml`).
- **CIS role**: follow `roles/RHEL9-CIS/VENDORED.md`.

Commit the result and carry the repository into the air-gapped network.

## Vendored versions

| Content | Version | Note |
|---|---|---|
| RHEL9-CIS | 2.2.0 | Last release supporting ansible-core < 2.16; CIS benchmark v2.0.0 |
| ansible.posix | 1.6.1 | |
| community.general | 9.5.13 | |
| community.crypto | 2.26.9 | |
| ansible.windows | 2.4.0 | |
| community.windows | 2.2.0 | |

The collections' own `tests/` directories were removed (they aren't needed to run and contain
symlinks that break on Windows checkouts).

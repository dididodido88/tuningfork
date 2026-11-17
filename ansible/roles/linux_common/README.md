# linux_common

Settings every Linux host gets: time synchronisation, login banners, IPv6 on or off, and journald
retention. Each area can be switched off on its own.

| | |
|---|---|
| Playbook | `playbooks/linux_common.yml` (after CIS in `site.yml`) |
| Hosts | `linux` |
| Tags | `linux_common`, and one per area: `ntp`, `banner`, `ipv6`, `journald` |
| Set variables in | `inventories/<ENV>/group_vars/linux.yml` |

## What it does

| Area | Switch | Result |
|---|---|---|
| NTP | `linux_common_ntp_enabled` | Installs chrony, writes `/etc/chrony.conf` with the environment's servers, starts `chronyd`. |
| Banner | `linux_common_banner_enabled` | Writes `/etc/motd`, `/etc/issue` and `/etc/issue.net`. |
| IPv6 | `linux_common_ipv6_manage` | Sets the `disable_ipv6` sysctls in `/etc/sysctl.d/70-tuningfork-ipv6.conf`. Stops instead if IPv6 would be disabled on a host that is managed over IPv6. |
| journald | `linux_common_journald_enabled` | Creates `/var/log/journal` and writes a drop-in with storage, retention and size limits. |

## How it shares settings with CIS

The CIS role also configures chrony, banners, IPv6 and journald. While an area is enabled here,
`playbooks/group_vars/rocky9.yml` turns the matching CIS rule off and feeds the CIS role the
values from this role, so each setting has one source. If you disable an area here, CIS manages
it again.

**Set the `linux_common_*` values in `inventories/<ENV>/group_vars/linux.yml`, not only in the
role defaults.** The CIS play reads them and doesn't load this role's defaults.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `linux_common_ntp_servers` | `[]` | NTP servers (host names or IP addresses). Must not be empty while NTP is enabled. The inventories set it from `env_ntp_servers`. |

NTP:

| Variable | Default | Description |
|---|---|---|
| `linux_common_ntp_enabled` | `true` | Manage chrony. |
| `linux_common_ntp_server_options` | `iburst` | Options added to every `server` line. |
| `linux_common_ntp_makestep` | `"1.0 3"` | chrony `makestep`: step the clock if it is off by more than 1 second, in the first 3 updates. |
| `linux_common_ntp_minsources` | `1` | Sources needed before the clock is updated. |
| `linux_common_ntp_rtcsync` | `true` | Keep the hardware clock in sync. |
| `linux_common_ntp_package` | `chrony` | Package name. |
| `linux_common_ntp_service` | `chronyd` | Service name. |
| `linux_common_ntp_config_path` | `/etc/chrony.conf` | Configuration file. |

Banner:

| Variable | Default | Description |
|---|---|---|
| `linux_common_banner_enabled` | `true` | Manage the banner files. |
| `linux_common_banner_text` | `Authorized users only. All activity may be monitored and reported.` | Text of `/etc/issue` and `/etc/issue.net`. Keep OS details (`\m \r \s \v`) out: CIS checks for them. The inventories set it from `env_banner_text`. |
| `linux_common_banner_motd_text` | same as `linux_common_banner_text` | Text of `/etc/motd`. |

IPv6:

| Variable | Default | Description |
|---|---|---|
| `linux_common_ipv6_manage` | `true` | Manage the IPv6 sysctls. This is the on/off switch for the area. |
| `linux_common_ipv6_enabled` | `false` | `true` keeps IPv6 enabled, `false` disables it. |
| `linux_common_ipv6_sysctl_file` | `/etc/sysctl.d/70-tuningfork-ipv6.conf` | File the sysctls are written to. |

journald:

| Variable | Default | Description |
|---|---|---|
| `linux_common_journald_enabled` | `true` | Manage journald. |
| `linux_common_journald_storage` | `persistent` | `persistent` keeps logs in `/var/log/journal` across reboots. Also `volatile`, `auto`, `none`. |
| `linux_common_journald_compress` | `true` | Compress journal files. |
| `linux_common_journald_max_retention` | `90day` | Entries older than this are deleted (`MaxRetentionSec`). |
| `linux_common_journald_max_file_sec` | `1month` | Time one journal file covers before it is rotated (`MaxFileSec`). |
| `linux_common_journald_system_max_use` | `2G` | Disk space the journal may use. |
| `linux_common_journald_system_keep_free` | `1G` | Disk space the journal leaves free. |
| `linux_common_journald_runtime_max_use` | `128M` | Space the in-memory journal may use. |
| `linux_common_journald_dropin` | `/etc/systemd/journald.conf.d/zz-tuningfork.conf` | Drop-in file. Named `zz-` so it is read after the CIS drop-ins and its values win. |

`meta/argument_specs.yml` declares the type of each variable. Ansible checks them when the role
starts, so a wrong type fails early with a clear message.

## Example

```yaml
# inventories/<ENV>/group_vars/linux.yml
linux_common_ntp_servers: "{{ env_ntp_servers }}"
linux_common_banner_text: "{{ env_banner_text }}"
linux_common_ipv6_enabled: false
linux_common_journald_max_retention: 90day
```

Run one area only:

```sh
ansible-playbook -i inventories/<ENV> playbooks/linux_common.yml --tags journald
```

## Adding an area

Add a task file, import it from `tasks/main.yml` with a `linux_common_<area>_enabled` switch and
a tag, add its defaults and its entries in `meta/argument_specs.yml`. If CIS also manages that
area, add the handover to `playbooks/group_vars/rocky9.yml`.

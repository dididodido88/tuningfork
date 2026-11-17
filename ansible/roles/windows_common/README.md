# windows_common

Settings every Windows host gets, Server and Desktop: time synchronisation and the logon banner.
Each area can be switched off on its own.

| | |
|---|---|
| Playbook | `playbooks/windows_common.yml` (first play) |
| Hosts | `windows` |
| Tags | `windows_common`, and one per area: `ntp`, `banner` |
| Needs first | WinRM access to the hosts (connection settings in `group_vars/windows.yml`) |
| Set variables in | `inventories/<ENV>/group_vars/windows.yml` |

## What it does

| Area | Switch | Result |
|---|---|---|
| Time | `windows_common_ntp_enabled` | Sets W32Time to manual NTP peers (`Type` and `NtpServer` in the registry), starts the service and resyncs when the peers change. |
| Banner | `windows_common_banner_enabled` | Sets the legal notice caption and text shown before sign-in. |

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `windows_common_ntp_servers` | `[]` | NTP servers. Must not be empty while time is managed. The inventories set it from `env_ntp_servers`. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `windows_common_ntp_enabled` | `true` | Manage W32Time. Set it to false where Group Policy or the domain hierarchy already manages time. |
| `windows_common_ntp_flags` | `"0x8"` | Flag added to every peer. `0x8` is client mode, `0x1` uses the special poll interval. |
| `windows_common_banner_enabled` | `true` | Manage the logon banner. |
| `windows_common_banner_caption` | `Authorized use only` | Title of the legal notice. |
| `windows_common_banner_text` | `Authorized users only. All activity may be monitored and reported.` | Text of the legal notice. The inventories set it from `env_banner_text`. |

## Example

```yaml
# inventories/<ENV>/group_vars/windows.yml
windows_common_ntp_servers: "{{ env_ntp_servers }}"
windows_common_banner_text: "{{ env_banner_text }}"

# Domain members that sync time from the domain hierarchy
windows_common_ntp_enabled: false
```

## Related roles

`windows_server_common` and `windows_desktop_common` run after this role, on the
`windows_server` and `windows_desktop` groups. Put a setting here if every Windows host needs
it, and in one of those roles if only servers or only desktops do.

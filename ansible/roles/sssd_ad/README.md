# sssd_ad

Joins a Rocky 9 host to Active Directory and configures sssd, so AD users can log in next to the
local accounts. AD users get a home directory on first login. SSH and sudo access are decided by
AD group membership.

| | |
|---|---|
| Playbook | `playbooks/sssd_ad.yml` (after `linux_common` in `site.yml`, so the clock is right before the Kerberos join) |
| Hosts | `rocky9` |
| Tag | `sssd_ad` |
| Needs first | `repositories`, `linux_common` (NTP), and the AD-side setup |
| Set variables in | `inventories/<ENV>/group_vars/linux.yml`, join password in `group_vars/all/vault.yml` |
| Longer guide | [docs/active-directory.md](../../docs/active-directory.md): join account, OU, groups, UID/GID plan, troubleshooting |

The role is **off by default** (`sssd_ad_enabled: false`), so environments without AD settings
are skipped.

## What it does

1. **Pre-checks** (nothing is changed until they pass): the settings are set, the short host name
   is 15 characters or fewer, the domain controllers resolve in DNS, and the clock offset is
   within `sssd_ad_max_clock_offset`.
2. Installs sssd, adcli and the Kerberos tools, and writes `/etc/krb5.conf.d/tuningfork-ad.conf`.
3. **Joins the domain** with `adcli join`, unless the host is already joined.
4. Writes `/etc/sssd/sssd.conf`: POSIX IDs come from `uidNumber` and `gidNumber` in AD, short
   user names, and only members of the allowed AD groups may log in.
5. Turns on automatic home directories (authselect `with-mkhomedir` and oddjobd) and checks that
   PAM and NSS use sssd.
6. Writes `/etc/ssh/sshd_config.d/40-sssd-ad.conf` so AD users can log in with their password.
7. Writes `/etc/sudoers.d/50-ad-admins` for the admin groups.
8. **Verifies**: sssd is online, the AD groups resolve, sshd accepts password logins, and
   (optionally) a test user resolves and may log in over SSH.

## Variables

Required per environment (when `sssd_ad_enabled` is true):

| Variable | Default | Description |
|---|---|---|
| `sssd_ad_enabled` | `false` | Turn the role on for this environment. |
| `sssd_ad_domain` | `""` | AD DNS domain, e.g. `lab.local`. |
| `sssd_ad_join_user` | `""` | AD account allowed to create computer objects in the OU. |
| `vault_sssd_ad_join_password` | | Password of the join account, in the vault. |
| `sssd_ad_ssh_groups` | `[linux-ssh-users]` | AD groups whose members may log in (SSH and console). |
| `sssd_ad_admin_groups` | `[linux-admins]` | AD groups whose members may log in and use sudo for all commands, with their AD password. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `sssd_ad_realm` | `sssd_ad_domain` in upper case | Kerberos realm. |
| `sssd_ad_servers` | `[]` | Domain controllers to use, in order of preference. Empty: find them through DNS SRV records. |
| `sssd_ad_computer_ou` | `""` | OU the computer object is created in. Empty: the domain's default Computers container. |
| `sssd_ad_extra_ssh_groups` | `[]` | More SSH groups for a subset of hosts, set in that group's group_vars (for example the Kubernetes bastions). |
| `sssd_ad_sudoers_nopasswd` | `false` | Let the admin groups use sudo without a password. Keep it false: CIS removes `NOPASSWD` unless the groups are also excluded there. |
| `sssd_ad_min_id` | `1000000` | Only AD users and groups with a `uidNumber` or `gidNumber` at or above this are visible. |
| `sssd_ad_homedir` | `/home/%u` | Home directory of AD users. |
| `sssd_ad_shell` | `/bin/bash` | Shell used when AD sets none. |
| `sssd_ad_cache_credentials` | `true` | Let users who logged in before log in while no domain controller is reachable. |
| `sssd_ad_ssh_password_auth` | `true` | Allow password and keyboard-interactive logins in sshd. |
| `sssd_ad_max_clock_offset` | `60` | Largest clock offset in seconds before the join is refused. Kerberos fails beyond 5 minutes. |
| `sssd_ad_packages` | sssd, sssd-ad, sssd-tools, adcli, krb5-workstation, oddjob-mkhomedir, authselect | Packages to install. |
| `sssd_ad_test_user` | `""` | AD user (short name) for an end-to-end check: it must resolve and pass the PAM account check for sshd. No password is needed. |

## Example

```yaml
# inventories/<ENV>/group_vars/linux.yml
sssd_ad_enabled: true
sssd_ad_domain: lab.local
sssd_ad_servers: [dc1.lab.local, dc2.lab.local]
sssd_ad_join_user: svc_sssd
sssd_ad_computer_ou: OU=Servers,OU=Lab,DC=lab,DC=local
sssd_ad_ssh_groups: [sg-all-users]
sssd_ad_admin_groups: [sg-lab-admins]

# inventories/<ENV>/group_vars/all/vault.yml (encrypted)
vault_sssd_ad_join_password: "<password>"
```

Check a real user end to end, once:

```sh
ansible-playbook -i inventories/lab playbooks/sssd_ad.yml -e sssd_ad_test_user=jdoe
```

## Good to know

- **Run `cis_rhel9.yml` after turning AD on or changing the groups.** The AD groups are added to
  sshd `AllowGroups` through `cis_safeguards_ssh_allow_groups`, and that is applied by the CIS
  play. Until then AD users resolve but sshd refuses them.
- AD groups need a `gidNumber` and users a `uidNumber` at or above `sssd_ad_min_id`, or they
  aren't visible on the host.
- Local accounts are not affected: they log in as before, and win a name clash with an AD user.

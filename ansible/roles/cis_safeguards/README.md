# cis_safeguards

Checks that run before and after the vendored `RHEL9-CIS` role, so applying the CIS benchmark
can't cut off SSH, sudo or console login. The pre-checks fix what is needed to keep access and
stop the host if a lockout risk remains. The post-checks prove a new SSH login and sudo still work.

| | |
|---|---|
| Playbook | `playbooks/cis_rhel9.yml` (pre-tasks and post-tasks around `RHEL9-CIS`) |
| Hosts | `rocky9` |
| Tag | `always` (the checks run whichever tags you select) |
| Set variables in | `inventories/<ENV>/group_vars/rocky9.yml` |
| Background | [ansible/README.md](../../README.md), "CIS lockout safeguards" |

This role has no `tasks/main.yml`. It has two entry points, used with `tasks_from`:

```yaml
pre_tasks:
  - name: CIS lockout pre-checks
    ansible.builtin.import_role:
      name: cis_safeguards
      tasks_from: preflight
    tags: [always]
post_tasks:
  - name: CIS lockout post-checks
    ansible.builtin.import_role:
      name: cis_safeguards
      tasks_from: verify
    tags: [always]
```

It reads `rhel9cis_*` settings, so it must run in the same play as `RHEL9-CIS`.

## What the pre-checks do (`preflight`)

| Area | Action |
|---|---|
| Connection account | Stops if Ansible connects as root (CIS sets `PermitRootLogin no`). |
| SSH access groups | Creates `cis_safeguards_ssh_group`, adds the Ansible account to it, and stops if the account is in none of `cis_safeguards_ssh_allow_groups`. |
| Other local users | Stops if a local interactive user (UID 1000 or higher, with a login shell) is in none of the allowed groups, unless listed in `cis_safeguards_ssh_user_exceptions`. |
| `AllowUsers` | Removes any `AllowUsers` line from `/etc/ssh/sshd_config`. Access is controlled by `AllowGroups` only. |
| sudo | Writes `/etc/sudoers.d/90-<account>` with `NOPASSWD`, which CIS leaves alone. |
| Password expiry | Stops if the Ansible account's password can expire. |
| Firewall | Installs firewalld and allows the SSH port in the default zone before CIS starts the firewall. |
| Reverse-path filter | Stops on hosts with more than one IPv4 interface until you confirm routing is symmetric. |
| IPv6 | Stops if IPv6 is about to be disabled on a host that is managed over IPv6. |
| SELinux | If SELinux is disabled, sets permissive for this run and schedules a relabel on next boot. |
| authselect | When `rhel9cis_disruption_high` is true, stops hosts whose PAM profile can't be replaced safely. |

## What the post-checks do (`verify`)

1. `sshd -t` passes and the effective sshd settings have no `AllowUsers`.
2. Drops the SSH connection, opens a new one and runs a command with sudo.
3. Every data-disk entry in `/etc/fstab` (from `filesystems_volumes__*`) still uses `UUID=`.

A failure stops the play, so later hosts in the staged rollout aren't touched.

## Variables

Set per environment:

| Variable | Default | Description |
|---|---|---|
| `cis_safeguards_ssh_allow_groups` | `[sshusers, wheel]` | Groups allowed to log in over SSH (sshd `AllowGroups`). The inventories add the AD groups when `sssd_ad_enabled` is true. |
| `cis_safeguards_ssh_group` | `sshusers` | Local group the Ansible account is added to. Must be in the list above. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `cis_safeguards_account` | `{{ ansible_user }}` (else `ansible`) | Account Ansible connects as. Must not be root. |
| `cis_safeguards_ssh_port` | `{{ ansible_port }}` (else `22`) | SSH port opened in the firewall. |
| `cis_safeguards_fail_on_unlisted_ssh_users` | `true` | Stop if a local interactive user would lose SSH access. |
| `cis_safeguards_ssh_user_exceptions` | `[]` | Local users that are meant to lose SSH access. |
| `cis_safeguards_manage_sudoers` | `true` | Write the `NOPASSWD` sudoers drop-in for the Ansible account. |
| `cis_safeguards_fail_on_expiring_account` | `true` | Stop if the Ansible account's password can expire. |
| `cis_safeguards_manage_firewall_ssh` | `true` | Allow SSH in firewalld before CIS turns the firewall on. |
| `cis_safeguards_strict_rp_filter_confirmed` | `false` | Set to true in host_vars for a multi-homed host whose routing is symmetric. |
| `cis_safeguards_rp_filter_ignore_interfaces` | regex for Docker, Podman, libvirt and CNI bridges | Interfaces that don't count as a second IPv4 interface. |
| `cis_safeguards_authselect_allowed_profiles` | `[sssd, local]` | authselect base profiles that CIS may replace. |
| `cis_safeguards_authselect_cis_features` | `[with-faillock, with-pwquality, with-pwhistory, without-nullok]` | Features CIS re-applies itself. Any other feature on the current profile would be lost, so the host stops. |

Variables from other roles that the checks read: `rhel9cis_firewall`, `rhel9cis_default_zone`,
`rhel9cis_rule_3_3_7`, `rhel9cis_disruption_high`, `rhel9cis_allow_authselect_updates`,
`rhel9cis_authselect_custom_profile_name`, `linux_common_ipv6_manage`, `linux_common_ipv6_enabled`
and every `filesystems_volumes__*` list.

## Example

```yaml
# inventories/<ENV>/group_vars/rocky9.yml
cis_safeguards_ssh_allow_groups: [sshusers, wheel, linux-admins]
cis_safeguards_ssh_group: sshusers

# inventories/<ENV>/host_vars/<multi-homed host>.yml
cis_safeguards_strict_rp_filter_confirmed: true
```

The matching `rhel9cis_*` settings (for example `rhel9cis_sshd_allowgroups`, which is built from
`cis_safeguards_ssh_allow_groups`) are in `playbooks/group_vars/rocky9.yml` and apply to every
environment.

# cloud_init_cleanup

Retires cloud-init once it has done its job. cloud-init is only needed for the first boot of a
clone, to set the host name, the static address and DNS from Terraform. After that this role
removes the account cloud-init created, that account's sudo rule, and cloud-init itself.

| | |
|---|---|
| Playbook | `playbooks/cloud_init_cleanup.yml` (in `site.yml` after data disks, before CIS) |
| Hosts | `rocky9` |
| Tag | `cloud_init_cleanup` |
| Needs first | Nothing. It works without the mirror. |
| Set variables in | `inventories/<ENV>/group_vars/rocky9.yml` (only to change the defaults) |

## Why it runs before CIS

cloud-init creates a login account, `cloud-user`, on every clone. Nobody uses it: Terraform gives
it no SSH key. But the CIS lockout pre-check (`roles/cis_safeguards`) stops any host where a local
login account would lose SSH access, so with `cloud-user` present the CIS play stops with:

```
These local users are in none of [...] and would lose SSH access: cloud-user.
```

Running this role first removes the account, so the pre-check passes.

## What it does, in order

1. **Checks** the settings, and that root or the account Ansible connects as is not in the list
   of accounts to remove.
2. **Waits for the first boot to finish** if cloud-init is still running. Stops if cloud-init
   reported an error, because the host name or network may then be wrong.
3. **Keeps Ansible's sudo**: writes `/etc/sudoers.d/90-<ansible account>`, the same file the
   Terraform bootstrap and `cis_safeguards` write. This matters on hosts where cloud-init created
   the Ansible account and its only sudo rule is in cloud-init's file.
4. **Removes `cloud-user`** and its home directory.
5. **Deletes `/etc/sudoers.d/90-cloud-init-users`**. If that file gave sudo to any other account,
   the play says which.
6. **Moves the sshd setting** cloud-init wrote (`PasswordAuthentication`, in
   `/etc/ssh/sshd_config.d/50-cloud-init.conf`) into `45-tuningfork-auth.conf`. It compares the
   effective sshd settings before and after, and stops if they differ.
7. **Uninstalls cloud-init** and deletes `/etc/cloud`, `/var/lib/cloud` and `/run/cloud-init`
   (`remove`), or **switches it off** with `/etc/cloud/cloud-init.disabled` (`disable`).
8. **Verifies**: drops the SSH connection, opens a new one and runs a command with sudo.

On a host that is already cleaned up, nothing changes.

## What it keeps

cloud-init wrote these on first boot. The host runs on them now, so they stay exactly as they are:

| Kept | Why |
|---|---|
| The network connection: `/etc/NetworkManager/system-connections/cloud-init-*.nmconnection` or `/etc/sysconfig/network-scripts/ifcfg-*`, and `/etc/NetworkManager/conf.d/99-cloud-init.conf` if present | The host's address, gateway and DNS. Deleting them takes the host off the network. The `cloud-init` in the names is only the name. |
| `/etc/resolv.conf`, `/etc/hostname`, `/etc/hosts` | Name resolution and the host name. |
| `/var/log/cloud-init.log`, `/var/log/cloud-init-output.log` | Record of the first boot. Logs aren't configuration. |
| The sshd setting from `50-cloud-init.conf` | Moved, not dropped (step 6). Dropping it would turn password logins back on (the sshd default), on hosts without AD. |

## Remove or disable

| | `remove` (default) | `disable` |
|---|---|---|
| Package | Uninstalled | Installed |
| `/etc/cloud`, `/var/lib/cloud` | Deleted | Kept |
| At boot | Nothing to run | cloud-init sees `/etc/cloud/cloud-init.disabled` and does nothing |
| Undo | Reinstall the package (not recommended: see below) | Delete `/etc/cloud/cloud-init.disabled` |

**Don't turn cloud-init back on for a VM that is in use.** With its state gone (`remove`), it
treats the next boot as a new VM: it regenerates the SSH host keys, rewrites the network and the
host name from Proxmox, and creates `cloud-user` again.

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `cloud_init_cleanup_method` | `remove` | `remove` uninstalls cloud-init and deletes its configuration and state. `disable` keeps it installed but switched off. |
| `cloud_init_cleanup_users` | `[cloud-user]` | Accounts cloud-init created that nobody uses. Must not include root or the Ansible account. |
| `cloud_init_cleanup_account` | `{{ ansible_user }}` (else `ansible`) | Account Ansible connects as. It keeps sudo through its own drop-in. |
| `cloud_init_cleanup_packages` | `[cloud-init]` | Packages uninstalled with `remove`. |
| `cloud_init_cleanup_paths` | `/etc/cloud`, `/var/lib/cloud`, `/run/cloud-init` | Configuration and state deleted with `remove`. |
| `cloud_init_cleanup_sshd_dropin` | `/etc/ssh/sshd_config.d/45-tuningfork-auth.conf` | Where the sshd setting from `50-cloud-init.conf` is moved. Keep it between `40-` and `50-redhat.conf` so sshd reads the files in the same order. |
| `cloud_init_cleanup_wait_timeout` | `600` | Seconds to wait for a first boot that is still running cloud-init. |
| `cloud_init_cleanup_allow_errors` | `false` | Carry on although cloud-init reported an error on first boot. For one run, on the command line, after checking the host. |

## Example

```sh
# One host
ansible-playbook -i inventories/lab playbooks/cloud_init_cleanup.yml --limit nas.lab.local

# Disable instead of uninstall, for this environment
# inventories/<ENV>/group_vars/rocky9.yml
cloud_init_cleanup_method: disable
```

## Changing a VM's address or DNS later

With cloud-init gone, changing `ipv4_cidr`, `ipv4_gateway` or the DNS servers in Terraform no
longer changes anything inside the VM. Terraform only updates the cloud-init drive in Proxmox,
which nothing reads any more. It does update the inventory, so Ansible would then try the new
address and fail.

To change an address: change it on the host first (`nmcli connection modify ...`), then in
Terraform, then apply.

## When the play stops

| Message contains | Meaning | What to do |
|---|---|---|
| `must not include root or the account Ansible connects as` | `cloud_init_cleanup_users` lists an account that must stay. | Remove it from the list. |
| `is still running after` | The first boot hasn't finished. | Wait, or look at `cloud-init status --long` on the host. |
| `reported an error` | cloud-init failed during first boot. | Check `/var/log/cloud-init.log`, `hostnamectl` and `nmcli connection show`. When the host is right, run once with `-e cloud_init_cleanup_allow_errors=true`. |
| `changed the effective sshd settings` | Another drop-in in `/etc/ssh/sshd_config.d/` sorts between the old and the new file. | Compare the two lists in the message and fix the drop-ins. sshd has not been restarted, so current sessions are unaffected. |
| `user ... is currently used by process` | Someone is logged in as `cloud-user`. | Log that session out and run again. |

# Active Directory logins on Rocky 9

Rocky 9 hosts join the AD domain and use **sssd** so that both local accounts and AD accounts can log
in. AD users get a home directory on first login. SSH and sudo access are controlled by AD groups.
The Linux side is automated by the `sssd_ad` role (`playbooks/sssd_ad.yml`). This document covers the
design choice, the one-time AD preparation, UID/GID management, and day-to-day access changes.

| Environment | Domain | Domain controllers |
|---|---|---|
| lab | `lab.local` | `dc1.lab.local`, `dc2.lab.local` |
| CRGS00 / CRGS01 / CRGS02 | set in `inventories/<ENV>/group_vars/linux.yml` | one DC each |

## 1. Join the domain or use LDAP only?

| | **Join the domain** (adcli, `id_provider = ad`), used here | **LDAP only** (`id_provider = ldap`, bind account) |
|---|---|---|
| Credentials on each host | Machine account keytab (`/etc/krb5.keytab`). sssd changes its password automatically every 30 days | A service account's bind password in `sssd.conf` on **every** host. Rotating it means changing every host |
| How users authenticate | Kerberos. The password is never sent to the DC, and users get Kerberos tickets | LDAP simple bind. The user's password is sent to the DC, so LDAPS/StartTLS is mandatory |
| Transport security | LDAP traffic is signed and sealed with Kerberos (SASL GSSAPI). Meets AD's LDAP signing and channel-binding requirements without LDAPS | Needs LDAPS certificates on the DCs and the CA trusted on every host |
| Finding DCs, failover | DNS SRV records, AD-site aware, automatic failover | Static `ldap_uri` list that you maintain |
| Group lookups | Fast (tokenGroups), nested groups resolved | Slower, and nested or large groups need tuning |
| Expired passwords | Can be changed at login (kpasswd) | Limited. Usually needs extra configuration |
| Access control | `simple` (groups, used here) or AD GPOs | `simple` or an LDAP filter |
| Prerequisites | A join account allowed to create computer objects, DNS that resolves the domain, clocks within 5 minutes (NTP), computer name ≤ 15 characters | A read-only bind account only |
| Lifecycle | One computer object per host, which must be deleted when the VM is destroyed | Nothing in AD per host |
| Best fit | Long-lived servers in a domain you administer | Hosts that can't use Kerberos, or where creating computer objects isn't allowed |

**Decision: join.** No shared secret is spread across hosts, passwords stay off the network, and
failover and nested groups work without tuning. The lab's DNS (192.168.70.101/.102) and NTP already
point at the DCs, which covers the Kerberos prerequisites. In return there is a delegated join account to look after
and computer objects to clean up (section 6).

## 2. One-time AD preparation (per domain)

Run on a DC or a machine with RSAT (PowerShell, `ActiveDirectory` module). Adjust the DN to the domain.

```powershell
$base = "DC=lab,DC=local"

# OU for Linux computer objects (matches sssd_ad_computer_ou)
New-ADOrganizationalUnit -Name "Servers" -Path $base
New-ADOrganizationalUnit -Name "Linux"   -Path "OU=Servers,$base"
$ou = "OU=Linux,OU=Servers,$base"

# Join account (matches sssd_ad_join_user). Password goes into the Ansible vault
# as vault_sssd_ad_join_password.
New-ADUser -Name "svc-linux-join" -SamAccountName "svc-linux-join" -Path "OU=Servers,$base" `
  -AccountPassword (Read-Host -AsSecureString "Password") -Enabled $true -PasswordNeverExpires $true `
  -CannotChangePassword $true -Description "Joins Linux hosts to AD (Ansible sssd_ad)"

# Groups (sssd_ad_ssh_groups / sssd_ad_admin_groups, plus the shared primary group)
New-ADGroup -Name "linux-users"     -GroupScope Global -GroupCategory Security -Path $ou
New-ADGroup -Name "linux-ssh-users" -GroupScope Global -GroupCategory Security -Path $ou
New-ADGroup -Name "linux-admins"    -GroupScope Global -GroupCategory Security -Path $ou
```

**Delegate the join account on the Linux OU only.** In ADUC, right-click the OU, choose *Delegate Control...*,
add `svc-linux-join`, pick *Create a custom task*, and select *Only the following objects: Computer objects* with
*Create selected objects* and *Delete selected objects*. On the next page, select *Reset password*,
*Read and write Account Restrictions*, *Validated write to DNS host name* and
*Validated write to service principal name*. The account needs no other rights. In particular it should not be in Domain Admins.

Group names: use lowercase names **without spaces**. Hosts use short names (`linux-admins`, not
`linux-admins@lab.local`), and the same names appear in sshd and sudoers.

## 3. UID/GID plan

The hosts read POSIX IDs from AD (`uidNumber`, `gidNumber`) instead of generating them from SIDs. Every host
and NFS share then sees the same IDs. **Users and groups without these attributes are invisible on Linux**,
which also acts as an allow list.

| Range | Used for |
|---|---|
| 0–999 | System accounts (local) |
| 1,000–59,999 | Local users (`useradd`) |
| 61,184–65,519 | systemd dynamic users |
| 65,534 | `nobody` |
| 100,000+ (65,536 per local user) | Rootless container subuid/subgid ranges (`/etc/subuid`) |
| **1,000,000–1,999,999** | **AD users** (`uidNumber`) |
| **2,000,000–2,999,999** | **AD groups** (`gidNumber`) |

- Hosts ignore anything below `sssd_ad_min_id` (1,000,000), so AD can never shadow a local or system ID.
- Every Linux user's `gidNumber` (primary group) is **2,000,000 = `linux-users`**. Give that group `gidNumber` 2000000.
- **Never reuse an ID** after deleting an account. Files on disk still carry the old number.
- `loginShell` and `unixHomeDirectory` are optional. Hosts use `/bin/bash` when `loginShell` isn't set, and
  always `/home/<user>` for the home directory.

Windows Server 2016 and later no longer assign these IDs automatically (the "UNIX Attributes" tab is gone).
Set them yourself:

**ADUC:** *View → Advanced Features*, then open the user or group and go to the *Attribute Editor* tab:
- user: `uidNumber` = next free ID in 1,000,000–1,999,999, and `gidNumber` = 2000000
- group: `gidNumber` = next free ID in 2,000,000–2,999,999

**PowerShell** (recommended: it finds the next free ID):

```powershell
Import-Module ActiveDirectory

function Get-NextUid {
  $max = (Get-ADUser -LDAPFilter "(uidNumber>=1000000)" -Properties uidNumber |
          Measure-Object -Property uidNumber -Maximum).Maximum
  if ($max) { [int]$max + 1 } else { 1000000 }
}
function Get-NextGid {
  $max = (Get-ADGroup -LDAPFilter "(gidNumber>=2000001)" -Properties gidNumber |
          Measure-Object -Property gidNumber -Maximum).Maximum
  if ($max) { [int]$max + 1 } else { 2000001 }
}

# Primary group for all Linux users
Set-ADGroup linux-users -Replace @{gidNumber = 2000000}

# Other groups that Linux should see
foreach ($g in "linux-ssh-users", "linux-admins") {
  if (-not (Get-ADGroup $g -Properties gidNumber).gidNumber) {
    Set-ADGroup $g -Replace @{gidNumber = (Get-NextGid)}
  }
}

# Enable a user for Linux
function Enable-LinuxUser([string]$Sam) {
  $u = Get-ADUser $Sam -Properties uidNumber
  if (-not $u.uidNumber) {
    Set-ADUser $Sam -Replace @{uidNumber = (Get-NextUid); gidNumber = 2000000}
  }
  Add-ADGroupMember linux-users -Members $Sam
}
Enable-LinuxUser jdoe

# Report
Get-ADUser  -LDAPFilter "(uidNumber=*)" -Properties uidNumber,gidNumber | Sort uidNumber | ft SamAccountName,uidNumber,gidNumber
Get-ADGroup -LDAPFilter "(gidNumber=*)" -Properties gidNumber | Sort gidNumber | ft Name,gidNumber
```

If two administrators assign IDs at the same time they can pick the same number. Assign IDs from one place
(one admin, or a scheduled script), and check for duplicates with the report above.

**Check from a Linux host:**

```sh
id jdoe                       # uid=1000000(jdoe) gid=2000000(linux-users) groups=...
getent group linux-admins     # linux-admins:*:2000002:jdoe
```

## 4. SSH access by AD group

A user can log in to Rocky 9 hosts when they are in `linux-ssh-users` or `linux-admins` and have a `uidNumber`.
Both groups need a `gidNumber`. Two settings enforce this, and the Ansible variables keep them in step:
- sssd `simple_allow_groups`: AD users outside these groups can't log in at all, including at the console
- sshd `AllowGroups`, set by CIS from `cis_safeguards_ssh_allow_groups`: `sshusers`, `wheel` and the AD groups

**Grant or revoke access for a person:** add them to or remove them from the AD group. Hosts pick the change up when
the sssd cache expires (up to about 90 minutes). To apply it immediately on a host, run `sudo sss_cache -E`.

**Add a new access group** (e.g. `app-operators`):
1. AD: create the group and give it a `gidNumber` (section 3).
2. Ansible: add it to `sssd_ad_ssh_groups` in `inventories/<ENV>/group_vars/linux.yml`.
3. Run `playbooks/sssd_ad.yml` (sssd) and `playbooks/cis_rhel9.yml` (sshd `AllowGroups`), or `site.yml`.

Local accounts keep working as before: SSH requires membership of `sshusers` or `wheel`.

**Extra SSH groups for some hosts** (e.g. only Kubernetes users on the bastion): set `sssd_ad_extra_ssh_groups`
in that group's `group_vars` (e.g. `inventories/<ENV>/group_vars/k8s_bastions.yml: [k8s-users]`). These groups are
added to sssd's allowed groups and to sshd `AllowGroups` on those hosts only. A separate variable is used because
a group-level `sssd_ad_ssh_groups` would compete with the one in `linux.yml`.

## 5. sudo by AD group

Members of `sssd_ad_admin_groups` (default `linux-admins`) get `/etc/sudoers.d/50-ad-admins`:

```
%linux-admins ALL=(ALL) ALL
```

sudo asks for the user's **AD password**, as CIS 5.2.4 requires. For narrower rights, add a group to
`sssd_ad_ssh_groups` for login and give it its own drop-in, for example
`%app-operators ALL=(root) /usr/bin/systemctl restart myapp`. Validate drop-ins with `visudo -cf`.
Sudo rules stored in AD aren't used, because they would need an AD schema extension.

## 6. Operations

| Task | Command (on the host) |
|---|---|
| Is the host joined? | `sudo adcli testjoin` |
| Is sssd talking to the DCs? | `sudo sssctl domain-status lab.local` |
| Why can't a user log in? | `sudo sssctl user-checks jdoe`, `sudo journalctl -u sssd -u sshd --since -1h` |
| Clear cached users/groups | `sudo sss_cache -E` |
| Machine keytab | `sudo klist -k /etc/krb5.keytab` |
| Kerberos test as a user | `kinit jdoe@LAB.LOCAL && klist` |

- **Clocks:** Kerberos fails if a host is more than 5 minutes off. The hosts use the DCs (or the same source) as NTP servers.
- **Destroying a VM** (`terragrunt destroy` or removing it from the VM list): delete its computer object as
  well, in ADUC or with `Remove-ADComputer <name>`. Otherwise stale objects pile up. Rebuilding a VM
  with the same name rejoins and reuses the object.
- **Offline logins:** users who have logged in before can still log in with cached credentials while no DC is reachable.
- **CIS:** in every environment `rhel9cis_disruption_high` is false, so CIS doesn't touch authselect. If it is
  ever turned on, the CIS pre-check stops because the profile has `with-mkhomedir`, which CIS would drop.

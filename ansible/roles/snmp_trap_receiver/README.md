# snmp_trap_receiver

Runs snmptrapd on the SIEM VM to receive SNMPv3 traps from the Dell iDRACs. It translates them
with the Dell iDRAC MIB and writes them to a log file that the Wazuh manager reads. Only traps
from the configured SNMPv3 users are accepted: there are no communities and no unauthenticated
traps.

| | |
|---|---|
| Playbook | `playbooks/snmp_trap_receiver.yml` (also run by `playbooks/siem.yml`, after `syslog_receiver`) |
| Hosts | `siem_servers` |
| Tags | `snmp_trap_receiver`; `firewall` on the firewall task |
| Needs first | `certificates`, `repositories`, `syslog_receiver` (its log rotation covers the trap log) |
| Set variables in | `group_vars/all/siem.yml` (`siem_snmp_trap_users`, `siem_log_senders_extra`), the vault (passwords), `siem_versions.yml` (the MIB) |
| Guide | [docs/siem.md](../../docs/siem.md) |

## What it does

1. **MIB**: `siem_artifacts` fetches the Dell iDRAC MIB from the mirror (key `dell_idrac_mib`),
   checks its sha256 and installs it to `/usr/share/snmp/mibs/tuningfork`.
2. **Packages**: installs `net-snmp` and `net-snmp-utils` from the mirror.
3. **Log folder**: creates `/var/log/remote/snmptrapd` and labels it `snmpd_log_t`. snmptrapd runs
   confined under SELinux and may only write to folders with its log type.
4. **Users**: writes `/etc/snmp/snmptrapd.conf` (0600, not logged). It has one `createUser` line
   per entry of `snmp_trap_receiver_users`, with the sender's engine ID, and allows only those
   users to log traps. With no users, every trap is dropped.
5. **Options**: `/etc/sysconfig/snmptrapd` sends the output to the log file and loads the MIB.
6. **Service and firewall**: starts snmptrapd. One rich rule per sender address opens 162/udp.

## Variables

Required, for traps to be accepted:

| Variable | Where | Description |
|---|---|---|
| `siem_snmp_trap_users` | `group_vars/all/siem.yml` | List of SNMPv3 trap senders (format below). Empty: every trap is dropped. |
| `dell_idrac_mib` artifact | `siem_versions.yml` | MIB file and sha256. |

Each entry of `siem_snmp_trap_users` is filled in with the iDRAC configuration. Put the passwords
in the vault and reference them:

```yaml
siem_snmp_trap_users:
  - engine_id: "0x80001f88..."     # the iDRAC's SNMP engine ID (each iDRAC has its own)
    name: tuningfork-trap
    auth_protocol: SHA-256         # net-snmp names: SHA, SHA-256, ...
    auth_password: "{{ vault_snmp_trap_auth_password }}"
    priv_protocol: AES
    priv_password: "{{ vault_snmp_trap_priv_password }}"
```

Optional:

| Variable | Default | Description |
|---|---|---|
| `snmp_trap_receiver_users` | `siem_snmp_trap_users` | Users allowed to send traps. |
| `snmp_trap_receiver_senders` | `siem_trap_senders`: the `idrac` hosts plus `siem_log_senders_extra` | Addresses the firewall lets in on 162/udp. |
| `snmp_trap_receiver_dir` | `/var/log/remote/snmptrapd` | Log folder, under the syslog receiver's folder. |
| `snmp_trap_receiver_log` | `<dir>/traps.log` | Log file the Wazuh manager reads. |
| `snmp_trap_receiver_mib_dir` | `/usr/share/snmp/mibs/tuningfork` | Where the MIB is installed. |
| `snmp_trap_receiver_mibs` | `[IDRAC-MIB-SMIv2]` | MIB modules loaded by name. |
| `snmp_trap_receiver_manage_firewall` | `true` | Open 162/udp to the senders. |
| `snmp_trap_receiver_firewall_zone` | `rhel9cis_default_zone`, else `public` | firewalld zone. |

The vault key names in the example are only examples. Use whichever `vault_*` names you add.

## Files on the host

| File | Content |
|---|---|
| `/etc/snmp/snmptrapd.conf` (0600) | SNMPv3 users allowed to send (template `snmptrapd.conf.j2`) |
| `/etc/sysconfig/snmptrapd` | Log file and MIB options |
| `/usr/share/snmp/mibs/tuningfork/` | Dell iDRAC MIB |
| `/var/log/remote/snmptrapd/traps.log` | Received traps, translated |

## Checks

```sh
systemctl status snmptrapd
tail -f /var/log/remote/snmptrapd/traps.log     # then send a test trap from the iDRAC
```

# syslog_receiver

Turns the SIEM VM into the environment's syslog receiver. rsyslog accepts syslog from the Proxmox
hosts and the iDRACs, which can't run a Wazuh agent. It writes one file per sender and program, and
the Wazuh manager reads those files (`roles/wazuh_server`, `wazuh_server_localfiles`).

| | |
|---|---|
| Playbook | `playbooks/syslog_receiver.yml` (also run by `playbooks/siem.yml`, after the Wazuh server) |
| Hosts | `siem_servers` |
| Tags | `syslog_receiver`; `firewall` on the firewall task |
| Needs first | `repositories`, the `/var/log/remote` data disk (`filesystems`) |
| Set variables in | `inventories/<ENV>/group_vars/all/siem.yml` (`siem_log_senders_extra`) |
| Guide | [docs/siem.md](../../docs/siem.md) |

**CIS exception.** On every other Rocky host, journald is the only log system, and the CIS control
"Ensure only one logging system is in use" would stop rsyslog. The benchmark allows a designated
log host to receive remote logs, so `playbooks/group_vars/siem_servers.yml` turns that control
off for `siem_servers` only.

## What it does

1. Installs rsyslog and creates `/var/log/remote` (0750).
2. Writes `/etc/rsyslog.d/10-tuningfork-receiver.conf`, which `rsyslogd -N1` validates before it is
   written:
   - listens on 514/udp and 514/tcp;
   - writes every received message to `/var/log/remote/<sender IP>/<program>.log`, through its
     own ruleset that ends in `stop`. Received messages therefore never mix with the SIEM VM's
     own logs.
3. Rotates `/var/log/remote/*/*.log` daily and keeps `syslog_receiver_keep_days` days,
   compressed. It uses `copytruncate`, so the rotation also covers files that other programs write
   there, such as snmptrapd's `traps.log`. Wazuh keeps its own copy of every event, for longer.
4. Starts rsyslog. One rich rule per sender address and protocol opens port 514.

## Variables

All optional. To add senders, set `siem_log_senders_extra` in `group_vars/all/siem.yml`.

| Variable | Default | Description |
|---|---|---|
| `syslog_receiver_senders` | `siem_log_senders`: the `ansible_host` of every `proxmox_hosts` and `idrac` host, plus `siem_log_senders_extra` | Addresses the firewall lets in. |
| `syslog_receiver_port` | `514` | Port. |
| `syslog_receiver_protocols` | `[udp, tcp]` | Protocols to listen on. |
| `syslog_receiver_dir` | `/var/log/remote` | Received logs, on a data disk. |
| `syslog_receiver_keep_days` | `30` | Days of rotated files kept. |
| `syslog_receiver_manage_firewall` | `true` | Open port 514 to the senders. |
| `syslog_receiver_firewall_zone` | `rhel9cis_default_zone`, else `public` | firewalld zone. |

## Files on the host

| File | Content |
|---|---|
| `/etc/rsyslog.d/10-tuningfork-receiver.conf` | Inputs, per-sender files (template `receiver.conf.j2`) |
| `/etc/logrotate.d/tuningfork-remote` | Rotation of the received files |
| `/var/log/remote/<sender IP>/<program>.log` | Received messages |

## Checks

```sh
systemctl status rsyslog
ls /var/log/remote/
logger -n <SIEM VM> -P 514 -d "test from $(hostname)"     # from a sender, over UDP
```

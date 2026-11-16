# Air-Gapped SIEM and Observability Design: Wazuh, Prometheus, Grafana

Nov 15, 2026 · @dido

## Summary

One dedicated Rocky Linux 9 VM hosts Wazuh (SIEM), Prometheus (metrics) and Grafana (dashboards) for the air-gapped environment. It collects logs, security audit events, and hardware and operating system metrics from the Dell iDRAC, the Proxmox VE host, the Windows Server domain controller and up to 10 Rocky Linux 9 VMs.

Indexed logs and dashboards are the primary source of observability. Email to the local SMTP endpoint is a secondary, best-effort channel that queues while the endpoint is unavailable.

| Component | Role | License |
| --- | --- | --- |
| Wazuh manager, indexer, dashboard | SIEM: log collection, rules, correlation, file integrity, security dashboards, email alerts | GPLv2 and Apache 2.0 |
| Wazuh agent | Log, audit and file integrity collection on Windows, Rocky and Proxmox | GPLv2 |
| Prometheus and Alertmanager | Metrics storage, alert rules, email routing | Apache 2.0 |
| Exporters: node, windows, snmp, pve | Metrics from Linux, Windows, iDRAC and Proxmox | Apache 2.0 or MIT |
| Grafana OSS | Hardware and OS dashboards | AGPLv3 |
| rsyslog, net-snmp (snmptrapd), Postfix, chrony, auditd | Syslog receiver, SNMP trap receiver, mail relay, time sync, Linux audit | Shipped with Rocky 9 |

The required audit event list also brings in anti-malware scanning: Microsoft Defender Antivirus on Windows and ClamAV (GPLv2) on Rocky Linux and Proxmox.

All components are used unmodified as internal tooling and are not redistributed to customers.

## Requirements

The design must meet these 12 requirements. Each maps to the component that satisfies it.

| ID | Requirement | Met by |
| --- | --- | --- |
| R1 | Runs entirely inside the air gap, with no internet dependency at install or run time | Offline package bundles, local repository, offline vulnerability feed |
| R2 | Free to use commercially, unmodified, as internal tooling | Open-source licenses listed in the summary |
| R3 | One dedicated Rocky Linux 9 VM | All-in-one deployment on the SIEM VM |
| R4 | SIEM capability: collection, correlation, rules, search | Wazuh manager and indexer |
| R5 | Accept syslog | rsyslog receiver on the SIEM VM, read by Wazuh |
| R6 | Accept SNMP | snmptrapd for traps, Prometheus snmp\_exporter for polling |
| R7 | Collect file-based logs | Wazuh agent `localfile` entries |
| R8 | Hardware monitoring: CPU, memory, disks, power supplies, fans, temperature | iDRAC syslog and traps (events), SNMP polling (state) |
| R9 | Operating system monitoring for Windows Server and Rocky Linux | Wazuh agents (logs), node\_exporter and windows\_exporter (metrics) |
| R10 | Security audit: every event on the required audit list (logins, accounts, roles, MFA, permissions, privileged commands, mounts, file deletion, network traffic, malware scans, backups, vulnerability scans, system information queries), plus time sync and 30 days of local log storage | Windows Advanced Audit Policy, Linux auditd, host firewall logging, anti-malware and backup logs, Wazuh rules and file integrity monitoring. See "Required audit events" |
| R11 | Dashboards and logs are the primary source of observability | Wazuh dashboard, Grafana, indexed alerts, on-disk archives |
| R12 | Optional email alerts to a local SMTP endpoint that may be unavailable | Wazuh and Alertmanager send through a local Postfix relay that queues and retries |

### Monitored systems

| System | Count | Role |
| --- | --- | --- |
| Dell server with iDRAC Enterprise | 1 | Hardware and out-of-band management |
| Proxmox VE | 1 | Virtualization host (Debian based) |
| Windows Server Standard | 1 | Active Directory domain controller |
| Rocky Linux 9 VMs | Up to 10 | Workloads, including the SIEM VM itself |

## Required audit events

Every event on the required audit list is logged at its source, kept there for at least 30 days, and forwarded to Wazuh. The tables below show where each event comes from. Settings that make this happen are in the per-system sections under "Additions for the required audit events".

Three items need a decision before they are fully covered: which MFA mechanism is in use, which anti-malware and backup products are in use, and how "system information query" is to be interpreted. Defaults are stated here and listed under open decisions.

### Applications that require a login

The successful and unsuccessful login requirements apply to operating system login. The design also logs every application login it introduces or depends on.

| Login surface | Where the login event is recorded | Collected by |
| --- | --- | --- |
| Windows console, RDP and domain logon | Security event log | Wazuh agent |
| Rocky Linux console and SSH | `/var/log/secure` and the audit log | Wazuh agent |
| Proxmox host console and SSH | journald and the audit log | Wazuh agent |
| Proxmox web interface and API | journald (`pvedaemon`), `pveproxy` access log | Wazuh agent |
| iDRAC web interface, SSH, Redfish, racadm | iDRAC Lifecycle log, sent by remote syslog | rsyslog, then Wazuh |
| Wazuh dashboard and indexer | Indexer security audit log (enable it) | Wazuh agent on the SIEM VM |
| Wazuh manager API | `/var/ossec/logs/api.log` | Wazuh manager |
| Grafana | Grafana server log | Wazuh agent on the SIEM VM |

Prometheus and Alertmanager have no login and are bound to localhost.

### Logins and accounts

| Audit event | Windows domain controller | Rocky Linux and Proxmox host |
| --- | --- | --- |
| Successful login | 4624; Kerberos 4768, 4769 | SSH and PAM entries in `/var/log/secure` or journald; audit `USER_LOGIN`, `USER_START` |
| Unsuccessful login | 4625, 4771, 4776 | SSH and PAM failures; audit `USER_LOGIN` with a failed result |
| Account lock | 4740 | `pam_faillock` lockout (audit `ANOM_LOGIN_LOCK`, `RESP_ACCT_LOCK`); administrative lock (audit `ACCT_LOCK`) |
| Account unlock | 4767 | `faillock --reset` (watched command and directory); administrative unlock (audit `ACCT_UNLOCK`) |
| Account created | 4720 | audit `ADD_USER`; `useradd` entry in the secure log |
| Account deleted | 4726 | audit `DEL_USER`; `userdel` entry in the secure log |
| Role assigned to account | 4728, 4732, 4756 (added to a group); 4704 (user right assigned) | Group membership change (audit `USER_MGMT`, `ADD_GROUP`); writes to sudoers files |
| Role removed from account | 4729, 4733, 4757; 4705 | Group membership change (audit `USER_MGMT`, `DEL_GROUP`); writes to sudoers files |
| MFA token assigned | 5136 on credential attributes such as `msDS-KeyCredentialLink`, `altSecurityIdentities`, `userCertificate` | Audit watches on the token enrolment files of the chosen mechanism |
| MFA token removed | 5136 on the same attributes | Same watches |
| Password reset | 4724 (reset by an administrator); 4723 (changed by the user) | audit `USER_CHAUTHTOK`; `passwd` entry in the secure log |

Proxmox's own users, roles and second factors live in `/etc/pve/user.cfg` and `/etc/pve/priv/tfa.cfg`. File integrity monitoring and the `pvedaemon` log record changes to them. Role and user changes inside Wazuh and Grafana are recorded in their own logs, which the SIEM VM's agent collects.

### Privilege, permissions and files

| Audit event | Windows domain controller | Rocky Linux and Proxmox host |
| --- | --- | --- |
| Discretionary access control permission change | 4670 (object permissions changed); 5136 for directory object permissions; file integrity monitoring reports permission changes | auditd on `chmod`, `fchmod`, `fchmodat`, `chown`, `fchown`, `lchown`, `fchownat`, `setxattr`, `lsetxattr`, `fsetxattr`, `removexattr`, `lremovexattr`, `fremovexattr` |
| Privileged command execution (Linux) | Not applicable | auditd on execution of every setuid and setgid program, and on any command run as root by a login user |
| File system mounts | 6416 (new device recognised); volume mount events in the NTFS operational channel | auditd on `mount` and `umount2`; mount units in the journal |
| File deletion by a user | 4660 and 4663 on audited folders; file integrity monitoring in who-data mode | auditd on `unlink`, `unlinkat`, `rename`, `renameat` by login users |
| Compute host administrator actions | 4672 (administrator logon); 4688 with command line and elevated token; 4673, 4674; PowerShell 4104 | `sudo` and `su` in the secure log; audit `USER_CMD` |
| System information queries | 4688 for every process, which captures `systeminfo`, `wmic`, `hostname` and similar; PowerShell 4104; WMI activity channel | auditd on every command run by a login user, which captures `uname`, `hostnamectl`, `lscpu`, `dmidecode`, `df` and similar |

System information queries are interpreted as commands and scripts that read system configuration. Logging every interactive command covers this without maintaining a list of tools. Proxmox API requests are in the `pveproxy` access log. iDRAC does not log individual read requests, only sessions.

### Network traffic

Only the establishment of a connection is logged, not every packet, in line with the notes on the inbound and outbound traffic requirements.

| Audit event | Windows domain controller | Rocky Linux | Proxmox host |
| --- | --- | --- | --- |
| Allowed outbound traffic | 5156, direction outbound | firewalld log rule on new outbound connections, prefix `FW-OUT-ALLOW` | Proxmox firewall log, outbound accept |
| Denied outbound traffic | 5157, direction outbound | firewalld log rule, prefix `FW-OUT-DENY` | Proxmox firewall log, outbound drop or reject |
| Allowed inbound traffic | 5156, direction inbound | firewalld log rule on new inbound connections, prefix `FW-IN-ALLOW` | Proxmox firewall log, inbound accept |
| Denied inbound traffic | 5157, direction inbound; 5152 | firewalld denied-packet logging, prefix `FW-IN-DENY` | Proxmox firewall log, inbound drop or reject |

Denied outbound events only exist where an outbound rule denies something. Hosts with no outbound restrictions will log allowed outbound connections only. iDRAC has no connection log.

### Malware scanning

The default design uses Microsoft Defender Antivirus on Windows and ClamAV on Rocky Linux and the Proxmox host. Each host runs a scheduled scan through a small wrapper that writes one explicit result line per scan, so "completed", "clean", "failed" and "malware found" are each a distinct logged event.

| Audit event | Windows domain controller | Rocky Linux and Proxmox host |
| --- | --- | --- |
| Scan completed successfully | Defender 1001; wrapper result `completed` | Wrapper result `completed` (ClamAV exit code 0 or 1) |
| Clean scan | Wrapper result `clean` (scan finished with no detection) | Wrapper result `clean` (exit code 0) |
| Unsuccessful scan | Defender 1002 (stopped), 1005 (failed); wrapper result `failed` | Wrapper result `failed` (exit code 2, timeout or missing signatures) |
| Malware found | Defender 1116 (detected), 1117 (action taken) | Wrapper result `infected` with the `FOUND` lines (exit code 1) |
| Anti-malware cannot start into an operational mode | Defender 3002, 5001, 5008; Defender service not running | Scan or signature-update unit in a failed state; wrapper cannot start the scanner |

The last row is an alert requirement. It emails the administrator from both Wazuh (the event) and Alertmanager (the service state), and shows on the SIEM health dashboard.

### Backup and restore

| Audit event | Proxmox host | Windows domain controller | SIEM VM |
| --- | --- | --- | --- |
| Backup completed successfully | `vzdump` task ends OK in the task log and journal | Windows Server Backup success event | Indexer snapshot and configuration backup wrapper result `ok` |
| Backup failed | `vzdump` task ends with an error | Windows Server Backup failure event | Wrapper result `failed` |
| Restore completed successfully | `qmrestore` or `pct restore` task ends OK | Windows Server Backup recovery success event | Snapshot restore result `ok` |
| Restore failed | Restore task ends with an error | Windows Server Backup recovery failure event | Snapshot restore result `failed` |

This assumes Proxmox backup jobs for VMs and Windows Server Backup for the domain controller's system state. Another backup product needs its own log source and rules.

### Vulnerability scanning

| Audit event | Source |
| --- | --- |
| Vulnerability scan completed successfully | Wazuh agent inventory scan completion on each host; Wazuh manager vulnerability scanner log entries for a completed evaluation and feed load |
| Vulnerability scan failed | Vulnerability scanner error entries in the Wazuh manager log; inventory scan errors in the agent log |
| Vulnerabilities found | Wazuh vulnerability alerts per package and CVE, and the vulnerability inventory per host |

The manager and agents read their own `ossec.log` files so these entries become events. Wazuh's scanner is driven by inventory changes and feed updates, not a fixed schedule; a daily forced inventory scan gives a regular "completed" event.

### Time and local log storage

| Requirement | Design |
| --- | --- |
| Time reference: synchronise with the Ground Segment time reference at least once every 24 hours | The domain controller, the Proxmox host and iDRAC synchronise with the Ground Segment time source. Every VM synchronises with the domain controller. chrony and Windows Time poll many times per day. Prometheus alerts if any host is unsynchronised or has not updated for 12 hours |
| Use the system clock for log timestamps | Events carry the timestamp written by the source host's own clock. rsyslog stores the device timestamp in RFC 3339 form with time zone. Wazuh keeps the original event time and adds its own receive time. All hosts use UTC |
| Audit log storage capacity at source: at least 30 days | Linux audit log on its own volume, rotated by size and kept, sized for 45 days. System logs kept for 8 weekly rotations. journald retention set to 45 days. Windows Security log archived when full, archives kept 45 days. A daily check exports the age of the oldest local audit record as a metric, with an alert below 30 days |

The iDRAC Lifecycle log has a fixed capacity set by firmware, so 30 days cannot be guaranteed on the device itself. Its events are held on the SIEM VM for 180 days.

## Architecture

Every source sends two kinds of data to the SIEM VM: events (logs, audit records, traps) to Wazuh, and state (metrics) to Prometheus. Events explain what happened; polled state still shows a fault if the event was lost.

&#91;embedded content: architecture · 4 sources, 5 services on the SIEM VM, 2 outputs\]

Logs, audit events and traps flow through the receivers and agents into Wazuh; exporters feed Prometheus, which Grafana reads. Wazuh and Prometheus's Alertmanager both hand email to the local relay.

### Data paths

| Source | Events to Wazuh | Metrics to Prometheus |
| --- | --- | --- |
| Dell iDRAC | Remote syslog to rsyslog; SNMP traps to snmptrapd; both written to files that Wazuh reads | snmp\_exporter polls iDRAC over SNMPv3 |
| Proxmox VE host | Wazuh agent: auth, system, Proxmox task and proxy logs, ZFS and SMART messages | node\_exporter on the host; pve-exporter queries the Proxmox API |
| Windows domain controller | Wazuh agent: Security, System, Application, Directory Service, DNS Server and PowerShell channels; file integrity monitoring | windows\_exporter |
| Rocky Linux VMs | Wazuh agent: `/var/log/secure`, `/var/log/messages`, `audit.log`, application log files; file integrity monitoring | node\_exporter |

### Ports and protocols

All listeners are on the SIEM VM unless the direction says otherwise.

| Port | Protocol | Direction | Purpose |
| --- | --- | --- | --- |
| 1514 | TCP | Agents to SIEM | Wazuh agent event transport |
| 1515 | TCP | Agents to SIEM | Wazuh agent enrollment |
| 514 | UDP and TCP | iDRAC and other devices to SIEM | Syslog into rsyslog |
| 162 | UDP | iDRAC to SIEM | SNMP traps into snmptrapd |
| 161 | UDP | SIEM to iDRAC | SNMP polling by snmp\_exporter |
| 9100 | TCP | SIEM to Rocky VMs and Proxmox host | node\_exporter scrape |
| 9182 | TCP | SIEM to Windows DC | windows\_exporter scrape |
| 8006 | TCP | SIEM to Proxmox host | Proxmox API, read-only token, for pve-exporter |
| 443 | TCP | Admin workstations to SIEM | Wazuh dashboard |
| 3000 | TCP | Admin workstations to SIEM | Grafana |
| 25 or 587 | TCP | SIEM to SMTP endpoint | Postfix relay of alert email |
| 123 | UDP | VMs to the domain controller; domain controller, Proxmox host and iDRAC to the Ground Segment time source | Time sync |

These stay bound to localhost on the SIEM VM: Wazuh indexer (9200), Wazuh API (55000), Prometheus (9090), Alertmanager (9093), snmp\_exporter (9116), pve-exporter (9221) and Postfix (25). Administrators reach Prometheus and Alertmanager through Grafana or an SSH tunnel.

## SIEM VM design

The SIEM VM is a single Rocky Linux 9 guest sized at 8 vCPU, 16 GB RAM and 400 GB of disk. Wazuh's own guidance for 1 to 25 agents is 4 vCPU, 8 GB RAM and 50 GB for 90 days ([Wazuh quickstart](https://documentation.wazuh.com/current/quickstart.html)). The extra capacity covers Prometheus, Grafana, on-disk archives and the high audit volume of a domain controller.

Wazuh lists Red Hat Enterprise Linux 9 as a recommended server platform, not Rocky by name. Rocky 9 is binary compatible and uses the same RPM packages.

### Sizing

| Resource | Value | Notes |
| --- | --- | --- |
| vCPU | 8 | Indexer and analysis engine are the main consumers |
| RAM | 16 GB | Indexer JVM heap fixed at 4 GB |
| OS disk | 40 GB | `/`, `/var/log` |
| Wazuh indexer data | 250 GB | `/var/lib/wazuh-indexer`, separate volume |
| Wazuh manager data and archives | 60 GB | `/var/ossec`, separate volume |
| Prometheus data | 30 GB | `/var/lib/prometheus`, separate volume |
| Remote syslog and trap files | 20 GB | `/var/log/remote`, separate volume |

Separate volumes stop one data store from filling the disk and stopping the others. Measure one week of real ingest before fixing final sizes.

### Services

| Service | Installed from | Purpose |
| --- | --- | --- |
| wazuh-indexer | Wazuh offline bundle | Stores and searches alerts |
| wazuh-manager | Wazuh offline bundle | Receives agent data, applies rules, sends email |
| filebeat | Wazuh offline bundle | Ships alerts from manager to indexer (Wazuh 4.x) |
| wazuh-dashboard | Wazuh offline bundle | Security dashboards and search |
| rsyslog | Rocky repository | Receives remote syslog, writes one file per source host |
| snmptrapd | Rocky repository (net-snmp) | Receives SNMP traps, writes them to a log file |
| prometheus | Upstream binary | Scrapes and stores metrics, evaluates alert rules |
| alertmanager | Upstream binary | Groups, deduplicates and emails metric alerts |
| snmp\_exporter | Upstream binary | Translates iDRAC SNMP data into metrics |
| prometheus-pve-exporter | Python package, wheels carried in | Proxmox node, VM and storage metrics |
| node\_exporter | Upstream binary | Metrics for the SIEM VM itself |
| grafana | Upstream RPM | Hardware and OS dashboards |
| postfix | Rocky repository | Local mail relay with queue |
| chronyd | Rocky repository | Time sync to the domain controller |

### Retention

| Data | Location | Retention | Mechanism |
| --- | --- | --- | --- |
| Wazuh alerts (searchable) | Indexer | 90 days | Index state management policy deletes old daily indices |
| All received events (archives) | `/var/ossec/logs/archives`, compressed daily | 180 days | Enabled with `logall_json`; cleanup timer |
| Raw remote syslog and traps | `/var/log/remote` | 180 days | logrotate |
| Metrics | Prometheus | 90 days | `--storage.tsdb.retention.time=90d` plus a size cap |

By default Wazuh indexes only events that match a rule. The on-disk archive keeps everything received, so nothing is lost for later investigation.

### Mail relay

Wazuh and Alertmanager both send to Postfix on `localhost:25`. Postfix relays to the SMTP endpoint and holds mail in its queue while the endpoint is down. Wazuh cannot authenticate to SMTP itself, so the relay is also where any SMTP credentials and TLS settings live.

### Additions for the required audit events

- **Own logins and role changes:** The indexer's security audit log is enabled, and the SIEM VM's agent reads it along with the Grafana server log and the Wazuh API log.
- **Vulnerability scan events:** The manager reads its own `ossec.log`. Custom rules turn vulnerability scanner completion and error lines into events.
- **Backups:** The indexer snapshot and configuration backup run through a wrapper that logs `ok` or `failed`.
- **Traffic volume:** Connection events from every host are indexed at a low level. The indexer volume was raised from 150 GB to 250 GB to allow for this.
- **Same baseline as other Rocky VMs:** The SIEM VM gets the full Rocky rule set, firewall logging, ClamAV scan and 30-day local retention.

## Dell iDRAC integration

iDRAC reports hardware faults three ways: remote syslog and SNMP traps carry the event, and SNMP polling shows the current state. Using all three means a failed power supply is visible even if the one-shot event message was lost.

### iDRAC configuration

| Setting | Value |
| --- | --- |
| Alerts | Enabled (off by default) |
| Alert actions | Remote System Log and SNMP Trap ticked for all Warning and Critical events in the System Health, Storage and Audit categories |
| Remote syslog | Server 1 = SIEM VM address, port 514. Requires the Enterprise license, which is present |
| SNMP agent | Enabled, SNMPv3 with authentication and privacy, a dedicated read-only user |
| SNMP trap destination | SIEM VM address, port 162, SNMPv3 |
| Time | NTP pointed at the Ground Segment time source |
| Network | iDRAC on the management network; only the SIEM VM needs SNMP access |

These settings can be applied with `racadm` or the Redfish API, so they can live in the infrastructure-as-code repository.

### Hardware events covered

| Component | Events | Dell message ID prefix |
| --- | --- | --- |
| CPU | Machine check, thermal trip, internal error, throttled or disabled | `CPU` |
| Memory | Uncorrectable errors, correctable error rate over threshold, DIMM failed or disabled | `MEM` |
| Physical disks | Failed, predictive failure, removed, inserted | `PDR` |
| Virtual disks and controller | Degraded, failed, rebuild, controller battery | `VDR`, `CTL`, `BAT` |
| Power supplies | Input lost, failed, removed, redundancy lost or restored | `PSU`, `RDU` |
| Cooling and environment | Fan failed, temperature or voltage threshold crossed, chassis intrusion | `FAN`, `TMP`, `VLT`, `SEC` |
| iDRAC access | Logins, failed logins, configuration changes | `USR`, `RAC` |

### SIEM VM side

- **Syslog:** rsyslog writes iDRAC messages to `/var/log/remote/<source>/idrac.log`. The Wazuh manager reads that file with a `localfile` entry.
- **Traps:** snmptrapd loads the Dell iDRAC MIB so traps are written as readable text to `/var/log/remote/snmptrapd.log`. Wazuh reads that file too.
- **Rules:** A custom Wazuh decoder extracts the Dell message ID and severity. Custom rules map Critical events to level 12 (emailed) and Warning events to level 8 (dashboard only).
- **Polling:** snmp\_exporter uses a module built from Dell's `iDRAC-SMIv2` MIB with the exporter's generator. Prometheus scrapes it every 60 seconds.

### Metrics polled

Global system status, power supply status and input voltage, fan status and speed, temperature probes, physical and virtual disk state, memory device status, processor status, system battery and power consumption.

### Limits

- iDRAC only sees drives behind Dell controllers (PERC, Dell HBA, BOSS).
- iDRAC does not know ZFS or software RAID pool health. That comes from the Proxmox host.
- Check whether the stock `snmp.yml` shipped with your snmp\_exporter version already contains a Dell iDRAC module before generating one.

### Additions for the required audit events

- **Logins:** iDRAC session logins, failed logins and logouts are in the Audit category already forwarded by syslog. Wazuh rules classify them as successful and unsuccessful login events.
- **Accounts and roles:** iDRAC user creation, deletion, privilege changes, password changes and two-factor settings are configuration-change events in the same category.
- **Time:** iDRAC uses the Ground Segment time reference as its NTP source.
- **Not available on iDRAC:** Connection logging, malware scanning and a guaranteed 30-day local log. The SIEM VM copy covers retention.

## Proxmox VE integration

The Proxmox host is Debian based, so it takes the Wazuh agent (DEB package) and node\_exporter directly. Guest and storage metrics come from the Proxmox API through pve-exporter running on the SIEM VM, which keeps extra software off the hypervisor.

### Logs collected by the Wazuh agent

| Source | Location | What it shows |
| --- | --- | --- |
| Authentication | journald, or `/var/log/auth.log` where rsyslog is installed | SSH and console logins, sudo, failed logins |
| System | journald, or `/var/log/syslog` | Kernel, hardware, service and storage messages |
| Proxmox web and API access | `/var/log/pveproxy/access.log` | Who called the web interface and API, from where |
| Proxmox daemons | journald units `pvedaemon`, `pveproxy`, `pvestatd` | Web logins and failures, VM start, stop, create, delete, backup and migration tasks |
| ZFS events | journald unit `zfs-zed` | Pool degraded, device faulted, scrub and resilver results |
| Disk health | journald unit `smartd` | SMART warnings and failures |
| Audit | `/var/log/audit/audit.log` (install `auditd`) | Privileged commands and changes to sensitive files |

Recent Proxmox releases log to journald only by default. The Wazuh agent reads journald directly, so rsyslog is not required on the host.

### Security monitoring on the host

- File integrity monitoring on `/etc/pve`, `/etc/network/interfaces`, `/etc/ssh` and `/etc/sudoers.d`.
- The same auditd rule set as the Rocky VMs (see the Rocky section).
- Custom Wazuh rules for Proxmox login failures and for VM deletion or configuration changes.

### Metrics

| Exporter | Runs on | Collects |
| --- | --- | --- |
| node\_exporter | Proxmox host | CPU, memory, disk, network, filesystem, ZFS ARC and pool statistics, hardware sensors |
| prometheus-pve-exporter | SIEM VM | Node and guest status, guest CPU and memory, storage usage, backup state |

pve-exporter authenticates with a dedicated API token on a user holding only the `PVEAuditor` role. The token is created by the infrastructure-as-code run and stored as a secret.

### Notes

- Proxmox package updates can overwrite files outside `/etc`. Keep agent and exporter configuration under `/etc` or `/var/ossec/etc`.
- If the host uses a PERC controller with hardware RAID and not ZFS, the ZFS items do not apply and array health comes from iDRAC alone.

### Additions for the required audit events

- **Audit rules:** The host gets the full rule set from the Rocky section, including permission changes, mounts, privileged programs, all interactive commands and account lock state.
- **Accounts, roles and MFA:** File integrity monitoring on `/etc/pve/user.cfg` and `/etc/pve/priv/tfa.cfg`, plus `pvedaemon` log rules, record Proxmox user, role, permission and second-factor changes.
- **Network traffic:** The Proxmox firewall is enabled at host level with logging on for inbound and outbound rules, and the agent reads `/var/log/pve-firewall.log`. Enabling the firewall on a host that does not use it today needs care; see open decisions.
- **Backup and restore:** Scheduled `vzdump` jobs and any `qmrestore` or `pct restore` run as Proxmox tasks. Wazuh rules classify task results as backup success, backup failure, restore success and restore failure.
- **Malware scanning:** ClamAV from the Debian repository with the same wrapper and result lines as Rocky. VM disk images are excluded from the scan.
- **Local storage:** journald retention 45 days; `pveproxy`, firewall and audit logs rotated to keep 45 days.
- **Time:** chrony uses the Ground Segment time reference.

## Windows Server domain controller integration

The domain controller needs audit policy enabled by Group Policy before Wazuh has anything useful to collect. Windows does not record most of the required events by default.

### Audit policy

Set under Advanced Audit Policy Configuration in the Default Domain Controllers Policy, Success and Failure unless noted. Also enable "Force audit policy subcategory settings to override audit policy category settings".

| Audit goal | Subcategories | Key event IDs |
| --- | --- | --- |
| Logon, logoff, failed logon | Logon, Logoff, Account Lockout, Special Logon | 4624, 4634, 4647, 4625, 4740, 4672 |
| Domain authentication | Kerberos Authentication Service, Kerberos Service Ticket Operations, Credential Validation | 4768, 4769, 4771, 4776 |
| Account changes | User Account Management, Computer Account Management | 4720, 4722, 4723, 4724, 4725, 4726, 4738, 4741, 4743 |
| Privilege escalation | Security Group Management, Sensitive Privilege Use | 4728, 4732, 4756, 4729, 4733, 4757, 4673, 4674 |
| File deletion | File System, Handle Manipulation, plus auditing entries on chosen folders | 4663, 4660, 4656 |
| Directory changes | Directory Service Changes, Directory Service Access | 5136, 5137, 5141, 4662 |
| Audit and policy tampering | Audit Policy Change, Authentication Policy Change | 1102, 4719, 4713, 4739 |
| Process and persistence | Process Creation with command line, Security System Extension, Other Object Access Events | 4688, 4697, 4698, 4702 |
| Services (System log) | Not an audit setting | 7045, 7036 |

### Other Group Policy settings

- Security log maximum size 4 GB, archived when full, with archives kept 45 days. This buffers events if the agent loses contact with the SIEM VM.
- PowerShell script block logging and module logging enabled (event 4104).
- "Include command line in process creation events" enabled.
- Windows Firewall rules allowing outbound 1514 and 1515 to the SIEM VM, and inbound 9182 from the SIEM VM only.

### Wazuh agent configuration

| Item | Setting |
| --- | --- |
| Event channels | Security, System, Application, Directory Service, DNS Server, `Microsoft-Windows-PowerShell/Operational`, `Microsoft-Windows-Windows Defender/Operational` |
| Security channel query | Replace the default query. The default excludes event IDs 4656, 4658, 4660, 4663, 4670, 4690, 4703, 4907, 5145, 5152, 5156, 5157 and 5447 ([default agent configuration](https://github.com/wazuh/wazuh/blob/master/src/win32/ossec.conf)) |
| File deletion | File integrity monitoring in who-data mode on chosen folders, including SYSVOL and NETLOGON. This reports who deleted or changed a file without needing events 4660 and 4663 |
| Registry monitoring | Default Wazuh registry keys plus run keys and service keys |
| Configuration assessment | Wazuh's Windows Server benchmark policy enabled |
| Inventory | Syscollector enabled for installed software, open ports and running processes |

Keep 4660 and 4663 excluded at the agent unless you need the raw Windows events. With folder auditing on, they are very high volume.

### Metrics

windows\_exporter runs as a service with these collectors: `cpu`, `memory`, `logical_disk`, `physical_disk`, `net`, `os`, `system`, `service`, `time`, `ad`, `dns`. It is installed from the MSI carried into the air gap.

### Optional

Sysmon (free from Microsoft Sysinternals) adds process, network and file-creation detail that Wazuh has rules for. Add its channel to the agent if you install it.

### Additions for the required audit events

These settings extend the audit policy above so that every required event is recorded on the domain controller.

| Audit goal | Subcategory or setting | Key event IDs |
| --- | --- | --- |
| Account unlock | User Account Management (already on) | 4767 |
| Role changes through user rights | Authorization Policy Change | 4704, 4705 |
| Permission changes | File System and Registry, with "Change permissions" and "Take ownership" included in the folder auditing entries | 4670 |
| MFA credential changes | Directory Service Changes, with auditing entries on user objects for the credential attributes | 5136 |
| File system mounts | Plug and Play Events; NTFS operational channel | 6416 |
| Allowed and denied connections | Filtering Platform Connection, Success and Failure | 5156, 5157 |
| Dropped packets | Filtering Platform Packet Drop, Failure | 5152 |

- **Agent query:** Stop excluding 4670, 5152, 5156 and 5157 in the Security channel query. The other default exclusions stay.
- **Extra channels:** Windows Server Backup, WMI activity, NTFS operational and Windows Time service.
- **Administrator actions and system information queries:** Covered by process creation auditing for all processes with command line, plus PowerShell script block logging.
- **Malware scanning:** Microsoft Defender Antivirus stays enabled. A scheduled task runs a daily quick scan and a weekly full scan through a wrapper script. The wrapper writes one Application log event per scan with the result `clean`, `infected` or `failed`. Definition updates are carried in with each media transfer.
- **Backup:** Windows Server Backup runs a scheduled system state backup. Its success, failure and recovery events are collected.
- **Local storage:** The Security log is archived when full and not overwritten. A scheduled task removes archives older than 45 days. Size the log volume for 45 days once real volume is known.
- **Time:** Windows Time is configured as an NTP client of the Ground Segment time source, and serves time to every VM. Sync and failure events are collected.

Connection events are the largest new source of volume on a domain controller. Allowed connections are indexed at a low rule level and never emailed; denied connections sit one level higher. If volume is too high after the first week, the fallback is to collect the Windows Firewall log file in place of events 5156 and 5157.

## Rocky Linux VM integration

Each Rocky 9 VM runs the Wazuh agent, node\_exporter and an auditd rule set. Logins and sudo use are logged by default; privilege escalation and file deletion need the auditd rules.

### Logs collected by the Wazuh agent

| Source | Location | What it shows |
| --- | --- | --- |
| Authentication | `/var/log/secure` | SSH logins and failures, logouts, sudo, su, PAM, account changes |
| System | `/var/log/messages` and journald | Kernel, services, hardware messages |
| Audit | `/var/log/audit/audit.log` (format `audit`) | Privileged commands, file deletion, identity file changes, SELinux denials |
| Package changes | `/var/log/dnf.log` | Software installed or removed |
| Application logs | Per-VM list of file paths | File-based logs from workloads; one `localfile` entry each, wildcards allowed |

Per-VM application log paths are a variable in the inventory, so adding a log file is a one-line change.

### auditd rules

| Rule purpose | Audit key | What is watched |
| --- | --- | --- |
| Privilege escalation | `audit-wazuh-c` | `execve` where effective user is root and the login user is a normal account |
| File deletion | `delete` | `unlink`, `unlinkat`, `rename`, `renameat` by login users |
| Identity changes | `identity` | Writes to `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` |
| Sudo configuration | `scope` | Writes to `/etc/sudoers` and `/etc/sudoers.d` |
| SSH configuration | `sshd` | Writes to `/etc/ssh/sshd_config` and `sshd_config.d` |
| Kernel modules | `modules` | `init_module`, `delete_module`, `finit_module` |
| Time changes | `time-change` | `adjtimex`, `settimeofday`, `clock_settime` |
| Audit tampering | `audit-config` | Writes to `/etc/audit` and audit log deletion |

The rules file ends with `-e 2` so rules cannot be changed without a reboot. The Wazuh manager holds a key list that maps each audit key to a rule group.

### Other agent modules

- File integrity monitoring on `/etc`, `/usr/bin`, `/usr/sbin`, `/boot`, in who-data mode for `/etc`.
- Security configuration assessment with the Rocky Linux 9 CIS policy.
- Syscollector inventory, which also feeds vulnerability detection.
- Rootcheck enabled.

### Metrics

node\_exporter runs as a systemd service under its own user, with the `systemd` collector enabled and the textfile collector directory available for custom metrics.

### Host settings

- firewalld allows 9100 from the SIEM VM only.
- SELinux stays enforcing; the role sets the right file contexts and port labels.
- chrony points at the domain controller.

### Kubernetes hosts

Where a Rocky VM runs Kubernetes, the same agent can also read the API server audit log and container log files as file-based logs. Cluster-level metrics are out of scope for this document.

### Additions for the required audit events

These rules and services extend the Rocky baseline so that every required event is recorded on each VM.

| Rule purpose | Audit key | What is watched |
| --- | --- | --- |
| Permission changes | `perm_mod` | `chmod`, `fchmod`, `fchmodat`, `chown`, `fchown`, `lchown`, `fchownat` and the extended attribute calls, by login users |
| File system mounts | `mounts` | `mount`, `umount2` |
| Privileged commands | `privileged` | Execution of every setuid and setgid program. The list is generated on each host at deploy time |
| All interactive commands | `user_cmd` | `execve` by login users. Covers administrator actions and system information queries |
| Account lock and unlock | `faillock` | Writes to the faillock directory and execution of `faillock` |
| Login records | `logins` | Writes to `lastlog` and `tallylog` files |
| MFA enrolment | `mfa` | Token files of the chosen mechanism, set by a variable |

- **Account lockout:** `pam_faillock` is enabled with its audit option so lock events are produced.
- **Firewall logging:** firewalld logs all denied packets. Log rules in the active zone record new accepted inbound connections. A firewalld policy from the host to any zone records new outbound connections. Each rule uses one of the four prefixes in the network traffic table and a rate limit. Messages reach `/var/log/messages` and Wazuh decodes them.
- **Outbound restrictions:** An optional variable turns on an outbound allow-list. It is off by default, so hosts log allowed outbound connections only.
- **Kubernetes nodes:** Where firewalld is not used because the cluster network plugin manages packet filtering, equivalent log-only nftables rules go in a separate table that does not affect cluster traffic.
- **Malware scanning:** ClamAV from EPEL packages carried into the air gap. A systemd timer runs a daily scan of a configurable path list through a wrapper. The wrapper writes one result line per scan to `/var/log/malware-scan.log`: `clean`, `infected` or `failed`. Signature files are refreshed with each media transfer.
- **Vulnerability scanning:** The inventory scan runs daily. The agent reads its own log so scan completion and errors become events.
- **Local storage:** `/var/log/audit` is its own volume. auditd rotates by size and keeps enough files for 45 days. logrotate keeps 8 weekly rotations of the secure and messages logs. journald retention is 45 days. A daily timer writes the age of the oldest audit record to a metric file for node\_exporter.
- **Time:** chrony uses the domain controller as its time source, with a maximum poll interval of about 17 minutes. Sync state is exported by node\_exporter.

Logging every interactive command and every new connection raises volume noticeably. Disk sizes in the SIEM VM section were increased to allow for it and should be confirmed after one week of real data.

## Alerting and dashboards

Everything is indexed and shown on dashboards; only events that need a person are emailed. Wazuh emails security and hardware events, and Alertmanager emails metric conditions, both through the local Postfix relay.

### Events that send email

| Area | Condition | Source |
| --- | --- | --- |
| Audit tampering | Windows Security log cleared (1102), audit policy changed (4719), Linux audit configuration changed | Wazuh |
| Privileged groups | Member added to or removed from Domain Admins, Enterprise Admins, Schema Admins or Administrators | Wazuh |
| Accounts | User created, disabled account enabled, password reset on a privileged account, account locked out | Wazuh |
| MFA | MFA token assigned to or removed from a privileged account | Wazuh |
| Brute force | Repeated failed logons from one source on Windows, SSH, Proxmox or iDRAC | Wazuh |
| Directory attack indicators | Replication request from a host that is not a domain controller; many Kerberos service ticket requests from one account | Wazuh |
| Persistence | New service or scheduled task on the domain controller; new systemd unit or cron entry on Linux | Wazuh |
| Linux privilege | Changes to sudoers or identity files; root command by an unexpected user | Wazuh |
| Network | Burst of denied outbound connections from one host | Wazuh |
| Malware | Malware found; scan unsuccessful; anti-malware not operational | Wazuh and Alertmanager |
| Backup and restore | Backup failed; restore failed; any restore performed | Wazuh |
| Vulnerability scanning | Scan failed; new critical vulnerability found | Wazuh |
| Hardware events | Any iDRAC Critical event: disk, power supply, memory, CPU, fan, temperature | Wazuh |
| Hardware state | iDRAC global status not OK; power supply, disk, fan or memory status not OK for 5 minutes | Alertmanager |
| Storage health | ZFS pool not ONLINE; SMART failure | Wazuh and Alertmanager |
| Availability | Host or exporter down for 5 minutes; Wazuh agent disconnected | Alertmanager and Wazuh |
| Capacity | Filesystem over 85% or predicted full within 24 hours; memory over 90% for 15 minutes; sustained CPU saturation | Alertmanager |
| Time | Clock offset over 1 second; host unsynchronised or not updated for 12 hours | Alertmanager |
| Local log storage | Audit log volume over 80%; oldest local audit record under 30 days old once a host has run for 30 days | Alertmanager |
| SIEM self-health | Indexer, manager or Prometheus data volume over 80%; mail queue growing; Wazuh service down | Alertmanager |

### Wazuh alert settings

- Email threshold: rule level 10 and above. Custom rules in `local_rules.xml` raise the events above to level 10 to 12.
- Email cap: 12 per hour, with the rest grouped, so a burst cannot flood the mailbox.
- Routine logon and logoff events stay at low levels: indexed and searchable, never emailed.

### Alertmanager settings

- One receiver: email through `localhost:25`.
- Grouped by alert name and host; 4-hour repeat interval; resolved notifications on.
- Inhibit rule: a host-down alert suppresses that host's other alerts.

### Dashboards

| Dashboard | Tool | Shows |
| --- | --- | --- |
| Security events overview | Wazuh | Alert volume by level, agent, rule group and MITRE ATT&CK tactic |
| Authentication | Wazuh | Successful and failed logons by user, host and source address; lockouts and unlocks |
| Accounts, roles and MFA | Wazuh | Account creation and deletion, role and group changes, MFA token changes, password resets |
| Active Directory changes | Wazuh | Account, group and policy changes on the domain controller |
| Privilege and audit | Wazuh | sudo and root commands, administrator actions, permission changes, mounts, audit tampering |
| File integrity | Wazuh | Files added, changed and deleted, with user and process |
| Network connections | Wazuh | Allowed and denied connections by host, direction, port and peer |
| Malware and vulnerability scans | Wazuh | Scan results per host, detections, hosts with no successful scan in 7 days |
| Backup and restore | Wazuh | Task results per job, last successful backup per VM |
| Compliance and configuration | Wazuh | Configuration assessment scores per host; vulnerability inventory |
| Hardware health | Grafana | iDRAC status, power supplies, fans, temperatures, disks, memory, power draw |
| Proxmox | Grafana | Node and guest status, CPU, memory, storage, ZFS |
| Linux hosts | Grafana | CPU, memory, disk, network and service state per VM |
| Windows domain controller | Grafana | CPU, memory, disk, services, AD and DNS counters |
| Audit readiness | Grafana | Time sync state per host, age of oldest local audit record, audit volume use, anti-malware service state |
| SIEM health | Grafana | Ingest rate, disk use per volume, mail queue, scrape status |

Grafana dashboards and data sources are provisioned from files in the repository, so they are rebuilt identically on redeploy. Wazuh custom dashboards are exported as saved objects and imported by the deployment.

## Air-gap delivery, versions and licensing

All software is downloaded once on a connected staging machine, checksummed, carried across, and served from a local artifact directory or repository inside the air gap. No host inside the air gap contacts the internet.

### Artifact bundle

| Artifact | Format | Source |
| --- | --- | --- |
| Wazuh central components | `wazuh-offline.tar.gz`, `wazuh-install-files.tar`, install script, GPG key | Wazuh offline download procedure ([offline installation guide](https://documentation.wazuh.com/current/deployment-options/offline-installation/index.html)) |
| Wazuh agents | RPM (Rocky), DEB (Proxmox), MSI (Windows), all at the manager's version | Wazuh package list |
| Wazuh vulnerability feed | CTI snapshot zip | Wazuh CTI API ([offline update](https://documentation.wazuh.com/current/user-manual/capabilities/vulnerability-detection/offline-update.html)) |
| Prometheus, Alertmanager, node\_exporter, snmp\_exporter | Release tarballs with checksums | Prometheus project releases |
| windows\_exporter | MSI | Project releases |
| prometheus-pve-exporter | Python wheels for it and its dependencies | PyPI, downloaded for Python 3.9 on Rocky 9 |
| Grafana OSS | RPM | Grafana downloads |
| ClamAV | RPMs for Rocky (EPEL), DEBs for Proxmox | EPEL and Debian repositories |
| ClamAV signature databases | `main.cvd`, `daily.cvd`, `bytecode.cvd` | ClamAV database mirror |
| Microsoft Defender definitions | Definition update package | Microsoft |
| Dell iDRAC MIB files | MIB files | Dell support site |
| Operating system dependencies | RPMs and DEBs | Internal Rocky and Debian mirrors, or carried in |

The Wazuh offline bundle does not include operating system dependencies. The SIEM VM needs a reachable internal Rocky mirror or those RPMs carried in alongside.

### Versions

| Component | Version to pin | Note |
| --- | --- | --- |
| Wazuh | 4.14.x, latest patch (4.14.9 was released 14 October 2026) | Wazuh 5.0 was pre-release when checked. Stay on 4.14 until 5.0 is stable; 5.x changes agent ports and file paths |
| Everything else | Latest stable at bundle time | Recorded in one versions file with SHA-256 checksums |

Agents must not be newer than the manager. Upgrade the manager first.

### Update procedure

1. Rebuild the bundle on the staging machine with new versions and a fresh vulnerability feed snapshot.
2. Verify checksums after transfer.
3. Run the deployment against the SIEM VM first, then agents and exporters.

The vulnerability feed goes stale between transfers. Refresh it on whatever schedule media transfers allow, or disable vulnerability detection if it cannot be refreshed.

### Licensing

| Component | License | Obligation for unmodified internal use |
| --- | --- | --- |
| Wazuh | GPLv2, Apache 2.0 | None |
| Prometheus, Alertmanager, node\_exporter, snmp\_exporter, pve-exporter | Apache 2.0 | None |
| windows\_exporter | MIT | None |
| Grafana OSS | AGPLv3 | None while unmodified; Grafana Labs states unmodified use is unaffected ([relicensing Q&A](https://grafana.com/blog/qa-with-our-ceo-on-relicensing/)) |
| ClamAV | GPLv2 | None |
| Microsoft Defender Antivirus | Included with Windows Server | Covered by the Windows Server license |
| Sysmon (optional) | Microsoft Sysinternals license | Free to use; not open source |

This is a technical reading of the licenses, not legal advice. Have counsel confirm it if it goes into a compliance record.

## Operations and hardening

The SIEM VM holds the audit trail for the whole environment, so it is hardened and monitored like the systems it watches.

### Hardening

| Area | Control |
| --- | --- |
| Network | firewalld default deny; each port opened only to the source addresses that need it |
| Transport | TLS on the Wazuh dashboard, indexer, API and Grafana; agent traffic is encrypted by Wazuh; SNMPv3 with authentication and privacy |
| Certificates | Wazuh certificates from its certificate tool; Grafana certificate from the internal CA if one exists, otherwise self-signed |
| Credentials | All Wazuh default passwords rotated at install; Grafana admin password set; no default accounts left |
| Secrets | Passwords, SNMP credentials, API tokens and the agent enrollment password stored encrypted in the repository (for example Ansible Vault) |
| Agent enrollment | Password-protected enrollment, so only authorised hosts can register |
| Access | Named accounts with role-based access in Wazuh and Grafana; read-only roles for viewers. LDAP sign-in against the domain controller is optional |
| Host | SELinux enforcing; SSH key-only; the SIEM VM runs its own Wazuh agent, auditd rules and node\_exporter |
| Syslog and traps | Plain UDP from iDRAC stays on the management network; rsyslog accepts only listed source addresses |

### Time

The domain controller, the Proxmox host and iDRAC sync to the Ground Segment time source. Every VM, including the SIEM VM, syncs to the domain controller. Event correlation across hosts depends on it.

### Backup and recovery

| Item | Method | Frequency |
| --- | --- | --- |
| Whole SIEM VM | Proxmox backup job | Weekly |
| Wazuh configuration, rules, decoders, agent keys | File backup of `/var/ossec/etc` to the Proxmox backup store | Daily |
| Indexer data | Indexer snapshot to a local repository path that the VM backup includes | Daily |
| Grafana and Prometheus configuration | Rebuilt from the repository | On deploy |

The repository is the source of truth for configuration. A lost SIEM VM is rebuilt by rerunning the deployment and restoring agent keys and indexer snapshots.

### Routine tasks

- Weekly: review the SIEM health dashboard, disconnected agents and the mail queue.
- Monthly: review rule noise and tune levels; check disk growth against retention.
- Each media transfer: refresh the vulnerability feed and apply pinned updates.
- After any audit policy or rule change: run the validation tests listed in the Claude Code brief.

### Single point of failure

If the SIEM VM is down, nothing sends alerts. Sources buffer in the meantime: Wazuh agents hold a limited event buffer, the Windows Security log and Linux audit logs keep local copies, and the iDRAC Lifecycle log keeps hardware events. A simple external check, such as a scheduled task on another VM that tests the dashboard port and emails on failure, covers this gap.

## Assumptions, open decisions and items to verify

These points were assumed to complete the design. Each one changes the implementation if the answer differs.

### Assumptions

| Topic | Assumed | Change if different |
| --- | --- | --- |
| Infrastructure-as-code tool | Ansible for all host configuration | Role structure in the brief |
| VM provisioning | The SIEM VM already exists or is created by your existing Proxmox tooling | Add a provisioning step |
| Proxmox storage | ZFS on a Dell HBA | Drop ZFS items if hardware RAID on PERC |
| Internal package mirrors | A Rocky 9 mirror and a Debian mirror are reachable inside the air gap | Carry dependency packages in the bundle |
| Time source | The domain controller, Proxmox host and iDRAC sync to the Ground Segment time source; every VM syncs to the domain controller | Time source settings on each host |
| Retention | 90 days searchable, 180 days archived | Disk sizes |
| Wazuh version | 4.14.x | Ports, paths and install steps differ on 5.x |
| Syslog path | rsyslog receives and writes files that Wazuh reads | Wazuh can listen for syslog directly instead |
| Kubernetes | Cluster-level monitoring is out of scope | Add kube-state-metrics and API audit log collection |

Assumptions added with the required audit event list:

| Topic | Assumed | Change if different |
| --- | --- | --- |
| Anti-malware product | Microsoft Defender Antivirus on Windows; ClamAV on Rocky and Proxmox | Log source, wrapper and rules for the product in use |
| Backup product | Proxmox backup jobs for VMs; Windows Server Backup for the domain controller | Log source and rules for the product in use |
| Vulnerability scanner | Wazuh vulnerability detection | Collect the scanner's own result log if another tool is mandated |
| MFA mechanism | Not yet known; credential attribute auditing in AD and file watches on Linux | Exact attributes and files to watch |
| System information query | Any command or script that reads system configuration, covered by logging all interactive commands | Narrow to a list of tools, or widen to API reads |
| Outbound restrictions | None today, so only allowed outbound connections are logged | Enable the outbound allow-list to produce denied events |
| Local retention | Sized for 45 days to stay above the 30-day minimum | Volume sizes |
| Time zone | All hosts log in UTC | Timestamp handling in decoders |

### Open decisions

- [ ] SMTP endpoint: host, port, TLS, authentication, sender and recipient addresses.
- [ ] Network layout: management network for iDRAC and Proxmox, addresses and host names for every system.
- [ ] Which Windows folders and Linux directories need file deletion auditing.
- [ ] Whether Sysmon is allowed on the domain controller.
- [ ] Whether Wazuh and Grafana sign-in should use Active Directory accounts.
- [ ] Per-VM list of application log files to collect.
- [ ] Who receives email, and whether hardware and security alerts go to different people.

* [ ] Which MFA mechanism is used for Windows, Linux, Proxmox and iDRAC logins, if any.
* [ ] Which anti-malware and backup products are mandated, if not the defaults assumed here.
* [ ] Confirm the interpretation of "system information query" with the requirement owner.
* [ ] Address of the Ground Segment time source.
* [ ] Whether to enable the Proxmox firewall at host level for connection logging, or use log-only nftables rules instead.
* [ ] Whether any host should enforce an outbound allow-list.
* [ ] Whether Kubernetes nodes use firewalld, which decides how connection logging is applied there.

### Items to verify during build

- [ ] Dell message ID prefixes and iDRAC menu names against your iDRAC firmware version.
- [ ] Whether the stock snmp\_exporter `snmp.yml` includes a Dell iDRAC module for your version.
- [ ] The default Security channel query in your Wazuh agent version before replacing it.
- [ ] Proxmox log locations and journald unit names against your Proxmox VE version.
- [ ] windows\_exporter collector names against the version in the bundle.
- [ ] Real ingest volume after one week, against the disk sizes above.

* [ ] Windows event IDs for Defender, Windows Server Backup, account unlock, permission change and Filtering Platform against your Windows Server version.
* [ ] Linux audit record types produced for account lock, unlock and group changes on Rocky 9.
* [ ] That firewalld log rules fire once per new connection and not per packet.
* [ ] Exact Wazuh manager log lines for vulnerability scan completion and failure in your Wazuh version.
* [ ] Proxmox firewall log format and task log wording for backup and restore results.
* [ ] Connection and command event volume after one week, against disk sizes and the 30-day local retention.

### Sources

- [Wazuh quickstart: hardware and operating system requirements](https://documentation.wazuh.com/current/quickstart.html)
- [Wazuh offline installation guide](https://documentation.wazuh.com/current/deployment-options/offline-installation/index.html)
- [Wazuh offline vulnerability detection](https://documentation.wazuh.com/current/user-manual/capabilities/vulnerability-detection/offline-update.html)
- [Wazuh alert management: email and syslog output](https://documentation.wazuh.com/4.8/user-manual/manager/alert-management.html)
- [Wazuh 4.14.9 release notes](https://documentation.wazuh.com/4.14/release-notes/release-4-14-9.html)
- [Wazuh default Windows agent configuration](https://github.com/wazuh/wazuh/blob/master/src/win32/ossec.conf)
- [Detecting threats in an air-gapped environment with Wazuh](https://wazuh.com/?p=34191)
- [Grafana Labs Q&A on AGPLv3 relicensing](https://grafana.com/blog/qa-with-our-ceo-on-relicensing/)

Wazuh facts above were checked against these pages. iDRAC, Proxmox, Windows audit and exporter details come from general product knowledge and are listed under items to verify.

## Claude Code brief

The implementation brief is on its own tab so it can be copied or exported by itself: Claude Code brief. It restates the architecture, constraints, deliverables and acceptance tests without relying on this tab, and lists the questions Claude Code should ask before planning.

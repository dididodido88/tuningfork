# Handoff: SIEM and observability stack

Status on 2026-11-20: Phases 1 through 4a are built and tested in the **lab** environment. Work is paused before
Phase 4b. Everything is committed on `main` and pushed to `origin`.

The user's guide is [ansible/docs/siem.md](ansible/docs/siem.md). Conventions and gotchas for this repository are in
[CLAUDE.md](CLAUDE.md).

## Goal

One SIEM VM per environment (lab, CRGS00, CRGS01, CRGS02) runs these:

- Wazuh 4.14 all-in-one: indexer, manager and dashboard
- rsyslog and snmptrapd receivers
- Prometheus, Alertmanager, snmp_exporter and pve-exporter
- Grafana
- a Postfix relay

Wazuh agents and exporters report to it from four kinds of host:

- the Rocky 9 VMs
- the Proxmox VE 9 cluster
- the Windows domain controllers
- the Dell iDRACs

The brief also asks for detection content mapped to the required audit event groups, dashboards, and acceptance tests
1 to 19 driven by a validation playbook.

### Hard constraints from the brief

- **Air gap.** Nothing is downloaded from the internet on any target. Every artifact comes from the mirror
  (`https://maestro`, served from `/repo`).
- **Licensing.** Only free software, used unmodified.
- **Pinning.** Every version and SHA-256 is pinned in `inventories/<ENV>/group_vars/all/siem_versions.yml`.
- **Idempotence.** A second run must report `changed=0`.
- **Secrets.** No plaintext secrets. They live as `vault_*` keys in `inventories/<ENV>/group_vars/all/vault.yml`.
  The user edits the vault; Claude never does.
- **Hardening stays on.** SELinux stays enforcing and firewalld stays enabled.
- **Email is best effort.** It must never block or fail a service.
- **Agent versions.** Wazuh agents are never newer than the manager.
- **Requirement identifiers.** Audit requirements are referred to by title only. A requirement identifier in square
  brackets must never be written anywhere: `ansible/scripts/check-no-requirement-ids.sh` enforces this.
- **Local retention.** Every host keeps at least 30 days of its own audit logs locally.

### Working method

- **The user runs everything.** Claude can't reach the air-gapped hosts. Claude writes code and commits it, then
  gives exact commands. The user runs them on `maestro` (the control node, checkout `/srv/tuningfork`) and pastes the
  output back.
- **One phase at a time.** A phase is tested until its second run reports `changed=0` before the next one starts.
- **Version-dependent behaviour is checked, not guessed.** For example, ask for `--help` output or the default config
  files.
- **Conflicts are flagged.** Raise any conflict between the brief and the repository.

## Done

| Phase | What | Key commits |
|---|---|---|
| 1 Artifacts | 18 artifacts are pinned. The list is printed by `playbooks/siem_download_list.yml`. The user downloads on an internet machine and uploads to `/repo/<path>` on maestro. `roles/siem_artifacts` downloads each one and checks its sha256. The iDRAC module is the stock `dell` module from snmp_exporter's own `snmp.yml`. | `1ff3850`, `ffa2000`, `88dbf41`, `ef8acfd` |
| 2 SIEM VM core | `sentinel.lab.local` (192.168.70.74; Terraform `terraform_sentinel.yml`; data disks for the indexer, `/var/ossec`, Prometheus, remote logs and audit). `roles/wazuh_server` installs offline and sets the vault passwords. The dashboard uses the host certificate. `ossec.conf` is templated from the 4.14.10 default and sets email, archives (`logall_json`), the enrollment password and the offline vulnerability feed. The API listens on 127.0.0.1 only. `roles/postfix_relay` relays loopback-only mail. | `c7463c9` to `12c3d5c` |
| 3 Collectors | These are `syslog_receiver` (514), `snmp_trap_receiver` (162, SNMPv3 only), `node_exporter`, `prometheus`, `alertmanager`, `snmp_exporter`, `pve_exporter` and `grafana` (https://sentinel.lab.local:3000). Wazuh reads `/var/log/remote/*/*.log`. | `8288b27`, `80cbe0c`, `bde9c2e` |
| 4a Agents | These are `wazuh_agent_linux` (RPM/DEB) and node_exporter on the monitored hosts. `proxmox_monitoring` creates the PVEAuditor user and API token. pve-exporter trusts the Proxmox cluster CA. | `010f756` to `fd86405` |

### Lab state at the pause

- **Wazuh agents.** Agents 001 to 008 are active: `nas`, `pve1`, `db`, `pss`, `mgmt`, `pve3`, `pve4` and `pve2`.
  The manager is agent 000.
- **Prometheus targets.** There are 19 targets, 16 up and 3 down. The down ones are `registry`, `lb-app` and
  `lb-rancher`, which were unreachable during the agent run.
- **Proxmox scraping.** Proxmox is scraped per node (`pve-node`) and cluster-wide from `pve1` (`pve-cluster`).
- **Syslog path.** Tested end to end, from `pve1` through rsyslog to the Wazuh archive.
- **Vulnerability feed.** It loads from the local snapshot ("Feed update process completed").
- **Grafana.** The admin login works.
- **Vault keys in use (lab):**
  - `vault_wazuh_indexer_admin_password`
  - `vault_wazuh_api_password`
  - `vault_wazuh_enrollment_password`
  - `vault_grafana_admin_password`
  - `vault_pve_exporter_token_value`
- **Vault keys not set yet:**
  - `vault_snmp_idrac_auth_password` and `vault_snmp_idrac_priv_password` (Phase 6)
  - `vault_postfix_relay_password` (only needed if the relay needs a login)

## Decisions made

| Decision | Why |
|---|---|
| **Artifact layout.** Each artifact has an explicit `path` relative to `env_repo_base_url` (`wazuh/`, `prometheus/`, `grafana/`, `mibs/idrac9/`, `clamav/<date>/`). | It matches how the user uploads by hand. The user rejected an automated bundle script. |
| **iDRAC metrics** use the stock snmp_exporter `dell` module, unmodified. | It already covers status, power, cooling, temperature, memory, CPU and disks. No generator is needed. |
| **No Wazuh agent on the SIEM VM.** | The manager and agent packages conflict, and the manager monitors itself as agent 000. |
| **Offline install uses `-o` only when nothing is there.** `wazuh-install.sh -o` is passed only if no Wazuh package is installed and the Wazuh folders are empty. | The installer treats the empty data-disk mount points as "already installed". |
| **Indexer settings live in a systemd drop-in.** The temporary folder (`OPENSEARCH_TMPDIR` on the indexer's data disk) and the heap are set there. | `/tmp` is noexec under CIS, which broke JNA. The installer's `-o` deletes `/etc/wazuh-indexer`, so a drop-in is the only place that survives. |
| **CIS 6.2.1.4 is off for `siem_servers` only.** | The SIEM VM is the designated log host and runs rsyslog. |
| **Rocky VMs use journald only, with no rsyslog.** The agent reads journald and `audit.log`. | CIS keeps journald, set to 90 days. |
| **Proxmox access is `root` over SSH** with `/root/.ssh/ansible` (set in `ansible.cfg`), without become. node_exporter binds to the management IP. | That is how the Proxmox hosts are reached, and the Proxmox firewall is out of scope. |
| **`k8s_nodes` (rancher01-03, node01-03) get the Wazuh agent but not node_exporter.** | Rancher's monitoring may use port 9100. |
| **pve1 to pve4 are one cluster.** Cluster-wide metrics come from the first host only. | Prometheus can't fail over between targets. |
| **Prometheus jobs for iDRAC and Proxmox are added only once their credentials are in the vault.** | This avoids false TargetDown alerts. |
| **Python 3.12+ targets download with curl.** On Proxmox the role uses curl, then checks the sha256. | ansible-core 2.14's `get_url` breaks on Python 3.12+ targets. |
| **Grafana's RPM and the Wazuh agent packages install with the GPG check off.** | The vendor keys aren't on the hosts. The sha256 pin is the integrity check. |
| **CRGS SIEM disks are 300/100/100/50/20 GB** (indexer, `/var/ossec`, Prometheus, remote logs, audit). Lab uses 100/40/40/20/10 GB. | These sizes are from the approved plan. The user's design document (`ansible/docs/siem/siem_design.md`) lists 250/60/30/20 with no audit disk; the user hasn't chosen yet. |

## Open issues

1. **Unreachable hosts.** These hosts were unreachable over SSH in Phase 4a:
   - `registry`
   - `lb-app` and `lb-rancher`
   - `rancher01` to `rancher03`
   - `node01` to `node03`

   When they're up, run `playbooks/siem_agents.yml --limit '<those hosts>'`, then `playbooks/siem.yml`. That
   clears the 3 down Prometheus targets.
2. **Leftover file.** `ansible/roles/siem_artifacts/tasks/manifest.yml` was deleted in `1ff3850` but is back in
   git and is used by nothing. Ask the user, then remove it.
3. **Stray folder.** Done: the stray `roles/RHEL9-CIS/` at the repository root is removed.
4. **Lint warning on maestro.** maestro's copy of `ansible/playbooks/site.yml` has a comment without a space at
   line 30 (yamllint warning). It's a local change on maestro, not in git.
5. **Placeholders (CHANGEME) still to fill:**
   - The SIEM VM addresses for the CRGS environments use the documentation ranges 192.0.2.x, 198.51.100.x and
     203.0.113.x.
   - `siem_mail_to` is empty in every environment, so email is off.
   - The SMTP relay must be confirmed: lab is set to `smtp.lab.local`.
   - The Ground Segment time source (`env_gs_time_sources`) isn't defined yet. Phases 4b and 5 need it.
6. **Timestamps.** Proxmox stamps syslog in local time, while `sentinel` is in UTC. Alerts use the receive time,
   so this is harmless. Ask whether the Proxmox hosts should be set to UTC.
7. **Not built yet. These belong to Phase 7:**
   - the Wazuh index retention policies (ISM: alerts 90 days, archives 180 days)
   - cleanup of the archive files in `/var/ossec/logs/archives`
   - the indexer security audit log, and Wazuh reading the Grafana and API logs
   - the Postfix queue metric
8. **Older ansible-core.** The control node has ansible-core 2.14. A newer version (2.16 or later) would remove the
   curl workaround and make `uri` work against Python 3.12+ hosts. It isn't required.
9. **Proxmox firewall and connection logging** are excluded by the user's decision. This is recorded as an open
   item in the docs.

## Next steps

### Phase 4b: hardening and logging on the monitored Linux hosts

Use the user's design document `ansible/docs/siem/siem_design.md` (sections on Rocky and Proxmox audit rules,
malware scanning and backups) and the approved plan for the details.

- **`auditd_rules`** (rocky9 and proxmox_hosts) writes `/etc/audit/rules.d/50-tuningfork.rules`. It covers these
  keys:
  - `perm_mod`, `mounts`, `privileged`, `user_cmd`, `faillock`, `logins`, `mfa` and the baseline keys
  - `privileged` uses a list of setuid and setgid programs generated per host with `find`
  - `mfa` uses an empty path list
  - Proxmox also gets `/etc/pve/priv/tfa.cfg` and `/etc/pve/user.cfg`

  Rocky already has CIS's `99_auditd.rules` with `-e 2`, so this role must not add a second one. Proxmox: install
  auditd from the Debian mirror and add `99-zz-finalize.rules` with `-e 2`. New rules need a reboot. Never reboot
  unless `siem_allow_reboot: true` (default false); instead warn and write a node_exporter textfile metric. On
  Proxmox, add an agent `<localfile>` for `/var/log/audit/audit.log`; Rocky's agent already reads it.
- **`local_log_retention`** keeps CIS's `keep_logs`. It adds a daily timer that deletes rotated `audit.log.N` files
  older than 45 days, and a metric with the age of the oldest audit record. On Rocky it adds the `audit` option to
  `pam_faillock`. Journald stays at 90 days.
- **`firewall_logging`** (rocky9):
  - firewalld `LogDenied`
  - rich rules logging inbound connections, with the `FW-IN-ALLOW` and `FW-IN-DENY` prefixes
  - a host-to-any policy with `FW-OUT-ALLOW` and `FW-OUT-DENY`, rate-limited
  - the outbound allow-list variable, off by default

  Mind the volume on the Kubernetes nodes.
- **`clamav`** (rocky9 from EPEL, Proxmox from Debian):
  - the signatures come from the checked artifacts `clamav_main`, `clamav_daily` and `clamav_bytecode`
  - a daily scan timer runs through a wrapper that writes `/var/log/malware-scan.log`
  - VM images are excluded on Proxmox
- **`linux_backup`** is opt-in. A tar of `linux_backup_paths` goes to NFS (placeholder). A `tuningfork-restore`
  script is added. Both log `result=ok|failed` to `/var/log/backup.log`.

### Later phases

- **Phase 5, Windows DC.**
  - **Ask the user for:** `wevtutil el`, the Windows Server version, `windows_exporter --help` and
    `auditpol /list /subcategory:*`.
  - **Build these roles:**
    - `windows_dc_audit`: the GPO "Tuningfork DC Audit", SACLs and W32Time. The PDC emulator syncs to the Ground
      Segment source; the other DCs use NT5DS.
    - `wazuh_agent_windows` (MSI, group `windows-dc`)
    - `windows_exporter` (MSI, firewall 9182 from the SIEM VM only)
    - `windows_defender_scan`
    - Windows Server Backup, behind `windows_dc_backup_enabled: false`
- **Phase 6, iDRAC.**
  - **Ask the user for:** a dump of `GET /redfish/v1/Managers/iDRAC.Embedded.1/Attributes`, filtered to SNMP,
    SysLog, NTP, users and event filters.
  - **Build `idrac_config`:** Redfish via `uri` from the control node (`group_vars/idrac.yml` already sets
    `ansible_connection: local`). It configures syslog to the SIEM VM on 514, and SNMPv3 traps to it on 162. It
    creates the read-only SNMPv3 users: `siem_idrac_snmp_username` for polling, and the trap user. The traps need
    each iDRAC's engine ID in `siem_snmp_trap_users`. End with a test event and a test trap.
- **Phase 7, detection content and dashboards.**
  - **Wazuh content (`wazuh_content`):**
    - `local_decoder.xml` and `local_rules.xml`, with rule IDs 100000 to 109999, covering every required audit event
      group
    - the shared `agent.conf` files for the agent groups `linux`, `proxmox` and `windows-dc`
    - the Wazuh dashboards and the ISM policies
  - **Prometheus and Grafana:**
    - the Prometheus alert rules
    - Grafana dashboards: hardware, Proxmox, Linux, Windows DC, SIEM health and audit readiness
  - **Mapping document:** `docs/siem-audit-events.md`.
- **Phase 8, validation.** Build `playbooks/siem_validate.yml`, tagged per acceptance test 1 to 19. Add the
  remaining sections to `docs/siem.md`: adding a VM, adding a log file, restoring the SIEM VM, and the open items.

## Resuming

The first run, on maestro from `/srv/tuningfork/ansible`, after `git pull`:

```sh
yamllint . && ansible-lint && scripts/check-no-requirement-ids.sh
ansible-playbook -i inventories/lab playbooks/siem.yml          # SIEM VM, expect changed=0
ansible-playbook -i inventories/lab playbooks/siem_agents.yml   # agents and exporters
```

Checks on the SIEM VM:

```sh
/var/ossec/bin/agent_control -l
curl -s 127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
```

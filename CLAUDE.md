# CLAUDE.md

This repository holds infrastructure code for air-gapped environments: **lab**, **CRGS00**, **CRGS01** and **CRGS02**.
Terraform/Terragrunt (bpg/proxmox) creates the Rocky 9 VMs, and Ansible hardens and configures them. Overview:
[README.md](README.md). For SIEM work in progress, read [HANDOFF.md](HANDOFF.md) first.

## How we work

- **The user runs everything.** Claude can't reach the air-gapped hosts. Claude writes code and commits it on `main`,
  then gives the exact commands to run on the control node `maestro` (checkout `/srv/tuningfork`, run from
  `ansible/`). The user pastes the output back. The user pushes to GitHub.
- **Work in tested phases.** Finish and test one phase before starting the next. A phase is done when its second run
  reports `changed=0`.
- **Don't guess version-specific behaviour.** Ask the user for `--help` output, default config files or a grep of the
  vendor script, then write the code.
- **Flag conflicts** between a request and the repository instead of silently picking one.
- **Ask before changing what the user decided:** their inventory edits, Terraform-managed hosts, vault contents. The
  user edits the vault (`ansible-vault edit`); Claude never writes it.
- **Downloads are manual.** Large artifacts are downloaded by the user on an internet machine and uploaded to the
  mirror. Give them a list, not a download script.

## Hard rules

- **No downloads from the internet on any target.** Every package, binary, wheel, MIB and feed comes from the mirror
  `env_repo_base_url` (`https://maestro`, served from `/repo` on maestro). Every SIEM artifact is pinned by version
  and sha256 in `inventories/<ENV>/group_vars/all/siem_versions.yml` and checked by `roles/siem_artifacts` before use.
- **Use only free software, unmodified.** Don't patch upstream code.
- **No plaintext secrets.** Put them in `vault_*` keys in `inventories/<ENV>/group_vars/all/vault.yml` and reference
  them from role defaults (`foo_password: "{{ vault_foo_password | default('') }}"`). Use `no_log: true` on any task
  that handles a secret.
- **Keep the hardening on.** SELinux stays enforcing and firewalld stays enabled. Open ports with firewalld rich rules
  limited to the networks that need them.
  - One exception, decided by the user: firewalld is off on RKE2 nodes (`rke2_servers`), as RKE2 and Rancher document,
    because it conflicts with RKE2's network plugin. The CIS firewall rules are off there
    (`playbooks/group_vars/rke2_servers.yml`), and network segmentation is the compensating control
    (`ansible/docs/rancher.md`, "Firewall exception and segmentation"). Every other host, load balancers included,
    keeps firewalld.
  - Also decided by the user: the CIS world-writable files control is off on RKE2 nodes, because kubelet and
    containerd own those files. It stays on everywhere else.
- **Refer to audit requirements by title only.** Never write a requirement identifier in square brackets, anywhere.
  `ansible/scripts/check-no-requirement-ids.sh` must pass.
- **Email is best effort** and must never block or fail a service.
- **Wazuh agents** are never newer than the manager. A single `wazuh_version` drives both.

## Repository conventions (Ansible)

- **Inventories** live in `ansible/inventories/<ENV>/`: `hosts.yml`, Terraform-generated `terraform_*.yml` (never edit
  these; they are generated), `group_vars/` and `host_vars/`. Settings shared by every environment go in
  `ansible/playbooks/group_vars/`.
- **Roles.**
  - Each role lives in `ansible/roles/<name>`.
  - Task names start with a short component prefix, such as `Wazuh | ...` or `Prometheus | ...`.
  - Tasks carry the role's tag.
  - `defaults/main.yml` documents every option in plain prose at the top.
  - Internal values go in `vars/main.yml`.
- **Playbooks.** There is one playbook per role in `ansible/playbooks/` (`rke2_server` has one per cluster:
  `rke2_rancher.yml`, `rke2_app.yml`). `site.yml` imports them in layer order: certificates, repositories,
  filesystems, cloud-init cleanup, CIS, common, server roles, load balancers, the RKE2 clusters (Rancher, then
  application), `siem.yml` (SIEM VM), `siem_agents.yml` (monitored hosts).
- **Mirror downloads.** Playbooks that download from the mirror run `certificates` `verify_trust` as a pre_task, on
  RedHat hosts only.
- **Firewall.** Each role that opens a port has `<role>_manage_firewall` and uses
  `zone: "{{ rhel9cis_default_zone | default('public') }}"`.
- **Data disks.** They come from Terraform (`filesystems_volumes__terraform`) or from `host_vars`
  (`filesystems_volumes__host`). The `filesystems` role mounts them.
- **SIEM artifacts.**
  - Download them with `include_role: siem_artifacts` and `siem_artifacts_required: [keys]`. Local paths come back in
    `siem_artifact_paths`.
  - Install release tarballs with `include_role: siem_artifacts, tasks_from: install_binaries`. It sets
    `siem_install_changed` and `siem_install_dir`.
- **Lint before handing over.** Run `yamllint .`, `ansible-lint` (with `offline: true`) and
  `scripts/check-no-requirement-ids.sh`. Lines are at most 160 characters.
  - For a deliberate exception, add an inline `# noqa: <rule>` with a one-line reason above the task. Tasks inside
    nested blocks don't honour `noqa`; use `ansible/.ansible-lint-ignore` for those.
  - The linters skip vendored content, the vault files and the `terraform_*.yml` files.
- **Commits.** Explain the why in the commit message body.

## Environment facts that bite

- **Old ansible-core on the control node.**
  - The control node runs ansible-core 2.14 with vendored collections: ansible.posix, community.general,
    community.crypto, ansible.windows, community.windows.
  - No other collections are available.
  - `get_url` and `uri` fail against Python 3.12+ targets (Proxmox VE 9 / Debian 13): `siem_artifacts` falls back to
    curl there.
- **CIS (vendored ansible-lockdown RHEL9-CIS) on the Rocky VMs has side effects:**
  - root's umask is 027, so files created by `pip`, `venv` or installers are root-only. Fix modes explicitly.
  - `/tmp` and `/var/tmp` are mounted noexec.
  - journald is the only log system. Control 6.2.1.4 stops rsyslog, except on `siem_servers`.
  - auditd ends with `-e 2`: new audit rules load only after a reboot.
  - The MTA is set to loopback-only.
- **SELinux.** Programs under `/opt` are `usr_t`. Install binaries to `/usr/local/bin`, or label them `bin_t` with
  `community.general.sefcontext`. Confined daemons such as snmptrapd need their log folder labelled with their log
  type.
- **Proxmox hosts** (`proxmox_hosts`) are Debian 13. Ansible reaches them as `root` over SSH with
  `/root/.ssh/ansible` (set in `ansible.cfg`), without become. There is no sudo on them.
- **iDRACs** (`idrac` group) use `ansible_connection: local`. They are configured through Redfish from the control
  node.
- **Wazuh 4.14 quirks:**
  - The installer treats any existing Wazuh folder (including data-disk mount points) as an earlier installation.
  - The installer resolves its own folder through symlinks and rewrites itself, so copy it rather than linking it.
  - The installer's `-o` deletes `/etc/wazuh-indexer`.
  - `ossec.conf` has two `<ossec_config>` blocks, so template it rather than editing it with the xml module.

## Ansible and Jinja pitfalls seen here

- **`ansible_managed`** exists only in `template`, not in `copy` `content:`.
- **Role defaults pulled in with `include_role`** aren't visible to the caller afterwards. Use `set_fact` to pass
  values back.
- **`vars:` on a `block`** don't reach tasks outside that block. Put them on the `include_tasks`.
- **Jinja `set` inside `for`** doesn't persist; use `namespace()`.
- **Avoid backslashes in Jinja string literals.** Use a variable, or a filter such as `replace`, `regex_findall` or
  `' ' in x`.
- **API bodies for `uri`:** build them with `| to_json` so that numbers and booleans keep their JSON types. Write a
  nested dict's closing braces as `} }` so ansible-lint doesn't misread them.
- **Don't edit task names with `sed` using `|` as the delimiter.** Task names contain `|`, and this has corrupted
  files twice. Use the Edit tool, or `awk` with exact string matching.
- **Debian package versions** carry a revision (`4.14.10-1`). Strip it before comparing with `version()`.

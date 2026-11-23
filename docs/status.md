# Status: assumptions and open work

What the code takes for granted, what is still to do, and what this documentation review found.
Last reviewed: 2026-11-22. Update this page when an item is done or a new one appears.

The SIEM has its own detailed tracker, [HANDOFF.md](../HANDOFF.md). This page only summarises it.

## Assumptions

The code relies on these and doesn't check all of them.

**Platform**
- Proxmox VE 9 (Debian 13) hosts the VMs. Terraform uses `bpg/proxmox` 0.122.0 from a local plugin
  directory (`/root/.terraform.d/plugins` on maestro). The Proxmox API token is in
  `PROXMOX_VE_API_TOKEN`.
- Every Linux VM is cloned from the template `rocky9-chrgs-template-v2`. It must have root with an
  authorised SSH key, cloud-init, and no SCSI disk other than `scsi0`
  ([terraform/README.md](../terraform/README.md), "Template requirements").
- The control node `maestro` runs ansible-core 2.14 with only the vendored collections
  (ansible.posix, community.general, community.crypto, ansible.windows, community.windows).

**Network and services outside this repository**
- `maestro` serves the mirror at `https://maestro` from `/repo`, with a certificate from the
  internal CA.
- The internal CA and the host certificates exist beforehand under
  `/srv/security/certificates/files/<domain>/` on maestro (`roles/certificates`).
- Active Directory provides DNS and logins. These records must exist before the plays that check
  them:
  - `registry.<domain>`;
  - `rancher.<domain>` on lb-rancher's virtual IP;
  - `command-pro.<domain>` on lb-app's virtual IP;
  - a record for every host.
- An upstream SMTP relay exists, and email stays best effort. Today `siem_mail_to` is empty
  everywhere, so no email is sent.
- Network segmentation outside the hosts protects the RKE2 nodes, which run without firewalld. The
  flows to allow are in [ansible/docs/rancher.md](../ansible/docs/rancher.md).

**Process**
- Someone downloads every artifact by hand on an internet machine and copies it to `/repo` on
  maestro. Every artifact's version and sha256 are pinned in the inventory.
- Container images are pushed to Harbor's `rancher` project by an administrator. The clusters
  pull them with the robot `robot$k8s-pull`.
- The user edits the vault (`ansible-vault edit`) and runs every command. The code never writes
  secrets.

## Open work

Owner "user" means a decision, a download, an apply or a run on maestro. Owner "code" means a
change to this repository.

### Kubernetes

| Item | Owner | State |
|---|---|---|
| Rancher Server v2.15.3, part 1: point `chart_path` at the new chart. It is still `rancher-2.12.3.tgz` in all four `terraform/k8s/*/rancher-server` units and in the `variables.tf` example. | code | Paused at the user's request |
| Rancher Server v2.15.3, part 2: check the chart. `kubeVersion` in `Chart.yaml` must accept 1.36, and `values.yaml` must still take `ingress.ingressClassName` and `tls.source` | user | The commands are in the paused plan |
| Rancher Server v2.15.3, part 3: push the images from `rancher-images.txt` to Harbor, then `terragrunt apply` | user | |
| Application cluster, managed mode: join through Rancher's registration command with the `rancher2` Terraform provider | code | Not built; `app_cluster_rancher_managed: false` everywhere |

### Environments

| Item | Owner | State |
|---|---|---|
| Lab values still marked `# REPLACE` but in use: the Proxmox endpoint and node in `env.hcl`, the RKE2 node addresses, lb-app's virtual IP | user | Confirm each one and remove the marker |
| CRGS00/01/02: every `REPLACE` and `CHANGEME`. These are the Proxmox settings, addresses (documentation ranges 192.0.2.x, 198.51.100.x, 203.0.113.x), RKE2 version and checksums, and SIEM settings. | user | Not built yet |
| `support` VM (lab: `pss`): Terraform creates it in group `support_servers`, but no Ansible role configures Keycloak or the basemap server | code | Not started |

### SIEM ([HANDOFF.md](../HANDOFF.md) has the details)

| Item | Owner |
|---|---|
| Phase 4b: hardening and logging on the monitored Linux hosts | code |
| Phase 5: Windows domain controllers (audit policy, Wazuh agent, windows_exporter) | code, after the user supplies output from the hosts |
| Phase 6: `idrac_config`. It would configure the iDRACs over Redfish: syslog, SNMPv3 traps and polling users. The `idrac` group exists, but this role doesn't yet. | code, after the user supplies a Redfish attribute dump |
| Phase 7: detection content, alert rules and Grafana dashboards. `grafana_dashboards_dir` and the rules folder are empty apart from `TargetDown`. | code |
| Phase 8: validation playbook and the remaining guide sections | code |
| Placeholders: SIEM addresses for the CRGS environments, `siem_mail_to`, the SMTP relay, the Ground Segment time source | user |

## Found in this review (not changed)

These are behaviour issues, not documentation issues, so they were recorded and not fixed.

| Finding | Where | Suggested fix |
|---|---|---|
| Lab `terraform_nas.yml` was generated before the rename from NFS to NAS server, so it puts `nas.lab.local` in group `nfs_servers`. `playbooks/nas_server.yml` targets `nas_servers` and so skips the host. | `ansible/inventories/lab/terraform_nas.yml` (generated) | Run `terragrunt apply` in `terraform/live/lab/nas` to regenerate it |
| `snmp_exporter_module` is defined but no task reads it; the Prometheus `idrac` job names `dell` itself | `ansible/roles/snmp_exporter/defaults/main.yml`, `roles/prometheus/templates/prometheus.yml.j2` | Use the variable in the template, or remove it |
| `roles/siem_artifacts/tasks/manifest.yml` is not included by anything (also in HANDOFF.md) | `ansible/roles/siem_artifacts/tasks/` | Remove it, after you confirm |

Fixed since the review:

- **NAS firewall.** NFS is now open only to `nas_server_firewall_sources`, with one rich rule per
  source and service. Lab allows `192.168.70.0/24`. The CRGS values are placeholders.
- **NAS exports.** Each environment exports the five Terraform data disks under `/export/`, to the
  same networks as the firewall. Every export uses `rw,sync,root_squash`.
- **Stray folder.** The `roles/` folder at the repository root, which held only a compiled Python
  file, is removed. `.gitignore` now ignores `__pycache__/` and `*.pyc`.
- **Rancher cluster (lab) is idempotent.** On 2026-11-23 a repeat run of
  `site.yml --limit 'lb_rancher:rke2_rancher'` reported `changed=0` on all four hosts. Three fixes
  got it there: the journald folder mode now matches CIS, the CIS facts file is off, and
  `restorecon` no longer counts container files it leaves alone. The CIS world-writable files
  control is also off on RKE2 nodes.
- **Application cluster (lab) is installed and idempotent.** On 2026-11-23, in standalone mode,
  `site.yml --limit 'lb_app:rke2_app'` reported `changed=0` on all four hosts. It took three or
  four runs to get there, not two, and the cause hasn't been looked at.
- **Lint exceptions.** The `curl` exception is in `ansible/.ansible-lint-ignore`, because the task
  is inside a block. The `systemctl` one has an inline `noqa`, because its task isn't.

## How the documentation was checked

- **Generated from the code.** Each role README was written from that role's tasks, defaults and
  templates. The variable map comes from a search for every `vault_*` reference.
- **Checks run here:** `scripts/check-no-requirement-ids.sh` passes, every relative link in the
  Markdown files points at an existing file, and the commits change only comments and Markdown.
- **Checks to run on maestro.** yamllint, ansible-lint and `terraform fmt` aren't installed on the
  workstation where this was written:
  ```sh
  cd /srv/tuningfork/ansible && yamllint . && ansible-lint && bash scripts/check-no-requirement-ids.sh
  cd /srv/tuningfork/terraform && terraform fmt -check -recursive
  ```

# Where variables live

This page answers "where do I set X?" for the Ansible side, and shows which values Terraform
writes for Ansible. Each role's own options are listed in `roles/<role>/README.md` and
`roles/<role>/defaults/main.yml`. This page covers the files that set them.

## Precedence

Ansible merges variables from many places. These are the ones this repository uses, from lowest
to highest. A later place wins over an earlier one:

| # | Place | Holds |
|---|---|---|
| 1 | `roles/<role>/defaults/main.yml` | Every option of a role, with its default and a description. |
| 2 | `inventories/<ENV>/group_vars/all/*.yml` | Environment-wide settings: `main.yml`, `siem.yml`, `siem_versions.yml`, and the secrets in `vault.yml`. |
| 3 | `playbooks/group_vars/all.yml` | Not used today. |
| 4 | `inventories/<ENV>/group_vars/<group>.yml` | Settings of one group in one environment. A more specific group wins over its parent, for example `rke2_rancher` over `linux`. |
| 5 | `playbooks/group_vars/<group>.yml` | Rules that must hold in **every** environment. These win over the inventory, so keep the files small. |
| 6 | Host variables in the inventory files: `hosts.yml` and the Terraform-generated `terraform_<unit>.yml` | Address, Proxmox VM ID, data disks, load balancer virtual IP. |
| 7 | `inventories/<ENV>/host_vars/<host>.yml` | Exceptions for one host. |
| 8 | `roles/<role>/vars/main.yml` | Internal values. These win over every inventory file, so they aren't meant to be changed per environment. |
| 9 | `-e` on the command line | One-off overrides. |

Two consequences:

- **The vault doesn't win by itself.** `vault.yml` is just another file in `group_vars/all`.
  Secrets don't need to win, because roles read them by name: a default such as
  `foo_password: "{{ vault_foo_password | default('') }}"` picks up the vault key.
- **Settings the CIS play also reads** (`linux_common_*`) must be in `group_vars/linux.yml`, not
  only in role defaults. The CIS play doesn't load the `linux_common` role.

## Inventory files, one environment

The `lab` names are shown. The CRGS environments have the same files.

### `inventories/<ENV>/hosts.yml`

Hosts and groups that Terraform doesn't create: Proxmox hosts, iDRACs, Windows hosts, and the
parent groups that tie the generated groups together. Examples are `rocky9` under `linux`,
`load_balancers`, `rke2_servers`, `k8s_nodes`, `wazuh_agents`, `node_exporter_hosts` and
`kubectl_hosts`. The comment at the top lists every group. **The user owns this file.**

### `inventories/<ENV>/terraform_<unit>.yml` (generated)

Written by `terraform/live/<ENV>/<unit>` on every apply. **Never edit it**: change the unit and
apply. Each VM is in the OS group (`rocky9`, under `linux`) and in its role groups. Its host
variables:

| Variable | Read by | Set in Terraform |
|---|---|---|
| `ansible_host` | Every play, plus the scrape targets and firewall rules built from the inventory | `ipv4_cidr` of the VM in the unit |
| `proxmox_vm_id`, `proxmox_node` | Informational | The created VM |
| `filesystems_volumes__terraform` | `filesystems` | `data_disks` of the role profile (`terraform/_envcommon/roles/<role>.hcl`) and the unit |
| `keepalived_vip` | `load_balancer`, and `rke2_registration_vip` in `group_vars/rke2_*.yml` | `host_vars` in `terraform/live/<ENV>/lb-rancher`, `lb-app` |

### `inventories/<ENV>/group_vars/all/`

| File | What it sets | Read by |
|---|---|---|
| `main.yml` | `env_name`, `env_domain`, `env_ntp_servers`, `env_banner_text`, `env_repo_base_url` (the mirror) and the mirror layout, `certificates_env_dir`, `kubectl_version`, `rancher_hostname`, `app_cluster_hostname`, `app_cluster_rancher_managed` | Most roles |
| `siem.yml` | `siem_server_name`, `siem_server_ip`, `siem_admin_networks`, mail settings (`siem_mail_*`), log and trap senders, the SNMPv3 and Proxmox API user names | SIEM roles, agents and exporters |
| `siem_versions.yml` | Every SIEM version and sha256, and the artifact manifest (mirror path, source URL) | `siem_artifacts` and every SIEM role; `playbooks/siem_download_list.yml` prints the download list from it |
| `vault.yml` | Secrets, encrypted with `ansible-vault` (next section) | Role defaults, by name |

### `inventories/<ENV>/group_vars/<group>.yml`

| File | Group | What it sets |
|---|---|---|
| `linux.yml` | Every Linux host | `ansible_user`, NTP, banner, IPv6, journald (`linux_common_*`), AD logins (`sssd_ad_*`) |
| `rocky9.yml` | Rocky 9 VMs | CIS settings (`rhel9cis_*`) |
| `proxmox_hosts.yml` | Proxmox hosts | Root login over SSH, no firewall management |
| `idrac.yml` | iDRACs | `ansible_connection: local` (Redfish from the control node) |
| `windows.yml`, `windows_server.yml`, `windows_desktop.yml` | Windows hosts | WinRM connection, Windows role settings |
| `db_servers.yml` | Database servers | PostgreSQL settings |
| `nas_servers.yml` | NAS servers | `nas_server_exports` (one per data disk) |
| `registry_servers.yml` | Harbor | Hostname, LDAP, projects, robot accounts |
| `k8s_bastions.yml` | Bastions | Tools and cluster contexts |
| `lb_rancher.yml`, `lb_app.yml` | Each load balancer | VRRP ID, backends, frontends, health checks |
| `rke2_rancher.yml`, `rke2_app.yml` | Each RKE2 cluster | Version and checksums, token, registration name, disks |
| `siem_servers.yml` | The SIEM VM | Wazuh and Prometheus settings for this environment |

### `playbooks/group_vars/` (every environment)

| File | Why it exists |
|---|---|
| `rocky9.yml` | How the CIS role and `linux_common` share settings, so they don't fight |
| `nas_servers.yml` | Keeps CIS from removing the NFS and rpcbind services |
| `registry_servers.yml` | Keeps IP forwarding on, so Docker can publish Harbor's ports |
| `rke2_servers.yml` | CIS exceptions for RKE2: firewalld off, IP forwarding on (network segmentation is the compensating control) |
| `siem_servers.yml` | Lets rsyslog run on the SIEM VM, the designated log host |

## Vault keys

These are all in `inventories/<ENV>/group_vars/all/vault.yml`. The user edits that file with
`ansible-vault edit`; the code only reads it. Most roles check their secret before using it, and
stop with a message naming the key. The iDRAC polling and the Proxmox metrics are different: they
stay off until their keys are set.

| Key | Used by | What it is |
|---|---|---|
| `vault_sssd_ad_join_password` | `sssd_ad` | Password of the AD account that joins hosts |
| `vault_windows_ansible_user`, `vault_windows_ansible_password` | `group_vars/windows.yml` | WinRM login |
| `vault_postgresql_postgres_password` | `database_server` | PostgreSQL `postgres` user (at least 12 ASCII characters) |
| `vault_harbor_admin_password`, `vault_harbor_db_password` | `harbor` | Harbor `admin` (break-glass) and its database |
| `vault_harbor_ldap_bind_password` | `harbor` | Read-only AD account Harbor binds with |
| `vault_harbor_robot_secrets` | `harbor`, `rke2_server` | Dictionary of robot name to secret; `k8s-pull` is the robot the RKE2 nodes pull images with |
| `vault_haproxy_stats_password` | `load_balancer` | HAProxy statistics page |
| `vault_rke2_rancher_token`, `vault_rke2_app_token` | `group_vars/rke2_rancher.yml`, `rke2_app.yml` | Cluster join secrets (`openssl rand -hex 32`) |
| `vault_wazuh_indexer_admin_password`, `vault_wazuh_api_password` | `wazuh_server` | Wazuh indexer `admin` and API user (Wazuh's password rules are in the role defaults) |
| `vault_wazuh_enrollment_password` | `wazuh_server`, `wazuh_agent_linux` | Agent enrollment |
| `vault_postfix_relay_password` | `postfix_relay` | SMTP login to the upstream relay, if it needs one |
| `vault_grafana_admin_password` | `grafana` | Grafana `admin` (at least 12 characters) |
| `vault_snmp_idrac_auth_password`, `vault_snmp_idrac_priv_password` | `snmp_exporter`, `prometheus` | SNMPv3 polling user on the iDRACs |
| `vault_pve_exporter_token_value` | `pve_exporter`, `prometheus` | Proxmox API token secret, printed once by `proxmox_monitoring` |

The trap senders in `siem_snmp_trap_users` (`group_vars/all/siem.yml`) reference vault keys that you
name yourself.

To check a secret without showing it, print only its length:

```sh
ansible localhost -i inventories/<ENV> -m ansible.builtin.debug \
  -a "msg='{{ vault_rke2_rancher_token | default('') | length }}'" --ask-vault-pass
```

## Terraform values

Terraform has its own settings. They aren't Ansible variables, but they decide much of the Ansible
inventory:

| Setting | File |
|---|---|
| Proxmox endpoint, node, storage, bridge, gateway, DNS, template, SSH keys | `terraform/live/<ENV>/env.hcl` |
| Size and disks of a role | `terraform/_envcommon/roles/<role>.hcl` ([table](../../terraform/_envcommon/roles/README.md)) |
| Host names, addresses, cluster size, load balancer virtual IPs | `terraform/live/<ENV>/<unit>/terragrunt.hcl` |
| Proxmox API token | `PROXMOX_VE_API_TOKEN` in the shell, never in a file |
| Rancher's first admin password | `TF_VAR_rancher_bootstrap_password` in the shell |
| Rancher chart and certificate folder | `terraform/k8s/<ENV>/rancher-server/terragrunt.hcl` |

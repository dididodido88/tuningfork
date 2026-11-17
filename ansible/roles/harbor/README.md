# harbor

Installs the Harbor registry for container images and Helm charts (OCI) with Harbor's offline
installer under Docker Compose, then sets it up through the Harbor API: AD logins, projects,
AD group roles, robot accounts and garbage collection.

| | |
|---|---|
| Playbook | `playbooks/harbor.yml` |
| Hosts | `registry_servers` |
| Tags | `harbor`, `firewall` |
| Needs first | `certificates` (host certificate covering the registry name), `repositories` (`docker-ce-stable`), `filesystems` (`/srv/harbor`) |
| Set variables in | `inventories/<ENV>/group_vars/registry_servers.yml`, secrets in `group_vars/all/vault.yml` |
| Longer guide | [docs/harbor.md](../../docs/harbor.md): files to mirror, DNS, certificate and AD prerequisites, client usage, backups, upgrades |

## What it does

1. **Pre-checks** (nothing is changed until they pass): the settings and secrets are set, the
   registry name resolves to this host, the TLS certificate covers the registry name, and no
   other Harbor version is installed.
2. **Docker**: installs Docker CE and the Compose plugin, writes `/etc/docker/daemon.json`,
   turns on IP forwarding (`/etc/sysctl.d/90-docker.conf`), starts Docker and opens the firewall.
3. **Install**: downloads the offline installer from the mirror and checks its SHA-256, unpacks
   it to `<harbor_install_dir>/<harbor_version>/harbor`, writes `harbor.yml`, a Compose override
   (so Harbor trusts the internal CA) and a `harbor` systemd unit, then runs `install.sh` once.
   On later runs, a change to `harbor.yml` regenerates the configuration and recreates the
   containers.
4. **Initialise through the API**: waits until Harbor is healthy, sets the authentication mode
   and LDAP settings, tests the AD bind, creates the projects and their AD group members,
   creates the robot accounts, schedules garbage collection, and logs in as a client would.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `env_repo_base_url` | (inventory) | Base URL of the internal mirror, in `group_vars/all/main.yml`. |
| `env_domain` | (inventory) | DNS domain of the environment. Used for the registry name and the LDAP URL. |
| `harbor_installer_checksum` | `""` | `sha256:<hash>` of the offline installer, recorded when it was downloaded and verified. |
| `vault_harbor_admin_password` | | Password of Harbor's local `admin` user. At least 8 characters. |
| `vault_harbor_db_password` | | Password of Harbor's internal database. At least 8 characters. |
| `harbor_ldap_base_dn` | `""` | With `ldap_auth`: search base, e.g. `DC=lab,DC=local`. |
| `harbor_ldap_bind_dn` | `""` | With `ldap_auth`: DN of the read-only bind account. |
| `vault_harbor_ldap_bind_password` | | With `ldap_auth`: password of the bind account. |
| `vault_harbor_robot_secrets` | `{}` | One secret per entry of `harbor_robots`, keyed by robot name: 8 to 128 characters with upper case, lower case and a digit. |

Installer and host layout:

| Variable | Default | Description |
|---|---|---|
| `harbor_version` | `v2.15.5` | Harbor release to install. |
| `harbor_mirror_url` | `<env_repo_base_url>/harbor` | Where the installers are on the mirror. |
| `harbor_installer_file` | `harbor-offline-installer-<version>.tgz` | Installer file name. |
| `harbor_installer_url` | `<mirror url>/<version>/<file>` | Full download URL. |
| `harbor_hostname` | `registry.<env_domain>` | Name clients use. Must resolve to this host and be in the certificate. |
| `harbor_install_dir` | `/opt/harbor` | Installer files, one directory per version. |
| `harbor_data_dir` | `/srv/harbor/data` | Images, charts, database and job logs. Put it on a data disk. |
| `harbor_log_dir` | `/var/log/harbor` | Harbor log files. |
| `harbor_tls_certificate` | `/etc/pki/tls/certs/host.fullchain.crt` | Certificate, from the `certificates` role. |
| `harbor_tls_key` | `/etc/pki/tls/private/host.key` | Private key, from the `certificates` role. |
| `harbor_trust_bundle_dir` | `/etc/pki/ca-trust/extracted/pem` | System trust bundle mounted into Harbor so it trusts the internal CA. |
| `harbor_with_trivy` | `false` | Install the Trivy scanner. Needs an offline vulnerability database (see the guide). |

Docker and firewall:

| Variable | Default | Description |
|---|---|---|
| `harbor_docker_packages` | `[docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin]` | Packages from the `docker-ce-stable` repository. |
| `harbor_docker_log_max_size` | `50m` | Size at which a container log file is rotated. |
| `harbor_docker_log_max_file` | `5` | Rotated log files kept per container. |
| `harbor_manage_firewall` | `true` | Open `harbor_firewall_services` in firewalld. |
| `harbor_firewall_services` | `[https]` | firewalld services opened in the default zone. Add `http` if clients use `http://` URLs (it only redirects). |

Authentication:

| Variable | Default | Description |
|---|---|---|
| `harbor_auth_mode` | `ldap_auth` | `ldap_auth`: AD users and groups log in, and the local `admin` and robot accounts keep working. `db_auth`: Harbor-local users only. |
| `harbor_ldap_url` | `ldaps://<env_domain>:636` | LDAP URL. The AD domain name resolves to every DC. |
| `harbor_ldap_verify_cert` | `true` | Check the DCs' LDAPS certificates. |
| `harbor_ldap_uid` | `sAMAccountName` | Attribute used as the login name. |
| `harbor_ldap_filter` | `(objectClass=user)` | Users that may log in. Narrow it with a `memberOf` filter. |
| `harbor_ldap_group_base_dn` | `harbor_ldap_base_dn` | Search base for groups. |
| `harbor_ldap_group_filter` | `(objectClass=group)` | Filter for groups. |
| `harbor_ldap_group_name_attribute` | `sAMAccountName` | Attribute used as the group name. |
| `harbor_ldap_group_admin_dn` | `""` | DN of the AD group whose members are Harbor system administrators. |

Projects, robots and garbage collection:

| Variable | Default | Description |
|---|---|---|
| `harbor_projects` | `library` (public), `charts` (private) | Projects to create. Each has `name`, `public` and `members` (a list of `group` and `role`). Roles: `project_admin`, `maintainer`, `developer`, `guest`, `limited_guest`. |
| `harbor_robots` | `[]` | System-level robot accounts. Each has `name`, optional `description`, `projects` (`["*"]` for all) and `actions` (`pull`, `push`). Clients log in as `robot$<name>`. |
| `harbor_gc_schedule` | `"0 0 3 * * 6"` | Garbage collection schedule in Harbor's cron format (seconds first). |
| `harbor_gc_delete_untagged` | `true` | Also delete untagged artifacts. |

## Example

```yaml
# inventories/<ENV>/group_vars/registry_servers.yml
harbor_version: v2.15.5
harbor_installer_checksum: "sha256:<hash>"

harbor_ldap_base_dn: "DC=lab,DC=local"
harbor_ldap_bind_dn: "CN=svc_ldap_bind,OU=Service Accounts,OU=Lab,DC=lab,DC=local"
harbor_ldap_group_admin_dn: "CN=sg-lab-harbor-admins,OU=Groups,OU=Lab,DC=lab,DC=local"

harbor_projects:
  - name: library
    public: true
    members:
      - {group: sg-all-users, role: developer}

harbor_robots:
  - name: k8s-pull
    projects: ["*"]
    actions: [pull]
```

## Good to know

- **Upgrades are never automatic.** If another version is installed, the play stops. Follow
  "Upgrading" in the guide.
- **Existing robot accounts are left alone**, including their secret. To change one, delete it in
  Harbor and run the play again.
- The `admin` password in `harbor.yml` is used only on first start. Changing it later is covered
  by "Rotating secrets" in the guide.
- Harbor only allows switching to `ldap_auth` while no local users other than `admin` exist.
- Docker needs IP forwarding, so CIS rule 3.3.1 is turned off for `registry_servers`
  (`playbooks/group_vars/registry_servers.yml`).
- In check mode the API steps are skipped.

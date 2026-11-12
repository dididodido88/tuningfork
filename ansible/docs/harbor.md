# Harbor registry (container images and Helm charts)

Harbor is the registry for container images and Helm charts in each environment. It runs on the
`registry_servers` host under Docker Compose and was installed from Harbor's **offline installer**.
Clients reach it at **`https://registry.<domain>`** (lab: `https://registry.lab.local`), a DNS alias for the
host (lab: `lab-registry.lab.local`).

```
docker pull registry.lab.local/library/nginx:1.27          # image: <registry>/<project>/<image>:<tag>
helm install web oci://registry.lab.local/charts/web --version 1.2.0
```

Harbor always puts a **project** in the path (`library`, `charts`, ...). `registry.lab.local/nginx:1.27`
without a project isn't possible. Use the public `library` project for shared base images.

The playbook is `playbooks/harbor.yml` (role `harbor`). Settings are in `inventories/<ENV>/group_vars/registry_servers.yml`,
and secrets in `inventories/<ENV>/group_vars/all/vault.yml`.

---

## 1. Files to download for the air-gapped mirror

Download these on an internet-connected machine, verify them there, and copy them to the mirror. The playbook
fetches them from the mirror only.

### Layout on the mirror

```
https://maestro/harbor/
├── v2.15.2/
│   ├── harbor-offline-installer-v2.15.2.tgz          required (~700 MB, contains every Harbor image)
│   ├── harbor-offline-installer-v2.15.2.tgz.sha256   recorded checksum (you create it)
│   └── *.sigstore.json / *.asc                      signature material, kept for audit
└── tools/                                            optional, for admin workstations
    ├── helm-v3.x.y-linux-amd64.tar.gz
    └── helm-v3.x.y-linux-amd64.tar.gz.sha256sum
https://maestro/rocky/repo/9/docker-ce-stable/       already mirrored (roles/repositories)
```

`https://maestro` is `env_mirror_base_url` in `inventories/<ENV>/group_vars/all/main.yml`. The role downloads
`<env_mirror_base_url>/harbor/<harbor_version>/harbor-offline-installer-<harbor_version>.tgz`.

### What to download

| File | Where from | Needed for |
|---|---|---|
| `harbor-offline-installer-vX.Y.Z.tgz` | https://github.com/goharbor/harbor/releases (assets of the release) | Harbor itself (all images included) |
| Signature for it: `….tgz.sigstore.json` (Cosign bundle, v2.15+) or `….tgz.asc` (GPG, older releases) | same release page | Proving the download is genuine |
| Docker CE packages `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` (+ `docker-buildx-plugin`, `docker-ce-rootless-extras` as pulled by dnf) | https://download.docker.com/linux/rhel/9/x86_64/stable/ (synced into the existing `docker-ce-stable` mirror) | Running Harbor. `container-selinux` comes from Rocky AppStream |
| `helm-vX.Y.Z-linux-amd64.tar.gz` + `.sha256sum` (optional) | https://get.helm.sh (version list: https://github.com/helm/helm/releases) | Pushing charts from admin workstations |

Pick the newest **patch** release of a Harbor minor version that you can support, e.g. the latest v2.15.x, and set
`harbor_version` to it. Read the release notes for upgrade steps (section 6).

### Example: download and verify (internet-connected Linux machine)

```sh
VER=v2.15.2
mkdir -p harbor/$VER harbor/tools && cd harbor/$VER

BASE=https://github.com/goharbor/harbor/releases/download/$VER
curl -fLO $BASE/harbor-offline-installer-$VER.tgz
# v2.15 and later: Cosign bundle (check the asset name on the release page)
curl -fLO $BASE/harbor-offline-installer-$VER.tgz.sigstore.json
cosign verify-blob \
  --bundle harbor-offline-installer-$VER.tgz.sigstore.json \
  --certificate-identity-regexp '^https://github.com/goharbor/harbor/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  harbor-offline-installer-$VER.tgz
# Older releases: GPG instead
#   curl -fLO $BASE/harbor-offline-installer-$VER.tgz.asc
#   gpg --keyserver hkps://keyserver.ubuntu.com --receive-keys <key ID from Harbor's install docs>
#   gpg -v --verify harbor-offline-installer-$VER.tgz.asc

sha256sum harbor-offline-installer-$VER.tgz | tee harbor-offline-installer-$VER.tgz.sha256

# Optional: Helm client
cd ../tools
HELM=v3.16.4
curl -fLO https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz
curl -fLO https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz.sha256sum
sha256sum -c helm-$HELM-linux-amd64.tar.gz.sha256sum
```

Carry the `harbor/` directory into the air-gapped network (approved media transfer), and place it on the mirror
as `/harbor/` so that the layout above is served. On the air-gapped side, check it again:

```sh
cd /path/to/mirror/harbor/v2.15.2 && sha256sum -c harbor-offline-installer-v2.15.2.tgz.sha256
```

Put the hash into `inventories/<ENV>/group_vars/registry_servers.yml`:

```yaml
harbor_version: v2.15.2
harbor_installer_checksum: "sha256:<the 64-character hash>"
```

**Docker CE:** make sure the mirror sync of `docker-ce-stable` (EL9, x86_64) includes the packages listed above.
`dnf --repo docker-ce-stable list available` on any Rocky 9 host shows what the mirror serves.

**Trivy (later, optional):** the scanner needs its vulnerability databases, which are OCI artifacts
(`ghcr.io/aquasecurity/trivy-db:2` and `ghcr.io/aquasecurity/trivy-java-db:1`), downloaded with
`oras pull` and refreshed regularly (at least weekly to stay useful). See section 6.

---

## 2. Prerequisites (per environment)

1. **DNS alias.** `registry.<domain>` must point at the Harbor host. In AD DNS:
   ```powershell
   Add-DnsServerResourceRecordCName -ZoneName "lab.local" -Name "registry" -HostNameAlias "lab-registry.lab.local"
   ```
   The playbook stops if the name doesn't resolve to the host.
2. **Certificate.** The host's pre-generated certificate (`/srv/security/certificates/files/<env>/<host>/`, deployed
   by `playbooks/certificates.yml`) must include **`DNS:registry.<domain>`** as a subjectAltName, in addition to the
   host's own name. Harbor serves `host.fullchain.crt` / `host.key`. The playbook checks the SAN.
3. **Data disk** mounted at `/srv/harbor` (Terraform adds a 200 GB disk; `playbooks/filesystems.yml` mounts it).
   Size it for your images: Harbor needs at least 4 CPUs, 8 GB RAM and 160 GB of disk.
4. **AD (for `harbor_auth_mode: ldap_auth`)**:
   - LDAPS (636) on the DCs, with DC certificates issued by the internal CA (the CA the `certificates` role trusts),
     covering the domain name (`lab.local`) as well as the DC names. Harbor connects to `ldaps://lab.local:636`, so either DC can answer.
   - A read-only bind account, and the groups:
     ```powershell
     $base = "DC=lab,DC=local"; $ou = "OU=Linux,OU=Servers,$base"
     New-ADUser -Name "svc-harbor-ldap" -SamAccountName "svc-harbor-ldap" -Path "OU=Servers,$base" `
       -AccountPassword (Read-Host -AsSecureString "Password") -Enabled $true -PasswordNeverExpires $true `
       -CannotChangePassword $true -Description "Harbor LDAP bind (read-only)"
     New-ADGroup -Name "harbor-admins"     -GroupScope Global -GroupCategory Security -Path $ou
     New-ADGroup -Name "harbor-developers" -GroupScope Global -GroupCategory Security -Path $ou
     ```
     Domain users can read the directory by default, so the bind account needs no extra rights.
   - Set the DNs in `registry_servers.yml` (`harbor_ldap_base_dn`, `harbor_ldap_bind_dn`, `harbor_ldap_group_admin_dn`),
     and `vault_harbor_ldap_bind_password` in the vault.
5. **Secrets** in `inventories/<ENV>/group_vars/all/vault.yml` (then `ansible-vault encrypt` it):
   `vault_harbor_admin_password`, `vault_harbor_db_password`, `vault_harbor_ldap_bind_password` and
   `vault_harbor_robot_secrets` (one per robot: 8–128 characters with upper case, lower case and a digit).

---

## 3. Install and initialise

From `ansible/`:

```sh
ansible-playbook -i inventories/lab playbooks/harbor.yml --vault-id lab@prompt
```

(`site.yml` runs it last, after certificates, repositories, data disks and CIS.)

What the playbook does:

1. **Checks** the settings, that `registry.<domain>` resolves to the host, that the certificate covers it, and that no
   other Harbor version is installed.
2. **Docker**:
   - installs Docker CE and the Compose plugin from the mirror
   - sets log rotation in `/etc/docker/daemon.json`
   - enables IP forwarding (`/etc/sysctl.d/90-docker.conf`; CIS 3.3.1 is turned off for `registry_servers` in
     `playbooks/group_vars/registry_servers.yml`)
   - opens `https` in firewalld
3. **Install**:
   - downloads and checks the offline installer, unpacks it to `/opt/harbor/<version>/harbor`, and writes `harbor.yml`
   - writes `docker-compose.override.yml`, which makes harbor-core and jobservice trust the host's CA bundle (LDAPS to the DCs)
   - runs `install.sh` on the first run
   - on later runs, a changed `harbor.yml` runs `prepare` and recreates the containers
   - `harbor.service` starts Harbor in order at boot
4. **Initialise** through the Harbor API (every step only changes what differs):
   - waits until all components are healthy
   - sets **AD login** (LDAP mode) and tests the bind
   - creates the **projects** (`library` public, `charts` private) and gives AD groups their **roles**
   - creates **robot accounts** with the secrets from the vault
   - schedules weekly **garbage collection**
   - finally runs `docker login` against `registry.<domain>` as a robot, to prove TLS, DNS and the account

**Logins.** In LDAP mode:
- AD users (members of the groups given roles, or `harbor-admins`) log in to the UI with their AD username and
  password. The same applies to `docker login` and `helm registry login`.
- The **local `admin`** account keeps working as break-glass and is what Ansible uses.
- **Robot accounts** (`robot$k8s-pull`, `robot$ci-push`) are the local credentials for machines.

Harbor allows no other local users in LDAP mode. The auth mode can only be switched while no users other than
admin exist, which is why the playbook sets it on the first run.

---

## 4. Using the registry

### Trust the CA

Hosts that ran `playbooks/certificates.yml` already trust the internal CA (system trust store). Docker,
containerd and Helm on Rocky 9 use the system store. On other machines:
- **Docker:** `/etc/docker/certs.d/registry.lab.local/ca.crt` (the root CA file)
- **containerd** (Kubernetes nodes), `/etc/containerd/certs.d/registry.lab.local/hosts.toml`:
  ```toml
  server = "https://registry.lab.local"
  [host."https://registry.lab.local"]
    ca = "/etc/pki/ca-trust/source/anchors/lab.local-root-ca.pem"
  ```

### Images

```sh
docker login registry.lab.local                     # AD user, or robot$ci-push
docker tag myapp:1.0 registry.lab.local/library/myapp:1.0
docker push registry.lab.local/library/myapp:1.0
docker pull registry.lab.local/library/myapp:1.0    # library is public: no login needed to pull
```

### Kubernetes

Public projects (`library`) need no credentials. For private projects, use the `k8s-pull` robot:

```sh
kubectl create secret docker-registry harbor-pull -n <namespace> \
  --docker-server=registry.lab.local --docker-username='robot$k8s-pull' --docker-password='<secret>'
```

Then reference it with `imagePullSecrets: [{name: harbor-pull}]`, or attach it to the namespace's default service account.
Images in manifests are written as `registry.lab.local/<project>/<image>:<tag>`.

### Helm charts (OCI)

Harbor 2.8+ stores charts as OCI artifacts. `helm repo add` and `index.yaml` aren't supported.

```sh
helm registry login registry.lab.local               # AD user or robot$ci-push
helm package ./web                                   # -> web-1.2.0.tgz
helm push web-1.2.0.tgz oci://registry.lab.local/charts
helm show chart oci://registry.lab.local/charts/web --version 1.2.0
helm install web oci://registry.lab.local/charts/web --version 1.2.0
```

Argo CD / Flux: add `registry.lab.local/charts` as an OCI Helm repository with the `k8s-pull` robot.

### Projects, groups, robots

Change `harbor_projects` and `harbor_robots` in `registry_servers.yml` and rerun the playbook. New projects,
group roles and robots are added. Removing an entry doesn't delete anything in Harbor (delete it in the UI).
Existing robots keep their permissions and secret; to change them, delete the robot in the UI and rerun.

---

## 5. Day-to-day

| Task | How |
|---|---|
| Status | `cd /opt/harbor/<version>/harbor && docker compose ps`; `systemctl status harbor` |
| Logs | `/var/log/harbor/*.log` (core, registry, jobservice, proxy, ...) |
| Health | `curl https://registry.lab.local/api/v2.0/health` |
| Restart | `systemctl restart harbor` |
| Disk use | `du -sh /srv/harbor/data/*`; garbage collection runs weekly (Administration → Clean Up) |
| LDAP test | Administration → Configuration → Authentication → Test LDAP Server |

---

## 6. Maintenance

**Backups.** Stop Harbor for a consistent copy, or dump the database online:
```sh
docker exec harbor-db pg_dumpall -U postgres > /srv/harbor/backup/harbor-db-$(date +%F).sql
# plus the data directory: /srv/harbor/data (registry blobs, secrets, certificates)
```
Keep `harbor.yml` and the vault: the database password and the `secretkey` in `/srv/harbor/data/secret/` are
needed for a restore.

**Upgrading** (never automatic; the playbook stops if `harbor_version` differs from the installed version):
1. Mirror the new offline installer (section 1). Read its release notes.
2. Back up (above), then `systemctl stop harbor`.
3. Migrate `harbor.yml` with the new version's `prepare` image:
   `docker run -it --rm -v /:/hostfs goharbor/prepare:<new version> migrate -i /opt/harbor/<old>/harbor/harbor.yml`
   (load the new images first with `docker load -i harbor.<new version>.tar.gz` from the unpacked installer).
4. Set `harbor_version` and `harbor_installer_checksum`, remove `/opt/harbor/.installed-version`, and run the playbook.
   It installs the new version with the same data directory. `install.sh` performs the database schema migration.
5. Check health, log in, pull an image. Then remove `/opt/harbor/<old>`.

**Rotating secrets:**
- *admin password*: change it in the UI (or `PUT /api/v2.0/users/1/password`), then update `vault_harbor_admin_password`.
  `harbor.yml` only uses it on the very first start.
- *robot secret*: in the UI, *Robot Accounts → Refresh secret*, then update the vault and the clients.
- *LDAP bind password*: change it in AD and the vault, then rerun the playbook (it updates Harbor's configuration
  when other LDAP settings change). Otherwise set it in the UI.

**Enabling Trivy:**
1. Mirror the DB artifacts: `oras pull ghcr.io/aquasecurity/trivy-db:2` and `oras pull ghcr.io/aquasecurity/trivy-java-db:1` (each gives a `db.tar.gz`).
2. Set `harbor_with_trivy: true` and rerun (with the version marker removed, or run `./prepare --with-trivy` and recreate).
3. Unpack the databases into `/srv/harbor/data/trivy-adapter/trivy/db/` and `.../java-db/` (owned by uid 10000).
   Repeat the download and unpack at least weekly. Harbor is configured with `skip_update: true`, so it never
   tries to reach the internet.

**Troubleshooting:**
- *Login with an AD user fails*: check `harbor_ldap_filter`, and the user's group membership. Run the LDAP test in the UI.
  Check `/var/log/harbor/core.log` for `x509` errors, which mean the DC certificate isn't trusted or doesn't cover the URL name.
- *`x509: certificate signed by unknown authority` on clients*: the client doesn't trust the internal CA (section 4).
- *`docker pull` times out from other hosts*: firewalld (`firewall-cmd --list-services`) and
  `sysctl net.ipv4.ip_forward` (must be 1).

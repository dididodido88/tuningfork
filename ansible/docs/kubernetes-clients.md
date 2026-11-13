# Kubernetes clients: kubectl and the bastion host

Two playbooks install the Kubernetes client tools from the air-gapped mirror:

| Playbook | Hosts | Installs |
|---|---|---|
| `playbooks/kubectl.yml` (role `kubectl`) | group `kubectl_hosts`: every Kubernetes bastion, plus any host you add (CI runners, admin hosts) | `kubectl` only |
| `playbooks/k8s_bastion.yml` (roles `kubectl` + `k8s_bastion`) | group `k8s_bastions` (lab: `mgmt.lab.local`) | `kubectl`, `helm`, `k9s`, `kubectx`, `kubens`, shared cluster contexts, login environment |

Both run in `site.yml` after the server roles.

---

## 1. Files to download for the mirror

### Layout on the mirror

```
https://maestro/kubernetes/
├── v1.31.0/                                   one directory per kubectl version (kubectl_version)
│   ├── kubectl
│   └── kubectl.sha256                         checked by the playbook unless kubectl_checksum pins it
└── tools/
    ├── helm/v3.16.4/helm-v3.16.4-linux-amd64.tar.gz
    ├── k9s/v0.32.7/k9s_Linux_amd64.tar.gz
    ├── kubectx/v0.9.5/kubectx_v0.9.5_linux_x86_64.tar.gz
    └── kubens/v0.9.5/kubens_v0.9.5_linux_x86_64.tar.gz
```

`https://maestro` is `env_mirror_base_url` in `inventories/<ENV>/group_vars/all/main.yml`. Keep the checksum and
signature files next to each tool for audit.

### Sources

| Tool | Download | Checksum / signature |
|---|---|---|
| kubectl | `https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl` | `kubectl.sha256` (same URL + `.sha256`); optional Sigstore signature `kubectl.sig` + `kubectl.cert` |
| helm | `https://get.helm.sh/helm-<version>-linux-amd64.tar.gz` (versions: https://github.com/helm/helm/releases) | `….tar.gz.sha256sum` |
| k9s | `https://github.com/derailed/k9s/releases/download/<version>/k9s_Linux_amd64.tar.gz` | the checksums file on the same release page |
| kubectx / kubens | `https://github.com/ahmetb/kubectx/releases/download/<version>/kubectx_<version>_linux_x86_64.tar.gz` (and `kubens_…`) | `checksums.txt` on the same release page |

**kubectl version:** use a version within **one minor version** of your clusters' API servers (e.g. kubectl
v1.31 for clusters on 1.30–1.32). To support clusters several minor versions apart, mirror more than one
kubectl version. Each environment chooses one with `kubectl_version`.

### Example: download and verify (internet-connected Linux machine)

```sh
set -euo pipefail
K=v1.31.0; HELM=v3.16.4; K9S=v0.32.7; KCTX=v0.9.5
mkdir -p kubernetes/$K kubernetes/tools/{helm/$HELM,k9s/$K9S,kubectx/$KCTX,kubens/$KCTX}
cd kubernetes

# kubectl
curl -fLo $K/kubectl        https://dl.k8s.io/release/$K/bin/linux/amd64/kubectl
curl -fLo $K/kubectl.sha256 https://dl.k8s.io/release/$K/bin/linux/amd64/kubectl.sha256
echo "$(cat $K/kubectl.sha256)  $K/kubectl" | sha256sum -c

# helm
( cd tools/helm/$HELM
  curl -fLO https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz
  curl -fLO https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz.sha256sum
  sha256sum -c helm-$HELM-linux-amd64.tar.gz.sha256sum )

# k9s (check the checksum file name on the release page)
( cd tools/k9s/$K9S
  curl -fLO https://github.com/derailed/k9s/releases/download/$K9S/k9s_Linux_amd64.tar.gz
  curl -fLO https://github.com/derailed/k9s/releases/download/$K9S/checksums.sha256
  grep ' k9s_Linux_amd64.tar.gz$' checksums.sha256 | sha256sum -c )

# kubectx / kubens
for t in kubectx kubens; do
  ( cd tools/$t/$KCTX
    curl -fLO https://github.com/ahmetb/kubectx/releases/download/$KCTX/${t}_${KCTX}_linux_x86_64.tar.gz
    curl -fLO https://github.com/ahmetb/kubectx/releases/download/$KCTX/checksums.txt
    grep " ${t}_${KCTX}_linux_x86_64.tar.gz\$" checksums.txt | sha256sum -c )
done

# Hashes to put into the inventory
find . -name '*.tar.gz' -exec sha256sum {} \;
```

Copy the `kubernetes/` directory to the mirror so that it is served as `https://maestro/kubernetes/`.

### Set versions and checksums

- `inventories/<ENV>/group_vars/all/main.yml`: `kubectl_version: v1.31.0`. The playbook verifies the binary against
  `kubectl.sha256` on the mirror. To pin the hash you recorded on the internet side instead, also set
  `kubectl_checksum: "sha256:<hash>"`.
- `inventories/<ENV>/group_vars/k8s_bastions.yml`: for each entry in `k8s_bastion_tools`, set `version`, `archive` and
  `checksum: "sha256:<hash>"`. The playbook stops if a checksum is missing.

**Changing versions:** mirror the new files, change the version (and checksum), and rerun. Each version is kept in
its own directory (`/usr/local/lib/kubectl/<version>/`, `/usr/local/lib/k8s-tools/<tool>/<version>/`), and the link
in `/usr/local/bin` is repointed. To roll back, set the old version again.

---

## 2. The bastion host

**Who can log in:** AD users in `sg-lab-k8s-users` (`sssd_ad_extra_ssh_groups` in `group_vars/k8s_bastions.yml`), plus the
usual SSH and admin groups (lab: `sg-all-users`, `sg-lab-admins`), and local accounts in `sshusers`/`wheel`. Before the first run, create
the AD group and give it a `gidNumber` (docs/active-directory.md, sections 3–4). Then run `sssd_ad.yml` and
`cis_rhel9.yml` (or `site.yml`) so sssd and sshd `AllowGroups` include it.

**What users get:**
- `kubectl`, `helm`, `k9s`, `kubectx`, `kubens` in `/usr/local/bin`, with bash completion, and the alias `k` for kubectl
- `KUBECONFIG` set at login to `~/.kube/config` followed by every shared cluster file in `/etc/kubernetes/clusters/`.
  Every shared cluster then shows up in `kubectl config get-contexts`. Credentials and the current context are
  written to the user's own `~/.kube/config` (mode 700 directory).
- a short usage note at login (`/etc/motd.d/k8s-bastion`)

### Shared cluster definitions

List the clusters in `group_vars/k8s_bastions.yml`:

```yaml
k8s_bastion_clusters:
  - name: lab-k8s
    server: https://lab-k8s-api.lab.local:6443
    # ca_file: /etc/pki/tls/certs/ca-bundle.crt   # default: system bundle, which trusts the internal CA
    namespace: default
```

Each becomes `/etc/kubernetes/clusters/lab-k8s.yaml`, containing the cluster and a context named after it, with a
user of the same name and **no credentials**. Removing an entry removes its file.

### First login: add your credentials

```sh
kubectl config get-contexts                        # shared clusters are listed
# token
kubectl config set-credentials lab-k8s --token=<token>
# or client certificate
kubectl config set-credentials lab-k8s --client-certificate=~/.kube/me.crt --client-key=~/.kube/me.key --embed-certs
kubectl config use-context lab-k8s                 # or: kubectx lab-k8s
kubectl get nodes
kubens kube-system                                 # change the default namespace
k9s                                                # terminal UI
```

With OIDC (e.g. AD FS or Keycloak), use the cluster's documented `kubectl config set-credentials … --exec-*` setup.
Any exec plugin (e.g. `kubelogin`) can be mirrored and added to `k8s_bastion_tools` the same way.

### Helm charts from Harbor

```sh
helm registry login registry.lab.local             # AD account
helm install web oci://registry.lab.local/charts/web --version 1.2.0
```

See [harbor.md](harbor.md) for pushing charts and images.

---

## 3. kubectl on other hosts

Add the host to `kubectl_hosts` in `inventories/<ENV>/hosts.yml` (directly, or as a child group):

```yaml
    kubectl_hosts:
      children:
        k8s_bastions:
      hosts:
        lab-ci01.lab.local:
```

Then run, from `ansible/`:

```sh
ansible-playbook -i inventories/lab playbooks/kubectl.yml --limit lab-ci01.lab.local
```

Only kubectl and its bash completion are installed. The host's own SSH access rules don't change.

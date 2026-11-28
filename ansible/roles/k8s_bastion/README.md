# k8s_bastion

Builds the Kubernetes bastion: the Rocky 9 host that Kubernetes users log in to. It installs
helm, k9s, kubectx and kubens from the internal mirror, publishes shared cluster contexts
without credentials, and sets up the login environment.

| | |
|---|---|
| Playbook | `playbooks/k8s_bastion.yml` (runs the `kubectl` role first) |
| Hosts | `k8s_bastions` |
| Tag | `k8s_bastion` |
| Needs first | `certificates` (CA trust for the mirror), `repositories`, the `kubectl` role |
| Set variables in | `inventories/<ENV>/group_vars/k8s_bastions.yml` |
| Longer guide | [docs/kubernetes-clients.md](../../docs/kubernetes-clients.md): files to mirror, checksums, using the bastion |

## What it does

1. Stops if the mirror URL is unset or any tool lacks a `sha256:` checksum.
2. Installs `k8s_bastion_packages` for interactive work.
3. For each tool: downloads the archive from the mirror, checks its checksum, unpacks the binary
   to `<k8s_bastion_tools_dir>/<name>/<version>/` and links it as `/usr/local/bin/<name>`.
   Changing a version repoints the link. Older versions stay on disk.
4. Writes bash completion for the tools in `k8s_bastion_completion_tools`.
5. Writes one kubeconfig per cluster to `<k8s_bastion_clusters_dir>/<name>.yaml` (cluster and
   context only, **no credentials**) and removes files for clusters no longer listed.
6. Writes `/etc/profile.d/k8s-bastion.sh`, which sets `KUBECONFIG` to the user's own
   `~/.kube/config` plus every shared cluster file, and adds the alias `k` for `kubectl`.
7. Writes usage notes shown at login (`/etc/motd.d/k8s-bastion`).
8. Mounts every export of the NAS host (`nas_server_exports` of the first host in `nas_servers`) at
   `<k8s_bastion_nas_mount_root>/<name>`, e.g. `/mnt/nas/pvcdata`, over NFS 4.2, for troubleshooting.
   The NAS gives the bastion `no_root_squash`, so root can fix files on any export.

Who may log in is decided by the `sssd_ad` role: add the bastion's AD groups to
`sssd_ad_extra_ssh_groups` in the same group_vars file.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `env_repo_base_url` | (inventory) | Base URL of the internal mirror, in `group_vars/all/main.yml`. |
| `k8s_bastion_tools` | helm, k9s, kubectx, kubens with empty checksums | Tools to install. The `checksum` of every entry must be set. See the fields below. |

Fields of one `k8s_bastion_tools` entry:

| Field | Description |
|---|---|
| `name` | Command name. The binary is linked as `/usr/local/bin/<name>`. |
| `version` | Version directory on the mirror and on the host, e.g. `v0.51.0`. |
| `mirror_dir` | Optional. Full URL of the mirror folder holding the archive, for a tool stored outside `<k8s_bastion_tools_mirror_url>/<name>/<version>/`. helm uses `<env_repo_base_url>/helm/<version>`. |
| `archive` | Archive file name on the mirror. |
| `member` | Path of the binary inside the archive, e.g. `linux-amd64/helm`. |
| `checksum` | `sha256:<hash>` from the upstream checksum file. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `k8s_bastion_tools_mirror_url` | `<env_repo_base_url>/kubernetes` | Archives are at `<this>/<name>/<version>/<archive>`, unless the entry sets `mirror_dir`. |
| `k8s_bastion_tools_dir` | `/usr/local/lib/k8s-tools` | Where the tools are unpacked. |
| `k8s_bastion_completion_tools` | `[helm, k9s]` | Tools that print a completion script with `<name> completion bash`. |
| `k8s_bastion_packages` | `[bash-completion, git, vim-enhanced, tmux]` | OS packages for interactive work. |
| `k8s_bastion_clusters` | `[]` | Shared cluster definitions. Each has `name`, `server`, and optional `ca_file` (default: the system CA bundle) and `namespace` (default: `default`). |
| `k8s_bastion_clusters_dir` | `/etc/kubernetes/clusters` | Where the shared cluster files are written. |
| `k8s_bastion_nas_mounts_enabled` | `true` | Mount the NAS exports. |
| `k8s_bastion_nas_host` | first host in `nas_servers` | The NAS. Its `nas_server_exports` lists what is mounted. |
| `k8s_bastion_nas_mount_root` | `/mnt/nas` | Each export is mounted at `<this>/<last part of its path>`. |
| `k8s_bastion_nas_mount_opts` | `rw,nfsvers=4.2,hard,_netdev,nofail,nosuid,nodev` | Mount options. `nofail`: a NAS that is down doesn't stop the bastion booting. |

The login notes also show `kubectl_version` (from the `kubectl` role) and `env_domain`.

## Example

```yaml
# inventories/<ENV>/group_vars/k8s_bastions.yml
sssd_ad_extra_ssh_groups: [sg-lab-k8s-users]

k8s_bastion_tools:
  - name: helm
    version: v4.3.1
    mirror_dir: "{{ env_repo_base_url }}/helm/v4.3.1"
    archive: helm-v4.3.1-linux-amd64.tar.gz
    member: linux-amd64/helm
    checksum: "sha256:<hash>"
  - name: k9s
    version: v0.51.0
    archive: k9s_Linux_amd64.tar.gz
    member: k9s
    checksum: "sha256:<hash>"

k8s_bastion_clusters:
  - name: lab-k8s
    server: https://lab-k8s-api.lab.local:6443
    namespace: default
```

Setting `k8s_bastion_tools` replaces the whole default list, so list every tool you want.

## Good to know

- Each user adds their own credentials once, for example
  `kubectl config set-credentials lab-k8s --token=<token>`. They are stored in `~/.kube/config`.
- In check mode the completion scripts are skipped, because the tools aren't installed yet.

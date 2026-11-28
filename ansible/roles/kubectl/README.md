# kubectl

Installs a pinned version of `kubectl` and `kubectl-convert` from the internal mirror. Each
version is kept in its own directory, and a symlink in `/usr/local/bin` points at the active one.

| | |
|---|---|
| Playbooks | `playbooks/kubectl.yml`, and `playbooks/k8s_bastion.yml` (before the bastion role) |
| Hosts | `kubectl_hosts` (the Kubernetes bastions are a child group) |
| Tag | `kubectl` |
| Needs first | `certificates` (CA trust for the mirror), `repositories` (for `bash-completion`) |
| Set variables in | `inventories/<ENV>/group_vars/all/main.yml` |
| Longer guide | [docs/kubernetes-clients.md](../../docs/kubernetes-clients.md): mirror layout and download steps |

## What it does

1. Stops if the mirror URL or `kubectl_version` is unset or malformed.
2. Downloads each binary to `<kubectl_install_dir>/<kubectl_version>/` and checks its SHA-256,
   against the `<binary>.sha256` file next to it on the mirror or against `kubectl_checksums`.
3. Links `<kubectl_bin_dir>/<binary>` to that version. Older versions stay on disk.
4. Runs `kubectl version --client` and stops if it doesn't report `kubectl_version`.
5. Installs system-wide bash completion (when `kubectl_bash_completion` is true).

Mirror layout, with the same file names as `dl.k8s.io`:

```
<env_repo_base_url>/kubernetes/kubectl/<kubectl_version>/kubectl
<env_repo_base_url>/kubernetes/kubectl/<kubectl_version>/kubectl.sha256
<env_repo_base_url>/kubernetes/kubectl/<kubectl_version>/kubectl-convert
<env_repo_base_url>/kubernetes/kubectl/<kubectl_version>/kubectl-convert.sha256
```

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `env_repo_base_url` | (inventory) | Base URL of the internal mirror. |
| `kubectl_version` | `""` | Version to install, e.g. `v1.36.5`. Keep it within one minor version of your clusters. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `kubectl_mirror_url` | `<env_repo_base_url>/kubernetes/kubectl` | Where the versions are on the mirror. |
| `kubectl_version_url` | `<kubectl_mirror_url>/<kubectl_version>` | Directory the binaries are downloaded from. |
| `kubectl_binaries` | `[kubectl, kubectl-convert]` | Binaries to install. Must include `kubectl`. |
| `kubectl_checksums` | `{}` | Pinned hashes per binary (`sha256:<hash>`), used instead of the `.sha256` file on the mirror. |
| `kubectl_install_dir` | `/usr/local/lib/kubectl` | Versions are kept in `<this>/<version>/`. |
| `kubectl_bin_dir` | `/usr/local/bin` | Where the symlinks are created. |
| `kubectl_bash_completion` | `true` | Install `/etc/bash_completion.d/kubectl`. |

## Example

```yaml
# inventories/<ENV>/group_vars/all/main.yml
kubectl_version: v1.36.5

# Optional: pin the hashes recorded when downloading on the internet side
kubectl_checksums:
  kubectl: "sha256:<hash>"
  kubectl-convert: "sha256:<hash>"
```

To give another host kubectl (a CI runner, for example), add it to the `kubectl_hosts` group in
`hosts.yml`.

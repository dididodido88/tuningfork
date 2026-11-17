# repositories

Points every Rocky 9 host at the internal mirror: imports the GPG keys, configures the DNF
repositories, and disables every other repository so dnf never tries to reach the internet.

| | |
|---|---|
| Playbook | `playbooks/repositories.yml` (second in `site.yml`, before any play installs packages) |
| Hosts | `rocky9` |
| Tag | `repositories` |
| Needs first | `certificates` (the mirror is HTTPS with a certificate from the internal CA) |
| Set variables in | `inventories/<ENV>/group_vars/all/main.yml` (mirror URL), `group_vars/rocky9.yml` (GPG keys) |

## What it does

1. Stops if the mirror URL or the GPG keys aren't set, or if a repository or key name is unknown.
2. Downloads each GPG key to `/etc/pki/rpm-gpg/` and imports it into the RPM database, checking
   the fingerprint if one is given.
3. Writes each repository with `gpgcheck=1` and a `file://` key path. BaseOS, AppStream and CRB
   go in the stock `rocky.repo` and extras in `rocky-extras.repo`, so each repository ID is
   defined once and the internet `mirrorlist` is removed.
4. Disables every other enabled repository (when `repositories_disable_unmanaged` is true).
5. Runs `dnf makecache --refresh`, which fails straight away if a URL, the TLS trust or a key is
   wrong.

Six repositories are managed: `baseos`, `appstream`, `crb`, `extras`, `epel` and
`docker-ce-stable`. Each URL is `repositories_base_url` plus its path in `repositories_paths`,
so on Rocky 9 the default BaseOS URL is `<env_repo_base_url>/rocky/repo/9/baseos`.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `env_repo_base_url` | (inventory) | Base URL of the internal mirror, in `group_vars/all/main.yml`. |
| `repositories_gpg_keys` | `[]` | Keys to download and import. Each has `name` (file name under `/etc/pki/rpm-gpg/`), `url`, and optional `fingerprint` (the import fails if it doesn't match). |

Optional:

| Variable | Default | Description |
|---|---|---|
| `repositories_base_url` | `{{ env_repo_base_url }}` | Base URL the repository paths are added to. |
| `repositories_paths` | `rocky/repo/$releasever/<repo>` for each repository | Path of each repository below the base URL. Change it if the mirror is laid out differently. |
| `repositories_url_overrides` | `{}` | Full URL for a repository on another server, keyed by repository name. Replaces base URL plus path. |
| `repositories_enabled` | all six | Repositories enabled on the host. One left out is still written, but disabled. |
| `repositories_repo_gpgkeys` | Rocky key for the four Rocky repositories, EPEL key for `epel`, `docker-ce-stable.gpg` for Docker | Which key signs each repository. The names must match `repositories_gpg_keys`. |
| `repositories_list` | the six repositories | Repository definitions: `name`, `file` (the `.repo` file) and `description`. |
| `repositories_sslverify` | `true` | Check the mirror's TLS certificate. |
| `repositories_sslcacert` | `""` | CA bundle for the mirror's certificate if it isn't in the system trust store. |
| `repositories_validate_certs` | `{{ repositories_sslverify }}` | Certificate check for the GPG key downloads. |
| `repositories_disable_unmanaged` | `true` | Disable every enabled repository this role doesn't manage. |

## Example

```yaml
# inventories/<ENV>/group_vars/all/main.yml
env_repo_base_url: https://maestro

# inventories/<ENV>/group_vars/rocky9.yml
repositories_gpg_keys:
  - name: RPM-GPG-KEY-Rocky-9
    url: "{{ repositories_base_url }}/rocky/repo/gpg/RPM-GPG-KEY-Rocky-9"
    fingerprint: 21CB256AE16FC54C6E652949702D426D350D275D
  - name: RPM-GPG-KEY-EPEL-9
    url: "{{ repositories_base_url }}/rocky/repo/gpg/RPM-GPG-KEY-EPEL-9"
  - name: docker-ce-stable.gpg
    url: "{{ repositories_base_url }}/rocky/repo/gpg/docker-ce-stable.gpg"

# Hosts that don't run Docker: leave that repository disabled
repositories_enabled: [baseos, appstream, crb, extras, epel]
```

## Good to know

- RPM keeps the edited `rocky.repo` files when the `rocky-repos` package is upgraded.
- The CIS GPG checks pass: the Rocky release key is imported and every repository has
  `gpgcheck=1`.
- In check mode the key import and the reachability check are skipped.

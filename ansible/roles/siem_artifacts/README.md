# siem_artifacts

Downloads SIEM artifacts from the internal mirror and checks each one against its pinned SHA-256
before anything is installed. Other roles call it for the artifacts they need, then install from
the checked local copies. It works on Linux and Windows hosts.

| | |
|---|---|
| Playbook | `playbooks/siem_artifacts.yml` (checks every artifact), and included by roles such as `wazuh_server` |
| Hosts | `siem_servers` by default, or any host a calling role runs on |
| Tag | `siem_artifacts` |
| Needs first | `certificates` (the mirror is HTTPS with a certificate from the internal CA) |
| Set variables in | `inventories/<ENV>/group_vars/all/siem_versions.yml` (the artifact list and checksums) |
| Longer guide | [docs/siem.md](../../docs/siem.md), "Getting the artifacts" |

## What it does

1. Works out which artifacts are wanted: the keys in `siem_artifacts_required`, or every entry of
   `siem_artifacts` when it is `all`.
2. Stops if the mirror URL isn't `https://`, a requested artifact is unknown, or an artifact has
   no valid SHA-256 pinned. **An artifact with an empty `sha256` is never installed.**
3. Downloads each artifact to the local cache and checks its SHA-256. A file that is already
   there with the right checksum isn't downloaded again. A download that doesn't match fails and
   leaves nothing behind.
4. Sets the fact `siem_artifact_paths`: artifact key to checked local file.

## Using it from another role

```yaml
- name: Download and check the artifacts
  ansible.builtin.include_role:
    name: siem_artifacts
  vars:
    siem_artifacts_required: [wazuh_install_script, wazuh_offline]

- name: Install from the checked copy
  ansible.builtin.command:
    argv: [bash, "{{ siem_artifact_paths['wazuh_install_script'] }}"]
```

## Variables

Inputs from the inventory (`group_vars/all/siem_versions.yml`):

| Variable | Description |
|---|---|
| `siem_mirror_url` | Base URL the artifact paths are relative to. Follows `env_repo_base_url`. Must be `https://`. |
| `siem_artifacts` | The artifact manifest: one entry per artifact, keyed by name, with `path` (below `siem_mirror_url`), `sha256`, and `source` (where to download it on the internet side). |

Role variables:

| Variable | Default | Description |
|---|---|---|
| `siem_artifacts_required` | `[]` | Keys of `siem_artifacts` this host needs, or the string `all`. With an empty list the role downloads nothing. |
| `siem_artifacts_cache_dir` | `/var/cache/tuningfork/siem` | Local cache on Linux hosts. The files are kept, so later runs skip the download. |
| `siem_artifacts_windows_cache_dir` | `C:\ProgramData\Tuningfork\siem` | Local cache on Windows hosts. |
| `siem_artifacts_win_sep` | `\` | Windows path separator. A variable so templates need no backslash escapes. Don't change it. |

Output:

| Fact | Description |
|---|---|
| `siem_artifact_paths` | Dictionary of artifact key to the checked local file. Calls add to it, so a role can call this role more than once. |

## Example

Check every artifact on the mirror:

```sh
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml
```

Before the SIEM VM exists, run the same check on the control node:

```sh
ansible-playbook -i inventories/lab playbooks/siem_artifacts.yml \
  -e siem_artifacts_hosts=localhost -e siem_artifacts_cache_dir=/var/tmp/siem-artifacts-check -K
```

To get the list of files to download and upload to the mirror, run
`playbooks/siem_download_list.yml`.

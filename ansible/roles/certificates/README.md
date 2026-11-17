# certificates

Adds the environment's root CA to the system trust store and installs each host's pre-generated
certificate, private key, PKCS#12 file and full chain. The role doesn't create certificates: it
checks and copies files that already exist on the control node.

| | |
|---|---|
| Playbook | `playbooks/certificates.yml` (first in `site.yml`) |
| Hosts | `rocky9` |
| Tag | `certificates` |
| Needs first | The certificate files on the control node, and `openssl` there |
| Set variables in | `inventories/<ENV>/group_vars/all/main.yml` |

It runs first because every later play that downloads from the HTTPS mirror (`env_repo_base_url`)
needs the internal CA to be trusted.

## Source files

The files are read **on the control node**, outside this repository, as the user who runs
`ansible-playbook` (not as root):

```
<certificates_source_root>/<certificates_env_dir>/ca/ca.cert.pem
<certificates_source_root>/<certificates_env_dir>/<host>/<host>.crt
<certificates_source_root>/<certificates_env_dir>/<host>/<host>.fullchain.crt
<certificates_source_root>/<certificates_env_dir>/<host>/<host>.key
<certificates_source_root>/<certificates_env_dir>/<host>/<host>.p12
```

`<host>` is the short inventory hostname (`registry` for `registry.lab.local`). Give the Ansible
user read access through a group instead of running `sudo ansible-playbook`:

```sh
chgrp -R certdeploy /srv/security/certificates/files
chmod -R g+rX,o-rwx /srv/security/certificates/files
usermod -aG certdeploy ansible
```

## What it does

1. Stops if `certificates_env_dir` is empty.
2. Checks on the control node that the CA file and the host's four files exist and are readable.
3. Checks with `openssl` on the control node (when `certificates_verify` is true) that the
   certificate chains to the CA, the key matches the certificate, the certificate hasn't expired,
   and it covers the host's inventory name. If a check fails, nothing is copied to that host.
4. Copies the CA to the trust anchors directory and runs `update-ca-trust extract` straight away.
5. Copies the host files:

| Source | Destination on the host | Owner and mode |
|---|---|---|
| `ca/ca.cert.pem` | `/etc/pki/ca-trust/source/anchors/<env dir>-root-ca.pem` | root:root 0644 |
| `<host>.crt` | `/etc/pki/tls/certs/host.crt` | root:root 0644 |
| `<host>.fullchain.crt` | `/etc/pki/tls/certs/host.fullchain.crt` | root:root 0644 |
| `<host>.key` | `/etc/pki/tls/private/host.key` | `certificates_key_owner`:`certificates_key_group` 0600 |
| `<host>.p12` | `/etc/pki/tls/private/host.p12` | `certificates_key_owner`:`certificates_key_group` 0600 |

Key contents never appear in logs or `--diff` output.

## Variables

Required:

| Variable | Default | Description |
|---|---|---|
| `certificates_env_dir` | `""` | Folder of this environment under `certificates_source_root`, e.g. `lab.local`. Also names the trust anchor file. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `certificates_source_root` | `/srv/security/certificates/files` | Top of the certificate tree on the control node. |
| `certificates_host_name` | `{{ inventory_hostname_short }}` | Folder and file prefix of a host's files. Set it in host_vars if a host's files are named differently. |
| `certificates_verify` | `true` | Run the `openssl` checks on the control node before copying. |
| `certificates_key_owner` | `root` | Owner of the key and p12 on the host. |
| `certificates_key_group` | `root` | Group of the key and p12. To let a service read the key without running as root, set its group here and the mode to `"0640"` in `certificates_files`. |
| `certificates_files` | crt, fullchain.crt, key, p12 | List of files to copy. Each entry has `suffix`, `dest`, `mode` and `secret` (true for private key material). |
| `certificates_ca_src` | `<source dir>/ca/ca.cert.pem` | Root CA file on the control node. |
| `certificates_ca_anchor_dir` | `/etc/pki/ca-trust/source/anchors` | Trust anchors directory on the host. |
| `certificates_ca_anchor_name` | `<certificates_env_dir>-root-ca.pem` | File name of the trust anchor. |
| `certificates_source_dir` | `<source root>/<env dir>` | Derived. Change the two parts above instead. |
| `certificates_host_source_dir` | `<source dir>/<host name>` | Derived. |

## Example

```yaml
# inventories/lab/group_vars/all/main.yml
certificates_env_dir: lab.local
```

## Trust check for other playbooks (`verify_trust`)

`tasks/verify_trust.yml` is a second entry point. Playbooks that download from the mirror run it
as a pre-task, so a standalone run on a new host stops with a clear message instead of a TLS error:

```yaml
pre_tasks:
  - name: Check the internal CA is trusted (playbooks/certificates.yml ran)
    ansible.builtin.import_role:
      name: certificates
      tasks_from: verify_trust
    tags: [always]
```

It stops the host if the trust anchor file is missing, or if `env_repo_base_url` (when it is an
`https://` URL) can't be reached with certificate validation on.

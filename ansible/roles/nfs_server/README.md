# nfs_server

Configures an NFS server: installs `nfs-utils`, creates the export directories, writes
`/etc/exports`, starts `nfs-server` and opens the firewall.

| | |
|---|---|
| Playbook | `playbooks/nfs_server.yml` |
| Hosts | `nfs_servers` |
| Tags | `nfs_server`, `firewall` |
| Needs first | `repositories`. Put the exports on a data disk with `filesystems`. |
| Set variables in | `inventories/<ENV>/group_vars/nfs_servers.yml` |

## What it does

1. Installs `nfs_server_packages`.
2. Creates each export directory with its owner, group and mode.
3. Writes `/etc/exports` and re-exports (`exportfs -ra`) when it changes.
4. Enables and starts `nfs-server`.
5. Opens `nfs_server_firewall_services` in firewalld (when `nfs_server_manage_firewall` is true).

`/etc/exports` is written as a whole: an export that is removed from `nfs_server_exports` is
removed from the file. Its directory and data are left in place.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `nfs_server_exports` | `[]` | Exports to publish. See the fields below. |

Fields of one export:

| Field | Required | Default | Description |
|---|---|---|---|
| `path` | yes | | Directory to export. Created if missing. |
| `owner` | no | `root` | Owner of the directory. |
| `group` | no | `root` | Group of the directory. |
| `mode` | no | `"0755"` | Mode of the directory. Quote it. |
| `clients` | yes | | List of clients. Each has `host` (an address, network or host name) and optional `options` (default `rw,sync,root_squash`). |

Optional:

| Variable | Default | Description |
|---|---|---|
| `nfs_server_packages` | `[nfs-utils]` | Packages to install. |
| `nfs_server_manage_firewall` | `true` | Open the services below in firewalld. |
| `nfs_server_firewall_services` | `[nfs, mountd, rpc-bind]` | firewalld services opened in the default zone. |

## Example

```yaml
# inventories/<ENV>/group_vars/nfs_servers.yml
nfs_server_exports:
  - path: /srv/nfs/share
    mode: "0775"
    clients:
      - host: 192.0.2.0/24
        options: rw,sync,root_squash
      - host: backup01.example.internal
        options: ro,sync

# Data disk for the exports (roles/filesystems)
filesystems_volumes__nfs:
  - mount: /srv/nfs
    disk: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:8:0
    fstype: xfs
```

## Good to know

CIS would remove or mask the NFS and rpcbind services. `playbooks/group_vars/nfs_servers.yml`
keeps them on these hosts in every environment.

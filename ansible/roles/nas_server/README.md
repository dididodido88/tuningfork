| Needs first | `repositories`, and `filesystems` to mount the data disks Terraform creates (one per export, `terraform/_envcommon/roles/nas.hcl`). |# nas_server

Configures the NAS server, which serves the clusters' persistent data over NFS: installs
`nfs-utils`, creates the export directories, writes
`/etc/exports`, starts `nfs-server` and opens the firewall.

| | |
|---|---|
| Playbook | `playbooks/nas_server.yml` |
| Hosts | `nas_servers` |
| Tags | `nas_server`, `firewall` |
| Needs first | `repositories`, and `filesystems` to mount the data disks Terraform creates (one per export, `terraform/_envcommon/roles/nas.hcl`). |
| Set variables in | `inventories/<ENV>/group_vars/nas_servers.yml` |

## What it does

1. Installs `nas_server_packages`.
2. Creates each export directory with its owner, group and mode.
3. Writes `/etc/exports` and re-exports (`exportfs -ra`) when it changes.
4. Enables and starts `nfs-server`.
5. When `nas_server_manage_firewall` is true, stops if `nas_server_firewall_sources` is empty. Then it adds
   one firewalld rich rule per source and service, so only those sources reach NFS. It also removes
   the services from the zone, in case an earlier version of this role opened them to every source.

`/etc/exports` is written as a whole: an export that is removed from `nas_server_exports` is
removed from the file. Its directory and data are left in place.

## Variables

Required per environment:

| Variable | Default | Description |
|---|---|---|
| `nas_server_exports` | `[]` | Exports to publish. See the fields below. |
| `nas_server_firewall_sources` | `[]` | Networks (CIDR) or single addresses allowed through firewalld to NFS. Required while `nas_server_manage_firewall` is true. Keep it in line with the export `clients`. |

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
| `nas_server_packages` | `[nfs-utils]` | Packages to install. |
| `nas_server_manage_firewall` | `true` | Manage the NFS rules in firewalld. |
| `nas_server_firewall_services` | `[nfs, mountd, rpc-bind]` | firewalld services opened to `nas_server_firewall_sources`, in the default zone. |

## Example

```yaml
# inventories/<ENV>/group_vars/nas_servers.yml
nas_server_exports:
  - path: /export/deliveries
    mode: "0775"
    clients:
      - host: 192.0.2.0/24
        options: rw,sync,root_squash
      - host: backup01.example.internal
        options: ro,sync

nas_server_firewall_sources:
  - 192.0.2.0/24
  - 198.51.100.40       # backup01
```

## Good to know

Each export should sit on its own data disk. Terraform creates the disks and writes them into the
inventory, and `filesystems` mounts them under `/export/`. An export path with no disk behind it
is created on the root file system.

CIS would remove or mask the NFS and rpcbind services. `playbooks/group_vars/nas_servers.yml`
keeps them on these hosts in every environment.

# database_server

Installs and starts a database server. Only PostgreSQL is implemented, from the AppStream module
stream on the internal mirror.

| | |
|---|---|
| Playbook | `playbooks/database_server.yml` |
| Hosts | `db_servers` |
| Tags | `database_server`, `firewall` |
| Needs first | `repositories`. Put `/var/lib/pgsql` on a data disk with `filesystems`. |
| Set variables in | `inventories/<ENV>/group_vars/db_servers.yml` |

## What it does

1. Stops if `database_server_engine` isn't a supported engine.
2. Installs the PostgreSQL server from the module stream `database_server_postgresql_stream`.
3. Initialises the database cluster with `postgresql-setup --initdb`, once.
4. Enables and starts the `postgresql` service.
5. Opens the PostgreSQL port in firewalld (when `database_server_manage_firewall` is true).

The role doesn't create databases or users, and doesn't edit `postgresql.conf` or `pg_hba.conf`.

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `database_server_engine` | `postgresql` | Database engine. Only `postgresql` is implemented. |
| `database_server_postgresql_stream` | `"16"` | AppStream module stream (major version) to install. Keep the quotes. |
| `database_server_postgresql_data_dir` | `/var/lib/pgsql/data` | Where the role looks for an existing cluster (`PG_VERSION`) before running initdb. It doesn't move the data directory. |
| `database_server_postgresql_port` | `5432` | Port opened in firewalld. It doesn't change the port PostgreSQL listens on. |
| `database_server_manage_firewall` | `true` | Open the port in firewalld. |

## Example

```yaml
# inventories/<ENV>/group_vars/db_servers.yml
database_server_postgresql_stream: "16"

# Data disk for PostgreSQL (roles/filesystems)
filesystems_volumes__db:
  - mount: /var/lib/pgsql
    disk: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:8:0
    fstype: xfs
    owner: postgres
    group: postgres
    mode: "0700"
```

## Adding another engine

Add `tasks/<engine>.yml`, add the engine name to the check in `tasks/main.yml`, and add its
`database_server_<engine>_*` defaults.

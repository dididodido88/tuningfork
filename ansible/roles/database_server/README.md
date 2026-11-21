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
3. Initialises the database cluster with `postgresql-setup --initdb`, once, with **UTF-8
   encoding** and the locale `C.UTF-8`.
4. Sets `timezone` and `log_timezone` in `postgresql.conf` to **UTC**, and reloads PostgreSQL
   if they changed.
5. Enables and starts the `postgresql` service.
6. Sets the password of the built-in `postgres` superuser from the vault, only when it differs.
7. Checks what the running cluster uses: the encoding of `template1` (the default for every new
   database) and both time zones. Stops if they differ from the settings.
8. Opens the PostgreSQL port in firewalld (when `database_server_manage_firewall` is true).

The role doesn't create databases or other users, and doesn't edit `pg_hba.conf`. In `postgresql.conf`
it changes only `timezone` and `log_timezone`.

## Encoding and time zone

| Setting | When it applies | On an existing cluster |
|---|---|---|
| Encoding (`UTF8`) and locale (`C.UTF-8`) | Only when the cluster is created | Never changed. The play stops if the encoding differs, and reports a different locale. |
| Time zone (`UTC`) | Every run | Changed in `postgresql.conf` and applied with a reload, without a restart. |

**Why the encoding is set explicitly.** Without it, `initdb` takes the encoding from the locale of
the session that runs it. An Ansible session often runs with the plain `C` locale, and the
cluster is then created as `SQL_ASCII`, which stores bytes without checking them.

**Why `C.UTF-8`.** It sorts by Unicode code point, so indexes stay valid when glibc is upgraded,
and it is part of the base system. Choose a language locale such as `en_US.UTF-8` only if
applications need language-aware sorting; that also needs the matching `glibc-langpack-*` package.

**A cluster created with another encoding.** The encoding can't be changed in place:

- No data yet: `systemctl stop postgresql`, move `/var/lib/pgsql/data` aside, and run the play
  again. It creates the cluster with UTF-8.
- With data: back up with `pg_dumpall`, create the cluster again as above, and restore.

## The postgres password

The password of the built-in `postgres` superuser comes from the vault:

```yaml
# inventories/<ENV>/group_vars/all/vault.yml (encrypted)
vault_postgresql_postgres_password: "<at least 12 characters, ASCII only>"
```

The play stops before changing anything if it is missing, shorter than 12 characters, or
`CHANGEME`. To change the password, change it in the vault and run the play again.

How it is set:

- The role reads the stored password hash (`pg_authid`), and compares it with the vault password
  on the host. If they match, nothing changes, so a re-run reports `ok`.
- If they differ, it makes the SCRAM-SHA-256 hash on the host (`files/scram_verifier.py`) and gives
  PostgreSQL only the hash. The password itself never reaches PostgreSQL, so it can't appear in
  the server log, and it is never on a command line or in Ansible's output.

**When the password is used.** `pg_hba.conf` decides which logins ask for a password, and the role
leaves it as Rocky creates it: local logins on the host use `peer` (no password), so
`sudo -u postgres psql` keeps working, and network logins aren't accepted with a password yet. The
password applies once `pg_hba.conf` allows password logins (`scram-sha-256`) for a connection.

**The time zone** controls how PostgreSQL shows and reads timestamps for clients that don't set
their own, and the times written in its log. A client can still choose another zone for its
session (`SET TIME ZONE`, or the `PGTZ` variable). The host's own time zone isn't changed.

## Variables

Required (in the vault):

| Variable | Description |
|---|---|
| `vault_postgresql_postgres_password` | Password of the built-in `postgres` superuser. At least 12 characters, ASCII only. Read through `database_server_postgresql_postgres_password`. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `database_server_engine` | `postgresql` | Database engine. Only `postgresql` is implemented. |
| `database_server_postgresql_stream` | `"16"` | AppStream module stream (major version) to install. Keep the quotes. |
| `database_server_postgresql_data_dir` | `/var/lib/pgsql/data` | Where the role looks for an existing cluster (`PG_VERSION`) before running initdb. It doesn't move the data directory. |
| `database_server_postgresql_port` | `5432` | Port opened in firewalld. It doesn't change the port PostgreSQL listens on. |
| `database_server_postgresql_encoding` | `UTF8` | Encoding the cluster is created with. Only used when the cluster is created. |
| `database_server_postgresql_locale` | `C.UTF-8` | Locale the cluster is created with (sorting and case rules). Only used when the cluster is created. |
| `database_server_postgresql_timezone` | `UTC` | Value of `timezone` and `log_timezone`. Applied on every run. |
| `database_server_postgresql_postgres_password` | `{{ vault_postgresql_postgres_password }}` | Password of the `postgres` superuser. Set the vault variable instead. |
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

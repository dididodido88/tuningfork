# filesystems

Sets up data disks: partitions a blank disk, formats it, copies any existing data across, and
mounts it by UUID with the mount options CIS requires for that path.

| | |
|---|---|
| Playbook | `playbooks/filesystems.yml` (before CIS in `site.yml`) |
| Hosts | `linux` |
| Tag | `filesystems` |
| Needs first | `repositories` (it installs parted, e2fsprogs, xfsprogs, rsync) |
| Set variables in | any group_vars or host_vars file, in a variable named `filesystems_volumes__<something>` |
| Background | [ansible/README.md](../../README.md), "Data disks" |

A disk is used only if it is **blank**, or already holds exactly the one partition this role
creates. A disk with any other data is never touched. The role does nothing on a host with no
volumes defined.

## What it does

1. **Validates every volume before changing anything.** Each disk must be given by a stable
   `/dev/disk/by-path/...` or `/dev/disk/by-id/...` path, be a whole disk, not hold `/`, `/boot`
   or swap, and be at least `min_size_gb`. No mount point or disk may be listed twice.
2. **Partitions**: GPT with one partition from 1 MiB to the end of the disk.
3. **Formats**: ext4 by default. An existing filesystem is never reformatted.
4. **Migrates**: if the directory already has content, copies it to the new filesystem with
   `rsync -aAXHx`, which keeps permissions, ACLs, xattrs and SELinux labels.
5. **Mounts by UUID** and writes the `UUID=` entry to `/etc/fstab`.
6. **Switches over without a reboot**: restarts the services in `filesystems_restart_services`,
   remounts pseudo-filesystems below the path, and lists any process still using the old copy.
7. **Verifies** each mount, its fstab entry and its options, then runs `findmnt --verify`.

## Defining volumes

Every variable whose name starts with `filesystems_volumes__` is combined into one list, so each
level adds volumes instead of replacing them:

```yaml
# inventories/<ENV>/group_vars/linux.yml
filesystems_volumes__base:
  - mount: /var/log
    disk: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:2:0
    min_size_gb: 20

# inventories/<ENV>/group_vars/db_servers.yml
filesystems_volumes__db:
  - mount: /var/lib/pgsql
    disk: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:8:0
    fstype: xfs
    owner: postgres
    group: postgres
    mode: "0700"
```

Run `ls -l /dev/disk/by-path/` on the host to find a disk's stable path.

Fields of one volume:

| Field | Required | Default | Description |
|---|---|---|---|
| `mount` | yes | | Absolute path of the mount point. |
| `disk` | yes | | Stable path to the **whole** disk, under `/dev/disk/by-path/` or `/dev/disk/by-id/`. |
| `fstype` | no | `filesystems_default_fstype` | Filesystem type. Must be in `filesystems_supported_fstypes`. |
| `mkfs_opts` | no | | Extra mkfs options, e.g. `"-m 1"`. |
| `label` | no | | Filesystem label (ext4: 16 characters at most, xfs: 12). |
| `mount_opts` | no | `[]` | Extra mount options, added to `defaults` and the CIS options. |
| `owner`, `group`, `mode` | no | copied from the existing directory, else `root:root 0755` (`1777` for `/tmp` and `/var/tmp`) | Owner, group and mode of the mount root. Quote the mode. |
| `migrate` | no | `filesystems_migrate` | Copy existing content onto the new disk. |
| `min_size_gb` | no | `0` | Refuse a disk smaller than this. A guard against picking the wrong disk. |

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `filesystems_default_fstype` | `ext4` | Filesystem type when a volume sets none. |
| `filesystems_supported_fstypes` | `[ext4, xfs]` | Types a volume may use. To add one, also add its mkfs package to `filesystems_packages`. |
| `filesystems_packages` | `[parted, e2fsprogs, xfsprogs, rsync, util-linux]` | Tools the role installs. |
| `filesystems_default_mount_opts` | `[defaults]` | Options every volume starts with. |
| `filesystems_migrate` | `true` | Copy existing content before mounting over a directory. |
| `filesystems_apply_cis_options` | true on hosts in `rocky9` | Add the CIS `nodev`, `nosuid` and `noexec` options for the paths CIS checks. |
| `filesystems_restart_services` | journald, rsyslog, auditd, chronyd by mount point | Services restarted after migrating `/var`, `/var/log` or `/var/log/audit`, so they write to the new filesystem. Only running services are restarted. |
| `filesystems_tmp_dir` | `/mnt/.filesystems` | Temporary mount location used while copying data. |
| `filesystems_passno` | `{xfs: 0, default: 2}` | fsck pass number in fstab, by filesystem type. |

`vars/main.yml` holds the table of CIS mount options per path (`filesystems_cis_mount_options`).
Each option is added only while its `rhel9cis_rule_1_1_2_*` rule is enabled.

## Good to know

- **Why before CIS:** when a CIS mount option is missing, the CIS role rewrites that fstab line
  with a device name and drops `UUID=`. This role sets the options first, so CIS changes nothing.
- A volume's `mount_opts` may not cancel an enabled CIS option (for example `exec` on `/tmp`).
- A disk-based `/tmp` needs `rhel9cis_tmp_svc: false` (the default).
- After a migration the original files stay on the root filesystem, hidden under the new mount.
  They are harmless but use space.
- The role doesn't resize. To grow a filesystem, resize the virtual disk, then run
  `growpart <disk> 1` and `resize2fs` or `xfs_growfs`.
- In check mode the role reports what it would create and skips the verification.

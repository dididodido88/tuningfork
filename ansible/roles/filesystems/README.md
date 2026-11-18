# filesystems

Turns empty data disks into mounted filesystems: partitions the disk, formats it, copies any
existing data across, and mounts it by UUID with the mount options CIS requires for that path.

| | |
|---|---|
| Playbook | `playbooks/filesystems.yml` (before CIS in `site.yml`) |
| Hosts | `linux` |
| Tag | `filesystems` |
| Needs first | `repositories` (it installs parted, e2fsprogs, xfsprogs, rsync) |
| Set variables in | Terraform writes them for the VMs it builds. For other hosts: a variable named `filesystems_volumes__<something>` in group_vars or host_vars |
| Related | [terraform/README.md](../../../terraform/README.md), "Data disks"; [ansible/README.md](../../README.md), "Data disks" |

The role does nothing on a host with no volumes defined, and it is safe to run again at any time.

## Design in one page

**Who does what.** Terraform creates each virtual disk, empty, and tells Ansible which disk
belongs to which mount point. This role does everything inside the guest.

**How a disk is identified.** Three names are used, one after the other:

| Stage | Name | Why |
|---|---|---|
| Finding the disk | `/dev/disk/by-id/...` or `/dev/disk/by-path/...` | Fixed by where the disk is attached to the VM. Names like `/dev/sdb` can change between boots and are refused. |
| Recognising it on later runs | The partition name, e.g. `var-log` | The role names the one partition it creates after the mount point. A disk whose partition carries another name belongs to another volume. |
| Mounting it | The filesystem UUID in `/etc/fstab` | Doesn't depend on device names or on the order disks are found in. |

**The rule the role follows.** A disk is used only if it is one of these:

- **Blank**: no partition table, no filesystem, no signature of any kind.
- **Already set up by this role for this mount point**: one GPT partition, named after the volume,
  holding the volume's filesystem type, and not mounted anywhere else.

Anything else is left untouched and the play stops with a message that says what was found.

## What it does, in order

1. **Validates every volume before changing anything.** If one volume fails a check, no disk on
   that host is touched.
2. **Partitions** a blank disk: GPT with one partition from 1 MiB to the end, named after the
   label or the mount point (`/var/log` becomes `var-log`).
3. **Formats** the partition if it has no filesystem. An existing filesystem is never reformatted.
4. **Migrates**: if the directory already has content (for example `/var/log` on a new host),
   copies it onto the new, empty filesystem with `rsync -aAXHx`, which keeps permissions, ACLs,
   xattrs and SELinux labels.
5. **Mounts by UUID** and writes the `UUID=` entry to `/etc/fstab`, with the CIS options.
6. **Switches over without a reboot**: restarts the services in `filesystems_restart_services`,
   remounts pseudo-filesystems below the path, and lists any process still using the old copy.
7. **Verifies** each mount, its fstab entry and its options, then runs `findmnt --verify`.

On a host that is already set up, steps 2 to 6 find nothing to do.

## How existing data is protected

| Situation | What the role does |
|---|---|
| The disk holds a partition table, a filesystem or any signature the role didn't create | Stops. The disk isn't touched. |
| The disk is one of the OS disks (`/`, `/boot`, swap) | Stops. |
| The disk's partition is named after another volume (disks reordered or removed, so the slots shifted) | Stops, even if the disk isn't mounted. |
| The disk's filesystem is mounted on another path | Stops. |
| The disk is smaller than `min_size_gb` (Terraform sets this to the size it created) | Stops: the wrong disk is in that slot. |
| The filesystem type in the configuration no longer matches the disk | Stops. It never reformats. |
| The disk is already mounted where it should be | Nothing is copied or changed. |
| The disk isn't mounted, the directory has content, and the filesystem is **empty** | Copies the directory onto it, then mounts it (step 4). |
| The disk isn't mounted, the directory has content, and the filesystem **already holds data** | **Stops and changes nothing.** See below. |

**The last case** happens when a data disk that is in use gets unmounted (maintenance, a failed
mount) and something writes to the directory underneath. There are then two copies of the data,
and only you know which one to keep. The message names both. Then run the play once with one of:

```sh
# Keep the data on the disk. The disk is mounted over the directory; the directory's content
# stays underneath, hidden. Move it away first if you need it.
ansible-playbook -i inventories/<ENV> playbooks/filesystems.yml --limit <host> -e filesystems_migrate=false

# Keep the directory's content. The disk is made identical to the directory:
# EVERYTHING ELSE ON THE DISK IS DELETED.
ansible-playbook -i inventories/<ENV> playbooks/filesystems.yml --limit <host> -e filesystems_migrate_overwrite=true
```

Pass these on the command line for that one run. Never put them in the inventory.

## Defining volumes

### VMs built by Terraform

Nothing to define here. Terraform writes each VM's disks into
`inventories/<ENV>/terraform_<unit>.yml` as `filesystems_volumes__terraform`:

```yaml
filesystems_volumes__terraform:
  - mount: /var/log
    disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
    min_size_gb: 10
    fstype: ext4
  - mount: /export/pvcdata
    disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
    min_size_gb: 50
    fstype: xfs
```

To add, grow or move a disk, change it in Terraform (see `terraform/README.md`, "Data disks"),
apply, then run this playbook. Don't repeat these volumes by hand in group_vars or host_vars: a
mount point listed twice stops the play.

### Other hosts

Every variable whose name starts with `filesystems_volumes__` is combined into one list, so each
level adds volumes instead of replacing them:

```yaml
# inventories/<ENV>/group_vars/linux.yml
filesystems_volumes__base:
  - mount: /var/log
    disk: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:2:0
    min_size_gb: 20

# inventories/<ENV>/host_vars/<host>.yml
filesystems_volumes__host:
  - mount: /var/lib/pgsql
    disk: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
    fstype: xfs
    owner: postgres
    group: postgres
    mode: "0700"
```

Run `ls -l /dev/disk/by-id/ /dev/disk/by-path/` on the host to find a disk's stable path.

### Fields of one volume

| Field | Required | Default | Description |
|---|---|---|---|
| `mount` | yes | | Absolute path of the mount point. |
| `disk` | yes | | Stable path to the **whole** disk, under `/dev/disk/by-id/` or `/dev/disk/by-path/`. |
| `fstype` | no | `filesystems_default_fstype` | Filesystem type. Must be in `filesystems_supported_fstypes`. Only used when the disk is first formatted. |
| `min_size_gb` | no | `0` | Refuse a disk smaller than this. A guard against the wrong disk. |
| `label` | no | | Filesystem label (ext4: 16 characters at most, xfs: 12). Also used as the partition name. Don't change it after the disk is set up. |
| `mkfs_opts` | no | | Extra mkfs options, e.g. `"-m 1"`. |
| `mount_opts` | no | `[]` | Extra mount options, added to `defaults` and the CIS options. |
| `owner`, `group`, `mode` | no | copied from the existing directory, else `root:root 0755` (`1777` for `/tmp` and `/var/tmp`) | Owner, group and mode of the mount root. Quote the mode. |
| `migrate` | no | `filesystems_migrate` | Copy existing content onto the new, empty disk. |

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `filesystems_default_fstype` | `ext4` | Filesystem type when a volume sets none. |
| `filesystems_supported_fstypes` | `[ext4, xfs]` | Types a volume may use. To add one, also add its mkfs package to `filesystems_packages`. |
| `filesystems_packages` | `[parted, e2fsprogs, xfsprogs, rsync, util-linux]` | Tools the role installs. |
| `filesystems_default_mount_opts` | `[defaults]` | Options every volume starts with. |
| `filesystems_migrate` | `true` | Copy existing content before mounting over a directory. The copy only happens onto an empty filesystem. |
| `filesystems_migrate_overwrite` | `false` | Allow the copy onto a filesystem that already holds data, deleting everything else on it. For one run, on the command line. |
| `filesystems_check_partition_name` | `true` | Accept an existing partition only if it is named after its volume. Turn it off only for disks partitioned outside this role. |
| `filesystems_apply_cis_options` | true on hosts in `rocky9` | Add the CIS `nodev`, `nosuid` and `noexec` options for the paths CIS checks. |
| `filesystems_restart_services` | journald, rsyslog, auditd, chronyd by mount point | Services restarted after migrating `/var`, `/var/log` or `/var/log/audit`, so they write to the new filesystem. Only running services are restarted. |
| `filesystems_tmp_dir` | `/mnt/.filesystems` | Temporary mount location used while copying data. |
| `filesystems_passno` | `{xfs: 0, default: 2}` | fsck pass number in fstab, by filesystem type. |

`vars/main.yml` holds the table of CIS mount options per path (`filesystems_cis_mount_options`).
Each option is added only while its `rhel9cis_rule_1_1_2_*` rule is enabled.

## Common tasks

| Task | How |
|---|---|
| Add a disk | Add the volume (Terraform: append it to `data_disks` and apply), then run the playbook. |
| Grow a filesystem | Grow the virtual disk (Terraform: raise `size_gb` and apply). On the host: `growpart <disk> 1`, then `xfs_growfs <mount>` or `resize2fs <partition>`. The role doesn't resize. |
| See what the role would do | `ansible-playbook ... playbooks/filesystems.yml --limit <host> --check`. It reports what it would create and skips the verification. |
| Stop managing a volume | Remove it from the configuration. The role leaves the mount and its fstab entry in place; unmount and remove them by hand if you want them gone. |
| Reuse a disk that held something else | Check it is the right disk and holds nothing you need, then `wipefs -a <disk>` on the host and run the playbook. |
| Free the space of migrated data | After a migration the original files stay on the root filesystem, hidden under the new mount. `mount --bind / /mnt/root`, remove the hidden copy under `/mnt/root/<path>`, `umount /mnt/root`. |

## When the play stops

| Message contains | Meaning | What to do |
|---|---|---|
| `is neither blank nor the disk this role set up` | The disk holds something else, or another volume's disk is in this slot. | Compare the partition name in the message with the expected one. If they differ, the disk order changed: restore the order in Terraform. Wipe the disk only if it is truly the right one and empty of anything you need. |
| `is not usable (type ..., OS disk: ..., minimum ...)` | The path isn't a whole disk, is an OS disk, or the disk is smaller than `min_size_gb`. | Check the disk path and the size in the configuration. |
| `does not exist` | No disk at that path. | The disk isn't attached. Check Terraform applied, and the slot number. |
| `both the directory and the filesystem hold data` | Two copies of the data exist. | See "How existing data is protected". |
| `already has another filesystem mounted` | Something else is mounted on the mount point. | Unmount it, or remove the volume. |
| `mount_opts ... cancel CIS options` | A volume's `mount_opts` contradicts a CIS option (for example `exec` on `/tmp`). | Remove the option, or disable the matching `rhel9cis_rule_1_1_2_*` rule. |
| `listed more than once` | The same volume is defined twice, often in two files under different variable names. The message lists every `filesystems_volumes__*` variable and its mount points. | Usually a hand-written `host_vars` entry for a VM that Terraform now manages. Keep `filesystems_volumes__terraform` and remove the hand-written one. |

## Good to know

- **Why before CIS:** when a CIS mount option is missing, the CIS role rewrites that fstab line
  with a device name and drops `UUID=`. This role sets the options first, so CIS changes nothing.
- A disk-based `/tmp` needs `rhel9cis_tmp_svc: false` (the default).
- Migrating a busy path (`/var`) without a reboot is safe on a freshly built host. On a
  long-running host, stop the applications that write there first, or reboot after the play.

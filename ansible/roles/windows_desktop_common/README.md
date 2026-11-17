# windows_desktop_common

Settings for Windows 11 Desktop hosts only. **The role has no tasks yet.** It is the place to add
configuration that desktops need and servers don't.

| | |
|---|---|
| Playbook | `playbooks/windows_common.yml` (third play, after `windows_common`) |
| Hosts | `windows_desktop` |
| Tag | `windows_desktop_common` |
| Set variables in | `inventories/<ENV>/group_vars/windows_desktop.yml` |

## Variables

None yet.

## Adding a task

1. Add a task file, for example `tasks/<area>.yml`.
2. Import it from `tasks/main.yml` with a switch and a tag:

   ```yaml
   - name: Configure <area>
     ansible.builtin.import_tasks: <area>.yml
     when: windows_desktop_common_<area>_enabled | bool
     tags: [windows_desktop_common, <area>]
   ```

3. Add the defaults to `defaults/main.yml`, named `windows_desktop_common_<area>_*`.
4. Add the variables to this README.

A setting that every Windows host needs belongs in `windows_common` instead.

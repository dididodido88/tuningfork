# windows_server_common

Settings for Windows Server hosts only. **The role has no tasks yet.** It is the place to add
configuration that servers need and desktops don't.

| | |
|---|---|
| Playbook | `playbooks/windows_common.yml` (second play, after `windows_common`) |
| Hosts | `windows_server` |
| Tag | `windows_server_common` |
| Set variables in | `inventories/<ENV>/group_vars/windows_server.yml` |

## Variables

None yet.

## Adding a task

1. Add a task file, for example `tasks/<area>.yml`.
2. Import it from `tasks/main.yml` with a switch and a tag:

   ```yaml
   - name: Configure <area>
     ansible.builtin.import_tasks: <area>.yml
     when: windows_server_common_<area>_enabled | bool
     tags: [windows_server_common, <area>]
   ```

3. Add the defaults to `defaults/main.yml`, named `windows_server_common_<area>_*`.
4. Add the variables to this README.

A setting that every Windows host needs belongs in `windows_common` instead.

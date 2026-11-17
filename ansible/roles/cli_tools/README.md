# cli_tools

Installs the same command-line tools and SELinux utilities on every Rocky 9 host, from the
internal mirror.

| | |
|---|---|
| Playbook | `playbooks/cli_tools.yml` |
| Hosts | `rocky9` |
| Tag | `cli_tools` |
| Needs first | `repositories` (most tools come from EPEL) |
| Set variables in | `inventories/<ENV>/group_vars/rocky9.yml` (only if you change the defaults) |

## What it does

One task: installs `cli_tools_packages` plus `cli_tools_extra_packages` with dnf. If the mirror
lacks a package (for example EPEL isn't synced), the play fails and names it.

| Tool | Package | Repository | Command |
|---|---|---|---|
| btop | `btop` | EPEL | `btop` |
| htop | `htop` | EPEL | `htop` |
| jq | `jq` | AppStream | `jq` |
| yq (Go, v4) | `yq` | EPEL | `yq` |
| tree | `tree` | BaseOS | `tree` |
| ripgrep | `ripgrep` | EPEL | `rg` |
| fd | `fd-find` | EPEL | `fd` |
| bat | `bat` | EPEL | `bat` |
| SELinux core tools | `policycoreutils` | BaseOS | `restorecon`, `semodule`, `setfiles`, `fixfiles` |
| SELinux management | `policycoreutils-python-utils` | AppStream | `semanage`, `audit2allow`, `audit2why` |

## Variables

All optional:

| Variable | Default | Description |
|---|---|---|
| `cli_tools_packages` | the ten packages above | Base package list. Prefer `cli_tools_extra_packages` over replacing this list. |
| `cli_tools_extra_packages` | `[]` | More packages for an environment or a group. |
| `cli_tools_state` | `present` | `present` installs what is missing. `latest` also upgrades on every run. |

## Example

```yaml
# inventories/<ENV>/group_vars/rocky9.yml
cli_tools_extra_packages: [tmux, strace]
```

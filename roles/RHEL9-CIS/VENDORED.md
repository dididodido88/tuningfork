# Vendored role: RHEL9-CIS

| | |
|---|---|
| Upstream | https://github.com/ansible-lockdown/RHEL9-CIS |
| Tag | 2.2.0 |
| Commit | b98381fcd8e29b44c466913d81ffb8b8a1a62cb0 |
| CIS benchmark | RHEL 9 v2.0.0 |
| Vendored on | 2026-11-06 |

Why 2.2.0: releases from 2.3.0 onward require ansible-core 2.16.1. The control node runs ansible-core 2.14.18.

## Local changes

None. Do not edit files in this directory. Configure the role through variables in:

- `playbooks/group_vars/rocky9.yml`: CIS rules handed over to `linux_common`, and the CIS variables that are set from `linux_common_*` values.
- `inventories/<ENV>/group_vars/rocky9.yml`: environment-specific CIS settings.

## Refreshing

On an internet-connected machine, from the repository root:

```sh
rm -rf roles/RHEL9-CIS
git clone --depth 1 --branch <TAG> https://github.com/ansible-lockdown/RHEL9-CIS roles/RHEL9-CIS
git -C roles/RHEL9-CIS rev-parse HEAD   # record this commit in VENDORED.md
rm -rf roles/RHEL9-CIS/.git
```

Then put this file back, update the table, and check that the rule and variable names in `playbooks/group_vars/rocky9.yml` still exist in `roles/RHEL9-CIS/defaults/main.yml`.

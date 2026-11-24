# Module `rancher-config`

Configures Rancher Server once the `rancher-server` unit has installed it:
- the local admin's password and the server URL;
- Active Directory login over LDAPS, limited to two AD groups;
- what those groups may do.

It is called by `terraform/k8s/<ENV>/rancher-config`, which is applied by hand after
`terraform/k8s/<ENV>/rancher-server`.

Guide: [ansible/docs/rancher.md](../../../ansible/docs/rancher.md). Every input is described in
[variables.tf](variables.tf).

## What it creates

| Resource | What it is |
|---|---|
| `rancher2_bootstrap.admin` | Logs in with the bootstrap password, sets the local `admin` password to `rancher_admin_password`, sets the server URL, turns telemetry off, and returns an admin API token the other resources use |
| `rancher2_auth_config_activedirectory.ad` | AD login: LDAPS to `ad_servers` on 636, trusting the internal CA, bound as `ad_service_account_username`. Access mode `restricted`: only the two groups below, and the test account by name, may log in. |
| `rancher2_global_role_binding.admins` | Admin group → global role `admin` |
| `rancher2_global_role_binding.viewers_login` | Viewer group → global role `user-base` (may log in) |
| `rancher2_global_role.cluster_viewer` | Global role "Cluster Viewer". Its inherited cluster roles (`viewer_cluster_roles`) apply in every downstream cluster, present and future. |
| `rancher2_global_role_binding.viewers_clusters` | Viewer group → Cluster Viewer |
| `rancher2_cluster_role_template_binding.viewers_local` | Viewer group → each of `viewer_cluster_roles` in the `local` (Rancher) cluster, which inherited cluster roles don't reach |

**Read-only cluster roles given to the viewer group** (Rancher's built-in role templates):

| Role template | Rancher's name | Lets them see |
|---|---|---|
| `projects-view` | View All Projects | Every project and its resources |
| `nodes-view` | View Nodes | The nodes |
| `clusterroletemplatebindings-view` | View Cluster Members | Who has access to the cluster |
| `clustercatalogs-view` | View Cluster Catalogs | The cluster's chart repositories |

## The test account becomes an admin

When AD login is turned on, Rancher logs in as `ad_test_username` to check the settings and links
that account to the local `admin`. It is a Rancher administrator from then on. So:
- use a dedicated account, such as `svc_rancher_admin`;
- never the bind account (the module refuses it);
- keep it out of every AD group, so it opens nothing but Rancher. It needs no group: the link
  makes it an admin, and the module allows it to log in by name (`ad_test_user_dn`). Rancher also
  adds it to the allowed list itself, so listing it keeps the next plan clean.

The local `admin` keeps working with `rancher_admin_password` as the break-glass login.

## Inputs you set in the unit

| Input | Lab value | Description |
|---|---|---|
| `certificate_dir` | `/srv/security/certificates/files/lab.local` | Reads the internal root CA, `ca/ca.cert.pem` |
| `ad_default_login_domain` | `LAB` | NetBIOS domain name; users log in with their account name alone |
| `ad_service_account_username` | `svc_ldap_bind` | The read-only bind account, shared with Harbor |
| `ad_test_username`, `ad_test_user_dn` | `svc_rancher_admin`, `CN=svc_rancher_admin,…` | See above |
| `ad_search_base` | `DC=lab,DC=local` | Users and groups |
| `admin_group_dn`, `viewer_group_dn` | `CN=sg-lab-admins,…`, `CN=sg-all-users,…` | The two groups |

**Secrets, typed in the shell as `TF_VAR_<name>`:**

| Variable | Vault key |
|---|---|
| `rancher_bootstrap_password` | `vault_rancher_bootstrap_password` |
| `rancher_admin_password` | `vault_rancher_admin_password` |
| `ad_service_account_password` | `vault_harbor_ldap_bind_password` |
| `ad_test_password` | `vault_rancher_ad_test_password` |

Defaults you can override: `rancher_hostname`, `ad_servers` (`[<dns_domain>]`), `ad_port`,
`ad_nested_groups`, `viewer_cluster_roles`.

## Providers

`rancher/rancher2` 15.x ([versions.tf](versions.tf)), the line for Rancher 2.15, from the local plugin
directory. It is configured twice ([providers.tf](providers.tf)):
- **bootstrap:** without a token, for `rancher2_bootstrap` only;
- **default:** with the token `rancher2_bootstrap` returns.

Both connect to `https://<rancher hostname>` and trust the internal CA.

## Outputs

`url`, `admin_group` and `viewer_group` (the AD principals), `cluster_viewer_role_id`.

## Security

The local state holds the admin password and API token, and the bind and test passwords. Keep
`terraform/state/` as protected as the Ansible vault.

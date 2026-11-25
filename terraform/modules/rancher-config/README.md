# Module `rancher-config`

Configures Rancher Server once the `rancher-server` unit has installed it:
- the local admin's password and the server URL;
- Active Directory login over LDAPS, limited to two AD groups;
- what those groups may do.
- monitoring: kube-prometheus-stack with Rancher's dashboards (see "Monitoring").
- the application cluster `command-pro`, defined as a custom cluster Rancher provisions (see "Application cluster").

It is called by `terraform/k8s/<ENV>/rancher-config`, which is applied by hand after
`terraform/k8s/<ENV>/rancher-server`.

Guide: [ansible/docs/rancher.md](../../../ansible/docs/rancher.md). Every input is described in
[variables.tf](variables.tf).

## What it creates

| Resource | What it is |
|---|---|
| `rancher2_bootstrap.admin` | Logs in with the bootstrap password, sets the local `admin` password to `rancher_admin_password`, sets the server URL, and returns an admin API token the other resources use |
| `rancher2_auth_config_activedirectory.ad` | AD login: LDAPS to `ad_servers` on 636, trusting the internal CA, bound as `ad_service_account_username`. Access mode `restricted`: only the two groups below, and the test account by name, may log in. |
| `rancher2_global_role_binding.admins` | Admin group → global role `admin` |
| `rancher2_global_role_binding.viewers_login` | Viewer group → global role `user-base` (may log in) |
| `rancher2_global_role.cluster_viewer` | Global role "Cluster Viewer". Its inherited cluster roles (`viewer_cluster_roles`) apply in every downstream cluster, present and future. |
| `rancher2_global_role_binding.viewers_clusters` | Viewer group → Cluster Viewer |
| `rancher2_cluster_role_template_binding.viewers_local` | Viewer group → each of `viewer_cluster_roles` in the `local` (Rancher) cluster, which inherited cluster roles don't reach |
| `helm_release.kube_prometheus_stack` | kube-prometheus-stack from the chart on the mirror, as release `kube-prometheus-stack` in `cattle-monitoring-system` (only while `monitoring_enabled`) |
| `rancher2_app_v2.monitoring_dashboards` | `rancher-monitoring-dashboards` from Rancher's built-in catalog, after the release above |
| `kubernetes_annotations.monitoring_namespace_project` | Puts `cattle-monitoring-system` in Rancher's System project (annotation `field.cattle.io/projectId`); Helm created it outside any project |
| `rancher2_project_role_template_binding.viewers_monitoring` | Viewer group → "View Monitoring" (`monitoring-ui-view`) in the System project: open Grafana, Prometheus and Alertmanager through Rancher, read-only |
| `rancher2_secret_v2.app_registry_auth` | `fleet-default/<app_cluster_name>-registry-auth`: the Harbor robot login the application cluster's nodes pull images with |
| `rancher2_cluster_v2.app` | The application cluster (`app_cluster_name`, default `command-pro`), a custom RKE2 cluster with no nodes yet (only while `app_cluster_enabled`) |

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

Secrets are typed in the shell as `TF_VAR_<name>`; see "Passwords" below.

Defaults you can override: `rancher_hostname`, `ad_servers` (`[<dns_domain>]`), `ad_port`,
`ad_nested_groups` (off; lab turns it on, because its users are in the groups through other
groups), `viewer_cluster_roles`.

## Monitoring

Rancher 2.15 deprecates its bundled `rancher-monitoring` chart. New installations run the upstream
`kube-prometheus-stack` and add Rancher's `rancher-monitoring-dashboards` chart, which supplies the
dashboards and the services Rancher's UI uses to reach Grafana, Prometheus and Alertmanager. The
module follows that chart's README:

- **Names:** release `kube-prometheus-stack` in `cattle-monitoring-system`. The dashboards chart
  points at `kube-prometheus-stack-grafana`, `-prometheus`, `-alertmanager` and the
  `kube-prometheus-stack-prometheus` service account, so these names must not change.
- **Grafana:** embedding allowed and anonymous Viewer access, so Rancher's UI can show the
  dashboards. Grafana is a ClusterIP service, reached only through Rancher's proxy. Its admin
  password comes from the vault; the chart's default is public.
- **Prometheus:** picks up every ServiceMonitor and PodMonitor in the cluster.
- **Off:** the etcd, controller-manager, scheduler and kube-proxy scrapers (they need PushProx),
  and Grafana's helm-test pod.
- **Dashboards chart:** `k3sServer.enabled: false` (this is RKE2).
- **Viewer access:** the viewer group gets "View Monitoring" in the System project, which now holds
  `cattle-monitoring-system`. Its ClusterRole allows only `get`/`create` on `services/proxy` for the
  three `rancher-monitoring-*` services: enough to open the dashboards through Rancher. Grafana
  then shows them as an anonymous Viewer.
- **No persistence:** metrics last as long as the pods. Prometheus doesn't support NFS for its
  data, and Rancher treats it as short-term storage (decided by the user).

**Images** come from Harbor, kept under their source registry and path:
`<registry>/<monitoring_image_project>/<source registry>/<path>`, for example
`registry.lab.local/library/quay.io/prometheus/prometheus`. The tags stay the chart's own. For chart
93.9.0 these are:

| Image | Tag |
|---|---|
| `quay.io/prometheus/prometheus` | `v3.16.0-distroless` |
| `quay.io/prometheus/alertmanager` | `v0.35.0` |
| `quay.io/prometheus-operator/prometheus-operator` | `v0.95.2` |
| `quay.io/prometheus-operator/prometheus-config-reloader` | `v0.95.2` |
| `ghcr.io/jkroepke/kube-webhook-certgen` | `1.11.1` |
| `docker.io/grafana/grafana` | `13.3.1-distroless` |
| `quay.io/kiwigrid/k8s-sidecar` | `2.14.3` |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics` | `v2.20.0` |
| `quay.io/prometheus/node-exporter` | `v1.13.1-distroless` |

The dashboards chart's own images (`rancher/mirrored-library-nginx`, `rancher/kuberlr-kubectl`) come
from Harbor's `rancher` project through Rancher's `systemDefaultRegistry`.

To upgrade kube-prometheus-stack: put the new chart on the mirror, push its images under the same
paths, change `kube_prometheus_stack_chart_path`, and apply.

## Application cluster

`command-pro` is defined in Rancher as a custom cluster: Rancher installs and manages RKE2 on each
node once the node runs the cluster's registration command. Defining it joins no node, so Rancher
shows it as waiting for nodes. Registering the app nodes, after reinstalling them without the
standalone RKE2, is a later phase (`ansible/docs/app-cluster.md`, section 6).

Its settings follow the standalone cluster built by `roles/rke2_server`:

| Setting | Value |
|---|---|
| RKE2 version | `app_cluster_kubernetes_version`, default `v1.36.5+rke2r1` (in Rancher 2.15.3's release list, and its default) |
| Network plugin, SELinux | Canal; `selinux: true` |
| Pod and service networks | `10.42.0.0/16`, `10.43.0.0/16` |
| TLS names | `app_cluster_hostname` (default `command-pro.<dns_domain>`) and `app_cluster_tls_sans` (lab: lb-app's virtual IP) |
| Authorized Cluster Endpoint | `<app_cluster_hostname>:6443`, through lb-app: a direct kubeconfig context that works while Rancher is down |
| etcd snapshots | Every 6 hours, 28 kept |
| Registry | `docker.io` mirrored to Harbor; nodes log in as `robot$k8s-pull`; images through Rancher's `systemDefaultRegistry` |

The viewer group sees it read-only through the global role Cluster Viewer, with no extra binding.
`terragrunt output -raw app_cluster_registration_command` prints the command a node runs to join as
etcd, control plane and worker; it holds the registration token.

## Passwords

Six passwords, each typed from the vault at a prompt (the unit's header has the loop). Only the
first is also used by the `rancher-server` unit.

| Prompt (`TF_VAR_…`) | Vault key | Account | Used by | What happens with it |
|---|---|---|---|---|
| `rancher_bootstrap_password` | `vault_rancher_bootstrap_password` | Rancher's local `admin` | `rancher-server`; `rancher-config` (first apply only) | `rancher-server` installs Rancher with it as `admin`'s first password. The first `rancher-config` apply logs in with it once to replace it, after which it no longer works. |
| `rancher_admin_password` | `vault_rancher_admin_password` | Rancher's local `admin` | `rancher-config` | Set as `admin`'s lasting password. Every later apply logs in with it. It is the break-glass login when AD is unavailable. |
| `ad_service_account_password` | `vault_harbor_ldap_bind_password` | AD `svc_ldap_bind`, the bind account shared with Harbor | `rancher-config` | Saved in Rancher's AD settings. Rancher uses it at every login to look up the user and their groups. |
| `ad_test_password` | `vault_rancher_ad_test_password` | AD `svc_rancher_admin`, the test account | `rancher-config` | Used when AD login is turned on: Rancher logs in as this account to check the settings, then links it to `admin`. After that it is an ordinary AD login, with admin rights. |
| `grafana_admin_password` | `vault_rancher_grafana_admin_password` | Grafana's `admin` | `rancher-config` (monitoring) | Set as Grafana's admin password on every apply. Rancher's users see the dashboards anonymously, as Viewers; the admin login is for changing Grafana itself. |
| `harbor_k8s_pull_secret` | `vault_harbor_robot_secrets['k8s-pull']` | Harbor robot `robot$k8s-pull` | `rancher-config` (application cluster) | Saved as the registry secret Rancher writes into each application node's `registries.yaml`. The RKE2 nodes of both clusters already use the same robot. |

**In order, on the first apply:**

1. `rancher-server`: Rancher starts, and `admin` has the bootstrap password.
2. `rancher-config` logs in as `admin` with the bootstrap password, sets the lasting password and
   receives an API token.
3. With that token, it saves the AD settings with the bind password.
4. Rancher logs in as the test account to check them, turns AD login on, and links the test
   account to `admin`.
5. The group permissions are created.

**Later applies** log in as `admin` with the lasting password; the bootstrap password isn't used
again. The unit still asks for all four, so type the same values from the vault.

**When a password changes:**

| Changed | Where | Then |
|---|---|---|
| `svc_ldap_bind` | AD | AD logins to Rancher and Harbor fail until the vault is updated, `playbooks/harbor.yml` is run and `rancher-config` is applied. |
| `svc_rancher_admin` | AD | Rancher keeps working; the next `rancher-config` apply fails until the vault is updated. |
| `admin`'s lasting password | The vault, then apply `rancher-config` | Not in the Rancher UI: the next apply logs in with the vault's value and would fail. |

The `rancher-config` state holds all six; the `rancher-server` state also holds the bootstrap
password.

## Providers

`rancher/rancher2` 15.x ([versions.tf](versions.tf)), the line for Rancher 2.15, from the local plugin
directory. It is configured twice ([providers.tf](providers.tf)):
- **bootstrap:** without a token, for `rancher2_bootstrap` only;
- **default:** with the token `rancher2_bootstrap` returns.

Both connect to `https://<rancher hostname>` and trust the internal CA.

`hashicorp/helm` v3 (kube-prometheus-stack) and `hashicorp/kubernetes` (the monitoring namespace's
project) connect through the kubeconfig Ansible wrote on the
control node (`kubeconfig_path`, default `~/.kube/<env_name>-rancher-cluster.yaml`).

## Outputs

`url`, `admin_group` and `viewer_group` (the AD principals), `test_user`, `cluster_viewer_role_id`,
`kube_prometheus_stack_version`, `app_cluster_id`, and `app_cluster_registration_command` (sensitive).

## Security

The local state holds the admin password and API token, the bind and test passwords, Grafana's admin
password, the Harbor robot secret and the application cluster's registration token. Keep
`terraform/state/` as protected as the Ansible vault.

# rke2_server

Installs RKE2 server nodes (control plane, etcd and workloads on every node) from pre-downloaded
artifacts on the internal mirror, with every image pulled from Harbor. It creates the cluster on
the first node and joins the others through the load balancer. One cluster per inventory group:
the Rancher cluster (`rke2_rancher`) and the application cluster (`rke2_app`).

| | |
|---|---|
| Playbooks | `playbooks/rke2_rancher.yml`, `playbooks/rke2_app.yml` (one node at a time, in name order) |
| Hosts | `rke2_rancher` (Rancher cluster), `rke2_app` (application cluster) |
| Tags | `rke2_server`, and `rke2_rancher` or `rke2_app` |
| Needs first | The common layers (certificates, repositories, data disks, CIS), Harbor with the images, `playbooks/load_balancer.yml` |
| Set variables in | `inventories/<ENV>/group_vars/rke2_rancher.yml`, `rke2_app.yml`; secrets in the vault |
| Longer guides | [docs/rancher.md](../../docs/rancher.md): downloads, images, run order, checks, upgrades; [docs/app-cluster.md](../../docs/app-cluster.md): the application cluster, its two modes and `/scratch` |

## Two modes

| `rke2_rancher_managed` | What the role does |
|---|---|
| `false` (default): standalone | Everything below: installs RKE2, creates or joins the cluster, writes the kubeconfig. |
| `true`: managed by Rancher Server | Pre-checks (both modes), host preparation and the container paths, then the join: a node not yet joined runs Rancher's system agent installer with the cluster's registration token, read from Rancher at run time (`tasks/join.yml`). Rancher installs RKE2. The first node's admin kubeconfig is then copied to the control node. |

The Rancher cluster is always standalone. The application cluster follows
`app_cluster_rancher_managed` in `group_vars/all/main.yml`.

## What it does

1. **Pre-checks** (nothing is changed until they pass):
   - the settings are complete and the cluster has an allowed number of nodes (1 or 3);
   - `/var/lib/rancher` and `/var/lib/kubelet` are their own mounted filesystems;
   - the registration name resolves to the load balancer's virtual IP;
   - Harbor answers;
   - no other RKE2 version is installed.
2. **Host**: stops and masks firewalld, sets `net.ipv4.ip_forward=1`, keeps NetworkManager away
   from the Canal interfaces, installs `container-selinux` and the RKE2 SELinux policy, and puts
   RKE2's `kubectl` and `crictl` on the PATH (root also gets the node's kubeconfig).
3. **Install**: downloads `install.sh`, the tarball and its checksum file from
   `<env_repo_base_url>/rancher/rke2/<rke2_version>/` and checks each one. Writes
   `/etc/rancher/rke2/config.yaml` and `registries.yaml`, then runs `install.sh` from the
   downloaded files. Nothing is fetched from the internet.
4. **Start**: starts `rke2-server` and waits until the node is `Ready`. The play runs one node at
   a time, so a later node only starts once the one before is Ready.
5. **Kubeconfig**: on the first node, copies the admin kubeconfig to the control node
   (`~/.kube/<ENV>-<rke2_cluster_name>.yaml`, 0600), with its server set to
   `https://<rke2_registration_host>:6443`.

**Which node creates the cluster.** The first host of the group, sorted by name, creates it,
but only if no cluster answers on `https://<rke2_registration_host>:9345/ping` yet. Every other
node joins through that address. A rebuilt first node therefore joins the running cluster
instead of starting a second one.

**Configuration changes** on a running node (token aside) restart `rke2-server` on that node,
one node at a time.

## Variables

Required (per cluster, in `group_vars/<cluster group>.yml` or the vault):

| Variable | Description |
|---|---|
| `rke2_cluster_group` | Inventory group that forms the cluster. |
| `rke2_version` | RKE2 version, e.g. `v1.36.5+rke2r1`. |
| `rke2_install_sh_checksum` | `sha256:<hash>` of `install.sh`, recorded when downloading. |
| `rke2_selinux_rpm`, `rke2_selinux_checksum` | File name of the RKE2 SELinux policy RPM on the mirror, and its `sha256:<hash>`. |
| `rke2_token` | Join secret shared by the nodes, at least 32 characters (Rancher cluster: `vault_rke2_rancher_token`). |
| `rke2_registration_host` | Name nodes join through on 9345, and that the kubeconfig uses on 6443 (Rancher cluster: `rancher_hostname`). |
| `vault_harbor_robot_secrets['k8s-pull']` | Secret of the Harbor robot the nodes pull images as. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `rke2_cluster_name` | `rke2_cluster_group` | Short name of the cluster; names the kubeconfig on the control node. |
| `rke2_allowed_server_counts` | `[1, 3]` | Node counts the cluster may have. |
| `rke2_mirror_url` | `<env_repo_base_url>/rancher/rke2` | Where the artifacts are on the mirror (maestro: `/repo/rancher/rke2`). |
| `rke2_version_url` | `<rke2_mirror_url>/<rke2_version>` | Directory of one version's artifacts. |
| `rke2_selinux_url` | `<rke2_version_url>/<rke2_selinux_rpm>` | Where the SELinux policy RPM is. |
| `rke2_artifacts_dir` | `/var/lib/rancher/rke2-artifacts` | Where the artifacts are kept on the node. |
| `rke2_registration_vip` | `""` | Virtual IP behind `rke2_registration_host`; the pre-check makes sure the name resolves to it. |
| `rke2_tls_san` | `[]` | Extra names and addresses the Kubernetes API certificate covers. |
| `rke2_cluster_cidr` | `10.42.0.0/16` | Pod network. |
| `rke2_service_cidr` | `10.43.0.0/16` | Service network. |
| `rke2_etcd_snapshot_schedule` | `"0 */6 * * *"` | etcd snapshot schedule (cron). |
| `rke2_etcd_snapshot_retention` | `28` | Snapshots kept (7 days at every 6 hours). |
| `rke2_config_extra` | `{}` | More RKE2 server options for `config.yaml`. |
| `rke2_registry` | `registry.<env_domain>` | Private registry for every image (`system-default-registry`, and the `docker.io` mirror). |
| `rke2_registry_username` | `robot$k8s-pull` | Login to the registry. |
| `rke2_registry_password` | `vault_harbor_robot_secrets['k8s-pull']` | Its password. |
| `rke2_registry_ca_file` | `/etc/pki/tls/certs/ca-bundle.crt` | CA bundle the registry's certificate is checked against (holds the internal CA). |
| `rke2_required_mounts` | `[/var/lib/rancher, /var/lib/kubelet]` | Paths that must be their own filesystems before installing (the application cluster adds `/scratch`). |
| `rke2_container_paths` | `[]` | Local paths workloads mount as `hostPath` volumes (the application cluster: `[/scratch]`). Labelled `container_file_t`, so pods can use them with SELinux enforcing. |
| `rke2_container_paths_mode` | `"0755"` | Mode of those paths (owned by root). |
| `rke2_rancher_managed` | `false` | Managed by Rancher Server: prepare the host and join it through Rancher (see "Two modes"). |
| `rke2_rancher_cluster` | `""` | Managed mode: the cluster's name in Rancher (`fleet-default/<name>`), e.g. `command-pro`. |
| `rke2_rancher_kubeconfig` | `~/.kube/<env_name>-rancher-cluster.yaml` | Managed mode: the Rancher cluster's admin kubeconfig on the control node, used to read the registration token. |
| `rke2_rancher_node_roles` | `[etcd, controlplane, worker]` | Managed mode: the roles each node joins with. |
| `rke2_rancher_join_timeout` | `1200` | Managed mode: seconds to wait for a joined node to be Ready. |
| `rke2_disable_firewalld` | `true` | Stop and mask firewalld. |
| `rke2_packages` | `[container-selinux, tar]` | Packages installed first. |
| `rke2_start_timeout` | `1800` | Seconds `rke2-server` may take to start. |
| `rke2_ready_timeout` | `600` | Seconds to wait for the node to be `Ready`. |
| `rke2_kubeconfig_dest` | `~/.kube/<env_name>-<rke2_cluster_name>.yaml` | Admin kubeconfig on the control node. |

## Files on the node

| File | Content |
|---|---|
| `/etc/rancher/rke2/config.yaml` (0600) | Token, node name, TLS names, registry, CIDRs, etcd snapshots; `server:` on joining nodes |
| `/etc/rancher/rke2/registries.yaml` (0600) | `docker.io` and the registry mapped to Harbor, robot login, CA bundle |
| `/etc/sysctl.d/90-rke2.conf` | `net.ipv4.ip_forward = 1` |
| `/etc/NetworkManager/conf.d/rke2-canal.conf` | `cali*` and `flannel*` unmanaged |
| `/etc/profile.d/rke2.sh` | RKE2's `kubectl`, `crictl` and `ctr` on the PATH |
| SELinux file context for each container path | `<path>(/.*)?` labelled `container_file_t` (`semanage fcontext -l` shows it) |

## CIS exceptions

`playbooks/group_vars/rke2_servers.yml` turns off, for every RKE2 node:

- the CIS firewall rules (4.1.x, 4.2.x, 4.3.x): firewalld is off;
- IP forwarding (3.3.1).

The compensating control for the firewall is network segmentation; the flows the perimeter must
allow are in [docs/rancher.md](../../docs/rancher.md), "Firewall exception and segmentation".

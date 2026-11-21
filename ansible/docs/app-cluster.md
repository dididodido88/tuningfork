# Application cluster

The application cluster runs the application workloads on RKE2, on 1 or 3 nodes behind the load
balancer `lb-app`, at `command.<domain>`. It comes in two modes, chosen with one setting per
environment. The Rancher cluster ([rancher.md](rancher.md)) is built the same way and its guide
covers the shared parts: downloads, images in Harbor, the firewall exception and upgrades.

| Part | Built by | Where |
|---|---|---|
| VMs (8 vCPU / 32 GB; disks `/var/lib/rancher`, `/var/lib/kubelet`, `/scratch`) | Terraform | `terraform/live/<ENV>/app-cluster`, `lb-app` |
| Load balancer `lb-app` | Ansible | `playbooks/load_balancer.yml`, `roles/load_balancer` |
| RKE2 on the nodes | Ansible (standalone) or Rancher (managed) | `playbooks/rke2_app.yml`, `roles/rke2_server` |

## 1. The two modes

Set in `inventories/<ENV>/group_vars/all/main.yml`:

```yaml
app_cluster_hostname: "command.{{ env_domain }}"
app_cluster_rancher_managed: false
```

| | Standalone (`false`) | Managed by Rancher (`true`) |
|---|---|---|
| Who installs RKE2 | Ansible, from the mirror | Rancher, when the node runs Rancher's registration command |
| How nodes join | Through `lb-app` on 9345 (`https://command.<domain>:9345`) | Rancher drives the joins |
| kubectl | Admin kubeconfig `~/.kube/<ENV>-app-cluster.yaml`, through `lb-app` on 6443 | Kubeconfig from Rancher: through the Rancher proxy, plus a direct context to `command.<domain>:6443` (Authorized Cluster Endpoint) that works while Rancher is down |
| Ports on `lb-app` | 80, 443, 6443, 9345 | 80, 443, 6443 |
| Status | Built (this phase) | Hosts prepared only. The join through Rancher is the next phase |

### Why the load balancer carries these ports

- **80/443 (applications)**: in both modes. The ingress runs on every node, and the load balancer
  gives one address in front of 1 or 3 nodes, with health checks.
- **6443 (Kubernetes API)**:
  - standalone: the only way in;
  - managed: kubectl normally goes through Rancher's proxy. With the Authorized Cluster Endpoint
    enabled, Rancher adds a direct context, and `lb-app` gives it one stable, health-checked
    address for all control-plane nodes.
- **9345 (RKE2 registration)**: standalone only, as the fixed address joining nodes use. Rancher
  handles joins itself in managed mode, so the port isn't on the load balancer.

## 2. Prerequisites

| What | Where |
|---|---|
| DNS A record `command.<domain>` → the `lb-app` virtual IP (`keepalived_vip` in `terraform/live/<ENV>/lb-app`) | AD DNS. The plays stop if it is missing. |
| RKE2 artifacts on the mirror and images in Harbor's `rancher` project | As for the Rancher cluster: [rancher.md](rancher.md), section 2. Usually the same RKE2 version. |
| Version and checksums | `inventories/<ENV>/group_vars/rke2_app.yml` (`REPLACE`) |
| Vault: `vault_rke2_app_token` (standalone) | A long random string: `openssl rand -hex 32` |
| Vault: `vault_haproxy_stats_password` | Already set for `lb-rancher`; `lb-app` uses the same one |

## 3. Run (standalone)

```sh
# 1. VMs (from terraform/)
cd terraform/live/lab/lb-app      && terragrunt apply
cd ../app-cluster                 && terragrunt apply

# 2. Ansible (from ansible/): common layers, the load balancer, RKE2
ansible-playbook -i inventories/lab playbooks/site.yml --limit 'lb_app:rke2_app'
#    or, once the common layers are on: playbooks/load_balancer.yml, then playbooks/rke2_app.yml
```

The RKE2 play works as for the Rancher cluster: one node at a time, and the first node creates
the cluster. In addition it checks that `/scratch` is its own filesystem and labels it for
containers. The admin kubeconfig lands at `~/.kube/<ENV>-app-cluster.yaml` and points at
`https://command.<domain>:6443`.

## 4. Check

```sh
# On lb-app
sudo haproxy-status

# From the control node
kubectl --kubeconfig ~/.kube/lab-app-cluster.yaml get nodes

# On a node
findmnt /scratch          # its own filesystem (ext4 by default)
ls -Zd /scratch           # ... container_file_t ...
```

| Endpoint (on the virtual IP) | Health check | Note |
|---|---|---|
| 80, 443 | The port accepts connections (TCP) | No application host name to ask for yet. Once one exists, switch to an HTTP check (`roles/load_balancer/README.md`). |
| 6443 | TLS, `GET /readyz`, 200 or 401 | As for the Rancher cluster |
| 9345 | TLS, `GET /ping`, 200 | Standalone only |

## 5. The /scratch disk

Each app node has a local disk mounted at `/scratch`, for workloads that need local scratch space.

- **Size and filesystem**: `scratch_size_gb` (20 GB to start) and `scratch_fstype` (`ext4`, or
  `xfs`) in `terraform/live/<ENV>/app-cluster/terragrunt.hcl`.
  - To grow it, raise the size and apply, then grow the filesystem on each node:
    `growpart <disk> 1`, then `resize2fs` (ext4) or `xfs_growfs /scratch` (xfs).
  - The filesystem only applies when the disk is first formatted. Changing it later needs a new
    disk.
- **Using it**: workloads mount it as a `hostPath` volume (`path: /scratch/...`). The role labels
  it `container_file_t`, so pods can read and write it with SELinux enforcing. It is owned by
  root with mode `0755` (`rke2_container_paths_mode`), so pods that don't run as root need a
  subdirectory they own, or a wider mode.
- **What it is not**: it isn't managed by Kubernetes. Data stays on the node when a pod moves
  elsewhere, isn't shared between nodes, and isn't backed up.

## 6. Next phase: managed by Rancher

Not built yet. Today, with `app_cluster_rancher_managed: true`, the play only prepares the hosts
(firewall, IP forwarding, SELinux policy, disks), and `lb-app` already drops 9345. Planned:

1. A Terraform unit `terraform/k8s/<ENV>/app-cluster` with the `rancher2` provider defines the
   cluster in Rancher. It sets:
   - the RKE2 version and Harbor as the registry;
   - `command.<domain>` and the `lb-app` virtual IP as TLS names;
   - the Authorized Cluster Endpoint with FQDN `command.<domain>` and the cluster's CA certificate.
2. Ansible runs Rancher's registration command on each node, with the token from the vault.

It is built once the Rancher cluster runs, from the provider version and the registration command
of your Rancher, rather than from guesses.

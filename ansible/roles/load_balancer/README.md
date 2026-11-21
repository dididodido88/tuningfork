# load_balancer

Puts a virtual IP and a load balancer in front of an RKE2 cluster. keepalived holds the virtual
IP; HAProxy spreads connections round robin over the cluster's nodes and checks each one's
health. The endpoints are the hosts of the cluster's inventory group, so 1 node gives 1 endpoint
and 3 give 3. Includes `haproxy-status`, a command that shows health and traffic distribution.

| | |
|---|---|
| Playbook | `playbooks/load_balancer.yml` (before `rke2_rancher.yml` in `site.yml`) |
| Hosts | `load_balancers`: `lb-rancher` and `lb-app`. A host whose group has no `load_balancer_backend_group` is skipped. |
| Tags | `load_balancer`, `firewall` |
| Set variables in | `inventories/<ENV>/group_vars/lb_rancher.yml`, `lb_app.yml`; the virtual IP in the Terraform `lb-*` units; the stats password in the vault |
| Longer guide | [docs/rancher.md](../../docs/rancher.md) |

## What it does

1. **Pre-checks**: the settings are complete, the backend group has hosts, and the cluster
   name (`load_balancer_health_host`) resolves to the virtual IP.
2. **System**:
   - installs `haproxy`, `keepalived` and `socat`;
   - lets HAProxy bind the virtual IP before it holds it (`net.ipv4.ip_nonlocal_bind`);
   - lets HAProxy use any port under SELinux (`haproxy_connect_any`).
3. **HAProxy** (`/etc/haproxy/haproxy.cfg`, checked with `haproxy -c` before it is installed):
   one frontend per port on the virtual IP, TCP passthrough, `balance roundrobin`.
4. **keepalived** (`/etc/keepalived/keepalived.conf`, checked before it is installed): one VRRP
   instance holds the virtual IP while HAProxy runs. The first host of the group is MASTER;
   other hosts in the group become unicast peers, ready for a second load balancer.
5. **Firewall** (firewalld stays on here):
   - 80, 443 and 6443 open;
   - 9345 only from the cluster nodes;
   - the statistics page only from the admin networks;
   - VRRP when there are peers.
6. **Checks**: both services run, the MASTER holds the virtual IP, and the current health of the
   endpoints is shown.

| Frontend on the virtual IP | Purpose | Health check of each node |
|---|---|---|
| 80, 443 | Rancher web UI | HTTPS `GET /healthz` on 443 with Host and SNI = the Rancher hostname; 200 |
| 6443 | Kubernetes API (kubectl, Terraform) | TLS, `GET /readyz`; 200 or 401 (RKE2 refuses anonymous requests, so 401 shows the API server answers) |
| 9345 | RKE2 registration (nodes joining) | TLS, `GET /ping`; 200 |

A node is marked down after 3 failed checks 5 s apart, and up again after 2 good ones. Idle
connections (kubectl watches, Rancher websockets) stay open for 1 hour.

## Status: `haproxy-status`

```sh
sudo haproxy-status            # once
sudo haproxy-status -w 5       # refresh every 5 seconds
```

```
BACKEND rancher_https: UP, 2 of 3 servers up, 1520 sessions
  SERVER         STATUS    LAST CHECK         CURRENT  SESSIONS   SHARE        IN       OUT  CHANGED
  rancher01      UP        L7OK/200 3ms             1       507   33.4%   409.6KB    13.3MB       1h
  rancher02      UP        L7OK/200 4ms             1       506   33.3%   409.6KB    13.3MB       1h
  rancher03      DOWN      L4CON 1001ms             1       507   33.4%   409.6KB    13.3MB       1m
```

- **SHARE** is each server's part of its backend's sessions since HAProxy started: with round
  robin and all servers up, about equal.
- **LAST CHECK** shows the check result: `L7OK/200` means the HTTP check passed, `L4CON` means the
  connection was refused or timed out.
- **CHANGED** is how long ago the server's state last changed.

It reads HAProxy's local stats socket, `/var/lib/haproxy/stats`, so it needs `sudo`.

The same figures are on the statistics web page, `http://<lb host>:8404/`, from an admin network,
with user `admin` and `vault_haproxy_stats_password`.

## Variables

Required (per load balancer group, or from Terraform and the vault):

| Variable | Description |
|---|---|
| `load_balancer_group` | This load balancer's inventory group, e.g. `lb_rancher`. |
| `load_balancer_backend_group` | Inventory group whose hosts are the endpoints, e.g. `rke2_rancher`. |
| `load_balancer_vrrp_router_id` | VRRP router ID 1-255, unique among load balancer groups on the network (`lb_rancher`: 51). |
| `load_balancer_health_host` | Host name for the Rancher health check (`rancher_hostname`). |
| `keepalived_vip` | The virtual IP, from the Terraform `lb-*` unit (read as `load_balancer_vip`). |
| `vault_haproxy_stats_password` | Statistics page password, at least 12 characters. |

Optional:

| Variable | Default | Description |
|---|---|---|
| `load_balancer_vip` | `keepalived_vip` | Virtual IP. |
| `load_balancer_vip_prefix` | the host's network prefix | Prefix length of the virtual IP. |
| `load_balancer_interface` | the host's default interface | Interface the virtual IP is added to. |
| `load_balancer_frontends` | 80, 443, 6443, 9345 (table above) | Frontends: `name`, `port`, `check` (`rancher`, `kube_api`, `rke2_supervisor`, `tcp`), optional `allow_from: backends`. |
| `load_balancer_check_interval` | `5s` | Time between health checks. |
| `load_balancer_check_fall` | `3` | Failed checks before a server is marked down. |
| `load_balancer_check_rise` | `2` | Good checks before it is marked up again. |
| `load_balancer_timeout_connect` | `5s` | Time to connect to a node. |
| `load_balancer_timeout_client`, `load_balancer_timeout_server` | `1m` | Idle time allowed while a connection is being set up. |
| `load_balancer_timeout_tunnel` | `1h` | Idle time allowed on an established connection. |
| `load_balancer_stats_port` | `8404` | Statistics page port, on the host's own address. |
| `load_balancer_stats_user` | `admin` | Statistics page user. |
| `load_balancer_stats_password` | `vault_haproxy_stats_password` | Statistics page password. Set the vault variable instead. |
| `load_balancer_stats_socket` | `/var/lib/haproxy/stats` | Socket `haproxy-status` reads. |
| `load_balancer_manage_firewall` | `true` | Open the ports in firewalld. |
| `load_balancer_firewall_zone` | `rhel9cis_default_zone` (else `public`) | firewalld zone. |
| `load_balancer_admin_networks` | `siem_admin_networks` | Networks allowed to open the statistics page. |
| `load_balancer_packages` | `[haproxy, keepalived, socat]` | Packages installed. |

## The application cluster: lb-app

`inventories/<ENV>/group_vars/lb_app.yml` configures `lb-app` in front of `rke2_app`, with VRRP
router ID 52. Its frontends follow `app_cluster_rancher_managed` (docs/app-cluster.md):

- standalone: 80, 443, 6443, 9345;
- managed by Rancher: 80, 443, 6443 (Authorized Cluster Endpoint).

80/443 use a TCP check, because no application host name exists yet. Once one does, switch them
to an HTTP check: the `rancher` check type asks `GET /healthz` with `load_balancer_health_host`.
For an application with another health path, add a check type to the template.

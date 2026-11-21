# Rancher Server cluster

Rancher Server runs on its own RKE2 Kubernetes cluster of 1 or 3 nodes, behind one load balancer.
Everything is air-gapped: RKE2 is installed from files on the internal mirror, and every container
image comes from Harbor.

```
              rancher.<domain>  (DNS A record)
                      |
              virtual IP (keepalived)
      lb-rancher: HAProxy, round robin, health checks
        80/443 Rancher UI    6443 Kubernetes API    9345 RKE2 registration
          |             |             |
     rancher01     rancher02     rancher03        RKE2 servers (etcd, API server, Rancher)
          \_____________|_____________/
                images from Harbor: registry.<domain>/rancher/...
```

| Part | Built by | Where |
|---|---|---|
| VMs (nodes 4 vCPU / 8 GB, data disks `/var/lib/rancher`, `/var/lib/kubelet`) | Terraform | `terraform/live/<ENV>/rancher-cluster`, `lb-rancher` |
| Load balancer: keepalived and HAProxy | Ansible | `playbooks/load_balancer.yml`, `roles/load_balancer` |
| RKE2 cluster | Ansible | `playbooks/rke2_rancher.yml`, `roles/rke2_server` |
| Rancher Server | Terraform (Helm), by hand | `terraform/k8s/<ENV>/rancher-server` |

## 1. Prerequisites

| What | Where |
|---|---|
| DNS A record `rancher.<domain>` → the virtual IP (`keepalived_vip` in `terraform/live/<ENV>/lb-rancher`) | AD DNS. The plays stop if it is missing. |
| Certificate for `rancher.<domain>` from the internal CA | On the control node: `/srv/security/certificates/files/<certificates_env_dir>/rancher/rancher.fullchain.crt` and `rancher.key` |
| Harbor running, with the project `rancher` | `harbor_projects` in `group_vars/registry_servers.yml` (already listed); run `playbooks/harbor.yml` |
| Vault: `vault_rke2_rancher_token` | A long random string, the cluster's join secret: `openssl rand -hex 32` |
| Vault: `vault_haproxy_stats_password` | Password for the HAProxy statistics page (at least 12 characters) |
| Vault: `vault_harbor_robot_secrets['k8s-pull']` | Already there: the nodes pull images as `robot$k8s-pull` |
| Terraform providers `hashicorp/helm` and `hashicorp/kubernetes` | In the control node's plugin directory (`terraform/README.md`) |

## 2. Files to download

Pick an RKE2 and Rancher version pair that Rancher supports (the Rancher support matrix). Then, on
the internet-connected download machine:

| File | Source | Mirror path (below `env_repo_base_url`) |
|---|---|---|
| `install.sh` | `https://get.rke2.io` (save as `install.sh`) | `rke2/<rke2_version>/install.sh` |
| `rke2.linux-amd64.tar.gz` | `https://github.com/rancher/rke2/releases/download/<rke2_version>/` | `rke2/<rke2_version>/` |
| `sha256sum-amd64.txt` | same release | `rke2/<rke2_version>/` |
| `rke2-images-all.linux-amd64.txt` | same release (the image list, not uploaded to the mirror) | - |
| `rke2-selinux-<v>.el9.noarch.rpm` | `https://github.com/rancher/rke2-selinux/releases` | `rke2/rke2-selinux/` |
| `rancher-<version>.tgz` (the chart) | `https://releases.rancher.com/server-charts/stable/` | `rancher/<version>/`; also copy it to the control node for Terraform |
| `rancher-images.txt` | `https://github.com/rancher/rancher/releases/download/<version>/` (the image list) | - |

```sh
V=v1.33.5+rke2r1                                  # example: the version you chose
B=https://github.com/rancher/rke2/releases/download/${V/+/%2B}
curl -fLO $B/rke2.linux-amd64.tar.gz
curl -fLO $B/sha256sum-amd64.txt
curl -fLO $B/rke2-images-all.linux-amd64.txt
sha256sum -c --ignore-missing sha256sum-amd64.txt # must say OK for the tarball
curl -fL https://get.rke2.io -o install.sh
sha256sum install.sh rke2-selinux-*.rpm           # values for rke2_install_sh_checksum and rke2_selinux_checksum
```

Record in `inventories/<ENV>/group_vars/rke2_rancher.yml`:

```yaml
rke2_version: v1.33.5+rke2r1
rke2_install_sh_checksum: "sha256:<hash of install.sh>"
rke2_selinux_rpm: rke2-selinux-0.20-1.el9.noarch.rpm
rke2_selinux_checksum: "sha256:<hash of the rpm>"
```

The tarball isn't pinned in the inventory: it is checked against `sha256sum-amd64.txt`, from the
same release, which you checked above.

### Images into Harbor

Every image keeps its path and goes into the Harbor project `rancher`:
`docker.io/rancher/hardened-kubernetes:<tag>` becomes `registry.<domain>/rancher/hardened-kubernetes:<tag>`.
RKE2 pulls its system images from there (`system-default-registry`), and Rancher pulls its own
(`systemDefaultRegistry`).

On the download machine, save each image (all architectures) to an archive:

```sh
mkdir -p images
cat rke2-images-all.linux-amd64.txt rancher-images.txt | sed 's#^docker.io/##' | sort -u > images.txt
while read -r img; do
  skopeo copy --all "docker://docker.io/$img" "oci-archive:images/$(echo "$img" | tr '/:' '__').tar:$img"
done < images.txt
```

Carry `images/` and `images.txt` inside, then push with a Harbor login that may push to
`rancher` (the admin, or a project maintainer):

```sh
skopeo login registry.lab.local
while read -r img; do
  skopeo copy --all "oci-archive:images/$(echo "$img" | tr '/:' '__').tar:$img" "docker://registry.lab.local/$img"
done < images.txt
```

`rancher-images.txt` lists every image Rancher can deploy, including the ones for downstream
clusters. That is several hundred images; Harbor's 200 GB data disk holds them.

## 3. Run

```sh
# 1. VMs (from terraform/)
cd terraform/live/lab/lb-rancher      && terragrunt apply
cd ../rancher-cluster                 && terragrunt apply      # 3 nodes in lab

# 2. Everything Ansible does (from ansible/): common layers, load balancer, RKE2
ansible-playbook -i inventories/lab playbooks/site.yml --limit 'lb_rancher:rke2_rancher'
#    or, once the common layers are on: playbooks/load_balancer.yml, then playbooks/rke2_rancher.yml

# 3. Rancher Server (from terraform/)
export TF_VAR_rancher_bootstrap_password='<first admin password>'
cd terraform/k8s/lab/rancher-server && terragrunt init && terragrunt apply
```

What the RKE2 play does, one node at a time (first node by name first):

1. Checks the settings, that `/var/lib/rancher` and `/var/lib/kubelet` are their own
   filesystems, that `rancher.<domain>` resolves to the virtual IP, and that Harbor answers.
2. Turns firewalld off, allows IP forwarding, keeps NetworkManager away from the Canal interfaces,
   and installs the SELinux policy for RKE2.
3. Downloads and checks the artifacts, writes `/etc/rancher/rke2/config.yaml` and
   `registries.yaml`, and runs `install.sh` from the downloaded files.
4. Starts RKE2. The first node creates the cluster; the others join it through
   `https://rancher.<domain>:9345`. Each must be `Ready` before the next starts.
5. Copies the admin kubeconfig to the control node: `~/.kube/<ENV>-rancher-cluster.yaml`, which
   points at `https://rancher.<domain>:6443` and is what Terraform uses in step 3.

Terraform then creates the namespace `cattle-system`, the TLS secrets (the `rancher` certificate
and the internal CA) and installs the chart: one Rancher pod per node, images from Harbor, no
cert-manager.

## 4. Check

```sh
# On lb-rancher: endpoints, health and traffic share
sudo haproxy-status            # once
sudo haproxy-status -w 2       # refresh every 2 s
# The same in a browser, from an admin network: http://lb-rancher.<domain>:8404/

# From the control node
kubectl --kubeconfig ~/.kube/lab-rancher-cluster.yaml get nodes          # all Ready
kubectl --kubeconfig ~/.kube/lab-rancher-cluster.yaml -n cattle-system get pods
```

Then open `https://rancher.<domain>/` and log in as `admin` with the bootstrap password.

Before Rancher is deployed, the 80/443 backends show every server DOWN: their health check asks
Rancher itself (`/healthz`), which isn't there yet. 6443 and 9345 are UP as soon as RKE2 runs.

| Endpoint (on the virtual IP) | Health check | Down means |
|---|---|---|
| 80, 443: Rancher UI | `GET /healthz` over HTTPS with the Rancher hostname | Rancher isn't answering on that node |
| 6443: Kubernetes API | TLS, `GET /readyz`, 200 or 401 | The API server isn't answering over TLS |
| 9345: RKE2 registration | TLS, `GET /ping`, 200 | RKE2 isn't running on that node |

A server is marked down after 3 failed checks 5 s apart, and up again after 2 good ones.

## 5. Firewall exception and segmentation

RKE2 nodes run **without a host firewall**. firewalld conflicts with RKE2's network plugin
(Canal), and RKE2's documented setup turns it off, so the CIS firewall rules are switched off for
these hosts (`playbooks/group_vars/rke2_servers.yml`). The load balancer keeps firewalld.

The compensating control is **network segmentation**: the RKE2 nodes sit in their own VLAN or
subnet, and the perimeter firewall or router only lets these flows through:

| Direction | From | To | Ports |
|---|---|---|---|
| In | Load balancer | RKE2 nodes | 80, 443, 6443, 9345/tcp |
| In | Admin networks, control node | RKE2 nodes | 22/tcp |
| Between nodes | RKE2 nodes | RKE2 nodes | 2379-2381, 6443, 9345, 10250/tcp; 8472/udp (all within the segment) |
| Out | RKE2 nodes | Mirror | 443/tcp |
| Out | RKE2 nodes | Harbor | 443/tcp |
| Out | RKE2 nodes | DNS, NTP, AD | 53, 123/udp; 88, 389, 636, 3268/tcp as the AD logins need |
| Out | RKE2 nodes | SIEM VM | 1514, 1515/tcp (Wazuh agent) |
| In | Users, managed clusters | Load balancer (virtual IP) | 80, 443, 6443/tcp |

Everything else is denied. Open item: without firewalld, these nodes produce no host-firewall
connection log for the SIEM; the Proxmox VE firewall could add filtering and logging later.

## 6. Upgrading RKE2

The role never upgrades: with another version installed it stops. Upgrade one node at a time,
followers first and the first node last:

1. Download the new artifacts to the mirror (section 2).
2. On the node: put the new files in `/var/lib/rancher/rke2-artifacts/<new version>/`, run
   `INSTALL_RKE2_ARTIFACT_PATH=<that dir> INSTALL_RKE2_METHOD=tar sh install.sh`, then
   `systemctl restart rke2-server`, and wait until `kubectl get nodes` shows it `Ready` with the new
   version.
3. When every node runs it, set `rke2_version` (and the checksums) to the new version.

Take an etcd snapshot first (`rke2 etcd-snapshot save`); scheduled ones are kept in
`/var/lib/rancher/rke2/server/db/snapshots`. Check the new version against the Rancher support
matrix, and upgrade Rancher itself with the new chart through Terraform.

## 7. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `... must resolve to the load balancer's virtual IP` | DNS record missing or pointing elsewhere. |
| `These aren't mounted filesystems` | The data disks aren't mounted: run `playbooks/filesystems.yml`. |
| A node stays not Ready; `journalctl -u rke2-server` shows image pull errors | The image isn't in Harbor's `rancher` project, or the robot secret is wrong. `crictl pull registry.<domain>/rancher/<image>:<tag>` on the node shows the error. |
| Nodes 2 and 3 wait at "Wait for the cluster to accept new nodes" | The load balancer has no healthy 9345 server: check `sudo haproxy-status` on lb-rancher and that node 1 runs. |
| `RKE2 ... is installed ..., but rke2_version is ...` | Another version is installed: see section 6. |
| Terraform: `chart_path doesn't point at a file` | Copy the chart `.tgz` to the control node and set `chart_path`. |
| Rancher pods `ImagePullBackOff` | Rancher's own images missing from Harbor (`rancher-images.txt`). |
| Browser warns about the certificate | The `rancher` certificate doesn't cover `rancher.<domain>`, or the browser doesn't trust the internal CA. |

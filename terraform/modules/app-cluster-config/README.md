# Module `app-cluster-config`

Post-install configuration of the application cluster (`command-pro`), step 6 of an environment
build ([README.md](../../../README.md), "Building a new environment, in order"). It is called by
`terraform/k8s/<ENV>/app-cluster-config`, applied by hand once the app nodes have joined.

It reaches the cluster directly, through the RKE2 admin kubeconfig the Ansible play `rke2_app.yml`
copies to the control node (`~/.kube/<ENV>-app-cluster.yaml`, server `https://<app cluster
name>:6443` through lb-app), so it doesn't depend on Rancher. It holds no secrets.

## What it creates

| Resource | What it is |
|---|---|
| `helm_release.csi_driver_nfs` | csi-driver-nfs in `kube-system` (driver `nfs.csi.k8s.io`), images from Harbor |
| `kubernetes_storage_class_v1.nfs` | One storage class per entry of `storage_classes`, on `nfs_server` |
| `helm_release.cert_manager` | cert-manager in `cert-manager`, with its CRDs. No issuer yet |
| `helm_release.trust_manager` | trust-manager in `cert-manager`, with its CRDs. No bundle yet; its default package (public CAs) is off |

Each part is left out while its chart path is null.

**Not here:** Traefik's default certificate (the `command-pro` certificate) is set with the
cluster's definition in `terraform/k8s/<ENV>/rancher-config`, because Rancher passes it to RKE2's
Traefik chart.

## Storage classes

Each class provisions into its own folder on the NAS (`share`), with one folder per volume inside
it. The folder must exist: the NAS creates it (`subdirs` of the export in
`ansible/inventories/<ENV>/group_vars/nas_servers.yml`). The NAS exports the parent to the app nodes
with `no_root_squash`, because the driver creates the folders as root.

| Lab class | Share | Default | Reclaim | On delete | Expansion |
|---|---|---|---|---|---|
| `m-shared-pv` | `/export/pvcdata/m-shared-pv` | no | Delete | delete | no |
| `m-dedicated-pv` | `/export/pvcdata/m-dedicated-pv` | yes | Delete | delete | no |

"On delete" is csi-driver-nfs's `onDelete` parameter: `delete` removes the volume's folder with its
claim (what `archiveOnDelete: false` means for other NFS provisioners), `retain` keeps it. Mount
options: `nfs_mount_options` (`nfsvers=4.2`).

## Images

Every image comes from Harbor's `mirror` project, under its source registry and path
([ansible/docs/harbor.md](../../../ansible/docs/harbor.md)):

| Chart | Images |
|---|---|
| csi-driver-nfs 4.13.6 | `registry.k8s.io/sig-storage/`: `nfsplugin:v4.13.6`, `csi-provisioner:v6.3.0`, `csi-resizer:v2.2.1`, `csi-snapshotter:v8.6.0`, `livenessprobe:v2.19.0`, `csi-node-driver-registrar:v2.17.0` |
| cert-manager v1.21.3 | `quay.io/jetstack/`: `cert-manager-controller`, `-webhook`, `-cainjector`, `-startupapicheck`, all `v1.21.3` |
| trust-manager v0.26.0 | `quay.io/jetstack/trust-manager:v0.26.0` (and `trust-pkg-debian-trixie` only with `trust_manager_default_package`) |

csi-driver-nfs takes them through `image.baseRepo` and `image.nfs.repository`; the jetstack charts
through `imageRegistry` and `imageNamespace`. The tags stay the charts' own, so an upgrade only
needs the new chart on the mirror, its images in Harbor and the new chart path.

## Outputs

`storage_classes` (name → share), `default_storage_class`, `chart_versions`.

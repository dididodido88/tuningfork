# csi-driver-nfs and its storage classes. Each class provisions into its own folder on the NAS
# (share), a folder per volume inside it, and removes a volume's folder with its claim
# (onDelete delete, reclaimPolicy Delete) unless set otherwise. The NAS exports the folder's
# parent to the app nodes with no_root_squash, because the driver creates the folders as root.

resource "helm_release" "csi_driver_nfs" {
  count = var.csi_driver_nfs_chart_path == null ? 0 : 1

  name      = "csi-driver-nfs"
  namespace = "kube-system"
  chart     = pathexpand(var.csi_driver_nfs_chart_path)
  wait      = true
  timeout   = var.helm_timeout

  # Images from Harbor: the chart prefixes image.baseRepo to the sidecars' paths (/sig-storage/...),
  # and nfsplugin has a full repository of its own (chart 4.13.6 values). The chart's own snapshot
  # controller stays off: RKE2 runs one (rke2-snapshot-controller).
  values = [yamlencode({
    image = {
      baseRepo = local.mirror.registry_k8s_io
      nfs      = { repository = "${local.mirror.registry_k8s_io}/sig-storage/nfsplugin" }
    }
    externalSnapshotter = { enabled = false }
  })]
}

resource "kubernetes_storage_class_v1" "nfs" {
  for_each = var.csi_driver_nfs_chart_path == null ? {} : { for c in var.storage_classes : c.name => c }

  metadata {
    name = each.key
    annotations = each.value.default ? {
      "storageclass.kubernetes.io/is-default-class" = "true"
    } : {}
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = each.value.reclaim_policy
  allow_volume_expansion = each.value.allow_volume_expansion
  volume_binding_mode    = "Immediate"
  mount_options          = var.nfs_mount_options

  parameters = {
    server   = local.nfs_server
    share    = each.value.share
    onDelete = each.value.on_delete
  }

  depends_on = [helm_release.csi_driver_nfs]
}

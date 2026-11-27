# cert-manager and trust-manager, installed only (decided by the user): no issuer and no bundle
# yet. Both charts build every image from imageRegistry/imageNamespace/<name> (chart values of
# v1.21.3 and v0.26.0), so pointing those at Harbor covers all their images.

locals {
  jetstack_images = {
    imageRegistry  = local.registry
    imageNamespace = "${var.image_project}/quay.io/jetstack"
  }
}

resource "helm_release" "cert_manager" {
  count = var.cert_manager_chart_path == null ? 0 : 1

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  chart            = pathexpand(var.cert_manager_chart_path)
  wait             = true
  timeout          = var.helm_timeout

  values = [yamlencode(merge(local.jetstack_images, {
    # The chart leaves its CRDs out by default.
    crds = { enabled = true }
  }))]
}

resource "helm_release" "trust_manager" {
  count = var.cert_manager_chart_path != null && var.trust_manager_chart_path != null ? 1 : 0

  name      = "trust-manager"
  namespace = "cert-manager"
  chart     = pathexpand(var.trust_manager_chart_path)
  wait      = true
  timeout   = var.helm_timeout

  values = [yamlencode(merge(local.jetstack_images, {
    crds           = { enabled = true }
    defaultPackage = { enabled = var.trust_manager_default_package }
  }))]

  # trust-manager's webhook gets its certificate from cert-manager.
  depends_on = [helm_release.cert_manager]
}

# cert-manager and trust-manager (decided by the user, 2026-11-28):
#   - cert-manager signs with a ClusterIssuer of type CA, backed by the cluster's own subordinate
#     CA (scripts/certificates/subCA/init-sub-ca.sh), never the root's key. The sub-CA is
#     name-constrained to the environment's domains and can sign leaf certificates only.
#   - trust-manager copies the internal root CA (public certificate only) into every namespace as
#     a ConfigMap, so pods can trust Harbor, Rancher, the NAS, AD and each other.
#   - Certificates for pods are valid for certificate_duration (7 years). cert-manager has no
#     cluster-wide default (v1.21.3: no controller flag), so each Certificate sets spec.duration
#     and each Ingress the annotation cert-manager.io/duration (module README).
# Both charts build every image from imageRegistry/imageNamespace/<name> (chart values of v1.21.3
# and v0.26.0), so pointing those at Harbor covers all their images.
#
# The ClusterIssuer and the Bundle are custom resources: their CRDs (from the two charts) must
# exist when this unit is planned. On a cluster without them, apply the charts first:
#   terragrunt apply -target=helm_release.cert_manager -target=helm_release.trust_manager

locals {
  jetstack_images = {
    imageRegistry  = local.registry
    imageNamespace = "${var.image_project}/quay.io/jetstack"
  }

  # cert-manager runs with --cluster-resource-namespace=$(POD_NAMESPACE) and trust-manager with
  # --trust-namespace=cert-manager (their deployments' arguments), so a ClusterIssuer's secret and
  # a Bundle's sources live in the release namespace.
  cert_manager_namespace = "cert-manager"

  root_ca_file = "${var.certificate_dir}/ca/ca.cert.pem"
  issuer_dir   = var.issuer_ca_name == null ? null : "${var.certificate_dir}/${var.issuer_ca_name}"

  issuer_enabled = var.cert_manager_chart_path != null && var.issuer_ca_name != null
  bundle_enabled = var.cert_manager_chart_path != null && var.trust_manager_chart_path != null
}

resource "helm_release" "cert_manager" {
  count = var.cert_manager_chart_path == null ? 0 : 1

  name             = "cert-manager"
  namespace        = local.cert_manager_namespace
  create_namespace = true
  chart            = pathexpand(var.cert_manager_chart_path)
  wait             = true
  timeout          = var.helm_timeout

  values = [yamlencode(merge(local.jetstack_images, {
    # The chart leaves its CRDs out by default.
    crds = { enabled = true }
    # A ServiceMonitor for the cluster's Prometheus (monitoring.tf), which picks up every
    # ServiceMonitor: certificate expiry and renewal metrics. It needs the Prometheus Operator's
    # CRDs, so only with monitoring.
    prometheus = { servicemonitor = { enabled = local.monitoring_enabled } }
  }))]

  # The ServiceMonitor CRD comes with kube-prometheus-stack.
  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "trust_manager" {
  count = local.bundle_enabled ? 1 : 0

  name      = "trust-manager"
  namespace = local.cert_manager_namespace
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

# --- Issuer: the cluster's sub-CA -----------------------------------------------------------
# tls.crt is the sub-CA followed by the root (the script's fullchain), so every certificate
# cert-manager issues carries the full chain and its ca.crt is the root. The key is unencrypted
# (cert-manager needs it so) and lands in this unit's local state, like Traefik's key in
# rancher-config: keep terraform/state/ as protected as the vault.
resource "kubernetes_secret_v1" "issuer_ca" {
  count = local.issuer_enabled ? 1 : 0

  metadata {
    name      = "${var.cluster_issuer_name}-ca"
    namespace = local.cert_manager_namespace
  }
  type = "kubernetes.io/tls"
  # try(): a missing file is reported by the precondition below, with what to do about it.
  data = {
    "tls.crt" = try(file("${local.issuer_dir}/${var.issuer_ca_name}.fullchain.crt"), "")
    "tls.key" = try(file("${local.issuer_dir}/${var.issuer_ca_name}.key"), "")
  }

  lifecycle {
    precondition {
      condition = alltrue([
        for f in ["fullchain.crt", "key"] : fileexists("${local.issuer_dir}/${var.issuer_ca_name}.${f}")
      ])
      error_message = "The sub-CA's files aren't in certificate_dir/<issuer_ca_name>/. Run scripts/certificates/subCA/init-sub-ca.sh first (SUBCA_NAME = issuer_ca_name)."
    }
    # Rancher adds the namespace's project to secrets as this annotation.
    ignore_changes = [metadata[0].annotations["field.cattle.io/projectId"]]
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "cluster_issuer" {
  count = local.issuer_enabled ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = var.cluster_issuer_name }
    spec = {
      ca = { secretName = kubernetes_secret_v1.issuer_ca[0].metadata[0].name }
    }
  }

  depends_on = [helm_release.cert_manager]
}

# --- Trust: the root CA in every namespace ----------------------------------------------------
# The source holds only the root (servers send their intermediates in their chains); public CAs
# stay out (useDefaultCAs not set; trust_manager_default_package off). With no namespaceSelector,
# trust-manager writes the ConfigMap <trust_bundle_name> into every namespace, new ones included.
resource "kubernetes_config_map_v1" "root_ca" {
  count = local.bundle_enabled ? 1 : 0

  metadata {
    name      = "${var.trust_bundle_name}-source"
    namespace = local.cert_manager_namespace
  }
  data = {
    "ca.crt" = file(local.root_ca_file)
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations["field.cattle.io/projectId"]]
  }

  depends_on = [helm_release.trust_manager]
}

resource "kubernetes_manifest" "trust_bundle" {
  count = local.bundle_enabled ? 1 : 0

  # Bundle trust.cert-manager.io/v1alpha1: the only version trust-manager v0.26.0 serves.
  manifest = {
    apiVersion = "trust.cert-manager.io/v1alpha1"
    kind       = "Bundle"
    metadata   = { name = var.trust_bundle_name }
    spec = {
      sources = [{
        configMap = {
          name = kubernetes_config_map_v1.root_ca[0].metadata[0].name
          key  = "ca.crt"
        }
      }]
      target = {
        configMap = { key = var.trust_bundle_key }
      }
    }
  }

  depends_on = [helm_release.trust_manager]
}

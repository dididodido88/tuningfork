# Rancher Server on the Rancher RKE2 cluster, from the Helm chart on the mirror, and the default
# certificate of the Traefik ingress controller RKE2 ships.
#
# TLS: Rancher serves a certificate from the internal CA (tls-rancher-ingress) and is told the
# CA (tls-ca, privateCA), so no cert-manager is needed. Traefik serves the same certificate to
# requests that name no known host (for example by address). Images: every image comes from the
# private registry (Harbor, project rancher/); the nodes log in to it themselves
# (/etc/rancher/rke2/registries.yaml, written by Ansible), so no image pull secret is needed.
#
# The local state holds the certificate's private key and the bootstrap password: keep
# terraform/state/ as protected as the Ansible vault.

locals {
  kubeconfig = pathexpand(coalesce(var.kubeconfig_path, "~/.kube/${var.env_name}-rancher-cluster.yaml"))
  hostname   = coalesce(var.rancher_hostname, "rancher.${var.dns_domain}")
  registry   = coalesce(var.registry, "registry.${var.dns_domain}")
  cert_dir   = "${var.certificate_dir}/${var.certificate_name}"
  replicas   = coalesce(var.replicas, length(data.kubernetes_nodes.cluster.nodes))

  # The Rancher certificate (full chain) and key, used by Rancher's ingress and by Traefik.
  tls_data = {
    "tls.crt" = file("${local.cert_dir}/${var.certificate_name}.fullchain.crt")
    "tls.key" = file("${local.cert_dir}/${var.certificate_name}.key")
  }
}

data "kubernetes_nodes" "cluster" {}

# --- Traefik: default certificate ---------------------------------------------------------
# RKE2 installs Traefik from its own HelmChart (kube-system/rke2-traefik). A HelmChartConfig of
# the same name adds values to it, which is how RKE2 lets you configure the packaged charts. The
# chart's tlsStore value creates the TLSStore "default" in kube-system, so the secret lives there.

resource "kubernetes_secret_v1" "traefik_default_certificate" {
  count = var.traefik_default_certificate ? 1 : 0

  metadata {
    name      = "tls-default-certificate"
    namespace = "kube-system"
  }

  type = "kubernetes.io/tls"
  data = local.tls_data

  # Rancher adds the namespace's project to the secret as this annotation.
  lifecycle {
    ignore_changes = [metadata[0].annotations["field.cattle.io/projectId"]]
  }
}

resource "kubernetes_manifest" "traefik_config" {
  count = var.traefik_default_certificate ? 1 : 0

  manifest = {
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-traefik"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        tlsStore = {
          default = {
            defaultCertificate = {
              secretName = kubernetes_secret_v1.traefik_default_certificate[0].metadata[0].name
            }
          }
        }
      })
    }
  }
}

# --- Rancher ------------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "cattle_system" {
  metadata {
    name = "cattle-system"
  }

  # Rancher adds its own labels and annotations to this namespace.
  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

# Certificate and key Rancher's ingress serves for the hostname (full chain).
resource "kubernetes_secret_v1" "tls_rancher_ingress" {
  metadata {
    name      = "tls-rancher-ingress"
    namespace = kubernetes_namespace_v1.cattle_system.metadata[0].name
  }

  type = "kubernetes.io/tls"
  data = local.tls_data

  # Rancher adds the namespace's project to the secret as this annotation.
  lifecycle {
    ignore_changes = [metadata[0].annotations["field.cattle.io/projectId"]]
  }
}

# The internal root CA. Rancher passes it to the agents of managed clusters, so they trust
# the certificate above.
resource "kubernetes_secret_v1" "tls_ca" {
  metadata {
    name      = "tls-ca"
    namespace = kubernetes_namespace_v1.cattle_system.metadata[0].name
  }

  data = {
    "cacerts.pem" = file("${var.certificate_dir}/ca/ca.cert.pem")
  }

  # Rancher adds the namespace's project to the secret as this annotation.
  lifecycle {
    ignore_changes = [metadata[0].annotations["field.cattle.io/projectId"]]
  }
}

resource "helm_release" "rancher" {
  name      = "rancher"
  namespace = kubernetes_namespace_v1.cattle_system.metadata[0].name
  chart     = pathexpand(var.chart_path)
  wait      = true
  timeout   = var.helm_timeout

  # Through set_sensitive, not values: the provider writes values to its debug log (TF_LOG) and
  # to the release metadata in the state, but masks set_sensitive in both.
  set_sensitive = [{
    name  = "bootstrapPassword"
    value = var.rancher_bootstrap_password
  }]

  values = [yamlencode(merge({
    hostname = local.hostname
    replicas = local.replicas

    # An Ingress (not the Gateway API), served by the Traefik RKE2 ships (IngressClass "traefik",
    # host ports 80/443, which lb-rancher forwards to). TLS from the secrets above; the CA is
    # private.
    networkExposure = { type = "ingress" }
    ingress = {
      ingressClassName = "traefik"
      tls              = { source = "secret", secretName = "tls-rancher-ingress" }
    }
    privateCA = true

    # Air-gapped: systemDefaultRegistry puts Harbor in front of every image, Rancher's own
    # included (the chart's image.repository stays rancher/rancher). The system charts bundled in
    # the Rancher image are used instead of a Git repository.
    systemDefaultRegistry = local.registry
    useBundledSystemChart = true
  }, var.extra_values))]

  depends_on = [
    kubernetes_secret_v1.tls_rancher_ingress,
    kubernetes_secret_v1.tls_ca,
  ]
}

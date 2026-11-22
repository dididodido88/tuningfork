# Rancher Server on the Rancher RKE2 cluster, from the downloaded Helm chart.
#
# TLS: Rancher serves a certificate from the internal CA (tls-rancher-ingress) and is told the
# CA (tls-ca, privateCA), so no cert-manager is needed. Images: every image comes from the
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
}

data "kubernetes_nodes" "cluster" {}

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

  data = {
    "tls.crt" = file("${local.cert_dir}/${var.certificate_name}.fullchain.crt")
    "tls.key" = file("${local.cert_dir}/${var.certificate_name}.key")
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
}

resource "helm_release" "rancher" {
  name      = "rancher"
  namespace = kubernetes_namespace_v1.cattle_system.metadata[0].name
  chart     = pathexpand(var.chart_path)
  wait      = true
  timeout   = var.helm_timeout

  values = [yamlencode(merge({
    hostname          = local.hostname
    replicas          = local.replicas
    bootstrapPassword = var.rancher_bootstrap_password

    # TLS from the secrets above; tell Rancher the CA is private. The ingress controller is the
    # Traefik RKE2 ships (IngressClass "traefik", host ports 80/443, which lb-rancher forwards to).
    ingress = {
      ingressClassName = "traefik"
      tls              = { source = "secret" }
    }
    privateCA = true

    # Air-gapped: Rancher and every image it deploys come from the private registry, and the
    # system charts bundled in the Rancher image are used instead of a Git repository.
    rancherImage          = "${local.registry}/rancher/rancher"
    systemDefaultRegistry = local.registry
    useBundledSystemChart = true
  }, var.extra_values))]

  depends_on = [
    kubernetes_secret_v1.tls_rancher_ingress,
    kubernetes_secret_v1.tls_ca,
  ]
}

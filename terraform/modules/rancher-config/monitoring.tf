# Monitoring on the Rancher cluster, the Rancher 2.15 way: rancher-monitoring is deprecated, so
#   1. kube-prometheus-stack (upstream) from the chart on the mirror, released as
#      "kube-prometheus-stack" in cattle-monitoring-system: the names the dashboards chart expects;
#   2. rancher-monitoring-dashboards from Rancher's built-in catalog, which adds Rancher's dashboards
#      and the services Rancher's UI uses to reach Grafana, Prometheus and Alertmanager.
# The kube-prometheus-stack values the dashboards need come from that chart's README. No storage
# is persisted: metrics live as long as the pods (decided by the user; Prometheus doesn't support
# NFS, and Rancher keeps Prometheus as short-term storage).

locals {
  kubeconfig = pathexpand(coalesce(var.kubeconfig_path, "~/.kube/${var.env_name}-rancher-cluster.yaml"))
  registry   = coalesce(var.registry, "registry.${var.dns_domain}")

  # Every image from Harbor: <registry>/<project>/<source registry>/<path>. The tags stay the
  # chart's own, so a chart upgrade only needs the new images pushed under the same paths.
  monitoring_images = {
    for name, source in {
      prometheus    = "quay.io/prometheus/prometheus"
      alertmanager  = "quay.io/prometheus/alertmanager"
      operator      = "quay.io/prometheus-operator/prometheus-operator"
      reloader      = "quay.io/prometheus-operator/prometheus-config-reloader"
      certgen       = "ghcr.io/jkroepke/kube-webhook-certgen"
      grafana       = "docker.io/grafana/grafana"
      sidecar       = "quay.io/kiwigrid/k8s-sidecar"
      state_metrics = "registry.k8s.io/kube-state-metrics/kube-state-metrics"
      node_exporter = "quay.io/prometheus/node-exporter"
    } : name => { registry = local.registry, repository = "${var.monitoring_image_project}/${source}" }
  }

  kube_prometheus_stack_values = {
    prometheusOperator = {
      image                    = local.monitoring_images.operator
      prometheusConfigReloader = { image = local.monitoring_images.reloader }
      admissionWebhooks        = { patch = { image = local.monitoring_images.certgen } }
    }

    prometheus = {
      prometheusSpec = {
        image = local.monitoring_images.prometheus
        # Pick up every ServiceMonitor and PodMonitor, not only this release's (dashboards README).
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }

    alertmanager = {
      alertmanagerSpec = { image = local.monitoring_images.alertmanager }
    }

    grafana = {
      image   = local.monitoring_images.grafana
      sidecar = { image = local.monitoring_images.sidecar }
      # The chart's helm-test pod (bats image) isn't needed.
      testFramework = { enabled = false }
      # Required by rancher-monitoring-dashboards so Rancher's UI can embed the dashboards. Grafana
      # is reached only through Rancher's proxy (a ClusterIP service), and anonymous users are
      # Viewers. No root_url or serve_from_sub_path: the dashboards chart's proxy handles the path.
      "grafana.ini" = {
        security         = { allow_embedding = true }
        auth             = { disable_login_form = false }
        "auth.anonymous" = { enabled = true, org_role = "Viewer" }
        dashboards       = { default_home_dashboard_path = "/tmp/dashboards/rancher-default-home.json" }
        users            = { auto_assign_org_role = "Viewer" }
      }
    }

    "kube-state-metrics"       = { image = local.monitoring_images.state_metrics }
    "prometheus-node-exporter" = { image = local.monitoring_images.node_exporter }

    # Off, as the dashboards README asks: scraping these needs PushProx.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.monitoring_enabled ? 1 : 0

  name             = "kube-prometheus-stack"
  namespace        = "cattle-monitoring-system"
  create_namespace = true
  chart            = pathexpand(var.kube_prometheus_stack_chart_path)
  wait             = true
  timeout          = 900

  # Masked in the provider's log and the release metadata (as in rancher-server).
  set_sensitive = [{
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }]

  # Helm merges these in order, deeply: the extra values can override single keys.
  values = [
    yamlencode(local.kube_prometheus_stack_values),
    yamlencode(var.kube_prometheus_stack_extra_values),
  ]

  lifecycle {
    precondition {
      condition     = var.kube_prometheus_stack_chart_path != null && var.grafana_admin_password != null
      error_message = "Monitoring needs kube_prometheus_stack_chart_path in the unit and TF_VAR_grafana_admin_password in the shell."
    }
  }

  # AD login first, so the namespace and its pods appear in a Rancher that is already configured.
  depends_on = [rancher2_auth_config_activedirectory.ad]
}

resource "rancher2_app_v2" "monitoring_dashboards" {
  count = var.monitoring_enabled ? 1 : 0

  cluster_id    = "local"
  name          = "rancher-monitoring-dashboards"
  namespace     = "cattle-monitoring-system"
  repo_name     = "rancher-charts"
  chart_name    = "rancher-monitoring-dashboards"
  chart_version = var.monitoring_dashboards_chart_version

  # RKE2, not K3s (dashboards README). The other defaults match the release above.
  values = yamlencode({
    k3sServer = { enabled = false }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

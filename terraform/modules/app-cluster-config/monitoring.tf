# Monitoring on the application cluster, as on the Rancher cluster (rancher-config/monitoring.tf):
#   1. kube-prometheus-stack (upstream) from the chart on the mirror, released as
#      "kube-prometheus-stack" in cattle-monitoring-system: the names the dashboards chart expects;
#   2. rancher-monitoring-dashboards from Rancher's built-in catalog, installed through Rancher, which
#      adds Rancher's dashboards and the services Rancher's UI uses to reach Grafana, Prometheus and
#      Alertmanager;
#   3. the viewer group's read-only access to them (View Monitoring in the System project).
# No storage is persisted, as on the Rancher cluster (decided by the user). Keep the values in step
# with rancher-config/monitoring.tf, so both clusters are monitored the same way.

locals {
  monitoring_enabled = var.kube_prometheus_stack_chart_path != null

  # Every image from Harbor's mirror project: <registry>/<project>/<source registry>/<path>, tags
  # the chart's own (the same images the Rancher cluster uses).
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
    } : name => { registry = local.registry, repository = "${var.image_project}/${source}" }
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
  count = local.monitoring_enabled ? 1 : 0

  name             = "kube-prometheus-stack"
  namespace        = "cattle-monitoring-system"
  create_namespace = true
  chart            = pathexpand(var.kube_prometheus_stack_chart_path)
  wait             = true
  timeout          = 900

  # Masked in the provider's log and the release metadata.
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
      condition     = var.grafana_admin_password != null
      error_message = "Monitoring needs TF_VAR_grafana_admin_password in the shell."
    }
  }
}

# Installed through Rancher, like any app from its catalog. On a downstream cluster the chart's
# Grafana proxy serves the dashboards under /k8s/clusters/<clusterId>/... (its
# monitoring-proxy-configmap.yaml), so global.cattle.clusterId must be this cluster's ID; it is
# set here so the URL doesn't depend on what the provider adds.
resource "rancher2_app_v2" "monitoring_dashboards" {
  count = local.monitoring_enabled ? 1 : 0

  cluster_id    = var.app_cluster_id
  name          = "rancher-monitoring-dashboards"
  namespace     = "cattle-monitoring-system"
  repo_name     = "rancher-charts"
  chart_name    = "rancher-monitoring-dashboards"
  chart_version = var.monitoring_dashboards_chart_version

  # RKE2, not K3s (dashboards README). The other defaults match the release above.
  values = yamlencode({
    global    = { cattle = { clusterId = var.app_cluster_id } }
    k3sServer = { enabled = false }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}

# --- Read-only dashboards for the viewer group -----------------------------------------------
# As on the Rancher cluster: the dashboards chart's ClusterRole monitoring-ui-view allows the
# services/proxy calls Rancher's UI makes, and Rancher's role template of the same name ("View
# Monitoring") is a project role. Helm created cattle-monitoring-system outside any project, so it
# goes into this cluster's System project first, then the viewer group gets View Monitoring there.

data "rancher2_project" "system" {
  count = local.monitoring_enabled ? 1 : 0

  cluster_id = var.app_cluster_id
  name       = "System"
}

resource "kubernetes_annotations" "monitoring_namespace_project" {
  count = local.monitoring_enabled ? 1 : 0

  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "cattle-monitoring-system"
  }
  annotations = {
    "field.cattle.io/projectId" = data.rancher2_project.system[0].id
  }
  # Rancher's controllers also write this namespace; keep this one annotation ours.
  force = true

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "rancher2_project_role_template_binding" "viewers_monitoring" {
  count = local.monitoring_enabled ? 1 : 0

  name               = "ad-viewers-monitoring-ui-view"
  project_id         = data.rancher2_project.system[0].id
  role_template_id   = "monitoring-ui-view"
  group_principal_id = var.viewer_group_principal

  depends_on = [
    kubernetes_annotations.monitoring_namespace_project,
    rancher2_app_v2.monitoring_dashboards,
  ]
}

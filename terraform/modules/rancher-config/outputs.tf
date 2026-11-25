# Outputs of the module, shown by `terragrunt output` in terraform/k8s/<ENV>/rancher-config.
output "url" {
  description = "Rancher Server address."
  value       = "${local.api_url}/"
}

output "admin_group" {
  description = "Principal of the AD group with the global role admin."
  value       = local.admin_group_principal
}

output "viewer_group" {
  description = "Principal of the AD group that may view every cluster."
  value       = local.viewer_group_principal
}

output "cluster_viewer_role_id" {
  description = "ID of the global role Cluster Viewer."
  value       = rancher2_global_role.cluster_viewer.id
}

output "test_user" {
  description = "Principal of the AD test account, linked to the local admin and allowed by name."
  value       = local.test_user_principal
}

output "kube_prometheus_stack_version" {
  description = "Version of the deployed kube-prometheus-stack chart, or null when monitoring is off."
  value       = var.monitoring_enabled ? helm_release.kube_prometheus_stack[0].metadata.version : null
}

# Outputs of the module, shown by `terragrunt output` in terraform/k8s/<ENV>/rancher-server.
output "url" {
  description = "Rancher Server address."
  value       = "https://${local.hostname}/"
}

output "replicas" {
  description = "Rancher pods deployed."
  value       = local.replicas
}

output "chart_version" {
  description = "Version of the deployed Rancher chart."
  value       = helm_release.rancher.metadata.version
}

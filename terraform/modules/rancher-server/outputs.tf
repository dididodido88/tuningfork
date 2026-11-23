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

output "traefik_default_certificate" {
  description = "Secret Traefik serves when a request names no known host, or null when off."
  value       = var.traefik_default_certificate ? "kube-system/${kubernetes_secret_v1.traefik_default_certificate[0].metadata[0].name}" : null
}

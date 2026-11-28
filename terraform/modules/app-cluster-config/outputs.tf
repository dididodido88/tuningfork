# Outputs of the module, shown by `terragrunt output` in terraform/k8s/<ENV>/app-cluster-config.
output "storage_classes" {
  description = "Storage classes created, with their share on the NFS server."
  value       = { for name, c in kubernetes_storage_class_v1.nfs : name => c.parameters.share }
}

output "default_storage_class" {
  description = "The cluster's default storage class, or null."
  value       = one([for c in var.storage_classes : c.name if c.default && var.csi_driver_nfs_chart_path != null])
}

output "chart_versions" {
  description = "Deployed chart versions."
  value = {
    csi_driver_nfs = one(helm_release.csi_driver_nfs[*].metadata.version)
    cert_manager   = one(helm_release.cert_manager[*].metadata.version)
    trust_manager  = one(helm_release.trust_manager[*].metadata.version)
  }
}

output "kube_prometheus_stack_version" {
  description = "Version of the deployed kube-prometheus-stack chart, or null when monitoring is off."
  value       = one(helm_release.kube_prometheus_stack[*].metadata.version)
}

output "cluster_issuer" {
  description = "Name of the ClusterIssuer backed by the cluster's sub-CA, or null."
  value       = one(kubernetes_manifest.cluster_issuer[*].manifest.metadata.name)
}

output "trust_bundle" {
  description = "ConfigMap (name and key) holding the internal root CA in every namespace, or null."
  value       = local.bundle_enabled ? { name = var.trust_bundle_name, key = var.trust_bundle_key } : null
}

output "certificate_duration" {
  description = "Lifetime every Certificate on this cluster sets in spec.duration (and every Ingress in cert-manager.io/duration)."
  value       = var.certificate_duration
}

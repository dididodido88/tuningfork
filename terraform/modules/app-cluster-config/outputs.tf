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

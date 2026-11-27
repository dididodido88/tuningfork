# Post-install configuration of the application cluster (step 6 of an environment build, after
# the nodes joined): what the cluster needs before user workloads arrive.
#   - csi-driver-nfs, and storage classes on the NAS (storage.tf);
#   - cert-manager and trust-manager, installed without an issuer or bundle (certificates.tf).
# Every chart comes from the mirror (/repo on the control node) and every image from Harbor's
# mirror project. Traefik's default certificate stays with the cluster's definition in
# terraform/k8s/<ENV>/rancher-config, because Rancher passes it to RKE2's Traefik chart.

locals {
  kubeconfig = pathexpand(coalesce(var.kubeconfig_path, "~/.kube/${var.env_name}-app-cluster.yaml"))
  registry   = coalesce(var.registry, "registry.${var.dns_domain}")
  nfs_server = coalesce(var.nfs_server, "nas.${var.dns_domain}")

  # <registry>/<project>/<source registry>, the prefix of every upstream image (docs/harbor.md).
  mirror = {
    registry_k8s_io = "${local.registry}/${var.image_project}/registry.k8s.io"
    quay_io         = "${local.registry}/${var.image_project}/quay.io"
  }
}

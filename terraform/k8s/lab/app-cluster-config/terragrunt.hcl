# lab: post-install configuration of the application cluster command-pro (step 6 of an environment
# build, README.md): csi-driver-nfs with its storage classes on the NAS, cert-manager and
# trust-manager. Applied by hand, after the app nodes joined: the Ansible play rke2_app.yml writes
# the kubeconfig this unit uses (~/.kube/lab-app-cluster.yaml). No secrets.
#   cd terraform/k8s/lab/app-cluster-config && terragrunt init && terragrunt apply
#
# Every field: terraform/modules/app-cluster-config/variables.tf.

include "root" {
  path = find_in_parent_folders("root.hcl")
  # deep: combine the terraform {} block below with the one in k8s/root.hcl.
  merge_strategy = "deep"
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules/app-cluster-config"
}

# The cluster and its Traefik certificate are defined there.
dependencies {
  paths = ["../rancher-config"]
}

inputs = {
  # --- Storage: csi-driver-nfs, classes on nas.lab.local:/export/pvcdata/<class> ---
  # The folders are made by the NAS (subdirs in ansible/inventories/lab/group_vars/nas_servers.yml).
  csi_driver_nfs_chart_path = "/repo/helm/charts/csi-driver-nfs/csi-driver-nfs-v4.13.6.tgz" # REPLACE: the file name on the mirror
  storage_classes = [
    { name = "m-shared-pv", share = "/export/pvcdata/m-shared-pv" },
    { name = "m-dedicated-pv", share = "/export/pvcdata/m-dedicated-pv", default = true },
  ]

  # --- cert-manager and trust-manager, installed only (no issuer or bundle yet) ---
  cert_manager_chart_path  = "/repo/helm/charts/cert-manager/cert-manager-v1.21.3.tgz"
  trust_manager_chart_path = "/repo/helm/charts/trust-manager/trust-manager-v0.26.0.tgz"

  # Defaults, shown for reference:
  #   kubeconfig_path               = "~/.kube/lab-app-cluster.yaml"
  #   registry                      = "registry.lab.local"
  #   image_project                 = "mirror"
  #   nfs_server                    = "nas.lab.local"
  #   nfs_mount_options             = ["nfsvers=4.2"]
  #   trust_manager_default_package = false
  #   (each storage class: reclaim_policy "Delete", on_delete "delete", allow_volume_expansion false)
}

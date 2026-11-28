# lab: post-install configuration of the application cluster command-pro (step 6 of an environment
# build, README.md): csi-driver-nfs with its storage classes on the NAS, cert-manager,
# trust-manager and monitoring. Applied by hand, after the app nodes joined: the Ansible play
# rke2_app.yml writes the kubeconfig this unit uses (~/.kube/lab-app-cluster.yaml). Rancher's API
# token, the cluster's ID and the viewer group come from rancher-config's state (dependency below).
# Type Grafana's admin password from the vault at the prompt:
#   read -rsp "grafana_admin_password: " TF_VAR_grafana_admin_password; echo; export TF_VAR_grafana_admin_password
#   cd terraform/k8s/lab/app-cluster-config && terragrunt init && terragrunt apply
#
#   grafana_admin_password   vault_rancher_grafana_admin_password (the same Grafana admin as the
#                            Rancher cluster's; a separate vault key works the same way)
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

# The cluster and its Traefik certificate are defined there. Its outputs give this unit Rancher's
# address and API token, the cluster's ID and the viewer group. The mocks serve validate only.
dependency "rancher_config" {
  config_path = "../rancher-config"

  mock_outputs = {
    url            = "https://rancher.lab.local/"
    api_token      = "mock"
    app_cluster_id = "c-m-mock"
    viewer_group   = "activedirectory_group://mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  # certificates_env_dir of this environment in the Ansible inventory (reads ca/ca.cert.pem).
  certificate_dir = "/srv/security/certificates/files/lab.local"

  rancher_url            = dependency.rancher_config.outputs.url
  rancher_api_token      = dependency.rancher_config.outputs.api_token
  app_cluster_id         = dependency.rancher_config.outputs.app_cluster_id
  viewer_group_principal = dependency.rancher_config.outputs.viewer_group

  # --- Storage: csi-driver-nfs, classes on nas.lab.local:/export/pvcdata/<class> ---
  # The folders are made by the NAS (subdirs in ansible/inventories/lab/group_vars/nas_servers.yml).
  csi_driver_nfs_chart_path = "/repo/helm/charts/csi-driver-nfs/csi-driver-nfs-4.13.6.tgz"
  storage_classes = [
    { name = "m-shared-pv", share = "/export/pvcdata/m-shared-pv" },
    { name = "m-dedicated-pv", share = "/export/pvcdata/m-dedicated-pv", default = true },
  ]

  # --- cert-manager and trust-manager, installed only (no issuer or bundle yet) ---
  cert_manager_chart_path  = "/repo/helm/charts/cert-manager/cert-manager-v1.21.3.tgz"
  trust_manager_chart_path = "/repo/helm/charts/trust-manager/trust-manager-v0.26.0.tgz"

  # --- Monitoring: the Rancher cluster's chart and images (mirror/<registry>/...) ---
  kube_prometheus_stack_chart_path = "/repo/helm/charts/kube-prometheus-stack/kube-prometheus-stack-93.9.0.tgz"

  # Defaults, shown for reference:
  #   kubeconfig_path               = "~/.kube/lab-app-cluster.yaml"
  #   registry                      = "registry.lab.local"
  #   image_project                 = "mirror"
  #   nfs_server                    = "nas.lab.local"
  #   nfs_mount_options             = ["nfsvers=4.2"]
  #   trust_manager_default_package = false
  #   monitoring_dashboards_chart_version = "110.0.1+up0.1.4"
  #   (each storage class: reclaim_policy "Delete", on_delete "delete", allow_volume_expansion false)
}

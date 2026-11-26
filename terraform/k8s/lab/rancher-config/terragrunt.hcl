# lab: Rancher's own configuration: the admin password, Active Directory login, who may do
# what, monitoring and the application cluster. Applied by hand, after rancher-server. Type each
# secret from the vault at the prompts, so none is left in the shell history:
#   for v in rancher_bootstrap_password rancher_admin_password ad_service_account_password ad_test_password \
#            grafana_admin_password harbor_k8s_pull_secret; do
#     read -rsp "$v: " "TF_VAR_$v"; echo; export "TF_VAR_$v"
#   done
#   cd terraform/k8s/lab/rancher-config && terragrunt init && terragrunt apply
#
#   rancher_bootstrap_password    vault_rancher_bootstrap_password
#   rancher_admin_password        vault_rancher_admin_password
#   ad_service_account_password   vault_harbor_ldap_bind_password (svc_ldap_bind)
#   ad_test_password              vault_rancher_ad_test_password
#   grafana_admin_password        vault_rancher_grafana_admin_password
#   harbor_k8s_pull_secret        vault_harbor_robot_secrets['k8s-pull']
#
# Every field: terraform/modules/rancher-config/variables.tf. Guide: ansible/docs/rancher.md.

include "root" {
  path = find_in_parent_folders("root.hcl")
  # deep: combine the terraform {} block below with the one in k8s/root.hcl.
  merge_strategy = "deep"
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules/rancher-config"
}

# Rancher must be installed first.
dependencies {
  paths = ["../rancher-server"]
}

inputs = {
  # certificates_env_dir of this environment in the Ansible inventory (reads ca/ca.cert.pem).
  certificate_dir = "/srv/security/certificates/files/lab.local"

  # --- Active Directory: the same directory and bind account as Harbor (registry_servers.yml) ---
  ad_default_login_domain     = "LAB"
  ad_service_account_username = "svc_ldap_bind"
  ad_search_base              = "DC=lab,DC=local"

  # Users are in sg-lab-admins and sg-all-users through other groups, so Rancher must follow
  # nested membership; with direct membership only it refused them ("Permission denied").
  ad_nested_groups = true

  # A dedicated AD account in no AD group, so it opens nothing but Rancher. Rancher links it to the
  # local admin (which makes it an administrator); the module allows it to log in by its DN.
  ad_test_username = "svc_rancher_admin"
  ad_test_user_dn  = "CN=svc_rancher_admin,OU=Service Accounts,OU=Lab,DC=lab,DC=local"

  # --- Access ---
  admin_group_dn  = "CN=sg-lab-admins,OU=Groups,OU=Lab,DC=lab,DC=local"
  viewer_group_dn = "CN=sg-all-users,OU=Groups,OU=Lab,DC=lab,DC=local"

  # --- Monitoring: kube-prometheus-stack from the mirror, images from Harbor (mirror/<registry>/...) ---
  kube_prometheus_stack_chart_path = "/repo/helm/charts/kube-prometheus-stack/kube-prometheus-stack-93.9.0.tgz"

  # --- Application cluster command-pro (custom, provisioned by Rancher; no nodes join yet) ---
  # lb-app's virtual IP (keepalived_vip in terraform/live/lab/lb-app), besides command-pro.lab.local.
  app_cluster_tls_sans = ["192.168.70.90"]

  # command-pro's RKE2 server CA, copied from a node once it joined, for the direct kubeconfig
  # context through lb-app (ansible/docs/app-cluster.md).
  app_cluster_ace_ca_file = "/srv/security/certificates/files/lab.local/command-pro/rke2-server-ca.crt"

  # Traefik's default certificate on command-pro (443 behind lb-app): certificate_dir/command-pro/.
  app_cluster_certificate_name = "command-pro"

  # Defaults, shown for reference:
  #   rancher_hostname     = "rancher.lab.local"
  #   ad_servers           = ["lab.local"]
  #   ad_port              = 636
  #   viewer_cluster_roles = ["projects-view", "nodes-view", "clusterroletemplatebindings-view", "clustercatalogs-view"]
  #   monitoring_enabled                  = true
  #   monitoring_dashboards_chart_version = "110.0.1+up0.1.4"
  #   monitoring_image_project            = "mirror"
  #   app_cluster_name                    = "command-pro"
  #   app_cluster_kubernetes_version      = "v1.36.5+rke2r1"
  #   app_cluster_hostname                = "command-pro.lab.local"
}

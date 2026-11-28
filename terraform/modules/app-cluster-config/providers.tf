# The kubernetes and helm providers talk to the application cluster directly, through the RKE2
# admin kubeconfig that the Ansible play rke2_app.yml copies to the control node once the first
# node has joined. Its server is https://<app cluster name>:6443, through lb-app.
provider "kubernetes" {
  config_path = local.kubeconfig
}

provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}

# rancher2: Rancher's API, for what only Rancher does (its catalog's monitoring dashboards, projects,
# role bindings). The admin token comes from rancher-config's state, through Terragrunt.
provider "rancher2" {
  api_url   = trimsuffix(var.rancher_url, "/")
  token_key = var.rancher_api_token
  ca_certs  = file("${var.certificate_dir}/ca/ca.cert.pem")
}

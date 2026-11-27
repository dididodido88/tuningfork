# Both providers talk to the application cluster directly, through the RKE2 admin kubeconfig that
# the Ansible play rke2_app.yml copies to the control node once the first node has joined. Its
# server is https://<app cluster name>:6443, through lb-app, so this unit works while Rancher is down.
provider "kubernetes" {
  config_path = local.kubeconfig
}

provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}

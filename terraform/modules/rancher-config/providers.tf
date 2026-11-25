# Two configurations of the rancher2 provider, both on https://<rancher hostname> and trusting the
# internal CA:
#   - bootstrap: no token; used only by rancher2_bootstrap, which logs in with the bootstrap
#     password, sets the admin password and the server URL, and returns an admin API token.
#   - default: that token; used by everything else.
provider "rancher2" {
  alias     = "bootstrap"
  api_url   = local.api_url
  ca_certs  = local.ca_cert
  bootstrap = true
}

provider "rancher2" {
  api_url   = rancher2_bootstrap.admin.url
  token_key = rancher2_bootstrap.admin.token
  ca_certs  = local.ca_cert
}

# Helm, for kube-prometheus-stack: through the kubeconfig Ansible wrote on the control node, like
# the rancher-server unit.
provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}

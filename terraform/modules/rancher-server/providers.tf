# Both providers talk to the Rancher RKE2 cluster through the kubeconfig Ansible wrote on the
# control node. Its server is https://<rancher hostname>:6443, through the load balancer.
provider "kubernetes" {
  config_path = local.kubeconfig
}

provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}

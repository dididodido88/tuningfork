# lab: Rancher Server on the Rancher RKE2 cluster, from the Helm chart on the mirror, and the
# Rancher certificate as the default certificate of RKE2's Traefik.
# Applied by hand, after Ansible has built the cluster (playbooks/rke2_rancher.yml writes the
# kubeconfig this unit uses):
#   read -rsp "Bootstrap password: " TF_VAR_rancher_bootstrap_password; echo   # vault_rancher_bootstrap_password
#   export TF_VAR_rancher_bootstrap_password
#   cd terraform/k8s/lab/rancher-server && terragrunt init && terragrunt apply
#
# Every field: terraform/modules/rancher-server/variables.tf. Guide: ansible/docs/rancher.md.

include "root" {
  path = find_in_parent_folders("root.hcl")
  # deep: combine the terraform {} block below with the one in k8s/root.hcl.
  merge_strategy = "deep"
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/../modules/rancher-server"
}

inputs = {
  # The Rancher chart, read from the mirror's folder on this machine (docs/rancher.md).
  chart_path = "/repo/helm/charts/rancher/rancher-2.15.3.tgz"

  # certificates_env_dir of this environment in the Ansible inventory.
  certificate_dir = "/srv/security/certificates/files/lab.local"

  # Defaults, shown for reference:
  #   rancher_hostname = "rancher.lab.local"
  #   registry         = "registry.lab.local"
  #   kubeconfig_path  = "~/.kube/lab-rancher-cluster.yaml"
  #   replicas         = one per cluster node
  #   traefik_default_certificate = true
}

# CRGS00: Rancher Server on the Rancher RKE2 cluster, from the downloaded Helm chart.
# Applied by hand, after Ansible has built the cluster (playbooks/rke2_rancher.yml writes the
# kubeconfig this unit uses):
#   export TF_VAR_rancher_bootstrap_password='<first admin password>'
#   cd terraform/k8s/CRGS00/rancher-server && terragrunt init && terragrunt apply
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
  # The Rancher chart, copied from the mirror to this machine (docs/rancher.md).
  chart_path = "/srv/rancher/charts/rancher-2.12.3.tgz" # REPLACE: the version you downloaded

  # certificates_env_dir of this environment in the Ansible inventory.
  certificate_dir = "/srv/security/certificates/files/crgs00.local"

  # Defaults, shown for reference:
  #   rancher_hostname = "rancher.example.internal"
  #   registry         = "registry.example.internal"
  #   kubeconfig_path  = "~/.kube/CRGS00-rancher-cluster.yaml"
  #   replicas         = one per cluster node
}

# Shared Terragrunt configuration for deployments onto Kubernetes clusters that Ansible built
# (Helm releases such as Rancher Server). Every unit under k8s/<ENV>/ includes this file:
#   include "root" { path = find_in_parent_folders("root.hcl"), merge_strategy = "deep" }
#
# Kept apart from live/ on purpose: these units need a running cluster and are applied by
# hand after Ansible, so `terragrunt run --all` in live/<ENV> must never reach them.
#
# It provides:
#   - local state under terraform/state/k8s/<ENV>/<unit> (git-ignored)
#   - air-gapped provider installation (same plugin directory as ../root.hcl)
#   - the environment's name and DNS domain, read from live/<ENV>/env.hcl
# There is no Proxmox provider here; each module configures its own Kubernetes providers.

locals {
  # k8s/<ENV>/<unit>: the environment is the name of the unit's parent directory.
  env_name = basename(dirname(get_terragrunt_dir()))
  env      = read_terragrunt_config("${get_parent_terragrunt_dir()}/../live/${local.env_name}/env.hcl").locals
}

remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    # terraform/state/k8s/<ENV>/<unit>/terraform.tfstate
    path = "${get_parent_terragrunt_dir()}/../state/k8s/${path_relative_to_include()}/terraform.tfstate"
  }
}

terraform {
  # Air-gapped: install providers only from the local plugin directory. Keep this the same as
  # in ../root.hcl. The helm, kubernetes and rancher2 providers must be in it (terraform/README.md).
  extra_arguments "plugin_dir" {
    commands  = ["init"]
    arguments = ["-plugin-dir=/root/.terraform.d/plugins"]
  }
}

inputs = {
  env_name   = local.env.env_name
  dns_domain = local.env.dns_domain
}

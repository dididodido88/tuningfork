# Shared Terragrunt configuration. Every unit under live/ includes this file:
#   include "root" { path = find_in_parent_folders("root.hcl") }
#
# It provides:
#   - local state, kept under terraform/state/ (outside .terragrunt-cache, git-ignored)
#   - the proxmox provider block, pointed at the environment's Proxmox API (env.hcl)
#   - air-gapped provider installation from terraform/providers/
#   - the environment's network/DNS/SSH settings as module inputs

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    path = "${get_parent_terragrunt_dir()}/state/${path_relative_to_include()}/terraform.tfstate"
  }
}

# Credentials are NOT set here. Export them before running Terragrunt:
#   export PROXMOX_VE_API_TOKEN='terraform@pve!provider=<uuid>'
# Cloning and cloud-init through the API need no SSH access to the nodes, so there is no ssh {} block.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "proxmox" {
      endpoint = "${local.env.proxmox_endpoint}"
      insecure = ${local.env.proxmox_insecure}
    }
  EOF
}

terraform {
  # Air-gapped: install providers only from terraform/providers/ (see terraform/README.md).
  # -plugin-dir turns off registry downloads completely.
  extra_arguments "plugin_dir" {
    commands  = ["init"]
    arguments = ["-plugin-dir=${get_parent_terragrunt_dir()}/providers"]
  }
}

inputs = {
  node_name       = local.env.node_name
  datastore_id    = local.env.datastore_id
  network_bridge  = local.env.network_bridge
  vlan_id         = local.env.vlan_id
  ipv4_gateway    = local.env.ipv4_gateway
  dns_servers     = local.env.dns_servers
  dns_domain      = local.env.dns_domain
  ssh_public_keys = local.env.ssh_public_keys
}

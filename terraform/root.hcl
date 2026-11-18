# Shared Terragrunt configuration. Every unit under live/ includes this file:
#   include "root" { path = find_in_parent_folders("root.hcl") }
#
# It provides:
#   - local state, kept under terraform/state/ (outside .terragrunt-cache, git-ignored)
#   - the proxmox provider block, pointed at the environment's Proxmox API (env.hcl)
#   - air-gapped provider installation from terraform/providers/
#   - the environment's placement, network, DNS and SSH settings as module inputs

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
    # One state file per unit: terraform/state/live/<ENV>/<unit>/terraform.tfstate
    path = "${get_parent_terragrunt_dir()}/state/${path_relative_to_include()}/terraform.tfstate"
  }
}

# Credentials are NOT set here. Export them before running Terragrunt:
#   export PROXMOX_VE_API_TOKEN='terraform@pve!provider=<uuid>'
# Cloning and cloud-init go through the API and need no SSH access to the Proxmox nodes, so
# there is no ssh {} block. (The bootstrap logs in to the new VMs, not to the nodes.)
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
#    arguments = ["-plugin-dir=${get_parent_terragrunt_dir()}/providers"] # if you want to store in the project folder, but it is commmited to git unless added 
    arguments = ["-plugin-dir=/root/.terraform.d/plugins"] # points to root home folder instead to avoid
  }
}

# Environment defaults. A VM can override node_name, datastore_id, network_bridge, vlan_id and
# ipv4_gateway in its unit; a single data disk can override datastore_id.
inputs = merge(
  {
    node_name      = local.env.node_name
    datastore_id   = local.env.datastore_id
    network_bridge = local.env.network_bridge
    vlan_id        = local.env.vlan_id
    ipv4_gateway   = local.env.ipv4_gateway
    dns_servers    = local.env.dns_servers
    dns_domain     = local.env.dns_domain

    # Keys authorised for the Ansible account the bootstrap creates.
    ssh_public_keys = local.env.ssh_public_keys
  },
  # Bootstrap: private half of the root key seeded in the template, on this machine. Optional:
  # when env.hcl doesn't set it, the input is left out (not passed as null) and the module uses
  # the SSH agent.
  try({ bootstrap_private_key_file = local.env.bootstrap_private_key_file }, {}),
)

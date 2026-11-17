# Provider requirements for the module. The providers come from terraform/providers/
# (air-gapped, see terraform/README.md), and each Terragrunt unit records what it uses in
# its .terraform.lock.hcl.
terraform {
  # terraform_data (used for the bootstrap) needs 1.4; optional() object attributes need 1.3.
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Pinned: to move to another release, change it here and refresh terraform/providers/.
      version = "0.122.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0, < 3.0.0"
    }
  }
}

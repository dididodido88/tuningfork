# Provider requirements for the module. The exact versions in use are recorded in each
# Terragrunt unit's .terraform.lock.hcl; the providers come from terraform/providers/
# (air-gapped, see terraform/README.md).
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0, < 1.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0, < 3.0.0"
    }
  }
}

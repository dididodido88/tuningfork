# Provider requirements. The providers come from the local plugin directory (air-gapped, see
# terraform/README.md); each Terragrunt unit records the exact versions in .terraform.lock.hcl.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source = "hashicorp/helm"
      # v3: the provider's kubernetes settings are an attribute (kubernetes = {...}), not a block.
      version = ">= 3.0.0, < 4.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0, < 4.0.0"
    }
  }
}

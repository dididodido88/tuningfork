# Provider requirements. The provider comes from the local plugin directory (air-gapped, see
# terraform/README.md); each Terragrunt unit records the exact version in .terraform.lock.hcl.
# rancher2 15.x is the line for Rancher 2.15.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    rancher2 = {
      source  = "rancher/rancher2"
      version = ">= 15.3.0, < 16.0.0"
    }
  }
}

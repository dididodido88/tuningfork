# CRGS01: Proxmox and network settings for every Terragrunt unit in this environment.
# The values are EXAMPLES (documentation addresses, example.internal): replace them.
# Keep env_name equal to the Ansible inventory directory name (ansible/inventories/CRGS01).

locals {
  env_name = "CRGS01"

  # Proxmox API. The token comes from PROXMOX_VE_API_TOKEN, never from this file.
  proxmox_endpoint = "https://pve01.example.internal:8006/"
  # true only while the API certificate isn't trusted by the machine running Terraform.
  proxmox_insecure = false

  # Where the VMs go (a VM can override node_name in the unit).
  node_name    = "pve01"
  datastore_id = "local-lvm"

  # Network. vlan_id = null for an untagged bridge.
  network_bridge = "vmbr0"
  vlan_id        = null
  ipv4_gateway   = "198.51.100.1"
  dns_servers    = ["198.51.100.2", "198.51.100.3"]
  dns_domain     = "example.internal" # same as env_domain in ansible/inventories/CRGS01/group_vars/all/main.yml

  # Keys authorised for the ansible account on new VMs.
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHTHEANSIBLECONTROLNODEKEY ansible@control-node",
  ]

  # Prepared Rocky 9 template (see terraform/README.md, "Template requirements").
  rocky9_template_vm_id     = 9000
  rocky9_template_node_name = "pve01"
}

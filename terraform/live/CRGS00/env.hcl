# CRGS00: Proxmox and network settings for every Terragrunt unit in this environment.
# The values are EXAMPLES (documentation addresses, example.internal): replace them.
# Keep env_name equal to the Ansible inventory directory name (ansible/inventories/CRGS00).

locals {
  env_name = "CRGS00"

  # Proxmox API. The token comes from PROXMOX_VE_API_TOKEN, never from this file.
  proxmox_endpoint = "https://pve00.example.internal:8006/"
  # true only while the API certificate isn't trusted by the machine running Terraform.
  proxmox_insecure = false

  # Where the VMs go (a VM can override node_name in the unit).
  node_name    = "pve00"
  datastore_id = "local-lvm"

  # Network. vlan_id = null for an untagged bridge.
  network_bridge = "vmbr0"
  vlan_id        = null
  ipv4_gateway   = "192.0.2.1"
  dns_servers    = ["192.0.2.2", "192.0.2.3"]
  dns_domain     = "example.internal" # same as env_domain in ansible/inventories/CRGS00/group_vars/all/main.yml

  # Keys authorised for the ansible account on new VMs.
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHTHEANSIBLECONTROLNODEKEY ansible@control-node",
  ]

  # Prepared Rocky 9 template (see terraform/README.md, "Template requirements").
  rocky9_template_vm_id     = 9000
  rocky9_template_node_name = "pve00"
}

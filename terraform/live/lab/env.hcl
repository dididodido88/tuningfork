# lab: Proxmox and network settings for every Terragrunt unit in this environment.
# Gateway, DNS domain and subnet follow the lab host (192.168.70.71, lab.local); the rest are
# placeholders marked REPLACE.
# Keep env_name equal to the Ansible inventory directory name (ansible/inventories/lab).

locals {
  env_name = "lab"

  # Proxmox API. The token comes from PROXMOX_VE_API_TOKEN, never from this file.
  proxmox_endpoint = "https://pve-lab.example.internal:8006/" # REPLACE
  # true only while the API certificate isn't trusted by the machine running Terraform.
  proxmox_insecure = false

  # Where the VMs go (a VM can override node_name in the unit).
  node_name    = "pve-lab" # REPLACE
  datastore_id = "local-lvm" # REPLACE

  # Network. vlan_id = null for an untagged bridge.
  network_bridge = "vmbr0"
  vlan_id        = null
  ipv4_gateway   = "192.168.70.254"
  dns_servers    = ["192.168.70.101", "192.168.70.102"]
  dns_domain     = "lab.local" # same as env_domain in ansible/inventories/lab/group_vars/all/main.yml

  # Keys authorised for the ansible account on new VMs.
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHTHEANSIBLECONTROLNODEKEY ansible@control-node",
  ]

  # Prepared Rocky 9 template (see terraform/README.md, "Template requirements").
  rocky9_template_vm_id     = 9000 # REPLACE
  rocky9_template_node_name = "pve-lab" # REPLACE
}

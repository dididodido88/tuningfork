# CRGS00: Proxmox, storage, network and SSH settings for every Terragrunt unit in this environment.
# The values are EXAMPLES (documentation addresses, example.internal): replace them.
# Keep env_name equal to the Ansible inventory directory name (ansible/inventories/CRGS00).

locals {
  env_name = "CRGS00"

  # Proxmox API. The token comes from PROXMOX_VE_API_TOKEN, never from this file.
  proxmox_endpoint = "https://pve00.example.internal:8006/"
  # true only while the API certificate isn't trusted by the machine running Terraform.
  proxmox_insecure = false

  # Where the VMs go. A VM can override node_name and datastore_id in its unit, and a single
  # data disk can go to another storage volume (data_disks[*].datastore_id) when this one fills.
  node_name    = "pve00"
  datastore_id = "local-lvm"

  # Network. vlan_id = null for an untagged bridge. A VM can override the bridge, the VLAN and
  # the gateway in its unit.
  network_bridge = "vmbr0"
  vlan_id        = null
  ipv4_gateway   = "192.0.2.1"
  dns_servers    = ["192.0.2.2", "192.0.2.3"]
  dns_domain     = "example.internal" # same as env_domain in ansible/inventories/CRGS00/group_vars/all/main.yml

  # Template every VM is cloned from, found by name (see terraform/README.md, "Template
  # requirements"). Uncomment the VM ID and the node only to skip the lookup.
  rocky9_template_name = "rocky9-chrgs-template-v2"
  # rocky9_template_vm_id     = 9000
  # rocky9_template_node_name = "pve-node"

  # Bootstrap. Terraform logs in to each new VM once as root, with the key seeded in the
  # template, and creates the ansible account. This is the PRIVATE key file on the machine that
  # runs Terraform. Comment the line out to use the SSH agent instead.
  bootstrap_private_key_file = "~/.ssh/rocky9-template-root"

  # Public keys authorised for the ansible account on new VMs (the Ansible control node).
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHTHEANSIBLECONTROLNODEKEY ansible@control-node",
  ]
}

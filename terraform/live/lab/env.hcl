# lab: Proxmox, storage, network and SSH settings for every Terragrunt unit in this environment.
# Values marked REPLACE are placeholders.
# Keep env_name equal to the Ansible inventory directory name (ansible/inventories/lab).

locals {
  env_name = "lab"

  # Proxmox API. The token comes from PROXMOX_VE_API_TOKEN, never from this file.
  proxmox_endpoint = "https://pve-lab.example.internal:8006/" # REPLACE
  # true only while the API certificate isn't trusted by the machine running Terraform.
  proxmox_insecure = false

  # Where the VMs go. A VM can override node_name and datastore_id in its unit, and a single
  # data disk can go to another storage volume (data_disks[*].datastore_id) when this one fills.
  node_name    = "pve-lab" # REPLACE
  datastore_id = "uxt-san-vol1"

  # Network. vlan_id = null for an untagged bridge. A VM can override the bridge, the VLAN and
  # the gateway in its unit.
  network_bridge = "vmbr2"
  vlan_id        = null
  ipv4_gateway   = "192.168.70.254"
  dns_servers    = ["192.168.70.101", "192.168.70.102"]
  dns_domain     = "lab.local" # same as env_domain in ansible/inventories/lab/group_vars/all/main.yml

  # Template every VM is cloned from, found by name (see terraform/README.md, "Template
  # requirements"). Uncomment the VM ID and the node only to skip the lookup.
  rocky9_template_name = "rocky9-chrgs-template-v2"
  # rocky9_template_vm_id     = 9000
  # rocky9_template_node_name = "pve-node"

  # Bootstrap. Terraform logs in to each new VM once as root, with the key seeded in the
  # template, and creates the ansible account. This is the PRIVATE key file on the machine that
  # runs Terraform. Comment the line out to use the SSH agent instead.
  bootstrap_private_key_file = "~/.ssh/rocky9-template-root" # REPLACE

  # Public keys authorised for the ansible account on new VMs (the Ansible control node).
  ssh_public_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEWITHTHEANSIBLECONTROLNODEKEY ansible@control-node",
  ]
}

# tuningfork

Infrastructure code for the **CRGS00**, **CRGS01** and **CRGS02** environments, built for air-gapped
networks. Terraform creates the VMs on Proxmox. Ansible then hardens and configures them.

| Directory | Tool | What it does | Docs |
|---|---|---|---|
| [`terraform/`](terraform/) | Terraform + Terragrunt (bpg/proxmox) | Clones VMs from prepared templates, sets network/SSH keys through cloud-init, writes the Ansible inventory | [terraform/README.md](terraform/README.md) |
| [`ansible/`](ansible/) | Ansible | Repositories, data disks, CIS hardening, common OS config, server roles | [ansible/README.md](ansible/README.md) |

## End to end

```sh
# 1. Provision (writes ansible/inventories/CRGS00/terraform_rocky9.yml)
cd terraform/live/CRGS00/rocky9
terragrunt apply

# 2. Configure: always run Ansible from the ansible/ directory so ansible.cfg is used
cd ../../../../ansible
ansible-playbook -i inventories/CRGS00 playbooks/site.yml --vault-id CRGS00@prompt
```

Each tool runs from its own directory. `.gitattributes` (LF line endings) and `.gitignore` at the
root apply to both.

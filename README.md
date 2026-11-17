# tuningfork

Infrastructure code for the **CRGS00**, **CRGS01** and **CRGS02** environments (plus a **lab** environment), built for air-gapped
networks. Terraform creates the VMs on Proxmox. Ansible then hardens and configures them.

| Directory | Tool | What it does | Docs |
|---|---|---|---|
| [`terraform/`](terraform/) | Terraform + Terragrunt (bpg/proxmox) | Clones the VMs of each role from the Rocky 9 template, sets their hardware, disks and network, creates the Ansible account, writes the Ansible inventory | [terraform/README.md](terraform/README.md) |
| [`ansible/`](ansible/) | Ansible | Repositories, data disks, CIS hardening, common OS config, server roles | [ansible/README.md](ansible/README.md) |

## End to end

```sh
# 1. Provision every unit of the environment (each writes
#    ansible/inventories/CRGS00/terraform_<unit>.yml)
cd terraform/live/CRGS00
terragrunt run --all apply

# 2. Configure: always run Ansible from the ansible/ directory so ansible.cfg is used
cd ../../../ansible
ansible-playbook -i inventories/CRGS00 playbooks/site.yml --vault-id CRGS00@prompt
```

Each tool runs from its own directory. `.gitattributes` (LF line endings) and `.gitignore` at the
root apply to both.

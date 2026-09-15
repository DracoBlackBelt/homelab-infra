# homelab-infra

IaC for my homelab: OpenTofu clones Debian 13 VMs on Proxmox VE (node `prox`)
from a hand-built golden template, and Ansible configures those VMs over SSH.

## Baseline state

This repo is reset to a working baseline: the *plumbing* is proven, but no VMs
or config is managed yet.

- **Working**: connection to Proxmox (endpoint + API token), the sealed golden
  template (vmid 9000), the cloud-init SSH key path, the tofu→Ansible inventory
  bridge, provider pinned to `~> 0.113.1`.
- **Empty**: `var.vms` defaults to `{}` (zero resources); the previous
  Docker/Dockge/Watchtower `setup.yml` playbook lives in git history only
  (`git show bafa092:ansible/setup.yml`).

## Layout

| Path                          | Purpose                                              |
| ----------------------------- | ---------------------------------------------------- |
| `tofu/`                       | OpenTofu config; local state in `tofu/terraform.tfstate` |
| `tofu/vms.tf`                 | VM schema (`var.vms`) + clone resource + inventory output |
| `tofu/terraform.tfvars`       | gitignored: API token **and where you declare VMs**  |
| `docs/golden-template.md`     | spec for building/sealing template vmid 9000         |
| `ansible/inventory/tofu.py`   | dynamic inventory: reads `tofu output -json`         |
| `ansible/ping.yml`            | smoke test for the full chain                        |

## Usage

```sh
tofu -chdir=tofu init          # once
tofu -chdir=tofu plan          # "No changes" on an empty baseline

# 1. add an entry to the `vms` map in tofu/terraform.tfvars
# 2. clone it:
tofu -chdir=tofu apply         # waits for the guest agent to report the VM's IP

# 3. check Ansible can reach it:
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook ping.yml
```

Adding a VM is a one-line change in `terraform.tfvars`; the dynamic inventory
picks it up automatically on the next play.

## Notes

- VM disks must be >= 16 GiB (the template's disk size; Proxmox cannot shrink
  a cloned volume).
- After sealing, template 9000 is never booted again — to change its contents,
  destroy and rebuild it per `docs/golden-template.md`.
- The old provisioning playbook is history, not gospel: rebuild guest config
  as you need it (new plays, roles, or something like Dockge) deliberately.

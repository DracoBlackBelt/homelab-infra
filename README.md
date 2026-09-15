# homelab-infra

IaC for my homelab: OpenTofu clones Debian 13 VMs on Proxmox VE (node `prox`)
from a hand-built golden template, and Ansible configures those VMs over SSH.

## State

The *plumbing* is proven against the live host: connection to Proxmox (endpoint +
API token), the sealed golden template (vmid 9000), the cloud-init SSH key path,
the tofu→Ansible inventory bridge, provider pinned to `~> 0.113.1`. On top of it
sits the guest-config chain: `ansible/site.yml` joins each VM to the tailnet,
installs Docker Engine, converges them into a Docker Swarm (all managers), and
connects a Komodo Periphery agent back to Komodo Core (outbound only — Core never
needs to reach the VMs). Komodo's own objects — the Swarm resource, stacks — are
declared as git-synced TOML in `komodo/`, applied by one bootstrap ResourceSync.

The *instances* are not in git: `var.vms` defaults to `{}` and real VMs are
declared only in the gitignored `tofu/terraform.tfvars`. The old all-in-one
Docker/Dockge/Watchtower `setup.yml` lives in git history only
(`git show bafa092:ansible/setup.yml`); its parts were rebuilt deliberately as
separate plays.

## Layout

| Path                          | Purpose                                              |
| ----------------------------- | ---------------------------------------------------- |
| `tofu/`                       | OpenTofu config; local state in `tofu/terraform.tfstate` |
| `tofu/vms.tf`                 | VM schema (`var.vms`) + clone resource + inventory output |
| `tofu/terraform.tfvars`       | gitignored: API token **and where you declare VMs**  |
| `docs/golden-template.md`     | spec for building/sealing template vmid 9000         |
| `ansible/inventory/tofu.py`   | dynamic inventory: reads `tofu output -json`         |
| `ansible/ping.yml`            | smoke test for the full chain                        |
| `ansible/site.yml`            | provisioning chain: tailscale → docker → swarm → komodo |
| `ansible/{tailscale,docker,swarm,komodo}.yml` | the four links, each also runnable standalone |
| `ansible/group_vars/vms/`     | group vars, incl. vault-encrypted keys               |
| `ansible/templates/`          | periphery config + systemd unit (rendered by komodo.yml) |
| `komodo/*.toml`               | Komodo resources as code, synced by a ResourceSync   |
| `stacks/`                     | swarm compose files referenced by `komodo/stacks.toml` |

## Usage

```sh
tofu -chdir=tofu init          # once
tofu -chdir=tofu plan          # "No changes" when var.vms is empty

# 1. add an entry to the `vms` map in tofu/terraform.tfvars
# 2. clone it:
tofu -chdir=tofu apply         # waits for the guest agent to report the VM's IP

# 3. check Ansible can reach it:
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook ping.yml

# 4. provision it (tailnet -> Docker -> Swarm -> Komodo periphery):
ansible-playbook site.yml --limit <vm-name>
```

Adding a VM is a one-line change in `terraform.tfvars`; the dynamic inventory
picks it up automatically on the next play.

## Notes

- VM disks must be >= 16 GiB (the template's disk size; Proxmox cannot shrink
  a cloned volume).
- After sealing, template 9000 is never booted again — to change its contents,
  destroy and rebuild it per `docs/golden-template.md`.
- Guest config is rebuilt deliberately, as one small play per concern
  (tailscale.yml, docker.yml, swarm.yml, komodo.yml). Extend it the same way — new plays,
  roles, or something like Dockge — rather than resurrecting `setup.yml`.
- App deploys are GitOps: edit `komodo/*.toml` or `stacks/`, push, and the Komodo
  ResourceSync (plus stack `deploy = true`) rolls the swarm. One-time UI setup: a
  read-only GitHub token as git account `DracoBlackBelt`, and one ResourceSync over
  `komodo/`. Secrets go in Komodo variables/secrets, never in the synced TOMLs.

# AGENTS.md

IaC for a homelab: on a Proxmox VE host (node `prox`), OpenTofu creates Debian 13 VMs
cloned from a hand-built golden template, and Ansible configures those VMs over SSH.

The repo is at a deliberately-empty baseline (reset 2026-09-15): the connection plumbing
is proven against the live host, but no VMs or guest config are managed. `var.vms`
defaults to `{}`; VMs are declared only in the gitignored `tofu/terraform.tfvars`.

## Commands

OpenTofu — run from the repo root (paths are `-chdir=tofu`):

```sh
tofu -chdir=tofu init
tofu -chdir=tofu validate
tofu -chdir=tofu plan           # "No changes" while var.vms is empty
tofu -chdir=tofu apply
tofu -chdir=tofu output -json
```

Ansible — must run from `ansible/` (`ansible.cfg` points at `inventory/` relatively):

```sh
cd ansible && ansible-galaxy collection install -r requirements.yml   # one-time
cd ansible && ansible-inventory --graph                               # what tofu exposes
cd ansible && ansible-playbook ping.yml                               # smoke-test the chain
cd ansible && ansible-playbook ping.yml --limit <vm-name>
```

There is no lint or unit-test suite; `ansible/ping.yml` is the closest thing to a test.
`requirements.yml` is the contract for collection deps — don't rely on whatever
Homebrew's ansible package happens to bundle.

**Adding a VM:** one entry in the `vms` map in `tofu/terraform.tfvars` (`vm_id`, `name`,
`address`, optional `cores`/`memory`/`disk_size`), then `tofu -chdir=tofu apply`. Ansible
picks it up automatically on its next run — nothing else to update. `disk_size` must be
>= 16: the template's volume is 16 GiB and a cloned disk cannot shrink (smaller values
fail at apply).

## Architecture

The chain is only visible across files:

- **Golden template (vmid 9000)** is built by hand and deliberately **not** a tofu
  resource: baking software into a disk (booting a guest, running apt) can't be expressed
  in tofu. `docs/golden-template.md` is the authoritative spec, including rebuild and
  sealing steps. `tofu/templates.tf` only *reads* it via a data source so a missing or
  renumbered template fails at plan time; a `lifecycle.precondition` in `vms.tf` fails
  apply if 9000 exists but isn't a template.
- **`tofu/vms.tf`** clones 9000 per entry in `var.vms`. Per-VM IP, hostname and SSH key
  come from the cloud-init `initialization` block (ide2 drive).
  `agent { enabled = true, timeout = "5m" }` makes the provider wait for a real guest IP
  before reporting created — a completed apply is itself proof the agent works.
- **Resource choice (deliberate):** `proxmox_virtual_environment_vm` is kept even though
  the provider shipped `proxmox_cloned_vm` (v0.113+, experimental). Reason:
  `proxmox_cloned_vm` cannot manage `initialization` (cloud-init), BIOS/EFI or the agent —
  all load-bearing here. `proxmox_vm` (the vm2 PoC) is marked "DO NOT USE". Re-evaluate
  when cloned_vm gains cloud-init support.
- **Provider defaults that must stay explicit in `vms.tf`:** the provider would otherwise
  push its own values onto the clone, so `bios = "ovmf"` + `efi_disk`, `cpu = "host"`,
  `scsi0` on `fastpool`, `scsi_hardware = "virtio-scsi-single"` and the cloud-init drive
  are all pinned in state. Changing any of these on 9000 requires a matching change in
  `vms.tf` — the correspondence is the table in `docs/golden-template.md`.
- **Ansible inventory is a single dynamic script**, `ansible/inventory/tofu.py`. It shells
  out to `tofu -chdir=tofu output -json` (state only, no Proxmox API calls, so VM power
  state is irrelevant) and serves the `vm_inventory` output from `vms.tf` as group `vms`
  with `ansible_host` + `ansible_user` hostvars. Addresses come from the config, not the
  agent's report, so they can't go stale between apply and play. Before the first apply
  (i.e. the current baseline) the inventory is empty and plays report "no hosts matched".
- **`ansible/group_vars/vms.yml`** sets `ansible_become: true` — Ansible connects as
  `debian` (sourced once from `local.vm_username` in `tofu/locals.tf` and exported via
  `vm_inventory`) and escalates; escalation is deliberately an Ansible concern, not part
  of the tofu output.

## Verified facts (baseline check, 2026-09-15)

- PVE 9.2.18 at `https://prox.int.huisman.dev`; API token auth works; TLS cert is valid
  (no `insecure` flag needed).
- Template 9000 exists, is sealed, 16 GiB disk.
- Toolchain: OpenTofu v1.12.6, provider `bpg/proxmox` 0.113.1, ansible-core 2.21.4
  (Homebrew ansible 14.4.0), Python 3.14.
- `tofu plan` with empty `var.vms` is clean; dynamic inventory degrades gracefully to an
  empty group.

## Gotchas

- `tofu/terraform.tfvars` (gitignored) holds the real Proxmox API token, endpoint and the
  `vms` map — keep it that way; never commit state files or tfvars.
- After the golden template is sealed it must **never be booted again** (cloud-init would
  re-bake an instance id); it can only be cloned. To change its contents, destroy 9000
  and rebuild per `docs/golden-template.md`.
- `tofu/locals.tf` reads `~/.ssh/id_ed25519.pub` (cloud-init installs it for `debian` at
  first boot). If the workstation key changes, this is the only file that feeds it to
  new VMs.
- Proxmox environment facts: node `prox`, ZFS pool `fastpool`, bridge `vmbr0`,
  gateway `10.0.0.1`, provider `bpg/proxmox`.
- The old all-in-one provisioning playbook `ansible/setup.yml` (Docker, Dockge,
  Watchtower, ufw, unattended-upgrades, sshd hardening, swap) was removed at the
  baseline reset. Recover it with `git show bafa092:ansible/setup.yml` and rebuild
  deliberately, not by reflex.

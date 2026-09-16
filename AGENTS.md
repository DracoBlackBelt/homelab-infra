# AGENTS.md

IaC for a homelab: on a Proxmox VE host (node `prox`), OpenTofu creates Debian 13 VMs
cloned from a hand-built golden template, and Ansible configures those VMs over SSH.

The connection plumbing is proven against the live host, and the guest-config chain
(tailscale -> docker -> swarm -> komodo periphery, `ansible/site.yml`) is defined here,
along with the Komodo resources themselves (`komodo/*.toml`, synced from git by a
ResourceSync). No VM *instances* live in git, though: `var.vms` defaults to `{}`; VMs
are declared only in the gitignored `tofu/terraform.tfvars`.

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
cd ansible && ansible-playbook site.yml                               # tailscale -> docker -> swarm -> komodo, in order
cd ansible && ansible-playbook tailscale.yml                          # install + join tailnet
cd ansible && ansible-playbook docker.yml                             # Docker Engine + compose plugin
cd ansible && ansible-playbook swarm.yml                              # converge the swarm (all managers)
cd ansible && ansible-playbook komodo.yml                             # periphery agent, dials Core
```

Secrets live in vault-encrypted files under `group_vars/` (e.g. `vms/vault.yml`);
`ansible.cfg` reads the password from `../.vault-pass` (gitignored) — create it once per machine.

There is no lint or unit-test suite; `ansible/ping.yml` is the closest thing to a test.
`requirements.yml` is the install contract for collection deps — currently empty:
the plays use only `ansible.builtin` modules and need **ansible-core >= 2.21** for the
`deb822_repository`/`systemd_service` names, so don't rely on whatever Homebrew's
ansible package happens to bundle.

**Adding a VM:** one entry in the `vms` map in `tofu/terraform.tfvars` (`vm_id`, `name`,
`address`, optional `cores`/`memory`/`disk_size`), then `tofu -chdir=tofu apply` followed
by `cd ansible && ansible-playbook site.yml --limit <name>`. The dynamic inventory picks
the VM up automatically — nothing else to update; `site.yml` even joins it to the swarm
as a new manager (add its name to `komodo/swarms.toml` `servers` only for read-path
redundancy in Core). `disk_size` must be >= 16: the
template's volume is 16 GiB and a cloned disk cannot shrink (smaller values fail at apply).

**Adding an app:** `stacks/<app>/docker-compose.yaml` (swarm `deploy:` syntax, pinned
image tags) + one `[[stack]]` block in `komodo/stacks.toml` targeting
`swarm = "homelab"` with `deploy = true`, then push — the ResourceSync diffs and
(re)deploys. One stack per app; secrets never enter synced TOMLs (see the
komodo/*.toml architecture bullet and the README's "Adding an app" section).
Webapps are routed by Traefik, not by publishing ports: join the external `proxy`
overlay + `deploy.labels` with `traefik.enable=true`, a
`Host(\`<app>.swarm.int.huisman.dev\`)` router on entrypoint `websecure` with
`tls.certresolver=le`, and `loadbalancer.server.port` — copy `stacks/whoami/`.

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
- **`ansible/group_vars/vms/`** holds the group's variables: `all.yml` sets
  `ansible_become: true` — Ansible connects as `debian` (sourced once from
  `local.vm_username` in `tofu/locals.tf` and exported via `vm_inventory`) and escalates;
  escalation is deliberately an Ansible concern, not part of the tofu output.
  `vault.yml` (ansible-vault encrypted) holds `tailscale_auth_key` (`tailscale.yml`)
  and `komodo_onboarding_key` (`komodo.yml`); `all.yml` also pins `komodo_core_address`.
- **`ansible/tailscale.yml`** installs the package from Tailscale's official apt repo
  (`deb822_repository`, key fetched from `pkgs.tailscale.com`) and registers each VM with
  one reusable+ephemeral auth key. The CLI does not read `TS_AUTHKEY` (that's
  containerboot-only), so the key goes through a mode-0600 temp file
  (`--auth-key=file://…`, removed in the block's `always`), never argv, `no_log`'d.
  `tailscale up` is gated on `tailscale status` so reruns don't re-present the key;
  Tailscale SSH is enabled (`--ssh`). Auth keys expire after at most 90 days — swap in a
  fresh one with `ansible-vault edit group_vars/vms/vault.yml`; ephemeral nodes GC'd after
  long shutdowns re-register with the same key.
- **`ansible/docker.yml`** installs Docker Engine + compose/buildx plugins from Docker's
  official apt repo (same `deb822_repository` pattern). Periphery acts on this host daemon,
  so it is a prerequisite for Komodo managing containers/stacks on a VM.
- **`ansible/swarm.yml`** converges the Docker Swarm: probes each node's
  `LocalNodeState`, `docker swarm init`s on `swarm_init_manager` (komodo-srv-01) if inactive,
  then joins every other node with the **manager** token (fetched `no_log`) — all nodes are
  managers, so 3 nodes = raft quorum that survives one loss. Advertise/join on the LAN
  addresses (vmbr0), never the tailnet. It never inits over, re-joins, or `swarm leave`s
  an `active` node, and aborts rather than touching a `pending` one. The header carries the
  lost-bootstrap-manager runbook. It also loads+persists the `openvswitch` kernel module
  (swarm's ingress datapath; Debian never loads it and published ports blackhole without
  it) and inits with `--default-addr-pool 10.10.0.0/16`, because swarm's stock ingress
   subnet (10.0.0.0/24) collides with the LAN and silently breaks the routing mesh — a
   tripwire assert re-checks the running cluster. Komodo deliberately does not own
   membership — its Swarm resource only *talks to* managers — which is why this play exists.
   It also ensures the cluster-wide `proxy` overlay (idempotent create) that Traefik and
   all routed apps share: stack-created networks get a `<stack>_` prefix and thus can't
   be shared across stacks, so no stack may own it.
- **`stacks/traefik/`** is the edge router: pinned Traefik v3 with the native **swarm
   provider** (`exposedbydefault=false`), reading routing from `deploy.labels` on swarm
   services — so an app's route is defined in the app's own compose file, and adding one
   never redeploys Traefik. Runs **global** (one task per node; all nodes are managers, so
   the mounted `docker.sock:ro` always serves the cluster API) and publishes 80/443 via
   **ingress**, letting the routing mesh serve the edge from any node IP. DNS is manual,
   outside git: AdGuard Home (10.0.0.70) rewrites `*.swarm.int.huisman.dev` → a node IP
   (npmplus on 10.0.0.6 keeps the rest of the LAN untouched). TLS is live: Cloudflare
   DNS-01 issues one `*.swarm.int.huisman.dev` wildcard via the `le` resolver; the
   API token is the external swarm secret `cloudflare_api_token` (value created in
   the Komodo UI, never in git; lego reads env, so the entrypoint cats the secret
   file into `CF_DNS_API_TOKEN` before `exec /traefik "$@"`). Apps route on
   `websecure`, `web` is redirect-only, and steady-state app stacks publish **no**
   ports — see README "Routing".
- **`komodo/*.toml`** is Komodo-as-code: the Swarm resource (`homelab` = the three VMs) and
  Stack declarations, diffed into Core by ONE bootstrap `ResourceSync` created in the UI
  (repo `homelab-infra`, path `komodo/`). From then on editing these files (+ `stacks/`)
  and pushing is how Komodo resources change; the sync's webhook can run it on push.
  `[[variable]]`/secret material must NOT go in these files — synced TOML is plaintext git.
  Stacks clone this repo via the `DracoBlackBelt` git account (read-only GitHub token,
  registered in the Core UI; the name must match `git_account` in `komodo/stacks.toml`).
- **`ansible/komodo.yml`** installs the Komodo Periphery agent as a root systemd service
  (`komodo.yml` owns binary, unit, and config; template at `templates/periphery.config.toml.j2`).
  **Outbound mode:** the agent dials `komodo_core_address` (a ts.net/MagicDNS name in
  `vms/all.yml`, hence the tailscale-then-komodo order in `site.yml`); Core never needs to
  reach VMs, port 8120 stays closed. Each VM self-onboards into Core as a Server named
  `{{ inventory_hostname }}` (== the tailscale hostname) using one reusable onboarding key
  from `vms/vault.yml` — create it in the Komodo UI (Servers → Onboarding Keys). The key is
  only consumed until the Server exists; steady-state auth is the keypair Periphery
  auto-generates in `/etc/komodo/keys/`. The pinned `komodo_version` and
  `komodo_release_checksums` in the play must change **together** (checksums are from the
  release page; `get_url` fails the check otherwise).

## Verified facts (baseline check, 2026-09-15)

- PVE 9.2.18 at `https://prox.int.huisman.dev`; API token auth works; TLS cert is valid
  (no `insecure` flag needed).
- Template 9000 exists, is sealed, 16 GiB disk.
- Komodo Core runs on the `pbs` tailnet node at `https://pbs.tail9ef5e7.ts.net`
  (tailnet-only, valid ts.net cert); periphery agents dial it in outbound mode.
- Live swarm `homelab`: 3 managers (komodo-srv-01..03) formed by `swarm.yml`; ingress
  overlay migrated to 10.10.0.0/24; `whoami` + `uptime-kuma` are routed by the
  Traefik edge (`*.swarm.int.huisman.dev`; mesh + Host-routing proven 2026-09-16,
  no published app ports since the TLS cutover).
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
- Ansible **silently ignores** `group_vars/vms.yml` once a `group_vars/vms/` directory
  exists (the directory shadows the same-named file). That is why the become setting
  lives in `vms/all.yml`. Keep all `vms` group vars inside the directory.

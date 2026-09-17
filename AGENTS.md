# AGENTS.md

IaC for a homelab: on a Proxmox VE host (node `prox`), OpenTofu creates Debian 13 VMs
cloned from a hand-built golden template, and Ansible configures those VMs over SSH.

The connection plumbing is proven against the live host, and the guest-config chain
(hardening -> tailscale -> docker -> swarm -> komodo periphery, `ansible/site.yml`) is defined here,
along with the Komodo resources themselves (`komodo/*.toml`, synced from git by a
ResourceSync). VMs are declared in `tofu/terraform.tfvars`, which is **committed**
(endpoint and addresses are not secrets, and the repo must be able to rebuild the
VMs); the PVE API token is the only thing that stays out, exported as an env var.

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
cd ansible && ansible-galaxy collection install -r requirements.yml   # required: ansible.utils + community.sops
cd ansible && ansible-inventory --graph                               # what tofu exposes
cd ansible && ansible-playbook ping.yml                               # smoke-test the chain
cd ansible && ansible-playbook ping.yml --limit <vm-name>
cd ansible && ansible-playbook site.yml                               # hardening -> tailscale -> docker -> swarm -> komodo, in order
cd ansible && ansible-playbook hardening.yml                          # apt policy: security upgrades, never auto-reboot
cd ansible && ansible-playbook tailscale.yml                          # install + join tailnet
cd ansible && ansible-playbook docker.yml                             # Docker Engine + compose plugin
cd ansible && ansible-playbook swarm.yml                              # converge the swarm (managers + workers)
cd ansible && ansible-playbook komodo.yml                             # periphery agent, dials Core
cd ansible && ansible-playbook secrets.yml                            # seed swarm secrets from SOPS (before deploying stacks)
cd ansible && ansible-playbook template.yml                           # build the golden template (no-op if it exists)
cd ansible && ansible-playbook template.yml -e template_rebuild=true  # destroy + rebuild it
cd ansible && ansible-lint                                            # lint (brew install ansible-lint)
```

Secrets live in SOPS-encrypted files under `group_vars/` (e.g.
`vms/secrets.sops.yml`), decrypted as they load by the `community.sops` vars plugin
(`vars_plugins_enabled` in `ansible.cfg`). Private keys stay outside the repo, and
`.sops.yaml` lists **two** recipients so losing one decryptor does not lose every
secret: the workstation key (`~/.config/sops/age/keys.txt`) and an escrow key kept
offline (`~/.config/sops/age/recovery-keys.txt`). Edit with
`sops ansible/group_vars/vms/secrets.sops.yml`; after changing recipients, re-wrap
with `sops updatekeys <file>`.

Lint is `ansible-lint` (`ansible/.ansible-lint`, `moderate` profile). There is no unit-test
suite, so `ansible/ping.yml` is still the closest thing to a test.

`make ci` (see `make help`) runs the whole local check set: `tofu fmt -check` + `validate`,
`ansible-lint`, `docker stack config` over every stack, and a stacks/ ↔ `komodo/stacks.toml`
consistency check. The same set runs in GitHub Actions (`.github/workflows/ci.yml`) on
push/PR; none of it contacts the live hosts, so it needs no token or age key.
`requirements.yml` pins two collections: `ansible.utils` (`swarm.yml`'s ingress/LAN overlap
check uses its `in_network` test — CIDR math Jinja cannot express) and `community.sops`
(the vars plugin that decrypts the `*.sops.yml` secrets), so the install step is required,
not a no-op. Every module is otherwise `ansible.builtin`, and the plays need **ansible-core
>= 2.21** for the `deb822_repository`/`systemd_service` names, so don't rely on whatever Homebrew's
ansible package happens to bundle.

**Adding a VM:** one entry in the `vms` map in `tofu/terraform.tfvars` (`vm_id`, `name`,
`address`, optional `cores`/`memory`/`disk_size`/`gateway`), then `tofu -chdir=tofu apply`
followed by `cd ansible && ansible-playbook site.yml --limit <name>`. The dynamic
inventory picks the VM up automatically — nothing else to update; `site.yml` joins it to
the swarm as a **worker**. To make it a raft manager instead, add its name to
`swarm_manager_hosts` (`group_vars/vms/all.yml`); to let Core read through it too, add it
to `komodo/swarms.toml` `servers`. `disk_size` must be >= 16: the template's volume is 16
GiB and a cloned disk cannot shrink (smaller values fail at apply). `address` must be
CIDR (`10.0.0.41/24`), enforced by a variable `validation`. Map key must equal `name`,
enforced by a `lifecycle.precondition`.

**Adding an app:** `stacks/<app>/docker-compose.yaml` (swarm `deploy:` syntax, pinned
image tags) + one `[[stack]]` block in `komodo/stacks.toml` targeting
`swarm = "homelab"` with `deploy = true`, then push — the ResourceSync diffs and
applies on confirmation. It re-deploys when the **TOML** changes, not when a referenced
compose file changes (Komodo #1120 / #1381), so a compose-only edit needs an explicit
Deploy in the UI. Deletes are likewise confirmation-gated, not automatic. One stack per
app; secrets never enter synced TOMLs (see the komodo/*.toml architecture bullet and the
README's "Adding an app" section). An app
needing a secret gets it into `group_vars/vms/secrets.sops.yml`, then
`ansible-playbook secrets.yml` creates the Swarm secret **before** the push — an
`external: true` secret that does not exist fails the deploy.
Webapps are routed by Traefik, not by publishing ports: join the external `proxy`
overlay + `deploy.labels` with `traefik.enable=true`, a
`Host(\`<app>.swarm.huisman.dev\`)` router on entrypoint `websecure` with
`tls.certresolver=le`, and `loadbalancer.server.port` — copy `stacks/whoami/`.
App-with-database (see `stacks/freshrss/`): DB on a stack-local network only,
volume-bearing services pinned to one node, swarm secret created in the Komodo
UI first (`freshrss_db_password`; an `external: true` secret that does not exist
fails the deploy) then consumed via native
`*_FILE` env or a `$$`-escaped sh wrapper (image entrypoints live under
`/var/www/...`, not `/traefik`-style paths — inspect the real image before
overriding; and when you DO override `entrypoint`, re-declare the image's CMD
in `command:` — `docker stack deploy` drops the image CMD, which crashed
freshrss in a silent exit-0 loop).

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
- **Ansible inventory is two sources in `ansible/inventory/`**: the dynamic script
  `tofu.py` for the VMs (below), and a static `prox.yml` adding the Proxmox host
  itself as group `pve` — the one host OpenTofu does not create. `pve` is reached as
  `root@prox.tail9ef5e7.ts.net` over the tailnet (root@10.0.0.2 rejects key auth;
  the host's Tailscale SSH is what authorizes it), and `ansible/group_vars/pve.yml`
  holds its settings (the template build today, the NFS export later).
- **VM inventory is a single dynamic script**, `ansible/inventory/tofu.py`. It shells
  out to `tofu -chdir=tofu output -json` (state only, no Proxmox API calls, so VM power
  state is irrelevant) and serves the `vm_inventory` output from `vms.tf` as group `vms`
  with `ansible_host` + `ansible_user` hostvars. Addresses come from the config, not the
  agent's report, so they can't go stale between apply and play. Before the first apply
  (i.e. the current baseline) the inventory is empty and plays report "no hosts matched".
- **`ansible/group_vars/vms/`** holds the group's variables: `all.yml` sets
  `ansible_become: true` — Ansible connects as `debian` (sourced once from
  `local.vm_username` in `tofu/locals.tf` and exported via `vm_inventory`) and escalates;
  escalation is deliberately an Ansible concern, not part of the tofu output.
  `secrets.sops.yml` (SOPS/age encrypted) holds `tailscale_auth_key` (`tailscale.yml`),
  `komodo_onboarding_key` (`komodo.yml`) and per-app secrets (`searxng_secret`,
  `flame_password`, … seeded into Swarm by `secrets.yml`); `all.yml` also pins
  `komodo_core_address` and the `swarm_manager_hosts` / `swarm_init_manager` roles.
- **`ansible/secrets.yml`** seeds cluster-wide Docker Swarm secrets from the
  SOPS-decrypted group_vars (`tasks/swarm_secret.yml`). It only creates what is
  missing — Swarm secrets are immutable, so rotation stays a manual `docker secret
  rm` + service update. Run it before deploying any stack whose compose references
  an `external: true` secret; a missing secret fails the deploy.
- **`ansible/tailscale.yml`** installs the package from Tailscale's official apt repo
  (`deb822_repository`, key fetched from `pkgs.tailscale.com`) and registers each VM with
  one reusable+ephemeral auth key. The CLI does not read `TS_AUTHKEY` (that's
  containerboot-only), so the key goes through a mode-0600 temp file
  (`--auth-key=file://…`, removed in the block's `always`, with a pre-task that clears any
  stale file from an interrupted run), never argv, `no_log`'d.
  `tailscale up` is gated on `tailscale status` so reruns don't re-present the key;
  Tailscale SSH is enabled (`--ssh`). Auth keys expire after at most 90 days — swap in a
  fresh one with `sops ansible/group_vars/vms/secrets.sops.yml`; ephemeral nodes GC'd after
  long shutdowns re-register with the same key.
- **`ansible/hardening.yml`** pins the guest APT policy: security upgrades stay enabled
  (`20auto-upgrades`) but `Unattended-Upgrade::Automatic-Reboot` is forced `false`
  (`51-…`, which sorts after the image's `50-`). All nodes are raft quorum members, so
  kernel reboots are manual and staggered, never automatic/together. This is the play that
  will own host-firewall rules when they land.
- **`ansible/docker.yml`** installs Docker Engine + compose/buildx plugins from Docker's
  official apt repo (same `deb822_repository` pattern) and pins `/etc/docker/daemon.json`
  for log rotation (`json-file`, `max-size=10m`, `max-file=3`) — unbounded json-file logs
  are what actually fills the small VM disks. Periphery acts on this host daemon, so it is
  a prerequisite for Komodo managing containers/stacks on a VM.
- **`ansible/swarm.yml`** converges the Docker Swarm: probes each node's
  `LocalNodeState`, `docker swarm init`s on `swarm_init_manager` (komodo-srv-01) if inactive,
  then joins every other node with the **manager or worker** token per `swarm_manager_hosts` —
  both fetched (`no_log`) only when a node is actually `inactive`. The 3 managers
  (komodo-srv-01..03) form raft quorum that survives one loss; every other VM is a worker, so
  an app OOM can't disturb raft (and Traefik's `node.role == manager` keeps the edge on the
  managers). Both init and join pass `--advertise-addr`, so nodes advertise on the
  LAN (vmbr0), never the tailnet. It never inits over, re-joins, or `swarm leave`s
  an `active` node, and aborts rather than touching a `pending` one. The header carries the
  lost-bootstrap-manager runbook. It also loads+persists the `openvswitch` kernel module
  (swarm's ingress datapath; Debian never loads it and published ports blackhole without
  it; the consequent dockerd restart is throttled to one node at a time) and inits with
  `--default-addr-pool 10.10.0.0/16`, because swarm's stock ingress subnet (10.0.0.0/24)
  collides with the LAN and silently breaks the routing mesh — a tripwire assert re-checks
  the running cluster with `ansible.utils.in_network` (the only non-builtin dependency).
  The manager assert is scope-aware: it fails only for nodes the run touched, so `--limit`
  keeps working while a newly declared VM is still unprovisioned. Komodo deliberately does
  not own membership — its Swarm resource only *talks to* managers — which is why this play
  exists. It also ensures the cluster-wide `proxy` overlay (inspect, create only if missing)
  that Traefik and all routed apps share: stack-created networks get a `<stack>_` prefix and
  thus can't be shared across stacks, so no stack may own it.
- **`stacks/traefik/`** is the edge router: pinned Traefik v3 with the native **swarm
   provider** (`exposedbydefault=false`), reading routing from `deploy.labels` on swarm
   services — so an app's route is defined in the app's own compose file, and adding one
   never redeploys Traefik. Runs `replicated: 1` constrained to `node.role == manager`
   (the mounted `docker.sock:ro` then always serves the cluster API) — one task, not
   one-per-node, because OSS Traefik has no shared-ACME storage and parallel replicas
   race on the same Cloudflare TXT record. Publishes 80/443 via
   **ingress**, letting the routing mesh serve the edge from any node IP. DNS is manual,
   outside git: AdGuard Home (10.0.0.70) rewrites `*.swarm.huisman.dev` → a node IP
   (npmplus on 10.0.0.6 keeps the rest of the LAN untouched). TLS is live: Cloudflare
   DNS-01 issues one `*.swarm.huisman.dev` wildcard via the `le` resolver; the
   API token is the external swarm secret `cloudflare_api_token` (value created in
   the Komodo UI, never in git; lego reads env, so the entrypoint cats the secret
   file into `CF_DNS_API_TOKEN` before `exec /traefik "$@"`). Apps route on
   `websecure`, `web` is redirect-only, and steady-state app stacks publish **no**
   ports — see README "Routing".
- **`komodo/*.toml`** is Komodo-as-code: the Swarm resource (`homelab` = the three manager VMs) and
  Stack declarations, diffed into Core by ONE bootstrap `ResourceSync` created in the UI
  (repo `homelab-infra`, path `komodo/`). From then on editing these files (+ `stacks/`)
  and pushing is how Komodo resources change; the sync's webhook can run it on push.
  `[[variable]]`/secret material must NOT go in these files — synced TOML is plaintext git.
  The repo is public, so Komodo clones it anonymously: no `git_account` or GitHub token
  anywhere. The sync declares itself in `komodo/resource-sync.toml` — the one bootstrap
  creation in the UI, whose name/repo/branch/path must match that file or a second sync
  appears. `delete` is deliberately not enabled there; see the file for why.
- **`ansible/komodo.yml`** installs the Komodo Periphery agent as a root systemd service
  (`komodo.yml` owns binary, unit, and config; template at `templates/periphery.config.toml.j2`).
  **Outbound mode:** the agent dials `komodo_core_address` (a ts.net/MagicDNS name in
  `vms/all.yml`, hence the tailscale-then-komodo order in `site.yml`); Core never needs to
  reach VMs, port 8120 stays closed. Each VM self-onboards into Core as a Server named
  `{{ inventory_hostname }}` (== the tailscale hostname) using one reusable onboarding key
  from `vms/secrets.sops.yml` — create it in the Komodo UI (Servers → Onboarding Keys). The key is
  only consumed until the Server exists; steady-state auth is the keypair Periphery
  auto-generates in `/etc/komodo/keys/`. The key still stays in the 0600 config on disk
  afterward (unused) — a deliberate tradeoff, not an oversight; removing it is a manual edit,
  and re-onboarding a deleted Server would then need a fresh key. The pinned `komodo_version` and
  `komodo_release_checksums` in the play must change **together** (checksums are from the
  release page; `get_url` fails the check otherwise).

## Verified facts (baseline 2026-09-15; swarm expanded 2026-09-17)

- Proxmox host `prox`: Ryzen 7 5800X (8c/16t), 32 GB RAM, ZFS `fastpool` ~1.4 TB free,
  PBS datastore only ~190 GB free (expand before relying on it). CPU is near-idle; RAM
  is the sizing constraint.
- PVE 9.2.18 at `https://prox.int.huisman.dev`; API token auth works; TLS cert is valid
  (no `insecure` flag needed).
- Template 9000 exists, is sealed, 16 GiB disk.
- Komodo Core runs on the `pbs` tailnet node at `https://pbs.tail9ef5e7.ts.net`
  (tailnet-only, valid ts.net cert); periphery agents dial it in outbound mode.
- Live swarm `homelab`: 3 managers (komodo-srv-01..03) + 3 workers (swarm-wrk-01..03) formed
  by `swarm.yml`; ingress
  overlay migrated to 10.10.0.0/24; ten stacks are deployed and all webapps are routed
  by the Traefik edge (`*.swarm.huisman.dev`; mesh + Host-routing proven 2026-09-16,
  no published app ports since the TLS cutover) — see README "Deployed apps" for the
  current hostnames, nodes and state.
- Toolchain: OpenTofu v1.12.6, provider `bpg/proxmox` 0.113.1, ansible-core 2.21.4
  (Homebrew ansible 14.4.0), Python 3.14.
- `tofu plan` with empty `var.vms` is clean; dynamic inventory degrades gracefully to an
  empty group.

## Gotchas

- `tofu/terraform.tfvars` **is committed**: it holds the Proxmox endpoint and the `vms`
  map, so a fresh clone can rebuild every VM. Only state files and `*.auto.tfvars`
  stay ignored. The PVE API token is **not** here: export `TF_VAR_pve_api_token` in the
  shell (or source from a gitignored env file) before running tofu. A `validation`
  block fails plan with a clear message if the variable is empty.
- After the golden template is sealed it must **never be booted again** (cloud-init would
  re-bake an instance id); it can only be cloned. To change its contents, rebuild it with
  `cd ansible && ansible-playbook template.yml -e template_rebuild=true` — the play that
  reproduces `docs/golden-template.md`.
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

# AGENTS.md

IaC for a homelab: on a Proxmox VE host (node `prox`), OpenTofu clones Debian 13 VMs
from a hand-built golden template, and Ansible configures them over SSH. The guest
chain (`ansible/site.yml`) is hardening -> tailscale -> docker -> swarm -> Komodo
periphery; Komodo's own objects (Swarm resource, stacks) are git-synced TOML under
`komodo/`. VMs are declared in `tofu/terraform.tfvars`, which is **committed**; only the
PVE API token stays out (env var).

`README.md` is the human-facing doc and owns the deep runbook detail (routing, placement
pools, secret handling, rolling updates, deployed apps): read the relevant section there
before changing a stack. This file is the short operational brief.

## Commands

OpenTofu, from the repo root:

```sh
tofu -chdir=tofu init
tofu -chdir=tofu validate
tofu -chdir=tofu plan      # "No changes" while var.vms is empty
tofu -chdir=tofu apply
tofu -chdir=tofu output -json
```

Ansible, from `ansible/` (`ansible.cfg` points at `inventory/` relatively):

```sh
ansible-galaxy collection install -r requirements.yml   # required: ansible.utils + community.sops
ansible-inventory --graph                               # what tofu exposes
ansible-playbook ping.yml                               # smoke-test the chain
ansible-playbook site.yml [--limit <name>]              # hardening -> tailscale -> docker -> swarm -> komodo
ansible-playbook hardening.yml|tailscale.yml|docker.yml|swarm.yml|komodo.yml
ansible-playbook secrets.yml                            # seed swarm secrets from SOPS (before stack deploys)
ansible-playbook template.yml                           # build the golden template (no-op if present)
ansible-playbook template.yml -e template_rebuild=true  # destroy + rebuild it
ansible-lint
```

`make ci` is the local mirror of CI (`.github/workflows/ci.yml`): `tofu fmt -check` +
`validate`, `ansible-lint`, `docker stack config` over every stack, and the
stacks/ <-> `komodo/stacks.toml` consistency check. Nothing in it contacts a live host,
so it needs no token and no age key. `make help` lists every target.

Every module is `ansible.builtin` except `ansible.utils.in_network` (`swarm.yml`'s
ingress/LAN overlap check -- CIDR math Jinja cannot express). The plays need
**ansible-core >= 2.21** for the `deb822_repository`/`systemd_service` names, so do not
rely on whatever Homebrew's ansible package happens to bundle.

Secrets are SOPS/age-encrypted in `group_vars/` (e.g. `vms/secrets.sops.yml`), decrypted
as they load by the `community.sops` vars plugin. `.sops.yaml` lists **two** recipients
(workstation key + offline escrow) so losing one decryptor does not lose every secret.
Edit with `sops ansible/group_vars/vms/secrets.sops.yml`; after changing recipients,
re-wrap with `sops updatekeys <file>`.

## Workflows

**Adding a VM** -- one entry in the `vms` map in `tofu/terraform.tfvars` (`vm_id`, `name`,
`address`, optional `cores`/`memory`/`disk_size`/`gateway`), then `tofu -chdir=tofu apply`
and `cd ansible && ansible-playbook site.yml --limit <name>`. The dynamic inventory picks
it up automatically; it joins the swarm as a **worker**. Make it a raft manager by adding
it to `swarm_manager_hosts` (`group_vars/vms/all.yml`), and to `komodo/swarms.toml`
`servers` to let Core read through it. Invariants: `address` is CIDR (validated),
`disk_size >= 16` (template disk; clones cannot shrink, so a smaller value fails at
apply), and the map key must equal `name` (lifecycle precondition).

**Adding an app** -- `stacks/<app>/docker-compose.yaml` (swarm `deploy:` syntax, pinned
image tags) + one `[[stack]]` block in `komodo/stacks.toml` (`swarm = "homelab"`,
`deploy = true`), then push. Webapps route through Traefik, never published ports -- copy
`stacks/whoami/` (see README "Adding an app" / "Routing"). Public exposure is separate: a
swarm label alone does not publish anything -- add the host to the allowlist in
`stacks/traefik-edge/dynamic.yml` (public DNS is a wildcard, so no record is needed).
Secrets: add the value to
`vms/secrets.sops.yml` and the name to `secrets.yml`, then run
`ansible-playbook secrets.yml` **before** the push (an `external: true` secret that does
not exist fails the deploy), or create it in the Komodo UI. The sync re-deploys when the
**TOML** changes, not when a referenced compose file changes (Komodo #1120 / #1381), so a
compose-only edit needs an explicit Deploy in the UI; deletes are confirmation-gated. The
stack conventions (pool pins, update/rollback anchors, the `failure_action` ban, the
secret-wrapper traps) are in README -- copy an existing stack rather than inventing.

## Layout

| Path | Purpose |
| --- | --- |
| `tofu/` | OpenTofu config, local state in `tofu/terraform.tfstate` |
| `tofu/vms.tf` | VM schema (`var.vms`) + clone resource + `vm_inventory` output |
| `tofu/terraform.tfvars` | committed: endpoint + **where you declare VMs** (token is env) |
| `docs/golden-template.md` | authoritative spec for building/sealing template 9000 |
| `ansible/template.yml` | reproduces that spec |
| `ansible/inventory/` | dynamic `tofu.py` (VMs) + static `prox.yml` (the `pve` host) |
| `ansible/{hardening,tailscale,docker,swarm,komodo}.yml` | the five links, each standalone |
| `ansible/secrets.yml` | seeds Swarm secrets from SOPS |
| `ansible/group_vars/vms/` | group vars, incl. SOPS-encrypted secrets |
| `komodo/*.toml` | Komodo resources as code, synced by one ResourceSync |
| `stacks/` | swarm compose files referenced by `komodo/stacks.toml` |
| `Makefile`, `.github/workflows/ci.yml` | static checks (see Commands) |

## Architecture

- **Golden template (vmid 9000)** is hand-built and deliberately not a tofu resource:
  baking software into a disk cannot be expressed in tofu, and keeping it out of state
  means tofu never guesses what is on the disk. `tofu/templates.tf` only reads it, so a
  missing or renumbered vmid fails at plan time; `vms.tf` clones it per `var.vms`.
  `docs/golden-template.md` is the spec and the "why".
- **Provider defaults pinned in `vms.tf`** (`bios = ovmf` + `efi_disk`, `cpu = host`,
  `scsi0` on `fastpool`, `virtio-scsi-single`, the cloud-init drive) must keep matching
  template 9000 -- the correspondence is the table in `docs/golden-template.md`.
- **Inventory is two sources**: dynamic `tofu.py` for the VMs (reads
  `tofu output -json`, state only, so VM power state is irrelevant and addresses come
  from config not the agent's report) and static `prox.yml` for the Proxmox host itself
  (`pve`, reached over the tailnet). Group vars set `ansible_become`; the user is
  `debian`, sourced from `tofu/locals.tf`.
- **`swarm.yml` owns membership** (Komodo's Swarm resource only *talks to* managers, it
  never joins nodes): inits on `swarm_init_manager` if inactive, joins every other node
  with the manager or worker token per `swarm_manager_hosts`, never touches an active or
  `pending` node. Handles two ingress traps (openvswitch; stock `10.0.0.0/24` ingress
  colliding with the LAN, avoided via `--default-addr-pool 10.10.0.0/16`), defaults
  advertise to the LAN, ensures the shared `proxy` overlay, and labels workers with
  placement **pools**. See README "Swarm" and "Placement".
- **`stacks/traefik/` is the edge**: v3 swarm provider reading `deploy.labels`, one task
  on a manager, 80/443 via ingress, one wildcard cert via Cloudflare DNS-01. See README
  "Routing".
- **`komodo/*.toml` is Komodo-as-code**, diffed in by ONE bootstrap `ResourceSync`
  created in the UI. That sync is the one object not declared here (Komodo refuses to
  update a running ResourceSync), and nothing secret goes in these files -- synced TOML is
  plaintext in a public repo. `komodo.yml` installs Periphery in outbound mode: it dials
  Core over the tailnet (a MagicDNS name, hence tailscale before komodo) and
  self-onboards with one reusable key.

## Gotchas

- `tofu/terraform.tfvars` **is committed**. The PVE token is exported as
  `TF_VAR_pve_api_token`; a `validation` fails plan if it is empty.
- After sealing, template 9000 must **never be booted again** (cloud-init would re-bake
  an instance id). To change it, `ansible-playbook template.yml -e template_rebuild=true`.
- `tofu/locals.tf` reads `~/.ssh/id_ed25519.pub` -- the only place the workstation key
  enters cloud-init. Rotate the key there.
- Ansible **silently ignores** `group_vars/vms.yml` once `group_vars/vms/` exists; keep
  all `vms` group vars inside the directory.
- **Never add `failure_action: rollback`** to a compose service: Komodo 2.3.3's bundled
  bollard cannot deserialize it, which empties its swarm service list and marks every
  stack `Down` while the apps keep running. See README "Rolling updates".
- Placement-pool labels must exist before a compose referencing them is deployed, or the
  service is unschedulable -- run `swarm.yml` first (and after adding a worker). Same for
  the `edge` label: the Traefik stack constrains on `node.labels.edge == true`, and the
  VPS public edge targets that node's tailnet IP `:8443` (host-mode, not the mesh -- the
  1450-byte overlay over the 1280-byte tailnet drops packets). See README "Public access".
- `whoami` is a `scratch` image: no shell, no client, no healthcheck -- Uptime Kuma probes
  it externally.
- The old all-in-one `ansible/setup.yml` is gone (`git show bafa092:ansible/setup.yml`);
  extend the chain as small plays, not by resurrecting it.
- `stacks/traefik-edge` is a **server** stack (`server = "PBS"`), not swarm: it is a plain
  `docker compose` on the VPS, and the swarm-only `docker stack config` CI step parses it
  but ignores keys like `restart`. Its public allowlist is `dynamic.yml`; its
  `CF_DNS_API_TOKEN` must exist as a Komodo secret variable or the deploy fails.
- The VPS's other stacks are server stacks too (`server = "PBS"`): `pocket-id`, `tinyauth`,
  `seaweedfs`, `zerobyte` (Komodo Core manages itself). Their secrets are Komodo
  **variables** interpolated as `[[NAME]]`, and the `environment` key must equal the compose
  `${NAME}` -- `FOO = [[BAR]]` exports `FOO`, so a compose reading `${BAR}` starts with an
  empty secret. Their data is host bind mounts under `/opt`; pocket-id's `ENCRYPTION_KEY`
  and the seaweedfs S3 keys must be preserved, not rotated casually.
- `zerobyte` needs `cap_add: SYS_ADMIN`, `devices: /dev/fuse` and
  `security_opt: apparmor:unconfined` to mount WebDAV/NFS/SMB/SFTP sources: on Debian the
  docker-default AppArmor profile denies the mount syscall even with `SYS_ADMIN`, and the
  failure reads as `can't open fuse device` / `mounting failed: Permission denied`.
- `docker-srv-01` is a Komodo **server that is not in `terraform.tfvars`**, and `baikal`
  plus `yuvomi` (`planner.huisman.dev`) are UI-managed stacks on it. Declare the host or
  migrate the apps -- it is the last undeclared infrastructure.
- The VPS (netcup) filters **outbound UDP** by default -- 53 and 123 both time out while
  `tcp/53` works and Tailscale's `100.100.100.100` resolves. That silently breaks ACME
  DNS-01: lego's authoritative-NS propagation check never completes, no certificate is
  issued, and the edge serves its self-signed fallback (clients see
  `ssl_verify_result=18`, i.e. "unreachable"). Fix it in the netcup SCP firewall in
  **both** directions -- outbound UDP *and* inbound from source ports 53/123 -- because it
  is stateless; otherwise renewals break again in ~60 days. A working `tcp/53` is not a
  diagnosis.
- In `komodo.yml`, `komodo_version` and `komodo_release_checksums` must change **together**
  or `get_url` fails the checksum.

## Facts (baseline 2026-09-15; swarm expanded 2026-09-17)

- `prox`: Ryzen 7 5800X (8c/16t), 32 GB RAM, ZFS `fastpool` ~1.4 TB free; PBS datastore
  only ~190 GB free (expand before relying on it). RAM is the sizing constraint.
- PVE 9.2.18 at `https://prox.int.huisman.dev`; API token auth, valid TLS (no `insecure`).
- Live swarm `homelab`: 3 managers (komodo-srv-01..03) + 3 workers (swarm-wrk-01..03), all
  on Docker 29.8.1; 10 stacks deployed and every webapp routed by the Traefik edge
  (`*.swarm.huisman.dev`). Core runs at `https://pbs.tail9ef5e7.ts.net` (tailnet-only).
- Toolchain: OpenTofu 1.12.6, provider `bpg/proxmox` 0.113.1, ansible-core 2.21.4
  (Homebrew ansible 14.4.0), Python 3.14.
- `tofu plan` with empty `var.vms` is clean; an empty inventory degrades to
  "no hosts matched".

## References

- `README.md` -- human docs: Routing, Placement, Secrets, Rolling updates, Swarm,
  Deployed apps, Agent access.
- `docs/golden-template.md` -- the template build/seal spec.

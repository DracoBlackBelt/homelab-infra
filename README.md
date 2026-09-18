# homelab-infra

IaC for my homelab: OpenTofu clones Debian 13 VMs on Proxmox VE (node `prox`)
from a hand-built golden template, and Ansible configures those VMs over SSH.

## State

The *plumbing* is proven against the live host: connection to Proxmox (endpoint +
API token), the sealed golden template (vmid 9000), the cloud-init SSH key path,
the tofu→Ansible inventory bridge, provider pinned to `~> 0.113.1`. On top of it
sits the guest-config chain: `ansible/site.yml` hardens each VM's APT policy, joins
it to the tailnet, installs Docker Engine, converges them into a Docker Swarm (3 raft
managers + workers), and connects a Komodo Periphery agent back to Komodo Core (outbound
only — Core never needs to reach the VMs). Komodo's own objects — the Swarm resource, stacks — are
declared as git-synced TOML in `komodo/`, applied by one bootstrap ResourceSync.
A `traefik` edge stack (deployed through the same loop) routes apps by hostname
under `*.swarm.huisman.dev`.

The *instances* are not in git: `var.vms` defaults to `{}` and real VMs are
declared in `tofu/terraform.tfvars`, which is committed (endpoint and IPs are
not secrets — the repo has to be able to rebuild the VMs). The old all-in-one
Docker/Dockge/Watchtower `setup.yml` lives in git history only
(`git show bafa092:ansible/setup.yml`); its parts were rebuilt deliberately as
separate plays.

## Layout

| Path                          | Purpose                                              |
| ----------------------------- | ---------------------------------------------------- |
| `tofu/`                       | OpenTofu config; local state in `tofu/terraform.tfstate` |
| `tofu/vms.tf`                 | VM schema (`var.vms`) + clone resource + inventory output |
| `tofu/terraform.tfvars`       | committed: endpoint + **where you declare VMs** (token is env) |
| `docs/golden-template.md`     | spec for building/sealing template vmid 9000         |
| `ansible/template.yml`        | builds that template (the doc explains why)          |
| `ansible/inventory/tofu.py`   | dynamic inventory: reads `tofu output -json`         |
| `ansible/inventory/prox.yml`  | static inventory: the Proxmox host itself (group `pve`) |
| `ansible/ping.yml`            | smoke test for the full chain                        |
| `ansible/site.yml`            | provisioning chain: hardening → tailscale → docker → swarm → komodo |
| `ansible/{hardening,tailscale,docker,swarm,komodo}.yml` | the five links, each also runnable standalone |
| `ansible/group_vars/vms/`     | group vars, incl. SOPS-encrypted secrets             |
| `ansible/secrets.yml`         | seeds Swarm secrets from SOPS (run before stack deploys) |
| `ansible/templates/`          | periphery config + systemd unit (rendered by komodo.yml) |
| `komodo/*.toml`               | Komodo resources as code, synced by a ResourceSync   |
| `stacks/`                     | swarm compose files referenced by `komodo/stacks.toml` |
| `Makefile`                    | local mirror of CI + the day-to-day commands (`make help`) |
| `.github/workflows/ci.yml`    | static checks on push/PR: tofu, ansible-lint, stack config |

## Usage

```sh
# the PVE API token is env-only, never in tfvars: see AGENTS.md
export TF_VAR_pve_api_token='terraform@pve!<tokenid>=<uuid>'

tofu -chdir=tofu init          # once
tofu -chdir=tofu plan          # "No changes" when var.vms is empty

# 1. add an entry to the `vms` map in tofu/terraform.tfvars
# 2. clone it:
tofu -chdir=tofu apply         # waits for the guest agent to report the VM's IP

# 3. check Ansible can reach it:
cd ansible
ansible-galaxy collection install -r requirements.yml   # pins ansible.utils + community.sops
ansible-playbook ping.yml

# 4. provision it (hardening -> tailnet -> Docker -> Swarm -> Komodo periphery):
ansible-playbook site.yml --limit <vm-name>
```

Adding a VM is a one-line change in `terraform.tfvars`; the dynamic inventory
picks it up automatically on the next play. New VMs join the swarm as **workers**
when `site.yml` reaches them; add the name to `swarm_manager_hosts`
(`group_vars/vms/all.yml`) to make it a raft manager instead.

## Adding an app (deploy to the swarm)

Everything is driven by git: edit, push, sync, deploy.

1. **Write the compose file** at `stacks/<app>/docker-compose.yaml`. This is a
   swarm stack (`docker stack deploy` semantics), so use `deploy:` for
   replicas, placement constraints and update config — and pin image tags
   (no `latest`), so re-syncs are deterministic. Give it a placement **pool**
   (see "Placement: pools"), and a `update_config`/`rollback_config` anchor
   (see "Rolling updates"). A webapp gets routed by
   Traefik instead of publishing a port: join the external `proxy` overlay and
   put the routing in `deploy.labels` (see `stacks/whoami` for the canonical
    pattern — `traefik.enable=true`, a `Host(\`<app>.swarm.huisman.dev\`)`
    router on entrypoint `websecure` with `tls.certresolver=le`, and
    `loadbalancer.server.port`).
2. **Declare the stack** — one `[[stack]]` block in `komodo/stacks.toml`:

   ```toml
   [[stack]]
   name = "immich"        # becomes the swarm stack name
   deploy = true          # the sync also (re)deploys on change
   [stack.config]
   swarm = "homelab"
   git_provider = "github.com"
   repo = "DracoBlackBelt/homelab-infra"   # public, so no git_account
   branch = "main"
   file_paths = ["stacks/immich/docker-compose.yaml"]  # several files merge like docker compose -f -f
   ```

3. **Secrets** (only if the app needs one) — add the value to
   `ansible/group_vars/vms/secrets.sops.yml` (`sops ansible/group_vars/vms/secrets.sops.yml`),
   add the name to `swarm_secrets` in `ansible/secrets.yml`, then
   `cd ansible && ansible-playbook secrets.yml` to create the Swarm secret. A compose
   `external: true` secret that does not exist fails the deploy.
4. **Push.** The ResourceSync over `komodo/` computes the diff; confirm its
   actions in the UI — or wire the sync's webhook to the repo for zero-click
   deploys. **Caveat:** `deploy = true` re-deploys when the *TOML* changes,
   not when a referenced compose file changes (Komodo #1120 / #1381), so a
   compose-only edit needs an explicit **Deploy** in the UI — the sync alone
   will not roll it. Removing a stack from `stacks.toml` likewise shows up as
   a delete action to confirm; it is not automatic.
5. **Verify:** the stack shows its services/tasks in the Komodo UI; on any VM,
   `docker service ls`. Apps are hostname-only (no published ports) — before
   DNS exists, `curl -s --resolve
   whoami.swarm.huisman.dev:443:10.0.0.41
   https://whoami.swarm.huisman.dev/` against any node IP.

### Routing: the Traefik edge

- **One shared overlay (`proxy`)**: Traefik and every routed app attach to it;
  Traefik reaches services by DNS name (`whoami`, `uptime-kuma`) with no
  published ports. Swarm prefixes stack-created network names, so `proxy`
  can't be owned by any stack — `swarm.yml` ensures it exists (rerun after
  `swarm leave` disasters).
- **Config lives with the app**: the v3 *swarm provider* reads routing from
  `deploy.labels` on services, so adding an app's route is a commit to that
  app's compose file — no Traefik redeploy. `exposedbydefault=false`: nothing
  routes unless labeled.
- **Edge shape**: `stacks/traefik` runs **`replicated: 1`** on a manager and
  publishes 80/443 via ingress — the routing mesh still accepts :80/:443 on
  every node and forwards to that one task, so any node IP is a valid entry.
   One task, not one-per-node, because only one process may drive the ACME
   (DNS-01) resolver: OSS Traefik has no shared-ACME storage (the v1 KV store
   was dropped in 2.0), so parallel replicas race on the same Cloudflare TXT
   record — the maintainers closed the flat-file requests as unsupported by
   design. Its `update_config` is therefore stop-first, never start-first.
   `web` (:80) is redirect-only.
- **DNS (manual, outside git)**: AdGuard Home (10.0.0.70) → Filters → DNS
  rewrites: `*.swarm.huisman.dev` → **three A records, one per manager LAN IP**
  (10.0.0.41–43), TTL 60s. The mesh accepts :80/:443 on every node and forwards
  to the single edge task, so multiple node IPs are pure redundancy: if one
  manager is down, clients still reach the edge through another. A single
  record also works, but silently makes that node a single point of failure for
  every app — this is the real edge-HA lever, not Traefik replicas. DNS has no
  health checking, hence the short TTL: a dead node is a client timeout until
  the record rolls over.
- **TLS**: one Let's Encrypt wildcard for `*.swarm.huisman.dev`, issued by
  Traefik via DNS-01 at Cloudflare (zone `huisman.dev` — validation is public
  even though AdGuard resolves the names locally). The API token (`Edit zone
  DNS` template, scoped to that zone) lives in the **swarm secret**
  `cloudflare_api_token`, created in the Komodo UI (Swarm `homelab` → Secrets)
  and referenced from compose as `external: true` — the value never enters git.
  lego (Traefik's ACME client) reads any provider variable suffixed `_FILE` from
  a file, so compose just sets
  `CF_DNS_API_TOKEN_FILE=/run/secrets/cloudflare_api_token` — no shell wrapper,
  and none of the wrapper traps. The single edge task keeps `acme.json` in the
  node-local `traefik-acme` volume — one wildcard cert, not one per node.
  Routers: `websecure` + `tls.certresolver=le`.

### Placement: pools, not hostnames

Swarm named volumes are **node-local**, so any service with a volume must be
pinned. The pin names a *pool* (`node.labels.pool == 01`) rather than a
hostname: `swarm.yml` labels each worker from `swarm_node_labels` in
`group_vars/vms/all.yml`, so replacing a VM means relabelling the new node once,
not editing nine compose files.

**Do not quote the value** (`node.labels.pool == "01"` is wrong). A YAML plain
scalar keeps the inner quotes, so Docker is handed the literal value `"01"` and
rejects the whole deploy with `value '"01"' is invalid` — which is how the first
rollout of this took the pool-pinned stacks down while the `node.role` ones
succeeded.

Being honest about what that buys: a pool is a **renaming abstraction, not
HA**. A node-local volume still cannot move — if the node dies, the service and
its data stay unavailable until the node returns or the volume is restored.
What actually frees placement is moving state off the node (a later NFS/bind
step); until then, pools just make the unavoidable pin cheap to maintain.

Current split: pool `01` = uptime-kuma, flame; pool `02` = forgejo, dawarich;
pool `03` = freshrss, vaultwarden. Deliberately unpinned, but constrained to
`node.role == worker` so they stay off the raft managers: `searxng`
(disposable cache) and `web-check` (stateless). `whoami` is unpinned entirely —
spreading across nodes is the point of a mesh canary. Traefik keeps
`node.role == manager`.

### Secrets into containers

Two patterns, and only two:

1. **Native `_FILE` (preferred).** The image reads a path from a `*_FILE`
   variable — Postgres `POSTGRES_PASSWORD_FILE`, lego's
   `CF_DNS_API_TOKEN_FILE`. Mount the swarm secret and point the variable at
   `/run/secrets/<name>`.
2. **`sh` wrapper.** When the image reads the secret only from the environment
   (Rails `SECRET_KEY_BASE`, FreshRSS `DB_PASSWORD`, Flame `PASSWORD`, SearXNG
   `SEARXNG_SECRET`, Vaultwarden `ADMIN_TOKEN`), override `entrypoint` with an
   `sh -c` that exports it from `/run/secrets` and `exec`s the image's own
   entrypoint. Three traps — all three have bitten this repo:
   - **re-declare the CMD** in `command:` — `docker stack deploy` drops the
     image's CMD when `entrypoint` is overridden (FreshRSS exited 0 silently;
     Flame's `chown` never ran);
   - **`exec`** the final process, or SIGTERM never reaches it and stops hang
     until the grace period expires;
   - **double every `$`** (`$$`) so compose expands at deploy time, not at
     container start.

Secrets are only ever **swarm secrets** (`external: true`), seeded by
`ansible/secrets.yml` from SOPS or created in the Komodo UI — never inline in a
compose file, never in a synced TOML, because both are plaintext in a public
repo.

### Rolling updates

Every service declares `update_config`/`rollback_config` via a per-file `x-`
anchor: `parallelism: 1`, `delay: 5s`, `monitor: 30s`, and
**`failure_action: rollback`** (Swarm's default is `pause`, which strands a
half-updated service). `order` is `stop-first` for anything stateful — two
tasks must never share a node-local volume, and two Rails tasks must never race
migrations — and `start-first` for the stateless three (`whoami`, `web-check`,
`searxng`) for zero-downtime. Traefik is stop-first deliberately: start-first
would briefly run two tasks against one `acme.json`, the ACME race OSS Traefik
cannot resolve. Postgres and Sidekiq get a longer `stop_grace_period` (30s) so
they shut down cleanly.

Rules of thumb: one directory and one `[[stack]]` per app (independent
deploys, clean blast radius); non-sensitive config via `[[variable]]` blocks —
synced TOML is plaintext in git; secrets only as Komodo-managed Swarm secrets
referenced from compose — create each one first (Komodo UI → Swarm `homelab` →
Secrets), e.g. `cloudflare_api_token` for the edge and `freshrss_db_password`
for the DB-backed stack, since an `external: true` secret that does not exist
fails the deploy; bind mounts to VM paths like `/data/...` are fine.
Apps with a database (see `stacks/freshrss`): the DB joins only a stack-local
network (never `proxy`, no router, no published port — structurally private);
name it after its service (e.g. `db`) for DNS; pin both the DB and its volume
consumer to one **pool**; prefer native `*_FILE` secret mounts, or the
sh-wrapper env export (compose `$$` escaping!) when an app only reads env; if
the wrapper overrides `entrypoint`, re-declare the image CMD in `command:` —
stack deploy drops it; set `deploy.resources.limits` — the nodes are small.

One-time setup that makes this loop exist: the repo is **public**, so Komodo
clones it anonymously — no GitHub token or git account in Core — and a single
`ResourceSync` points at this repo's `komodo/` directory:

```text
name "homelab-infra" · repo DracoBlackBelt/homelab-infra · branch main · path komodo/
```

That sync is the **one object deliberately not declared in `komodo/`** — and it
cannot be. Komodo refuses to update a `ResourceSync` while that sync is running
(`failed to update config on ResourceSync 'homelab-infra' | ResourceSync busy`),
so a self-declaration can never apply and it fails the rest of the run. It stays
a one-time creation in the UI.

Two settings in that sync are deliberate: `delete` stays **off** because it is
scoped to the resource *types* the sync knows about, and Komodo auto-creates a
Server per Periphery agent — enabling it blind can delete the platform out from
under the sync. Deletions therefore stay confirmation-gated (see "Adding an
app"). `git_account` stays empty now that the repo is public.

## Deployed apps

What is live right now, and where. Services with a node-local volume are pinned
to a **pool** (see "Placement: pools"), so the pin is not cosmetic — moving one
means moving its data too. All nodes run Docker 29.8.1.

| App | URL (`*.swarm.huisman.dev`) | Placement | State |
| --- | --- | --- | --- |
| whoami | `whoami` | any (3 replicas) | none |
| uptime-kuma | `kuma` | pool 01 | sqlite volume |
| searxng | `search` | any worker | cache (disposable) |
| flame | `home` | pool 01 | sqlite volume |
| web-check | `webcheck` | any worker | none |
| forgejo | `git` | pool 02 | sqlite volume |
| dawarich | `timeline` | pool 02 | postgis + volumes |
| freshrss | `rss` | pool 03 | postgres + volumes |
| vaultwarden | `vault` | pool 03 | sqlite volume |

Pools map to workers by naming (`pool 01` = `swarm-wrk-01`, …); Traefik itself
is the edge, on a manager. See `komodo/stacks.toml` for the authoritative list.

## Notes

- The PVE API token comes from `TF_VAR_pve_api_token` in the environment, never
  from `terraform.tfvars`; a variable `validation` fails `tofu plan` if it is unset.
- Secrets are SOPS/age-encrypted in `ansible/group_vars/vms/secrets.sops.yml` with
  **two** age recipients (`.sops.yaml`): the workstation key
  (`~/.config/sops/age/keys.txt`) and an escrow key kept offline
  (`~/.config/sops/age/recovery-keys.txt`) — losing every decryptor would lose every
  secret. Edit with `sops ansible/group_vars/vms/secrets.sops.yml`; after changing
  recipients, re-wrap the existing files with `sops updatekeys <file>`.
- VM disks must be >= 16 GiB (the template's disk size; Proxmox cannot shrink
  a cloned volume).
- After sealing, template 9000 is never booted again — to change its contents,
  rebuild it: `cd ansible && ansible-playbook template.yml -e template_rebuild=true`.
  The play reproduces `docs/golden-template.md`, which remains the explanation of
  why each step is what it is.
- Guest config is rebuilt deliberately, as one small play per concern
  (tailscale.yml, docker.yml, swarm.yml, komodo.yml). Extend it the same way — new plays,
  roles, or something like Dockge — rather than resurrecting `setup.yml`.
- App deploys are GitOps — see "Adding an app" above; Komodo resources change
  only by editing `komodo/*.toml` / `stacks/` and pushing.
- **Image updates are manual and deliberate**: tags are pinned in every compose
  (never `latest`) for deterministic re-syncs, and there is no auto-updater.
  Bump a tag by hand, roughly monthly or on a security advisory, then push and
  Deploy. `update_config`/`rollback_config` (see "Rolling updates") make the
  resulting restart predictable and self-reverting.

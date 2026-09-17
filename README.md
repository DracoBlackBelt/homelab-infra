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
   (no `latest`), so re-syncs are deterministic. A webapp gets routed by
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
  record. `web` (:80) is redirect-only.
- **DNS (manual, outside git)**: AdGuard Home (10.0.0.70) → Filters → DNS
  rewrites: `*.swarm.huisman.dev` → a swarm node LAN IP. One record is
  enough (ingress accepts on every node and forwards to the edge task); all
  six node IPs just spread the lookups.
- **TLS**: one Let's Encrypt wildcard for `*.swarm.huisman.dev`, issued by
  Traefik via DNS-01 at Cloudflare (zone `huisman.dev` — validation is public
  even though AdGuard resolves the names locally). The API token (`Edit zone
  DNS` template, scoped to that zone) lives in the **swarm secret**
  `cloudflare_api_token`, created in the Komodo UI (Swarm `homelab` → Secrets)
  and referenced from compose as `external: true` — the value never enters
  git; rotate it there too (Komodo does the rm/recreate + service-update
  dance). lego reads the token from env while swarm secrets mount as files,
  so the service entrypoint wraps `/traefik "$@"` to export
  `CF_DNS_API_TOKEN` from `/run/secrets/…`. The single edge task keeps
  `acme.json` in the node-local `traefik-acme` volume — one wildcard cert, not
  one per node. Routers: `websecure` + `tls.certresolver=le`.

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
consumer to one node; prefer native `*_PASSWORD_FILE` secret mounts, or the
sh-wrapper env export (compose `$$` escaping!) when an app only reads env; if
the wrapper overrides `entrypoint`, re-declare the image CMD in `command:` —
stack deploy drops it; set `deploy.resources.limits` — the nodes are small.

One-time setup that makes this loop exist: the repo is **public**, so Komodo
clones it anonymously — there is no GitHub token or git account in Core — and a
single `ResourceSync` points at this repo's `komodo/` directory. That sync is
declared as code in `komodo/resource-sync.toml`, so a fresh Core needs it
created by hand exactly once (same name, repo, branch and path), after which it
maintains itself; see that file for the bootstrap and for why `delete = true`
is deliberately left off.

## Deployed apps

What is live right now, and where. Stateful services are pinned to one node
because their data is a node-local volume, so the pin is not cosmetic — moving
one means moving its data too.

| App | URL (`*.swarm.huisman.dev`) | Node | State |
| --- | --- | --- | --- |
| whoami | `whoami` | any (3 replicas) | none |
| uptime-kuma | `kuma` | swarm-wrk-01 | sqlite volume |
| searxng | `search` | swarm-wrk-01 | cache volume |
| flame | `home` | swarm-wrk-01 | sqlite volume |
| web-check | `webcheck` | swarm-wrk-02 | none |
| forgejo | `git` | swarm-wrk-02 | sqlite volume |
| dawarich | `timeline` | swarm-wrk-02 | postgis + volumes |
| freshrss | `rss` | swarm-wrk-03 | postgres + volumes |
| vaultwarden | `vault` | swarm-wrk-03 | sqlite volume |

`traefik` itself is the edge, on a manager; see `komodo/stacks.toml` for the
authoritative list.

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

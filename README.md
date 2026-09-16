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
A `traefik` edge stack (deployed through the same loop) routes apps by hostname
under `*.swarm.huisman.dev`.

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
picks it up automatically on the next play. New VMs also join the swarm as
managers when `site.yml` reaches them.

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
   git_account = "DracoBlackBelt"
   repo = "DracoBlackBelt/homelab-infra"
   branch = "main"
   file_paths = ["stacks/immich/docker-compose.yaml"]  # several files merge like docker compose -f -f
   ```

3. **Push.** The ResourceSync over `komodo/` computes the diff; confirm its
   actions in the UI — or wire the sync's webhook to the repo for zero-click
   deploys. Updates to an existing app are the same loop: edit, push, sync.
4. **Verify:** the stack shows its services/tasks in the Komodo UI; on any VM,
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
- **Edge shape**: `stacks/traefik` runs **global** (one task per node) and
  publishes 80/443 via ingress — the routing mesh makes any node IP a valid
  target and survives a node loss. `web` (:80) is redirect-only.
- **DNS (manual, outside git)**: AdGuard Home (10.0.0.70) → Filters → DNS
  rewrites: `*.swarm.huisman.dev` → a swarm node LAN IP. One record is
  enough (the mesh forwards), but all three IPs give DNS-level spreading.
- **TLS**: one Let's Encrypt wildcard for `*.swarm.huisman.dev`, issued by
  Traefik via DNS-01 at Cloudflare (zone `huisman.dev` — validation is public
  even though AdGuard resolves the names locally). The API token (`Edit zone
  DNS` template, scoped to that zone) lives in the **swarm secret**
  `cloudflare_api_token`, created in the Komodo UI (Swarm `homelab` → Secrets)
  and referenced from compose as `external: true` — the value never enters
  git; rotate it there too (Komodo does the rm/recreate + service-update
  dance). lego reads the token from env while swarm secrets mount as files,
  so the service entrypoint wraps `/traefik "$@"` to export
  `CF_DNS_API_TOKEN` from `/run/secrets/…`. Each replica keeps its own
  `acme.json` in the node-local `traefik-acme` volume — three issuances per
  renewal cycle, far under LE's limits. Routers: `websecure` +
  `tls.certresolver=le`.

Rules of thumb: one directory and one `[[stack]]` per app (independent
deploys, clean blast radius); non-sensitive config via `[[variable]]` blocks —
synced TOML is plaintext in git; secrets only as Komodo-managed Swarm secrets
referenced from compose; bind mounts to VM paths like `/data/...` are fine.

One-time setup that makes this loop exist (already done): a read-only GitHub
token registered in Komodo as git account `DracoBlackBelt`, and the single
`ResourceSync` pointing at this repo's `komodo/` directory.

## Notes

- VM disks must be >= 16 GiB (the template's disk size; Proxmox cannot shrink
  a cloned volume).
- After sealing, template 9000 is never booted again — to change its contents,
  destroy and rebuild it per `docs/golden-template.md`.
- Guest config is rebuilt deliberately, as one small play per concern
  (tailscale.yml, docker.yml, swarm.yml, komodo.yml). Extend it the same way — new plays,
  roles, or something like Dockge — rather than resurrecting `setup.yml`.
- App deploys are GitOps — see "Adding an app" above; Komodo resources change
  only by editing `komodo/*.toml` / `stacks/` and pushing.

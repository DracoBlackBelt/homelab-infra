# homelab-infra

IaC for my homelab: OpenTofu clones Debian 13 VMs on Proxmox VE (node `prox`) from a
hand-built golden template, and Ansible configures them over SSH -- hardening, tailnet,
Docker Engine, a Docker Swarm, and the Komodo Periphery agent. Komodo's own objects
(Swarm resource, stacks) are git-synced TOML in `komodo/`; apps are Compose stacks in
`stacks/`, routed by a Traefik edge under `*.swarm.huisman.dev`.

Everything is proven against the live host. The operational brief for coding agents is
`AGENTS.md`; this file is the human-facing doc and owns the deep detail.

## Layout

| Path | Purpose |
| --- | --- |
| `tofu/` | OpenTofu config (local state in `tofu/terraform.tfstate`) |
| `tofu/vms.tf` | VM schema (`var.vms`) + clone resource + `vm_inventory` output |
| `tofu/terraform.tfvars` | committed: endpoint + **where you declare VMs** (token is env) |
| `docs/golden-template.md` | authoritative spec for building/sealing template 9000 |
| `ansible/template.yml` | reproduces that spec |
| `ansible/inventory/` | dynamic `tofu.py` (VMs) + static `prox.yml` (the `pve` host) |
| `ansible/ping.yml` | smoke test for the whole chain |
| `ansible/site.yml` | chain: hardening -> tailscale -> docker -> swarm -> komodo |
| `ansible/{hardening,tailscale,docker,swarm,komodo}.yml` | the five links, each runnable standalone |
| `ansible/secrets.yml` | seeds Swarm secrets from SOPS (run before stack deploys) |
| `komodo/*.toml` | Komodo resources as code, synced by one ResourceSync |
| `stacks/` | swarm compose files referenced by `komodo/stacks.toml` |
| `Makefile`, `.github/workflows/ci.yml` | static checks (`make help`) |

## Usage

```sh
# the PVE API token is env-only, never in tfvars
export TF_VAR_pve_api_token='terraform@pve!<tokenid>=<uuid>'

tofu -chdir=tofu init      # once
tofu -chdir=tofu plan      # "No changes" while var.vms is empty

# 1. add an entry to the `vms` map in tofu/terraform.tfvars
# 2. clone it (apply waits for the guest agent to report the VM's IP):
tofu -chdir=tofu apply

# 3. check Ansible can reach it:
cd ansible
ansible-galaxy collection install -r requirements.yml   # ansible.utils + community.sops
ansible-playbook ping.yml

# 4. provision it (hardening -> tailnet -> Docker -> Swarm -> Komodo periphery):
ansible-playbook site.yml --limit <vm-name>
```

Adding a VM is one line in `terraform.tfvars`; the dynamic inventory picks it up on the
next play, and `site.yml` joins it to the swarm as a **worker**. Add the name to
`swarm_manager_hosts` (`group_vars/vms/all.yml`) to make it a raft manager instead.
`address` must be CIDR, `disk_size` must be `>= 16` (the template volume; clones cannot
shrink, so a smaller value fails at apply), and the map key must equal `name` -- all
enforced by validations.

## Adding an app (deploy to the swarm)

Everything is driven by git: edit, push, sync, deploy.

1. **Write the compose file** at `stacks/<app>/docker-compose.yaml`. This is a swarm
   stack (`docker stack deploy` semantics), so use `deploy:` for replicas, placement and
   update config, and pin image tags (no `latest`) for deterministic re-syncs. Give it a
   placement **pool** (see "Placement") and an `update_config`/`rollback_config` anchor
   (see "Rolling updates"). A webapp is routed by Traefik instead of publishing a port:
   join the external `proxy` overlay and put the routing in `deploy.labels` (copy
   `stacks/whoami/` -- `traefik.enable=true`, a `Host(\`<app>.swarm.huisman.dev\`)`
   router on `websecure` with `tls.certresolver=le`, and `loadbalancer.server.port`).
2. **Declare the stack** -- one `[[stack]]` block in `komodo/stacks.toml`:

   ```toml
   [[stack]]
   name = "immich"        # becomes the swarm stack name
   deploy = true          # the sync also (re)deploys on change
   [stack.config]
   swarm = "homelab"
   file_paths = ["stacks/immich/docker-compose.yaml"]  # multiple files merge like -f -f
   ```

3. **Secrets** (only if needed) -- add the value to
   `ansible/group_vars/vms/secrets.sops.yml`, add the name to `swarm_secrets` in
   `ansible/secrets.yml`, then `cd ansible && ansible-playbook secrets.yml`. An
   `external: true` secret that does not exist fails the deploy.
4. **Push.** The ResourceSync over `komodo/` computes the diff; confirm its actions in
   the UI (or wire the sync's webhook to the repo). **Caveat:** `deploy = true`
   re-deploys when the *TOML* changes, not when a referenced compose file changes
   (Komodo #1120 / #1381), so a compose-only edit needs an explicit **Deploy** in the
   UI. Removing a stack is likewise a confirmation-gated action.
5. **Verify:** the stack shows its services/tasks in the Komodo UI; on any VM,
   `docker service ls`. Apps are hostname-only, so before DNS exists use
   `curl --resolve whoami.swarm.huisman.dev:443:<node-ip> https://whoami.swarm.huisman.dev/`.

### Routing: the Traefik edge

- **One shared overlay (`proxy`)**: Traefik and every routed app attach to it; Traefik
  reaches services by DNS name (`whoami`, `uptime-kuma`) with no published ports. Swarm
  prefixes stack-created network names, so `proxy` can't be owned by any stack --
  `swarm.yml` ensures it exists (rerun after a `swarm leave` disaster).
- **Config lives with the app**: the v3 *swarm provider* reads routing from
  `deploy.labels`, so adding an app's route is a commit to that app's compose file -- no
  Traefik redeploy. `exposedbydefault=false`: nothing routes unless labeled.
- **Edge shape**: `stacks/traefik` runs **`replicated: 1`** on a manager and publishes
  80/443 via ingress, so any node IP is a valid entry. One task, not one-per-node,
  because only one process may drive the ACME (DNS-01) resolver: OSS Traefik has no
  shared-ACME storage (the v1 KV store was dropped in 2.0), so parallel replicas race on
  the same Cloudflare TXT record. Its `update_config` is therefore stop-first. `web`
  (:80) is redirect-only.
- **DNS (manual, outside git)**: AdGuard Home (10.0.0.70) -> Filters -> DNS rewrites:
  `*.swarm.huisman.dev` -> **three A records, one per manager LAN IP** (10.0.0.41-43),
  TTL 60s. The mesh accepts :80/:443 on every node and forwards to the single edge task,
  so multiple node IPs are pure redundancy -- the real edge-HA lever. DNS has no health
  checking, hence the short TTL.
- **TLS**: one Let's Encrypt wildcard for `*.swarm.huisman.dev`, issued via DNS-01 at
  Cloudflare (zone `huisman.dev`). The API token (scoped `Edit zone DNS`) lives in the
  **swarm secret** `cloudflare_api_token`, created in the Komodo UI and referenced as
  `external: true` -- never in git. lego reads any provider variable suffixed `_FILE`, so
  compose sets `CF_DNS_API_TOKEN_FILE=/run/secrets/cloudflare_api_token` (no wrapper, and
  none of the wrapper traps). The single task keeps `acme.json` in the node-local
  `traefik-acme` volume -- one wildcard cert, not one per node.

### Public access (the VPS edge)

The swarm itself never faces the internet. `stacks/traefik` reserves a **host-mode** `8443`
on the single node labelled `edge` (`swarm_edge_host`): that is the handoff the VPS edge
reverse-proxies to over the tailnet, preserving the original `Host`. `websecure` trusts the
VPS's `X-Forwarded-For`, so apps log the real client IP. Host-mode is not incidental --
the VPS arrives over the 1280-byte tailnet while the `ingress`/`proxy` overlays ride a
1450-byte VXLAN, so public traffic routed through the mesh silently drops the larger
replies. Only named hosts are ever exposed; the AdGuard rewrites stay internal, so on-LAN
clients never involve the VPS. The trusted IP is a tailnet address and must be updated if
`pbs` re-registers.

The edge itself is `stacks/traefik-edge`, a **Compose stack on `pbs`** (declared with
`server = "PBS"`, not a swarm stack). It runs with the **file provider only** -- no docker
socket -- so its entire routing table is the committed `dynamic.yml`: an explicit allowlist
of `whoami`, `kuma`, `git`, `rss`, `timeline`, `home` on `*.swarm.huisman.dev`, plus `id.`
and `auth.` for the auth plane (which stay on the VPS, unproxied) and `zerobyte.` for the
VPS backup UI. Labelling a new app in
the swarm therefore does **not** expose it: publishing a host means adding it to the
allowlist, and redeploying this stack. Public DNS is the Cloudflare wildcard
(`*.huisman.dev` and `*.swarm.huisman.dev` both point at the VPS, DNS-only), so no per-host
record is needed. TLS is Cloudflare DNS-01, and the token is a Komodo **secret variable**
(`CF_DNS_API_TOKEN`) interpolated into the stack environment -- never in git.

TLS is also the one place the VPS host itself matters: netcup filters **outbound UDP** by
default (53 and 123 both time out; `tcp/53` and Tailscale's `100.100.100.100` work), which
makes lego's DNS-01 authoritative-NS check fail silently -- no certificate is issued and
the edge serves its self-signed fallback, so clients report the host as unreachable. The
netcup SCP firewall must allow outbound UDP and the matching inbound replies from source
ports 53/123; it is stateless, so a one-way rule is not enough.

Let's Encrypt caps issuance at **5 certificates per exact identifier set per 168 h**, so
never force a re-issue just to test a token: Traefik reuses the cached `acme.json` and
renews on its own. Tripping the cap leaves that name on the self-signed fallback until the
window passes -- recover by restoring the cached `acme.json` (a copy of `/data/acme.json`),
not by retrying.

### Placement: pools, not hostnames

Swarm named volumes are **node-local**, so any service with a volume must be pinned. The
pin names a *pool* (`node.labels.pool == 01`) rather than a hostname: `swarm.yml` labels
each worker from `swarm_node_labels` in `group_vars/vms/all.yml`, so replacing a VM means
relabelling the new node once, not editing every compose file.

**Do not quote the value** (`node.labels.pool == "01"` is wrong). A YAML plain scalar
keeps the inner quotes, so Docker is handed the literal value `"01"` and rejects the whole
deploy with `value '"01"' is invalid`.

A pool is a **renaming abstraction, not HA**: a node-local volume still cannot move -- if
the node dies, the service and its data stay unavailable until it returns or the volume is
restored. What actually frees placement is moving state off the node (a later NFS/bind
step); until then, pools just make the unavoidable pin cheap to maintain.

Current split: pool `01` = uptime-kuma, flame; pool `02` = forgejo, dawarich; pool `03` =
freshrss, vaultwarden. Deliberately unpinned but constrained to `node.role == worker` (so
they stay off the raft managers): `searxng` (disposable cache) and `web-check`
(stateless). `whoami` is unpinned entirely -- spreading across nodes is the point of a mesh
canary. Traefik keeps `node.role == manager` plus the `edge` label (`swarm_edge_host`),
which pins the host-mode handoff port for the VPS edge to one node.

### Secrets into containers

Two patterns, and only two:

1. **Native `_FILE` (preferred).** The image reads a path from a `*_FILE` variable --
   Postgres `POSTGRES_PASSWORD_FILE`, lego `CF_DNS_API_TOKEN_FILE`. Mount the swarm secret
   and point the variable at `/run/secrets/<name>`.
2. **`sh` wrapper.** When the image reads the secret only from the environment (Rails
   `SECRET_KEY_BASE`, FreshRSS `DB_PASSWORD`, Flame `PASSWORD`, SearXNG `SEARXNG_SECRET`,
   Vaultwarden `ADMIN_TOKEN`), override `entrypoint` with an `sh -c` that exports it from
   `/run/secrets` and `exec`s the image's own entrypoint. Three traps -- all have bitten:
   - **re-declare the CMD** in `command:` -- `docker stack deploy` drops the image's CMD
     when `entrypoint` is overridden (FreshRSS exited 0 silently; Flame's `chown` never
     ran);
   - **`exec`** the final process, or SIGTERM never reaches it and stops hang until the
     grace period expires;
   - **double every `$`** (`$$`) so compose expands at deploy time, not container start.

Secrets are never inline in a compose file and never in a synced TOML -- both are plaintext
in a public repo. Swarm services get them only as **swarm secrets** (`external: true`),
seeded by `ansible/secrets.yml` from SOPS or created in the Komodo UI. The VPS server
stacks use the equivalent Komodo mechanism instead: the value is a **variable** (Settings
-> Variables, marked secret) and the stack's `environment` references it as `[[NAME]]`.
The key must match the `${NAME}` the compose interpolates -- `FOO = [[BAR]]` exports `FOO`,
so a compose reading `${BAR}` silently gets an empty secret.

### Rolling updates

Every service declares `update_config`/`rollback_config` via a per-file `x-` anchor:
`parallelism: 1`, `delay: 5s`, `monitor: 30s`. `order` is `stop-first` for anything
stateful -- two tasks must never share a node-local volume, and two Rails tasks must never
race migrations -- and `start-first` for the stateless three (`whoami`, `web-check`,
`searxng`) for zero-downtime. Traefik is stop-first deliberately: start-first would
briefly run two tasks against one `acme.json`. Postgres and Sidekiq get a longer
`stop_grace_period` (30s) so they shut down cleanly.

**Never set `failure_action: rollback`.** It looks like the obvious improvement over
Swarm's default (`pause`, which can strand a half-updated service), but Komodo 2.3.3 ships
bollard 0.21.1, whose `FailureAction` enum has no `rollback` variant. One service carrying
that value makes bollard fail to deserialize the **entire** `/services` response, which
Komodo swallows -- its swarm service list comes back empty and **every swarm stack shows
`Down` with no services**, while the apps keep running and deploys keep succeeding (they
use the CLI, not bollard). The tell: `ListSwarmNodes`/`ListSwarmStacks`/`ListSwarmTasks`
return data but `ListSwarmServices` returns `[]`. Revisit when Komodo bumps bollard.

### Swarm

`ansible/swarm.yml` converges membership; Komodo's Swarm resource only *talks to* managers,
it never joins nodes. Two Debian+Swarm ingress traps are handled there: `openvswitch` is
never loaded by Debian (published ports blackhole without it), and Swarm's stock ingress
subnet `10.0.0.0/24` collides with the LAN and silently blackholes routing-mesh replies --
the cluster inits with `--default-addr-pool 10.10.0.0/16` (an existing cluster was
migrated by hand). Every node advertises on the LAN, so 2377/7946/4789 stay on-LAN. The
play also owns the shared `proxy` overlay and the worker placement-pool labels.

## Deployed apps

Services with a node-local volume are pinned to a **pool** (see "Placement"), so the pin
is not cosmetic -- moving one means moving its data too. All nodes run Docker 29.8.1.

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

Traefik itself is the edge, on a manager. `komodo/stacks.toml` is the authoritative list.

The VPS (`pbs`) runs its own **server stacks**, declared in the same file with
`server = "PBS"`: `traefik-edge`, `pocket-id` + `tinyauth` (the auth plane), and the backup
pair `seaweedfs` + `zerobyte` (restic automation writing to the S3 store). They bind host
paths under `/opt` -- data that must survive redeploys -- and take their secrets from Komodo
variables. Komodo Core manages itself and is the one stack not declared here.

## Agent access

The Komodo MCP server used by AI agents connects as a dedicated **read-only** Komodo user
`mcp-agent` (declared in `komodo/users.toml`), so even a buggy or hostile client cannot
deploy, destroy, edit config or open a shell. The API key must not enter git: it lives on
the workstation at `~/.config/komodo/mcp-agent.env` (mode 0600) and is created in the
Komodo UI under Settings -> API Keys. Run the server with `npx -y komodo-mcp-server@1.5.0`
(the same project as the published GHCR image), letting it read that env file; it reaches
Core over the tailnet.

## Notes

- The PVE API token comes from `TF_VAR_pve_api_token` in the environment, never from
  `terraform.tfvars`; a `validation` fails `tofu plan` if it is unset.
- Secrets are SOPS/age-encrypted with **two** age recipients (`.sops.yaml`): the
  workstation key (`~/.config/sops/age/keys.txt`) and an escrow key kept offline
  (`~/.config/sops/age/recovery-keys.txt`) -- losing every decryptor would lose every
  secret. Edit with `sops ansible/group_vars/vms/secrets.sops.yml`; after changing
  recipients, re-wrap with `sops updatekeys <file>`.
- After sealing, template 9000 is never booted again -- to change its contents, rebuild
  it: `ansible-playbook template.yml -e template_rebuild=true`. The play reproduces
  `docs/golden-template.md`, which remains the explanation of why each step is what it is.
- Guest config is rebuilt deliberately, as one small play per concern. Extend it the same
  way -- new plays, roles, or something like Dockge -- rather than resurrecting the old
  all-in-one `setup.yml` (`git show bafa092:ansible/setup.yml`).
- App deploys are GitOps: Komodo resources change only by editing `komodo/*.toml` /
  `stacks/` and pushing.
- **Image updates are manual and deliberate**: tags are pinned in every compose (never
  `latest`) and there is no auto-updater. Bump a tag by hand, roughly monthly or on a
  security advisory, then push and Deploy. The `update_config`/`rollback_config` anchors
  make the resulting restart predictable.

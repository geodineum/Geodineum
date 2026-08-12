# Service Onboarding — registrations, grants, and the permission model

> The ONE definitive document for bringing a new service into a Geodineum
> constellation. An agent (human or LLM) should be able to onboard a service
> end-to-end from this file alone. Machine-primer twin:
> `SERVICE_ONBOARDING.scn.md`. Deep references: `access-grants.scn.md`
> (ValKey ACL), `permission-model.md` (disk/group — a DIFFERENT layer),
> `service-provisioning.md`, `keyspace-model.md`, `receipt-stream.md`.

## 0. The one rule

**Do not raw-`XADD` from an unregistered process.** Registration is what gives
you delivery guarantees (consumer groups + orphan reclaim), a least-privilege
ValKey identity, observability (receipts, heartbeat tile), and a place in the
capability topology. A raw writer has none of that and shows up in nobody's
audit. The paved road below is five commands.

## 1. Concepts (60 seconds)

- A **service** is any process that participates in the mesh — it does not
  have to be a website. The taxonomy: **public** types `website-wp` |
  `website-static` | `app-pwa` (serve visitors over HTTP), **internal** types
  `daemon` | `gcore-service` | `custom` (infrastructure). Light nodes
  (ValKey + gNode only) are first-class.
- Each type carries a **requirement matrix** — the interview asks what the
  service IS; the matrix decides what runs (vhost/certbot, docroot, systemd
  unit + own user, cred model, mail, heartbeat); every type ends on the SAME
  paved road. `geodineum service new --matrix` prints it; the single source
  is `lib/service-taxonomy.sh`.
- Every service gets its own **ValKey identity**: ACL user
  `gnode_client_<service>`, credential at
  `/etc/geodineum/credentials/<service>.password` (root:<component-group> 0640).
- **Three separate permission layers** — never conflate them:
  1. **Disk** — Unix users/groups (see `permission-model.md`).
  2. **ValKey ACL** — which keys/streams this identity may touch (this doc §4).
  3. **Relay policy** — which services may message which, per command,
     enforced by the daemon on every relayed message.
- **Cross-service access is never a self-declared grant.** Your manifest can
  only grant your OWN namespace + well-known shared trees. To reach another
  service: message it via the relay (§5), or request a grant through the
  approval loop (§6).

## 2. Declare — the manifest (ONE schema)

Create `.geodineum/gnode_services.yaml` (or pass `--yaml <dir>`). Every
generator in the estate (`service new`, `new site`, `register`, the
scaffolder templates) emits this same shape:

```yaml
profile: service                  # web | headless | service | system | component
                                  # THIS drives the 30-dim capability vector.
environment: production           # DTAP tier — REQUIRED (flag|manifest|abort)

services:
  - id: "myservice"
    metadata:                     # daemon discovery reads this
      description: "What this service does"
      type: "daemon"
      tier: "SERVICE"

# REQUIRED — least-privilege ACL composition. Own-namespace + well-known
# patterns ONLY; anything foreign is REFUSED and the onboarding aborts
# (never silently narrowed or broadened).
consumes: []
produces:
  - "{myservice}:gnode:comms:*"   # {site_id}/{service}/{ecosystem} interpolate
```

The ACL is composed from the declarations (plus a safe base: own namespace +
the shared gnode bus). **A manifest that declares nothing is refused** — the
old fallback (a broad legacy-uniform grant set) is retired: it silently
handed `{testing..production}:gnode:*`, `gnode:*`, `topology:*`,
`template:*`, `membership:*` to services that asked for nothing, and looked
correct on every own-namespace check. Regenerate an undeclared manifest with
`sudo geodineum register <service> --force`, then `--regrant`.

> **`services[].capabilities` is gone.** It was read by nothing —
> `manifest-policy.sh` consumes only `consumes`/`produces`, and the daemon's
> periodic discovery does not probe `.geodineum/` at all. Generators no
> longer emit it; per-dimension capability data lives in
> `.geodineum/config.yaml`. The 30-dim vector comes from the top-level
> **`profile:`** key above (or `--profile`, which overrides it).
>
> **Declare `profile:` — do not rely on the default.** It falls back to `web`,
> which describes a client-facing HTTP service. An internal daemon registered
> that way is matched by discovery for work it cannot do. No caller in this
> estate passes `--profile`, so the manifest is the only place that reliably
> gets this right; onboarding now logs which source it came from and warns when
> it fell back.

> **Two files share this name and are not the same document.**
> `.geodineum/gnode_services.yaml` is the ONBOARDING manifest (ACL policy;
> `consumes`/`produces`; read by `yq` via `manifest-policy.sh`).
> **`gnode_discovery.yaml`** at a discovery path's ROOT is the DISCOVERY
> manifest, parsed by the daemon with a different schema — `services[].id` plus
> `capabilities: [{name, value}]`. Putting the onboarding shape at a discovery
> root registers nothing; putting the discovery shape in `.geodineum/` composes
> no grants — and both fail silently.
>
> The discovery manifest was also called `gnode_services.yaml`, which is what
> made the two indistinguishable. The daemon still accepts the old name so
> nothing breaks on upgrade; new deployments should use `gnode_discovery.yaml`. The allow-list is the **8 well-known
namespace classes** (own namespace, per-site gnode/gcore bus, ecosystem bus,
shared defaults, env-tagged streams, shared topology, legacy aliases —
`access-grants.scn.md ::PATTERNS`).

## 3. Onboard + register — five commands

**Preferred entry: `sudo geodineum service new`** — the taxonomy interview
(or `--type <type> --env <tier> --yes` non-interactive) runs the type's
matrix rows and ends on exactly the steps below, including the mail
dispatch-verification probe. Delegated provisioning for a worker node:
`--node <name>` mints identity + credential on the master and prints the
`add-service-credential.sh` one-liner for the worker. The manual road:

```bash
# 1. Mint identity + streams + discovery (CONSTELLATION MASTER — the ACL
#    admin credential exists only there):
sudo geodineum provision-service myservice   # wraps onboard-service.sh --yaml ...

# 2. Register the topology entity (NODE-LOCAL — run where the service lives):
sudo geodineum register service myservice service
#    profiles: web | headless | service | system | component
#    Review the 30-dim vector — meaningful capabilities beat profile defaults.

# 3. Wire the heartbeat (in your service, every ~60s):
#    SETEX {geodineum}:gnode:heartbeat:production:myservice:$(hostname -s) 120 '{"ts":<unix>,"node":"<short-hostname>"}'   # node segment: CONTRACTS/heartbeat.md — add yourself to its census
#    → your tile on the wp-admin dashboard goes green; missing/stale = red.

# 4. Prove the round-trip (any registered site stream):
#    XADD your own stream, poll the reply key, find your receipt (§5).

# 5. Check what you can touch:
sudo geodineum grants show myservice
```

## 4. What your identity can do

Composed grants from the declared manifest — the legacy uniform set for
undeclared services is retired (undeclared ⇒ refused, fail-loud). ACL
patterns are **additive-only** — revocation is a full recompose, not a
subtraction. Commands allowed: streams (`x*`), `fcall`, basic
KV/hash/set/list/zset, `scan`, `publish` — no admin surface
(`FUNCTION FLUSH`/`RESTORE` are explicitly denied at the daemon tier).

The credential's disk model follows the type: web types →
`root:geodineum-web:640` (www-data reads via the group); internal →
`root:geodineum:640` (www-data must NOT read); daemon → `root:<svc>:640`
(own single-member group).

## 5. Talk to the mesh

- **Send a command**: `XADD {yoursite}:gnode:unified:{env} * id <uuid> t c
  c <command> ss <yoursite> sn <node> ts <unix> p '{"_request_id":"<uuid>", ...}'`
- **Await the reply**: poll `{yoursite}:res:<uuid>` (SET EX 10 — poll fast).
- **Durable outcome**: a signed receipt lands on
  `{yoursite}:gnode:receipts:{env}` (ed25519 per-node signature; verify via
  the pubkey registry `{geodineum}:gnode:receipt_pubkeys`). Observers use
  their own consumer groups here — this is the audit/observability channel.
- **Another service**: add `_rt` (relay target) to your command — the daemon
  routes it to the target's stream and applies relay policy (per
  source:target pair, per command). You never write into a foreign keyspace.

## 6. Need more access? The grant-request loop

```bash
geodineum grants request myservice "{geodine}:receipts:*" --reason "..." [--ttl-hours 72]
```

- The request is **data** on `{geodineum}:gnode:grants:requests`; the admin is
  emailed via COMMS with the approve/deny one-liners.
- An operator decides on the master: `sudo geodineum grants approve <id>` /
  `deny <id>`; undecided requests **auto-deny** after the TTL (default 72 h).
- Every decision is appended to the `{geodineum}:gnode:grants:ledger`
  **before** any ACL change (ledger-then-apply) — `grants show <service>`
  prints the full decision history plus your effective ACL. That ledger is the
  audit trail for every off-manifest capability a service holds.

## 7. Verification checklist (an agent should prove all five)

1. `ACL GETUSER gnode_client_<svc>` shows exactly the expected patterns.
2. The topology lists your entity (`geodineum topology show <svc>`).
3. Your heartbeat key exists with a fresh `ts` (< 75 s → green tile).
4. A `ping` round-trip returns on the reply key AND a signed receipt appears.
5. `grants show <svc>` — ledger empty (or exactly your approved requests).


## Tenant grouping (`--owner`)

Services under one owner discover each other across site boundaries:

```bash
./scripts/onboard-service.sh staging_my_app --owner acme --yaml /opt/acme/staging
./scripts/onboard-service.sh my_app        --owner acme --yaml /opt/acme/production
```

Query the group (daemon-level; clients stay ACL-isolated to their own
keyspace — they ask, the daemon crosses the boundary):

```bash
FCALL GNODE_TENANT_LIST_SITES 0 acme
FCALL GNODE_TENANT_DISCOVER   0 acme '{"protocol":"http_rest"}' 10
```

Implementation: `gNode/daemon/functions/gnode_site.lua`.

## What onboarding creates

| Artifact | Where |
|---|---|
| ACL user | `gnode_client_{service_id}` |
| Credential (0640, group-readable) | `/etc/geodineum/credentials/valkey_client_{service_id}.password` |
| Unified + health streams (per DTAP env) | `{service_id}:gnode:unified:{env}` |
| Site-registry membership | `gnode:sites:registry` SET |
| Discovery path | `discovery-paths.conf` |
| Registration intent | `{ns}:gnode:registrations` |
| Tenant-group membership (with `--owner`) | `gnode:tenant:{owner}:sites` SET |

## Decommissioning

```bash
./scripts/deregister-service.sh my_service --dry-run    # preview
./scripts/deregister-service.sh my_service --remove-acl # streams + keys + registry
```

Tenant-group cleanup is automatic. (Both scripts live in `gNode/scripts/`.)

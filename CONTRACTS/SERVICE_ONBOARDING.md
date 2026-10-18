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
  `website-static` | `app-pwa` | `webapp-gcore` (serve visitors over HTTP),
  **internal** types `daemon` | `gcore-service` | `custom` (infrastructure).
  Light nodes (ValKey + gNode only) are first-class.
- `webapp-gcore` is a public PHP application on the shared framework without
  WordPress: front controller in the docroot, bootstrap and application code
  in `src/` outside it, runtime user `www-data` reading gCore source through
  `geodineum-code` (asserted at onboarding, never assumed). `gcore-service` is
  the internal sibling: same framework, own system user, systemd unit, no
  vhost.
- Each type carries a **requirement matrix** — the interview asks what the
  service IS; the matrix decides what runs (vhost/certbot, docroot, systemd
  unit + own user, cred model, mail, heartbeat); every type ends on the SAME
  paved road. `geodineum register --matrix` prints it; the single source
  is `lib/service-taxonomy.sh`.
- Every service gets its own **ValKey identity**: ACL user
  `gnode_client_<service>`, credential at
  `/etc/geodineum/credentials/<service>.password` (root:<component-group> 0640).
- **Three separate permission layers** — never conflate them:
  1. **Disk** — Unix users/groups (see `permission-model.md`).
  2. **ValKey ACL** — which keys/streams this identity may touch (this doc §4).
  3. **Reach labels** — which services may message which: `holds` /
     `requires` labels plus a deny list, checked by the daemon on every relayed
     message and fail-closed (`REGISTRATION.md` section 6).
- **Cross-service access is never a self-declared grant.** Your manifest can
  only grant your OWN namespace + well-known shared trees. To reach another
  service: message it via the relay (§5), or request a grant through the
  approval loop (§6).

## 2. Declare — the manifest (ONE schema)

Create `.geodineum/gnode_services.yaml` (or pass `--yaml <dir>`). Every
generator in the estate (`register` and its type rows, the
scaffolder templates) emits this same shape:

```yaml
profile: service                  # web | headless | service | system | component
                                  # names the shape when gnode: is absent
environment: production           # DTAP tier — REQUIRED (flag|manifest|abort)

# The one topology: the declaration by NAME the daemon registers (SPEC-ONE-TOPOLOGY §10).
# The daemon codes the words and refuses one it does not know; derived slots are its.
gnode:
  constellation: geodineum        # where it registers; {ecosystem} interpolates to it
  shape: daemon                   # site (3.1) | app (3.2) | daemon (3.3)
  heartbeat: myservice            # the component name in the heartbeat key
  holds: [internal]               # REACH labels this entity carries
  requires: [internal]            # labels a caller must hold to reach it (fail closed)
  fundamentality: 0.3             # optional; the shape's default applies
  capacity_weight: 1              # per placement; 0 = standby
  axes:                           # the service body's vocabulary, by name
    protocol: [gnode_stream]
    native_format: json
    contract_version: v1
    contract_stability: stable
    auth_method: api_key
    service_scope: internal_api
    domain: [compute]
    throughput_tier: standard
    latency_class: responsive
    reliability_tier: standard
    execution_priority: normal
    implementation_language: rust

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

The ACL is composed from the declarations (plus a safe base: own namespace, the
service's own heartbeat key, and **read-only** access to its constellation's bus
`{<constellation>}:gnode:*` — the one topology is written by the daemon tier only,
so read it with `FCALL_RO`/`HGETALL`, never expect a write there to succeed).
**A manifest that declares nothing is refused** — the
old fallback (a broad legacy-uniform grant set) is retired: it silently
handed `{testing..production}:gnode:*`, `gnode:*`, `topology:*`,
`template:*`, `membership:*` to services that asked for nothing, and looked
correct on every own-namespace check. Regenerate an undeclared manifest with
`sudo geodineum register <its path>` (it recomposes the grants when the manifest changed).

> **`services[].capabilities` is gone.** It was read by nothing —
> `manifest-policy.sh` consumes only `consumes`/`produces`. The declaration is
> the **`gnode:`** block above, registered by name through `register-tools
> --manifest`; the top-level **`profile:`** key (or `--profile`) names the shape
> when the block is absent.
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
> The daemon registers each discovered service into **its own site only**: the
> registered site named by `services[].site`, or else the registered site whose
> id equals `services[].id`. A service with neither is registered nowhere and
> the scan logs a warning. A service is never copied into other sites'
> topologies.
>
> The discovery manifest was also called `gnode_services.yaml`, which is what
> made the two indistinguishable. The daemon still accepts the old name so
> nothing breaks on upgrade; new deployments should use `gnode_discovery.yaml`. The allow-list is the **8 well-known
namespace classes** (own namespace, per-site gnode/gcore bus, ecosystem bus,
shared defaults, env-tagged streams, shared topology, legacy aliases —
`access-grants.scn.md ::PATTERNS`).

## 3. Onboard + register — one command

**`sudo geodineum register`** is the only entry. It asks NEW or INTEGRATE.
- **NEW** (`--new <type> --env <tier>`, `--yes` for no questions) runs the type's
  rows and ends on the steps below, including the mail dispatch-verification
  probe.
- **INTEGRATE** (a path) scans an existing codebase and applies only what it
  lacks, through the same rows.
- **A worker node:** `--node <name>` on the master mints the identity and writes
  its credential to a 0600 file. On the node, `credential add --auth-file`
  installs it and `register … --worker` sets up the files and units.

What it does, in order (the parts register composes; each is idempotent):

```bash
# 1. Identity + streams + discovery + topology entity + intent (on the master):
#    gNode/scripts/onboard-service.sh <service> --yaml <dir> --environment <tier>
#    The manifest's gnode: block is the declaration (shape, constellation, axes);
#    a site is placed on the node that registers it.

# 2. The heartbeat, after onboarding (it runs with the credential's group):
#    a probe-gated timer, scripts/heartbeat/install-heartbeat.sh, whose key is
#    written ONLY while the probe passes — or your service writes its own:
#    SETEX {geodineum}:gnode:heartbeat:production:myservice:$(hostname -s) 120 '{"ts":<unix>,"node":"<short-hostname>"}'   # node segment: CONTRACTS/heartbeat.md — add yourself to its census
#    → your tile on the wp-admin dashboard goes green; missing/stale = red.
#    register's probe: --probe unit:<unit> | tcp:<host>:<port> | http:<url> | pid:<pidfile> | cmd:</abs/path>
#    (default: the unit; an app's /health on NEW, its port on INTEGRATE)

# 3. Prove the round-trip (any registered site stream):
#    XADD your own stream, poll the reply key, find your receipt (§5).

# 4. Check what you can touch:
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
  routes it to the target's stream after the reach check (labels, then the
  deny list; undeclared is refused). You never write into a foreign keyspace.

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
FCALL_RO GNODE_TOPO_QUERY 1 '{acme}:gnode:constellation' <layer_lo> <layer_hi> '{"facets":{"protocol":["http_rest"]}}' '{"limit":10}'   # one topology (GNODE_TENANT_DISCOVER retired 2026-10-11)
```

Implementation: `gNode/daemon/functions/gnode_site.lua`.

## What onboarding creates

| Artifact | Where |
|---|---|
| ACL user | `gnode_client_{service_id}` |
| Credential (0640, group-readable) | `/etc/geodineum/credentials/valkey_client_{service_id}.password` |
| Unified + health streams (per DTAP env) | `{service_id}:gnode:unified:{env}` |
| Site-registry membership | `gnode:sites:registry` SET |
| Registration intent | `{ns}:gnode:registrations` |
| Tenant-group membership (with `--owner`) | `gnode:tenant:{owner}:sites` SET |

## Decommissioning

```bash
sudo geodineum deregister my_service --dry-run      # the plan
sudo geodineum deregister my_service                # remove it (data kept)
sudo geodineum deregister my_service --purge-data   # and the data registration created
```

The inverse of onboarding: the registration intent, the topology entity and its
placements, the keys, the identity, then what registering created on this host
from its ledger (`/etc/geodineum/registrations/<id>.tsv`), newest first. It ends
with a residue check. `gNode/scripts/deregister-service.sh` is its ValKey half
([REGISTRATION.md](REGISTRATION.md)).

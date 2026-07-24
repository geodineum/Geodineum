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
  have to be a website. Public types: Website / App / PWA. Internal types:
  Daemon / Service / Custom. Light nodes (ValKey + gNode only) are first-class.
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

## 2. Declare — the manifest

Create `.geodineum/gnode_services.yaml` (or pass `--yaml <dir>`):

```yaml
services:
  - name: myservice
    capabilities: [workflow]        # drives the 30-dim capability vector

# Optional but recommended — least-privilege ACL composition.
# Own-namespace + well-known patterns ONLY; anything foreign is REFUSED
# and the onboarding aborts (never silently narrowed or broadened).
consumes:
  - "{myservice}:gnode:comms:*"
  - "{site_id}:state:*"             # {site_id}/{svc}/{eco} interpolate
produces:
  - "{myservice}:results:*"
```

With declarations, the ACL is composed from them (plus a safe base: own
namespace + the shared gnode bus). Without them, a legacy uniform grant set
applies — broader; declare when you can. The allow-list is the **8 well-known
namespace classes** (own namespace, per-site gnode/gcore bus, ecosystem bus,
shared defaults, env-tagged streams, shared topology, legacy aliases —
`access-grants.scn.md ::PATTERNS`).

## 3. Onboard + register — five commands

```bash
# 1. Mint identity + streams + discovery (CONSTELLATION MASTER — the ACL
#    admin credential exists only there):
sudo geodineum provision-service myservice   # wraps onboard-service.sh --yaml ...

# 2. Register the topology entity (NODE-LOCAL — run where the service lives):
sudo geodineum register service myservice service
#    profiles: web | headless | service | system | component
#    Review the 30-dim vector — meaningful capabilities beat profile defaults.

# 3. Wire the heartbeat (in your service, every ~60s):
#    SETEX {geodineum}:gnode:heartbeat:production:myservice 120 '{"ts":<unix>}'
#    → your tile on the wp-admin dashboard goes green; missing/stale = red.

# 4. Prove the round-trip (any registered site stream):
#    XADD your own stream, poll the reply key, find your receipt (§5).

# 5. Check what you can touch:
sudo geodineum grants show myservice
```

## 4. What your identity can do

Composed grants (declared manifests) or the legacy uniform set (undeclared).
Either way ACL patterns are **additive-only** — revocation is a full
recompose, not a subtraction. Commands allowed: streams (`x*`), `fcall`,
basic KV/hash/set/list/zset, `scan`, `publish` — no admin surface
(`FUNCTION FLUSH`/`RESTORE` are explicitly denied at the daemon tier).

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

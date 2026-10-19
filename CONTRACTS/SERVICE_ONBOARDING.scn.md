# SERVICE ONBOARDING :: Registration + Grants + Permission Model — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent onboarding a NEW service into a live Geodineum constellation from COLD.
> TRUTH = code on disk (`Geodineum/lib/register.sh`, `gNode/scripts/onboard-service.sh`,
> `Geodineum/lib/manifest-policy.sh`, `Geodineum/lib/service-taxonomy.sh`,
> `scripts/cli/grants.sh`) — re-verify on drift. Human twin:
> [[SERVICE_ONBOARDING]]. Deep layers: [[access-grants]] [[permission-model]]
> [[service-provisioning]] [[keyspace-model]] [[receipt-stream]].

## ::PRIME

```
Onboarding := Interview (what IS it) → Matrix (what RUNS) → Paved road
  (provision → register → heartbeat → mail-verify → verify) — SAME road, every type.
TAXONOMY: public website-wp|website-static|app-pwa|webapp-gcore · internal daemon|gcore-service|custom
  matrix-as-data in lib/service-taxonomy.sh; `geodineum register --matrix` prints it.
NEVER raw-XADD unregistered: registration buys delivery guarantees (consumer groups +
  orphan reclaim), a least-privilege identity, receipts/heartbeat observability, and
  a capability-topology position.
THREE permission layers, never conflated:
  disk (unix groups) ∥ ValKey ACL (key/stream patterns) ∥ reach labels (holds/requires + deny list, fail closed)
CROSS-SERVICE is NEVER self-declared: own-namespace grants only; foreign reach =
  relay (_rt, daemon-bridged, policy-checked) OR the grant-request approval loop.
UNDECLARED ⇒ REFUSED: the legacy uniform grant set is RETIRED (fail-loud, never
  silent-broad). A written config is a claim; only a dispatched message is proof
  (mail row verifies by dispatch probe, Step 5.5).
```

## ::ANCHOR

```
ENTRY: `geodineum register [<path|domain|name>] [--new T | --integrate] --env E [--yes]` — asks NEW or INTEGRATE; NEW = the type interview
  or flags; `--node <worker>` = delegated (master mints, prints
  add-service-credential.sh one-liner); `new site` unchanged (≡ website-wp lane)
IDENTITY: gnode_client_<svc> · cred /etc/geodineum/credentials/valkey_client_<svc>.password
  minted MASTER-ONLY (admin cred never leaves ValKey owner)
CRED MODEL follows type: web → root:geodineum-web:640 (www-data via group) ·
  internal → root:geodineum:640 (www-data NEVER) · daemon → root:<svc>:640 (own group)
MANIFEST (ONE schema, all generators): .geodineum/gnode_services.yaml —
  gnode: block = the declaration by NAME on the one topology (constellation, shape
  site|app|daemon, heartbeat, holds/requires = REACH labels, fundamentality,
  capacity_weight, axes in the service body's vocabulary; SPEC-ONE-TOPOLOGY §10) +
  profile: (names the shape when gnode: absent) + environment: (REQUIRED,
  flag|manifest|abort) + services[].metadata + consumes:/produces: (flat lists;
  {site_id}/{service}/{ecosystem}=gnode.constellation interpolate).
  services[].capabilities DELETED — was read by nothing.
DISCOVERY PLACEMENT: a discovered service registers into ITS OWN site only —
  services[].site if registered, else the registered site == services[].id;
  neither ⇒ registered nowhere + WARN; never copied into other sites.
POLICY: 8 well-known namespace classes; foreign pattern → POLICY DENY, onboard ABORTS
  (fail-loud, never silent-narrow, never silent-broaden); declared ⇒ composed grants +
  safe base (own ns + own heartbeat key + READ-ONLY {geodineum}:gnode:* via %R~ — daemon tier writes the topology; clients read with FCALL_RO/HGETALL); UNDECLARED ⇒ REFUSED (legacy uniform set gone;
  regenerate: `geodineum register <its path>` recomposes grants when the manifest changed)
COMMANDS: geodineum register (taxonomy) · geodineum register <svc> --node <node>
  [--yaml <dir>] (master; no manifest → mints minimal at /etc/geodineum/manifests/<svc>/)
  · geodineum grants
  request|pending|approve|deny|show|sweep
HEARTBEAT: SETEX {geodineum}:gnode:heartbeat:{env}:<svc>:<node> 120 '{"ts":<unix>,"node":...}' every ~60s (node = short hostname; census in CONTRACTS/heartbeat.md, update SAME commit)
  — dashboard tile green ≤75s, lagging ≤120s, red after · daemon/gcore types get a
  timer pair GATED on the main unit being active (never false-green)
HEARTBEAT-WRAPPER: a service with no heartbeat of its own integrates with geodineum-heartbeat
  (scripts/heartbeat/: geodineum-heartbeat.sh + geodineum-heartbeat@.service/.timer 30s +
  install-heartbeat.sh <svc> --probe unit:|tcp:|http:|pid:|cmd: [--apply]); spec at
  /etc/geodineum/heartbeat/<svc>.env 0640; the probe is the proof — SETEX only on pass,
  fail = no write + journal line, key expires, placement reads dead
WIRE: XADD {site}:gnode:unified:{env} (t=c, p carries _request_id) → poll {site}:res:{id}
  (EX 10) → signed receipt on {site}:gnode:receipts:{env} (ed25519; pubkeys at
  {geodineum}:gnode:receipt_pubkeys) · cross-service via _rt (relay), _rr (reply-to)
GRANTS-LOOP: request = DATA on {geodineum}:gnode:grants:requests → COMMS email w/ CLI
  one-liners → operator approve|deny on master → AUTO-DENY after ttl (72h default) →
  LEDGER-THEN-APPLY on {geodineum}:gnode:grants:ledger (decision recorded BEFORE any
  SETUSER) · ACL additive-only ⇒ revoke = full recompose, never subtraction
```

## ::MATRIX (rows per type — data lives in lib/service-taxonomy.sh)

```
website-wp      mail wp_stack notify                          profile web  cred g-web
website-static  docroot skeleton form_endpoint vhost manifest  profile web  cred g-web
                mail onboard web_perms                         (form → COMMS)
app-pwa         docroot skeleton_pwa [form] vhost manifest     profile web  cred g-web
                mail onboard web_perms
webapp-gcore    docroot web_code_group skeleton_gcore          profile web  cred g-web
                gcore_bootstrap [form] vhost manifest mail     (www-data ∈ geodineum-code ASSERTED;
                onboard web_perms                              src/ outside docroot, root:www-data 750/640)
daemon          own_user service_dirs manifest systemd_unit    profile service  cred own
                heartbeat mail onboard
gcore-service   code_group service_dirs gcore_bootstrap        profile service  cred geodineum
                manifest systemd_unit heartbeat mail onboard   (user ∈ geodineum-code + geodineum)
custom          manifest mail onboard                          mesh identity only
DTAP env: REQUIRED all types · mail: opt, domain-scoped, ALL types, PROVEN by dispatch
onboard is ALWAYS the last row — one paved road, many matrices.
```

## ::SEQUENCE (the paved road — execute in order)

```
0 REGISTER  sudo geodineum register [--new T | <path>] --env E [--yes]  → runs 1-5 for you (INTEGRATE: only the missing ones)
1 DECLARE   gnode_services.yaml (ONE schema); consumes/produces = OWN namespace only
2 PROVISION sudo geodineum register <svc> --node <node>          [master]
3 TOPOLOGY  done by 1 (onboard registers the entity and its intent); topology register service = repair primitive
4 HEARTBEAT wire the SETEX loop into the service runtime (or the gated timer pair)
5 VERIFY    ACL GETUSER exact · topology shows entity · heartbeat fresh ·
            ping round-trip (reply + verified receipt) · grants show = expected ledger ·
            mail: journal says "dispatched successfully" (Step 5.5 probe), never config-read
```

## ::FAILURE_MODES

```
RAW-XADD-TEMPTATION: it works mechanically — and loses reclaim, audit, identity, policy.
FOREIGN-GRANT-ASK: adding {other}:* to your manifest → POLICY DENY aborts onboarding.
  Wanted: relay (_rt) or `grants request`. NEVER widen the 8-class allowlist.
UNDECLARED-MANIFEST: refused at grant time (uniform fallback retired). Fix = declare
  consumes/produces or `geodineum register <svc> --force`, then --regrant.
WORKER-PROVISION: provision-service on a worker fails (admin cred absent) — by design;
  delegated flow = `register <name> --new <type> --node <worker>` on the master (credential → 0600 file), then on the worker `credential add --auth-file` + `register … --worker`.
GRANT-WITHOUT-LEDGER: any SETUSER outside the loop breaks the audit invariant;
  effective-vs-ledger drift is checkable (ACL GETUSER diff).
SILENT-EXPIRY: replies are EX 10 — poll immediately; the receipt is the durable record.
FALSE-GREEN-HEARTBEAT: a bare timer heartbeats a dead service; the shipped pair is
  ExecCondition-gated on the main unit — keep that property when hand-rolling.
TENANT: `--owner acme` → `gnode:tenant:acme:sites` SET; cross-site discover = daemon-level
  (GNODE_TENANT_LIST_SITES, gnode_site.lua; cross-site discovery = GNODE_TOPO_QUERY on the constellation key since 2026-10-11); clients stay keyspace-isolated.
CREATES: ACL user + cred 0640 (group per type) + unified/health streams ×DTAP +
  sites:registry + discovery-path + intent + type rows (vhost/unit/heartbeat/manifest),
  each host artifact recorded in the ledger /etc/geodineum/registrations/<id>.tsv.
DECOMMISSION: sudo geodineum deregister <id> [--dry-run|--purge-data|--keep-acl] = the inverse:
  ValKey half deregister-service.sh, then the ledger newest-first, then a residue check;
  service-cycle-test.sh asserts zero residue through it.
```

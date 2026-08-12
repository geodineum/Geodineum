# SERVICE ONBOARDING :: Registration + Grants + Permission Model — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent onboarding a NEW service into a live Geodineum constellation from COLD.
> TRUTH = code on disk (`gNode/scripts/onboard-service.sh`, `register-site.sh`,
> `Geodineum/lib/manifest-policy.sh`, `Geodineum/lib/service-taxonomy.sh`,
> `scripts/cli/grants.sh`) — re-verify on drift. Human twin:
> [[SERVICE_ONBOARDING]]. Deep layers: [[access-grants]] [[permission-model]]
> [[service-provisioning]] [[keyspace-model]] [[receipt-stream]].

## ::PRIME

```
Onboarding := Interview (what IS it) → Matrix (what RUNS) → Paved road
  (provision → register → heartbeat → mail-verify → verify) — SAME road, every type.
TAXONOMY: public website-wp|website-static|app-pwa · internal daemon|gcore-service|custom
  matrix-as-data in lib/service-taxonomy.sh; `geodineum service new --matrix` prints it.
NEVER raw-XADD unregistered: registration buys delivery guarantees (consumer groups +
  orphan reclaim), a least-privilege identity, receipts/heartbeat observability, and
  a capability-topology position.
THREE permission layers, never conflated:
  disk (unix groups) ∥ ValKey ACL (key/stream patterns) ∥ relay policy (per-pair per-command)
CROSS-SERVICE is NEVER self-declared: own-namespace grants only; foreign reach =
  relay (_rt, daemon-bridged, policy-checked) OR the grant-request approval loop.
UNDECLARED ⇒ REFUSED: the legacy uniform grant set is RETIRED (fail-loud, never
  silent-broad). A written config is a claim; only a dispatched message is proof
  (mail row verifies by dispatch probe, Step 5.5).
```

## ::ANCHOR

```
ENTRY: `geodineum service new [<domain|name>] [--type T --env E --yes]` — interview
  or flags; `--node <worker>` = delegated (master mints, prints
  add-service-credential.sh one-liner); `new site` unchanged (≡ website-wp lane)
IDENTITY: gnode_client_<svc> · cred /etc/geodineum/credentials/valkey_client_<svc>.password
  minted MASTER-ONLY (admin cred never leaves ValKey owner)
CRED MODEL follows type: web → root:geodineum-web:640 (www-data via group) ·
  internal → root:geodineum:640 (www-data NEVER) · daemon → root:<svc>:640 (own group)
MANIFEST (ONE schema, all generators): .geodineum/gnode_services.yaml —
  top-level profile: (drives 30-dim vector) + environment: (REQUIRED,
  flag|manifest|abort) + services[].metadata (daemon discovery) +
  consumes:/produces: (flat lists; {site_id}/{service}/{ecosystem} interpolate).
  services[].capabilities DELETED — was read by nothing.
POLICY: 8 well-known namespace classes; foreign pattern → POLICY DENY, onboard ABORTS
  (fail-loud, never silent-narrow, never silent-broaden); declared ⇒ composed grants +
  safe base (own ns + shared gnode bus); UNDECLARED ⇒ REFUSED (legacy uniform set gone;
  regenerate: `geodineum register <svc> --force` then `--regrant`)
COMMANDS: geodineum service new (taxonomy) · geodineum provision-service <svc>
  [--yaml <dir>] (master; no manifest → mints minimal at /etc/geodineum/manifests/<svc>/)
  · geodineum register service <svc> <profile> (node-local) · geodineum grants
  request|pending|approve|deny|show|sweep
HEARTBEAT: SETEX {geodineum}:gnode:heartbeat:{env}:<svc>:<node> 120 '{"ts":<unix>,"node":...}' every ~60s (node = short hostname; census in CONTRACTS/heartbeat.md, update SAME commit)
  — dashboard tile green ≤75s, lagging ≤120s, red after · daemon/gcore types get a
  timer pair GATED on the main unit being active (never false-green)
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
                mail onboard web_perms                         (generalized palacio)
app-pwa         docroot skeleton_pwa [form] vhost manifest     profile web  cred g-web
                mail onboard web_perms
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
0 INTERVIEW sudo geodineum service new [--type --env --yes]  → runs 1-5 for you
1 DECLARE   gnode_services.yaml (ONE schema); consumes/produces = OWN namespace only
2 PROVISION sudo geodineum provision-service <svc>          [master]
3 REGISTER  sudo geodineum register service <svc> <profile> [node-local, review 30-dim]
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
  delegated flow = `service new --node <worker>` on the master.
GRANT-WITHOUT-LEDGER: any SETUSER outside the loop breaks the audit invariant;
  effective-vs-ledger drift is checkable (ACL GETUSER diff).
SILENT-EXPIRY: replies are EX 10 — poll immediately; the receipt is the durable record.
FALSE-GREEN-HEARTBEAT: a bare timer heartbeats a dead service; the shipped pair is
  ExecCondition-gated on the main unit — keep that property when hand-rolling.
TENANT: `--owner acme` → `gnode:tenant:acme:sites` SET; cross-site discover = daemon-level
  (GNODE_TENANT_LIST_SITES / GNODE_TENANT_DISCOVER, gnode_site.lua); clients stay keyspace-isolated.
CREATES: ACL user + cred 0640 (group per type) + unified/health streams ×DTAP +
  sites:registry + discovery-path + intent + type rows (vhost/unit/heartbeat/manifest).
DECOMMISSION: deregister-service.sh [--dry-run|--remove-acl]; tenant cleanup automatic;
  full per-row uninstall parity = service-cycle-test.sh reversal (repo scripts/).
```

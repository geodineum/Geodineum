# SERVICE ONBOARDING :: Registration + Grants + Permission Model — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent onboarding a NEW service into a live Geodineum constellation from COLD.
> TRUTH = code on disk (`gNode/scripts/onboard-service.sh`, `register-site.sh`,
> `Geodineum/lib/manifest-policy.sh`, `scripts/cli/grants.sh`) — re-verify on
> drift. Human twin: [[SERVICE_ONBOARDING]]. Deep layers: [[access-grants]]
> [[permission-model]] [[service-provisioning]] [[keyspace-model]]
> [[receipt-stream]].

## ::PRIME

```
Onboarding := Declare → Provision (master) → Register (node-local) → Heartbeat → Verify
NEVER raw-XADD unregistered: registration buys delivery guarantees (consumer groups +
  orphan reclaim), a least-privilege identity, receipts/heartbeat observability, and
  a capability-topology position. Paved road = 5 commands.
THREE permission layers, never conflated:
  disk (unix groups) ∥ ValKey ACL (key/stream patterns) ∥ relay policy (per-pair per-command)
CROSS-SERVICE is NEVER self-declared: own-namespace grants only; foreign reach =
  relay (_rt, daemon-bridged, policy-checked) OR the grant-request approval loop.
```

## ::ANCHOR

```
IDENTITY: gnode_client_<svc> · cred /etc/geodineum/credentials/<svc>.password
  (root:<component-group> 0640) · minted MASTER-ONLY (admin cred never leaves ValKey owner)
MANIFEST: .geodineum/gnode_services.yaml — services[].name/capabilities +
  top-level consumes:/produces: (flat lists; {site_id}/{svc}/{eco} interpolate)
POLICY: 8 well-known namespace classes; foreign pattern → POLICY DENY, onboard ABORTS
  (fail-loud, never silent-narrow, never silent-broaden); declared ⇒ composed grants +
  safe base (own ns + shared gnode bus); undeclared ⇒ legacy uniform set (never bricked)
COMMANDS: geodineum provision-service <svc> (master) · geodineum register service <svc>
  <profile: web|headless|service|system|component> (node-local) · geodineum grants
  request|pending|approve|deny|show|sweep
HEARTBEAT: SETEX {geodineum}:gnode:heartbeat:{env}:<svc> 120 '{"ts":<unix>}' every ~60s
  — dashboard tile green ≤75s, lagging ≤120s, red after
WIRE: XADD {site}:gnode:unified:{env} (t=c, p carries _request_id) → poll {site}:res:{id}
  (EX 10) → signed receipt on {site}:gnode:receipts:{env} (ed25519; pubkeys at
  {geodineum}:gnode:receipt_pubkeys) · cross-service via _rt (relay), _rr (reply-to)
GRANTS-LOOP: request = DATA on {geodineum}:gnode:grants:requests → COMMS email w/ CLI
  one-liners → operator approve|deny on master → AUTO-DENY after ttl (72h default) →
  LEDGER-THEN-APPLY on {geodineum}:gnode:grants:ledger (decision recorded BEFORE any
  SETUSER) · ACL additive-only ⇒ revoke = full recompose, never subtraction
```

## ::SEQUENCE (the paved road — execute in order)

```
1 DECLARE   write gnode_services.yaml; consumes/produces = OWN namespace only
2 PROVISION sudo geodineum provision-service <svc>          [master]
3 REGISTER  sudo geodineum register service <svc> <profile> [node-local, review 30-dim]
4 HEARTBEAT wire the SETEX loop into the service runtime
5 VERIFY    ACL GETUSER exact · topology shows entity · heartbeat fresh ·
            ping round-trip (reply + verified receipt) · grants show = expected ledger
```

## ::FAILURE_MODES

```
RAW-XADD-TEMPTATION: it works mechanically — and loses reclaim, audit, identity, policy.
FOREIGN-GRANT-ASK: adding {other}:* to your manifest → POLICY DENY aborts onboarding.
  Wanted: relay (_rt) or `grants request`. NEVER widen the 8-class allowlist.
WORKER-PROVISION: provision-service on a worker fails (admin cred absent) — by design.
GRANT-WITHOUT-LEDGER: any SETUSER outside the loop breaks the audit invariant;
  effective-vs-ledger drift is checkable (ACL GETUSER diff).
SILENT-EXPIRY: replies are EX 10 — poll immediately; the receipt is the durable record.
UNDECLARED-FOREVER: legacy uniform grants are broad; declare consumes/produces to shrink.
TENANT: `--owner acme` → `gnode:tenant:acme:sites` SET; cross-site discover = daemon-level
  (GNODE_TENANT_LIST_SITES / GNODE_TENANT_DISCOVER, gnode_site.lua); clients stay keyspace-isolated.
CREATES: ACL user + cred 0640 + unified/health streams ×DTAP + sites:registry + discovery-path + intent.
DECOMMISSION: deregister-service.sh [--dry-run|--remove-acl]; tenant cleanup automatic.
```

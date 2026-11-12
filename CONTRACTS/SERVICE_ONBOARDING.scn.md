# SERVICE ONBOARDING :: register + reach + prove — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent onboarding a NEW service into a live constellation from COLD. TRUTH = code
> (`Geodineum/lib/{register,service-taxonomy,manifest-policy,common,site-pool}.sh`,
> `gNode/scripts/onboard-service.sh`, `gNode/scripts/cli/{grants,register}.sh`,
> `gNode/daemon/functions/gnode_topo.lua`). Human twin: [[SERVICE_ONBOARDING]].
> Neighbours: [[REGISTRATION]] [[access-grants]] [[permission-model]] [[heartbeat]] [[receipt-stream]].
> All commands on the master, root, unless stated.

## ::PRIME

```
ENTRY := `sudo geodineum register` — NEW (--new <type>) | INTEGRATE (<path>); --env REQUIRED.
TYPES := public website-wp|website-static|app-pwa|webapp-gcore · internal app|daemon|scheduled|gcore-service|custom
  (lib/service-taxonomy.sh; `register --matrix`).
IDENTITY := gnode_client_<id> · /etc/geodineum/credentials/valkey_client_<id>.password root:<g> 0640 + .owner
  g: web→geodineum-web (pool → web_<id>) · app|daemon|scheduled→own · gcore-service|custom→geodineum.
BASE GRANT := ~{<id>}:* ~<id>:* ~{<c>}:gnode:heartbeat:*:<id>:* %R~{<c>}:gnode:*
  + manifest consumes/produces ⊂ allow-list (manifest-policy.sh); foreign ⇒ ABORT; empty ⇒ REFUSED.
COMMANDS := allowlist in onboard-service.sh; NO eval|subscribe|keys|xautoclaim|zrangebyscore.
THREE LAYERS := disk ∥ ValKey ACL ∥ reach — never conflated.
REACH(c→t) := both declared ∧ (t below c: lower layer | same layer ∧ lower fundamentality | t ∈ peers:c)
  ∧ env equal (or t global) ∧ c holds ∀ requires:t ∧ no deny. Verdicts undeclared|layer|env|label:<l>|deny.
  defaults site 0.7 · app 0.5 · daemon 0.3 ⇒ site→daemon free; daemon→app/daemon needs peers.
LABELS := generated app/daemon hold+require internal; a site holds/requires nothing; adding a label = operator decision.
NEVER raw-XADD unregistered. NEVER self-declare a foreign key: relay (_rt) or grant loop.
```

## ::MANIFEST

```
.geodineum/gnode_services.yaml: profile · environment · gnode:{constellation, shape site|app|daemon, heartbeat,
  holds, requires, peers, fundamentality, capacity_weight, axes(words of topology_schema.yaml)} · services[] ·
  consumes/produces ({site_id} {service} {ecosystem} interpolate).
NEW writes it; INTEGRATE writes one only if absent.
CHANGE consumes/produces → `sudo geodineum register <path>` (manifest drift ⇒ regrant).
CHANGE labels/axes → `sudo geodineum topology register service <id> --manifest <f> --env <e> [--on <node>]`.
REGRANT := base + manifest + ledger approvals in force; `grants revoke <rid>` ⇒ out at next regrant; ledger unreadable ⇒ REFUSE.
The daemon reads no discovery manifest; the CLI finds .geodineum/.
```

## ::REGISTER

```
NEW       sudo geodineum register <domain|name> --new <type> --env <e> [--dry-run] [--yes]
          NEW-only: --mail-domain|--no-mail --form|--no-form --owner --notify-email --theme --schedule --no-ssl --node --worker
INTEGRATE sudo geodineum register <path> --env <e> [--name --type --probe --port --manifest --yes --dry-run]  (else exit 2)
WORKER    master: register <n> --new <t> --env <e> --node <node> → ~/<n>.credential 0600
          node:   credential add --service <n> --auth-file ~/<n>.credential --group <g> ; register <n> --new <t> --env <e> --worker
HEARTBEAT app|daemon|scheduled|gcore-service: probe-gated timer (install-heartbeat.sh); web: host daemon's heartbeat.
```

## ::CASE_1 composed (uses registered components)

```
1 register (above).
2 COMMS: write own {<id>}:gnode:comms:<env>; `sudo geodineum comms recipients <id> set <addr>`. No grant.
3 relay: SMEMBERS {geodineum}:gnode:constellation:req:<t> / holds:<id>; FCALL GNODE_TOPO_CAN_REACH 1
  {geodineum}:gnode:constellation <id> <t> <now_ms> (daemon cred, root; NO CLI VERB).
  label:<l> → holds += l · layer → peers += t · env → same env; then topology register service --manifest.
4 foreign keys: `sudo geodineum grants request <id> '%R~{x}:…' --reason …` → operator approves.
```

## ::CASE_2 standalone website (webapp-gcore)

```
1 DNS → master (or --no-ssl, certbot later).
2 sudo geodineum register <domain> --new webapp-gcore --env staging --mail-domain <domain> [--dry-run]
  rows: docroot · www-data∈geodineum-code · public_html/index.php → src/bootstrap.php · vhost+a2ensite+certbot
  · manifest (site, holds/requires []) · DKIM · onboard (placed on this node) · perms root:www-data 750/640.
3 sudo geodineum site pool <id> plan|apply|verify --kind standalone  (cred → web_<id>).
4 code: gcore_init() from /opt/geodineum/gCore/gcore-standalone.php.
5 DEPLOY: the orchestrator pulls only /opt/geodineum checkouts (core + site-repos.conf), NEVER /var/www;
  ship the docroot with your own script.
6 mail: geodineum mail records <domain>; comms recipients/sender.
```

## ::WIRE

```
XADD {<id>}:gnode:unified:<env> * id <u> t c c <cmd> ss <id> sn <node> ts <unix> p '{"_request_id":"<u>",…}'
→ GET {<id>}:res:<u> (EX 10) → receipt {<id>}:gnode:receipts:<env> (ed25519; {geodineum}:gnode:receipt_pubkeys)
· _rt <target> = relay after reach; a site is never a relay target.
```

## ::GRANTS

```
request → {geodineum}:gnode:grants:requests → COMMS alert + buttons → approve|deny (master, admin)
→ LEDGER {geodineum}:gnode:grants:ledger BEFORE SETUSER → TTL auto-deny (72h). %R~ read · %W~ write · bare rw.
`sudo geodineum grants show <id>` = ledger + effective ACL. Approvals survive regrants until revoked.
```

## ::PROVE

```
sudo geodineum status <id> · topology show <id> · topology verify · grants show <id>
reach FCALL = 1 reach · site pool <id> verify · geodineum status --config --site <id> · curl -sI https://<domain>/
geodineum mail records <domain> · sudo geodineum comms test-send <id> · geodineum status comms
```

## ::COMMS

```
own stream, no grant · `comms recipients <id> list|set|add|remove` · `comms sender <id> show|set` (both reload)
SENDER: domain ∈ /etc/geodineum/mail/authorized-domains (setup-mail-stack.sh) or default, else rewritten to default.
min_priority: delivered iff priority ≤ it (5 = all) · TLS unset: plaintext to loopback, TLS elsewhere.
accepted ≠ delivered: {<id>}:gnode:comms:status:<stream_id>.
```

## ::FAILURE_MODES

```
RAW-XADD · FOREIGN-PATTERN in manifest (abort) · EMPTY MANIFEST (refused) · INTEGRATE + --owner/--mail-domain (exit 2)
· PUSH ≠ DEPLOY for /var/www · status <id> needs sudo.
TENANT: --owner (NEW only) → gnode:tenant:<o>:sites; GNODE_TENANT_LIST_SITES; GNODE_TOPO_QUERY is not tenant-filtered.
CREATES: ACL user · cred+.owner · streams ×DTAP · gnode:sites:registry · entity+labels · intent · .geodineum/ · ledger
  /etc/geodineum/registrations/<id>.tsv.  DECOMMISSION: sudo geodineum deregister <id> [--dry-run|--purge-data].
```

## ::GRAPH

CO_LESSON: [[SERVICE_ONBOARDING]] [[REGISTRATION]] [[access-grants]] [[heartbeat]] [[permission-model]]

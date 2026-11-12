# Service Onboarding — register, reach, prove

> The one document for bringing a new service into a Geodineum constellation,
> from this file alone. Machine twin: `SERVICE_ONBOARDING.scn.md`. Per-entity
> recipes and refusals: `REGISTRATION.md`. Deeper: `access-grants.md` (the
> approval loop), `permission-model.md` (disk, a different layer),
> `heartbeat.md`, `receipt-stream.md`.
>
> Code wins over this file. Commands run on the constellation master as root
> unless a step says otherwise.

## 0. The one rule

**Do not raw-`XADD` from an unregistered process.** Registration is what gives
you delivery guarantees (consumer groups and reclaim), a least-privilege ValKey
identity, observability (receipts, heartbeat), and a place in the topology that
the relay checks. A raw writer has none of that and shows up in nobody's audit.

## 1. Concepts

- **Types** (`lib/service-taxonomy.sh`, `sudo geodineum register --matrix`):
  public `website-wp | website-static | app-pwa | webapp-gcore` (need a domain),
  internal `app | daemon | scheduled | gcore-service | custom`. Each type is a
  list of rows; `onboard` is the row that mints the identity and registers the
  entity.
- **Identity**: ACL user `gnode_client_<id>`, credential
  `/etc/geodineum/credentials/valkey_client_<id>.password`, `root:<group> 0640`
  with a `.owner` sidecar that the deploy permission pass enforces. Group per
  type: web types `geodineum-web`, `app`/`daemon`/`scheduled` their own group,
  `gcore-service`/`custom` `geodineum`. A site on its own PHP pool
  (`geodineum site pool <id> apply`) moves it to the pool user `web_<id>`.
- **What every identity may touch** (`gNode/scripts/onboard-service.sh`): its own
  namespace `~{<id>}:*` and `~<id>:*`, its own heartbeat key
  `~{<c>}:gnode:heartbeat:*:<id>:*`, and **read-only** `%R~{<c>}:gnode:*` (the
  topology is written by the daemon tier only). On top of that, the manifest's
  `consumes`/`produces`, each checked against the allow-list in
  `lib/manifest-policy.sh`; a pattern outside it aborts onboarding. Commands are an
  allowlist in the same script: streams with consumer groups, `FCALL`/`FCALL_RO`,
  basic string/hash/set/list/zset, `SCAN`, `PUBLISH`, `MULTI`/`EXEC`. Not granted,
  among others: `EVAL`, `SUBSCRIBE`, `KEYS`, `XAUTOCLAIM`, `ZRANGEBYSCORE`.
- **Three permission layers**, never conflated:
  1. **Disk**: Unix users and groups (`permission-model.md`).
  2. **ValKey ACL**: which keys this identity may touch (above, and §7).
  3. **Reach**: which entity the relay lets message which (below).
- **Reach** (`GNODE_TOPO_CAN_REACH`, `gNode/daemon/functions/gnode_topo.lua`).
  A relayed command from caller to target passes only when all of these hold:
  both are registered; the target sits below the caller (a lower layer, or the
  same layer and a lower `fundamentality`) **or** the target is in the caller's
  `peers`; the target's environment equals the caller's (or is `global`); the
  caller holds every label the target `requires`; no deny is active. Refusal
  reasons: `undeclared`, `layer`, `env`, `label:<l>`, `deny`. Shape defaults
  (`gNode/daemon/config/topology_schema.yaml`): site 0.7, app 0.5, daemon 0.3, so
  a site reaches apps and daemons by default, and a daemon reaching an app or
  another daemon of equal or higher fundamentality needs `peers`.
- **Labels**: generated `app` and `daemon` manifests hold and require
  `internal`; a site holds and requires nothing. A service that guards a command
  requires its own label; adding a label to a caller is an operator decision,
  because root registers the manifest.
- **Cross-service keys are never self-declared.** To reach another service:
  message it through the relay (§6), or ask for its keys through the grant loop (§7).

## 2. Declare — the manifest

`.geodineum/gnode_services.yaml` in the service root. `register` NEW writes it;
INTEGRATE writes one only when none exists and never touches an existing one.

```yaml
profile: service                  # web | headless | service | system | component
environment: production           # DTAP tier; register's --env wins

gnode:                            # the declaration by name; the daemon codes the words
  constellation: geodineum
  shape: daemon                   # site (3.1) | app (3.2) | daemon (3.3)
  heartbeat: myservice            # component name in the heartbeat key (app, daemon)
  holds: [internal]               # labels this entity carries
  requires: [internal]            # labels a caller must hold
  peers: []                       # entities this one may reach although they are not below it
  fundamentality: 0.3             # optional; the shape's default applies
  capacity_weight: 1              # 0 = standby
  axes:                           # words from gNode/daemon/config/topology_schema.yaml
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
    metadata:
      description: "What this service does"
      type: "daemon"
      tier: "SERVICE"

consumes: []                      # at least one of consumes/produces is REQUIRED:
produces:                         # a manifest that declares nothing is refused
  - "{myservice}:gnode:comms:*"   # {site_id} {service} {ecosystem} interpolate
```

- Without a `gnode:` block, `profile:` names the shape (web → site, headless →
  app, the rest → daemon). Declare it; the fallback is `web`.
- **After a manifest change**: `consumes`/`produces` recompose with
  `sudo geodineum register <path>` (it sees the changed manifest and regrants);
  labels and axes re-register with
  `sudo geodineum topology register service <id> --manifest <file> --env <env> [--on <node>]`.
- **A regrant keeps approved grants.** It resets the identity's key patterns to the
  base and the manifest, then replays every approval the grant ledger holds in force
  (§7); `grants revoke <request_id>` takes one out at the next regrant. A regrant that
  cannot read the ledger refuses rather than drop them.
- The daemon reads no discovery manifest: the service's `.geodineum/` is found by
  the CLI, and the declaration reaches the topology through registration only.

## 3. Register — the one entry

`sudo geodineum register` asks NEW or INTEGRATE; a path to an existing directory
means INTEGRATE.

```bash
sudo geodineum register --matrix                                          # the types and their rows
sudo geodineum register <domain> --new <public type> --env <tier> [--dry-run]
sudo geodineum register <name> --new app --lang python --port 8090 --env <tier>
sudo geodineum register <name> --new daemon|scheduled|gcore-service|custom --env <tier>
sudo geodineum register <path> --env <tier> [--name <id>] [--type <t>] [--probe <p>] [--dry-run]   # INTEGRATE
```

- `--env` is required; nothing is assumed. `--yes` skips the questions.
- NEW-only options: `--mail-domain <d> | --no-mail`, `--form | --no-form`,
  `--owner <tenant>`, `--notify-email`, `--theme`, `--schedule`, `--no-ssl`,
  `--node`, `--worker`. INTEGRATE accepts only `--name --env --type --probe --port
  --manifest --yes --dry-run` and exits on anything else.
- **A service on another node**: on the master
  `sudo geodineum register <name> --new <type> --env <tier> --node <node>` runs only
  `manifest mail onboard` and writes the credential to `~/<name>.credential`
  (0600) of the user who ran it; on the node
  `sudo geodineum credential add --service <name> --auth-file ~/<name>.credential --group <g>`,
  then `sudo geodineum register <name> --new <type> --env <tier> --worker`.
- The heartbeat row (`app`, `daemon`, `scheduled`, `gcore-service`) installs a
  probe-gated timer (`scripts/heartbeat/install-heartbeat.sh`): the key is written
  only while the probe passes. Web types have no heartbeat of their own: a site's
  health is its host daemon's heartbeat.
- `onboard` also runs a mail dispatch probe that emails the site's recipients;
  `onboard-service.sh --no-mail-probe` skips it when calling the script directly.

## 4. Case 1 — a composed service (uses what is already registered)

A service whose work is done by components already in the constellation: COMMS
for mail, another service's commands, another service's keys.

1. **Register it** (§3):
   `sudo geodineum register <name> --new daemon --env production --dry-run`, then without `--dry-run`.
2. **Mail through COMMS: nothing to grant.** Write your own stream
   `{<id>}:gnode:comms:<env>` (already in the generated `produces`); COMMS scans
   `{*}:gnode:comms:<env>`. Recipients: `sudo geodineum comms recipients <id> set you@example.com` (§9).
3. **Commands to another service go through the relay.** Find what the target
   requires and whether you reach it. There is no CLI verb for labels or reach;
   with the daemon credential:
   ```bash
   sudo bash -c 'V() { REDISCLI_AUTH="$(</etc/geodineum/credentials/valkey_daemon.password)" valkey-cli --no-auth-warning --raw --user gnode_daemon -p 47445 "$@"; }
     V SMEMBERS "{geodineum}:gnode:constellation:req:<target>"
     V SMEMBERS "{geodineum}:gnode:constellation:holds:<you>"
     V FCALL GNODE_TOPO_CAN_REACH 1 "{geodineum}:gnode:constellation" <you> <target> "$(date +%s000)"'
   ```
   `label:<l>`: add `<l>` to your `holds`. `layer`: add the target to your
   `peers`. `env`: register in the target's environment. Then re-register the
   entity:
   `sudo geodineum topology register service <you> --manifest <root>/.geodineum/gnode_services.yaml --env <env>`
   (a site also `--on <node>`).
4. **Reading another service's keys**: a grant request (§7):
   `sudo geodineum grants request <you> '%R~{other}:some:*' --reason "…"`;
   the operator approves it. `%R~` asks read-only; ask for nothing broader.
5. **Prove it** (§8).

## 5. Case 2 — a new standalone website (gCore web app, no WordPress)

The type is `webapp-gcore`: PHP on gCore without WordPress, a front controller in
the docroot, application code in `src/` outside it. Example domain `example.com`,
site id `example_com` (dots and hyphens become underscores).

1. **DNS**: A/AAAA records for the domain and `www.` to the master before step 2,
   or pass `--no-ssl` and run certbot later.
2. **Register**:
   ```bash
   sudo geodineum register example.com --new webapp-gcore --env staging --mail-domain example.com --dry-run
   sudo geodineum register example.com --new webapp-gcore --env staging --mail-domain example.com --yes
   ```
   Rows: docroot, `www-data` asserted in `geodineum-code` (reads gCore source),
   `/var/www/example.com/public_html/index.php` front controller and
   `/var/www/example.com/src/bootstrap.php` (gCore standalone entry), Apache vhost +
   `a2ensite` + `certbot --apache`, the manifest (site shape, holds and requires
   nothing), DKIM for the domain (`scripts/setup-mail-stack.sh`), the identity, the
   topology entity placed on this node, permissions `root:www-data 750/640`. Start on
   `staging`; promote with `sudo geodineum env set example_com production`.
3. **Its own PHP pool and user**:
   `sudo geodineum site pool example_com plan --kind standalone`, then `apply`, then
   `verify`. Apply also moves the credential to `web_example_com`.
4. **Code**: `gcore_init()` from `/opt/geodineum/gCore/gcore-standalone.php`
   (`src/bootstrap.php` shows it).
5. **Deploy**: the deploy orchestrator pulls only checkouts under
   `/opt/geodineum` (the core repos and the names in `/opt/geodineum/site-repos.conf`,
   each with its `geodeploy.yaml`); it never pulls `/var/www`. Ship the site's files
   into `/var/www/<domain>` with your own script (rsync, `root:www-data`
   `0750/0640`).
6. **Mail**: `geodineum mail records example.com` prints the DNS records to
   publish; then §9.
7. **Prove it** (§8).

## 6. Talk to the mesh

- **Send**: `XADD {<id>}:gnode:unified:<env> * id <uuid> t c c <command> ss <id> sn <node> ts <unix> p '{"_request_id":"<uuid>", …}'`.
- **Reply**: poll `{<id>}:res:<uuid>` (SET EX 10: poll at once).
- **Durable outcome**: a signed receipt on `{<id>}:gnode:receipts:<env>`
  (`receipt-stream.md`; pubkeys at `{geodineum}:gnode:receipt_pubkeys`).
- **Another service**: add `_rt <target>`; the daemon checks reach (§1) and routes
  to the target's placement. A site has no reader and is never a relay target.
  You never write into a foreign keyspace.

## 7. More keys? The grant loop

```bash
sudo geodineum grants request <id> '%R~{other}:some:*' --reason "…" [--ttl-hours 72]
sudo geodineum grants pending
sudo geodineum grants approve <request_id> [--patterns "…"]     # on the master
sudo geodineum grants deny <request_id> [--reason "…"]          # on the master
sudo geodineum grants show <id>        # decisions for <id> + its effective ACL
```

- `%R~<pattern>` is granted read-only, `%W~` write-only, a bare pattern read and
  write; nothing else passes.
- The request is data on `{geodineum}:gnode:grants:requests`; an alert goes through
  COMMS with Approve/Deny buttons; undecided requests auto-deny after the TTL.
- Ledger first: the decision lands on `{geodineum}:gnode:grants:ledger` before any
  `ACL SETUSER`. Details: `access-grants.md`.
- An approval stays through regrants until `grants revoke` (§2).

## 8. Prove it worked

| Question | Command |
|---|---|
| Registered? intent, placement, heartbeats, this host's files | `sudo geodineum status <id>` |
| The entity record | `sudo geodineum topology show <id>` |
| The topology consistent | `sudo geodineum topology verify` |
| Exactly the ACL you expect, and the grant ledger | `sudo geodineum grants show <id>` |
| Labels and reach | the `GNODE_TOPO_CAN_REACH` lines in Case 1, step 3; want `1 reach` |
| Heartbeat (app, daemon, scheduled, gcore-service) | `sudo geodineum status <id>` lists it; `systemctl list-timers 'geodineum-heartbeat@<id>.timer'` |
| The site's pool | `sudo geodineum site pool <id> verify` |
| This host's configuration for it | `geodineum status --config --site <id>` |
| HTTP | `curl -sI https://<domain>/ \| head -1` |
| Mail | `geodineum mail records <domain>`; `sudo geodineum comms test-send <id>`; `geodineum status comms` |

## 9. Notifications through COMMS

Each producer writes its own stream `{<id>}:gnode:comms:<env>`; COMMS scans
`{*}:gnode:comms:<env>`. No grant, no announcement.

```bash
sudo geodineum comms recipients <id> list
sudo geodineum comms recipients <id> set a@example.com [b@example.com]   # also: add, remove
sudo geodineum comms sender <id> show
sudo geodineum comms sender <id> set noreply@<domain> --name "<Name>"
sudo geodineum comms test-send <id> [--channel email|telegram]
```

Both edit `{<id>}:comms:config` and signal `settings.reload` on the site's stream,
which COMMS needs: it caches the config.

What silently swallows a message:
1. **Sender domain.** COMMS sends as a domain only when it is in
   `/etc/geodineum/mail/authorized-domains` (written by `setup-mail-stack.sh`, i.e.
   `register`'s mail row) or is the default sender (`GEODINEUM_DEFAULT_FROM`);
   otherwise it rewrites the sender to the default and warns. Publish the domain's
   records (`geodineum mail records <domain>`) before switching its sender.
2. **`min_priority`.** A recipient receives a message only when its priority is at
   or under the recipient's `min_priority`; 5 means everything.
3. **TLS**: unset `use_tls`/`smtp_tls` means plaintext to a loopback relay and TLS
   to anything else.

Accepted is not delivered: an `XADD` id means accepted. Delivery status mirrors to
`{<id>}:gnode:comms:status:<stream_id>`; check it on the first send of a new producer.

## 10. Tenant grouping (`--owner`)

`--owner` exists on NEW only: `sudo geodineum register acme_api --new daemon --owner acme --env production`.
It adds the id to `gnode:tenant:acme:sites`. List the group at daemon level:
`FCALL GNODE_TENANT_LIST_SITES 0 acme` (`gNode/daemon/functions/gnode_site.lua`).
Capability queries run on the constellation key and are not tenant-filtered:
`FCALL_RO GNODE_TOPO_QUERY 1 '{geodineum}:gnode:constellation' <lo> <hi> '<filters json>' '<opts json>'`.

## 11. What registering creates

| Thing | Where |
|---|---|
| ACL user | `gnode_client_<id>` |
| Credential | `/etc/geodineum/credentials/valkey_client_<id>.password` + `.owner` |
| Streams per DTAP environment, site-registry entry | `{<id>}:gnode:unified:<env>`, `gnode:sites:registry` (`GNODE_PROVISION_SERVICE`) |
| Topology entity and labels | `{<c>}:gnode:constellation` and its siblings (daemon tier) |
| Registration intent | `{<c>}:gnode:registrations` |
| Tenant membership (`--owner`) | `gnode:tenant:<owner>:sites` |
| Host footprint | `<root>/.geodineum/` (manifest, `.registered`), the type's rows |
| Ledger of what was created on this host | `/etc/geodineum/registrations/<id>.tsv` |

## 12. Decommissioning

```bash
sudo geodineum deregister <id> --dry-run       # the plan
sudo geodineum deregister <id>                 # remove it (data kept)
sudo geodineum deregister <id> --purge-data    # and the data registration created
```

The inverse of registering: intent, topology entity and placements, keys,
identity, then what registering created on this host from its ledger, newest
first, then a residue check. `gNode/scripts/deregister-service.sh` is the ValKey half.

## 13. Not built yet

- A CLI verb that shows labels or reach: use the raw calls in Case 1, step 3.
- Deploying a `/var/www` site with a push: the orchestrator does not pull websites.
- Issuing a credential for another node without the operator: today it is
  `register --node` + `credential add`.

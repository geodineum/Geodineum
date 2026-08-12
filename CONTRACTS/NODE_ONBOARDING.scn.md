# NODE ONBOARDING :: Machine → Constellation — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent joining a NEW machine (server, workstation, laptop, borrowed GPU box) to
> a live Geodineum constellation from COLD. TRUTH = code on disk
> (`gNode/scripts/constellation-setup.sh`, `node-exposure.sh`,
> `mint-node-identity.sh`, `install-gnode-service.sh`, `Geodineum/install.sh`,
> `gnode-daemon.service`, `daemon/src/integration/receipt.rs`) — re-verify on
> drift. Human twin: [[NODE_ONBOARDING]]. Sibling (workloads, not machines):
> [[SERVICE_ONBOARDING]]. Deep network ref: `docs/MULTI_NODE_DEPLOYMENT.md`.

## ::PRIME

```
NODE = a MACHINE on the VPN running a gNode daemon. SERVICE = a workload on a node.
  Add the machine here; add services with SERVICE_ONBOARDING. A node hosts many services.
Onboarding := Init master → Expand (master mints bundle) → Join (installer, node-local) →
  Expose → Verify. Rejoin after any disconnect = `systemctl start gnode-daemon`, NOTHING else.
MASTER-ONLY holds: ValKey admin cred, ACL/peer minting, function-library writes,
  provision-service. WORKERS have NO local ValKey — reach master ValKey over VPN
  10.66.0.1:47445. Worker daemon Wants= (not Requires=) valkey unit ⇒ restartable without it.
DELEGATED SERVICE: master `geodineum service new <n> --type T --env E --node <worker>`
  (mint + composed grants + hand-off print) → worker `geodineum credential add
  --service <n> --auth <printed> --group <printed>`. Taxonomy: [[SERVICE_ONBOARDING]].
INTERMITTENT NODES ARE FIRST-CLASS (SB-8.85): reclaim on every node, exposure-gated claim,
  bounded consumers, DELCONSUMER-self on graceful stop. Node loss = throughput cost, never
  correctness. EXPOSURE (willingness, _gh-matched) gates delivery, independent of capability.
```

## ::ANCHOR

```
VPN: WireGuard wg-geodineum, 10.66.0.0/24, master=10.66.0.1, workers=.2+; public UDP 51820
  (silent-drop unknown peers); ValKey :47445 bound 127.0.0.1 + master VPN IP ONLY, never public.
  fail2ban 3-strikes→permanent ban. Setup: constellation-setup.sh; boot drop-in orders ValKey
  After=wg-quick@ (VPN-bound ValKey must wait for the tunnel).
NODE-ID: unique per node = consumer name in shared groups. TWO daemons sharing an id CONTEND
  over the same PEL, don't load-balance. GNODE_NODE_ID in daemon.env; default = `hostname -s`
  on join, `master` standalone. Never reuse `master`.
EXPOSURE: GNODE_NODE_TYPE in daemon.env = comma set; daemon processes an entry if ANY member
  covers its _gh hint. Built-in: general|inference|gpu_compute|all. Custom hint needs
  daemon/config/nodes/<hint>.yaml on master else matches NOTHING. Manage: geodineum node
  show|expose <set>|add <hint>|remove <hint> (wraps node-exposure.sh show|set|add|remove).
  Effect on next `systemctl restart gnode-daemon`. remove never leaves it empty (→general).
BUNDLE (master `constellation expand <name> <ip:port>`): mints worker WG keypair + registers
  peer (next VPN IP, appends [Peer], hot-reload) + reads valkey_daemon.password +
  valkey_replica.password + mints per-node identity gnode_node_<name> (random 32-char pw,
  grants from acl-daemon-tier.rule — ONE definition, identity-only not scope) → base64
  BUNDLE-V2. SECRET (private key + creds). Fallback if mint fails: shared gnode_daemon login.
JOIN: wizard "Join constellation" + paste bundle (easiest) OR flag-driven
  `install.sh --constellation private --deploy-tier <web|full|compute|replica> --master-ip
  10.66.0.1 --yes` (pre-stage WG conf + valkey_daemon.password). --master-ip (or VALKEY_HOST)
  REQUIRED for non-standalone tiers. bootstrap.env gets VALKEY_HOST=<master>. --branch sets the
  git ref for ALL component repos.
TIERS (web·daemon·valkey): web=Y·N·N (minimal) | full=Y·Y·N (standard) | compute=N·Y·N
  (daemon-only, never exposed) | replica=Y·Y·local-replica (EXPERIMENTAL, no r/w split).
WORKER-UNIT REWRITE (install-gnode-service.sh, no local ValKey unit present): strip valkey
  dep, After=network.target network-online.target + Wants=wg-quick@wg-geodineum,
  StartLimitIntervalSec=0 (unbounded restart — master mid-reboot must not exhaust start limit).
  Shipped unit: After+Wants+PartOf=valkey-gnode.service (Wants not Requires).
RECEIPT SIGNER (daemon 1st start, receipt.rs load_or_generate_signer): writes
  /etc/geodineum/components/gnode-daemon/receipt_signing.key 0600 (gnode-owned component dir,
  private key never leaves node), publishes PUBLIC key HSET {geodineum}:gnode:receipt_pubkeys
  signer_id→<alg>:<pubkey_hex>. Non-fatal if unavailable. Override GNODE_RECEIPT_KEY_FILE.
FUNCTIONS: master WRITES Lua libraries; worker verify_functions() = READ-ONLY (FUNCTION LIST),
  reports gaps only. Worker install correctly states "libraries + admin cred stay on master".
RE-MINT (already-joined node lost its cred): master mint-node-identity.sh <name> [--rotate];
  idempotent, touches NO WireGuard/peer state. NEVER re-run `expand` on a live member (add-peer
  not idempotent: second [Peer], fresh IP, strands old peer).
```

## ::SEQUENCE (execute in order)

```
0 MASTER   sudo geodineum constellation init                       [idempotent; VPN + ValKey bind + fail2ban]
1 EXPAND   sudo geodineum constellation expand <name> <ip:port>    [master mints bundle — SECRET]
2 JOIN     node: install.sh → "Join constellation" + paste bundle  [node-local]
             OR install.sh --constellation private --deploy-tier <tier> --master-ip 10.66.0.1 --yes
3 EXPOSE   sudo geodineum node expose <set> ; sudo systemctl restart gnode-daemon
4 VERIFY   node: systemctl status gnode-daemon; journalctl (Stream discovery + Receipt signer ready);
             restart survives · master: topology HGETALL shows <name> · receipt_pubkeys has its signer ·
             geodineum constellation status (ValKey NOT exposed) · geodineum node show (exposure = role)
REJOIN     after ANY disconnect: sudo systemctl start gnode-daemon  [NO re-registration/re-mint/bundle]
```

## ::FAILURE_MODES

```
SHARED-NODE-ID: two daemons with the same id contend over one PEL, never load-balance —
  silent throughput loss. Always a unique id (hostname-s default); never reuse `master`.
EXPAND-ON-LIVE-MEMBER: re-running expand to reissue a credential appends a 2nd [Peer],
  allocates a fresh VPN IP, strands the old peer. Use mint-node-identity.sh instead.
CUSTOM-HINT-NO-ROUTING: exposing to a hint with no daemon/config/nodes/<hint>.yaml on the
  master ⇒ matches NOTHING, node silently idle. Warned by node-exposure.sh, not blocked.
WORKER-REQUIRES-VALKEY: a hard Requires=valkey-gnode on a worker (no local unit) makes the
  daemon un-restartable ("Unit not found"). The unit ships Wants=, and the worker rewrite
  strips the dep — never re-add Requires on a worker.
BOUNDED-START-LIMIT-ON-WORKER: default StartLimitBurst gives up for good when the master is
  mid-reboot. Worker rewrite sets StartLimitIntervalSec=0; keep it.
RECLAIM-STEALS-LIVE-WORK: min-idle threshold must exceed the slowest legitimate processing
  time, or reclaim transfers entries a busy node is still working. (30s floor.)
DELCONSUMER-WITH-PENDING: pruning a consumer that still holds entries discards them ("stuck"
  → "lost"). Sweep only removes idle + zero-pending; graceful stop reclaims first.
LOST-VALKEY-EXPOSURE-ON-PUBLIC: never bind ValKey off the VPN IP; `constellation status`
  flags a public-interface bind. Port 47445 stays VPN-only.
NODE-HOLDS-ADMIN-CRED: a node must never carry valkey.password or another node's signing key;
  those are master-only / node-local-private by design.
```

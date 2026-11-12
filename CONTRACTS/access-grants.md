# Access Grants — the ACL approval loop

A service asks for key patterns; an operator decides; the decision is a
ledger entry before it is an ACL change. Implementation `gNode/scripts/cli/grants.sh`.

## Flow

```
request  geodineum grants request <svc> <pattern...> [--reason ...] [--ttl-hours N]
         → {ns}:gnode:grants:requests (idempotent: identical pending request refused)
         <pattern> is read+write; %R~<pattern> read-only, %W~<pattern> write-only.
         Nothing else passes: a pattern can never carry another ACL rule.
notify   one COMMS message to the operator channel (resolve: GEODINEUM_GRANTS_SITE
         → COMMS_INBOUND_SITE, default geodineum, when it has a COMMS config
         → geodineum_com), type=alert (NEVER system —
         COMMS drops those), carrying Telegram Approve/Deny buttons via
         dispatch.reply_markup
decide   CLI: grants approve|deny <id>   (master; admin cred)
         Telegram: button press → {COMMS_INBOUND_SITE}:gnode:comms:inbound:{env}
         → grants watch applies it
timeout  auto-DENY after ttl (default 72 h), notified
```

## Invariants — each earned by a live failure

- **Ledger-then-apply.** The decision lands on `{ns}:gnode:grants:ledger`
  before any `ACL SETUSER`; an already-decided id is refused, so replay
  (watch reads from `0`) decides nothing twice.
- **Allowlist checked twice.** The Telegram receiver gates on
  `COMMS_ADMIN_IDS` before writing the inbound stream; `grants watch`
  checks the same list again — the stream is a ValKey key anyone with a
  grant on it could write. `GEODINEUM_GRANT_ADMINS` may narrow, never
  widen. No list → watch refuses to run.
- **Buttons, not links.** A capability URL is a bearer credential in a
  medium that forwards and link-prefetches; a callback carries no
  capability — Telegram reports the presser's id and it is checked here.
- **`ACL SAVE` after apply.** Without it the grant lives in memory and the
  next ValKey restart silently reverts it (this reverted three services
  once).

## The ledger is what a service holds

An approval adds its patterns to `gnode_client_<svc>` directly. A regrant of that
service (`onboard-service.sh --regrant`, or `geodineum register <path>` after its
manifest changed) resets the key patterns to the base and the manifest, then replays
every approval in force: per request the newest ledger action decides, and only
`approve` keeps its patterns (`gNode/scripts/cli/grants-ledger.sh`). A regrant that
cannot read the ledger refuses. `grants revoke <request_id>` ledgers a revoke; the
patterns leave the ACL at the service's next regrant. `grants show <svc>` puts the
ledger beside the effective ACL.

## Keys

`{ns}:gnode:grants:requests` · `{ns}:gnode:grants:ledger` (append-only) ·
inbound presses on `{COMMS_INBOUND_SITE}:gnode:comms:inbound:{env}`.

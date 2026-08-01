# SCN: access-grants

**Flow** request(idempotent-pending)→`{ns}:gnode:grants:requests` → COMMS alert (NEVER type=system — dropped) + `dispatch.reply_markup` buttons → decide CLI (master, admin cred) | Telegram press → `{COMMS_INBOUND_SITE}:gnode:comms:inbound:{env}` → `grants watch` → TTL 72h auto-DENY.

**Invariants** (each from a live failure): ledger-then-apply (`:grants:ledger` BEFORE SETUSER; already-decided refused → replay-safe, watch reads from 0) · allowlist ×2 (`COMMS_ADMIN_IDS` at receiver AND watch — inbound stream is writable data; `GEODINEUM_GRANT_ADMINS` narrows only; none → refuse) · buttons not capability-URLs (prefetch fires GETs) · `ACL SAVE` post-apply (memory-only grants reverted 3 services once).

**Notify-site resolve** GEODINEUM_GRANTS_SITE → bot's site if config exists → geodineum_com. Impl: gNode/scripts/cli/grants.sh.

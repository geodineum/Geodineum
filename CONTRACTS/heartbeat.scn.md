# SCN: heartbeat

**Key** `{<ns>}:gnode:heartbeat:<env>:<component>:<node>` · `gnode` LITERAL (never prefix-config) · SETEX 120, refresh ~60 (TTL=2×cadence: 1 miss survives, 2 = down) · absence IS down, no dereg.

**Value** `{"ts":u64,"pid":u32,"comp":str,"node":str}` — self-describing detached.

**node** = identity = `GNODE_NODE_ID` = consumer name = constellation entity id = **short hostname** (first dot-label). NEVER `master` — role ≠ identity; role lives at node_role dim 0. Pre-segment failure: all nodes → one key → last-writer-wins → dead daemon hides behind live peer's ts.

**Read** HGETALL `{ns}:gnode:constellation:entities` → node list (no SCAN) → GET per component×env×node → judge by ts ≤75s. Grant `~{geodineum}:gnode:*` covers all.

**Census** (update WITH form changes, same commit): gnode-daemon Rust `integration/heartbeat.rs` (canonical+tests) · COMMS Rust `main.rs::write_heartbeat` · gSchedule Rust `config.rs::k_heartbeat` · gFlow Node `engine/heartbeat.js` · Geodine PHP `pipeline_runner.php` · gShield Py `gshield-decide.py`. Reader: gCore `wp-hooks.php::gcore_fetch_component_health`.

4 languages, no shared code → form pinned HERE, per-writer literal tests (≡ field_names discipline).

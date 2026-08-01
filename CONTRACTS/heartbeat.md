# Component-Liveness Heartbeat

The shared "am I up" signal. Every long-running component writes one key;
the operator dashboard joins those keys against the constellation registry
to render per-node component health. Absence *is* the down signal — there
is no deregistration step, only expiry.

## The wire form

```
{<topology_ns>}:gnode:heartbeat:<env>:<component>:<node>
```

| Segment | Value | Rules |
|---|---|---|
| `topology_ns` | `geodineum` unless overridden | Brace-literal hash tag |
| `gnode` | **literal** | Never built from a configurable prefix — one env override would diverge a writer from every reader |
| `env` | DTAP environment (`production`, `testing`, …) | The component's own resolved environment |
| `component` | stable component name | `gnode-daemon`, `comms`, `gschedule`, `gflow`, `geodine`, `gshield` |
| `node` | the node's declared id | See below |

Value — JSON, self-describing when found detached from its key:

```json
{"ts": 1753900000, "pid": 1234, "comp": "comms", "node": "aesir"}
```

Write: `SETEX <key> 120 <value>`, refreshed ~every 60s. TTL is twice the
cadence: one missed refresh survives, two reads as down.

## The node segment

The node id is the node's **identity**: the same value as the daemon's
`GNODE_NODE_ID`, which is also its consumer-group consumer name and its
constellation entity id. Default and convention: **short hostname**
(first dot-label of the kernel hostname, `hostname -s`). Components with
no node configuration of their own derive exactly that.

It is a name, not a role. `master` belongs in `node_role`
(constellation schema dim 0), never in an identity slot — a role in an
identity slot renames the node when its role changes, and heartbeats,
consumer names and constellation entities all silently fork.

Why the segment exists: without it, every node in a constellation wrote
the same key and last-writer-won. A two-node estate could not say which
node a component ran on, and one dead daemon hid behind the other's
fresh `ts`.

## Reading

1. Node list: one `HGETALL {<ns>}:gnode:constellation:entities` — the
   registry every daemon re-asserts at startup. No `SCAN`.
2. Per component × env × node: direct `GET` on the key above.
3. Staleness is judged by `ts` (≤75 s = up), not by key presence alone.

The per-site ACL grant `~{geodineum}:gnode:*` covers both the registry
read and every heartbeat key.

## Writers (the census — update this table when adding one)

| Component | Language | Site |
|---|---|---|
| gnode-daemon | Rust | `gNode/daemon/src/integration/heartbeat.rs` (canonical helpers + literal-pinning tests) |
| Geodineum-COMMS | Rust | `src/main.rs` `write_heartbeat` |
| gSchedule | Rust | `src/config.rs` `k_heartbeat` |
| gFlow | Node.js | `engine/heartbeat.js` |
| Geodine | PHP | `workers/pipeline_runner.php` |
| gShield | Python | `scripts/gshield-decide.py` `_heartbeat_loop` |

Reader: `gCore/gcore-mu/wp-hooks.php` `gcore_fetch_component_health`.

Six writers in four languages cannot share code, so the wire form is
pinned **here** and each writer carries a test (or the reviewed literal)
against it — the same discipline as `utils::field_names` for the command
schema. If you change the form, change every row of the census and this
document in the same commit.

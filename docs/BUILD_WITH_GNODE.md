# Building with gNode

The orientation map: which canonical doc to read first, per system. This page
duplicates nothing — a copy is a future disagreement. Integrating end to end?
Work the checklist at the bottom; it includes the parts real onboardings forgot.

## The one mental model

Everything is stateless-yet-state-aware through shared ValKey. A service:

1. **authenticates** as its own ACL identity (`gnode_client_<name>`), granted
   least-privilege from its manifest;
2. **registers** as a geometric entity so others discover it by capability,
   not by name;
3. **speaks** by `XADD` to unified streams and polls `{site}:res:<id>` for
   replies — one wire format, whichever internal lane serves it;
4. **announces liveness** with a heartbeat key; absence *is* the down signal.

Nothing holds state in-process that another node would need.

## Where each system is documented

| System | Canonical source | Verify with |
|---|---|---|
| **Wire protocol & commands** | gNode `COMMAND_SCHEMA.md` — message format, field aliases, all commands, lane semantics | `describe` at runtime |
| **Integration contract** | gNode `CONTRACT.md` / `CONTRACT.scn.md` — what gNode provides/consumes | `geodineum daemon contract` |
| **Service registration & ACL** | `CONTRACTS/SERVICE_ONBOARDING.md` (this repo) — `.geodineum/` manifest, `onboard-service.sh`, `--profile`, `--environment` | `geodineum grants show <svc>`; entity in `{<svc>}:gnode:services:entities` |
| **Registration intent (derived)** | gNode `daemon/src/registration_intent.rs` — declare once, entity re-derived, 120 s reconcile | `HGETALL {ns}:gnode:registrations` |
| **Inter-service routing** | gNode `docs/architecture/INTER_SERVICE_ROUTING.md` — `_rt`/`_rr` relay, format translation | send with `_rt`, watch the target stream |
| **Format system** | gNode `COMMAND_SCHEMA.md` §Format — `register_format`, `detect_format`, `list_formats` | `list_formats` |
| **Tera templates** | gNode `COMMAND_SCHEMA.md` — `render_template`, `render_string`, template CRUD | `render_string` with an ad-hoc template |
| **Daemon configuration** | gNode `docs/operations/CONFIGURATION.md` | `config_get` |
| **Per-service config keyspace** | manifest `config:` section (`schemas/geodeploy-manifest.schema.yaml`, this repo); convention default `{site}:<name>:config:*` | read your keys |
| **Heartbeat / liveness** | `CONTRACTS/heartbeat.md` (this repo) — key form, node segment, writer census | your key appears within 60 s of start |
| **Deploy** | your `geodeploy.yaml` — triggers, build, dirty-tree; annotated reference: `services/hello-world/` (this repo) | push to main; the orchestrator does the rest |
| **CLI verbs** | manifest `cli:` section — verbs surface in `geodineum --help` | `geodineum --help` |
| **Native install** | manifest `install:`/`uninstall:`/`health_check` sections | `sudo geodineum service install <repo>/geodeploy.yaml` |
| **Backup** | manifest `backup:` section — keys, files, schedule; consumed by Geodineum-BAK | `geodineum bak status` |
| **Permissions model** | `CONTRACTS/permission-model.md` (this repo) + gNode `docs/operations/PERMISSIONS.md` | — |
| **Keyspace conventions** | `CONTRACTS/keyspace-model.md` (this repo) — hash-tag braces are load-bearing | — |
| **FCALL from any language** | gNode `docs/reference/FCALL_COOKBOOK.md` — polyglot examples | `FCALL_RO GNODE_SCHEMA_GET service` |
| **Tool catalogue & affordances** | `config/ecosystem_tools.yaml` (this repo) — `metadata.affordances`: how to ask any component what it does | `service_describe` on any tool entity |
| **Node onboarding (constellation)** | `CONTRACTS/NODE_ONBOARDING.md` (this repo) — nodes self-register at daemon start | `HKEYS {ns}:gnode:constellation:entities` |
| **Notifications (COMMS)** | Geodineum-COMMS `CONTRACT.md`; `geodineum comms contract` | `geodineum comms test-send` |
| **Signed receipts** | `CONTRACTS/receipt-stream.md` (this repo) | receipts stream after any keyed reply |
| **Extensions (signed)** | gNode `docs/writing-extensions.md` — handlers, Lua, mandatory re-signing | daemon log at load |

Where two documents overlap, **this repo's `CONTRACTS/` file wins** — those
are the cross-component contracts, updated in lockstep with code by rule.

## The full-integration checklist

Everything a first-class component declares. gSchedule shipped without the
last three and nobody noticed — that is why this list exists.

```
[ ] .geodineum/gnode_services.yaml   — onboarding manifest (ACL consumes/produces)
[ ] onboard-service.sh run           — WITH --profile and --environment; both
                                       omissions have silently mis-registered
                                       services (wrong vector / DTAP-gated out)
[ ] geodeploy.yaml: runtime.service  — unit name deploys restart
[ ] geodeploy.yaml: triggers + build — what redeploys you
[ ] config/<name>.service            — the unit itself (see gSchedule's as reference)
[ ] install:/uninstall:/health_check — native install: sudo geodineum service
                                       install <repo>/geodeploy.yaml
[ ] heartbeat writer                 — per CONTRACTS/heartbeat.md, and ADD
                                       YOURSELF TO ITS CENSUS in the same commit
[ ] COMMS config                     — {<name>}:comms:config if you notify humans
[ ] CONTRACT.md + CONTRACT.scn.md    — your own integration contract, both files
[ ] config: section                  — your config keyspace declared
[ ] cli: section                     — your verbs in geodineum --help
[ ] backup: section                  — what Geodineum-BAK preserves for you
```

## For an LLM picking this up

Read in this order: this file → gNode `CONTRACT.scn.md` (dense, complete) →
gNode `COMMAND_SCHEMA.md` for whatever you touch → this repo's `CONTRACTS/` file
for any cross-component surface. Runtime beats prose: `describe` returns
per-command schemas, `FCALL_RO GNODE_SCHEMA_GET <tier>` returns the live
capability schema, and `service_describe` returns any entity's affordances.
Numbers (dimension counts, command totals) are deliberately absent from prose
throughout this repo — fetch them from the published schemas; a number in
prose has no mechanism keeping it true.

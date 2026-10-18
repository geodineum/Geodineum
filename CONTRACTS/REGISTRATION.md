# Registration — one topology, one recipe per thing

> Register, check and deregister a node, the ecosystem components, a site, a
> service (daemon or headless app) and a service that is not Geodineum software,
> from this file alone. Agent twin: `REGISTRATION.scn.md`. Wire detail lives in
> gNode `CONTRACT.md` and `COMMAND_SCHEMA.md`; the ValKey identity and grants
> half of onboarding is `SERVICE_ONBOARDING.md`; joining a machine is
> `NODE_ONBOARDING.md`.

## 1. The model in one screen

A constellation has **one** topology: the key `{<c>}:gnode:constellation`
(default constellation `geodineum`). Everything that exists in it is an entity
of exactly one **shape**:

| Shape | Key | What it is | Registered by |
|---|---|---|---|
| node | 1 | a machine | the daemon on start; `topology register node` for a machine with no daemon |
| component | 2 | an ecosystem component (gNode, gCore, COMMS, ...) | `topology register components` |
| site | 3.1 | a website or web app; no process of its own | profile `web` |
| app | 3.2 | a headless application | profile `headless` |
| daemon | 3.3 | a service with its own process | profile `service`, `system` or `component` |
| component on node | 4.1 | a component running on a node | derived from a heartbeat |
| service on node | 4.2 | a service running on a node (a member of its ring) | derived from a heartbeat, or `--on` |

Three rules hold for every recipe below.

- **Declare by name.** You write words from the published vocabulary
  (`protocol: [gnode_stream]`, `node_role: observer`), never numbers. The daemon
  encodes them and refuses a word it does not know. The vocabulary is
  `gNode/daemon/config/topology_schema.yaml`.
- **Health is a heartbeat.** A running thing writes
  `{<c>}:gnode:heartbeat:<env>:<component>:<node>` (`SETEX` 120, contract in
  `heartbeat.md`). The registrar turns it into a placement and a health band.
  Older than 75 s is dead and the placement leaves the ring. A site has no
  process: its health is its **host daemon's** heartbeat, which is why a site is
  registered `--on <node>`.
- **Permission is labels.** An entity `holds` labels and `requires` labels of
  its callers. A caller reaches a target when it sits above it, holds what it
  requires and no deny is active. Anything undeclared is refused.

Routing is weighted round-robin over a service's ring; `capacity_weight: 0`
is a standby that serves only when the ring is empty.

### The manifest block

The declaration lives in the service's `.geodineum/gnode_services.yaml`. Every
generator (`register`, `new site`, `register`) writes it.

```yaml
profile: service            # fallback when there is no gnode: block
environment: production
gnode:
  constellation: geodineum  # default; the only place a manifest names its constellation
  shape: daemon             # site | app | daemon
  heartbeat: myservice      # component name in the heartbeat key
  holds: [internal]
  requires: [internal]
  peers: []                 # same-layer entities allowed to reach each other
  fundamentality: 0.3       # optional; the shape's default applies
  capacity_weight: 1        # 0 = standby
  axes: { protocol: [gnode_stream], service_scope: internal_api, domain: [compute] }
```

No `gnode:` block means the manifest's `profile:` decides: `web` is a site,
`headless` an app, `service`, `system` and `component` a daemon.

### Who runs what

Every command here that reads a credential needs `sudo`. Registration writes use
the daemon identity, so run them **on the master** (the ACL admin credential
exists nowhere else). Commands for another machine say so.

## 2. Node

A machine that runs the daemon registers itself when the daemon starts; joining
it is `NODE_ONBOARDING.md`. A machine that runs **no** daemon (an observer
laptop, an app box behind a tunnel) is declared by hand so that the heartbeats of
the services on it can become placements.

```bash
# on master: register
sudo geodineum topology register node laptop --role observer
#   --role observer|headless|edge|replica|full_node
#   --specialization general|inference|storage|compute|content   (optional)
#   --constellation <c>                                          (default geodineum)

# check
sudo geodineum topology show laptop
sudo geodineum status

# deregister
sudo geodineum topology deregister laptop
```

Writes one shape-1 entity. A node's health is its daemon heartbeat; a declared
daemon-less node is the name that its services' placements attach to.

## 3. Ecosystem components

The components (gNode, gCore, COMMS, ...) are declared in
`config/ecosystem_tools.yaml`, each with axes by name, `depends_on` and `requires`.
The installer registers them; re-run it after editing the file.

```bash
# on master: register or refresh every component
sudo geodineum topology register components

# check
sudo geodineum topology all          # SHAPE column: component
sudo geodineum topology show gNode

# deregister one, or all of one shape
sudo geodineum topology deregister gCore
sudo geodineum topology deregister --shape component --confirm
```

To add a component, append an entry to `ecosystem_tools.yaml` and register again.
A component's health is its `<component>:<node>` heartbeat, which also creates its
shape-4.1 placement on that node.

## 4. Site

A site is a website or web app: WordPress, static, PWA or a gCore web app.

```bash
# on master: new site, everything included (vhost, TLS, ACL, manifest, topology)
sudo geodineum register example.com --new website-wp --env production

# or the type-driven interview for any public type
sudo geodineum register example.com --new website-static --env production

# or an existing directory: scan, report, add what it lacks
sudo geodineum register /var/www/example.com --env production
```

A web site is placed on the node that registers it, so its health is that node's
daemon heartbeat. The topology primitive underneath (`geodineum topology register
service <id> [profile] [--manifest <path>] [--on <node>]`) is for repairing one
entity by hand, never the way to register.

Check and deregister:

```bash
sudo geodineum topology show example_com     # shape 3.1, placement example_com@<node>
sudo geodineum status                         # health = the host daemon's heartbeat
geodineum status example_com

sudo geodineum deregister example_com                  # topology, intent, keys, identity, and what registering created here
```

`geodineum deregister` is the one way a service leaves: its intent, its entity and placements in the constellation that holds it, its keys, its identity, and what registering created on this host (data only with `--purge-data`). `geodineum topology deregister <id>` is the primitive underneath it, for the topology entity alone.

## 5. Service: a daemon or a headless app

A daemon (shape 3.3) has its own system user and process. A headless app
(shape 3.2) is an application with no public site.

```bash
# on master: the type's rows, identity to heartbeat
sudo geodineum register myservice --new daemon --env production --yes
sudo geodineum register myapp --new app --port 8090 --env production --yes      # shape app
sudo geodineum register nightly --new scheduled --schedule daily --env production --yes

# an existing service: scan, report, add what it lacks
sudo geodineum register /srv/myservice --env production
```

A worker machine gets its identity from the master with
`register … --node <name>` (`SERVICE_ONBOARDING.md` section 3), then installs the credential
with `sudo geodineum credential add`.

Liveness: have the service write its own heartbeat (`heartbeat.md`), or put the
generic probe wrapper next to it (section 7). Each node that beats becomes a
placement; a second node running the same service joins the ring.

```bash
sudo geodineum topology show myservice      # shape 3.3, holds/requires, placements
sudo geodineum status                       # health, load, where it runs
sudo geodineum topology load myservice      # what the sampler measured, and its age

sudo geodineum deregister myservice
```

## 6. Declaring who may reach whom

Edit the manifest and register again; a re-registration keeps whatever the
daemon measured.

| Field | Meaning |
|---|---|
| `holds` | labels this entity carries |
| `requires` | labels a caller must hold to reach it |
| `peers` | same-layer entities allowed to reach each other |
| `fundamentality` | position inside its layer; edges point from the less to the more fundamental |

A TTL deny blocks one caller from one target without touching the manifest.
Reach is checked once per relayed command and fails closed. A refusal names its
reason: `undeclared`, `layer`, `env`, `label:<l>` or `deny`.

## 7. A service that is not Geodineum software

Any process counts: a database, a Python worker, a vendor binary. It needs
three things, none of which require changing it: a mesh identity, a declaration,
and a probe.

```bash
# on master: identity + manifest + topology entity (no runtime is installed)
sudo geodineum register billing --new custom --env production --yes

# on the node that runs it, from the Geodineum checkout: a heartbeat written only when the probe passes
sudo scripts/heartbeat/install-heartbeat.sh billing --probe unit:billing            # plan
sudo scripts/heartbeat/install-heartbeat.sh billing --probe unit:billing --apply    # act
```

Probe kinds: `unit:<systemd unit>`, `tcp:<host>:<port>`, `http:<url>`,
`pid:<pidfile>`, `cmd:</abs/path>`. The probe is the proof: no pass, no
heartbeat, no health. The component name given to the wrapper must equal the
manifest's `heartbeat:` (default: the service id).

Check and deregister as in section 5.

## 8. Verify

| Question | Command |
|---|---|
| What is registered, by shape | `sudo geodineum topology` or `sudo geodineum topology all` |
| One entity's stored record | `sudo geodineum topology show <id>` |
| Is it alive, where, how loaded | `sudo geodineum status` (`--json` for machines) |
| What the sampler measured | `sudo geodineum topology load [id]` |
| Is the topology internally consistent | `sudo geodineum topology verify` |
| Constellation counters | `sudo geodineum topology stats` |

## 9. Refusals and what they mean

| Message | Meaning and fix |
|---|---|
| `<axis> = <word> is not in the vocabulary` | The word is not in the shape's published vocabulary. Use a word from `topology_schema.yaml`, spelled as there. |
| `shape "<x>" is not one of site, app, daemon, component, node` | The manifest's `shape:` is not a shape word. |
| `profile '<x>' is not in topology_schema.yaml` | Use `web`, `headless`, `service`, `system` or `component`. |
| `capabilities by number are not axes` | A manifest still carries numbers. Declare `shape` and `axes` by name. |
| `4.2 places a service; <id> is shape 2` | `--on` or a placement was aimed at the wrong layer: only a site, app or daemon can be placed, and a component is placed by heartbeat. |
| `<node> is not a node` | `--on <node>` names something that is not a shape-1 entity. Register the node first (section 2). |
| `` `on` places a service; nodes and components are placed by heartbeat `` | Drop `--on` for anything that is not a site, app or daemon. |
| `constellation <c> is not served by this daemon` | The manifest names a constellation this daemon does not serve; fix `gnode.constellation` or serve it. |
| `ValKey URL carries no credential` | A daemon subcommand was run without `VALKEY_USER` and `GNODE_REDIS_AUTH_FILE`; use the CLI verbs, which supply them. |
| `cannot read admin credential ... run with sudo` | The topology verbs read a root-only credential. |
| `no placement` (on a relay) | The target is a site; sites have no reader and are never relay targets. |

## 10. Where each thing is written

| Thing | Written to |
|---|---|
| Entities, facet sets, axis indexes, edges, rings, labels | `{<c>}:gnode:constellation` and its `:`-suffixed siblings, by the daemon only |
| Liveness | `{<c>}:gnode:heartbeat:<env>:<component>:<node>`, by the thing itself or its probe |
| ValKey identity and streams | `SERVICE_ONBOARDING.md` |
| Registration intent (for re-derivation) | `{<c>}:gnode:registrations` |
| Site-local footprint | `<service root>/.geodineum/` |

Clients hold a read-only identity on the constellation key; only the daemon tier
writes it.

# REGISTRATION :: one topology, one recipe per thing — LLM Primer

> SCN primer (SPR + Semantic Anchors + Latent-Space Activation). Audience = an
> agent registering / checking / deregistering an entity on a live constellation
> from COLD. TRUTH = code on disk (`gNode/scripts/cli/{register,deregister,topology,status}.sh`,
> `gNode/daemon/src/tool_registration.rs`, `gNode/daemon/config/topology_schema.yaml`,
> `Geodineum/lib/{common,register,service-taxonomy}.sh`) — re-verify on drift.
> Human twin: [[REGISTRATION]]. Neighbours: [[SERVICE_ONBOARDING]] [[NODE_ONBOARDING]] [[heartbeat]].

## ::PRIME

```
ONE KEY per constellation: {<c>}:gnode:constellation (default c=geodineum). Entities, facet sets,
  axis indexes, edges, rings, labels all live under it; the daemon tier writes, clients read.
SHAPES: node 1 · component 2 · site 3.1 · app 3.2 · daemon 3.3 · component@node 4.1 · service@node 4.2
DECLARE BY NAME: words from topology_schema.yaml, never numbers; the daemon encodes, refuses unknown words.
MANIFEST: .geodineum/gnode_services.yaml  gnode:{constellation,shape,heartbeat,holds,requires,peers,
  fundamentality,capacity_weight,axes}; no block ⇒ manifest profile: (web→site, headless→app,
  service|system|component→daemon).
HEALTH := heartbeat {<c>}:gnode:heartbeat:<env>:<component>:<node> SETEX 120 → placement + band;
  >75 s stale = dead = off the ring. SITE health = its HOST DAEMON's heartbeat ⇒ register --on <node>.
ROUTING := weighted round-robin over a service's ring; capacity_weight 0 = standby (ring empty only).
PERMISSION := holds/requires labels + TTL deny; undeclared ⇒ refused (fail closed).
```

## ::ANCHOR (commands — all on the MASTER, sudo; every one verified against its script)

```
NODE      register  sudo geodineum topology register node <id> --role observer|headless|edge|replica|full_node
                    [--specialization general|inference|storage|compute|content] [--constellation <c>]
          (a daemon-running node registers itself at start — NODE_ONBOARDING)
COMPONENTS register sudo geodineum topology register components     (from config/ecosystem_tools.yaml; append entry + re-run to add)
SITE      register  sudo geodineum new site <domain> --env <e>  |  service new <d> --type website-wp|website-static|app-pwa|webapp-gcore --env <e>
                    |  register <id> --express|--yaml|--template … |  topology register service <id> web [--env <e>]
          bind host: gnode-daemon register-tools --tier service --site <id> --profile web --on <node>
                    (VALKEY_USER=gnode_daemon GNODE_REDIS_AUTH_FILE=…/valkey_daemon.password) — `--on` exists ONLY here
DAEMON    register  sudo geodineum service new <n> --type daemon|gcore-service --env <e> --yes  |  provision-service <n> + topology register service <n> service
APP       register  sudo geodineum topology register service <n> headless   (or manifest shape: app)
NON-GEO   register  sudo geodineum service new <n> --type custom --env <e> --yes ; on the node: scripts/heartbeat/install-heartbeat.sh <n>
                    --probe unit:<u>|tcp:<h>:<p>|http:<url>|pid:<file>|cmd:</abs> [--apply]  (plan by default; the probe is the proof;
                    component name == manifest heartbeat:)
CHECK     sudo geodineum topology [all|show <id>|load [id]|verify|stats] · sudo geodineum status [--json] · geodineum info <id> · geodineum list
DEREG     sudo geodineum deregister <id> [--remove-acl]   (streams, config, ACL, .geodineum/ — NOT the topology)
          THEN sudo geodineum topology deregister <id>    (entity, indexes, edges, placements)
          sudo geodineum topology deregister --shape site|app|daemon|component|node --confirm   (every entity of one shape)
```

## ::REFUSALS

```
"<axis> = <word> is not in the vocabulary"     → word not in the shape's vocabulary; read topology_schema.yaml
shape "<x>" is not one of site, app, daemon, component, node → manifest shape: word wrong
profile '<x>' is not in topology_schema.yaml    → web|headless|service|system|component
capabilities by number are not axes             → legacy numeric manifest; declare shape + axes by name
4.2 places a service; <id> is shape 2           → placement aimed at the wrong layer (only 3.x is placed; components by heartbeat)
<node> is not a node                            → --on names a non-shape-1 entity; register the node first
`on` places a service; nodes and components are placed by heartbeat → drop --on
constellation <c> is not served by this daemon  → gnode.constellation names a constellation this daemon does not serve
ValKey URL carries no credential                → daemon subcommand run bare; use the CLI verbs
cannot read admin credential … run with sudo    → topology verbs read a root-only credential
no placement (relay)                            → target is a site; sites are never relay targets
reach verdicts: undeclared | layer | env | label:<l> | deny
```

## ::TRAPS

```
`geodineum register <site>` = the INSTALLER's registrar (ACL+streams+.geodineum/); topology entity verbs are `geodineum topology register …`.
`geodineum deregister` leaves the topology entity: always follow with `topology deregister`.
A written manifest is a claim; the heartbeat probe is the proof.
Re-registration keeps what the daemon measured (derived slots are the sampler's).
```

## ::GRAPH

CO_LESSON: [[REGISTRATION]] [[SERVICE_ONBOARDING]] [[NODE_ONBOARDING]] [[heartbeat]] [[access-grants]]

# Multi-Node Deployment Guide

Deploy additional nodes that join an existing Geodineum constellation.

## Deployment Tiers

```
                          ┌──────────────────────────────────┐
                          │         MASTER SERVER             │
                          │                                    │
                          │   ValKey :47445 (VPN only)         │
                          │   gNode daemon (--node-id master)  │
                          │   All sites, all streams           │
                          │                                    │
                          └──────────┬───────────────────────┘
                                     │ WireGuard VPN
                                     │ (10.66.0.0/24)
                    ┌────────────────┼────────────────┐
                    │                │                 │
           ┌────────┴──────┐  ┌──────┴───────┐  ┌─────┴────────┐
           │   HEADLESS    │  │   REPLICA    │  │  FULL NODE   │
           │               │  │              │  │              │
           │  gCore + PHP  │  │  ValKey      │  │  gNode       │
           │  No daemon    │  │  (replica)   │  │  daemon      │
           │  No ValKey    │  │  + gNode     │  │  No local    │
           │               │  │  daemon      │  │  ValKey      │
           │  Streams via  │  │              │  │              │
           │  VPN directly │  │  Local reads │  │  Can take    │
           │               │  │  VPN writes  │  │  over on     │
           │  SMTP server, │  │              │  │  master fail │
           │  satellite    │  │  Content,    │  │              │
           │  sites, COMMS │  │  caching,    │  │  HA, infra,  │
           │               │  │  rendering   │  │  inference   │
           └───────────────┘  └──────────────┘  └──────────────┘
```

| Tier | Components | ValKey | gNode | Use Case |
|------|-----------|-------|-------|----------|
| **Headless** | gCore + services or standalone (COMMS, BAK) | None | None | Lightest. SMTP servers, satellite PHP sites, standalone components that just need stream access |
| **Replica** | Full stack + local ValKey replica | Local (read) + VPN (write) | Yes | Content-heavy. Caching, template rendering, topology queries at local speed. Ideal for serving sites with heavy read patterns |
| **Full node** | Full stack, no local ValKey | Remote via VPN | Yes | High availability. Full command processing, service discovery, can take over failing master's streams. For inference workers, distributed topologies |

ValKey is never exposed to the internet. All inter-node communication flows
through a WireGuard VPN (10.66.0.0/24). The only internet-facing port is
WireGuard's UDP port (51820), which is cryptographically silent - drops all
packets not signed by a known peer.

## Prerequisites

**Master server:** Working Geodineum installation.

**Worker server:**
- Ubuntu/Debian (or any OS - WireGuard runs on Linux, macOS, Windows, FreeBSD)
- Rust toolchain (cargo) for building the daemon
- Network reach to github.com (component code is cloned from the public
  repositories at install time and kept current by the deploy orchestrator;
  only credentials come from the master)

## Step 1: Add the Worker — on the master

```bash
# On the MASTER: the worker's id (its short hostname) and where the master reaches
# it for the WireGuard handshake (its public IP + 51820)
sudo geodineum node add worker1 203.0.113.50:51820 --tier compute
```

The first `node add` also sets up the mesh on the master (after a confirmation):
- installs WireGuard and creates `wg-geodineum` (10.66.0.1/24)
- binds ValKey to `127.0.0.1` + `10.66.0.1` (VPN only; one ValKey restart)
- deploys fail2ban (3 failed auth attempts → permanent ban)
- opens UDP 51820 (the WireGuard handshake only)

Every `node add` then mints the worker's WireGuard key and its own ValKey
identity, registers the peer at the lowest free VPN address, and writes the
bundle `~/worker1.geodineum-bundle` (`0600`; never printed). The bundle names
the constellations the master serves, so the worker serves the same ones. The
command prints what to run on each machine.

## Step 2: Join — on the worker

```bash
# Copy the bundle over a trusted channel
scp ~/worker1.geodineum-bundle <user>@203.0.113.50:      # on the MASTER

# On the WORKER
git clone -b <the master's branch> https://github.com/geodineum/Geodineum.git && cd Geodineum
sudo ./install.sh --join ~/worker1.geodineum-bundle --yes
```

The installer applies the bundle (tunnel, credentials, constellations, node id,
tier), deletes its copy, and converges the worker. The daemon starts and
declares the node into each constellation itself; there is no registration
step.

## Step 3: Verify

```bash
sudo geodineum status                      # on the master: the worker, fresh heartbeat
sudo geodineum topology show worker1       # shape 1, in each constellation it serves
journalctl -u gnode-daemon -f              # on the worker: stream discovery
geodineum constellation status             # the mesh; ValKey not on the public interface
```

## Managing the Constellation

```bash
# Add another worker
sudo geodineum node add worker2 <ip>:51820 --tier compute

# A machine with its own WireGuard key (an admin laptop)
sudo geodineum node add laptop roaming --pubkey "<its public key>"

# Remove a worker (stop its daemon first; prints what to run on the worker)
sudo geodineum node remove worker1

# Show the mesh
geodineum constellation status

# Tear down the mesh (revert to single-node)
sudo geodineum constellation close
```

## Node Types

Route commands to specialized nodes using the `_gh` field:

| Type | Routing | Use Case |
|------|---------|----------|
| `general` | Excludes inference/gpu hints | Default worker |
| `inference` | Only inference/ML commands | Dedicated ML server |
| `gpu_compute` | Only GPU tensor commands | GPU node |
| `all` | Processes everything | Dev/single-node |

```bash
# Route a command to an inference node
XADD {site}:gnode:unified:production * cmd predict params '{}' _gh inference
```

A node processes an entry only if its type covers the entry's `_gh` hint. This
is *exposure*: what a node is willing to do, independent of what it is capable
of. It is why an intermittent or partially-trusted node — a developer laptop, a
borrowed GPU box — can join without being handed load-bearing work. Give it
`inference` and it serves inference and nothing else, no matter how busy the
rest of the constellation is.

## Intermittent Nodes and Orphan Recovery

Nodes may leave without notice — a laptop sleeps, a network drops, a process is
killed. Ownership of an in-flight stream entry lives in the consumer group until
the entry is acknowledged, so an entry held by a node that vanished would, on
its own, never be redelivered.

Every node therefore periodically reclaims entries whose owner has gone idle
past a threshold, restricted to entries its own exposure covers — a node never
takes work it would not otherwise process. An entry orphaned by one node is
picked up by another that is exposed to it; node loss costs throughput, never
correctness.

Consumers are cleaned up in step: a node removes itself from its groups on
graceful shutdown, and a periodic sweep removes consumers that are idle with no
pending entries. A consumer still holding entries is never removed — that would
discard the entries — so a crashed node's work is reclaimed first and its
consumer entry disappears only once it is empty. The practical effect: you can
connect and disconnect a laptop all day and the group tracks live participants,
not the history of connections.

## Security Model

| Layer | Protection |
|-------|-----------|
| Network | WireGuard VPN - ValKey only on private `10.66.0.x` interface |
| Port 47445 | Not bound to public IP - unreachable from internet |
| Port 51820 (UDP) | WireGuard - cryptographically silent, drops unknown packets |
| Authentication | ValKey ACL - per-user permissions, 64-char hex passwords |
| Brute-force | fail2ban - 3 failed auth attempts → permanent ban |
| Encryption | WireGuard ChaCha20-Poly1305 - all traffic between nodes encrypted |

## Cross-Platform Workers

WireGuard runs on Linux, macOS, Windows, FreeBSD, iOS, and Android. The config
file format is identical. A developer can run a gNode worker on macOS connecting
to the Linux master over the VPN.

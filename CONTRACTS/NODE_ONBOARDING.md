# Node Onboarding — adding a machine to a constellation

> The ONE definitive document for joining a new **machine** (server,
> workstation, laptop, borrowed GPU box) to an existing Geodineum
> constellation. An agent (human or LLM) should be able to onboard a node
> end-to-end from this file alone. Machine-primer twin:
> `NODE_ONBOARDING.scn.md`. Deeper network reference: `docs/MULTI_NODE_DEPLOYMENT.md`.

## 0. Node vs service — the distinction this doc turns on

- A **node** is a **machine** that joins the constellation over the VPN and runs
  a gNode daemon (and optionally a web tier, a ValKey replica, …). This is the
  doc for onboarding one.
- A **service** is a **workload** that lives on a node and participates in the
  mesh (a site, a daemon, an API). Onboarding a service is a different job —
  see `SERVICE_ONBOARDING.md`.

You add the machine first (here), then add services to it (there). The two
never merge: a machine can host many services; a service always names a home
node.

## 1. Concepts (60 seconds)

- The constellation is a private **WireGuard VPN** (`10.66.0.0/24`). The
  **master** is `10.66.0.1`; workers are `10.66.0.2+`. ValKey listens on port
  `47445` bound to `127.0.0.1` + the master's VPN IP **only** — never the public
  internet. The sole internet-facing port is WireGuard's UDP `51820`, which
  drops every packet not signed by a known peer.
- **Only the master holds ValKey.** Worker daemons have **no local ValKey**;
  they reach the master's ValKey over the VPN (`10.66.0.1:47445`). A worker's
  systemd unit therefore `Wants=` (not `Requires=`) the ValKey unit, so a worker
  with no such unit is still restartable.
- A node's **id** is its unique identity and its **consumer name** in the shared
  stream groups. Two daemons must never share an id — they would contend over
  the same pending entries instead of load-balancing. Defaults to the host's
  short hostname; `master`/standalone uses `master`.
- A node's **exposure** is the set of work classes it is willing to process
  (`general`, `inference`, `gpu_compute`, `all`, or custom hints). Exposure is
  independent of capability: it is why an intermittent or partially-trusted node
  — a laptop, a borrowed GPU box — can join and serve only what you allow it.
- **Intermittent nodes are first-class.** Sleep, disconnect, and rejoin are
  normal (§7). Rejoining is just `systemctl start gnode-daemon` — never a
  re-registration.

## 2. Prerequisites

**Master:** a working Geodineum install, already initialized as a constellation
master (§3). The master alone holds the ValKey admin credential and mints
everything a node needs.

**New node:**
- Linux/macOS/Windows/FreeBSD (WireGuard is cross-platform; the daemon needs a
  Rust toolchain — `cargo` — to build).
- `wireguard-tools` installed.
- Network reach to `github.com` (component code is cloned from the public repos
  at install time; the master ships **credentials, never code**).
- The master's VPN IP (`10.66.0.1` by convention).

## 3. Get the bundle — one command on the master

Initialize the master once (idempotent; skips if already up):

```bash
# On the MASTER
sudo geodineum constellation init
```

Then enroll the new node in a single command. `expand` is the paved road — it
mints the worker's WireGuard keypair, registers the peer (assigns the next VPN
IP, appends the `[Peer]` block, hot-reloads the tunnel), and prints one base64
**bundle**:

```bash
# On the MASTER — <name> is the node's id; <ip:port> is where the master
# reaches it for the WireGuard handshake (its public IP + 51820).
sudo geodineum constellation expand mynode 203.0.113.50:51820
```

The bundle carries everything the node needs and **nothing it must guess**:

- the worker's WireGuard config (private key + master peer + assigned VPN IP);
- the shared daemon credential (`valkey_daemon.password`);
- the replica credential (`valkey_replica.password`), for a replica-tier node;
- a **per-node ValKey identity** — user `gnode_node_<name>` with its own password,
  minted from the daemon-tier ACL rule so the master can tell one node from
  another. (If the master cannot mint one, the node falls back to the shared
  `gnode_daemon` login and still works.)

The bundle contains a private key and live credentials — **treat it as a secret**
and copy it over a trusted channel.

**Manual alternative** (no bundle): `sudo geodineum constellation add-peer
<name> <worker_pubkey> <ip:port>` then `geodineum constellation show-config` —
the worker generates its own keypair and pastes the shown config. `expand`
collapses all of this into one step.

## 4. Run the join — on the new node

### Easiest — the guided installer

```bash
# On the NEW NODE
git clone https://github.com/geodineum/Geodineum.git
cd Geodineum
sudo ./install.sh
```

Choose **Join constellation**, pick the node's **tier** (below), and paste the
single-line bundle from §3 at the prompt. The installer decodes it, writes the
WireGuard config, brings the tunnel up, captures the credentials, and converges
the node.

### Flag-driven (scripted) join

Pre-stage the WireGuard config and the daemon credential, then:

```bash
# On the NEW NODE
sudo ./install.sh --constellation private --deploy-tier full \
    --master-ip 10.66.0.1 --yes
```

**Deploy tiers** — each names what the node *does*, along three axes (serves
web · runs a daemon · holds ValKey):

| Tier | Web | Daemon | Local ValKey | Use |
|------|-----|--------|--------------|-----|
| `web` | yes | no | no | Serves sites; reaches the master over the VPN. |
| `full` | yes | yes | no | Serves sites **and** processes commands. |
| `compute` | no | yes | no | Daemon only — no web, no PHP, no DB, never exposed. Inference/GPU workers. |
| `replica` | yes | yes | local replica | Local reads, VPN writes. **EXPERIMENTAL** (no read/write split yet). |

Joining any non-standalone tier requires the master's VPN IP: pass `--master-ip`
(or set `VALKEY_HOST`).

**What the installer converges on a worker:**

- `bootstrap.env` written with `VALKEY_HOST=<master-ip>` — no hand-editing.
- **No local ValKey** on `web`/`full`/`compute` — only `valkey-cli` client tools
  are built; all state lives in the master's ValKey over the VPN.
- Every component cloned and built (the daemon compiled with its signed
  extensions); the deploy orchestrator keeps them current from the public repos
  afterward.
- A **unique node id** — defaults to the host's short hostname; the wizard lets
  you override. The scripted path never reuses `master`.
- A **worker-aware systemd unit**: the local-ValKey dependency is stripped, the
  daemon is ordered after the WireGuard tunnel, and its restart limit is made
  unbounded (`StartLimitIntervalSec=0`) so a master mid-reboot can't exhaust the
  worker's start limit and give up for good.
- The daemon **started and enabled**, registering itself into the master's
  topology on first connect. No manual registration step.

On first start the daemon also **generates its own receipt signing key** at
`/etc/geodineum/components/gnode-daemon/receipt_signing.key` (`0600`, held only
by this node) and publishes the matching **public** key to
`{geodineum}:gnode:receipt_pubkeys` so any verifier can resolve receipts this
node signs. The private key never leaves the machine.

## 5. Set the node's exposure

Exposure is a **set** of work classes; the node processes a stream entry if any
member covers the entry's routing hint (`_gh`). Manage it with:

```bash
geodineum node show                          # current exposure + daemon state
sudo geodineum node expose inference,gpu_compute   # set the whole set
sudo geodineum node add sync                 # add one class
sudo geodineum node remove gpu_compute       # remove one (never leaves it empty)
```

Built-in exposures: `general` (default work), `inference`, `gpu_compute`, `all`.
Custom hints are allowed but need a routing config (`daemon/config/nodes/<hint>.yaml`
on the master), or the daemon treats them as matching nothing. Exposure is
written to `daemon.env` (`GNODE_NODE_TYPE`) and takes effect on the next restart:

```bash
sudo systemctl restart gnode-daemon
```

A laptop lending its GPU might be exposed only to `inference,gpu_compute` — it
then serves inference and nothing else, no matter how busy the rest of the
constellation is.

## 6. Verify (an agent should prove all five)

```bash
# On the NODE — daemon up, unique node id on the command line
systemctl status gnode-daemon
journalctl -u gnode-daemon -n 20      # expect "Stream discovery status: N sites"
                                      # and "Receipt signer ready: ... published to ..."

# Restart survives cleanly (proves the worker-aware unit)
sudo systemctl restart gnode-daemon && systemctl is-active gnode-daemon
```

```bash
# On the MASTER — the node appears in the live topology
sudo bash -c 'REDISCLI_AUTH=$(cat /etc/geodineum/credentials/valkey.password) \
  valkey-cli -p 47445 --no-auth-warning HGETALL "{geodineum}:gnode:topology:services"' \
  | grep -i mynode

# Its receipt signer is published (a field per live signer)
sudo bash -c 'REDISCLI_AUTH=$(cat /etc/geodineum/credentials/valkey.password) \
  valkey-cli -p 47445 --no-auth-warning HKEYS "{geodineum}:gnode:receipt_pubkeys"'
```

Check from either machine: `geodineum constellation status` (VPN up, peer count,
ValKey NOT exposed) and `geodineum node show` (exposure matches the role).

The five proofs: **(1)** daemon active with a unique id; **(2)** it consumes
streams as a distinct consumer (its node id in the group); **(3)** its receipt
signer is published; **(4)** it shows in the master's topology / heartbeat;
**(5)** a restart brings it straight back.

## 7. Intermittent and reconnect behavior

Nodes may leave without notice — a laptop sleeps, a network drops, a process is
killed. Ownership of an in-flight stream entry lives in the consumer group until
it is acknowledged, so an entry held by a node that vanished would, on its own,
never be redelivered. The constellation handles this so node loss costs
throughput, never correctness:

- **Reclaim on every node.** Every daemon periodically reclaims entries whose
  owner has gone idle past a threshold — this is a liveness property all nodes
  share, not a specialisation.
- **Exposure-gated claim.** Reclaim *reads* each orphan's routing hint first
  (`XPENDING` + `XRANGE`) and only claims entries its own exposure covers;
  entries it isn't exposed to are left for a node that can run them. A node never
  takes work it would not otherwise process.
- **Bounded consumers.** A node removes itself from its groups on graceful
  shutdown (`DELCONSUMER` self), and a periodic sweep prunes consumers that are
  idle **with zero pending entries** — never one still holding entries (that
  would discard them). A crashed node's work is reclaimed first; its consumer
  entry disappears only once empty.

The practical effect: **rejoining is just `sudo systemctl start gnode-daemon`.**
No re-registration, no re-minting, no bundle. You can connect and disconnect a
laptop all day and the group tracks live participants, not the history of
connections.

If a node lost its per-node credential (not a rejoin — an actual loss), re-mint
it on the **master** without disturbing the live peer:

```bash
# On the MASTER — credential half only; touches no WireGuard/peer state
sudo /opt/geodineum/gNode/scripts/mint-node-identity.sh mynode           # idempotent
sudo /opt/geodineum/gNode/scripts/mint-node-identity.sh mynode --rotate  # only if truly lost
```

(Never re-run `constellation expand` against a working member just to reissue a
credential — its add-peer step is not idempotent and would strand the old peer.)

## 8. What a node NEVER holds

- The **ValKey admin credential** (`valkey.password`) — master-only. ACL
  minting, peer registration, and service provisioning all happen on the master.
- **Another node's receipt signing key** — each node's private signing key is
  generated locally and never leaves it; only public keys are shared.
- The authority to **write function libraries.** The master owns the Lua
  function libraries; a worker's daemon only *verifies* them (read-only
  `FUNCTION LIST`) and reports any gaps. Expected, correct worker output states
  that libraries and the admin credential stay on the master.
- **Service ACL identities.** Minting a *service's* ValKey auth is master-only —
  `sudo geodineum provision-service <svc>` (see `SERVICE_ONBOARDING.md`).

## 9. Roadmap

Onboarding today assumes a node and then a service are added separately.
**SB-8.87** (service-type-aware onboarding) is the direction: the installer will
branch on a service taxonomy — public (Website / App / PWA) vs internal (Daemon /
Service / Custom) — so a granular, non-web node (ValKey + gNode only) becomes a
first-class default rather than a stripped-down site. It is not built yet;
today, join a tier (§4) and add services separately.

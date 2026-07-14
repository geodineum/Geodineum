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

## Step 1: Initialize the Master

```bash
# On the MASTER server
sudo geodineum constellation init
```

This:
- Installs WireGuard tools (if needed)
- Generates a keypair for the master
- Creates the `wg-geodineum` VPN interface (10.66.0.1/24)
- Binds ValKey to `127.0.0.1` + `10.66.0.1` (VPN only)
- Deploys fail2ban (3 failed auth attempts → permanent ban)
- Opens UDP 51820 in the firewall (WireGuard handshake only)

Note the **public key** shown in the output - the worker needs it.

## Step 2: Set Up the Worker

```bash
# On the WORKER server

# 1. Install WireGuard
sudo apt install wireguard-tools    # Linux
# Or: brew install wireguard-tools  (macOS)
# Or: download from wireguard.com   (Windows)

# 2. Generate a keypair
wg genkey | sudo tee /etc/wireguard/wg-geodineum.key | wg pubkey
# Save the public key output - the master needs it
```

## Step 3: Add the Worker to the Constellation

```bash
# On the MASTER server
sudo geodineum constellation add-peer worker1 "<worker_public_key>" "<worker_public_ip>:51820"
```

Then get the config the worker needs:

```bash
geodineum constellation show-config
```

This prints a complete WireGuard config file. Copy it to the worker.

## Step 4: Connect the Worker

```bash
# On the WORKER server

# 1. Save the config (replace WORKER_PRIVATE_KEY with your generated key)
sudo nano /etc/wireguard/wg-geodineum.conf

# 2. Start WireGuard
sudo systemctl enable --now wg-quick@wg-geodineum

# 3. Verify VPN connectivity
ping 10.66.0.1    # Should reach the master
```

## Step 5: Stage the Shared Daemon Credential

Every daemon in the constellation authenticates to the master's ValKey as
`gnode_daemon`. Copy the credential before installing so the installer can
pick it up:

```bash
# On the MASTER
sudo cat /etc/geodineum/credentials/valkey_daemon.password

# On the WORKER
sudo install -d -m 750 /etc/geodineum/credentials
echo -n "<paste_password>" | sudo tee /etc/geodineum/credentials/valkey_daemon.password >/dev/null
sudo chmod 640 /etc/geodineum/credentials/valkey_daemon.password
```

(The interactive wizard prompts for this instead; pre-staging is what makes
the fully flag-driven install below possible.)

## Step 6: Install Geodineum on the Worker

```bash
# On the WORKER server
git clone https://github.com/geodineum/Geodineum.git
cd Geodineum
sudo ./install.sh --constellation private --deploy-tier full \
    --master-ip 10.66.0.1 --yes --no-comms
```

That single command is the whole node setup. Component code is fetched from
the public GitHub repositories (the master ships credentials, never code) and
the installer converges everything a worker needs:

- **bootstrap.env** written with `VALKEY_HOST=<master-ip>` - no hand-editing.
- **No local ValKey**: only `valkey-cli` is built (client tools); all state
  lives in the master's ValKey over the VPN.
- **Every component cloned and built** (daemon compiled with its signed
  extensions); the deploy orchestrator keeps them updated from `main` every
  five minutes afterwards.
- **Unique node id**: defaults to the worker's hostname (the wizard prompts
  instead when run interactively). Two daemons must never share an id - they
  would contend over the same stream entries instead of load-balancing - so
  the flag-driven path never reuses `master`.
- **Worker-aware systemd unit**: the local-ValKey dependency is stripped, the
  daemon is ordered after the WireGuard tunnel, and the restart policy is
  unbounded so a master mid-reboot cannot exhaust the worker's start limit.
- **Daemon started and enabled**, registering itself into the master's
  topology on first connect.

Re-running the installer is idempotent: it re-pulls, re-asserts permissions,
and converges services rather than duplicating anything.

Expected (and correct) worker-tier output: Lua function libraries are managed
on the master, and the ValKey admin credential stays on the master by design;
the installer states both instead of failing.

## Step 7: Verify

```bash
# On the WORKER - daemon up, unique node id on the command line
systemctl status gnode-daemon
journalctl -u gnode-daemon -n 20   # expect "Stream discovery status: N sites"

# On the MASTER - the worker appears in the live topology
sudo bash -c 'REDISCLI_AUTH=$(cat /etc/geodineum/credentials/valkey.password) \
  valkey-cli -p 47445 --no-auth-warning HGETALL "{geodineum}:gnode:topology:services"' \
  | grep -i "<worker-hostname>"
```

Check from either server:
```bash
geodineum constellation status
```

## Managing the Constellation

```bash
# Add another worker
sudo geodineum constellation add-peer worker2 "<pubkey>" "<ip>:51820"

# Remove a worker
sudo geodineum constellation remove-peer worker1

# Show current state
geodineum constellation status

# Tear down entirely (revert to single-node)
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

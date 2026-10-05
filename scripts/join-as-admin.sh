#!/bin/bash
# join-as-admin.sh — enroll an admin workstation in the constellation mesh.
#
# What this is NOT: a constellation node. It installs no component, starts no
# daemon, registers no service and answers no command. A service registers only
# in its own site, and a laptop is not a site — so nothing here touches the
# topology. What it gives you is the mesh, the CLI and a credential, so one
# machine can operate the estate without an ssh session per node.
#
# Why it is not a --deploy-tier: every tier resolves to a component profile and
# the lightest of those still installs gNode-Client, gCore and a theme. An admin
# workstation wants none of them. Nothing is skipped here — there is nothing to
# skip.
#
# A laptop is a ROAMING peer. Two consequences the worker path gets wrong for it:
# no ListenPort (an ephemeral source port traverses whatever NAT it wakes up
# behind), and no Endpoint on the master's side — WireGuard learns the address
# from the first authenticated packet. Pass "-" as the endpoint to add-peer.
#
#   on the laptop:  sudo scripts/join-as-admin.sh --master-pubkey "<key>" \
#                        --master-endpoint "<aesir_public_ip>:51820" --vpn-ip 10.66.0.9
#   on the laptop:  sudo scripts/join-as-admin.sh --verify-only
#
# Idempotent: every step is a desired-state write, and an existing private key is
# never regenerated — that would silently orphan the peer entry on the master.
set -uo pipefail

WG_IFACE=${WG_IFACE:-wg-geodineum}
WG_NETWORK=${WG_NETWORK:-10.66.0}
WG_PORT=${GEODINEUM_WG_PORT:-51820}
MASTER_IP="${WG_NETWORK}.1"
VALKEY_PORT=${VALKEY_PORT:-47445}
WG_DIR=/etc/wireguard
KEY_FILE="$WG_DIR/${WG_IFACE}.key"
CONF_FILE="$WG_DIR/${WG_IFACE}.conf"
CRED_DIR=${CRED_DIR:-/etc/geodineum/credentials}
CRED_GROUP=${CRED_GROUP:-geodineum-creds}
CLI_LINK=/usr/local/bin/geodineum

MASTER_PUBKEY=""
MASTER_ENDPOINT=""
VPN_IP=""
NODE_NAME="$(hostname -s 2>/dev/null || echo admin)"
CLI_FROM=""
MODE=join
DRY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --master-pubkey)   MASTER_PUBKEY=${2:?needs a key}; shift 2 ;;
        --master-endpoint) MASTER_ENDPOINT=${2:?needs host:port}; shift 2 ;;
        --vpn-ip)          VPN_IP=${2:?needs an address}; shift 2 ;;
        --name)            NODE_NAME=${2:?needs a name}; shift 2 ;;
        --cli-from)        CLI_FROM=${2:?needs a path}; shift 2 ;;
        --verify-only)     MODE=verify; shift ;;
        --dry-run)         DRY=true; shift ;;
        -h|--help)         sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

hr() { printf '%s\n' "────────────────────────────────────────────────────────────────────────"; }
say() { printf '  %s\n' "$*"; }
die() { printf 'on the laptop: %s\n' "$*" >&2; exit 1; }

# --dry-run writes nothing, so it must not demand root: the point of a dry run
# is that you can read it before you trust it.
[[ $EUID -eq 0 || "$DRY" == "true" ]] || die "this needs sudo (it writes $WG_DIR and brings up an interface)"

# ───────────────────────────────────────────────────────────── verify
# Separated so it can run alone: after a reboot, after a network change, or to
# answer "is my laptop still on the mesh" without rewriting anything.
verify() {
    local rc=0
    hr; echo "on the laptop: is this workstation on the mesh?"

    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        say "interface            $WG_IFACE up"
    else
        say "interface            $WG_IFACE ABSENT"; return 1
    fi

    local hs
    hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -rn | head -1)
    if [[ -n "$hs" && "$hs" != "0" ]]; then
        say "last handshake       $(( $(date +%s) - hs ))s ago"
    else
        say "last handshake       NEVER — the master has not accepted this peer"
        say "                     on aesir: sudo geodineum constellation add-peer $NODE_NAME \"\$(cat $KEY_FILE.pub)\" -"
        rc=1
    fi

    if ping -c1 -W2 "$MASTER_IP" >/dev/null 2>&1; then
        say "master reachable     $MASTER_IP"
    else
        say "master reachable     NO ($MASTER_IP did not answer ping)"; rc=1
    fi

    [[ -x "$CLI_LINK" ]] && say "cli                  $CLI_LINK" || { say "cli                  ABSENT"; rc=1; }

    # The credential is never read aloud. Presence, mode and a PING are the whole
    # report: a token that works is proof, a token that is printed is a leak.
    local cred
    cred=$(find "$CRED_DIR" -maxdepth 1 -type f -name '*dash*' 2>/dev/null | head -1)
    if [[ -n "$cred" ]]; then
        say "credential           present, mode $(stat -c '%a %U:%G' "$cred")"
        if command -v valkey-cli >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1; then
            local cli; cli=$(command -v valkey-cli 2>/dev/null || command -v redis-cli)
            if REDISCLI_AUTH=$(<"$cred") "$cli" -h "$MASTER_IP" -p "$VALKEY_PORT" PING >/dev/null 2>&1; then
                say "valkey               PONG from $MASTER_IP:$VALKEY_PORT"
            else
                say "valkey               NO ANSWER from $MASTER_IP:$VALKEY_PORT"; rc=1
            fi
        fi
    else
        say "credential           ABSENT — see the scp line this script printed"
        rc=1
    fi
    hr
    [[ $rc -eq 0 ]] && echo "on the mesh. This workstation registers nothing and answers nothing." \
                    || echo "not yet complete — the lines marked above say what is missing."
    return $rc
}

[[ "$MODE" == verify ]] && { verify; exit $?; }

[[ -n "$MASTER_PUBKEY"   ]] || die "--master-pubkey is required (on aesir: geodineum constellation status)"
[[ -n "$MASTER_ENDPOINT" ]] || die "--master-endpoint is required, as <aesir_public_ip>:$WG_PORT"
[[ -n "$VPN_IP"          ]] || die "--vpn-ip is required; pick a free ${WG_NETWORK}.x the master has not assigned"

# ───────────────────────────────────────────────────── 1. dependencies
hr; echo "on the laptop: 1. the two tools this needs, and nothing else"
need=()
command -v wg      >/dev/null 2>&1 || need+=(wireguard-tools)
command -v valkey-cli >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1 || need+=(valkey-tools)
if [[ ${#need[@]} -gt 0 ]]; then
    say "missing: ${need[*]}"
    if [[ "$DRY" == "true" ]]; then
        say "[dry] would install them"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "${need[@]}" \
            || die "install failed — install ${need[*]} by hand and re-run"
        say "installed: ${need[*]}"
    else
        die "no apt-get here; install ${need[*]} by hand and re-run"
    fi
else
    say "wireguard-tools and a valkey client are present"
fi

# ─────────────────────────────────────────────────────── 2. keypair
hr; echo "on the laptop: 2. this workstation's key"
[[ "$DRY" == "true" ]] || install -d -m 0700 -o root -g root "$WG_DIR"
if [[ -s "$KEY_FILE" ]]; then
    say "keeping the existing key — regenerating it would orphan the master's peer entry"
else
    if [[ "$DRY" == "true" ]]; then
        say "[dry] would generate $KEY_FILE"
    else
        (umask 077; wg genkey > "$KEY_FILE") || die "wg genkey failed"
        chmod 0600 "$KEY_FILE"; chown root:root "$KEY_FILE"
        say "generated $KEY_FILE ($(stat -c '%a %U:%G' "$KEY_FILE"))"
    fi
fi
if [[ "$DRY" != "true" ]]; then
    wg pubkey < "$KEY_FILE" > "$KEY_FILE.pub" || die "wg pubkey failed"
    chmod 0644 "$KEY_FILE.pub"
    PUBKEY=$(<"$KEY_FILE.pub")
else
    PUBKEY="<generated-on-a-real-run>"
fi

# ──────────────────────────────────────────────── 3. the master's turn
hr; echo "on the laptop: 3. membership is granted by the master, never taken"
echo
echo "  on aesir:  sudo geodineum constellation add-peer $NODE_NAME \"$PUBKEY\" -"
echo
say "the trailing \"-\" means roaming: no Endpoint is written for this peer and"
say "WireGuard learns the address from the first packet this laptop sends."
echo
if [[ "$DRY" != "true" ]]; then
    read -r -p "  press enter once that has run on aesir (ctrl-c to stop here) " _
fi

# ────────────────────────────────────────────────────────── 4. tunnel
hr; echo "on the laptop: 4. the tunnel"
# Same shape as `constellation-setup.sh --show-config` with two deliberate
# differences: no ListenPort, because a roaming client wants an ephemeral source
# port, and AllowedIPs stays the constellation /24 so only estate traffic is
# tunnelled — a laptop must not route its whole life through aesir.
if [[ "$DRY" == "true" ]]; then
    say "[dry] would write $CONF_FILE for ${VPN_IP}/24 → ${MASTER_ENDPOINT}"
else
    tmp=$(mktemp); chmod 0600 "$tmp"
    {
        printf '[Interface]\n'
        printf 'Address = %s/24\n' "$VPN_IP"
        printf 'PrivateKey = %s\n\n' "$(<"$KEY_FILE")"
        printf '[Peer]\n# Constellation master\n'
        printf 'PublicKey = %s\n' "$MASTER_PUBKEY"
        printf 'Endpoint = %s\n' "$MASTER_ENDPOINT"
        printf 'AllowedIPs = %s.0/24\n' "$WG_NETWORK"
        printf 'PersistentKeepalive = 25\n'
    } > "$tmp"
    mv "$tmp" "$CONF_FILE"; chmod 0600 "$CONF_FILE"; chown root:root "$CONF_FILE"
    say "wrote $CONF_FILE ($(stat -c '%a %U:%G' "$CONF_FILE"))"

    systemctl enable --now "wg-quick@${WG_IFACE}" >/dev/null 2>&1 \
        || systemctl restart "wg-quick@${WG_IFACE}" >/dev/null 2>&1 \
        || die "wg-quick@${WG_IFACE} would not start — journalctl -u wg-quick@${WG_IFACE}"
    say "wg-quick@${WG_IFACE} $(systemctl is-active "wg-quick@${WG_IFACE}" 2>/dev/null)"
fi

# ───────────────────────────────────────────────────────────── 5. cli
hr; echo "on the laptop: 5. the CLI"
if [[ -n "$CLI_FROM" ]]; then
    if [[ -x "$CLI_FROM/geodineum" ]]; then
        [[ "$DRY" == "true" ]] && say "[dry] would link $CLI_LINK → $CLI_FROM/geodineum" || {
            ln -sfn "$CLI_FROM/geodineum" "$CLI_LINK"
            say "linked $CLI_LINK → $CLI_FROM/geodineum"
        }
    else
        say "no executable 'geodineum' under $CLI_FROM — skipping the link"
    fi
elif [[ -x "$CLI_LINK" ]]; then
    say "already present at $CLI_LINK"
else
    say "not installed. Clone the installer repo on this laptop and re-run with"
    say "  --cli-from /path/to/Geodineum-pro"
fi

# ────────────────────────────────────────────────────── 6. credential
hr; echo "on the laptop: 6. the credential — copied by you, never minted here"
if [[ "$DRY" == "true" ]]; then
    say "[dry] would create $CRED_DIR mode 0750, group $CRED_GROUP"
else
    install -d -m 0750 "$CRED_DIR" 2>/dev/null
    getent group "$CRED_GROUP" >/dev/null 2>&1 && chgrp "$CRED_GROUP" "$CRED_DIR" 2>/dev/null
    say "directory $CRED_DIR ($(stat -c '%a %U:%G' "$CRED_DIR" 2>/dev/null))"
fi
echo
say "a read-only identity is enough to operate from here. Copy the dashboard"
say "credential across yourself — this script never mints or prints one:"
echo
echo "  on aesir:       sudo cat /etc/geodineum/credentials/<dashboard-cred-file>   # you read it, nothing logs it"
echo "  on the laptop:  sudo install -m 0640 -o root -g $CRED_GROUP /dev/stdin \\"
echo "                    $CRED_DIR/geodineum-dash.password   # paste, then ctrl-d"
echo
say "scp would also work; either way the file is a bare token, so it is 0640 and"
say "it is passed as REDISCLI_AUTH=\$(<file), never on a command line."

# ────────────────────────────────────────────────────────── 7. verify
if [[ "$DRY" == "true" ]]; then
    hr; echo "dry run: nothing was written."
    exit 0
fi
verify
rc=$?
hr
echo "This workstation is a client of the mesh. It registered nothing, it holds no"
echo "writer lease, and no entity was added to the topology — so the estate's"
echo "liveness census and the load axis do not change because of it."
exit $rc

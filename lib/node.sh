#!/bin/bash
#
# Geodineum CLI — Node and Constellation Lifecycle
# =================================================
# The one route for each: a new constellation on a fresh machine, a node added to
# or removed from it, and what work a node takes (exposure). The primitives stay
# in gNode: constellation-setup.sh (WireGuard + per-node identity),
# cli/deregister.sh (topology), node-exposure.sh.
#
# Requires: common.sh sourced first
#

NODE_STATE_FILE="${GEODINEUM_CONFIG_ROOT}/components/gnode/constellation.state"
NODE_PEERS_DIR="${GEODINEUM_CONFIG_ROOT}/components/gnode/peers"

usage_node() {
    cat <<EOF
Usage: sudo geodineum node <add|remove|expose|show> ...

  add <name> <ip:port> [--tier web|full|compute|replica] [--yes]
        On the master. Enrolls a new machine: its WireGuard peer, its own ValKey
        identity, and a bundle file naming the constellations it will serve. Prints
        the command the new machine runs (install.sh --join <bundle>). The first
        node add sets up the constellation's mesh.
  add <name> <ip:port|roaming> --pubkey <key>
        A machine that made its own WireGuard key (an admin laptop: roaming): adds
        the peer only and prints the [Interface]/[Peer] lines for that machine.
  remove <name> [--dry-run] [--force]
        On the master. Removes the node from every constellation this master serves
        (entity and the placements on it), its WireGuard peer and its ValKey
        identity, then prints what to run on the node itself.
  expose [<hint[,hint...]>] | expose add <hint> | expose remove <hint>
        The work classes THIS node processes (general, inference, gpu_compute, all).
  show  This node's exposure and daemon state.

A new constellation starts on a fresh machine:  sudo ./geodineum constellation new <name>
EOF
}

_nd_vk() {
    REDISCLI_AUTH="$(<"${GEODINEUM_CREDENTIALS_DIR}/valkey.password")" \
        valkey-cli --no-auth-warning --raw -h "$VALKEY_HOST" -p "$VALKEY_PORT" "$@"
}

_nd_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ && "$1" != localhost && "$1" != master ]]; }

_nd_setup() {
    ND_SETUP="${GNODE_SCRIPTS}/constellation-setup.sh"
    [[ -x "$ND_SETUP" ]] || { log_error "gNode's constellation-setup.sh not found at ${ND_SETUP}"; exit 1; }
    # shellcheck source=/dev/null
    source "${GNODE_SCRIPTS}/cli/constellation.sh"
}

_nd_state() {
    [[ -r "$NODE_STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$NODE_STATE_FILE" | head -n1
}

cmd_node_add() {
    local name="" endpoint="" tier="" yes=false pubkey=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier) tier="${2:-}"; shift 2 ;;
            --pubkey) pubkey="${2:-}"; shift 2 ;;
            --yes)  yes=true; shift ;;
            -h|--help) usage_node; exit 0 ;;
            -*) log_error "Unknown option: $1"; exit 2 ;;
            *) if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$endpoint" ]]; then endpoint="$1"; else log_error "Unexpected argument: $1"; exit 2; fi; shift ;;
        esac
    done
    [[ -n "$name" && -n "$endpoint" ]] || { usage_node; exit 2; }
    _nd_name_ok "$name" || { log_error "'$name' is not a usable node id (lowercase letters, digits, -)"; exit 2; }
    [[ "$endpoint" == roaming && -n "$pubkey" ]] || [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[0-9]{2,5}$ ]] \
        || { log_error "Endpoint must be <public-ip-or-host>:<wireguard-port>, e.g. 203.0.113.7:51820 (roaming only with --pubkey)"; exit 2; }
    [[ -z "$pubkey" || "$pubkey" =~ ^[A-Za-z0-9+/]{42,43}=$ ]] || { log_error "--pubkey is not a WireGuard public key"; exit 2; }
    case "$tier" in ""|web|full|compute|replica) ;; *) log_error "--tier must be web, full, compute or replica"; exit 2 ;; esac
    require_sudo "Adding a node"
    _nd_setup
    [[ "$name" != "$(gnode_cli_node_id)" ]] || { log_error "'$name' is this node"; exit 2; }

    if [[ -z "$(_nd_state master_pubkey)" ]]; then
        echo ""
        log_step "First node: setting up the constellation's mesh on $(gnode_cli_node_id)"
        echo "  This binds ValKey to the WireGuard address as well as localhost and restarts it,"
        echo "  so every service on this machine reconnects once (a few seconds)."
        if [[ "$yes" != true ]]; then
            local answer
            read -r -p "  Continue? [y/N] " answer < /dev/tty
            [[ "${answer,,}" == y || "${answer,,}" == yes ]] || { log_info "Cancelled"; return 0; }
        fi
        "$ND_SETUP" --init-master || { log_error "Mesh setup failed; no node was added"; return 1; }
    fi

    if [[ -n "$pubkey" ]]; then
        "$ND_SETUP" --add-peer "$name" "$pubkey" "$endpoint" || return 1
        local ip master_ep
        ip="$(_nd_state "peer_${name}")"
        master_ep="$(curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'):${GEODINEUM_WG_PORT:-51820}"
        echo "  on ${name}:  /etc/wireguard/wg-geodineum.conf (the installer fills WORKER_PRIVATE_KEY from its own key):"
        echo "    [Interface]"
        echo "    Address = ${ip}/24"
        echo "    PrivateKey = WORKER_PRIVATE_KEY"
        echo "    [Peer]"
        echo "    PublicKey = $(_nd_state master_pubkey)"
        echo "    Endpoint = ${master_ep}"
        echo "    AllowedIPs = ${ip%.*}.0/24"
        echo "    PersistentKeepalive = 25"
        return 0
    fi
    local -a args=(--expand "$name" "$endpoint")
    [[ -n "$tier" ]] && args+=(--tier "$tier")
    "$ND_SETUP" "${args[@]}"
}

cmd_node_remove() {
    local name="" dry_run=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --force)   force=true ;;
            -h|--help) usage_node; exit 0 ;;
            -*) log_error "Unknown option: $1"; exit 2 ;;
            *) [[ -z "$name" ]] || { log_error "Unexpected argument: $1"; exit 2; }; name="$1" ;;
        esac
        shift
    done
    [[ -n "$name" ]] || { usage_node; exit 2; }
    _nd_name_ok "$name" || { log_error "'$name' is not a node id"; exit 2; }
    require_sudo "Removing a node"
    _nd_setup
    [[ "$name" != "$(gnode_cli_node_id)" ]] || { log_error "'$name' is this node; a node is removed from its master"; exit 2; }

    local -a cs entity_in=() beating=()
    mapfile -t cs < <(gnode_cli_constellations)
    local c sh placed=0
    for c in "${cs[@]}"; do
        sh="$(_nd_vk HGET "{$c}:gnode:constellation:entities" "$name" | python3 -I -c 'import json,sys
d = sys.stdin.read().strip()
print(json.loads(d).get("sh", "") if d else "")' 2>/dev/null)"
        case "$sh" in
            "") ;;
            1) entity_in+=("$c"); placed=$((placed + $(_nd_vk SCARD "{$c}:gnode:constellation:plon:${name}"))) ;;
            *) log_error "'$name' in {$c} is shape $sh, not a node: use  sudo geodineum deregister $name"; exit 2 ;;
        esac
        [[ "$(_nd_vk EXISTS "{$c}:gnode:heartbeat:all:gnode-daemon:${name}")" == 1 ]] && beating+=("$c")
    done
    local peer=false legacy=false acl=false
    local node_user="gnode_node_${name//-/_}"
    [[ -f "${NODE_PEERS_DIR}/${name}.conf" || -n "$(_nd_state "peer_${name}")" ]] && peer=true
    [[ "$(_nd_vk EXISTS "gnode:node:${name}:config")" == 1 || "$(_nd_vk SISMEMBER gnode:nodes:registry "$name")" == 1 ]] && legacy=true
    [[ -n "$(_nd_vk ACL GETUSER "$node_user" 2>/dev/null)" ]] && acl=true

    echo ""
    log_step "Remove node ${name} (constellations: ${cs[*]})"
    echo "  topology      ${entity_in[*]:-(none)}${entity_in:+ — with ${placed} placement(s) on it}"
    for c in "${entity_in[@]}"; do
        local p
        while IFS= read -r p; do [[ -n "$p" ]] && echo "                  ${p} in {$c} (that service keeps its registration, without this placement)"; done \
            < <(_nd_vk SMEMBERS "{$c}:gnode:constellation:plon:${name}")
    done
    echo "  WireGuard     $([[ $peer == true ]] && echo "peer present" || echo "(none)")"
    echo "  identity      $([[ $acl == true ]] && echo "ACL user ${node_user}" || echo "(none)")"
    echo "  legacy record $([[ $legacy == true ]] && echo present || echo "(none)")"
    if [[ ${#entity_in[@]} -eq 0 && $peer == false && $acl == false && $legacy == false ]]; then
        log_info "Nothing is known about node '${name}' here"
        return 0
    fi
    if [[ ${#beating[@]} -gt 0 && "$force" != true ]]; then
        log_error "${name}'s daemon is still heartbeating into {${beating[*]}}: it would declare itself again."
        echo "  Stop it first:   on ${name}:  sudo systemctl disable --now gnode-daemon"
        echo "  (or --force to remove it anyway; it re-appears when its daemon next starts)"
        return 1
    fi
    [[ "$dry_run" == true ]] && { log_info "Dry run — nothing changed"; return 0; }
    if [[ "$force" != true ]]; then
        local answer
        echo -en "\n  ${RED}Remove node ${name}?${NC} [y/${BOLD}N${NC}] "
        read -r answer < /dev/tty
        [[ "${answer,,}" == y || "${answer,,}" == yes ]] || { log_info "Cancelled"; return 0; }
    fi

    local failed=0 out
    for c in "${entity_in[@]}"; do
        if out="$(GNODE_TOPOLOGY_NAMESPACE="$c" "${GNODE_SCRIPTS}/cli/deregister.sh" "$name" 2>&1)" && [[ "$out" == *'"ok":true'* ]]; then
            log_success "Removed from {$c} with its placements"
        else
            log_error "Topology removal in {$c} failed: $out"; failed=1
        fi
    done
    if [[ $legacy == true ]]; then
        local t
        _nd_vk DEL "gnode:node:${name}:config" "gnode:node:${name}:health" "gnode:node:${name}:metrics" >/dev/null
        _nd_vk SREM gnode:nodes:registry "$name" >/dev/null
        while IFS= read -r t; do [[ -n "$t" ]] && _nd_vk SREM "$t" "$name" >/dev/null; done < <(_nd_vk --scan --pattern 'gnode:nodes:by_type:*')
        log_success "Legacy node record removed"
    fi
    "$ND_SETUP" --remove-peer "$name" || failed=1

    log_step "Residue"
    local residue=0
    for c in "${cs[@]}"; do
        [[ "$(_nd_vk HEXISTS "{$c}:gnode:constellation:entities" "$name")" == 1 ]] && { echo "  entity in {$c}"; residue=$((residue + 1)); }
        [[ "$(_nd_vk SCARD "{$c}:gnode:constellation:plon:${name}")" -gt 0 ]] && { echo "  placements on it in {$c}"; residue=$((residue + 1)); }
    done
    [[ -f "${NODE_PEERS_DIR}/${name}.conf" || -n "$(_nd_state "peer_${name}")" ]] && { echo "  WireGuard peer"; residue=$((residue + 1)); }
    [[ -n "$(_nd_vk ACL GETUSER "$node_user" 2>/dev/null)" ]] && { echo "  ACL user ${node_user}"; residue=$((residue + 1)); }
    [[ "$(_nd_vk EXISTS "gnode:node:${name}:config")" == 1 ]] && { echo "  legacy node record"; residue=$((residue + 1)); }
    [[ $residue -eq 0 ]] && log_success "none" || { log_error "${residue} residue item(s) — re-run to finish"; failed=1; }

    echo ""
    echo "  Then, on the node itself:"
    echo "    on ${name}:  sudo systemctl disable --now gnode-daemon wg-quick@wg-geodineum"
    echo "    on ${name}:  sudo rm -f /etc/wireguard/wg-geodineum.conf /etc/geodineum/credentials/valkey_node.password /etc/geodineum/credentials/valkey_daemon.password"
    echo "    on ${name}:  sudo geodineum constellation leave-replica    # only if it was a replica"
    echo "    (or uninstall Geodineum there entirely:  on ${name}:  sudo ./uninstall.sh --commit)"
    local bundle_home
    bundle_home="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
    [[ -f "${bundle_home}/${name}.geodineum-bundle" ]] && rm -f "${bundle_home}/${name}.geodineum-bundle" && echo "  (removed the unused bundle ${bundle_home}/${name}.geodineum-bundle)"
    return "$failed"
}

cmd_node_expose() {
    local script="${GNODE_SCRIPTS}/node-exposure.sh"
    [[ -x "$script" ]] || { log_error "node-exposure.sh not found under ${GNODE_SCRIPTS} — is gNode installed?"; return 1; }
    case "${1:-}" in
        add|remove)
            [[ $# -ge 2 ]] || { log_error "Usage: geodineum node expose $1 <hint>"; return 2; }
            require_sudo "Changing node exposure"
            "$script" "$1" "$2" ;;
        "")
            "$script" show
            echo ""
            echo "Enter the work classes this node should process, comma-separated."
            echo "Common: general (default work), inference, gpu_compute, all."
            local ans
            read -r -p "Exposure (blank to cancel): " ans
            [[ -z "$ans" ]] && { echo "Unchanged."; return 0; }
            require_sudo "Setting node exposure"
            "$script" set "$ans" ;;
        *)
            require_sudo "Setting node exposure"
            "$script" set "$1" ;;
    esac
    echo "Takes effect on the next daemon restart:  sudo systemctl restart gnode-daemon"
}

cmd_node() {
    local sub="${1:-show}"; shift || true
    case "$sub" in
        add)    cmd_node_add "$@" ;;
        remove) cmd_node_remove "$@" ;;
        expose) cmd_node_expose "$@" ;;
        show)
            local script="${GNODE_SCRIPTS}/node-exposure.sh"
            [[ -x "$script" ]] || { log_error "node-exposure.sh not found under ${GNODE_SCRIPTS}"; return 1; }
            "$script" show ;;
        -h|--help|help) usage_node ;;
        *) log_error "Unknown node subcommand: ${sub}"; usage_node; return 2 ;;
    esac
}

# A new constellation on a fresh machine: preflight, then the installer with the
# name. The mesh comes with the first `node add`; a one-machine constellation
# needs none.
cmd_constellation_new() {
    local name="" ; local -a pre=() inst=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --private-repo|--port|--data|--domain) pre+=("$1" "$2"); shift 2 ;;
            -h|--help)
                cat <<'EOF'
Usage: sudo ./geodineum constellation new <name> [preflight options] [installer options]

Run from the installer checkout on a fresh machine. Runs the preflight, then the
installer for a new constellation named <name> (a-z, 0-9, _). The mesh is set up
by the first `geodineum node add`.

  preflight options:  --private-repo <owner/repo>  --port <n>  --data <file>  --domain <d>
  installer options:  anything install.sh takes, e.g. --components gnode-daemon --yes
EOF
                return 0 ;;
            --yes|-y|--dry-run|--skip-build|--no-comms|--with-comms) inst+=("$1"); shift ;;
            -*) inst+=("$1" "${2:-}"); shift $(( $# > 1 ? 2 : 1 )) ;;
            *) [[ -z "$name" ]] || { log_error "Unexpected argument: $1"; return 2; }; name="$1"; shift ;;
        esac
    done
    [[ -n "$name" ]] || { log_error "Usage: sudo ./geodineum constellation new <name>"; return 2; }
    [[ "$name" =~ ^[a-z][a-z0-9_]{1,31}$ ]] || { log_error "Constellation name '$name': lowercase letter first, then a-z 0-9 _ (2-32)"; return 2; }
    require_sudo "Creating a constellation"
    local env="${GEODINEUM_CONFIG_ROOT}/components/gnode-daemon/daemon.env"
    if [[ -e "$env" ]]; then
        log_error "This machine already runs a gNode ($(grep -m1 '^GNODE_CONSTELLATIONS=' "$env" 2>/dev/null)); a constellation starts on a fresh machine"
        return 1
    fi
    local preflight="${GEODINEUM_CLI_ROOT}/scripts/constellation-preflight.sh" installer="${GEODINEUM_CLI_ROOT}/install.sh"
    [[ -x "$preflight" && -x "$installer" ]] || { log_error "Run this from the installer checkout (scripts/constellation-preflight.sh and install.sh)"; return 1; }

    log_step "1/2 Preflight"
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" "$preflight" --constellation "$name" "${pre[@]}" || { log_error "Preflight has failures; fix them and re-run"; return 1; }
    else
        "$preflight" --constellation "$name" "${pre[@]}" || { log_error "Preflight has failures; fix them and re-run"; return 1; }
    fi
    log_step "2/2 Install constellation ${name}"
    "$installer" --constellation-name "$name" "${inst[@]}" || return 1
    echo ""
    log_success "Constellation ${name} is up on $(hostname -s)"
    echo "  check it:       sudo geodineum status"
    echo "  add a machine:  sudo geodineum node add <name> <its-ip>:51820 [--tier compute]"
    echo "  add a service:  sudo geodineum register"
}

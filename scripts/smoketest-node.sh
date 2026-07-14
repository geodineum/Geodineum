#!/bin/bash
# =============================================================================
# smoketest-node.sh — verify a constellation node's link to the master ValKey
# =============================================================================
# Worker-side. Proves the full headless/full-node path end to end:
#   VPN reachable -> bootstrap.env correct -> authenticated ValKey over the VPN
#   -> gNode Lua functions present -> (optional) a read FCALL round-trips.
#
# Uses the daemon credential purely as a connectivity probe (it can PING,
# FUNCTION LIST, and FCALL). Copy it from the master first:
#   # master: sudo cat /etc/geodineum/credentials/valkey_daemon.password
#   # node:   install it to /etc/geodineum/credentials/valkey_daemon.password
#
# Usage (as root or a user that can read the credential):
#   sudo ./smoketest-node.sh [--master-ip <ip>] [--port 47445]
#                            [--user gnode_daemon] [--password-file <path>]
#                            [--site-id <id>]      # optional: also FCALLs health
# =============================================================================
set -uo pipefail

BOOTSTRAP="/etc/geodineum/bootstrap.env"
CREDS="/etc/geodineum/credentials"
MASTER_IP=""
PORT=""
USER_NAME="gnode_daemon"
PW_FILE="${CREDS}/valkey_daemon.password"
SITE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --master-ip)     MASTER_IP="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --user)          USER_NAME="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --site-id)       SITE_ID="$2"; shift 2 ;;
        -h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
        *)               echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Fill defaults from bootstrap.env
strip() { local v="$1"; v="${v//\"/}"; v="${v//\'/}"; echo "${v// /}"; }
if [[ -f "$BOOTSTRAP" ]]; then
    src_host="$(strip "$(grep -E '^VALKEY_HOST=' "$BOOTSTRAP" | tail -1 | cut -d= -f2)")"
    src_port="$(strip "$(grep -E '^VALKEY_PORT=' "$BOOTSTRAP" | tail -1 | cut -d= -f2)")"
    [[ -z "$MASTER_IP" ]] && MASTER_IP="$src_host"
    [[ -z "$PORT" ]] && PORT="$src_port"
fi
PORT="${PORT:-47445}"

CLI="$(command -v valkey-cli || command -v redis-cli || true)"

pass=0; fail=0
P() { echo "  [PASS] $*"; pass=$((pass+1)); }
F() { echo "  [FAIL] $*"; fail=$((fail+1)); }

echo "Geodineum node smoke test → master ${MASTER_IP:-<unset>}:${PORT}"
echo "────────────────────────────────────────────────────────────"

# 1. master IP known
[[ -n "$MASTER_IP" ]] && P "master IP resolved (${MASTER_IP})" \
    || F "master IP unknown — pass --master-ip or fix ${BOOTSTRAP}"

# 2. WireGuard interface present
if command -v wg >/dev/null 2>&1 && wg show 2>/dev/null | grep -q interface; then
    P "WireGuard interface up ($(wg show interfaces 2>/dev/null))"
else
    F "no WireGuard interface up (expected the constellation VPN)"
fi

# 3. VPN reachability
if [[ -n "$MASTER_IP" ]] && ping -c1 -W2 "$MASTER_IP" >/dev/null 2>&1; then
    P "master reachable over VPN (ping ${MASTER_IP})"
else
    F "master ${MASTER_IP} not pingable — VPN/firewall issue"
fi

# 4. bootstrap.env points at the master
if [[ -f "$BOOTSTRAP" ]] && grep -qE "^VALKEY_HOST=\"?${MASTER_IP}\"?$" "$BOOTSTRAP"; then
    P "bootstrap.env VALKEY_HOST → ${MASTER_IP}"
else
    F "bootstrap.env does not point at ${MASTER_IP} (check ${BOOTSTRAP})"
fi

# 5. credential present
if [[ -r "$PW_FILE" ]] && [[ -s "$PW_FILE" ]]; then
    P "credential present (${PW_FILE})"
else
    F "credential missing/unreadable: ${PW_FILE} — copy it from the master"
fi

# 6. valkey-cli available
[[ -n "$CLI" ]] && P "valkey-cli found (${CLI})" || F "valkey-cli/redis-cli not installed"

# 7-9. live ValKey checks (only if we have the pieces)
if [[ -n "$CLI" && -n "$MASTER_IP" && -r "$PW_FILE" ]]; then
    AUTH=( -h "$MASTER_IP" -p "$PORT" --user "$USER_NAME" -a "$(cat "$PW_FILE")" --no-auth-warning )

    pong="$("$CLI" "${AUTH[@]}" PING 2>/dev/null)"
    [[ "$pong" == "PONG" ]] && P "authenticated PING over VPN → PONG (user ${USER_NAME})" \
        || F "PING failed (auth/ACL/connectivity): '${pong}'"

    # FUNCTION LIST is daemon-level; a scoped per-service user may lack it.
    # PING already proved the link, so treat NOPERM as a soft skip.
    fout="$("$CLI" "${AUTH[@]}" FUNCTION LIST 2>&1)"
    if echo "$fout" | grep -qi 'noperm'; then
        echo "  [skip] FUNCTION LIST not permitted for ${USER_NAME} (scoped user) — link already proven by PING"
    elif echo "$fout" | grep -qi 'gnode'; then
        P "gNode Lua functions visible on master"
    else
        F "FUNCTION LIST returned no gNode functions: $(echo "$fout" | head -c 60)"
    fi

    if [[ -n "$SITE_ID" ]]; then
        hc="$("$CLI" "${AUTH[@]}" FCALL GNODE_MONITORING_HEALTH_CHECK 0 "$SITE_ID" 2>&1 | head -c 80)"
        echo "$hc" | grep -qiv 'error\|wrongpass\|noperm' && [[ -n "$hc" ]] \
            && P "FCALL health round-trip for site '${SITE_ID}'" \
            || F "health FCALL failed: ${hc}"
    fi
fi

echo "────────────────────────────────────────────────────────────"
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] && { echo "  RESULT: node is correctly wired into the constellation."; exit 0; }
echo "  RESULT: node NOT fully connected — see [FAIL] lines above."
exit 1

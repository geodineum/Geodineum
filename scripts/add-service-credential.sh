#!/bin/bash
# =============================================================================
# add-service-credential.sh — install a service's ValKey auth on this node
# =============================================================================
# Run on a constellation NODE. Takes the service name + auth that the master
# `geodineum register --node <node>` minted on the master, and writes the
# credential file gNode-Client reads, with the right owner/group/mode.
#
# No manual commands needed — pass flags, or run with no arguments and the
# script prompts for what it needs.
#
# Usage:
#   sudo ./add-service-credential.sh --service <name> --auth-file <file>
#   sudo ./add-service-credential.sh                      # prompts for both
#
# Options:
#   --service <name>   Service id (as registered on the master)
#   --auth-file <f>    The file register --node wrote on the master (removed after reading)
#   --auth <password>  The auth string itself (avoid: it lands in shell history)
#   --group <group>    Group that must read the file (default: www-data — the
#                      PHP/web reader; use the service's own group for daemons)
#   --creds-dir <dir>  Credentials directory (default: /etc/geodineum/credentials)
# =============================================================================
set -euo pipefail

CREDS_DIR="/etc/geodineum/credentials"
SERVICE=""
AUTH=""
GROUP="www-data"

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)   SERVICE="$2"; shift 2 ;;
        --auth)      AUTH="$2"; shift 2 ;;
        --auth-file) AUTH_FILE="$2"; shift 2 ;;
        --group)     GROUP="$2"; shift 2 ;;
        --creds-dir) CREDS_DIR="$2"; shift 2 ;;
        -h|--help)   sed -n '2,26p' "$0"; exit 0 ;;
        *)           die "Unknown argument: $1" ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "must run as root (writes under ${CREDS_DIR})"

# The file `geodineum register --node` wrote on the master: read, then removed.
if [[ -n "${AUTH_FILE:-}" ]]; then
    [[ -r "$AUTH_FILE" ]] || die "cannot read ${AUTH_FILE}"
    AUTH="$(tr -d '[:space:]' < "$AUTH_FILE")"
    shred -u "$AUTH_FILE" 2>/dev/null || rm -f "$AUTH_FILE"
fi

# Prompt for anything not supplied.
if [[ -z "$SERVICE" ]]; then
    read -r -p "Service name (from register --node on the master): " SERVICE
fi
[[ -n "$SERVICE" ]] || die "service name required"
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid service name '${SERVICE}' (allowed: letters, digits, _ -)"

if [[ -z "$AUTH" ]]; then
    read -r -s -p "Auth for ${SERVICE} (from register --node on the master): " AUTH; echo
fi
[[ -n "$AUTH" ]] || die "auth is empty"

# Pick an owner that exists: prefer gnode (the daemon user), else root.
OWNER="root"
id gnode >/dev/null 2>&1 && OWNER="gnode"
# Fall back to root group if the requested group is absent on this node.
getent group "$GROUP" >/dev/null 2>&1 || { echo "[!] group '${GROUP}' absent — using root"; GROUP="root"; }

install -d -m 0750 "$CREDS_DIR" 2>/dev/null || true
CRED_FILE="${CREDS_DIR}/valkey_client_${SERVICE}.password"

umask 077
printf '%s' "$AUTH" > "$CRED_FILE"
chown "${OWNER}:${GROUP}" "$CRED_FILE" 2>/dev/null || echo "[!] could not chown ${OWNER}:${GROUP} (left as $(stat -c '%U:%G' "$CRED_FILE"))"
chmod 0640 "$CRED_FILE"

echo ""
echo "[OK] Installed credential for service '${SERVICE}'"
echo "       file : ${CRED_FILE}"
echo "       owner: $(stat -c '%U:%G (%a)' "$CRED_FILE")"
echo "       user : gnode_client_${SERVICE}"
echo ""
echo "  Verify the connection to the master:"
echo "    sudo ./smoketest-node.sh --user gnode_client_${SERVICE} --password-file ${CRED_FILE}"

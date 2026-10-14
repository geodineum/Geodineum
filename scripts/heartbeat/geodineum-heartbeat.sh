#!/bin/bash
# Probe-gated liveness heartbeat (CONTRACTS/heartbeat.md): the key is written only when PROBE passes.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin

spec="${1:-}"
[[ -n "$spec" && -r "$spec" ]] || { echo "geodineum-heartbeat: cannot read spec '${spec}'" >&2; exit 2; }

COMPONENT="" CONSTELLATION=geodineum ENVIRONMENT=production NODE_ID=""
VALKEY_HOST=127.0.0.1 VALKEY_PORT=47445 VALKEY_USER="" VALKEY_PASSWORD_FILE="" PROBE=""
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    case "$key" in
        COMPONENT|CONSTELLATION|ENVIRONMENT|NODE_ID|VALKEY_HOST|VALKEY_PORT|VALKEY_USER|VALKEY_PASSWORD_FILE|PROBE)
            printf -v "$key" '%s' "$val" ;;
        *) echo "geodineum-heartbeat: ignoring unknown key '${key}' in ${spec}" >&2 ;;
    esac
done < "$spec"

[[ -n "$NODE_ID" ]] || NODE_ID="$(hostname -s)"
for req in COMPONENT PROBE VALKEY_USER VALKEY_PASSWORD_FILE; do
    [[ -n "${!req}" ]] || { echo "geodineum-heartbeat: ${req} missing in ${spec}" >&2; exit 2; }
done
for id in COMPONENT CONSTELLATION ENVIRONMENT NODE_ID; do
    [[ "${!id}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "geodineum-heartbeat: ${id} has illegal characters" >&2; exit 2; }
done
[[ -r "$VALKEY_PASSWORD_FILE" ]] || { echo "geodineum-heartbeat: cannot read ${VALKEY_PASSWORD_FILE}" >&2; exit 2; }

probe_fail() { echo "geodineum-heartbeat: ${COMPONENT} probe failed (${PROBE}): $1 - no heartbeat written" >&2; exit 1; }

kind="${PROBE%%:*}"; arg="${PROBE#*:}"
[[ "$PROBE" =~ ^https?:// ]] && { kind=http; arg="$PROBE"; }
case "$kind" in
    unit)
        systemctl is-active --quiet -- "$arg" || probe_fail "unit not active" ;;
    tcp)
        host="${arg%:*}"; port="${arg##*:}"
        [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || probe_fail "bad tcp spec"
        timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null || probe_fail "connect refused or timed out" ;;
    http)
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -- "$arg" 2>/dev/null)" || true
        [[ "$code" =~ ^[23][0-9][0-9]$ ]] || probe_fail "http status ${code:-none}" ;;
    pid)
        pid="$(head -c 16 -- "$arg" 2>/dev/null | tr -dc '0-9')"
        [[ -n "$pid" && -d "/proc/${pid}" ]] || probe_fail "process not alive" ;;
    cmd)
        [[ "$arg" == /* && -x "$arg" ]] || probe_fail "not an absolute executable path"
        timeout 10 "$arg" >/dev/null 2>&1 || probe_fail "command exited non-zero" ;;
    *) echo "geodineum-heartbeat: unknown probe kind '${kind}'" >&2; exit 2 ;;
esac

hb_key="{${CONSTELLATION}}:gnode:heartbeat:${ENVIRONMENT}:${COMPONENT}:${NODE_ID}"
payload="{\"ts\":$(date +%s),\"comp\":\"${COMPONENT}\",\"node\":\"${NODE_ID}\",\"probe\":\"${kind}\"}"
REDISCLI_AUTH="$(<"$VALKEY_PASSWORD_FILE")" \
    valkey-cli --no-auth-warning -h "$VALKEY_HOST" -p "$VALKEY_PORT" --user "$VALKEY_USER" \
    SETEX "$hb_key" 120 "$payload" >/dev/null \
    || { echo "geodineum-heartbeat: ${COMPONENT} probe passed but ValKey write failed" >&2; exit 3; }

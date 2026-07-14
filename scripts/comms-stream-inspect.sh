#!/usr/bin/env bash
# =============================================================================
# comms-stream-inspect.sh — inspect a site's Geodineum-COMMS streams + config
# =============================================================================
# Operator diagnostic. Shows, per DTAP environment, the comms stream state
# (length, consumer groups, newest messages), the site's channel config at the
# canonical {site}:comms:config key, and the daemon's recent handling of it.
#
# Usage (root, or a user that can read the ValKey credential):
#   sudo ./comms-stream-inspect.sh <site_id> [--port 47445] [--env staging]
#   e.g.  sudo ./comms-stream-inspect.sh staging_nierto_com
#
# site_id uses underscores (staging.nierto.com -> staging_nierto_com).
# =============================================================================
set -uo pipefail
BLD=$'\e[1m'; NC=$'\e[0m'; YEL=$'\e[33m'; GRN=$'\e[32m'; RED=$'\e[31m'
ok(){ echo "  ${GRN}✓${NC} $*"; }; warn(){ echo "  ${YEL}!${NC} $*"; }; err(){ echo "  ${RED}✗${NC} $*"; }

SITE=""; PORT="47445"; ONLY_ENV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --env)  ONLY_ENV="$2"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) SITE="$1"; shift ;;
    esac
done
[[ $EUID -eq 0 ]] || { err "run with sudo (needs the ValKey credential)"; exit 1; }
[[ -n "$SITE" ]] || { err "site_id required — e.g. staging_nierto_com"; exit 1; }

PW_FILE="/etc/geodineum/credentials/valkey.password"
[[ -r "$PW_FILE" ]] || { err "cannot read $PW_FILE"; exit 1; }
PW="$(cat "$PW_FILE")"
vk(){ valkey-cli -p "$PORT" -a "$PW" --no-auth-warning "$@" 2>/dev/null; }

ENVS=(production staging development test acceptance)
[[ -n "$ONLY_ENV" ]] && ENVS=("$ONLY_ENV")

echo "${BLD}== Comms streams for ${SITE} ==${NC}"
for env in "${ENVS[@]}"; do
    key="{${SITE}}:gnode:comms:${env}"
    [[ "$(vk EXISTS "$key")" == "1" ]] || continue
    echo "${BLD}── ${key} ──${NC}"
    echo "  XLEN: $(vk XLEN "$key")"
    grp="$(vk XINFO GROUPS "$key" | grep -c name || true)"
    if [[ "$grp" -ge 1 ]]; then ok "consumer group present (daemon consuming this env)"
    else warn "no consumer group — daemon is not consuming :${env} (non-prod is safe-by-non-consumption)"; fi
    echo "  ${YEL}newest 5 messages:${NC}"
    vk XREVRANGE "$key" + - COUNT 5 | sed 's/^/    /'
    echo
done

echo "${BLD}== Channel config ({${SITE}}:comms:config) ==${NC}"
cfg="$(vk GET "{${SITE}}:comms:config")"
if [[ -z "$cfg" ]]; then
    warn "empty — no channel configured yet (wp-admin → Notifications → Settings)"
else
    [[ "${cfg:0:1}" == "{" ]] && ok "plain JSON at the raw key (correct)" \
                              || err "does not start with '{' — looks type-tagged/ghosted"
    echo "$cfg" | sed 's/^/    /' | head -c 1200; echo
fi

echo; echo "${BLD}== Daemon handling of ${SITE} (last 5 min) ==${NC}"
journalctl -u geodineum-comms --since '5 min ago' --no-pager 2>/dev/null \
    | grep -iE "${SITE}|reload signal|dispatch|smtp|email|would send|dry|error" \
    | tail -30 | sed 's/^/  /'
echo "  (no lines above = daemon didn't process it in the window — expected if it landed"
echo "   on a :env with no consumer group, i.e. non-prod safe-by-non-consumption)"

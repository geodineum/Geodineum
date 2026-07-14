#!/bin/bash
set -euo pipefail

source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh" 2>/dev/null \
    || source "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/cli-helpers.sh" 2>/dev/null \
    || { SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/cli-helpers.sh"; }

GEODINEUM_REPO="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"

ORCHESTRATOR_PATH="${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/scripts/geodeploy-orchestrator"
CRON_PATTERN="geodeploy-orchestrator"

action="${1:-}"
# Accept all forms the usage string + the CLI dispatcher might pass:
#   on  / enable  / --enable   → turn cron on
#   off / disable / --disable  → turn cron off
# Pre-fix only --enable/--disable worked; direct invocation with the
# usage-advertised `on`/`off` fell through to the error case.
case "$action" in
    on|enable|--enable)
        if crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
            log_info "Auto-deploy cron already enabled"
            exit 0
        fi
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * ${ORCHESTRATOR_PATH}") | crontab -
        log_success "Auto-deploy cron enabled (*/5 * * * *)"
        ;;
    off|disable|--disable)
        if ! crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
            log_info "Auto-deploy cron already disabled"
            exit 0
        fi
        crontab -l 2>/dev/null | grep -v "$CRON_PATTERN" | crontab -
        log_success "Auto-deploy cron disabled"
        ;;
    *)
        echo "Usage: geodineum geodeploy <on|off>" >&2
        echo "       (also accepts: enable|disable|--enable|--disable)" >&2
        exit 2
        ;;
esac

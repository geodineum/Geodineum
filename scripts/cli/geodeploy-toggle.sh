#!/bin/bash
set -euo pipefail

source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh" 2>/dev/null \
    || source "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/cli-helpers.sh" 2>/dev/null \
    || { SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/cli-helpers.sh"; }

GEODINEUM_REPO="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"

ORCHESTRATOR_PATH="${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/scripts/geodeploy-orchestrator"
CRON_PATTERN="geodeploy-orchestrator"

action="${1:-}"
# on/off is the usage form; the CLI dispatcher may pass enable/disable or --enable/--disable.
case "$action" in
    -h|--help)
        echo "Usage: geodineum geodeploy <on|off>"
        echo ""
        echo "Enable or disable the auto-deploy cron (geodeploy-orchestrator)."
        exit 0
        ;;
    on|enable|--enable)
        if crontab -l 2>/dev/null | grep -c "$CRON_PATTERN" >/dev/null; then
            log_info "Auto-deploy cron already enabled"
            exit 0
        fi
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * ${ORCHESTRATOR_PATH}") | crontab -
        log_success "Auto-deploy cron enabled (*/5 * * * *)"
        ;;
    off|disable|--disable)
        if ! crontab -l 2>/dev/null | grep -c "$CRON_PATTERN" >/dev/null; then
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

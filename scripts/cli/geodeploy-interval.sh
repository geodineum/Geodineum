#!/bin/bash
set -euo pipefail

source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh" 2>/dev/null \
    || source "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/cli-helpers.sh" 2>/dev/null \
    || { SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/cli-helpers.sh"; }

GEODINEUM_REPO="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"

ORCHESTRATOR_PATH="${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/scripts/geodeploy-orchestrator"
CRON_PATTERN="geodeploy-orchestrator"

if [[ $# -eq 0 ]]; then
    echo "Usage: geodineum geodeploy interval <cron-schedule>" >&2
    echo "  Example: geodineum geodeploy interval '*/10 * * * *'" >&2
    exit 2
fi

schedule="$*"

# Basic 5-field validation
field_count=$(echo "$schedule" | awk '{print NF}')
if [[ "$field_count" -ne 5 ]]; then
    log_error "Invalid cron schedule: must be 5 fields (got ${field_count})"
    echo "  Example: '*/10 * * * *'" >&2
    exit 1
fi

if ! crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
    log_error "Auto-deploy cron not enabled. Run: geodineum geodeploy on"
    exit 1
fi

crontab -l 2>/dev/null | grep -v "$CRON_PATTERN" | { cat; echo "${schedule} ${ORCHESTRATOR_PATH}"; } | crontab -
log_success "Auto-deploy schedule updated: ${schedule}"

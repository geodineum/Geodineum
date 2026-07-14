#!/bin/bash
set -euo pipefail

# Standard handler preamble: source cli-helpers.sh from the canonical search
# path. Falls back to the in-repo location for dev/uninstalled runs.
source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh" 2>/dev/null \
    || source "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/cli-helpers.sh" 2>/dev/null \
    || { SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/cli-helpers.sh"; }

GEODINEUM_REPO="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"

ORCHESTRATOR="${GEODINEUM_REPO}/scripts/geodeploy-orchestrator"
LOG_FILE="${GEODINEUM_ROOT:-/opt/geodineum}/logs/auto-deploy.log"

# Cron status
cron_line=$(crontab -l 2>/dev/null | grep 'geodeploy-orchestrator' || true)
if [[ -n "$cron_line" ]]; then
    schedule=$(echo "$cron_line" | awk '{print $1,$2,$3,$4,$5}')
    log_success "Auto-deploy cron: ENABLED (${schedule})"
else
    log_warning "Auto-deploy cron: DISABLED"
fi

# Last run
if [[ -f "$LOG_FILE" ]]; then
    last_line=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
    if [[ -n "$last_line" ]]; then
        echo "  Last log entry: ${last_line}"
    fi
    line_count=$(wc -l < "$LOG_FILE")
    echo "  Log file: ${LOG_FILE} (${line_count} lines)"
else
    echo "  Log file: not found (${LOG_FILE})"
fi

# Managed repos
root="${GEODINEUM_ROOT:-/opt/geodineum}"
repo_count=0
for f in "${root}"/*/geodeploy.yaml; do
    [[ -f "$f" ]] && repo_count=$((repo_count + 1))
done
echo "  Managed repos: ${repo_count}"

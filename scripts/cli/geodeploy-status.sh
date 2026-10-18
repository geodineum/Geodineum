#!/bin/bash
set -euo pipefail

# Standard handler preamble: source cli-helpers.sh from the canonical search
# path. Falls back to the in-repo location for dev/uninstalled runs.
source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh" 2>/dev/null \
    || source "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/cli-helpers.sh" 2>/dev/null \
    || { SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/cli-helpers.sh"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: geodineum geodeploy status"
    echo ""
    echo "Show the auto-deploy cron state, schedule, and the last run's log tail."
    exit 0
fi

LOG_FILE="${GEODEPLOY_LOG:-${GEODINEUM_LOG_ROOT:-/var/log/geodineum}/deploy/auto-deploy.log}"
STAMP="$(dirname "$LOG_FILE")/.last-success"

# The sweep's own stamp is the evidence; the cron line may sit in root's crontab or the deploy user's.
cron_line="$( { crontab -l 2>/dev/null; sudo -n crontab -l 2>/dev/null; } | grep 'geodeploy-orchestrator' | grep -v '^#' | head -1 || true)"
last=""; [[ -r "$STAMP" ]] && last="$(<"$STAMP")"
age=-1; [[ -n "$last" ]] && age=$(( $(date +%s) - $(date -d "$last" +%s 2>/dev/null || echo 0) ))
if (( age >= 0 && age <= 900 )); then
    log_success "Auto-deploy: RUNNING (last successful sweep ${last}, $((age / 60)) min ago)"
elif (( age > 900 )); then
    log_warning "Auto-deploy: STALLED or OFF (last successful sweep ${last})"
else
    log_warning "Auto-deploy: no successful sweep recorded (${STAMP})"
fi
[[ -n "$cron_line" ]] && echo "  Schedule: $(echo "$cron_line" | awk '{print $1,$2,$3,$4,$5}')"

if [[ -r "$LOG_FILE" ]]; then
    echo "  Last log entry: $(tail -1 "$LOG_FILE")"
    echo "  Log file: ${LOG_FILE} ($(wc -l < "$LOG_FILE") lines)"
else
    echo "  Log file: not readable (${LOG_FILE})"
fi

# Managed repos
root="${GEODINEUM_ROOT:-/opt/geodineum}"
repo_count=0
for f in "${root}"/*/geodeploy.yaml; do
    [[ -f "$f" ]] && repo_count=$((repo_count + 1))
done
echo "  Managed repos: ${repo_count}"

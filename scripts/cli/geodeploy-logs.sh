#!/bin/bash
set -euo pipefail

LOG_FILE="${GEODINEUM_ROOT:-/opt/geodineum}/logs/auto-deploy.log"

lines=50
follow=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)     lines="$2"; shift 2 ;;
        -f|--follow) follow=true; shift ;;
        --help|-h)
            echo "Usage: geodineum geodeploy logs [-n <lines>] [-f]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$LOG_FILE" ]]; then
    echo "Log file not found: ${LOG_FILE}" >&2
    exit 1
fi

if [[ "$follow" == "true" ]]; then
    exec tail -f -n "$lines" "$LOG_FILE"
else
    exec tail -n "$lines" "$LOG_FILE"
fi

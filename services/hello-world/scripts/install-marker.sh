#!/bin/bash
# Idempotently write the install marker.
set -euo pipefail
STATE_DIR="${HELLO_STATE_DIR:-/var/lib/geodineum/hello-world}"
MARKER="$STATE_DIR/installed.marker"
printf 'installed_at=%s\nversion=0.1.0\n' "$(date -Iseconds)" > "$MARKER"
chmod 0640 "$MARKER"
echo "marker written: $MARKER"

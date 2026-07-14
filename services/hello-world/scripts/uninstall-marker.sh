#!/bin/bash
# Idempotently remove the install marker.
set -euo pipefail
STATE_DIR="${HELLO_STATE_DIR:-/var/lib/geodineum/hello-world}"
MARKER="$STATE_DIR/installed.marker"
if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    echo "marker removed: $MARKER"
else
    echo "marker already absent (idempotent no-op)"
fi

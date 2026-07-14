#!/bin/bash
# Health check — succeeds iff the marker file exists.
STATE_DIR="${HELLO_STATE_DIR:-/var/lib/geodineum/hello-world}"
MARKER="$STATE_DIR/installed.marker"
if [ -f "$MARKER" ]; then
    echo "healthy: $MARKER present"
    exit 0
fi
echo "unhealthy: $MARKER missing" >&2
exit 1

#!/bin/bash
# Idempotently create the service state directory.
set -euo pipefail
STATE_DIR="${HELLO_STATE_DIR:-/var/lib/geodineum/hello-world}"
mkdir -p "$STATE_DIR"
chmod 0750 "$STATE_DIR"
echo "ensured: $STATE_DIR"

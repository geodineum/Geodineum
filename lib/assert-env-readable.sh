#!/bin/bash
# ExecStartPre check, run as the unit's own user: fail when an existing env file is unreadable,
# which `EnvironmentFile=-` would otherwise skip silently.
# Usage: assert-env-readable.sh <env-file> [<env-file>...]

set -uo pipefail

_rc=0
_id="$(id -un 2>/dev/null || echo "uid=$(id -u)")"
_groups="$(id -Gn 2>/dev/null || echo '?')"

for _f in "$@"; do
    if [[ ! -e "$_f" ]]; then
        echo "env-preflight: ${_f} does not exist — continuing (declared optional). If this service needs settings from it, create it." >&2
        continue
    fi
    if [[ -r "$_f" ]]; then
        continue
    fi

    _owner="$(stat -c '%U:%G' "$_f" 2>/dev/null || echo '?:?')"
    _mode="$(stat -c '%a' "$_f" 2>/dev/null || echo '?')"
    echo "env-preflight: FATAL — ${_f} exists but is NOT readable by this service." >&2
    echo "env-preflight:   file is ${_owner} ${_mode}; this service runs as ${_id} (groups: ${_groups})." >&2
    echo "env-preflight:   every variable in that file is silently absent, which is how a working daemon serves nothing." >&2
    echo "env-preflight:   fix: chown the file to a group this service is in, or add the service user to ${_owner#*:}." >&2
    _rc=1
done

exit "$_rc"

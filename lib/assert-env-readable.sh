#!/bin/bash
#
# Preflight: a component must be able to READ the env files it was given.
#
# Run as ExecStartPre, so it executes under the unit's own User=/Group= and
# therefore answers the only question that matters: can THIS service, as the
# identity it will actually run under, read this file?
#
# Why this exists. On 2026-07-24 Geodineum-COMMS ran for 20 hours with no
# Telegram and no email. Nothing was broken in COMMS. A permission sweep had
# grouped geodineum-comms.env to `geodineum`, a group the geodineum-comms user
# is not in, so the file was unreadable — and because the unit loads it with
# `EnvironmentFile=-`, systemd skipped it without a word. The daemon started
# "successfully" with TELEGRAM_BOT_TOKEN simply absent. There was no error
# anywhere to find.
#
# The `-` is not itself wrong: an env file that is genuinely optional (a
# deployment using email but not Telegram) should not block startup by being
# absent. What must never be silent is a file that EXISTS and cannot be read.
# That is always a misconfiguration, and it is the case this script fails on.
#
#   absent      -> report and continue (may be deliberate)
#   unreadable  -> report loudly, exit 1, let Restart= retry and keep saying so
#   readable    -> silent
#
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

    # Unreadable. Say exactly who we are, what the file is, and what to change:
    # the 20-hour outage was expensive because none of that was anywhere.
    _owner="$(stat -c '%U:%G' "$_f" 2>/dev/null || echo '?:?')"
    _mode="$(stat -c '%a' "$_f" 2>/dev/null || echo '?')"
    echo "env-preflight: FATAL — ${_f} exists but is NOT readable by this service." >&2
    echo "env-preflight:   file is ${_owner} ${_mode}; this service runs as ${_id} (groups: ${_groups})." >&2
    echo "env-preflight:   every variable in that file is silently absent, which is how a working daemon serves nothing." >&2
    echo "env-preflight:   fix: chown the file to a group this service is in, or add the service user to ${_owner#*:}." >&2
    _rc=1
done

exit "$_rc"

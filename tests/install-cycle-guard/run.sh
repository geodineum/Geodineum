#!/bin/bash
# install-cycle-test.sh refuses a host that carries the protected-host marker, and the old production name. No root needed.
#   bash tests/install-cycle-guard/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/cycle-guard.XXXXXX")"; trap 'rm -rf "${SB:?}"' EXIT
awk '/^PROTECTED_MARKER=/' "$HERE/scripts/install-cycle-test.sh" > "$SB/fn.sh"
awk '/^protected_host\(\)/,/^}/' "$HERE/scripts/install-cycle-test.sh" >> "$SB/fn.sh"
# shellcheck source=/dev/null
source "$SB/fn.sh"
pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
r() { protected_host "$@" >/dev/null && echo refused || echo allowed; }

is "no marker, another name: allowed" "$(r "$SB/none" scratch-box)" allowed
: > "$SB/marker"
is "the marker refuses any name" "$(r "$SB/marker" scratch-box)" refused
is "the old production name still refuses" "$(r "$SB/none" aesir-solutions)" refused
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

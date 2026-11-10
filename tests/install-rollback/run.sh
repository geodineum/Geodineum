#!/bin/bash
# install.sh's rollback wrapper around fetch_component: a new clone is recorded in INSTALLED_REPOS, a pre-existing
# tree is not, and the original's return code comes through.
#   bash tests/install-rollback/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
D="$(mktemp -d)"; trap 'rm -rf "${D:?}"' EXIT
pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: got '$2', want '$3'"; fi; }
wrapper="$(awk '/# Track component fetches for rollback/{f=1} f{print} f&&/^    }$/{exit}' "$HERE/install.sh")"
[[ -n "$wrapper" ]] || { echo "  FAIL wrapper not found in install.sh"; exit 1; }
INSTALL_ROOT="$D"; INSTALLED_REPOS=()
get_install_dir() { echo "$1"; }
fetch_component() { [[ "$1" == broken ]] && return 3; mkdir -p "${INSTALL_ROOT}/$1"; return 0; }
eval "$wrapper"
fetch_component alpha; is "a new clone returns 0" "$?" 0
is "a new clone is recorded" "${INSTALLED_REPOS[*]}" "$D/alpha"
fetch_component alpha; is "an existing tree is not recorded again" "${#INSTALLED_REPOS[@]}" 1
rc=0; fetch_component broken || rc=$?; is "a failure returns the original's code" "$rc" 3
is "a failure records nothing" "${#INSTALLED_REPOS[@]}" 1
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

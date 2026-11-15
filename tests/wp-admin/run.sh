#!/bin/bash
# `geodineum wp <site> admin` under set -u: the site name must be known to the info view. Needs no root, no WordPress.
#   bash tests/wp-admin/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/wp-admin.XXXXXX")"; trap 'rm -rf "${SB:?}"' EXIT
mkdir -p "$SB/bin" "$SB/www/example.com"; : > "$SB/www/example.com/wp-config.php"
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/wp"; chmod 750 "$SB/bin/wp"

awk '/^_wp_login_url\(\)/,/^}/' "$HERE/geodineum" > "$SB/fn.sh"
awk '/^cmd_wp\(\)/,/^}/' "$HERE/geodineum" >> "$SB/fn.sh"
set +u
# shellcheck source=/dev/null
source "$SB/fn.sh"
_wp_resolve_root() { echo "$SB/www/example.com"; }
sudo() { shift 2; [[ "$1" == env ]] && shift; echo "admin_user"; }
log_error() { echo "$*" >&2; }
export PATH="$SB/bin:$PATH"

out="$( set -u; cmd_wp example_com admin info 2>&1 )"; rc=$?
pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
is "the admin info view runs under set -u" "$rc" 0
is "it names the site's domain" "$(grep -c 'Site:   example.com' <<< "$out")" 1
is "and gives a login URL on that domain" "$(grep -c 'https://example.com/wp-admin/' <<< "$out")" 1
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

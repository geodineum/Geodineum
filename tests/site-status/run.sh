#!/bin/bash
# The site status check against a throwaway ValKey and a fake curl: an outage needs two failures, starts and ends once,
# a preview copy is left alone, and the operator hears both ends. Needs python3 and valkey.
#   bash tests/site-status/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; D="$(mktemp -d)"; P=${SITE_STATUS_PORT:-47983}
trap 'valkey-cli -p $P shutdown nosave >/dev/null 2>&1; rm -rf "${D:?}"' EXIT
valkey-server --bind 127.0.0.1 --port $P --save '' --appendonly no --daemonize yes --dir "$D" --logfile "$D/v.log" >/dev/null
for _ in $(seq 50); do valkey-cli -p $P ping >/dev/null 2>&1 && break; python3 -c "import time;time.sleep(0.1)"; done
pass=0; fail=0
is() { [[ "$2" == "$3" ]] && { pass=$((pass+1)); echo "  ok   $1"; } || { fail=$((fail+1)); echo "  FAIL $1: got '$2', want '$3'"; }; }
mkdir -p "$D/www/shop.example" "$D/www/preview.test" "$D/www/blog.example"; touch "$D/www/shop.example/.site" "$D/www/preview.test/.site" "$D/www/preview.test/.viewkey"
printf '#!/bin/bash\ncat "%s/code"\n' "$D" > "$D/curl"; printf '#!/bin/bash\necho Result=success; echo ExecMainExitTimestamp=@1700000000\n' > "$D/sc"; chmod +x "$D/curl" "$D/sc"
go() { python3 -I "$HERE/scripts/site-status.py" --www "$D/www" --curl "$D/curl" --systemctl "$D/sc" --port $P --cred '' --alert-site alerts --env production --no-tls >/dev/null; }
k='{shop_example}:site:status'; v() { valkey-cli -p $P "$@"; }
alerts() { v XLEN '{alerts}:gnode:comms:production'; }
echo 200 > "$D/code"; go
is "first check: up" "$(v HGET "$k" state)" up
is "the backup's time" "$(v HGET "$k" backup_ms)" 1700000000000
is "a preview copy gets nothing" "$(v EXISTS '{preview_test}:site:status')" 0
is "a site without .site gets nothing" "$(v EXISTS '{blog_example}:site:status')" 0
echo 500 > "$D/code"; go
is "one failure is not an outage" "$(v HGET "$k" state)" up
is "and no alert" "$(alerts)" 0
go
is "two failures are" "$(v HGET "$k" state)" down
is "the operator hears" "$(alerts)" 1
from=$(v HGET "$k" since_ms)
go
is "a third changes nothing" "$(v HGET "$k" since_ms)" "$from"
is "no second alert" "$(alerts)" 1
is "no incident yet" "$(v XLEN '{shop_example}:site:incidents')" 0
echo 200 > "$D/code"; go
is "back up" "$(v HGET "$k" state)" up
is "one incident" "$(v XLEN '{shop_example}:site:incidents')" 1
is "from when it went down" "$(v XRANGE '{shop_example}:site:incidents' - + | sed -n 3p)" "$from"
is "the operator hears it ended" "$(alerts)" 2
echo 200 > "$D/code"; go
is "a healthy check after that: nothing new" "$(alerts)" 2
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

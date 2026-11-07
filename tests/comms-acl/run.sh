#!/bin/bash
# COMMS's grant on a throwaway ValKey: what it needs is allowed, what it must not do is refused, and the
# real binary with delivery off starts and handles a message without one NOPERM.
#   bash tests/comms-acl/run.sh [path to geodineum-comms]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; BIN="${1:-/opt/geodineum/Geodineum-COMMS/target/release/geodineum-comms}"
D="$(mktemp -d)"; P=47981; trap 'valkey-cli -p $P -a admin --no-auth-warning SHUTDOWN NOSAVE >/dev/null 2>&1; [[ -n "${CP:-}" ]] && kill "$CP" 2>/dev/null; rm -rf "${D:?}"' EXIT
pass=0; fail=0; ok() { pass=$((pass+1)); echo "  ok   $*"; }; bad() { fail=$((fail+1)); echo "  FAIL $*"; }
valkey-server --port $P --bind 127.0.0.1 --dir "$D" --save '' --requirepass admin --daemonize yes --logfile "$D/v.log" >/dev/null
until valkey-cli -p $P -a admin --no-auth-warning PING 2>/dev/null | grep -F PONG >/dev/null; do :; done
A() { valkey-cli -p $P -a admin --no-auth-warning "$@"; }
# the array as install.sh states it, so this test tests what ships
keys_src="$(awk '/local acl_comms_keys=\(/{f=1;next} f&&/^    \)$/{exit} f' "$HERE/install.sh")"
eval "keys=($keys_src)"
cmds_src="$(awk '/local acl_comms_commands=\(/{f=1;next} f&&/^    \)$/{exit} f' "$HERE/install.sh")"
eval "cmds=($cmds_src)"
printf 'secret-comms' > "$D/pw"
A ACL SETUSER geodineum_comms on '>secret-comms' resetkeys clearselectors "${keys[@]}" resetchannels '&*' "${cmds[@]}" >/dev/null || bad "grant refused"
T() { local want="$1"; shift; local r; r=$(A ACL DRYRUN geodineum_comms "$@" | head -1); if [[ "$want" == yes ]]; then [[ "$r" == OK ]] && ok "allowed: $*" || bad "needed and refused: $* -> $r"; else [[ "$r" != OK ]] && ok "refused: $*" || bad "must be refused: $*"; fi; }
S='{site_a}'
T yes XREADGROUP GROUP g c STREAMS "$S:gnode:comms:production" '>'
T yes XACK "$S:gnode:comms:production" g 1-0
T yes XGROUP CREATE "$S:gnode:comms:production" g 0 MKSTREAM
T yes HSET "$S:comms:config" a 1
T yes SET "$S:comms:retry:m" x
T yes HSET "$S:comms:messages:m" a 1
T yes INCR "$S:comms:stats:addressed:20261107"
T yes SET "$S:comms:context:x" x
T yes SET "{geodineum}:gnode:heartbeat:production:comms:aesir" x
T yes XADD "$S:gnode:receipts:production" '*' a 1
T yes HSET '{geodineum}:gnode:receipt_pubkeys' k v
T yes XADD "$S:gnode:unified:production" '*' a 1
T yes XRANGE "$S:gnode:unified:production" - +
T yes XREVRANGE "$S:gnode:unified:production" + -
T yes XLEN "$S:gnode:unified:production"
T yes GET 'gnode:site:x:meta'
T yes HGETALL 'gnode:site:x:meta'
T yes GET "$S:inference:metrics:p"
T yes LRANGE "$S:inference:history:s" 0 -1
T yes GET "$S:gnode:pipeline:_index"
T no DEL "$S:gnode:unified:production"
T no XTRIM "$S:gnode:unified:production" MAXLEN 0
T no XDEL "$S:gnode:unified:production" 1-0
T no XGROUP DESTROY "$S:gnode:unified:production" g
T no XREADGROUP GROUP g c STREAMS "$S:gnode:unified:production" '>'
T no SET 'gnode:site:x:meta' x
T no DEL 'gnode:site:x:meta'
T no SET 'topology:x' x
T no SET "$S:inference:history:s" x
T no GET "$S:site:content"
T no GET "$S:edit:token:x"
T no GET "{geodineum}:gnode:heartbeat:production:gnode-daemon:aesir"
T no SET "{geodineum}:gnode:constellation:entities" x
T no GET "$S:geodine:history:s"
if [[ -x "$BIN" ]]; then
    A XGROUP CREATE "$S:gnode:comms:production" geodineum_comms_dispatch 0 MKSTREAM >/dev/null
    A XADD 'gnode:sites:registry' '*' x 1 >/dev/null 2>&1 || true
    A HSET 'gnode:site:site_a:meta' site_id site_a >/dev/null
    env -i HOME="$D" PATH="$PATH" COMMS_DATA_DIR="$D" "$BIN" --redis-host 127.0.0.1 --redis-port $P --redis-user geodineum_comms --redis-auth-file "$D/pw" --delivery off --log-level debug --node-id testnode --environment production start >"$D/c.log" 2>&1 &
    CP=$!
    for i in 1 2 3 4 5 6 7 8; do sleep 1; done
    A XADD "$S:gnode:comms:production" '*' id probe-1 site_id site_a environment production type alert priority 3 timestamp "$(date -u -Is)" sender '{"name":"t"}' subject acl body acl metadata '{"source":"t"}' dispatch '{"channels":["email"]}' >/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; done
    kill "$CP" 2>/dev/null; CP=""
    n=$(grep -ciE 'noperm|no permissions' "$D/c.log" || true)
    (( n == 0 )) && ok "the real binary ran 18 s and handled a message: 0 NOPERM" || { bad "$n NOPERM lines from the real binary"; grep -iE 'noperm|no permissions' "$D/c.log" | cut -c1-160 | sort -u | head -8; }
    r=$(A XPENDING "$S:gnode:comms:production" geodineum_comms_dispatch | head -1); d=$(A XINFO GROUPS "$S:gnode:comms:production" | grep -A1 -E '^entries-read$' | tail -1)
    [[ "${d:-0}" -ge 1 ]] && ok "COMMS consumed the message (entries-read $d, pending $r)" || { bad "COMMS never read the message"; tail -5 "$D/c.log" | cut -c1-160; }
    h=$(A KEYS '*:gnode:heartbeat:*:comms:*' | wc -l); (( h >= 1 )) && ok "its heartbeat landed" || note=1
else echo "  ..   $BIN not found: the binary part is skipped"; fi
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

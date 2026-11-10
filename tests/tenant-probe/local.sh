#!/bin/bash
# on a dev box, as yourself: the tenant probe's ValKey layer on a throwaway ValKey
# (:47998) with two sites shaped like onboarding shapes them. Green first; then one ACL is widened
# and the probe MUST go red (a probe that cannot fail proves nothing). No sudo, no live keys.
#   bash tests/tenant-probe/local.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT=47998
W="$(mktemp -d)"; chmod 0750 "$W"
cleanup() { REDISCLI_AUTH="$(cat "$W/valkey.password" 2>/dev/null)" valkey-cli --no-auth-warning -p $PORT shutdown nosave >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1 ($2)"; else echo "  FAIL $1: expected $3, got $2"; fail=1; fi; }
umask 077
for u in valkey valkey_client_a_nl valkey_client_b_nl; do head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$W/$u.password"; done
mkdir -p "$W/state"
valkey-server --port $PORT --save '' --appendonly no --daemonize yes --dir "$W" --logfile "$W/valkey.log" >/dev/null
for _ in $(seq 20); do valkey-cli -p $PORT ping >/dev/null 2>&1 && break; sleep 0.5; done
valkey-cli -p $PORT ACL SETUSER default on ">$(<"$W/valkey.password")" >/dev/null
vk() { REDISCLI_AUTH="$(<"$W/valkey.password")" valkey-cli --no-auth-warning --raw -p $PORT "$@"; }
shape() { # <site>: the grant onboard-service.sh composes (own tag, brace-less alias, read on the shared topology)
    vk ACL SETUSER "gnode_client_$1" on ">$(<"$W/valkey_client_$1.password")" resetkeys "~{$1}:*" "~$1:*" "%R~{geodineum}:gnode:*" \
        nocommands +xread +xreadgroup +xadd +xack +xclaim +xpending +xinfo +xlen +xtrim +xrange +xrevrange +xgroup +xdel +fcall +fcall_ro +get +set +setex +setnx +del +exists +ttl +expire +mget +mset +incr +decr +incrby +decrby +hget +hset +hgetall +hdel +hexists +hkeys +hvals +hincrby +hmget +hmset +sadd +smembers +sismember +srem +scard +lpush +rpush +lpop +rpop +lrange +llen +lindex +ltrim +zadd +zrange +zrevrange +zrem +zscore +zcard +scan +ping +publish +auth +select +info +multi +exec +discard +time +type +object >/dev/null
}
REDISCLI_AUTH="$(<"$W/valkey.password")" valkey-cli --no-auth-warning -p $PORT -x FUNCTION LOAD REPLACE < "${GNODE_FUNCTIONS_DIR:-/opt/geodineum/gNode/daemon/functions}/gnode_gcore_config.lua" >/dev/null
shape a_nl; shape b_nl
vk HSET '{a_nl}:site:content' hero.title A >/dev/null; vk HSET '{b_nl}:site:content' hero.title B >/dev/null

probe() { bash "$ROOT/scripts/tenant-probe.sh" --sites a_nl,b_nl --creds "$W" --port $PORT --layers valkey --no-alert --state "$W/state" "$@"; }

echo "green: two sites shaped as onboarding shapes them"
out=$(probe 2>&1) && rc=0 || rc=$?
check "the probe passes" "$rc" 0
check "every check is a pass" "$(grep -c '  FAIL' <<<"$out" || true)" 0
check "both controls read their own tag" "$(grep -c 'reads its own tag (control)' <<<"$out" || true)" 2
check "2 ordered pairs x 6 refusals" "$(grep -c -E '^  ok   [ab]_nl -> ' <<<"$out" || true)" 12
check "a JSON record was written" "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["failed"]==[] and r["checks"]>0 and r["sites"]==["a_nl","b_nl"])' "$W/state/last.json")" True

echo "red: a_nl's user is widened onto {b_nl}:*"
vk ACL SETUSER gnode_client_a_nl '~{b_nl}:*' >/dev/null
out=$(probe 2>&1) && rc=0 || rc=$?
check "the probe fails" "$rc" 1
check "it names the pair and the layer" "$(grep -c -E 'FAIL a_nl -> \{b_nl\}: EXISTS answered' <<<"$out" || true)" 1
check "the write checks went red too" "$(grep -c -E 'FAIL a_nl (may (write|XADD)|wrote \{b_nl\} through a function)' <<<"$out" || true)" 3
check "b_nl -> a_nl is still refused (the breach is one-way)" "$(grep -c -E 'FAIL b_nl -> ' <<<"$out" || true)" 0
check "the record carries the failures" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["failed"]) > 0)' "$W/state/last.json")" True

echo "red: only the brace-less alias leaks"
shape a_nl; vk ACL SETUSER gnode_client_a_nl '~b_nl:*' >/dev/null
out=$(probe 2>&1) && rc=0 || rc=$?
check "the probe fails on the alias alone" "$rc $(grep -c 'FAIL a_nl -> b_nl:site:content answered' <<<"$out" || true)" "1 1"

echo "red: a grant that allows a flush"
shape a_nl; vk ACL SETUSER gnode_client_a_nl +flushall >/dev/null
out=$(probe 2>&1) && rc=0 || rc=$?
check "the probe names it" "$rc $(grep -c "a_nl's grant allows FLUSHALL" <<<"$out" || true)" "1 1"

echo "red: a wrong credential cannot pass as 'refused'"
shape a_nl; head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$W/valkey_client_a_nl.password"
out=$(probe 2>&1) && rc=0 || rc=$?
check "the control catches it" "$rc $(grep -c 'FAIL a_nl cannot read its own tag' <<<"$out" || true)" "1 1"

(( fail )) && { echo "tenant-probe local: FAIL"; exit 1; } || echo "tenant-probe local: PASS"

#!/bin/bash
# on a dev box, no sudo: the probe's daemon layer against a real daemon binary on a throwaway ValKey.
#   bash tests/tenant-probe/daemon.sh <binary> <gNode tree> green    (a binary with the tenant guard: must pass)
#   bash tests/tenant-probe/daemon.sh <binary> <gNode tree> red      (one without: must go red)
set -uo pipefail
BIN=$1; TREE=$2; WANT=$3; ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; PORT=6397
W=$(mktemp -d /dev/shm/gn.XXXX); chmod 0750 "$W"; umask 077
vk() { valkey-cli -p $PORT "$@"; }
DP=; cleanup() { [[ -n $DP ]] && kill "$DP" 2>/dev/null; vk shutdown nosave >/dev/null 2>&1; rm -rf "$W"; }; trap cleanup EXIT
valkey-server --port $PORT --save '' --appendonly no --bind 127.0.0.1 --daemonize yes --dir "$W" --logfile "$W/v.log" >/dev/null; sleep 0.4
for u in valkey valkey_daemon valkey_client_a_nl valkey_client_b_nl; do head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$W/$u.password"; done
vk acl setuser gnode_daemon on ">$(<"$W/valkey_daemon.password")" '~*' '&*' +@all >/dev/null
for f in "$TREE"/daemon/functions/*.lua; do vk -x function load replace < "$f" >/dev/null; done
for s in a_nl b_nl; do vk sadd gnode:sites:registry $s >/dev/null; vk xadd "{$s}:gnode:unified:production" '*' t init >/dev/null; vk xadd "{$s}:gnode:health" '*' t init >/dev/null
    vk acl setuser "gnode_client_$s" on ">$(<"$W/valkey_client_$s.password")" resetkeys "~{$s}:*" "~$s:*" nocommands +xread +xreadgroup +xadd +xack +xclaim +xpending +xinfo +xlen +xtrim +xrange +xrevrange +xgroup +xdel +fcall +fcall_ro +get +set +setex +setnx +del +exists +ttl +expire +mget +mset +incr +decr +incrby +decrby +hget +hset +hgetall +hdel +hexists +hkeys +hvals +hincrby +hmget +hmset +sadd +smembers +sismember +srem +scard +lpush +rpush +lpop +rpop +lrange +llen +lindex +ltrim +zadd +zrange +zrevrange +zrem +zscore +zcard +scan +ping +publish +auth +select +info +multi +exec +discard +time +type +object >/dev/null; done
vk config set requirepass "$(<"$W/valkey.password")" >/dev/null; export REDISCLI_AUTH="$(<"$W/valkey.password")"
printf 'VALKEY_HOST=127.0.0.1\nVALKEY_PORT=%s\nVALKEY_CREDS_PATH=%s\n' $PORT "$W" > "$W/boot.env"; chmod 600 "$W/boot.env"
( cd "$TREE" && exec env GEODINEUM_BOOTSTRAP_DEV=1 GEODINEUM_BOOTSTRAP_FILE="$W/boot.env" VALKEY_HOST=127.0.0.1 VALKEY_PORT=$PORT VALKEY_USER=gnode_daemon GNODE_REDIS_AUTH_FILE="$W/valkey_daemon.password" GEODINEUM_CREDENTIALS_DIR="$W" GNODE_FUNCTIONS_DIR="$TREE/daemon/functions" GNODE_TOPOLOGY_SCHEMA="$TREE/daemon/config/topology_schema.yaml" GNODE_SCHEMAS_DIR="$TREE/config/schemas" GNODE_CONFIG_SCHEMA_FILE="$TREE/daemon/config/config_schema.yaml" GNODE_EXT_DIR="${GNODE_EXT_DIR:-/opt/geodineum/pro/gNode}" GNODE_TOPOLOGY_NAMESPACE=geodineum GNODE_NODE_CONFIG_DIR="$W/nodes" GNODE_LOG_LEVEL=warn "$BIN" --node-id bench --node-type general start ) >"$W/d.log" 2>&1 &
DP=$!
for _ in $(seq 90); do [[ $(vk xinfo groups "{a_nl}:gnode:unified:production" 2>/dev/null | wc -l) -gt 1 ]] && break; sleep 1; done; sleep 2
out=$(bash "$ROOT/scripts/tenant-probe.sh" --sites a_nl,b_nl --creds "$W" --port $PORT --layers daemon --no-alert --state "$W/state" 2>&1); rc=$?
echo "$out" | cut -c1-130
case $WANT in green) [[ $rc == 0 ]] && grep -c '  ok ' <<<"$out" | grep -qx 6 ;; red) [[ $rc == 1 ]] && grep -c 'obeyed' <<<"$out" | grep -qx 4 ;; esac
r=$?; (( r == 0 )) && echo "tenant-probe daemon ($WANT): PASS" || echo "tenant-probe daemon ($WANT): FAIL"; exit $r

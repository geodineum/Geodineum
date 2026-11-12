#!/bin/bash
# A WordPress site's grant on a throwaway ValKey with gNode's functions loaded: every shared key its runtime
# reads or writes works, every shared or environment bus it must not write is refused. Function calls and
# writes are made for real (a dry run answers OK for any FCALL); a refused write is checked as not landed.
#   bash tests/manifest-policy/run.sh [gNode root, default /opt/geodineum/gNode]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; GNODE="${1:-/opt/geodineum/gNode}"
FUNCS="$GNODE/daemon/functions"; ONBOARD="$GNODE/scripts/onboard-service.sh"
D="$(mktemp -d)"; P=${VALKEY_TEST_PORT:-47994}
trap 'valkey-cli -p $P -a admin --no-auth-warning SHUTDOWN NOSAVE >/dev/null 2>&1; rm -rf "${D:?}"' EXIT
pass=0; fail=0; ok() { pass=$((pass+1)); echo "  ok   $*"; }; bad() { fail=$((fail+1)); echo "  FAIL $*"; }
[[ -d "$FUNCS" && -f "$ONBOARD" ]] || { echo "gNode not found at $GNODE (functions + onboard-service.sh)"; exit 2; }
command -v yq >/dev/null || { echo "yq is required"; exit 2; }
valkey-server --port $P --bind 127.0.0.1 --dir "$D" --save '' --requirepass admin --daemonize yes --logfile "$D/v.log" >/dev/null
until valkey-cli -p $P -a admin --no-auth-warning PING 2>/dev/null | grep -F PONG >/dev/null; do :; done
A() { valkey-cli -p $P -a admin --no-auth-warning "$@"; }
U() { valkey-cli -p $P --user gnode_client_site_a --pass site-a-pw --no-auth-warning "$@" 2>&1; }
# shellcheck source=../../lib/manifest-policy.sh
source "$HERE/lib/manifest-policy.sh"

echo "== the policy"
cat > "$D/legacy.yaml" <<'EOF'
consumes: ["gnode:*", "topology:*", "template:*", "membership:*", "{default}:gnode:*", "{default}:gcore:*",
           "{testing}:gnode:*", "{staging}:gnode:*", "{acceptance}:gnode:*", "{production}:gnode:*"]
produces: ["{site_a}:gnode:comms:*"]
EOF
n=$(policy_compose_key_grants "$D/legacy.yaml" site_a site_a geodineum 2>&1 >/dev/null | grep -c 'POLICY DENY')
policy_compose_key_grants "$D/legacy.yaml" site_a site_a geodineum >/dev/null 2>&1 \
    && bad "the old uniform set still composes" || ok "the old uniform set is refused ($n patterns denied)"
for p in 'gnode:*' 'gnode:endpoints' '{production}:gnode:*' '{default}:gnode:*' 'membership:*' 'topology:*' \
         'topology:site_b:*' 'template:site_b:*' 'gnode:consumer_groups_verified:site_b:*'; do
    policy_validate_pattern "$p" site_a site_a geodineum 2>/dev/null && bad "admitted: $p" || ok "refused: $p"
done
for p in 'gnode:site:*' 'gnode:sites:registry' 'gnode:routing:*' '{default}:gcore:*' '{geodineum}:gnode:x'; do
    [[ "$(policy_key_grant_form "$p" site_a geodineum)" == "%R~$p" ]] && ok "read-only form: $p" || bad "not read-only: $p"
done
for p in 'topology:site_a:*' 'template:site_a:*' 'gnode:consumer_groups_verified:site_a:*'; do
    policy_validate_pattern "$p" site_a site_a geodineum 2>/dev/null && [[ "$(policy_key_grant_form "$p" site_a geodineum)" == "~$p" ]] \
        && ok "own, read-write: $p" || bad "own pattern not granted read-write: $p"
done

echo "== the manifest a new WordPress site gets"
mkdir -p "$D/site"
( log_warning() { :; }; log_success() { :; }; log_dry() { :; }; ledger_mkdir() { :; }; ledger_add() { :; }; ledger_file() { :; }
  # shellcheck source=../../lib/service-taxonomy.sh
  source "$HERE/lib/service-taxonomy.sh" 2>/dev/null
  gnode_block_yaml() { echo "gnode: {constellation: geodineum, shape: site}"; }
  GEODINEUM_CLI_ROOT="$HERE" SVC_TYPE=website-wp SVC_NAME=site_a SVC_PATH="$D/site" SVC_ENV=staging SVC_PROFILE=web \
      SVC_LANG=php SVC_FORM=false SVC_NODE="" SVC_DRY_RUN=false SVC_CONSTELLATION=geodineum ensure_manifest )
M="$D/site/.geodineum/gnode_services.yaml"
[[ -f "$M" ]] && ok "ensure_manifest wrote $(basename "$M")" || { bad "ensure_manifest wrote nothing"; echo "== $pass ok, $fail failed"; exit 1; }
mapfile -t declared < <(policy_compose_key_grants "$M" site_a site_a geodineum)
(( ${#declared[@]} )) && ok "it composes: ${declared[*]}" || bad "it does not compose"
printf '%s\n' "${declared[@]}" | grep -qE '^~(gnode:\*|topology:\*|template:\*|membership:\*|\{(default|production|staging|testing|acceptance)\}:gnode)' \
    && bad "a shared or environment bus is granted read-write" || ok "no shared or environment bus read-write"

echo "== the grant on ValKey, as onboard-service.sh applies it"
loaded=0; for f in "$FUNCS"/*.lua; do A -x FUNCTION LOAD REPLACE < "$f" >/dev/null 2>&1 && loaded=$((loaded+1)); done
A FUNCTION LIST LIBRARYNAME gnode_gcore_config | grep -q gnode_gcore_config && ok "$loaded function libraries loaded (gnode_gcore_config among them)" \
    || { bad "gnode_gcore_config did not load"; }
cmds_src="$(awk '/ACL SETUSER "\$ACL_USER" nocommands/{f=1} f{print; if ($0 !~ /\\$/) exit}' "$ONBOARD" | sed 's/.*nocommands//; s/\\$//; s/>\/dev\/null//')"
eval "cmds=($cmds_src)"
(( ${#cmds[@]} > 20 )) && ok "command allowlist read from onboard-service.sh (${#cmds[@]} rules)" || bad "command allowlist not found in $ONBOARD"
r=$(A ACL SETUSER gnode_client_site_a on '>site-a-pw' clearselectors resetkeys \
      '~site_a:*' '~{site_a}:*' '~{geodineum}:gnode:heartbeat:*:site_a:*' '%R~{geodineum}:gnode:*' "${declared[@]}" \
      resetchannels '&*' nocommands "${cmds[@]}")
[[ $r == OK ]] && ok "ACL SETUSER accepted" || bad "ACL SETUSER: $r"

A HSET gnode:site:site_a:meta active_environment staging >/dev/null
A HSET gnode:site:site_b:meta active_environment production >/dev/null
A SADD gnode:sites:registry site_a site_b >/dev/null
A HSET '{default}:gcore:config:CacheManager' default_ttl 3600 >/dev/null
A HSET '{default}:gcore:secrets:CapabilityManager' link_secret shared-fallback >/dev/null
A HSET '{geodineum}:gnode:constellation:entities' site_a '{}' >/dev/null
A SET gnode:endpoints untouched >/dev/null

echo "== what the runtime does: allowed"
yes_() { local want="$1"; shift; local r; r=$(U "$@"); if [[ $r == *NOPERM* || $r == *"ACL failure"* || $r == *"No permissions"* || $r == ERR* ]]; then bad "refused: $* -> ${r:0:120}"; elif [[ -n $want && $r != *"$want"* ]]; then bad "$* -> ${r:0:120} (wanted $want)"; else ok "$*"; fi; }
yes_ staging HGET gnode:site:site_a:meta active_environment
yes_ site_b SMEMBERS gnode:sites:registry
yes_ OK SETEX gnode:consumer_groups_verified:site_a:node1 300 1
yes_ 1 GET gnode:consumer_groups_verified:site_a:node1
yes_ 3600 FCALL GCORE_MGR_CONFIG_HGETALL 0 site_a CacheManager
yes_ 3600 FCALL GCORE_MGR_CONFIG_GET 0 site_a CacheManager default_ttl
yes_ shared-fallback FCALL GCORE_MGR_SECRETS_GET 0 site_a CapabilityManager link_secret
yes_ '' FCALL GCORE_MGR_CONFIG_SET 0 site_a CacheManager prefix site_a_
yes_ '' FCALL GCORE_MGR_CONFIG_VERSION 0 site_a CacheManager
yes_ OK FCALL GNODE_CACHE_SET 0 '{site_a}:cache:topology:site_a:discover:x' v 60 site_a
yes_ v FCALL GNODE_CACHE_GET 0 '{site_a}:cache:topology:site_a:discover:x' site_a
yes_ '' XADD '{site_a}:gnode:comms:staging' '*' type alert
yes_ OK SET cache:site_a:node1:k v
yes_ OK SET error:site_a:x v
yes_ OK SET session:site_a:x v
yes_ OK SETEX '{geodineum}:gnode:heartbeat:staging:site_a:node1' 120 1
yes_ '{}' HGETALL '{geodineum}:gnode:constellation:entities'

echo "== what it must not do: refused, and nothing landed"
no_() { local key="$1"; shift; local before after r; before=$(A DUMP "$key" | od -An -tx1 | tr -d ' \n'); r=$(U "$@")
    after=$(A DUMP "$key" | od -An -tx1 | tr -d ' \n')
    if [[ ( $r == *NOPERM* || $r == *"No permissions"* || $r == *"ACL failure"* ) && "$before" == "$after" ]]; then ok "refused: $*"; else bad "NOT refused: $* -> ${r:0:120}"; fi; }
for e in production staging testing acceptance; do
    no_ "{$e}:gnode:unified:$e" XADD "{$e}:gnode:unified:$e" '*' t c
    no_ "{$e}:gnode:x" SET "{$e}:gnode:x" 1
done
no_ '{default}:gnode:x' SET '{default}:gnode:x' 1
no_ gnode:site:site_a:meta HSET gnode:site:site_a:meta active_environment production
no_ gnode:site:site_b:meta HSET gnode:site:site_b:meta active_environment testing
no_ gnode:site:site_b:meta HGETALL gnode:site:site_b:meta
no_ gnode:sites:registry SADD gnode:sites:registry intruder
no_ gnode:endpoints SET gnode:endpoints x
no_ gnode:x SET gnode:x 1
no_ gnode:consumer_groups_verified:site_b:node1 SETEX gnode:consumer_groups_verified:site_b:node1 300 1
no_ topology:site_b:x SET topology:site_b:x 1
no_ template:site_b:x SET template:site_b:x 1
no_ membership:x SET membership:x 1
no_ '{default}:gcore:config:CacheManager' HSET '{default}:gcore:config:CacheManager' default_ttl 1
no_ '{default}:gcore:config:CacheManager' FCALL GCORE_MGR_CONFIG_SET 0 default CacheManager default_ttl 1
no_ '{default}:gcore:secrets:CapabilityManager' FCALL GCORE_MGR_SECRETS_SET 0 default CapabilityManager link_secret x
no_ '{site_b}:gcore:config:CacheManager' FCALL GCORE_MGR_CONFIG_SET 0 site_b CacheManager prefix x
no_ '{geodineum}:gnode:constellation:entities' HDEL '{geodineum}:gnode:constellation:entities' site_a
no_ '{geodineum}:gnode:heartbeat:staging:site_b:node1' SETEX '{geodineum}:gnode:heartbeat:staging:site_b:node1' 120 1
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

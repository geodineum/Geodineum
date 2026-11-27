#!/bin/bash
# STORE's settings in the config sweep: its folder keeps its installers' layout (root:geodineum_store, its keys
# its own), the components default never touches it, and STORE joins geodineum-bootstrap to traverse components/.
# Runs geodeploy_fix_config_perms on a sandbox; every privileged call is recorded, none is made. Needs no sudo.
#   bash tests/geodeploy-store-config.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/geodeploy-store.XXXXXX")"; trap 'rm -rf "${SB:?}"' EXIT
export GEODINEUM_ROOT="$SB/root" GEODEPLOY_LOG="$SB/log/auto-deploy.log" GEODEPLOY_DEPLOY_USER="$(id -un)"
mkdir -p "$SB/log" "$GEODINEUM_ROOT" "$SB/bin"; touch "$GEODEPLOY_LOG"
ETC="$SB/etc"; ST="$ETC/components/geodineum-store"
mkdir -p "$ST/detectors.d" "$ST/seal" "$ST/mailbak" "$ETC/components/gnode-daemon"
touch "$ST/store.env" "$ST/keep.effective.yaml" "$ST/detectors.d/x.yaml" "$ST/seal/k1.key" "$ST/seal/k1.pub" \
      "$ST/seal/current" "$ST/mailbak/id_ed25519" "$ST/mailbak/id_ed25519.pub" "$ST/mailbak/mailbak.env" \
      "$ETC/components/gnode-daemon/daemon.env"

# shellcheck source=/dev/null
source "$HERE/lib/geodeploy.sh"
set +e
PRIV="$SB/priv"; : > "$PRIV"
printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done | paste -sd" " >> %q\n' "$PRIV" > "$SB/bin/rec"
chmod 0750 "$SB/bin/rec"
_gd_priv() { echo "$*" >> "$PRIV"; }
_GD_PRIV_ARGV=("$SB/bin/rec")
getent() { [[ "$1 $2" == "passwd geodineum_store" ]] && return 0; command getent "$@"; }
GROUPS_OF_STORE="geodineum_store geodineum-creds geodineum-code"
# geodineum_store exists only on the STORE node; find refuses an unknown name, so it asks about root's here
find() { local a=() x; for x in "$@"; do [[ $x == geodineum_store ]] && x=root; a+=("$x"); done; command find "${a[@]}"; }
id() { if [[ "$1 ${2:-}" == "-nG geodineum_store" ]]; then echo "$GROUPS_OF_STORE"; else command id "$@"; fi; }

pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
# chown/chmod lines that name one path (xargs batches several paths on one line)
for_path() { grep -E -- "$1" "$PRIV" | grep -F -- "$2" | wc -l | tr -d ' '; }

geodeploy_fix_config_perms "$ETC"

is "no default owner lands on anything of STORE's" "$(grep -E 'chown -h gnode:geodineum(-bootstrap)? ' "$PRIV" | grep -c -F "$ST")" 0
is "no default mode lands on STORE's files" "$(grep -E 'chmod 0640 ' "$PRIV" | grep -F "$ST" | grep -c -E 'seal/k1.key|mailbak/id_ed25519( |$)')" 0
is "STORE's folder is root:geodineum_store" "$(for_path "chown -h root:geodineum_store $ST\$" "$ST")" 1
is "its settings files are root:geodineum_store" "$(for_path 'chown -h root:geodineum_store' "$ST/store.env")" 1
is "the seal key is STORE's alone" "$(for_path 'chown -h geodineum_store:geodineum_store' "$ST/seal/k1.key")" 1
is "the seal key is 0600" "$(for_path 'chmod 0600' "$ST/seal/k1.key")" 1
is "the seal folder is 0700" "$(for_path "chmod 0700 $ST/seal\$" "$ST/seal")" 1
is "the mail backup login is STORE's alone" "$(for_path "chown -h geodineum_store:geodineum_store $ST/mailbak/id_ed25519\$" "$ST/mailbak/id_ed25519")" 1
is "the mail backup login is 0600" "$(for_path "chmod 0600 $ST/mailbak/id_ed25519\$" "$ST/mailbak/id_ed25519")" 1
is "the mail backup settings are root:geodineum_store" "$(for_path 'chown -h root:geodineum_store' "$ST/mailbak/mailbak.env")" 1
is "STORE joins geodineum-bootstrap" "$(grep -c 'usermod -aG geodineum-bootstrap geodineum_store' "$PRIV")" 1
is "and is restarted once to take it" "$(grep -c 'systemctl try-restart geodineum-store.service' "$PRIV")" 1
is "other components keep the default owner" "$(for_path 'chown -h gnode:geodineum' "$ETC/components/gnode-daemon/daemon.env")" 1

: > "$PRIV"; GROUPS_OF_STORE="geodineum_store geodineum-creds geodineum-code geodineum-bootstrap"
geodeploy_fix_config_perms "$ETC"
is "a member is not added again" "$(grep -c usermod "$PRIV")" 0
is "nor restarted" "$(grep -c try-restart "$PRIV")" 0

: > "$PRIV"; getent() { [[ "$1 $2" == "passwd geodineum_store" ]] && return 2; command getent "$@"; }
geodeploy_fix_config_perms "$ETC"
is "a node without STORE's user leaves the folder alone" "$(grep -c -F "root:geodineum_store" "$PRIV")" 0

echo "$pass passed, $fail failed"
(( fail == 0 ))

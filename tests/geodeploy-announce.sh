#!/bin/bash
# The deploy sweep announces component_deployed on the constellation's broadcast stream after a good build or
# restart, never after a failed one, and never fails over it. A throwaway ValKey; touches no /opt, needs no sudo.
#   bash tests/geodeploy-announce.sh [port]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; PORT="${1:-47993}"
SB="$(mktemp -d "${TMPDIR:-/tmp}/geodeploy-announce.XXXXXX")"
trap 'valkey-cli -p "$PORT" shutdown nosave >/dev/null 2>&1; rm -rf "${SB:?}"' EXIT
valkey-server --port "$PORT" --bind 127.0.0.1 --save '' --appendonly no --daemonize yes --dir "$SB" --logfile "$SB/v.log" >/dev/null
for _ in $(seq 20); do valkey-cli -p "$PORT" ping >/dev/null 2>&1 && break; sleep 0.1; done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

export GEODINEUM_ROOT="$SB/root" GEODEPLOY_LOG="$SB/log/auto-deploy.log" GEODEPLOY_DEPLOY_USER="$(id -un)"
export GNODE_DAEMON_ENV="$SB/daemon.env"
mkdir -p "$SB/log" "$GEODINEUM_ROOT/gNode/scripts" "$SB/remotes" "$SB/work"; touch "$GEODEPLOY_LOG"
printf 'GNODE_TOPOLOGY_NAMESPACE="testc"\nGNODE_NODE_ID=n1\n' > "$GNODE_DAEMON_ENV"
VCLI="$GEODINEUM_ROOT/gNode/scripts/valkey-cli-secure.sh"
real_vcli() { printf '#!/bin/bash\nexec valkey-cli -p %s "$@"\n' "$1" > "$VCLI"; chmod 0750 "$VCLI"; }
real_vcli "$PORT"
KEY='{testc}:gnode:broadcast:global'

# shellcheck source=/dev/null
source "$HERE/lib/geodeploy.sh"
set +e
_gd_priv() { :; }
geodeploy_action_build()   { return "${BUILD_RC:-0}"; }
geodeploy_action_restart() { return "${RESTART_RC:-0}"; }

pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
logged() { grep -c -- "$1" "$GEODEPLOY_LOG" | tr -d ' '; }
entries() { valkey-cli -p "$PORT" XLEN "$KEY"; }

geodeploy_announce_deployed Comp 0123456789abcdef
is "announce returns 0" "$?" 0
is "one entry on the node's constellation stream" "$(entries)" 1
is "of type component_deployed" "$(valkey-cli -p "$PORT" --raw XRANGE "$KEY" - + | sed -n 3p)" component_deployed
data="$(valkey-cli -p "$PORT" --raw XRANGE "$KEY" - + | sed -n 5p)"
is "data names the component, rev, node" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["component"],d["rev"],d["node"],type(d["ts"]).__name__)' "$data")" "Comp 0123456789ab n1 int"
is "logged" "$(logged 'Comp: announced component_deployed')" 1

real_vcli 1
geodeploy_announce_deployed Down rev
is "ValKey unreachable: still returns 0" "$?" 0
is "and the log says so" "$(logged 'Down: WARN component_deployed not announced')" 1
printf '#!/bin/bash\necho "(error) NOPERM User x has no permissions"\n' > "$VCLI"
geodeploy_announce_deployed Refused rev
is "a refusal: returns 0" "$?" 0
is "and the log names it" "$(logged 'Refused: WARN component_deployed not announced ((error) NOPERM')" 1
rm -f "$VCLI"
geodeploy_announce_deployed Missing rev
is "no wrapper: returns 0" "$?" 0
is "and the log says so" "$(logged 'Missing: WARN component_deployed not announced (valkey-cli-secure.sh not found)')" 1
real_vcli "$PORT"

# Through geodeploy_repo: a repo whose push triggers build and restart.
g init --bare "$SB/remotes/Comp.git"
( cd "$SB/work" && g clone "$SB/remotes/Comp.git" Comp && cd Comp \
  && printf 'runtime:\n  service: comp\ntriggers:\n  - match: "src/*"\n    actions: [build, restart]\n' > geodeploy.yaml \
  && mkdir src && echo 1 > src/a && echo 1 > README && g add -A && g commit -m init && g push origin HEAD:main )
g clone "$SB/remotes/Comp.git" "$GEODINEUM_ROOT/Comp"
push() { ( cd "$SB/work/Comp" && echo "$2" > "$1" && g add -A && g commit -m "$1 $2" && g push origin HEAD:main ); }
deploy() { local n; n=$(entries); geodeploy_repo Comp main >/dev/null 2>&1; echo $(( $(entries) - n )); }

push src/a 2;              is "build and restart succeed: announced" "$(deploy)" 1
BUILD_RC=1 push src/a 3;   BUILD_RC=1;   is "build failed: not announced" "$(deploy)" 0; BUILD_RC=0
RESTART_RC=1;  push src/a 4;             is "restart failed: not announced" "$(deploy)" 0; RESTART_RC=0
push README 2;             is "no build or restart ran: not announced" "$(deploy)" 0
is "nothing new: not announced" "$(deploy)" 0
real_vcli 1
push src/a 5;              is "ValKey down: the deploy still completes" "$(deploy)" 0
is "the pull happened" "$(git -C "$GEODINEUM_ROOT/Comp" show HEAD:src/a)" 5

echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

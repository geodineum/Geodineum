#!/bin/bash
# geodeploy_deploy_pro against local bare remotes with stubbed actions; touches no /opt, needs no sudo.
# usage: tests/geodeploy-pro.sh [sandbox-dir]
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/geodeploy.sh"
if [[ -n "${1:-}" ]]; then SB="$1"; rm -rf "$SB"; mkdir -p "$SB"
else SB="$(mktemp -d "${TMPDIR:-/tmp}/geodeploy-pro.XXXXXX")"; trap 'rm -rf "$SB"' EXIT; fi
mkdir -p "$SB"/{remotes,work,log} "$SB"/root/pro/{gCore,gNode,GSD}
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

mkremote() { # name [ext]
    g init --bare "$SB/remotes/$1.git"
    mkdir -p "$SB/work/$1"
    ( cd "$SB/work/$1" && g init && echo init > README \
      && if [[ "${2:-}" == ext ]]; then mkdir -p functions src/handlers && echo n > extension.yaml \
         && echo s1 > extension.sig && echo l1 > functions/a.lua && echo r1 > src/handlers/h.rs; fi \
      && g add -A && g commit -m init && g remote add origin "$SB/remotes/$1.git" && g push origin HEAD:main )
}
push() { ( cd "$SB/work/$1" && mkdir -p "$(dirname "$2")" && echo "$3" > "$2" && g add -A && g commit -m "$2" && g push origin HEAD:main ); }
rmpush() { ( cd "$SB/work/$1" && g rm "$2" && g commit -m "rm $2" && g push origin HEAD:main ); }
deploy_clone() { g clone "$SB/remotes/$1.git" "$SB/root/pro/$2/$1"; }

mkremote gCore-A; mkremote ext-a ext; mkremote ext-bad ext; mkremote gsd-old; mkremote ext-new ext
deploy_clone gCore-A gCore; deploy_clone ext-a gNode; deploy_clone ext-bad gNode; deploy_clone gsd-old GSD

mkdir -p "$SB/root/gNode/daemon/target/release"
cat > "$SB/root/gNode/geodeploy.yaml" <<'EOF'
runtime:
  group: gnode
  service: gnode-daemon
build:
  command: scripts/build.sh
EOF
( cd "$SB/root/gNode" && g init && echo x > f && g add -A && g commit -m init )
cat > "$SB/root/gNode/daemon/target/release/gnode-daemon" <<'EOF'
#!/bin/bash
[[ "$1" == verify-extension && ! -f "$2/BAD" ]]
EOF
chmod 750 "$SB/root/gNode/daemon/target/release/gnode-daemon"

export GEODINEUM_ROOT="$SB/root" GEODEPLOY_LOG="$SB/log/auto-deploy.log" GEODEPLOY_DEPLOY_USER="$(id -un)"
touch "$GEODEPLOY_LOG"
# shellcheck source=/dev/null
source "$LIB"
set +e   # the orchestrator runs deploy_pro under ||, where errexit is ignored anyway

ACT="$SB/actions"; : > "$ACT"
PENDING="$SB/log/.pro-gnode-rebuild-pending"
geodeploy_action_lua_reload()    { echo "lua $1" >> "$ACT"; }
geodeploy_action_opcache_clear() { echo "opcache $1" >> "$ACT"; }
geodeploy_action_build()         { echo "build $2 [$_GD_BUILD_CMD]" >> "$ACT"; return "${BUILD_RC:-0}"; }
geodeploy_action_restart()       { echo "restart $1 [$_GD_SERVICE]" >> "$ACT"; }
geodeploy_fix_binaries()         { :; }
geodeploy_fix_gnode_dirs()       { :; }

PASS=0; FAIL=0; RC=0; CYCLE_LOG=""
run() {
    : > "$ACT"
    local before; before=$(wc -l < "$GEODEPLOY_LOG")
    RC=0; geodeploy_deploy_pro >/dev/null 2>&1 || RC=$?
    cd "$SB" || exit 1
    CYCLE_LOG=$(tail -n +"$((before + 1))" "$GEODEPLOY_LOG")
}
check() {
    if eval "$2"; then PASS=$((PASS + 1)); echo "ok   $1"
    else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     rc=$RC actions=[$(tr '\n' ';' < "$ACT")]"
         echo "     log=[$(grep -v '^From \|^ \* \|^   ' <<< "$CYCLE_LOG" | tr '\n' ';')]"; fi
}
has_log() { grep -qF -- "$1" <<< "$CYCLE_LOG"; }
has_act() { grep -qxF -- "$1" "$ACT"; }
no_act()  { ! grep -q "^$1" "$ACT"; }
head_of() { git -C "$1" rev-parse HEAD; }

run
check "quiet cycle: rc 0, no actions, no pull"      '[[ $RC == 0 ]] && [[ ! -s $ACT ]] && ! has_log PULL && [[ ! -e $PENDING ]]'

push gCore-A x.php v1; push ext-a functions/a.lua l2; push gsd-old y z
run
check "php + lua change: pulls both"                'has_log "pro/gCore/gCore-A: PULL" && has_log "pro/gNode/ext-a: PULL"'
check "php + lua change: one reload each, no build" 'has_act "lua pro/gNode" && has_act "opcache pro/gCore" && no_act build && [[ $RC == 0 ]]'
check "GSD tree is never pulled"                    '! has_log gsd-old && [[ $(head_of $SB/root/pro/GSD/gsd-old) != $(head_of $SB/work/gsd-old) ]]'

push ext-a CLAUDE.md docs
run
check "docs-only extension change: pull, no action" 'has_log "ext-a: PULL" && [[ ! -s $ACT ]] && [[ ! -e $PENDING ]]'

push ext-a extension.sig s2
run
check "signed change: forced build then restart"    'has_act "build pro/gNode [scripts/build.sh --force]" && has_act "restart gNode [gnode-daemon]" && [[ $RC == 0 ]] && [[ ! -e $PENDING ]]'

push ext-bad BAD x; push ext-bad src/handlers/h.rs r2
run
check "unverifiable extension: rebuild held, rc 1"  'has_log "rebuild held (signature verification failed: ext-bad" && no_act build && [[ $RC == 1 ]] && [[ -s $PENDING ]]'
run
check "same inputs: no retry, still rc 1, quiet"    'no_act build && [[ $RC == 1 ]] && ! has_log "rebuild held"'
rmpush ext-bad BAD; push ext-bad extension.sig s3
run
check "re-signed: build, restart, pending cleared"  'has_act "build pro/gNode [scripts/build.sh --force]" && has_act "restart gNode [gnode-daemon]" && [[ $RC == 0 ]] && [[ ! -e $PENDING ]]'

BUILD_RC=1; push ext-a src/handlers/h.rs r3
run
check "build failure: rc 1, inputs recorded"        'has_act "build pro/gNode [scripts/build.sh --force]" && [[ $RC == 1 ]] && [[ -s $PENDING ]]'
run
check "build failure, same inputs: no rebuild"      'no_act build && [[ $RC == 1 ]]'
BUILD_RC=0; ( cd "$SB/root/gNode" && echo y > f && g commit -am core )
run
check "new gNode commit: retried and cleared"       'has_act "build pro/gNode [scripts/build.sh --force]" && [[ $RC == 0 ]] && [[ ! -e $PENDING ]]'

echo "  pro/gCore/gCore-A   # held back" > "$SB/root/unmanaged-repos.conf"
push gCore-A y.php v1
run
check "unmanaged pro repo is not pulled"            '! has_log "gCore-A: PULL" && no_act opcache'
rm "$SB/root/unmanaged-repos.conf"
run
check "released again: pulled"                      'has_log "gCore-A: PULL" && has_act "opcache pro/gCore"'

echo retired > "$SB/root/pro/gNode/ext-a/manifest.sig"; push ext-a CLAUDE.md docs2
run
check "dirty tree discarded, then pulled"           'has_log "ext-a: DISCARD dirty tree" && has_log "ext-a: PULL" && [[ ! -e $SB/root/pro/gNode/ext-a/manifest.sig ]]'

( cd "$SB/work/gCore-A" && echo amended > y.php && g commit -a --amend -m rewritten && g push --force origin HEAD:main )
run
check "force-pushed history: mirrors origin"        'has_log "gCore-A: PULL" && [[ $(head_of $SB/root/pro/gCore/gCore-A) == $(head_of $SB/work/gCore-A) ]]'

cat > "$SB/root/pro/manifest.yaml" <<EOF
pro:
  - name: ext-new
    remote: $SB/remotes/ext-new.git
    branch: main
    type: gNode
  - name: gCore-A
    remote: $SB/remotes/gCore-A.git
    type: gCore
  - name: gsd-old
    remote: $SB/remotes/gsd-old.git
    type: GSD
EOF
run
check "manifest clones a missing extension, builds" 'has_log "pro/gNode/ext-new: CLONE success" && has_act "build pro/gNode [scripts/build.sh --force]" && [[ $RC == 0 ]]'
check "manifest ignores other types"                '! has_log "gsd-old"'

echo "pro: [unclosed" > "$SB/root/pro/manifest.yaml"
push gCore-A z.php v1
run
check "bad manifest: logged, rc 1, pulls continue"  'has_log "manifest parse-failed" && [[ $RC == 1 ]] && has_log "gCore-A: PULL"'
rm "$SB/root/pro/manifest.yaml"

git -C "$SB/root/pro/gNode/ext-a" remote set-url origin "$SB/remotes/missing.git"
push gCore-A w.php v1
run
check "fetch failure: logged, rc 1, others deploy"  'has_log "ext-a: ERROR fetch-failed" && [[ $RC == 1 ]] && has_log "gCore-A: PULL"'
git -C "$SB/root/pro/gNode/ext-a" remote set-url origin "$SB/remotes/ext-a.git"

GEODINEUM_ROOT="$SB/empty"; mkdir -p "$SB/empty"
run
check "host without pro/: no-op"                    '[[ $RC == 0 ]] && [[ ! -s $ACT ]]'

echo "---- $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))

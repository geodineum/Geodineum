#!/bin/bash
# Checkout owners in the deploy sweep: root's checkouts stay root's, a repo cannot name its own owner, unit files and
# links come only from where they may, and the sudoers template holds exact restarts. Touches no /opt, needs no sudo.
#   bash tests/geodeploy-owner.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/geodeploy-owner.XXXXXX")"; trap 'rm -rf "${SB:?}"' EXIT
export GEODINEUM_ROOT="$SB/root" GEODEPLOY_LOG="$SB/log/auto-deploy.log" GEODEPLOY_DEPLOY_USER="$(id -un)"
mkdir -p "$SB/log" "$SB/outside"; touch "$GEODEPLOY_LOG"
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
for r in Mine Roots; do mkdir -p "$GEODINEUM_ROOT/$r" && ( cd "$GEODINEUM_ROOT/$r" && g init ); done
touch "$GEODINEUM_ROOT/Roots/.ROOT"

# shellcheck source=/dev/null
source "$HERE/lib/geodeploy.sh"
set +e
_gd_owner_of() { if [[ -e "$(dirname "$1")/.ROOT" ]]; then echo root; else /usr/bin/stat -c %U "$1"; fi; }
PRIV="$SB/priv"; : > "$PRIV"
_gd_priv() { echo "$*" >> "$PRIV"; }

pass=0; fail=0
is() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
logged() { grep -c -- "$1" "$GEODEPLOY_LOG" | tr -d ' '; }

is "a checkout whose .git root owns is root's" "$(geodeploy_checkout_owner "$GEODINEUM_ROOT/Roots")" root
is "any other checkout is the deploy user's" "$(geodeploy_checkout_owner "$GEODINEUM_ROOT/Mine")" "$GEODEPLOY_DEPLOY_USER"

printf 'runtime:\n  owner: someone-else\n  group: gnode\n' > "$GEODINEUM_ROOT/Mine/geodeploy.yaml"
_GD_OWNER=keep; geodeploy_parse_descriptor "$GEODINEUM_ROOT/Mine/geodeploy.yaml"
is "a descriptor cannot name the owner" "$_GD_OWNER" keep
is "the descriptor still sets the group" "$_GD_GROUP" gnode

_GD_RUN_AS="$GEODEPLOY_DEPLOY_USER"
is "as_owner runs directly as the owner" "$(geodeploy_as_owner id -un)" "$GEODEPLOY_DEPLOY_USER"

for r in Mine Roots; do mkdir -p "$GEODINEUM_ROOT/$r/config" && echo "[Service]" > "$GEODINEUM_ROOT/$r/config/x-$r.service"; done
: > "$PRIV"; geodeploy_action_service_install "$GEODINEUM_ROOT/Mine" Mine "config/x-Mine.service"
is "a unit from the deploy user's checkout is not installed" "$(grep -c install "$PRIV")" 0
is "and the log says to install it by hand" "$(logged 'x-Mine.service changed in a checkout root does not own')" 1
: > "$PRIV"; geodeploy_action_service_install "$GEODINEUM_ROOT/Roots" Roots "config/x-Roots.service"
is "a unit from root's checkout is installed" "$(grep -c "install -m 0644 -o root -g root $GEODINEUM_ROOT/Roots/config/x-Roots.service" "$PRIV")" 1
is "followed by one daemon-reload" "$(grep -c daemon-reload "$PRIV")" 1

cat > "$GEODINEUM_ROOT/Mine/geodeploy.yaml" <<EOF
links:
  - {target: $SB/outside, link: inside}
  - {target: $SB/outside, link: ../escape}
  - {target: $SB/outside, link: /tmp/abs-escape}
EOF
geodeploy_ensure_links "$GEODINEUM_ROOT/Mine" Mine
is "a link inside the checkout is made" "$(readlink "$GEODINEUM_ROOT/Mine/inside")" "$SB/outside"
is "a link with .. is refused" "$([[ -e "$GEODINEUM_ROOT/escape" || -L "$GEODINEUM_ROOT/escape" ]] && echo made || echo refused)" refused
is "an absolute link is refused" "$(logged 'link /tmp/abs-escape leaves the checkout')" 1

echo secret > "$SB/outside/target"; chmod 600 "$SB/outside/target"
ln -s "$SB/outside/target" "$GEODINEUM_ROOT/Mine/evil.sh"; echo 'echo' > "$GEODINEUM_ROOT/Mine/real.sh"; chmod 600 "$GEODINEUM_ROOT/Mine/real.sh"
printf 'triggers:\n  - match: "*.sh"\n    actions: [chmod-scripts]\n' > "$GEODINEUM_ROOT/Mine/geodeploy.yaml"
geodeploy_match_and_run "$GEODINEUM_ROOT/Mine" Mine "real.sh"
is "chmod-scripts sets a script's mode" "$(stat -c %a "$GEODINEUM_ROOT/Mine/real.sh")" 750
is "chmod-scripts does not follow a symlink" "$(stat -c %a "$SB/outside/target")" 600

ln -s "$SB/outside/target" "$GEODINEUM_ROOT/Mine/.htaccess"; : > "$PRIV"
geodeploy_fix_perms "$GEODINEUM_ROOT/Mine" "$GEODEPLOY_DEPLOY_USER" "$(id -gn)"
is "fix_perms leaves a symlinked .htaccess alone" "$(grep -c '\.htaccess' "$PRIV")" 0

sed 's/{{DEPLOY_USER}}/deployer/g' "$HERE/templates/sudoers-geodeploy.tpl" > "$SB/sudoers"
is "the sudoers template holds only systemctl restart/reload/daemon-reload" \
   "$(grep -v -E '^(#|$)' "$SB/sudoers" | grep -c -v -E '^deployer ALL=\(root\) NOPASSWD: /usr/bin/systemctl ((restart|reload) [a-z0-9@._-]+|daemon-reload)$')" 0
if command -v visudo >/dev/null || [[ -x /usr/sbin/visudo ]]; then
    is "the rendered template passes visudo" "$(PATH="$PATH:/usr/sbin" visudo -c -f "$SB/sudoers" >/dev/null 2>&1 && echo ok)" ok
fi

if (( EUID != 0 )); then
    out="$(bash "$HERE/scripts/geodeploy-orchestrator" 2>&1)"; rc=$?
    is "the orchestrator refuses to run as anyone but root" "$rc:$out" "1:geodeploy-orchestrator runs from root's crontab"
fi

( cd "$GEODINEUM_ROOT/Mine" && git remote add origin "http://user:s3cr3t@127.0.0.1:9/x.git" 2>/dev/null )
: > "$GEODEPLOY_LOG"
( cd "$GEODINEUM_ROOT/Mine" && geodeploy_fetch main ); rc=$?
is "a failed fetch returns non-zero" "$((rc > 0))" 1
is "its error reaches the deploy log" "$(grep -c 'fatal' "$GEODEPLOY_LOG")" 1
is "a URL credential never does" "$(grep -c 's3cr3t' "$GEODEPLOY_LOG")" 0

is "the redactor strips a URL credential" "$(_geodeploy_redact <<< "fatal: unable to access 'https://u:tok@h.example/r.git/'")" "fatal: unable to access 'https://h.example/r.git/'"

echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

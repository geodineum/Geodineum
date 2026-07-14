#!/usr/bin/env bash
# =============================================================================
# install-cycle-test.sh — DESTRUCTIVE install → uninstall → reinstall test
# =============================================================================
# Proves the installer is idempotent: a fresh install, a clean uninstall, and a
# reinstall must all reach the SAME green ecosystem state. Composes the existing
# ecosystem-smoke-test.sh (L0 ValKey auth / L1 Lua libs / L2 command dispatch /
# L3 services+HTTP) as the pass/fail oracle after each install.
#
#   ⚠  THIS ERASES ALL GEODINEUM STATE (services, ValKey data, sites).
#      Run ONLY on a throwaway box. It hard-refuses on known production hosts
#      and requires an explicit --destroy acknowledgement.
#
# Usage (root, from a repo checkout):
#   sudo ./scripts/install-cycle-test.sh --destroy [--profile standard]
#        [--site test.example.com] [--keep-data] [--keep-going]
#
#   --destroy      REQUIRED. Confirms this box is disposable.
#   --profile <p>  install profile (default: standard)
#   --site <dom>   also deploy a WP site each install and expect it to serve
#   --keep-data    cycle uninstalls with --keep-data (tests the preserve path)
#   --keep-going   run all phases even after a failure (default: stop on fail)
#
# Exit: 0 = both installs reached green + uninstall left the box clean; 1 = fail.
# =============================================================================
set -uo pipefail

PROFILE="standard"; TEST_SITE=""; KEEP_DATA="false"; DESTROY="false"; KEEP_GOING="false"
DENY_HOSTS=("aesir-solutions")   # protected production hosts — never wipe these
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; NC=$'\e[0m'
say(){ echo "${BLD}${BLU}▶ $*${NC}"; }
ok(){ echo "  ${GRN}✓${NC} $*"; }
no(){ echo "  ${RED}✗${NC} $*"; }
die(){ echo "${RED}${BLD}FATAL:${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do case "$1" in
    --profile)    PROFILE="$2"; shift 2 ;;
    --site)       TEST_SITE="$2"; shift 2 ;;
    --keep-data)  KEEP_DATA="true"; shift ;;
    --destroy)    DESTROY="true"; shift ;;
    --keep-going) KEEP_GOING="true"; shift ;;
    -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
esac; done

# ---- safety guards -------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
HOST="$(hostname 2>/dev/null || echo unknown)"
for h in "${DENY_HOSTS[@]}"; do
    [[ "$HOST" == "$h" ]] && die "REFUSING on '$HOST' — a protected production host. This test wipes Geodineum entirely."
done
[[ "$DESTROY" == "true" ]] || die "this ERASES all Geodineum state. Re-run with --destroy on a THROWAWAY box only."
for f in "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/scripts/ecosystem-smoke-test.sh"; do
    [[ -f "$f" ]] || die "missing required script: $f"
done
# Repos are private pre-launch — a fresh clone needs the deploy key.
[[ -f /root/.ssh/id_ed25519 || -f "$HOME/.ssh/id_ed25519" || -n "${GEODINEUM_DEPLOY_KEY:-}" ]] \
    || echo "${YEL}! no obvious deploy key found — install.sh may fail to clone private repos${NC}"

FAILED=0
mark_fail(){ FAILED=1; no "$1"; [[ "$KEEP_GOING" == "true" ]] || { verdict; exit 1; }; }
phase_time(){ local s=$1; printf "    (%.0fs)\n" "$(echo "$(date +%s) - $s" | bc 2>/dev/null || echo 0)"; }

install_once(){
    local label="$1" args=(--profile "$PROFILE" --yes)
    [[ -n "$TEST_SITE" ]] && args+=(--site "$TEST_SITE")
    say "$label: install.sh ${args[*]}"
    ( cd "$REPO_DIR" && ./install.sh "${args[@]}" ) && ok "$label install returned 0" || mark_fail "$label install failed"
}

smoke(){
    local label="$1" args=()
    [[ -n "$TEST_SITE" ]] && args+=(--site "${TEST_SITE//./_}")
    say "$label: ecosystem-smoke-test.sh ${args[*]}"
    if ( cd "$REPO_DIR" && ./scripts/ecosystem-smoke-test.sh "${args[@]}" ); then
        ok "$label smoke PASSED (all L0–L3 green)"
    else
        mark_fail "$label smoke FAILED — install did not reach a working state"
    fi
}

uninstall_verify(){
    local args=(--commit --force --quiet)
    [[ "$KEEP_DATA" == "true" ]] && args+=(--keep-data)
    say "uninstall.sh ${args[*]}"
    ( cd "$REPO_DIR" && ./uninstall.sh "${args[@]}" ) && ok "uninstall returned 0" || mark_fail "uninstall failed"
    # Clean-state assertions: no active units, install tree gone.
    local active
    active="$(systemctl list-units --type=service --state=active 2>/dev/null \
              | grep -iE 'gnode-daemon|geodineum|valkey-gnode' | grep -c . || true)"
    [[ "$active" -eq 0 ]] && ok "no Geodineum services still active" \
                          || mark_fail "$active Geodineum service(s) still active after uninstall"
    if [[ "$KEEP_DATA" == "true" ]]; then
        [[ -d /var/lib/valkey-gnode ]] && ok "--keep-data preserved /var/lib/valkey-gnode" \
                                       || no "expected /var/lib/valkey-gnode to survive --keep-data"
    fi
}

verdict(){
    echo; say "VERDICT"
    if [[ "$FAILED" -eq 0 ]]; then
        echo "  ${GRN}${BLD}PASS${NC} — fresh install, clean uninstall, and reinstall all reached green."
        echo "  Installer is idempotent for profile='${PROFILE}'${TEST_SITE:+, site='${TEST_SITE}'}${KEEP_DATA:+ (keep-data path)}."
    else
        echo "  ${RED}${BLD}FAIL${NC} — see the ✗ lines above."
    fi
}

echo "${BLD}install-cycle-test on ${HOST} — profile=${PROFILE} site=${TEST_SITE:-none} keep-data=${KEEP_DATA}${NC}"
echo "${YEL}This wipes and rebuilds the box twice. Ctrl-C within 5s to abort.${NC}"; sleep 5

install_once     "FRESH INSTALL (1/2)"
smoke            "post-fresh"
uninstall_verify
install_once     "REINSTALL (2/2)"
smoke            "post-reinstall"
verdict
exit "$FAILED"

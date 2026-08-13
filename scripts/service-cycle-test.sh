#!/usr/bin/env bash
# =============================================================================
# service-cycle-test.sh — create → verify → remove → recreate per service type
# =============================================================================
# Proves the taxonomy onboarding is idempotent and reversible: each tested
# type must reach the same green state on install and reinstall, and leave
# nothing behind on removal. Covers website-static and daemon (the two ends
# of the matrix); website-wp is covered by install-cycle-test.sh --site.
#
# Touches live state (ValKey identities, apache vhosts, systemd units) using
# throwaway cycletest_* names, and removes everything it created.
#
# Usage (root, from a repo checkout, on a box with gNode + ValKey live):
#   sudo ./scripts/service-cycle-test.sh --confirm [--type static|daemon|both]
#
# Exit: 0 = both cycles green; 1 = a phase failed (state left for inspection).
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GNODE_SCRIPTS_DIR="${GNODE_SCRIPTS:-/opt/geodineum/gNode/scripts}"
TYPE="both"; CONFIRM="false"
STATIC_DOMAIN="cycletest-static.invalid"
STATIC_ID="cycletest_static_invalid"
DAEMON_ID="cycletest_daemon"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; NC=$'\e[0m'
say(){ echo "${BLD}${BLU}▶ $*${NC}"; }
ok(){ echo "  ${GRN}✓${NC} $*"; PASS=$((PASS+1)); }
no(){ echo "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
die(){ echo "${RED}${BLD}FATAL:${NC} $*" >&2; exit 1; }
PASS=0; FAIL=0

while [[ $# -gt 0 ]]; do case "$1" in
    --confirm) CONFIRM="true"; shift ;;
    --type)    TYPE="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
esac; done

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$CONFIRM" == "true" ]] || die "pass --confirm (creates + removes cycletest_* services against live ValKey/apache/systemd)"
[[ -x "${REPO_DIR}/geodineum" ]] || die "geodineum CLI not found at ${REPO_DIR}"
[[ -x "${GNODE_SCRIPTS_DIR}/deregister-service.sh" ]] || die "deregister-service.sh not found under ${GNODE_SCRIPTS_DIR}"

CLI="${REPO_DIR}/geodineum"
CRED_DIR="/etc/geodineum/credentials"

# ---- assertions -------------------------------------------------------------

assert_file(){ [[ -f "$1" ]] && ok "file: $1" || no "missing file: $1"; }
assert_no_file(){ [[ ! -e "$1" ]] && ok "gone: $1" || no "still present: $1"; }
assert_mode(){ # path owner:group:mode
    local got
    got=$(stat -c '%U:%G:%a' "$1" 2>/dev/null)
    [[ "$got" == "$2" ]] && ok "perms $1 = $2" || no "perms $1 = ${got:-absent}, want $2"
}
assert_registry(){
    local want="$2" got
    got=$(VALKEY_USER=gnode_daemon "${GNODE_SCRIPTS_DIR}/valkey-cli-secure.sh" \
        SISMEMBER gnode:sites:registry "$1" 2>/dev/null | tr -d '[:space:]')
    [[ "$got" == "$want" ]] && ok "registry[$1] = $want" || no "registry[$1] = ${got:-?}, want $want"
}
assert_acl_composed(){
    # The retired legacy-uniform set granted ~template:* to everything; a
    # composed ACL must NOT carry it unless the manifest declared it.
    local user="gnode_client_$1" out
    out=$(REDISCLI_AUTH="$(cat "${CRED_DIR}/valkey.password")" \
        valkey-cli -p "${VALKEY_PORT:-47445}" ACL GETUSER "$user" 2>/dev/null)
    if [[ -z "$out" ]]; then no "ACL user ${user} missing"; return; fi
    ok "ACL user ${user} exists"
    if grep -q 'template:\*' <<< "$out"; then
        no "ACL for ${user} carries legacy ~template:* — uniform set leaked back"
    else
        ok "ACL for ${user} is manifest-composed (no legacy powerset)"
    fi
}

# ---- removal (reverses every filesystem row the type creates) ---------------

remove_static(){
    "${GNODE_SCRIPTS_DIR}/deregister-service.sh" "$STATIC_ID" --remove-acl --force >/dev/null 2>&1
    a2dissite "${STATIC_DOMAIN}.conf" >/dev/null 2>&1
    rm -f "/etc/apache2/sites-available/${STATIC_DOMAIN}.conf"
    systemctl reload apache2 2>/dev/null
    rm -rf "/var/www/${STATIC_DOMAIN}"
    rm -f "${CRED_DIR}/valkey_client_${STATIC_ID}.password" \
          "${CRED_DIR}/valkey_client_${STATIC_ID}.password.owner"
    sed -i "\\|/var/www/${STATIC_DOMAIN}|d" \
        /etc/geodineum/components/gnode-daemon/discovery-paths.conf 2>/dev/null
}

remove_daemon(){
    systemctl disable --now "geodineum-${DAEMON_ID}-heartbeat.timer" >/dev/null 2>&1
    systemctl disable --now "geodineum-${DAEMON_ID}.service" >/dev/null 2>&1
    rm -f "/etc/systemd/system/geodineum-${DAEMON_ID}.service" \
          "/etc/systemd/system/geodineum-${DAEMON_ID}-heartbeat.service" \
          "/etc/systemd/system/geodineum-${DAEMON_ID}-heartbeat.timer" \
          "/etc/geodineum/services/${DAEMON_ID}.env"
    systemctl daemon-reload
    "${GNODE_SCRIPTS_DIR}/deregister-service.sh" "$DAEMON_ID" --remove-acl --force >/dev/null 2>&1
    rm -rf "/opt/geodineum/services/${DAEMON_ID}"
    rm -f "${CRED_DIR}/valkey_client_${DAEMON_ID}.password" \
          "${CRED_DIR}/valkey_client_${DAEMON_ID}.password.owner"
    sed -i "\\|/opt/geodineum/services/${DAEMON_ID}|d" \
        /etc/geodineum/components/gnode-daemon/discovery-paths.conf 2>/dev/null
    userdel "$DAEMON_ID" 2>/dev/null
    groupdel "$DAEMON_ID" 2>/dev/null
}

# ---- cycles ------------------------------------------------------------------

verify_static(){
    local root="/var/www/${STATIC_DOMAIN}"
    assert_file "${root}/public_html/index.html"
    assert_file "${root}/public_html/form/submit.php"
    assert_file "${root}/.geodineum/gnode_services.yaml"
    assert_file "/etc/apache2/sites-available/${STATIC_DOMAIN}.conf"
    assert_mode "${root}/.env-tier" "root:www-data:640"
    assert_mode "${CRED_DIR}/valkey_client_${STATIC_ID}.password" "root:geodineum-web:640"
    assert_registry "$STATIC_ID" 1
    assert_acl_composed "$STATIC_ID"
}

verify_daemon(){
    local root="/opt/geodineum/services/${DAEMON_ID}"
    assert_file "${root}/.geodineum/gnode_services.yaml"
    assert_file "${root}/run"
    assert_file "/etc/systemd/system/geodineum-${DAEMON_ID}.service"
    assert_file "/etc/systemd/system/geodineum-${DAEMON_ID}-heartbeat.timer"
    assert_mode "/etc/geodineum/services/${DAEMON_ID}.env" "root:${DAEMON_ID}:640"
    assert_mode "${CRED_DIR}/valkey_client_${DAEMON_ID}.password" "root:${DAEMON_ID}:640"
    id "$DAEMON_ID" >/dev/null 2>&1 && ok "system user ${DAEMON_ID}" || no "system user ${DAEMON_ID} missing"
    assert_registry "$DAEMON_ID" 1
    assert_acl_composed "$DAEMON_ID"
}

cycle_static(){
    say "static: create"
    "$CLI" service new "$STATIC_DOMAIN" --type website-static --env testing \
        --yes --no-ssl --no-mail || { no "create failed"; return; }
    verify_static
    say "static: remove"
    remove_static
    assert_no_file "/var/www/${STATIC_DOMAIN}"
    assert_no_file "/etc/apache2/sites-available/${STATIC_DOMAIN}.conf"
    assert_registry "$STATIC_ID" 0
    say "static: recreate"
    "$CLI" service new "$STATIC_DOMAIN" --type website-static --env testing \
        --yes --no-ssl --no-mail || { no "recreate failed"; return; }
    verify_static
    say "static: final cleanup"
    remove_static
    assert_registry "$STATIC_ID" 0
}

cycle_daemon(){
    say "daemon: create"
    "$CLI" service new "$DAEMON_ID" --type daemon --env testing --yes --no-mail \
        || { no "create failed"; return; }
    verify_daemon
    say "daemon: remove"
    remove_daemon
    assert_no_file "/opt/geodineum/services/${DAEMON_ID}"
    assert_no_file "/etc/systemd/system/geodineum-${DAEMON_ID}.service"
    assert_registry "$DAEMON_ID" 0
    say "daemon: recreate"
    "$CLI" service new "$DAEMON_ID" --type daemon --env testing --yes --no-mail \
        || { no "recreate failed"; return; }
    verify_daemon
    say "daemon: final cleanup"
    remove_daemon
    assert_registry "$DAEMON_ID" 0
}

# ---- main --------------------------------------------------------------------

case "$TYPE" in
    static) cycle_static ;;
    daemon) cycle_daemon ;;
    both)   cycle_static; cycle_daemon ;;
    *) die "unknown --type: $TYPE (static|daemon|both)" ;;
esac

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "${GRN}${BLD}CYCLE GREEN${NC} — ${PASS} assertions passed"
    exit 0
else
    echo "${RED}${BLD}CYCLE FAILED${NC} — ${FAIL} failed / ${PASS} passed (state left for inspection)"
    exit 1
fi

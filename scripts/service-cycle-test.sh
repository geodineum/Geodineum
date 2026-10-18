#!/usr/bin/env bash
# =============================================================================
# service-cycle-test.sh — create → verify → remove → recreate per service type
# =============================================================================
# Proves the taxonomy onboarding is idempotent and reversible: each tested
# type must reach the same green state on install and reinstall, and leave
# nothing behind on removal. Covers website-static, webapp-gcore and daemon
# (both ends of the matrix plus the public-gCore row); website-wp is covered
# by install-cycle-test.sh --site.
#
# Touches live state (ValKey identities, apache vhosts, systemd units) using
# throwaway cycletest_* names, and removes everything it created.
#
# Usage (root, from a repo checkout, on a box with gNode + ValKey live):
#   sudo ./scripts/service-cycle-test.sh --confirm [--type static|webapp|daemon|app|scheduled|all]
#
# Exit: 0 = every cycle green; 1 = a phase failed (state left for inspection).
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GNODE_SCRIPTS_DIR="${GNODE_SCRIPTS:-/opt/geodineum/gNode/scripts}"
TYPE="all"; CONFIRM="false"
STATIC_DOMAIN="cycletest-static.invalid"
STATIC_ID="cycletest_static_invalid"
WEBAPP_DOMAIN="cycletest-webapp.invalid"
WEBAPP_ID="cycletest_webapp_invalid"
DAEMON_ID="cycletest_daemon"
APP_ID="cycletest_app"
JOB_ID="cycletest_job"

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
vk_admin(){ REDISCLI_AUTH="$(cat "${CRED_DIR}/valkey.password")" valkey-cli --no-auth-warning --raw -p "${VALKEY_PORT:-47445}" "$@"; }
# <id> <0|1> [placed]: the entity and its intent in the constellation that holds them;
# "placed" also wants a site's placement on this node.
assert_registry(){
    local id="$1" want="$2" c got=0 intent=0 placed=0 node
    node="$(hostname -s)"
    for c in $(GNODE_DAEMON_ENV=/etc/geodineum/components/gnode-daemon/daemon.env bash -c 'source '"${GNODE_SCRIPTS_DIR}"'/cli/constellation.sh; gnode_cli_constellations'); do
        [[ "$(vk_admin HEXISTS "{$c}:gnode:constellation:entities" "$id")" == 1 ]] && got=1
        [[ "$(vk_admin HEXISTS "{$c}:gnode:registrations" "$id")" == 1 ]] && intent=1
        [[ "$(vk_admin HEXISTS "{$c}:gnode:constellation:entities" "${id}@${node}")" == 1 ]] && placed=1
    done
    [[ "$got" == "$want" ]] && ok "topology[$id] = $want" || no "topology[$id] = $got, want $want"
    [[ "$intent" == "$want" ]] && ok "intent[$id] = $want" || no "intent[$id] = $intent, want $want"
    if [[ "${3:-}" == placed ]]; then
        [[ "$placed" == 1 ]] && ok "placement ${id}@${node}" || no "no placement ${id}@${node}"
    fi
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
    # TOPOLOGY-ACL-SCOPE: the shared topology is daemon-written. As the client:
    # a raw mutation must be NOPERM, a no-writes read via FCALL_RO must work.
    local pw shared="{${GNODE_TOPOLOGY_NAMESPACE:-geodineum}}:gnode:constellation" reply
    pw=$(cat "${CRED_DIR}/valkey_client_$1.password" 2>/dev/null) || { no "client password unreadable for ${user}"; return; }
    reply=$(REDISCLI_AUTH="$pw" valkey-cli -p "${VALKEY_PORT:-47445}" --user "$user" --no-auth-warning \
        HDEL "${shared}:entities" __cycletest_never_exists__ 2>&1)
    if grep -q NOPERM <<< "$reply"; then
        ok "shared topology is read-only for ${user} (HDEL → NOPERM)"
    else
        no "shared topology is WRITABLE by ${user} (HDEL reply: ${reply})"
    fi
    reply=$(REDISCLI_AUTH="$pw" valkey-cli -p "${VALKEY_PORT:-47445}" --user "$user" --no-auth-warning \
        FCALL_RO GNODE_TOPO_STATS 1 "$shared" 2>&1)
    if grep -q NOPERM <<< "$reply"; then
        no "shared topology not readable via FCALL_RO for ${user}: ${reply}"
    else
        ok "shared topology readable via FCALL_RO for ${user}"
    fi
}

# ---- removal: the one route, which must leave nothing behind ----------------

remove_svc(){   # <id>
    if "$CLI" deregister "$1" --purge-data --force >/tmp/cycletest-deregister.$$ 2>&1; then
        ok "deregister $1: residue none"
    else
        no "deregister $1 left residue:"; sed -n '/Residue/,$p' /tmp/cycletest-deregister.$$ | sed 's/^/      /'
    fi
    rm -f /tmp/cycletest-deregister.$$
}
remove_static(){ remove_svc "$STATIC_ID"; }
remove_webapp(){ remove_svc "$WEBAPP_ID"; }
remove_daemon(){ remove_svc "$DAEMON_ID"; }

# ---- cycles ------------------------------------------------------------------

verify_static(){
    local root="/var/www/${STATIC_DOMAIN}"
    assert_file "${root}/public_html/index.html"
    assert_file "${root}/public_html/form/submit.php"
    assert_file "${root}/.geodineum/gnode_services.yaml"
    assert_file "/etc/apache2/sites-available/${STATIC_DOMAIN}.conf"
    assert_mode "${root}/.env-tier" "root:www-data:640"
    assert_mode "${CRED_DIR}/valkey_client_${STATIC_ID}.password" "root:geodineum-web:640"
    assert_registry "$STATIC_ID" 1 placed
    assert_acl_composed "$STATIC_ID"
}

verify_webapp(){
    local root="/var/www/${WEBAPP_DOMAIN}"
    assert_file "${root}/public_html/index.php"
    assert_file "${root}/public_html/g/hit.php"
    assert_file "${root}/src/bootstrap.php"
    assert_no_file "${root}/public_html/form/submit.php"   # --no-form: row is a no-op
    assert_file "${root}/.geodineum/gnode_services.yaml"
    assert_file "/etc/apache2/sites-available/${WEBAPP_DOMAIN}.conf"
    assert_mode "${root}/src" "root:www-data:750"
    assert_mode "${root}/src/bootstrap.php" "root:www-data:640"
    assert_mode "${root}/.env-tier" "root:www-data:640"
    assert_mode "${CRED_DIR}/valkey_client_${WEBAPP_ID}.password" "root:geodineum-web:640"
    if id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx geodineum-code; then
        ok "www-data ∈ geodineum-code"
    else
        no "www-data not in geodineum-code — the app cannot read gCore source"
    fi
    assert_registry "$WEBAPP_ID" 1 placed
    assert_acl_composed "$WEBAPP_ID"
}

verify_daemon(){
    local root="/opt/geodineum/services/${DAEMON_ID}"
    assert_file "${root}/.geodineum/gnode_services.yaml"
    assert_file "${root}/run"
    assert_file "/etc/systemd/system/geodineum-${DAEMON_ID}.service"
    assert_file "${root}/src/main.py"
    assert_file "/etc/geodineum/heartbeat/${DAEMON_ID}.env"
    systemctl is-enabled --quiet "geodineum-heartbeat@${DAEMON_ID}.timer" && ok "heartbeat timer enabled" || no "heartbeat timer geodineum-heartbeat@${DAEMON_ID}.timer not enabled"
    assert_mode "/etc/geodineum/services/${DAEMON_ID}.env" "root:${DAEMON_ID}:640"
    assert_mode "${CRED_DIR}/valkey_client_${DAEMON_ID}.password" "root:${DAEMON_ID}:640"
    id "$DAEMON_ID" >/dev/null 2>&1 && ok "system user ${DAEMON_ID}" || no "system user ${DAEMON_ID} missing"
    assert_registry "$DAEMON_ID" 1
    assert_acl_composed "$DAEMON_ID"
}

cycle_static(){
    say "static: create"
    "$CLI" register "$STATIC_DOMAIN" --new website-static --env testing \
        --yes --no-ssl --no-mail || { no "create failed"; return; }
    verify_static
    say "static: remove"
    remove_static
    assert_no_file "/var/www/${STATIC_DOMAIN}"
    assert_no_file "/etc/apache2/sites-available/${STATIC_DOMAIN}.conf"
    assert_registry "$STATIC_ID" 0
    say "static: recreate"
    "$CLI" register "$STATIC_DOMAIN" --new website-static --env testing \
        --yes --no-ssl --no-mail || { no "recreate failed"; return; }
    verify_static
    say "static: final cleanup"
    remove_static
    assert_registry "$STATIC_ID" 0
}

cycle_webapp(){
    say "webapp: create"
    "$CLI" register "$WEBAPP_DOMAIN" --new webapp-gcore --env testing \
        --yes --no-ssl --no-mail --no-form || { no "create failed"; return; }
    verify_webapp
    say "webapp: remove"
    remove_webapp
    assert_no_file "/var/www/${WEBAPP_DOMAIN}"
    assert_no_file "/etc/apache2/sites-available/${WEBAPP_DOMAIN}.conf"
    assert_registry "$WEBAPP_ID" 0
    say "webapp: recreate"
    "$CLI" register "$WEBAPP_DOMAIN" --new webapp-gcore --env testing \
        --yes --no-ssl --no-mail --no-form || { no "recreate failed"; return; }
    verify_webapp
    say "webapp: final cleanup"
    remove_webapp
    assert_registry "$WEBAPP_ID" 0
}

cycle_daemon(){
    say "daemon: create"
    "$CLI" register "$DAEMON_ID" --new daemon --lang python --env testing --yes --no-mail \
        || { no "create failed"; return; }
    verify_daemon
    say "daemon: remove"
    remove_daemon
    assert_no_file "/opt/geodineum/services/${DAEMON_ID}"
    assert_no_file "/etc/systemd/system/geodineum-${DAEMON_ID}.service"
    assert_registry "$DAEMON_ID" 0
    say "daemon: recreate"
    "$CLI" register "$DAEMON_ID" --new daemon --lang python --env testing --yes --no-mail \
        || { no "recreate failed"; return; }
    verify_daemon
    say "daemon: final cleanup"
    remove_daemon
    assert_registry "$DAEMON_ID" 0
}

verify_app(){
    local root="/opt/geodineum/services/${APP_ID}"
    assert_file "${root}/src/main.py"
    assert_file "/etc/systemd/system/geodineum-${APP_ID}.service"
    grep -q '^PORT=48791' "/etc/geodineum/services/${APP_ID}.env" && ok "app env carries its port" || no "app env has no PORT=48791"
    grep -q '^PROBE=http:http://127.0.0.1:48791/health' "/etc/geodineum/heartbeat/${APP_ID}.env" && ok "app heartbeat probes /health" || no "app heartbeat probe is not its /health"
    grep -q 'shape: app' "${root}/.geodineum/gnode_services.yaml" && ok "manifest shape app" || no "manifest is not shape app"
    assert_registry "$APP_ID" 1
}

verify_job(){
    local root="/opt/geodineum/services/${JOB_ID}"
    assert_file "${root}/src/main.sh"
    assert_file "/etc/systemd/system/geodineum-${JOB_ID}.timer"
    systemctl is-enabled --quiet "geodineum-${JOB_ID}.timer" && ok "job timer enabled" || no "job timer not enabled"
    grep -q "^PROBE=unit:geodineum-${JOB_ID}.timer" "/etc/geodineum/heartbeat/${JOB_ID}.env" && ok "job heartbeat probes its timer" || no "job heartbeat probe is not its timer"
    assert_registry "$JOB_ID" 1
}

remove_app(){ remove_svc "$APP_ID"; }
remove_job(){ remove_svc "$JOB_ID"; }

cycle_app(){
    say "app: create"
    "$CLI" register "$APP_ID" --new app --lang python --port 48791 --env testing --yes --no-mail || { no "create failed"; return; }
    verify_app
    say "app: remove"
    remove_app
    assert_no_file "/opt/geodineum/services/${APP_ID}"
    assert_no_file "/etc/geodineum/heartbeat/${APP_ID}.env"
    assert_registry "$APP_ID" 0
}

cycle_job(){
    say "scheduled: create"
    "$CLI" register "$JOB_ID" --new scheduled --schedule daily --lang bash --env testing --yes --no-mail || { no "create failed"; return; }
    verify_job
    say "scheduled: remove"
    remove_job
    assert_no_file "/opt/geodineum/services/${JOB_ID}"
    assert_no_file "/etc/systemd/system/geodineum-${JOB_ID}.timer"
    assert_registry "$JOB_ID" 0
}

# ---- main --------------------------------------------------------------------

case "$TYPE" in
    static) cycle_static ;;
    webapp) cycle_webapp ;;
    daemon) cycle_daemon ;;
    both)   cycle_static; cycle_daemon ;;
    app)    cycle_app ;;
    scheduled) cycle_job ;;
    all)    cycle_static; cycle_webapp; cycle_daemon; cycle_app; cycle_job ;;
    *) die "unknown --type: $TYPE (static|webapp|daemon|app|scheduled|all)" ;;
esac

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "${GRN}${BLD}CYCLE GREEN${NC} — ${PASS} assertions passed"
    exit 0
else
    echo "${RED}${BLD}CYCLE FAILED${NC} — ${FAIL} failed / ${PASS} passed (state left for inspection)"
    exit 1
fi

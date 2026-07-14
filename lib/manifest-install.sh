#!/bin/bash
# =============================================================================
# manifest-install.sh — execute LAYER_2 (install) + LAYER_6 (backup) hooks
# =============================================================================
# Reads a service's geodeploy.yaml install:/uninstall: sections and runs them
# with the documented manifest contract (LAYER_2):
#
#   install.prerequisites.apt/php_ext/commands  - checked, optionally installed
#   install.steps[]                              - ordered, idempotent
#     name                                       - identifier
#     run                                        - script path relative to manifest dir
#     on_failure: fatal | warn | skip            - explicit graceful degradation
#     requires_sudo: bool                        - refuse if we lack permission
#     timeout_seconds: int (default 600)         - hard timeout per step
#   install.health_check                         - script; exit 0 = healthy
#   uninstall.steps[]                            - mirrors install.steps
#   uninstall.preserve_on_keep_data[]            - paths NOT deleted under --keep-data
#
# Audit trail (best-effort, published to ValKey under geodineum:registry:<name>):
#   install:last_run_at, install:last_run_ok, install:last_run_reason
#   health:last_check_at, health:last_ok, health:last_reason
#
# Concurrency: each service install/uninstall holds a flock on
# /var/lock/geodineum-service-<name>.lock to prevent two runs colliding.
#
# Failure model: every operation reports its outcome via exit code AND
# stdout/stderr. Library functions return 0/1 — they do NOT call exit; the
# caller (geodineum CLI handler) decides whether a failure aborts a session.
# =============================================================================

[[ -n "${_GEODINEUM_MANIFEST_INSTALL_SH:-}" ]] && return 0
_GEODINEUM_MANIFEST_INSTALL_SH=1

# Source registry for audit-trail writes (best-effort; missing is OK)
_mi_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_mi_lib_dir}/manifest-registry.sh" ]] && source "${_mi_lib_dir}/manifest-registry.sh"

# Colors — only if stdout is a TTY and not already set by a caller
if [[ -t 1 ]] && [[ -z "${MI_RED:-}" ]]; then
    MI_RED='\033[0;31m'; MI_GREEN='\033[0;32m'; MI_YELLOW='\033[1;33m'
    MI_CYAN='\033[0;36m'; MI_DIM='\033[2m'; MI_BOLD='\033[1m'; MI_NC='\033[0m'
else
    MI_RED=''; MI_GREEN=''; MI_YELLOW=''; MI_CYAN=''; MI_DIM=''; MI_BOLD=''; MI_NC=''
fi

_mi_log()    { echo -e "${MI_CYAN}[INFO]${MI_NC} $*"; }
_mi_ok()     { echo -e "${MI_GREEN}[OK]${MI_NC}   $*"; }
_mi_warn()   { echo -e "${MI_YELLOW}[WARN]${MI_NC} $*" >&2; }
_mi_fail()   { echo -e "${MI_RED}[FAIL]${MI_NC} $*" >&2; }
_mi_dry()    { echo -e "${MI_DIM}[DRY]${MI_NC}  $*"; }

# ---- helpers ---------------------------------------------------------------

# Echo manifest path for a name, by searching well-known locations.
# Usage: _mi_find_manifest <name>
_mi_find_manifest() {
    local name="$1"
    local root="${GEODINEUM_ROOT:-/opt/geodineum}"
    local candidate

    # 1. Registry-known path
    if declare -F manifest_get_field >/dev/null 2>&1; then
        candidate=$(manifest_get_field "$name" "manifest_path" 2>/dev/null)
        [[ -n "$candidate" && -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    fi
    # 2. /opt/geodineum/<name>/geodeploy.yaml
    candidate="${root}/${name}/geodeploy.yaml"
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    # 3. ./services/<name>/geodeploy.yaml
    candidate="./services/${name}/geodeploy.yaml"
    [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }

    return 1
}

# Resolve manifest arg — accept full path OR name. Echo the resolved path.
_mi_resolve_manifest() {
    local arg="$1"
    if [[ -f "$arg" ]]; then
        printf '%s' "$arg"
        return 0
    fi
    _mi_find_manifest "$arg"
}

# Read .name from a manifest (fallback: dirname).
_mi_manifest_name() {
    local m="$1"
    local n
    n=$(yq eval '.name // ""' "$m" 2>/dev/null)
    [[ -n "$n" && "$n" != "null" ]] && { printf '%s' "$n"; return 0; }
    basename "$(dirname "$m")"
}

# Run a step. Echoes step result. Returns:
#   0 — step OK
#   1 — step failed and on_failure=fatal (caller should abort the chain)
#   2 — step failed but on_failure=warn or skip (caller should continue)
# Usage: _mi_run_step <manifest-dir> <name> <run> <on_failure> <requires_sudo> <timeout_seconds> <dry_run>
_mi_run_step() {
    local mdir="$1" name="$2" run="$3" on_failure="$4" requires_sudo="$5"
    local timeout_s="$6" dry_run="$7"

    local script="${mdir}/${run}"
    if [[ ! -f "$script" ]]; then
        _mi_fail "[$name] script not found: ${script}"
        [[ "$on_failure" == "fatal" ]] && return 1 || return 2
    fi
    if [[ ! -x "$script" ]]; then
        _mi_warn "[$name] script not executable, attempting with bash: ${script}"
    fi

    local prefix=""
    if [[ "$requires_sudo" == "true" ]]; then
        if [[ "$EUID" -ne 0 ]]; then
            _mi_fail "[$name] requires_sudo: true but caller is not root"
            [[ "$on_failure" == "fatal" ]] && return 1 || return 2
        fi
    fi

    if [[ "$dry_run" == "true" ]]; then
        _mi_dry "[$name] would run: ${script} (timeout=${timeout_s}s, on_failure=${on_failure})"
        return 0
    fi

    _mi_log "[$name] running ${run} (timeout=${timeout_s}s)"
    local t0 t1 rc
    t0=$(date +%s 2>/dev/null || echo 0)

    if [[ -x "$script" ]]; then
        timeout --preserve-status "$timeout_s" "$script" 2>&1
        rc=$?
    else
        timeout --preserve-status "$timeout_s" bash "$script" 2>&1
        rc=$?
    fi

    t1=$(date +%s 2>/dev/null || echo 0)
    local elapsed=$((t1 - t0))

    if [[ $rc -eq 0 ]]; then
        _mi_ok "[$name] completed in ${elapsed}s"
        return 0
    fi

    if [[ $rc -eq 124 ]]; then
        _mi_fail "[$name] TIMEOUT after ${timeout_s}s"
    else
        _mi_fail "[$name] exit=${rc} (after ${elapsed}s)"
    fi

    case "$on_failure" in
        fatal) return 1 ;;
        warn)  _mi_warn "[$name] on_failure=warn — continuing"; return 2 ;;
        skip)  return 2 ;;
        *)     _mi_warn "[$name] unknown on_failure='${on_failure}', treating as fatal"; return 1 ;;
    esac
}

# Acquire per-service lock (flock). Uses fixed FD 200 — the dynamic
# {VAR}>file syntax is bash-4.1+ but behaves inconsistently in
# `bash -c` subshells, so we stay portable. Returns 1 on conflict, 0 on
# acquired (or if locking isn't possible — we warn but don't block).
_mi_lock() {
    local name="$1"
    local lockfile="/var/lock/geodineum-service-${name}.lock"
    # /var/lock is a symlink to /run/lock on systemd hosts; -d follows the
    # symlink. Fall back to /tmp if /var/lock isn't writable.
    if ! ( [[ -d /var/lock ]] && [[ -w /var/lock ]] ); then
        lockfile="/tmp/geodineum-service-${name}.lock"
    fi
    # Open FD 200 for writing. If open itself fails, warn and proceed
    # without lock — the executor's idempotency contract is the real safety
    # net; the lock is only "don't accidentally double-run".
    if ! eval "exec 200>\"$lockfile\"" 2>/dev/null; then
        _mi_warn "could not open lockfile $lockfile — running without lock"
        MI_LOCK_FD=""
        return 0
    fi
    if ! flock -n 200; then
        _mi_fail "another install/uninstall for '${name}' is in progress (lock $lockfile)"
        exec 200>&-
        return 1
    fi
    MI_LOCK_FD=200
    return 0
}

_mi_unlock() {
    [[ -n "${MI_LOCK_FD:-}" ]] && exec 200>&- 2>/dev/null
    MI_LOCK_FD=""
}

# Publish audit-trail fields to registry. Best-effort.
_mi_audit() {
    local name="$1"; shift
    declare -F manifest_get_field >/dev/null 2>&1 || return 0
    declare -F _manifest_valkey_cli >/dev/null 2>&1 || return 0
    _manifest_valkey_cli HSET "geodineum:registry:${name}" "$@" >/dev/null 2>&1 || true
}

# ---- public API: prerequisites ---------------------------------------------

# Check install.prerequisites. Echoes missing items; returns 0 if all met, 1 otherwise.
# Usage: service_check_prerequisites <manifest>
service_check_prerequisites() {
    local m
    m=$(_mi_resolve_manifest "$1") || { _mi_fail "manifest not found: $1"; return 1; }
    command -v yq &>/dev/null || { _mi_fail "yq required"; return 1; }

    local name; name=$(_mi_manifest_name "$m")
    local missing=0

    # commands
    while IFS= read -r cmd; do
        [[ -z "$cmd" || "$cmd" == "null" ]] && continue
        if ! command -v "$cmd" >/dev/null 2>&1; then
            _mi_warn "[${name}] missing command on PATH: $cmd"
            missing=$((missing + 1))
        fi
    done < <(yq eval '.install.prerequisites.commands[] // empty' "$m" 2>/dev/null)

    # apt
    while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" == "null" ]] && continue
        if command -v dpkg >/dev/null 2>&1; then
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                _mi_warn "[${name}] apt package not installed: $pkg"
                missing=$((missing + 1))
            fi
        fi
    done < <(yq eval '.install.prerequisites.apt[] // empty' "$m" 2>/dev/null)

    # php_ext — only check if `php` is on PATH
    if command -v php >/dev/null 2>&1; then
        local php_loaded
        php_loaded=$(php -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
        while IFS= read -r ext; do
            [[ -z "$ext" || "$ext" == "null" ]] && continue
            if ! printf '%s\n' "$php_loaded" | grep -qx "$(echo "$ext" | tr '[:upper:]' '[:lower:]')"; then
                _mi_warn "[${name}] PHP extension not loaded: $ext"
                missing=$((missing + 1))
            fi
        done < <(yq eval '.install.prerequisites.php_ext[] // empty' "$m" 2>/dev/null)
    fi

    if [[ $missing -eq 0 ]]; then
        _mi_ok "[${name}] prerequisites met"
        return 0
    fi
    _mi_fail "[${name}] $missing prerequisite(s) missing"
    return 1
}

# ---- public API: install ---------------------------------------------------

# Execute install.steps in order. Returns 0 on success, 1 on first fatal failure.
# Options:
#   MI_DRY_RUN=true       — print what would happen, do not execute
#   MI_SKIP_PREREQ=true   — skip prerequisites check (use after a prior pass)
#   MI_SKIP_HEALTH=true   — skip health_check
# Usage: service_install <manifest>
service_install() {
    local m
    m=$(_mi_resolve_manifest "$1") || { _mi_fail "manifest not found: $1"; return 1; }
    command -v yq &>/dev/null || { _mi_fail "yq required"; return 1; }

    local name mdir
    name=$(_mi_manifest_name "$m")
    mdir=$(dirname "$m")

    _mi_log "${MI_BOLD}Installing service:${MI_NC} $name"
    _mi_log "${MI_DIM}manifest: ${m}${MI_NC}"

    _mi_lock "$name" || return 1
    # shellcheck disable=SC2064
    trap "_mi_unlock" RETURN

    # Prerequisites gate (default ON)
    if [[ "${MI_SKIP_PREREQ:-false}" != "true" ]]; then
        if ! service_check_prerequisites "$m"; then
            _mi_fail "[${name}] prerequisites not met — aborting (use MI_SKIP_PREREQ=true to bypass)"
            _mi_audit "$name" install:last_run_at "$(date -Iseconds)" install:last_run_ok "false" install:last_run_reason "prerequisites-not-met"
            return 1
        fi
    fi

    # Iterate steps (no install: section ⇒ no-op success)
    local step_count
    step_count=$(yq eval '(.install.steps // []) | length' "$m" 2>/dev/null)
    [[ "$step_count" =~ ^[0-9]+$ ]] || step_count=0

    if [[ "$step_count" -eq 0 ]]; then
        _mi_log "[${name}] no install.steps — convention default no-op"
    fi

    local i passed=0 warned=0
    for ((i=0; i<step_count; i++)); do
        local sname srun son_failure srequires_sudo stimeout
        sname=$(yq eval        ".install.steps[$i].name"            "$m")
        srun=$(yq eval         ".install.steps[$i].run"             "$m")
        son_failure=$(yq eval  ".install.steps[$i].on_failure // \"fatal\"" "$m")
        srequires_sudo=$(yq eval ".install.steps[$i].requires_sudo // false" "$m")
        stimeout=$(yq eval     ".install.steps[$i].timeout_seconds // 600" "$m")

        _mi_run_step "$mdir" "$sname" "$srun" "$son_failure" "$srequires_sudo" "$stimeout" \
                     "${MI_DRY_RUN:-false}"
        case $? in
            0) passed=$((passed + 1)) ;;
            1) _mi_fail "[${name}] install aborted at step '$sname'"
               _mi_audit "$name" install:last_run_at "$(date -Iseconds)" install:last_run_ok "false" install:last_run_reason "fatal-step-$sname"
               return 1 ;;
            2) warned=$((warned + 1)) ;;
        esac
    done

    # Health check (optional, default ON)
    local health_ok="skipped" health_reason=""
    local health_check
    health_check=$(yq eval '.install.health_check // ""' "$m" 2>/dev/null)
    if [[ -n "$health_check" && "$health_check" != "null" && "${MI_SKIP_HEALTH:-false}" != "true" ]]; then
        local hscript="${mdir}/${health_check}"
        if [[ "${MI_DRY_RUN:-false}" == "true" ]]; then
            _mi_dry "[${name}] would run health_check: ${hscript}"
            health_ok="dry-run"
        elif [[ ! -f "$hscript" ]]; then
            _mi_warn "[${name}] health_check script not found: ${hscript}"
            health_ok="false"; health_reason="script-missing"
        else
            _mi_log "[${name}] running health_check: ${health_check}"
            if [[ -x "$hscript" ]]; then
                "$hscript"; local hrc=$?
            else
                bash "$hscript"; local hrc=$?
            fi
            if [[ $hrc -eq 0 ]]; then
                _mi_ok "[${name}] health_check OK"; health_ok="true"
            else
                _mi_warn "[${name}] health_check exit=$hrc"; health_ok="false"; health_reason="exit-$hrc"
            fi
        fi
        _mi_audit "$name" health:last_check_at "$(date -Iseconds)" health:last_ok "$health_ok" health:last_reason "$health_reason"
    fi

    _mi_audit "$name" install:last_run_at "$(date -Iseconds)" install:last_run_ok "true" install:last_run_reason "ok"
    _mi_ok "${MI_BOLD}[${name}] install complete${MI_NC} (steps: ${passed} ok, ${warned} warned, health: ${health_ok})"
    return 0
}

# ---- public API: uninstall ------------------------------------------------

# Execute uninstall.steps. Path preservation via preserve_on_keep_data.
# Options: MI_DRY_RUN=true, MI_KEEP_DATA=true
# Usage: service_uninstall <manifest>
service_uninstall() {
    local m
    m=$(_mi_resolve_manifest "$1") || { _mi_fail "manifest not found: $1"; return 1; }
    command -v yq &>/dev/null || { _mi_fail "yq required"; return 1; }

    local name mdir
    name=$(_mi_manifest_name "$m")
    mdir=$(dirname "$m")

    _mi_log "${MI_BOLD}Uninstalling service:${MI_NC} $name"
    _mi_log "${MI_DIM}manifest: ${m}${MI_NC}"
    [[ "${MI_KEEP_DATA:-false}" == "true" ]] && _mi_log "${MI_YELLOW}--keep-data${MI_NC} (preserve_on_keep_data paths will NOT be removed)"

    _mi_lock "$name" || return 1
    # shellcheck disable=SC2064
    trap "_mi_unlock" RETURN

    local step_count
    step_count=$(yq eval '(.uninstall.steps // []) | length' "$m" 2>/dev/null)
    [[ "$step_count" =~ ^[0-9]+$ ]] || step_count=0

    if [[ "$step_count" -eq 0 ]]; then
        _mi_log "[${name}] no uninstall.steps — nothing to run"
    fi

    local i passed=0 warned=0
    for ((i=0; i<step_count; i++)); do
        local sname srun son_failure srequires_sudo stimeout
        sname=$(yq eval        ".uninstall.steps[$i].name"            "$m")
        srun=$(yq eval         ".uninstall.steps[$i].run"             "$m")
        son_failure=$(yq eval  ".uninstall.steps[$i].on_failure // \"warn\"" "$m")  # default warn for uninstall
        srequires_sudo=$(yq eval ".uninstall.steps[$i].requires_sudo // false" "$m")
        stimeout=$(yq eval     ".uninstall.steps[$i].timeout_seconds // 600" "$m")

        _mi_run_step "$mdir" "$sname" "$srun" "$son_failure" "$srequires_sudo" "$stimeout" \
                     "${MI_DRY_RUN:-false}"
        case $? in
            0) passed=$((passed + 1)) ;;
            1) _mi_fail "[${name}] uninstall aborted at step '$sname'"; return 1 ;;
            2) warned=$((warned + 1)) ;;
        esac
    done

    # Report preserve_on_keep_data paths (informational; we do NOT delete other paths
    # — that's the steps' job. We only enumerate so the operator knows what stayed.)
    if [[ "${MI_KEEP_DATA:-false}" == "true" ]]; then
        local preserved
        preserved=$(yq eval '(.uninstall.preserve_on_keep_data // []) | .[]' "$m" 2>/dev/null)
        if [[ -n "$preserved" ]]; then
            _mi_log "[${name}] preserved on --keep-data:"
            printf '%s\n' "$preserved" | sed 's/^/    /'
        fi
    fi

    # Drop registry entry (best-effort)
    if declare -F manifest_drop_registry >/dev/null 2>&1; then
        manifest_drop_registry "$name"
    fi

    _mi_ok "${MI_BOLD}[${name}] uninstall complete${MI_NC} (steps: ${passed} ok, ${warned} warned)"
    return 0
}

# ---- public API: health ---------------------------------------------------

# Run the health_check script in isolation. Useful for periodic checks.
# Usage: service_health <manifest>
service_health() {
    local m
    m=$(_mi_resolve_manifest "$1") || { _mi_fail "manifest not found: $1"; return 1; }
    local name; name=$(_mi_manifest_name "$m")
    local mdir; mdir=$(dirname "$m")

    local health_check
    health_check=$(yq eval '.install.health_check // ""' "$m" 2>/dev/null)
    if [[ -z "$health_check" || "$health_check" == "null" ]]; then
        _mi_log "[${name}] no health_check declared"
        return 0
    fi

    local hscript="${mdir}/${health_check}"
    if [[ ! -f "$hscript" ]]; then
        _mi_fail "[${name}] health_check script not found: ${hscript}"
        _mi_audit "$name" health:last_check_at "$(date -Iseconds)" health:last_ok "false" health:last_reason "script-missing"
        return 1
    fi

    _mi_log "[${name}] running health_check: ${health_check}"
    if [[ -x "$hscript" ]]; then
        "$hscript"; local rc=$?
    else
        bash "$hscript"; local rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        _mi_ok "[${name}] healthy"
        _mi_audit "$name" health:last_check_at "$(date -Iseconds)" health:last_ok "true" health:last_reason ""
        return 0
    fi
    _mi_fail "[${name}] health_check exit=$rc"
    _mi_audit "$name" health:last_check_at "$(date -Iseconds)" health:last_ok "false" health:last_reason "exit-$rc"
    return 1
}

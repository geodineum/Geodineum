#!/bin/bash
# =============================================================================
# geodeploy — shared deploy library for the Geodineum ecosystem
# =============================================================================
# Git operations, permissions, build actions, service management and
# dirty-tree recovery. Sourced by scripts/geodeploy-orchestrator,
# scripts/fix-permissions.sh and install.sh.
#
# Optional overlay lib/geodeploy-extras.sh (not in this repo) may define
#   geodeploy_fix_extras <name> <repo_dir>   — per-component fix-ups
#   geodeploy_fix_log_extras <log_root>      — extra log-dir ownership
# =============================================================================

set -euo pipefail

# Per-site PHP pools: a site with a record in /etc/geodineum/web keeps its own user on its writable dirs.
_GD_SITE_POOL_LIB="$(dirname "${BASH_SOURCE[0]}")/site-pool.sh"
# shellcheck source=site-pool.sh
[[ -f "$_GD_SITE_POOL_LIB" ]] && source "$_GD_SITE_POOL_LIB"

_GEODEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_GEODEPLOY_LIB_DIR}/geodeploy-extras.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_GEODEPLOY_LIB_DIR}/geodeploy-extras.sh"
fi

# =============================================================================
# Configuration
# =============================================================================
GEODINEUM_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"
GEODINEUM_LOG_ROOT="${GEODINEUM_LOG_ROOT:-/var/log/geodineum}"
# Must be writable by the deploy user: git commands run as that user append here too.
GEODEPLOY_LOG="${GEODEPLOY_LOG:-${GEODINEUM_LOG_ROOT}/deploy/auto-deploy.log}"
GEODEPLOY_LOG_MAX="${GEODEPLOY_LOG_MAX:-2000}"
# Deploy user from the environment, else /etc/geodineum/deploy.env (the only source under cron).
if [[ -z "${GEODEPLOY_DEPLOY_USER:-}" ]] && [[ -n "${DEPLOY_USER:-}" ]]; then
    GEODEPLOY_DEPLOY_USER="$DEPLOY_USER"
fi
if [[ -z "${GEODEPLOY_DEPLOY_USER:-}" ]] && [[ -r /etc/geodineum/deploy.env ]]; then
    # shellcheck source=/dev/null
    . /etc/geodineum/deploy.env
    GEODEPLOY_DEPLOY_USER="${DEPLOY_USER:-}"
fi
GEODEPLOY_DEPLOY_USER="${GEODEPLOY_DEPLOY_USER:-${SUDO_USER:-${USER:-}}}"
if [[ -z "$GEODEPLOY_DEPLOY_USER" ]]; then
    # Log always; stderr (cron mail) at most once per hour.
    _gd_fatal_msg="FATAL: deploy user unresolved (GEODEPLOY_DEPLOY_USER + DEPLOY_USER + /etc/geodineum/deploy.env + SUDO_USER + USER all empty). Set GEODEPLOY_DEPLOY_USER explicitly or run install.sh first."
    if declare -F geodeploy_log >/dev/null 2>&1; then
        geodeploy_log "$_gd_fatal_msg"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $_gd_fatal_msg" >> "$GEODEPLOY_LOG" 2>/dev/null || true
    fi
    _gd_fatal_stamp="$(dirname "$GEODEPLOY_LOG")/.fatal-stderr-stamp"
    _gd_now=$(date +%s)
    _gd_last=$(cat "$_gd_fatal_stamp" 2>/dev/null || echo 0)
    if (( _gd_now - _gd_last > 3600 )); then
        echo "$_gd_fatal_msg" >&2
        echo "$_gd_now" > "$_gd_fatal_stamp" 2>/dev/null || true
    fi
    return 1 2>/dev/null || exit 1
fi

# Loaded from geodeploy.yaml per-repo (defaults)
_GD_OWNER="${GEODEPLOY_DEPLOY_USER}"
_GD_GROUP="gnode"
_GD_SERVICE=""
_GD_DIRTY="discard"
_GD_BUILD_TYPE=""
_GD_BUILD_DIR=""
_GD_BUILD_CMD=""
_GD_TRIGGERS=()

# =============================================================================
# Logging
# =============================================================================
# A message identical to the previous line collapses into it with a repeat counter.
geodeploy_log() {
    local raw="$1"
    local last
    last=$(tail -n 1 "$GEODEPLOY_LOG" 2>/dev/null || true)

    local last_body="${last#\[*\] }"
    last_body="${last_body% (repeated *}"

    if [[ -n "$last" && "$last_body" == "$raw" ]]; then
        local n=1
        if [[ "$last" =~ \(repeated\ ([0-9]+)x ]]; then
            n="${BASH_REMATCH[1]}"
        fi
        n=$((n + 1))
        # Safe: the orchestrator's flock makes this the only writer.
        local first_stamp="${last%%]*}]"
        sed -i '$d' "$GEODEPLOY_LOG" 2>/dev/null || true
        echo "${first_stamp} ${raw} (repeated ${n}x, last $(date '+%Y-%m-%d %H:%M:%S'))" >> "$GEODEPLOY_LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $raw" >> "$GEODEPLOY_LOG"
    fi

    local lc
    lc=$(wc -l < "$GEODEPLOY_LOG" 2>/dev/null || echo 0)
    if [ "$lc" -gt "$GEODEPLOY_LOG_MAX" ]; then
        tail -n "$GEODEPLOY_LOG_MAX" "$GEODEPLOY_LOG" > "${GEODEPLOY_LOG}.tmp"
        mv "${GEODEPLOY_LOG}.tmp" "$GEODEPLOY_LOG"
    fi
}

# =============================================================================
# Deploy-user execution
# =============================================================================
# Every git call runs as the deploy user: root git in its repos fails dubious-ownership and returns empty revs.
geodeploy_as_deploy() {
    if [[ "$(/usr/bin/id -un)" == "$GEODEPLOY_DEPLOY_USER" ]]; then
        "$@"
    else
        local _home
        _home=$(/usr/bin/getent passwd "$GEODEPLOY_DEPLOY_USER" | /usr/bin/cut -d: -f6)
        /usr/bin/sudo -u "$GEODEPLOY_DEPLOY_USER" \
            env HOME="$_home" PATH="${_home}/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
            "$@"
    fi
}

# =============================================================================
# YAML parsing — extract geodeploy.yaml into shell variables
# =============================================================================
geodeploy_parse_descriptor() {
    local descriptor="$1"

    if [[ ! -f "$descriptor" ]]; then
        return 1
    fi

    local parsed
    parsed=$(python3 -c "
import yaml, sys, json
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
r = d.get('runtime', {})
b = d.get('build', {})
dt = d.get('dirty-tree', {})
triggers = d.get('triggers', [])
print(json.dumps({
    'owner': r.get('owner', '${GEODEPLOY_DEPLOY_USER}'),
    'group': r.get('group', 'gnode'),
    'service': r.get('service', ''),
    'dirty': dt.get('strategy', 'discard'),
    'build_type': b.get('type', ''),
    'build_dir': b.get('working_dir', '.'),
    'build_cmd': b.get('command', ''),
    'triggers': [{'match': t.get('match',''), 'actions': t.get('actions',[])} for t in triggers]
}))
" "$descriptor" 2>/dev/null) || return 1

    _GD_OWNER=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['owner'])")
    _GD_GROUP=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['group'])")
    _GD_SERVICE=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['service'])")
    _GD_DIRTY=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['dirty'])")
    _GD_BUILD_TYPE=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['build_type'])")
    _GD_BUILD_DIR=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['build_dir'])")
    _GD_BUILD_CMD=$(echo "$parsed" | python3 -c "import sys,json; print(json.load(sys.stdin)['build_cmd'])")

    return 0
}

# Set defaults for a component type (when no geodeploy.yaml exists)
geodeploy_set_defaults() {
    local comp_type="${1:-php}"  # php | rust-daemon | rust-lib | lua | bash

    _GD_OWNER="${GEODEPLOY_DEPLOY_USER}"
    _GD_DIRTY="discard"
    _GD_BUILD_TYPE=""
    _GD_BUILD_DIR="."
    _GD_BUILD_CMD=""
    _GD_SERVICE=""

    case "$comp_type" in
        php)
            _GD_GROUP="www-data"
            ;;
        rust-daemon|lua|bash)
            _GD_GROUP="gnode"
            ;;
        rust-lib)
            _GD_GROUP="gnode"
            ;;
        *)
            _GD_GROUP="gnode"
            ;;
    esac
}

# =============================================================================
# Git operations
# =============================================================================
geodeploy_fetch() {
    local branch="$1"
    local remote="${2:-origin}"

    # The permission sweeps own file modes; git tracking them would show a dirty tree.
    geodeploy_as_deploy git config core.fileMode false 2>> "$GEODEPLOY_LOG"
    geodeploy_as_deploy git fetch "$remote" "$branch" 2>> "$GEODEPLOY_LOG"
}

# Every checkout under GEODINEUM_ROOT: never pushes, never tracks modes. Runs as the checkout's owner.
geodeploy_assert_git_guards() {
    local dir name owner now changed
    for dir in "${GEODINEUM_ROOT}"/*/; do
        [[ -d "${dir}.git" ]] || continue
        name="$(basename "$dir")"
        owner="$(/usr/bin/stat -c %U "$dir")"
        changed=""
        for kv in "remote.origin.pushurl=READ_ONLY_DEPLOY_NO_PUSH" "core.fileMode=false"; do
            now="$(_geodeploy_git_as "$owner" -C "$dir" config --get "${kv%%=*}" 2>/dev/null)" || now=""
            [[ "$now" == "${kv#*=}" ]] && continue
            if _geodeploy_git_as "$owner" -C "$dir" config "${kv%%=*}" "${kv#*=}" 2>> "$GEODEPLOY_LOG"; then
                changed+=" ${kv%%=*}=${kv#*=}"
            else
                geodeploy_log "${name}: WARN could not set ${kv%%=*} (as ${owner})"
            fi
        done
        if [[ -n "$changed" ]]; then geodeploy_log "${name}: guards set:${changed}"; fi
    done
    return 0
}

# An unmanaged checkout is never pulled: fetch its refs only and log it when behind origin.
geodeploy_report_unmanaged_behind() {
    local dir="${1%/}" name owner branch behind
    name="$(basename "$dir")"
    owner="$(/usr/bin/stat -c %U "${dir}/.git" 2>/dev/null)" || return 0
    _geodeploy_git_as "$owner" -c core.sshCommand="ssh -o BatchMode=yes -o ConnectTimeout=15" \
        -C "$dir" fetch -q origin 2>/dev/null || { geodeploy_log "COVERAGE: ${name} (unmanaged) could not be fetched"; return 0; }
    branch="$(_geodeploy_git_as "$owner" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
    behind="$(_geodeploy_git_as "$owner" -C "$dir" rev-list --count "HEAD..origin/${branch}" 2>/dev/null)" || return 0
    if [[ "${behind:-0}" -gt 0 ]]; then
        local how="sudo -u ${owner} git -C ${dir} pull --ff-only"
        [[ "$name" == "Geodineum-BAK" ]] && how="sudo bash <another checkout>/scripts/deploy.sh"
        geodeploy_log "COVERAGE WARNING: ${name} is unmanaged and ${behind} commit(s) behind origin/${branch} — deploy it by hand: ${how}"
    fi
    return 0
}

_geodeploy_git_as() {
    local owner="$1"; shift
    if [[ "$(/usr/bin/id -un)" == "$owner" ]]; then git "$@"
    elif [[ "$owner" == "$GEODEPLOY_DEPLOY_USER" ]]; then geodeploy_as_deploy git "$@"
    else /usr/bin/sudo -u "$owner" git "$@"; fi
}

geodeploy_has_changes() {
    local branch="$1"
    local local_rev remote_rev

    local_rev=$(geodeploy_as_deploy git rev-parse HEAD 2>/dev/null)
    remote_rev=$(geodeploy_as_deploy git rev-parse "origin/${branch}" 2>/dev/null)

    [[ "$local_rev" != "$remote_rev" ]]
}

geodeploy_get_changed() {
    local branch="$1"
    geodeploy_as_deploy git diff --name-only HEAD "origin/${branch}" 2>/dev/null
}

geodeploy_get_revs() {
    local branch="$1"
    local local_rev remote_rev count

    local_rev=$(geodeploy_as_deploy git rev-parse --short HEAD 2>/dev/null)
    remote_rev=$(geodeploy_as_deploy git rev-parse --short "origin/${branch}" 2>/dev/null)
    count=$(geodeploy_as_deploy git rev-list --count HEAD.."origin/${branch}" 2>/dev/null || echo 0)

    echo "${local_rev}|${remote_rev}|${count}"
}

geodeploy_pull() {
    local branch="$1"
    # Deploy targets mirror origin: reset, never merge; checkout -B re-attaches a detached HEAD.
    geodeploy_as_deploy git reset --hard "origin/${branch}" 2>> "$GEODEPLOY_LOG" || return 1
    geodeploy_as_deploy git symbolic-ref -q HEAD >/dev/null 2>&1 \
        || geodeploy_as_deploy git checkout -B "$branch" "origin/${branch}" 2>> "$GEODEPLOY_LOG"
}

# =============================================================================
# Dirty tree handling
# =============================================================================
geodeploy_handle_dirty() {
    local strategy="${1:-stash}"
    local name="${2:-unknown}"

    if geodeploy_as_deploy git diff --quiet HEAD 2>/dev/null && [ -z "$(geodeploy_as_deploy git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        return 0  # Clean
    fi

    case "$strategy" in
        stash|discard)
            # clean must keep untracked runtime dirs: daemon state, ValKey backups, caches, cargo target/.
            geodeploy_log "${name}: DISCARD dirty tree (force-sync to origin)"
            geodeploy_as_deploy git checkout -- . 2>> "$GEODEPLOY_LOG"
            geodeploy_as_deploy git clean -fd \
                -e logs -e .gnode -e backups -e cache -e target \
                2>> "$GEODEPLOY_LOG"
            return 0
            ;;
        skip)
            geodeploy_log "${name}: SKIP dirty tree (strategy=skip)"
            return 1
            ;;
        force)
            geodeploy_log "${name}: FORCE checkout (discarding local changes)"
            geodeploy_as_deploy git checkout -- . 2>> "$GEODEPLOY_LOG"
            geodeploy_as_deploy git clean -fd \
                -e logs -e .gnode -e backups -e cache -e target \
                2>> "$GEODEPLOY_LOG"
            return 0
            ;;
        *)
            geodeploy_log "${name}: WARN unknown dirty-tree strategy '${strategy}', skipping"
            return 1
            ;;
    esac
}

# =============================================================================
# Actions — called by trigger matching
# =============================================================================

geodeploy_action_build() {
    local repo_dir="$1"
    local name="$2"
    local build_dir="${_GD_BUILD_DIR:-.}"
    local build_cmd="${_GD_BUILD_CMD}"

    cd "${repo_dir}/${build_dir}" || return 1

    if [[ -n "$build_cmd" ]]; then
        # build_cmd comes from the repo: one command, argv-split, no shell metacharacters.
        if [[ "$build_cmd" =~ [\;\&\|\`\$\<\>] ]]; then
            geodeploy_log "${name}: BUILD rejected (forbidden shell metachars in build_cmd: ${build_cmd})"
            return 1
        fi
        local -a build_argv
        # shellcheck disable=SC2206  # intentional word-splitting
        build_argv=( $build_cmd )
        if geodeploy_as_deploy "${build_argv[@]}" 2>> "$GEODEPLOY_LOG"; then
            geodeploy_log "${name}: BUILD success"
            return 0
        else
            geodeploy_log "${name}: ERROR build-failed"
            return 1
        fi
    elif [[ "$_GD_BUILD_TYPE" == "cargo" ]]; then
        if geodeploy_as_deploy cargo build --release 2>> "$GEODEPLOY_LOG"; then
            geodeploy_log "${name}: BUILD cargo success"
            return 0
        else
            geodeploy_log "${name}: ERROR cargo-build-failed"
            return 1
        fi
    fi
    return 0
}

geodeploy_action_restart() {
    local name="$1"
    local service="${_GD_SERVICE}"

    if [[ -z "$service" ]]; then
        geodeploy_log "${name}: WARN no service defined, skip restart"
        return 0
    fi

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        if /usr/bin/sudo /usr/bin/systemctl restart "$service" 2>> "$GEODEPLOY_LOG"; then
            geodeploy_log "${name}: RESTART ${service} success"
            return 0
        else
            geodeploy_log "${name}: WARN restart ${service} failed"
            return 1
        fi
    else
        geodeploy_log "${name}: SKIP restart (${service} not active)"
    fi
}

# APCu survives an FPM reload; the config loaders compare this generation on every hit.
geodeploy_action_generation_bump() {
    local name="$1"
    local vcli="${GEODINEUM_ROOT}/gNode/scripts/valkey-cli-secure.sh"
    if [[ ! -x "$vcli" ]]; then
        geodeploy_log "${name}: WARN generation-bump skipped (valkey-cli-secure.sh not found)"
        return 0
    fi
    local sites
    sites=$(VALKEY_USER=gnode_daemon "$vcli" SMEMBERS gnode:sites:registry 2>/dev/null) || sites=""
    if [[ -z "$sites" ]]; then
        geodeploy_log "${name}: WARN generation-bump skipped (registry unreadable as daemon tier — APCu config stale for up to 300 s)"
        return 0
    fi
    local site n=0 gen
    while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        if gen=$(VALKEY_USER=gnode_daemon "$vcli" FCALL GNODE_CONSTELLATION_GENERATION_INCR 0 "$site" "deploy:${name}" 2>&1); then
            n=$((n + 1))
        else
            geodeploy_log "${name}: WARN generation-bump failed for ${site}: ${gen}"
        fi
    done <<< "$sites"
    geodeploy_log "${name}: generation-bumped (${n} sites)"
    return 0
}

# Every active PHP FPM unit: per-site pools may run on several PHP versions at once.
geodeploy_fpm_units() {
    local unit
    for unit in php8.5-fpm php8.4-fpm php8.3-fpm php-fpm; do
        systemctl is-active --quiet "$unit" 2>/dev/null && echo "$unit"
    done
    return 0
}

# OPcache lives in FPM shared memory, so only an FPM reload clears it; a CLI reset does not.
geodeploy_action_opcache_clear() {
    local name="$1"
    local unit n=0
    for unit in $(geodeploy_fpm_units); do
        if /usr/bin/sudo /usr/bin/systemctl reload "$unit" 2>/dev/null; then
            geodeploy_log "${name}: opcache-cleared (${unit} reloaded)"
        else
            geodeploy_log "${name}: WARN opcache-clear failed (${unit} reload denied)"
        fi
        n=$((n + 1))
    done
    if (( n > 0 )); then
        geodeploy_action_generation_bump "$name"
        return 0
    fi
    php -r "if(function_exists('opcache_reset')){opcache_reset();}" 2>/dev/null \
        && geodeploy_log "${name}: opcache-cleared (cli only — no active FPM unit)"
}

geodeploy_action_php_fpm_restart() {
    local name="$1"
    local unit n=0
    for unit in $(geodeploy_fpm_units); do
        if /usr/bin/sudo /usr/bin/systemctl restart "$unit" 2>/dev/null; then
            geodeploy_log "${name}: php-fpm-restarted (${unit})"
        else
            geodeploy_log "${name}: WARN php-fpm-restart failed (${unit})"
        fi
        n=$((n + 1))
    done
    (( n > 0 )) && return 0
    geodeploy_log "${name}: WARN php-fpm-restart skipped (no active FPM unit)"
}

geodeploy_action_lua_reload() {
    local name="$1"
    local script="${GEODINEUM_ROOT}/gNode/scripts/load-valkey-functions.sh"

    if [[ -x "$script" ]]; then
        if "$script" >/dev/null 2>&1; then
            geodeploy_log "${name}: lua-functions-reloaded"
        else
            geodeploy_log "${name}: WARN lua-reload-failed"
        fi
    else
        geodeploy_log "${name}: WARN lua reload script not found"
    fi
}

geodeploy_action_service_install() {
    local repo_dir="$1"
    local name="$2"
    local changed="$3"

    local service_files
    service_files=$(echo "$changed" | grep '\.service$' || true)

    for svc in $service_files; do
        local src="${repo_dir}/${svc}"
        if [[ -f "$src" ]]; then
            if /usr/bin/sudo -n /usr/bin/cp "$src" /etc/systemd/system/ 2>> "$GEODEPLOY_LOG"; then
                geodeploy_log "${name}: SERVICE installed $(basename "$svc")"
            else
                geodeploy_log "${name}: ERROR SERVICE install refused for $(basename "$svc") — no sudoers cp rule for ${src%/*}/*.service (templates/sudoers-geodeploy.tpl); the installed unit is unchanged"
            fi
        fi
    done

    if [[ -n "$service_files" ]]; then
        /usr/bin/sudo /usr/bin/systemctl daemon-reload 2>> "$GEODEPLOY_LOG"
    fi
}

# =============================================================================
# Trigger matching — match changed files against geodeploy.yaml patterns
# =============================================================================
geodeploy_match_and_run() {
    local repo_dir="$1"
    local name="$2"
    local changed="$3"
    local descriptor="${repo_dir}/geodeploy.yaml"

    if [[ ! -f "$descriptor" ]]; then
        return 0
    fi

    python3 -c "
import yaml, json, sys, fnmatch

with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}

changed = sys.argv[2].strip().split('\n') if sys.argv[2].strip() else []
triggers = d.get('triggers', [])

matched_actions = set()
for trigger in triggers:
    patterns = trigger.get('match', '').split('|')
    actions = trigger.get('actions', [])
    for pat in patterns:
        pat = pat.strip()
        if not pat:
            continue
        for f in changed:
            if fnmatch.fnmatch(f, pat):
                for a in actions:
                    matched_actions.add(a)
                break  # One match per pattern is enough

for action in sorted(matched_actions):
    print(action)
" "$descriptor" "$changed" 2>/dev/null > "${GEODEPLOY_LOG}.actions.$$" || true

    # Restart is queued until after the permission passes (see geodeploy_repo).
    _GD_RESTART_QUEUED=""
    local _actions=()
    mapfile -t _actions < "${GEODEPLOY_LOG}.actions.$$"
    rm -f "${GEODEPLOY_LOG}.actions.$$"
    local action
    for action in "${_actions[@]}"; do
        case "$action" in
            build)
                geodeploy_action_build "$repo_dir" "$name"
                ;;
            restart)
                _GD_RESTART_QUEUED="$name"
                ;;
            opcache-clear)
                geodeploy_action_opcache_clear "$name"
                ;;
            php-fpm-restart)
                geodeploy_action_php_fpm_restart "$name"
                ;;
            lua-reload)
                geodeploy_action_lua_reload "$name"
                ;;
            service-install)
                geodeploy_action_service_install "$repo_dir" "$name" "$changed"
                ;;
            chmod-scripts)
                find "$repo_dir" -name "*.sh" -exec chmod 750 {} \; 2>/dev/null
                geodeploy_log "${name}: chmod-scripts"
                ;;
            custom)
                # Never run shell strings from a repo: the deploy user holds sudo rules.
                geodeploy_log "${name}: WARN 'custom' action is no longer supported. Add a named geodeploy_action_* dispatch instead."
                ;;
            *)
                geodeploy_log "${name}: WARN unknown action '${action}'"
                ;;
        esac
    done
}

# =============================================================================
# Privileged operations — quiet, guarded, batched
# =============================================================================
# No sudo when root; act only on drifted paths; batch with `-exec … +`.

# argv prefix for `find -exec`, which cannot call a shell function; empty when root.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    _GD_PRIV_ARGV=()
else
    _GD_PRIV_ARGV=(/usr/bin/sudo)
fi

_gd_priv() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

# Paths corrected this run, with a sample so a recurring count can be traced to its rule.
_GD_PERM_FIXES=0
_GD_PERM_SAMPLE=""
_GD_PERM_SAMPLE_MAX=5

_gd_note_fix() {
    _GD_PERM_FIXES=$(( _GD_PERM_FIXES + 1 ))
    if (( _GD_PERM_FIXES <= _GD_PERM_SAMPLE_MAX )); then
        _GD_PERM_SAMPLE="${_GD_PERM_SAMPLE}${_GD_PERM_SAMPLE:+, }$1"
    fi
}

# Assert owner:group on one path when it differs; an unreadable stat still chowns.
_gd_own() {
    local path="$1" owner="$2" group="$3" cur
    [[ -e "$path" ]] || return 0
    cur=$(stat -c '%U:%G' "$path" 2>/dev/null)
    [[ -n "$cur" && "$cur" == "${owner}:${group}" ]] && return 0
    _gd_priv /usr/bin/chown -h "${owner}:${group}" "$path" 2>/dev/null || true
    _gd_note_fix "${path}(own)"
    return 0
}

# Assert mode on ONE path, only when it differs. Takes 640 or 0640 alike.
_gd_mode() {
    local path="$1" mode="$2" cur
    [[ -e "$path" ]] || return 0
    cur=$(stat -c '%a' "$path" 2>/dev/null)
    if [[ -n "$cur" ]] && (( 8#$cur == 8#$mode )); then
        return 0
    fi
    _gd_priv /usr/bin/chmod "$mode" "$path" 2>/dev/null || true
    _gd_note_fix "${path}(mode ${mode})"
    return 0
}

# Extra find predicates follow the group; chown -h because find tests a symlink's own owner.
_gd_own_tree() {
    local root="$1" owner="$2" group="$3"; shift 3
    [[ -d "$root" ]] || return 0
    # read -d '' rather than mapfile -d '', which silently yields nothing before bash 4.4.
    local -a drifted=()
    local _p
    while IFS= read -r -d '' _p; do drifted+=("$_p"); done \
        < <(find "$root" "$@" \( ! -user "$owner" -o ! -group "$group" \) -print0 2>/dev/null)
    (( ${#drifted[@]} )) || return 0
    printf '%s\0' "${drifted[@]}" \
        | xargs -0r "${_GD_PRIV_ARGV[@]}" /usr/bin/chown -h "${owner}:${group}" 2>/dev/null || true
    for _p in "${drifted[@]}"; do _gd_note_fix "${_p}(own ${owner}:${group})"; done
    return 0
}

# Numeric chmod never clears setgid on a directory: assert 2750, not 750, on setgid dirs.
_gd_mode_tree() {
    local root="$1" mode="$2"; shift 2
    [[ -d "$root" ]] || return 0
    local -a drifted=()
    local _p
    while IFS= read -r -d '' _p; do drifted+=("$_p"); done \
        < <(find "$root" "$@" ! -perm "$mode" -print0 2>/dev/null)
    (( ${#drifted[@]} )) || return 0
    printf '%s\0' "${drifted[@]}" \
        | xargs -0r "${_GD_PRIV_ARGV[@]}" /usr/bin/chmod "$mode" 2>/dev/null || true
    for _p in "${drifted[@]}"; do _gd_note_fix "${_p}(mode ${mode})"; done
    return 0
}

# =============================================================================
# Permissions
# =============================================================================
geodeploy_fix_perms() {
    local repo_dir="$1"
    local owner="${2:-${_GD_OWNER}}"
    local group="${3:-${_GD_GROUP}}"

    # A missing group makes the chown below silently no-op.
    getent group "$group" >/dev/null 2>&1 || /usr/bin/sudo /usr/bin/groupadd --system "$group" 2>/dev/null || true

    # A refusal means the sudoers template lacks this owner:group+path; say so loudly.
    if ! /usr/bin/sudo /usr/bin/chown -R "${owner}:${group}" "$repo_dir" 2>/dev/null; then
        geodeploy_log "PERMS WARNING: chown -R ${owner}:${group} ${repo_dir} refused — sudoers rule missing for this owner:group+path (templates/sudoers-geodeploy.tpl vs the repo's geodeploy.yaml). Tree group NOT converged."
    fi

    # setgid so files git creates inherit the repo group; cargo's target/ manages its own modes.
    _gd_mode_tree "$repo_dir" 2750 -type d -not -path '*/.git/*' -not -path '*/target/*'

    _gd_mode_tree "$repo_dir" 640 -type f -not -path '*/.git/*' -not -path '*/target/*' \
        -not -name '.htaccess' -not -name 'nginx-deny.conf' -not -name '*.sh' -not -name '*.bash'

    _gd_mode_tree "$repo_dir" 750 -type f -name '*.sh' -not -path '*/.git/*'
    _gd_mode_tree "$repo_dir" 750 -type f -name '*.bash' -not -path '*/.git/*'

    # Extensionless scripts, found by shebang: repo root CLIs, scripts/, bin/.
    for script_dir in "${repo_dir}" "${repo_dir}/scripts" "${repo_dir}/bin"; do
        [[ -d "$script_dir" ]] || continue
        local _depth=2
        [[ "$script_dir" == "$repo_dir" ]] && _depth=1
        find "$script_dir" -maxdepth "$_depth" -type f -not -path '*/.git/*' ! -perm 750 \
            -exec sh -c 'for f; do
                    case $(head -c 2 "$f" 2>/dev/null) in "#!") chmod 750 "$f" 2>/dev/null ;; esac
                done' _ {} + 2>/dev/null
    done

    if [[ -d "${repo_dir}/.git" ]]; then
        /usr/bin/sudo /usr/bin/chown -R "${owner}:${group}" "${repo_dir}/.git" 2>/dev/null
    fi

    # Apache (www-data) must read these or it fails closed with 403.
    for deny_file in "${repo_dir}/.htaccess" "${repo_dir}/nginx-deny.conf"; do
        if [[ -f "$deny_file" ]]; then
            /usr/bin/sudo /usr/bin/chown root:www-data "$deny_file" 2>/dev/null
            chmod 640 "$deny_file" 2>/dev/null
        fi
    done

    # www-data traverses these repo roots: gNode's .gnode/ link, gNode-Client's autoload.
    local repo_name
    repo_name=$(basename "$repo_dir")
    case "$repo_name" in
        gNode|gNode-Client)
            /usr/bin/sudo /usr/bin/chmod 751 "$repo_dir" 2>/dev/null
            ;;
    esac
}

# Restore the execute bit on Rust release binaries, found by ELF magic.
geodeploy_fix_binaries() {
    local repo_dir="$1"
    local name="$2"

    while IFS= read -r -d '' bin_path; do
        if [[ "$(head -c 4 "$bin_path" 2>/dev/null)" == $'\x7fELF' ]]; then
            chmod 750 "$bin_path" 2>/dev/null
        fi
    done < <(find "$repo_dir" -type f -path '*/target/release/*' \
        -not -path '*/deps/*' -not -path '*/build/*' \
        -not -path '*/.fingerprint/*' -not -path '*/incremental/*' \
        -not -name '*.d' -not -name '*.rlib' -print0 2>/dev/null)
}

# The backup service writes these as gnode.
geodeploy_fix_bak_dirs() {
    local repo_dir="$1"

    for writable_dir in "${repo_dir}/backups" "${repo_dir}/logs"; do
        if [[ -d "$writable_dir" ]]; then
            /usr/bin/sudo /usr/bin/chown -R gnode:gnode "$writable_dir" 2>/dev/null
            chmod 750 "$writable_dir" 2>/dev/null
        fi
    done
}

# COMMS writes .gnode/ and logs/ (its unit's ReadWritePaths) as its own user.
geodeploy_fix_comms_dirs() {
    local repo_dir="$1"

    for writable_dir in "${repo_dir}/.gnode" "${repo_dir}/logs"; do
        /usr/bin/sudo /usr/bin/mkdir -p "$writable_dir" 2>/dev/null
        /usr/bin/sudo /usr/bin/chown -R geodineum-comms:geodineum-comms "$writable_dir" 2>/dev/null
        /usr/bin/sudo /usr/bin/chmod 2750 "$writable_dir" 2>/dev/null
    done
}

# gNode's untracked logs/ is in the unit's ReadWritePaths: if missing, the daemon fails to start (226/NAMESPACE).
geodeploy_fix_gnode_dirs() {
    local repo_dir="$1"

    /usr/bin/sudo /usr/bin/mkdir -p "${repo_dir}/logs" 2>/dev/null
    /usr/bin/sudo /usr/bin/chown -R gnode:gnode "${repo_dir}/logs" 2>/dev/null
    /usr/bin/sudo /usr/bin/chmod 2750 "${repo_dir}/logs" 2>/dev/null

    if [[ ! -e "${repo_dir}/.gnode" ]]; then
        /usr/bin/sudo /usr/bin/ln -s /etc/geodineum/credentials "${repo_dir}/.gnode" 2>/dev/null
    fi
}

# Restart consumers only when a member was added: groups are fixed at process start.
geodeploy_ensure_code_members() {
    local changed=0 u fpm
    getent group geodineum-code >/dev/null 2>&1 \
        || { /usr/bin/sudo /usr/bin/groupadd --system geodineum-code 2>/dev/null && changed=1; }
    for u in www-data geodine; do
        id "$u" >/dev/null 2>&1 || continue
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -cx geodineum-code >/dev/null && continue
        /usr/bin/sudo /usr/bin/usermod -aG geodineum-code "$u" 2>/dev/null && changed=1
    done
    [[ $changed -eq 0 ]] && return 0
    for fpm in $(geodeploy_fpm_units); do /usr/bin/sudo /usr/bin/systemctl reload "$fpm" 2>/dev/null || true; done
    /usr/bin/sudo /usr/bin/systemctl restart apache2 2>/dev/null || true
    if id geodine >/dev/null 2>&1 && systemctl list-unit-files geodine.service >/dev/null 2>&1; then
        /usr/bin/sudo /usr/bin/systemctl restart geodine.service 2>/dev/null || true
    fi
}

# Converge geodineum-dash membership (readers of the dashboard credential); reload FPM only on change.
geodeploy_ensure_dash_members() {
    local changed=0 u fpm
    getent group geodineum-dash >/dev/null 2>&1 \
        || { /usr/bin/sudo /usr/bin/groupadd --system geodineum-dash 2>/dev/null && changed=1; }
    # A site's pool user joins only when its record says DASH="1".
    for u in gnode "${GEODEPLOY_DEPLOY_USER:-}" $(declare -F site_pool_flag_users >/dev/null && site_pool_flag_users DASH); do
        [[ -n "$u" ]] || continue
        id "$u" >/dev/null 2>&1 || continue
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -cx geodineum-dash >/dev/null && continue
        /usr/bin/sudo /usr/bin/usermod -aG geodineum-dash "$u" 2>/dev/null && changed=1
    done
    [[ $changed -eq 0 ]] && return 0
    geodeploy_log "ensure_dash_members: geodineum-dash membership changed → reloading PHP-FPM"
    for fpm in $(geodeploy_fpm_units); do /usr/bin/sudo /usr/bin/systemctl reload "$fpm" 2>/dev/null || true; done
}

# Keep the helper list in lockstep with install.sh ensure_bootstrap_loader_installed.
geodeploy_ensure_helper_libs() {
    local src="${_GEODEPLOY_LIB_DIR}"
    local dst="/usr/local/lib/geodineum"
    if [[ ! -f "${src}/bootstrap-loader.sh" ]]; then
        geodeploy_log "ensure_helper_libs: source bootstrap-loader.sh missing at ${src} (skipped)"
        return 0
    fi
    /usr/bin/sudo /usr/bin/install -d -m 0755 -o root -g root "$dst" 2>/dev/null
    local _helper
    for _helper in bootstrap-loader.sh common.sh cli-helpers.sh manifest-registry.sh manifest-policy.sh manifest-install.sh assert-env-readable.sh; do
        [[ -f "${src}/${_helper}" ]] || continue
        /usr/bin/sudo /usr/bin/install -m 0755 -o root -g root "${src}/${_helper}" "${dst}/${_helper}" 2>/dev/null
    done
}

# =============================================================================
# WordPress site hardening
# =============================================================================
# www-data reads source, writes only dirs where PHP cannot run; .htaccess is immutable.

# PHP blocker for writable dirs: engine off for mod_php, SetHandler None for FPM.
_GEODEPLOY_PHP_BLOCK='<FilesMatch "\.(?:php[1-7]?|phtml|phar|phps)$">
    Require all denied
</FilesMatch>
<IfModule mod_php.c>
    php_flag engine off
</IfModule>
<IfModule mod_php7.c>
    php_flag engine off
</IfModule>
<IfModule mod_php8.c>
    php_flag engine off
</IfModule>
<FilesMatch "\.(?:php[1-7]?|phtml|phar|phps)$">
    SetHandler None
    ForceType application/octet-stream
    Header set Content-Disposition attachment
</FilesMatch>
<Files .htaccess>
    Require all denied
</Files>'

geodeploy_harden_wp_site() {
    # No trailing slash: find -path matches strings, and `//` would match nothing.
    local site_dir="${1%/}"
    local wp_root="$site_dir"

    # With a public_html/ docroot, www-data must not own the parent, or it could swap the docroot.
    if [ -f "${wp_root}/public_html/wp-config.php" ]; then
        wp_root="${wp_root}/public_html"
        _gd_own "$site_dir" "${GEODEPLOY_DEPLOY_USER}" www-data
        _gd_mode "$site_dir" 750
    fi
    [ -f "${wp_root}/wp-config.php" ] || return 0

    # 1. Source; the writable dirs (node and contents) and .htaccess belong to the later steps.
    _gd_own_tree "$wp_root" "${GEODEPLOY_DEPLOY_USER}" www-data -not -name '.htaccess' \
        -not -path "${wp_root}/wp-content/uploads"    -not -path "${wp_root}/wp-content/uploads/*" \
        -not -path "${wp_root}/wp-content/cache"      -not -path "${wp_root}/wp-content/cache/*" \
        -not -path "${wp_root}/wp-content/upgrade"    -not -path "${wp_root}/wp-content/upgrade/*" \
        -not -path "${wp_root}/wp-content/wflogs"     -not -path "${wp_root}/wp-content/wflogs/*" \
        -not -path "${wp_root}/wp-content/gcore-logs" -not -path "${wp_root}/wp-content/gcore-logs/*"
    _gd_mode_tree "$wp_root" 750 -type d \
        -not -path '*/uploads/*' -not -path '*/cache/*' -not -path '*/upgrade/*' -not -path '*/wflogs/*' -not -path '*/gcore-logs/*' \
        -not -path "${wp_root}/wp-content/uploads" -not -path "${wp_root}/wp-content/cache" -not -path "${wp_root}/wp-content/upgrade" \
        -not -path "${wp_root}/wp-content/wflogs" -not -path "${wp_root}/wp-content/gcore-logs"
    _gd_mode_tree "$wp_root" 640 -type f -not -name '.htaccess' \
        -not -path '*/uploads/*' -not -path '*/cache/*' -not -path '*/upgrade/*' -not -path '*/wflogs/*' -not -path '*/gcore-logs/*'

    # A site on its own pool: its user owns the writable dirs and reads the rest through an ACL.
    local _wr_owner=www-data
    if declare -F site_pool_owner_for >/dev/null; then
        _wr_owner="$(site_pool_owner_for "$site_dir" || true)"
        if [[ -n "$_wr_owner" ]] && id "$_wr_owner" >/dev/null 2>&1; then
            getfacl -cp "$wp_root" 2>/dev/null | grep -c "^user:${_wr_owner}:r" >/dev/null \
                || find "$site_dir" -not -type l -not -name .htaccess -exec setfacl -m "u:${_wr_owner}:rX" {} + 2>/dev/null || true
        else
            _wr_owner=www-data
        fi
    fi
    local _wr_dmode=750
    [[ "$_wr_owner" != www-data ]] && _wr_dmode=2750

    # 2. Writable dirs: www-data, or the site's own user when it runs its own pool.
    for writable_dir in \
        "${wp_root}/wp-content/uploads" \
        "${wp_root}/wp-content/cache" \
        "${wp_root}/wp-content/upgrade" \
        "${wp_root}/wp-content/gcore-logs" \
        "${wp_root}/wp-content/wflogs"; do
        if [[ -d "$writable_dir" ]]; then
            _gd_own_tree "$writable_dir" "$_wr_owner" www-data -not -name '.htaccess' -not -type l
            _gd_mode_tree "$writable_dir" "$_wr_dmode" -type d
            _gd_mode_tree "$writable_dir" 640 -type f -not -name '.htaccess'
        fi
    done

    # 3. PHP execution blocker in writable dirs (immutable)
    for writable_dir in \
        "${wp_root}/wp-content/uploads" \
        "${wp_root}/wp-content/gcore-logs" \
        "${wp_root}/wp-content/cache"; do
        if [[ -d "$writable_dir" ]]; then
            local htaccess="${writable_dir}/.htaccess"
            # Rewrite only on a content difference, so file-integrity baselines stay quiet.
            if [[ "$(cat "$htaccess" 2>/dev/null)" != "$_GEODEPLOY_PHP_BLOCK" ]]; then
                _gd_priv /usr/bin/chattr -i "$htaccess" 2>/dev/null || true
                echo "$_GEODEPLOY_PHP_BLOCK" | _gd_priv /usr/bin/tee "$htaccess" > /dev/null 2>&1
                _gd_own "$htaccess" root www-data
                _gd_mode "$htaccess" 640
                _gd_priv /usr/bin/chattr +i "$htaccess" 2>/dev/null || true
            elif ! lsattr -d "$htaccess" 2>/dev/null | cut -d' ' -f1 | grep -c i >/dev/null; then
                _gd_own "$htaccess" root www-data
                _gd_mode "$htaccess" 640
                _gd_priv /usr/bin/chattr +i "$htaccess" 2>/dev/null || true
            fi
        fi
    done

    # 4. Root .htaccess: root:www-data 640, immutable; unlocked only when it drifted.
    if [[ -f "${wp_root}/.htaccess" ]]; then
        local _root_ht="${wp_root}/.htaccess"
        local _ht_state _ht_immutable=0
        _ht_state=$(stat -c '%U:%G %a' "$_root_ht" 2>/dev/null)
        lsattr -d "$_root_ht" 2>/dev/null | cut -d' ' -f1 | grep -c i >/dev/null && _ht_immutable=1
        if [[ "$_ht_state" != "root:www-data 640" || "$_ht_immutable" -eq 0 ]]; then
            _gd_priv /usr/bin/chattr -i "$_root_ht" 2>/dev/null || true
            _gd_own "$_root_ht" root www-data
            _gd_mode "$_root_ht" 640
            _gd_priv /usr/bin/chattr +i "$_root_ht" 2>/dev/null || true
        fi
    fi

    # 5. .geodineum/ config (beside WordPress or at the site root): www-data reads, never writes.
    local _gdir
    for _gdir in "${wp_root}/.geodineum" "${site_dir}/.geodineum"; do
        [[ -d "$_gdir" ]] || continue
        [[ "$_gdir" == "${site_dir}/.geodineum" && "$wp_root" == "$site_dir" ]] && continue
        _gd_own_tree "$_gdir" "${GEODEPLOY_DEPLOY_USER}" www-data
        _gd_mode_tree "$_gdir" 750 -type d
        _gd_mode_tree "$_gdir" 640 -type f
    done

    # Best-effort: the installer calls this unguarded under set -e.
    return 0
}

geodeploy_harden_all_wp() {
    local www_root="${1:-/var/www}"

    for site_dir in "${www_root}"/*/; do
        [[ -d "$site_dir" ]] || continue
        local site_name
        site_name="$(basename "$site_dir")"
        [[ "$site_name" == "html" || "$site_name" == "lost+found" ]] && continue
        geodeploy_harden_wp_site "$site_dir" || true
    done
    return 0
}

# =============================================================================
# /etc/geodineum permissions
# =============================================================================
# www-data reads only through single-purpose groups, never the broad geodineum ones.
geodeploy_fix_config_perms() {
    local config_root="${1:-/etc/geodineum}"

    [[ ! -d "$config_root" ]] && return 0

    # o+x: www-data traverses to credentials/ and bootstrap.env.
    _gd_own "$config_root" root geodineum
    _gd_mode "$config_root" 751

    # The gNode daemon refuses to start unless bootstrap.env is 0640 (or 0600).
    if [[ -f "${config_root}/bootstrap.env" ]]; then
        _gd_own "${config_root}/bootstrap.env" root geodineum-bootstrap
        _gd_mode "${config_root}/bootstrap.env" 0640

        # The daemon rejects any key beyond these three: rewrite, keeping the values.
        local _extra
        _extra=$(grep -E "^[A-Z_]+=" "${config_root}/bootstrap.env" 2>/dev/null \
            | grep -vE "^(VALKEY_HOST|VALKEY_PORT|VALKEY_CREDS_PATH)=" \
            | head -1 || true)
        if [[ -n "$_extra" ]]; then
            geodeploy_log "bootstrap.env: content drift detected, rewriting to strict 3-key shape"
            local _host _port _creds _ts
            _host=$(grep -E '^VALKEY_HOST=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            _port=$(grep -E '^VALKEY_PORT=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            _creds=$(grep -E '^VALKEY_CREDS_PATH=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            _host="${_host:-127.0.0.1}"
            _port="${_port:-47445}"
            _creds="${_creds:-/etc/geodineum/credentials}"
            _ts=$(date +%Y%m%d-%H%M%S)
            /usr/bin/sudo /usr/bin/cp "${config_root}/bootstrap.env" "${config_root}/bootstrap.env.archived-${_ts}" 2>/dev/null
            /usr/bin/sudo /usr/bin/bash -c "cat > ${config_root}/bootstrap.env <<EOF
VALKEY_HOST=${_host}
VALKEY_PORT=${_port}
VALKEY_CREDS_PATH=${_creds}
EOF"
            /usr/bin/sudo /usr/bin/chown root:geodineum-bootstrap "${config_root}/bootstrap.env" 2>/dev/null
            /usr/bin/sudo /usr/bin/chmod 0640 "${config_root}/bootstrap.env" 2>/dev/null
        fi
    fi

    # ── components/ ──
    if [[ -d "${config_root}/components" ]]; then
        _gd_own "${config_root}/components" gnode geodineum-bootstrap
        _gd_mode "${config_root}/components" 0750
        _gd_own_tree "${config_root}/components" gnode geodineum-bootstrap -mindepth 1 -type d
        _gd_mode_tree "${config_root}/components" 0750 -mindepth 1 -type d

        # Default gnode:geodineum 0640; the exceptions set below are excluded so the two never fight.
        _gd_own_tree "${config_root}/components" gnode geodineum -type f \
            -not -name 'receipt_signing.key' \
            -not -path "${config_root}/components/gCore/gcore.env" \
            -not -path "${config_root}/components/gTemplate/gtemplate.env" \
            -not -path "${config_root}/components/geodineum-comms/geodineum-comms.env"
        _gd_mode_tree "${config_root}/components" 0640 -type f \
            -not -name 'receipt_signing.key'

        local _receipt_key="${config_root}/components/gnode-daemon/receipt_signing.key"
        if [[ -f "$_receipt_key" ]]; then
            _gd_own "$_receipt_key" gnode gnode
            _gd_mode "$_receipt_key" 0600
        fi

        :

        # PHP-readable envs: www-data reads them through geodineum-bootstrap.
        for php_env in \
            "${config_root}/components/gCore/gcore.env" \
            "${config_root}/components/gTemplate/gtemplate.env"; do
            if [[ -f "$php_env" ]]; then
                _gd_own "$php_env" root geodineum-bootstrap
                _gd_mode "$php_env" 0640
            fi
        done

        # COMMS runs outside geodineum, and its optional EnvironmentFile fails silently.
        _comms_env="${config_root}/components/geodineum-comms/geodineum-comms.env"
        if [[ -f "$_comms_env" ]] && getent group geodineum-comms >/dev/null 2>&1; then
            _gd_own "$_comms_env" root geodineum-comms
            _gd_mode "$_comms_env" 0640
        fi
    fi

    # ── credentials/: o+x lets service users reach their own file; listing needs the group ──
    if [[ -d "${config_root}/credentials" ]]; then
        _gd_own "${config_root}/credentials" root geodineum-creds
        _gd_mode "${config_root}/credentials" 0751
    fi

    # ── dashboard/: the read-only dashboard token; install.sh provisions its content ──
    if getent group geodineum-dash >/dev/null 2>&1; then
        [[ -d "${config_root}/dashboard" ]] \
            || /usr/bin/sudo /usr/bin/install -d -m 0750 -o root -g geodineum-dash "${config_root}/dashboard" 2>/dev/null
    fi
    if [[ -d "${config_root}/dashboard" ]]; then
        _gd_own "${config_root}/dashboard" root geodineum-dash
        _gd_mode "${config_root}/dashboard" 0750
        if [[ -f "${config_root}/dashboard/geodineum-dashboard.txt" ]]; then
            _gd_own "${config_root}/dashboard/geodineum-dashboard.txt" gnode geodineum-dash
            _gd_mode "${config_root}/dashboard/geodineum-dashboard.txt" 0640
        else
            geodeploy_log "fix_config_perms: dashboard credential MISSING (${config_root}/dashboard/geodineum-dashboard.txt) — run provision_dashboard_acl (re-run install.sh) or wp-admin module pages will show 'credentials not found'"
        fi
    fi

    # ── sites/: the daemon writes, PHP reads ──
    if [[ -d "${config_root}/sites" ]]; then
        _gd_own "${config_root}/sites" gnode www-data
        _gd_mode "${config_root}/sites" 0750
        _gd_own_tree "${config_root}/sites" gnode www-data -mindepth 1
        _gd_mode_tree "${config_root}/sites" 0750 -mindepth 1 -type d
        _gd_mode_tree "${config_root}/sites" 0640 -type f
    fi

    # ── services/ ──
    if [[ -d "${config_root}/services" ]]; then
        _gd_own "${config_root}/services" gnode gnode
        _gd_mode "${config_root}/services" 0750
        _gd_own_tree "${config_root}/services" gnode gnode -mindepth 1
        _gd_mode_tree "${config_root}/services" 0750 -mindepth 1 -type d
        _gd_mode_tree "${config_root}/services" 0640 -type f
    fi
}

# COMMS keeps its signing key in /var/lib (its unit cannot write /etc); owner-only.
geodeploy_fix_comms_signing_key() {
    local key="${1:-/var/lib/geodineum-comms/receipt_signing.key}"
    [[ -f "$key" ]] || return 0
    getent passwd geodineum-comms >/dev/null 2>&1 || return 0
    _gd_own "$key" geodineum-comms geodineum-comms
    _gd_mode "$key" 0600
    return 0
}

# Geodineum-BAK is outside the repo sweep; the backup timer runs its scripts as gnode.
geodeploy_fix_bak_perms() {
    local bak="${1:-${GEODINEUM_ROOT}/Geodineum-BAK}"
    [[ -d "$bak" ]] || return 0
    _gd_own "$bak" root gnode
    _gd_mode "$bak" 0750
    if [[ -d "$bak/scripts" ]]; then
        _gd_own_tree "$bak/scripts" root gnode
        _gd_mode_tree "$bak/scripts" 0750 -type d -not -path '*/.git/*'
        _gd_mode_tree "$bak/scripts" 0750 -type f -name '*.sh' -not -path '*/.git/*'
    fi
    if [[ -d "$bak/backups" ]]; then
        _gd_own_tree "$bak/backups" gnode gnode
        _gd_mode "$bak/backups" 0750
    fi
}

# Log subdirectories are owned by their writer; group geodineum reads across them.
geodeploy_fix_log_perms() {
    local log_root="${1:-${GEODINEUM_LOG_ROOT}}"

    [[ ! -d "$log_root" ]] && return 0

    _gd_own "$log_root" root geodineum
    _gd_mode "$log_root" 2750

    for dir in gnode valkey; do
        _gd_own_tree "${log_root}/${dir}" gnode geodineum
    done

    _gd_own_tree "${log_root}/comms" geodineum-comms geodineum

    for dir in gcore apache wordpress themes; do
        _gd_own_tree "${log_root}/${dir}" www-data geodineum
    done

    # Git runs as the deploy user and appends to this log.
    _gd_own_tree "${log_root}/deploy" "${GEODEPLOY_DEPLOY_USER}" geodineum

    if declare -F geodeploy_fix_log_extras >/dev/null; then
        geodeploy_fix_log_extras "$log_root"
    fi

    # setgid carries the group to new log files.
    _gd_mode_tree "$log_root" 2750 -type d
    _gd_mode_tree "$log_root" 640 -type f
}

# =============================================================================
# Credential provisioning — called by `geodineum register`
# =============================================================================
# A credential file is readable by its runtime user only.
geodeploy_fix_credential() {
    local cred_file="$1"
    local runtime_user="$2"

    if [[ ! -f "$cred_file" ]]; then
        return 1
    fi

    _gd_own "$cred_file" "$runtime_user" "$runtime_user"
    _gd_mode "$cred_file" 600
}

# Changes together with gNode/scripts/onboard-service.sh; see CONTRACTS/permission-model.md.
geodeploy_fix_all_credentials() {
    local creds_dir="${1:-/etc/geodineum/credentials}"

    [[ ! -d "$creds_dir" ]] && return 0

    # 0751 as in install.sh: service users traverse to their own files without listing.
    _gd_own "$creds_dir" root geodineum-creds
    _gd_mode "$creds_dir" 0751

    for f in \
        "${creds_dir}/valkey_daemon.password" \
        "${creds_dir}/valkey.password" \
        "${creds_dir}/valkey_client.password"; do
        [[ -f "$f" ]] && geodeploy_fix_credential "$f" "gnode"
    done

    # COMMS reads its credentials through its group but cannot rewrite them.
    for f in \
        "${creds_dir}/valkey_comms.password" \
        "${creds_dir}"/smtp_comms.*; do
        if [[ -f "$f" ]]; then
            _gd_own "$f" root geodineum-comms
            _gd_mode "$f" 0640
        fi
    done

    # Client creds follow their <cred>.owner sidecar (owner:group:mode); without one they are left alone.
    for f in "${creds_dir}"/valkey_client_*.password; do
        [[ -f "$f" ]] || continue
        local sidecar="${f}.owner" o="" g="" m=""
        [[ -f "$sidecar" ]] || continue
        IFS=: read -r o g m < "$sidecar"
        o="${o:-root}"; g="${g:-geodineum}"; m="${m:-640}"
        [[ "$o" == "www-data" ]] && o=root                 # never www-data-owned
        getent group "$g" >/dev/null 2>&1 || g=geodineum   # unknown group → safe
        _gd_own "$f" "$o" "$g"
        _gd_mode "$f" "$m"
        _gd_own "$sidecar" root geodineum-creds
        _gd_mode "$sidecar" 0644
    done

    for f in "${creds_dir}/.htaccess" "${creds_dir}/nginx-deny.conf"; do
        if [[ -f "$f" ]]; then
            _gd_own "$f" root www-data
            _gd_mode "$f" 640
        fi
    done
}

# =============================================================================
# Pro components: pro/gCore/* and pro/gNode/*
# =============================================================================
# A `pro/<type>/<name>` line in unmanaged-repos.conf holds a checkout back.
_gd_pro_unmanaged() {
    [[ -r "${GEODINEUM_ROOT}/unmanaged-repos.conf" ]] || return 1
    grep -qxE "[[:space:]]*${1}[[:space:]]*(#.*)?" "${GEODINEUM_ROOT}/unmanaged-repos.conf"
}

# A site that can read pro/gCore runs it, so geodineum-pro limits it once that group exists.
_gd_pro_group() {
    if getent group geodineum-pro >/dev/null 2>&1; then echo geodineum-pro; else echo geodineum-code; fi
}

geodeploy_deploy_pro() {
    local pro_root="${GEODINEUM_ROOT}/pro"
    [[ -d "$pro_root" ]] || return 0

    local manifest="${pro_root}/manifest.yaml"
    local pending
    pending="$(dirname "$GEODEPLOY_LOG")/.pro-gnode-rebuild-pending"
    local failed=0 php_changed=0 lua_changed=0
    local entries name branch remote comp_type pro_dir label changed local_rev remote_rev count

    if [[ -r "$manifest" ]]; then
        if entries=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
for e in d.get('pro', []):
    print('|'.join(str(e.get(k, dflt)) for k, dflt in (('name', ''), ('branch', 'main'), ('remote', ''), ('type', ''))))
" "$manifest" 2>/dev/null); then
            while IFS='|' read -r name branch remote comp_type; do
                [[ -n "$name" && ( "$comp_type" == "gCore" || "$comp_type" == "gNode" ) ]] || continue
                pro_dir="${pro_root}/${comp_type}/${name}"
                label="pro/${comp_type}/${name}"
                if [[ -e "$pro_dir" ]] || _gd_pro_unmanaged "$label"; then continue; fi
                if geodeploy_as_deploy git clone --branch "$branch" "$remote" "$pro_dir" 2>> "$GEODEPLOY_LOG"; then
                    geodeploy_log "${label}: CLONE success"
                    if [[ "$comp_type" == "gNode" ]]; then
                        chgrp -R gnode "$pro_dir"; : > "$pending"
                    else
                        chgrp -R "$(_gd_pro_group)" "$pro_dir"
                    fi
                    chmod -R o-rwx,g-w "$pro_dir"
                    if [[ "$comp_type" == "gCore" ]] && geodeploy_parse_descriptor "${pro_dir}/geodeploy.yaml" && [[ -n "$_GD_BUILD_TYPE$_GD_BUILD_CMD" ]]; then
                        geodeploy_action_build "$pro_dir" "$label" || failed=1
                        chgrp -R "$(_gd_pro_group)" "$pro_dir"; chmod -R o-rwx,g-w "$pro_dir"
                    fi
                else
                    geodeploy_log "${label}: ERROR clone-failed"
                    failed=1
                fi
            done <<< "$entries"
        else
            geodeploy_log "pro: ERROR manifest parse-failed (${manifest})"
            failed=1
        fi
    fi

    for pro_dir in "$pro_root"/gCore/*/ "$pro_root"/gNode/*/; do
        pro_dir="${pro_dir%/}"
        [[ -d "${pro_dir}/.git" && ! -L "$pro_dir" ]] || continue
        comp_type="$(basename "$(dirname "$pro_dir")")"
        label="pro/${comp_type}/$(basename "$pro_dir")"
        if _gd_pro_unmanaged "$label"; then continue; fi
        cd "$pro_dir" || { failed=1; continue; }

        branch=$(geodeploy_as_deploy git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
        [[ -n "$branch" && "$branch" != "HEAD" ]] || branch="main"

        if ! geodeploy_fetch "$branch"; then
            geodeploy_log "${label}: ERROR fetch-failed"
            failed=1
            continue
        fi
        geodeploy_has_changes "$branch" || continue

        IFS='|' read -r local_rev remote_rev count <<< "$(geodeploy_get_revs "$branch")"
        changed=$(geodeploy_get_changed "$branch")
        geodeploy_handle_dirty discard "$label"
        if ! geodeploy_pull "$branch"; then
            geodeploy_log "${label}: ERROR pull-failed"
            failed=1
            continue
        fi
        geodeploy_log "${label}: PULL ${local_rev}→${remote_rev} (${count} commits)"

        if [[ "$comp_type" == "gCore" ]]; then
            if grep -qE '\.php$' <<< "$changed"; then php_changed=1; fi
            if geodeploy_parse_descriptor "${pro_dir}/geodeploy.yaml"; then
                geodeploy_match_and_run "$pro_dir" "$label" "$changed"
                chgrp -R "$(_gd_pro_group)" "$pro_dir"; chmod -R o-rwx,g-w "$pro_dir"
            fi
        else
            if grep -qE '^(functions/.*\.lua|extension\.yaml)$' <<< "$changed"; then lua_changed=1; fi
            if grep -qE '^(src/|extension\.(yaml|sig)$)' <<< "$changed"; then : > "$pending"; fi
        fi
    done

    if [[ -f "$pending" ]]; then
        geodeploy_pro_rebuild_daemon "$pending" || failed=1
    fi
    if (( lua_changed )); then
        geodeploy_action_lua_reload "pro/gNode"
    fi
    if (( php_changed )); then
        geodeploy_action_opcache_clear "pro/gCore"
    fi
    return "$failed"
}

# build.rs drops an unverified extension, so rebuild only when all verify; a failure retries on a new commit.
geodeploy_pro_rebuild_daemon() {
    local pending="$1"
    local gnode_dir="${GEODINEUM_ROOT}/gNode"
    local bin="${gnode_dir}/daemon/target/release/gnode-daemon"
    local inputs ext bad=""

    inputs=$(for ext in "$gnode_dir" "${GEODINEUM_ROOT}"/pro/gNode/*/; do
        geodeploy_as_deploy git -C "$ext" rev-parse HEAD 2>/dev/null || true
    done | sha256sum | cut -c1-16)
    if [[ "$(cat "$pending" 2>/dev/null)" == "$inputs" ]]; then return 1; fi

    if [[ ! -x "$bin" ]]; then
        geodeploy_log "pro/gNode: ERROR rebuild held (no daemon binary to verify extensions with)"
        echo "$inputs" > "$pending"
        return 1
    fi
    for ext in "${GEODINEUM_ROOT}"/pro/gNode/*/; do
        [[ -f "${ext}extension.yaml" ]] || continue
        geodeploy_as_deploy "$bin" verify-extension "${ext%/}" >/dev/null 2>&1 || bad+=" $(basename "$ext")"
    done
    if [[ -n "$bad" ]]; then
        geodeploy_log "pro/gNode: ERROR rebuild held (signature verification failed:${bad}; a rebuild would drop them)"
        echo "$inputs" > "$pending"
        return 1
    fi

    if ! geodeploy_parse_descriptor "${gnode_dir}/geodeploy.yaml"; then
        geodeploy_log "pro/gNode: ERROR rebuild held (gNode descriptor unreadable)"
        echo "$inputs" > "$pending"
        return 1
    fi
    _GD_BUILD_CMD="${_GD_BUILD_CMD:-scripts/build.sh} --force"
    if ! geodeploy_action_build "$gnode_dir" "pro/gNode"; then
        echo "$inputs" > "$pending"
        return 1
    fi
    geodeploy_fix_binaries "$gnode_dir" "gNode"
    geodeploy_fix_gnode_dirs "$gnode_dir"
    geodeploy_action_restart "gNode" || return 1
    rm -f "$pending"
}

# =============================================================================
# Symlink management — ensure declared links exist after pull
# =============================================================================
# geodeploy.yaml `links: [{target: <abs path>, link: <repo-relative>}]`; runs on every deploy.
geodeploy_ensure_links() {
    local repo_dir="$1"
    local name="$2"
    local descriptor="${repo_dir}/geodeploy.yaml"

    [[ ! -f "$descriptor" ]] && return 0

    python3 -c "
import yaml, sys, json
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
for link in d.get('links', []):
    t = link.get('target', '')
    l = link.get('link', '')
    if t and l:
        print(json.dumps({'target': t, 'link': l}))
" "$descriptor" 2>/dev/null | while read -r entry; do
        local target link link_path
        target=$(echo "$entry" | python3 -c "import json,sys;print(json.load(sys.stdin)['target'])")
        link=$(echo "$entry" | python3 -c "import json,sys;print(json.load(sys.stdin)['link'])")
        link_path="${repo_dir}/${link}"

        if [[ ! -e "$target" ]]; then
            geodeploy_log "${name}: WARN link target missing: ${target}"
            continue
        fi

        if [[ -L "$link_path" ]]; then
            local current_target
            current_target=$(readlink -f "$link_path" 2>/dev/null)
            local expected_target
            expected_target=$(readlink -f "$target" 2>/dev/null)
            if [[ "$current_target" != "$expected_target" ]]; then
                rm -f "$link_path"
                ln -sf "$target" "$link_path"
                geodeploy_log "${name}: LINK updated ${link} → ${target}"
            fi
        elif [[ ! -e "$link_path" ]]; then
            ln -sf "$target" "$link_path"
            geodeploy_log "${name}: LINK created ${link} → ${target}"
        else
            geodeploy_log "${name}: WARN ${link} exists and is not a symlink, skipping"
        fi
    done
}

# =============================================================================
# Main deploy cycle for a single repo
# =============================================================================
geodeploy_repo() {
    local name="$1"
    local branch="$2"
    local repo_dir="${GEODINEUM_ROOT}/${name}"

    [[ ! -d "${repo_dir}/.git" ]] && return 0

    cd "$repo_dir" || return 1

    geodeploy_as_deploy git config core.fileMode false 2>/dev/null || true

    # Follow the checked-out branch; the configured one applies only to a detached HEAD.
    local current_branch
    current_branch=$(geodeploy_as_deploy git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
        branch="$current_branch"
    fi

    geodeploy_fetch "$branch" || {
        geodeploy_log "${name}: ERROR fetch-failed"
        return 1
    }

    if ! geodeploy_has_changes "$branch"; then
        # No new commits, but ownership may have drifted; skip what other rules own on purpose.
        if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
            geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml" || true
        fi
        local _drifted
        _drifted="$(find "$repo_dir" -not -path '*/.git*' -not -path '*/target*' \
                -not -name '.htaccess' -not -name 'nginx-deny.conf' \
                -not -path "${repo_dir}/logs" -not -path "${repo_dir}/logs/*" \
                -not -path "${repo_dir}/backups" -not -path "${repo_dir}/backups/*" \
                -not -path "${repo_dir}/.gnode" -not -path "${repo_dir}/.gnode/*" \
                \( ! -group "$_GD_GROUP" -o ! -user "$_GD_OWNER" \) \
                -printf '%p (%u:%g)' -quit 2>/dev/null)"
        if [[ -n "$_drifted" ]]; then
            geodeploy_log "${name}: ownership drift detected (no new commits) — converging to ${_GD_OWNER}:${_GD_GROUP}; first offender: ${_drifted}"
            geodeploy_fix_perms "$repo_dir" "$_GD_OWNER" "$_GD_GROUP"
        fi
        return 0
    fi

    if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
        geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml"
    fi

    local pre_deploy_rev
    pre_deploy_rev=$(geodeploy_as_deploy git rev-parse HEAD 2>/dev/null)
    IFS='|' read -r local_rev remote_rev count <<< "$(geodeploy_get_revs "$branch")"

    geodeploy_handle_dirty "$_GD_DIRTY" "$name" || return 0

    local changed
    changed=$(geodeploy_get_changed "$branch")

    if geodeploy_pull "$branch"; then
        geodeploy_log "${name}: PULL ${local_rev}→${remote_rev} (${count} commits)"

        # The pull may have changed geodeploy.yaml itself.
        if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
            geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml" || true
        fi

        geodeploy_match_and_run "$repo_dir" "$name" "$changed"

        geodeploy_fix_perms "$repo_dir" "$_GD_OWNER" "$_GD_GROUP"
        geodeploy_fix_binaries "$repo_dir" "$name"

        geodeploy_ensure_links "$repo_dir" "$name"

        if [[ "$name" == "Geodineum-BAK" ]]; then
            geodeploy_fix_bak_dirs "$repo_dir"
        fi
        if [[ "$name" == "gNode" ]]; then
            geodeploy_fix_gnode_dirs "$repo_dir"
        fi
        if [[ "$name" == "Geodineum-COMMS" ]]; then
            geodeploy_fix_comms_dirs "$repo_dir"
        fi
        if [[ "$_GD_GROUP" == "geodineum-code" ]]; then
            geodeploy_ensure_code_members
        fi
        if declare -F geodeploy_fix_extras >/dev/null; then
            geodeploy_fix_extras "$name" "$repo_dir"
        fi

        # The queued restart runs only once ownership, modes and runtime dirs are settled.
        if [[ -n "${_GD_RESTART_QUEUED:-}" ]]; then
            geodeploy_action_restart "$_GD_RESTART_QUEUED"
            _GD_RESTART_QUEUED=""
        fi

        # Best-effort: publish the manifest to ValKey for `geodineum describe` and `geodineum logs`.
        local _registry_lib="${GEODINEUM_ROOT}/Geodineum/lib/manifest-registry.sh"
        if [[ -f "${repo_dir}/geodeploy.yaml" && -r "$_registry_lib" ]]; then
            # shellcheck source=/dev/null
            source "$_registry_lib"
            manifest_publish_registry "${repo_dir}/geodeploy.yaml" 2>/dev/null || true
        fi
    else
        geodeploy_log "${name}: ERROR pull-failed ${local_rev}→${remote_rev}"
    fi
}

# =============================================================================
# Post-deploy check: the web tree is still readable by Apache
# =============================================================================
# Logs only; never changes anything.
geodeploy_verify_web_readable() {
    local root="${1:-${GEODINEUM_ROOT:-/opt/geodineum}}"
    local repo drift dirs_no_x
    # Plus every component whose geodeploy.yaml uses group geodineum-code.
    local -a repos=(gCore gTemplate gCube gNode-Client) _wd _wn
    for _wd in "${root}"/*/; do
        _wn="$(basename "$_wd")"
        [[ " ${repos[*]} " == *" ${_wn} "* ]] && continue
        grep -qE 'group:[[:space:]]*geodineum-code' "${_wd}geodeploy.yaml" 2>/dev/null \
            && repos+=("$_wn")
    done
    for repo in "${repos[@]}"; do
        [[ -d "${root}/${repo}" ]] || continue
        drift=$(find "${root}/${repo}" -type f ! -group www-data ! -group geodineum-code ! -path '*/.git/*' 2>/dev/null | head -1)
        dirs_no_x=$(find "${root}/${repo}" -type d ! -perm -g+x ! -path '*/.git/*' 2>/dev/null | head -1)
        if [[ -n "$drift" ]]; then
            geodeploy_log "WEB-PERM WARNING: ${repo} has non-www-data group files (e.g. ${drift#${root}/}). Apache reads may fail intermittently — run: sudo ${root}/Geodineum/scripts/fix-permissions.sh"
        fi
        if [[ -n "$dirs_no_x" ]]; then
            geodeploy_log "WEB-PERM WARNING: ${repo} has non-traversable dir (e.g. ${dirs_no_x#${root}/}). Apache cannot reach files below it."
        fi
    done
}

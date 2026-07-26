#!/bin/bash
# =============================================================================
# geodeploy — shared deploy library for the Geodineum ecosystem
# =============================================================================
# Single source of truth for: git operations, permissions, build actions,
# service management, and dirty-tree recovery.
#
# Sourced by:
#   - scripts/geodeploy-orchestrator  (cron, every 5 min)
#   - scripts/fix-permissions.sh      (manual, one-shot)
#   - install.sh                      (Phase 8, initial setup)
#
# All permission logic lives here. No other script should chown/chmod
# ecosystem files directly.
#
# Deployment-local overlay: lib/geodeploy-extras.sh (same directory, not
# part of this repo) is sourced if present. It may define
#   geodeploy_fix_extras <name> <repo_dir>   — per-component fix-ups
#   geodeploy_fix_log_extras <log_root>      — extra log-dir ownership
# for components that exist on a given deployment but not in the public
# component set.
# =============================================================================

# Fail on unset vars and pipe failures, but not on individual command errors
# (callers check return codes explicitly)
# -e added so failed steps abort the cron run
# rather than silently continuing across N repos. The script already
# handles per-repo errors via geodeploy_log + return-1; -e adds the
# safety net for unanticipated failures.
set -euo pipefail

# Source the deployment-local overlay if present (see header).
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
# Deploy log lives with the rest of the ecosystem logs under /var/log/geodineum,
# in a per-writer `deploy/` subdir (deploy_user:geodineum 2750) — NOT under
# /opt/geodineum (which is operator-owned 0750 and not a log location). The dir
# must be writable by DEPLOY_USER, because both the orchestrator (root) AND the
# git commands it runs *as the deploy user* (geodeploy_as_deploy ... 2>>LOG)
# append here; a root-owned log locks the deploy user out → the "/bin/sh: cannot
# create ...: Permission denied" cron-mail storm.
GEODEPLOY_LOG="${GEODEPLOY_LOG:-${GEODINEUM_LOG_ROOT}/deploy/auto-deploy.log}"
GEODEPLOY_LOG_MAX="${GEODEPLOY_LOG_MAX:-2000}"
# Resolve deploy identity
# through a fallback chain that handles cron context too.
#   1. GEODEPLOY_DEPLOY_USER env var (caller's explicit override)
#   2. DEPLOY_USER env var (install.sh's session)
#   3. /etc/geodineum/deploy.env (persisted by install.sh phase_deploy_user;
#      the only reliable source under cron-driven geodeploy-orchestrator)
#   4. SUDO_USER → USER (interactive fallback)
#   5. explicit FATAL
#
# Previously, the SUDO_USER → USER fallback was sufficient for interactive
# install runs but broke cron orchestration (cron has neither var). The
# deploy.env layer makes the deploy identity self-describing on disk.
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
    # FATAL goes to the LOG (timestamped, deduped) as well as
    # stderr, and stderr is rate-limited to once per hour. Previously
    # this was a raw stderr echo — under the */5 cron it produced an
    # email storm to root (288 identical mails/day) while the log file
    # stayed silent, so the outage was invisible in the one place an
    # operator actually looks.
    _gd_fatal_msg="FATAL: deploy user unresolved (GEODEPLOY_DEPLOY_USER + DEPLOY_USER + /etc/geodineum/deploy.env + SUDO_USER + USER all empty). Set GEODEPLOY_DEPLOY_USER explicitly or run install.sh first."
    if declare -F geodeploy_log >/dev/null 2>&1; then
        geodeploy_log "$_gd_fatal_msg"
    else
        # Sourced top-to-bottom: geodeploy_log isn't defined yet at this
        # point in the file — append directly with the same format.
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
_GD_DIRTY="stash"
_GD_BUILD_TYPE=""
_GD_BUILD_DIR=""
_GD_BUILD_CMD=""
_GD_TRIGGERS=()

# =============================================================================
# Logging
# =============================================================================
# repeated-message backoff. When the same message is logged
# consecutively (a failing cron loop emits the identical line every 5
# minutes), collapse it into one line with a repeat counter instead of
# thousands of duplicates. A failing deploy-user FATAL once filled the
# log cap with one repeated line — burying WHEN the failure started and
# everything that happened before it.
geodeploy_log() {
    local raw="$1"
    local last
    last=$(tail -n 1 "$GEODEPLOY_LOG" 2>/dev/null || true)

    # Strip "[timestamp] " prefix and any "(repeated Nx, last ...)" suffix
    # from the previous line to compare message bodies.
    local last_body="${last#\[*\] }"
    last_body="${last_body% (repeated *}"

    if [[ -n "$last" && "$last_body" == "$raw" ]]; then
        local n=1
        if [[ "$last" =~ \(repeated\ ([0-9]+)x ]]; then
            n="${BASH_REMATCH[1]}"
        fi
        n=$((n + 1))
        # Replace the last line: keep the FIRST-seen timestamp prefix,
        # bump the counter, refresh last-seen. sed '$d' + append is safe
        # for the single-writer cron model (flock in the orchestrator).
        local first_stamp="${last%%]*}]"
        sed -i '$d' "$GEODEPLOY_LOG" 2>/dev/null || true
        echo "${first_stamp} ${raw} (repeated ${n}x, last $(date '+%Y-%m-%d %H:%M:%S'))" >> "$GEODEPLOY_LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $raw" >> "$GEODEPLOY_LOG"
    fi

    # Cap log file
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
# Git network/write operations and builds run AS THE DEPLOY USER, never
# root. The GitHub deploy key lives in the deploy user's ~/.ssh (set up
# by install.sh) — root has no access to the private repos (its fetches
# fail with "Permission denied (publickey)"), and root-run git/cargo
# also litters .git/ and target/ with root-owned files the deploy user
# can no longer touch. CWD is preserved by sudo; HOME + PATH are set so
# ssh finds the deploy key and cargo finds the toolchain.
#
# EVERY git call goes through here — including read-only rev-parse/diff.
# Root-context git in a deploy-user-owned repo trips git's
# dubious-ownership protection (CVE-2022-24765): rev-parse returns
# EMPTY, the has-changes comparison sees ''=='' , and the repo is
# silently skipped forever. That is exactly how the installer repo
# stopped self-updating (root happened to have safe.directory entries
# for the other repos, but not this one).
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
# Minimal python3 parser. Sets _GD_* variables for the current repo.
# Falls back to defaults if geodeploy.yaml is missing.
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
    'dirty': dt.get('strategy', 'stash'),
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
    _GD_DIRTY="stash"
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

    geodeploy_as_deploy git fetch "$remote" "$branch" 2>> "$GEODEPLOY_LOG"
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
    # Deploy targets MIRROR origin — force-sync, never merge. The prior
    # `git pull` (merge) combined with the stash/stash-pop dance left
    # unresolved conflict markers in tracked files and wedged repos at a
    # detached HEAD whenever an upstream change touched the same lines as a
    # stashed deploy artifact. reset --hard can never conflict; checkout -B
    # re-attaches HEAD if a previous bad merge left it detached.
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

    # Check if working tree is clean
    if geodeploy_as_deploy git diff --quiet HEAD 2>/dev/null && [ -z "$(geodeploy_as_deploy git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        return 0  # Clean
    fi

    case "$strategy" in
        stash)
            # Deploy targets mirror origin; geodeploy_pull's reset --hard
            # overwrites tracked files regardless. Discard local changes here
            # rather than stashing — stash + stash-pop is what wrote conflict
            # markers into working-tree files when upstream touched the same
            # lines. (Strategy name kept for geodeploy.yaml compatibility.)
            #
            # clean MUST exclude untracked RUNTIME dirs: logs/ + .gnode/
            # (daemon state), backups/ (ValKey RDB archive — deleting it
            # on a deploy would be silent data loss), cache/ (Geodine
            # prefill KV), target/ (cargo — nuking it forces a full
            # rebuild every dirty cycle).
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

geodeploy_stash_pop() {
    local name="${1:-unknown}"

    # The deploy flow no longer stashes (it force-syncs to origin via
    # reset --hard). This now only DROPS legacy geodeploy-auto stashes left
    # by older versions — popping them onto a reset tree is what produced
    # conflict markers. Local deploy artifacts are not authored here, so
    # discarding the stash is safe.
    local stash_ref
    while stash_ref=$(geodeploy_as_deploy git stash list 2>/dev/null | grep -m1 "geodeploy-auto-" | cut -d: -f1); do
        [[ -n "$stash_ref" ]] || break
        geodeploy_as_deploy git stash drop "$stash_ref" 2>> "$GEODEPLOY_LOG" || break
        geodeploy_log "${name}: dropped legacy stash ${stash_ref}"
    done
}

# =============================================================================
# Actions — called by trigger matching
# =============================================================================

# Cargo build (Rust components)
geodeploy_action_build() {
    local repo_dir="$1"
    local name="$2"
    local build_dir="${_GD_BUILD_DIR:-.}"
    local build_cmd="${_GD_BUILD_CMD}"

    cd "${repo_dir}/${build_dir}" || return 1

    if [[ -n "$build_cmd" ]]; then
        # `$build_cmd` came from
        # `<repo>/geodeploy.yaml` and was eval'd. Same RCE class as
        # the `custom` action above. Restrict to a single command +
        # explicit argv split (no shell metachars) — `bash -c` would
        # be the same problem as `eval` for our threat model.
        # Acceptable forms now:
        #   build_cmd: scripts/build.sh
        #   build_cmd: cargo build --release
        #   build_cmd: composer install --no-dev
        # Anything containing `;`, `&&`, `||`, backticks, `$(...)`,
        # pipes, or redirection is rejected.
        if [[ "$build_cmd" =~ [\;\&\|\`\$\<\>] ]]; then
            geodeploy_log "${name}: BUILD rejected (forbidden shell metachars in build_cmd: ${build_cmd})"
            return 1
        fi
        # Argv-split on whitespace; leading word is the executable.
        # No shell expansion happens here.
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

# Restart a systemd service
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

# Clear PHP OPcache. The pool opcache lives in FPM shared memory — a CLI
# opcache_reset() only clears the CLI SAPI. Graceful FPM reload respawns
# workers against fresh shm, which is the actual pool-wide clear.
geodeploy_action_opcache_clear() {
    local name="$1"
    local unit
    for unit in php8.3-fpm php8.4-fpm php-fpm; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            if /usr/bin/sudo /usr/bin/systemctl reload "$unit" 2>/dev/null; then
                geodeploy_log "${name}: opcache-cleared (${unit} reloaded)"
            else
                geodeploy_log "${name}: WARN opcache-clear failed (${unit} reload denied)"
            fi
            return 0
        fi
    done
    php -r "if(function_exists('opcache_reset')){opcache_reset();}" 2>/dev/null \
        && geodeploy_log "${name}: opcache-cleared (cli only — no active FPM unit)"
}

# Restart PHP-FPM
geodeploy_action_php_fpm_restart() {
    local name="$1"
    local unit
    for unit in php8.3-fpm php8.4-fpm php-fpm; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            if /usr/bin/sudo /usr/bin/systemctl restart "$unit" 2>/dev/null; then
                geodeploy_log "${name}: php-fpm-restarted (${unit})"
            else
                geodeploy_log "${name}: WARN php-fpm-restart failed (${unit})"
            fi
            return 0
        fi
    done
    geodeploy_log "${name}: WARN php-fpm-restart skipped (no active FPM unit)"
}

# Reload gNode Lua functions
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

# Install systemd service file
geodeploy_action_service_install() {
    local repo_dir="$1"
    local name="$2"
    local changed="$3"

    local service_files
    service_files=$(echo "$changed" | grep '\.service$' || true)

    for svc in $service_files; do
        local src="${repo_dir}/${svc}"
        if [[ -f "$src" ]]; then
            if /usr/bin/sudo /usr/bin/cp "$src" /etc/systemd/system/ 2>> "$GEODEPLOY_LOG"; then
                geodeploy_log "${name}: SERVICE installed $(basename "$svc")"
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

    # Parse triggers from YAML and match against changed files
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

    # Actions run from a captured list, NOT a `| while` pipeline — the
    # pipeline subshell swallowed variable writes, and restart must be
    # DEFERRED: restarting before geodeploy_fix_perms/fix_binaries run
    # hands the service a binary it may not be able to read yet (this
    # took geodineum-comms down on the first post-ownership-change
    # deploy). geodeploy_repo performs the queued restart after the
    # permission passes.
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
                # The `custom` action used to
                # `eval` a string read from `<repo>/geodeploy.yaml`. The
                # cron orchestrator runs as deploy-user with NOPASSWD
                # systemctl-restart + 100+ chown rules in sudoers, so
                # one merged malicious PR (or a YAML-injection in a
                # legit PR) → pipeline RCE → path-to-root escalation
                # via the sudoers surface.
                #
                # Fix: drop the `custom` action entirely. There is no
                # safe whitelist of arbitrary shell strings sourced
                # from the repo. Repos that need post-deploy work
                # should add a named action via the registered
                # geodeploy_action_* dispatch above (and add the
                # corresponding sudoers entry if it needs root).
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
# Three rules, all bought with one incident. The COMMS outage of 2026-07-24 sat
# undiagnosed for 20 hours because the journal only reached back ~15: 96% of a
# 500M ring was sudo session noise from the sweeps below — roughly 1,250
# invocations every five minutes, three to four pam/session lines each, against
# a tree that had not drifted and needed none of them. The evidence was evicted
# before the question was asked.
#
#   1. Do not sudo to root when already root. The orchestrator runs from root's
#      crontab, so every call logged `root : USER=root ; COMMAND=/usr/bin/chmod
#      …` and bought no privilege the process did not already hold.
#   2. Do not act on what has not drifted. Assert-if-different means a
#      converged tree issues ZERO privileged calls.
#   3. Batch. `-exec … +` passes many paths per process, and behind a drift
#      guard find skips the exec entirely when nothing matches.
#
# Use these helpers for every ownership/mode assertion in this file. A raw
# `sudo chmod` in a loop is the bug, not the style.

# argv prefix for `find -exec`, which cannot call a shell function.
# Empty when root; bash 4.4+ expands an empty array safely under `set -u`.
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

# How many paths this run actually corrected. sudo's session lines used to be
# the only record that the sweep had done anything, which is a poor trade: 1,250
# journal lines per cycle to say "nothing had drifted". The helpers count their
# own work instead and the orchestrator prints ONE line per cycle when the count
# is non-zero — silence now means genuinely nothing changed.
_GD_PERM_FIXES=0

# Assert owner:group on ONE path, only when it differs.
# An unreadable stat falls THROUGH to the chown: never skip a fix because the
# check was inconclusive.
_gd_own() {
    local path="$1" owner="$2" group="$3" cur
    [[ -e "$path" ]] || return 0
    cur=$(stat -c '%U:%G' "$path" 2>/dev/null)
    [[ -n "$cur" && "$cur" == "${owner}:${group}" ]] && return 0
    _gd_priv /usr/bin/chown "${owner}:${group}" "$path" 2>/dev/null || true
    _GD_PERM_FIXES=$(( _GD_PERM_FIXES + 1 ))
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
    _GD_PERM_FIXES=$(( _GD_PERM_FIXES + 1 ))
    return 0
}

# Assert owner:group across a TREE. Extra find predicates go after the group
# (e.g. -type f, -not -path '*/.git/*') and AND with the drift guard.
_gd_own_tree() {
    local root="$1" owner="$2" group="$3"; shift 3
    [[ -d "$root" ]] || return 0
    # `while read -d ''` rather than `mapfile -d ''`: mapfile's -d needs bash
    # 4.4, and where it is missing it does not fail — it yields an EMPTY array,
    # so every ownership assertion in the ecosystem would quietly stop
    # happening. A silent no-op is the one failure mode this file exists to
    # prevent. read -d '' has worked since bash 3 and cannot degrade that way.
    local -a drifted=()
    local _p
    while IFS= read -r -d '' _p; do drifted+=("$_p"); done \
        < <(find "$root" "$@" \( ! -user "$owner" -o ! -group "$group" \) -print0 2>/dev/null)
    (( ${#drifted[@]} )) || return 0
    printf '%s\0' "${drifted[@]}" \
        | xargs -0r "${_GD_PRIV_ARGV[@]}" /usr/bin/chown "${owner}:${group}" 2>/dev/null || true
    _GD_PERM_FIXES=$(( _GD_PERM_FIXES + ${#drifted[@]} ))
    return 0
}

# Assert mode across a TREE. `! -perm <mode>` is an EXACT-bits mismatch test,
# so this converges on the contract rather than merely adding bits.
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
    _GD_PERM_FIXES=$(( _GD_PERM_FIXES + ${#drifted[@]} ))
    return 0
}

# =============================================================================
# Permissions — THE single authority
# =============================================================================
# This function is the ONLY place in the ecosystem that sets file ownership
# and permissions. All other scripts (install.sh, fix-permissions.sh) should
# source this library and call this function.

geodeploy_fix_perms() {
    local repo_dir="$1"
    local owner="${2:-${_GD_OWNER}}"
    local group="${3:-${_GD_GROUP}}"

    # Self-heal: the target group MUST exist or the chown below silently
    # no-ops (2>/dev/null) and the tree keeps a stale group — the exact
    # failure that left gCore in geodineum-web and crash-looped geodine.
    # install.sh creates the roster, but a worker host (e.g. the constellation
    # replica) deploying via the orchestrator may predate a new group like
    # geodineum-code. Create-if-missing makes deploys converge on any host.
    getent group "$group" >/dev/null 2>&1 || /usr/bin/sudo /usr/bin/groupadd --system "$group" 2>/dev/null || true

    # Use /usr/bin/sudo /usr/bin/chown to fix root-owned file drift.
    # FAIL LOUD on refusal: when the sudoers whitelist lacks a rule for this
    # exact owner:group+path, sudo dies at the password prompt (cron has no
    # tty), the tree keeps its stale group, and — silently — the sweep
    # converges nothing on every cycle. That skew crash-looped a gCore-consuming
    # service for a week after gCore's descriptor moved to geodineum-code.
    # The template now grants old+new groups per PHP component; this warning
    # catches the next skew before it takes a service down.
    if ! /usr/bin/sudo /usr/bin/chown -R "${owner}:${group}" "$repo_dir" 2>/dev/null; then
        geodeploy_log "PERMS WARNING: chown -R ${owner}:${group} ${repo_dir} refused — sudoers rule missing for this owner:group+path (templates/sudoers-geodeploy.tpl vs the repo's geodeploy.yaml). Tree group NOT converged."
    fi

    # Directory permissions: 2750 (owner rwx, group rx, sgid).
    # The sgid bit makes new files created under the dir (e.g. by `git pull`
    # running as the deploy_user) inherit the directory's group instead of
    # the creator's primary group. Without this, a worker's deploy-user git
    # pull into a deploy_user:gnode repo would create files as
    # deploy_user:deploy_user, and
    # gnode-daemon would lose group-read access to the new working tree.
    # cargo's target/ is a regenerable build cache, NOT deployed source — exclude
    # it from the perm sweep. chmod 640 over target/ strips the execute bit off
    # cargo's helper binaries (build-script-build, proc-macro .so, release bin),
    # so the next `cargo build` dies with "Permission denied (os error 13)".
    # cargo manages target/ perms itself; this sweep must not touch it.
    _gd_mode_tree "$repo_dir" 2750 -type d -not -path '*/.git/*' -not -path '*/target/*'

    # File permissions: 640 (owner rw, group r).
    # *.sh/*.bash are excluded here because the very next pass sets them 750:
    # sweeping them to 640 first only to raise them again left every script
    # briefly non-executable and guaranteed this pass could never be a no-op.
    _gd_mode_tree "$repo_dir" 640 -type f -not -path '*/.git/*' -not -path '*/target/*' \
        -not -name '.htaccess' -not -name 'nginx-deny.conf' -not -name '*.sh' -not -name '*.bash'

    # Shell scripts: executable (by extension)
    _gd_mode_tree "$repo_dir" 750 -type f -name '*.sh' -not -path '*/.git/*'
    _gd_mode_tree "$repo_dir" 750 -type f -name '*.bash' -not -path '*/.git/*'

    # Shell/Python scripts: detect by shebang line. Three scan locations:
    #
    #   repo_dir  (maxdepth 1) — top-level component CLIs operators invoke
    #                            via /usr/local/bin symlinks.
    #   scripts/  (maxdepth 2) — component-private utility scripts.
    #   bin/      (maxdepth 2) — same.
    #
    # repo_dir itself must be scanned: a root-level CLI with no extension
    # would otherwise have its execute bit stripped by the 640 sweep with
    # nothing restoring it — "Permission denied" even for the owner.
    for script_dir in "${repo_dir}" "${repo_dir}/scripts" "${repo_dir}/bin"; do
        [[ -d "$script_dir" ]] || continue
        local _depth=2
        [[ "$script_dir" == "$repo_dir" ]] && _depth=1
        # `! -perm 750` first, so an already-correct script is never re-read or
        # re-chmodded; `-exec … +` then hands the survivors to ONE shell.
        find "$script_dir" -maxdepth "$_depth" -type f -not -path '*/.git/*' ! -perm 750 \
            -exec sh -c 'for f; do
                    case $(head -c 2 "$f" 2>/dev/null) in "#!") chmod 750 "$f" 2>/dev/null ;; esac
                done' _ {} + 2>/dev/null
    done

    # .git/ must be writable by deploy user for git pull
    if [[ -d "${repo_dir}/.git" ]]; then
        /usr/bin/sudo /usr/bin/chown -R "${owner}:${group}" "${repo_dir}/.git" 2>/dev/null
    fi

    # .htaccess must stay www-data-readable (Apache reads it or fails closed → 403); www-data is NOT in geodineum
    for deny_file in "${repo_dir}/.htaccess" "${repo_dir}/nginx-deny.conf"; do
        if [[ -f "$deny_file" ]]; then
            /usr/bin/sudo /usr/bin/chown root:www-data "$deny_file" 2>/dev/null
            chmod 640 "$deny_file" 2>/dev/null
        fi
    done

    # Repos that www-data needs to traverse (o+x on repo root only)
    # gNode: www-data traverses to reach .gnode/ credential symlinks
    # gNode-Client: www-data loads PHP classes via Composer autoload
    local repo_name
    repo_name=$(basename "$repo_dir")
    case "$repo_name" in
        gNode|gNode-Client)
            /usr/bin/sudo /usr/bin/chmod 751 "$repo_dir" 2>/dev/null
            ;;
    esac
}

# Fix permissions for Rust binary outputs (prevent chmod 640 from stripping execute)
geodeploy_fix_binaries() {
    local repo_dir="$1"
    local name="$2"

    # Scan every */target/release/ in the repo for compiled ELF outputs
    # (top-level files only — deps/, build/, .fingerprint/ are cargo
    # internals). ELF magic is the discriminator because the 640 sweep
    # has already stripped the execute bit, so -executable can't match.
    while IFS= read -r -d '' bin_path; do
        if [[ "$(head -c 4 "$bin_path" 2>/dev/null)" == $'\x7fELF' ]]; then
            chmod 750 "$bin_path" 2>/dev/null
        fi
    done < <(find "$repo_dir" -type f -path '*/target/release/*' \
        -not -path '*/deps/*' -not -path '*/build/*' \
        -not -path '*/.fingerprint/*' -not -path '*/incremental/*' \
        -not -name '*.d' -not -name '*.rlib' -print0 2>/dev/null)
}

# Fix BAK-specific writable dirs (backup service writes as gnode)
geodeploy_fix_bak_dirs() {
    local repo_dir="$1"

    for writable_dir in "${repo_dir}/backups" "${repo_dir}/logs"; do
        if [[ -d "$writable_dir" ]]; then
            /usr/bin/sudo /usr/bin/chown -R gnode:gnode "$writable_dir" 2>/dev/null
            chmod 750 "$writable_dir" 2>/dev/null
        fi
    done
}

# COMMS runtime-writable dirs stay OWNED by the
# geodineum-comms service user (the unit's ReadWritePaths). The blanket
# geodeploy_fix_perms pass sets deploy:geodineum-comms across the tree —
# correct for code, but .gnode/ and logs/ need the daemon as OWNER or it
# can't write sessions/logs after every deploy. Mirrors install.sh's
# Geodineum-COMMS ownership block.
geodeploy_fix_comms_dirs() {
    local repo_dir="$1"

    for writable_dir in "${repo_dir}/.gnode" "${repo_dir}/logs"; do
        /usr/bin/sudo /usr/bin/mkdir -p "$writable_dir" 2>/dev/null
        /usr/bin/sudo /usr/bin/chown -R geodineum-comms:geodineum-comms "$writable_dir" 2>/dev/null
        /usr/bin/sudo /usr/bin/chmod 2750 "$writable_dir" 2>/dev/null
    done
}

# gNode runtime dirs: logs/ is untracked AND listed in the unit's
# ReadWritePaths — if it's missing, systemd cannot set up the mount
# namespace and the daemon fails with status=226/NAMESPACE on the next
# restart. A pre-excludes `git clean -fd` deleted it once and the daemon
# died hours later on its next deploy-triggered restart (the namespace
# is only rebuilt at unit start, so the damage was invisible until
# then). Owned by the gnode service user so it can write after every
# deploy's perms pass. The .gnode credential symlink is asserted too —
# same untracked-and-required class.
geodeploy_fix_gnode_dirs() {
    local repo_dir="$1"

    /usr/bin/sudo /usr/bin/mkdir -p "${repo_dir}/logs" 2>/dev/null
    /usr/bin/sudo /usr/bin/chown -R gnode:gnode "${repo_dir}/logs" 2>/dev/null
    /usr/bin/sudo /usr/bin/chmod 2750 "${repo_dir}/logs" 2>/dev/null

    if [[ ! -e "${repo_dir}/.gnode" ]]; then
        /usr/bin/sudo /usr/bin/ln -s /etc/geodineum/credentials "${repo_dir}/.gnode" 2>/dev/null
    fi
}

# Self-heal the geodineum-code source-read group MEMBERSHIP. geodeploy_fix_perms
# guarantees the group exists and owns the source; install.sh adds the members —
# but install.sh does NOT run on every deploy, so a worker re-provision or a
# drifted host can have source in geodineum-code with NOBODY in the group →
# silent web 500s and the geodine "Interface not found" autoload crash. This
# converges membership on deploy. It restarts the affected consumers ONLY when
# it actually ADDS a member (supplementary groups are cached at process start);
# steady-state is a no-op, so a normal deploy never blips the web tier.
geodeploy_ensure_code_members() {
    local changed=0 u fpm
    getent group geodineum-code >/dev/null 2>&1 \
        || { /usr/bin/sudo /usr/bin/groupadd --system geodineum-code 2>/dev/null && changed=1; }
    # Consumers of the shared framework source. Add gshield/gsignals here when
    # they deploy as gCore-linking services — keep in lockstep with
    # validate-geodineum-config.sh::check_source_readable CONSUMERS.
    for u in www-data geodine; do
        id "$u" >/dev/null 2>&1 || continue
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx geodineum-code && continue
        /usr/bin/sudo /usr/bin/usermod -aG geodineum-code "$u" 2>/dev/null && changed=1
    done
    [[ $changed -eq 0 ]] && return 0
    fpm="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -1)"
    [[ -n "$fpm" ]] && /usr/bin/sudo /usr/bin/systemctl restart "$fpm" 2>/dev/null || true
    /usr/bin/sudo /usr/bin/systemctl restart apache2 2>/dev/null || true
    if id geodine >/dev/null 2>&1 && systemctl list-unit-files geodine.service >/dev/null 2>&1; then
        /usr/bin/sudo /usr/bin/systemctl restart geodine.service 2>/dev/null || true
    fi
}

# Self-heal the geodineum-dash group + MEMBERSHIP — the identity layer behind
# the dashboard credential (/etc/geodineum/dashboard/geodineum-dashboard.txt,
# the read-only +@read `geodineum_dashboard` ACL token). gCore's wp-admin
# module pages (Dashboard, Schemas) connect through it AS www-data; the Status
# page uses the per-site cred instead, so it keeps working even when this is
# broken — exactly the "only Status connects" symptom. install.sh creates the
# group + adds www-data|gnode|deploy_user once and never re-runs, so a host
# that lost the group (image reprovision, partial install, manual groupdel)
# leaves every module page stuck on "credentials not found" with nothing to
# heal it. Mirrors geodeploy_ensure_code_members: steady-state no-op; only a
# real change blips the web tier (group membership applies only to processes
# started AFTER the change — the running-workers-lack-the-group failure mode).
geodeploy_ensure_dash_members() {
    local changed=0 u fpm
    getent group geodineum-dash >/dev/null 2>&1 \
        || { /usr/bin/sudo /usr/bin/groupadd --system geodineum-dash 2>/dev/null && changed=1; }
    for u in www-data gnode "${GEODEPLOY_DEPLOY_USER:-}"; do
        [[ -n "$u" ]] || continue
        id "$u" >/dev/null 2>&1 || continue
        id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx geodineum-dash && continue
        /usr/bin/sudo /usr/bin/usermod -aG geodineum-dash "$u" 2>/dev/null && changed=1
    done
    [[ $changed -eq 0 ]] && return 0
    geodeploy_log "ensure_dash_members: geodineum-dash membership changed → restarting web tier"
    fpm="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -1)"
    [[ -n "$fpm" ]] && /usr/bin/sudo /usr/bin/systemctl restart "$fpm" 2>/dev/null || true
    /usr/bin/sudo /usr/bin/systemctl restart apache2 2>/dev/null || true
}

# Re-assert the canonical helper-lib install at /usr/local/lib/geodineum/.
# install.sh::ensure_bootstrap_loader_installed lays these down at install
# time, but the orchestrator runs every 5 min and install.sh does NOT — so a
# host that lost the dir (manual rm, a botched uninstall sweep, an image
# reprovision) breaks the `geodineum` CLI (every verb FATALs sourcing the
# bootstrap-loader) and gNode's scripts/build.sh until a full reinstall.
# Re-asserting on each deploy makes it converge. Source = this lib's own dir
# (the freshly-pulled Geodineum/lib). Mode 0755 root:root matches install.sh:
# the libs carry no secrets (they ARE the public installer) and are sourced by
# five distinct identities (operator, www-data, gnode, geodine, deploy_user).
# Keep the helper list in lockstep with install.sh::ensure_bootstrap_loader_installed.
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
# WordPress site hardening — defensive ownership model
# =============================================================================
# Principle: www-data reads everything, writes almost nothing.
# Source code: ${GEODEPLOY_DEPLOY_USER}:www-data 640 — attacker must escalate to deploy-user to persist
# Uploads/cache: www-data:www-data 750 — writable but PHP execution blocked
# .htaccess: root:www-data 640 + immutable — attacker can't override
#
# Moats:
#   1. Source code read-only → can't write web shells to theme/plugin dirs
#   2. PHP blocked in uploads → can't execute uploaded malware
#   3. Immutable .htaccess → can't remove the PHP block
#   4. wp-config read-only → can't modify DB credentials
#   5. Credentials 600 per-owner → can't read other services' secrets
#   6. Logs centralized → can't tamper with audit trail in component log dirs

# PHP execution blocker content for writable directories
# (engine-off covers mod_php SAPIs; SetHandler None is the FPM equivalent —
# it unmaps the proxy_fcgi handler so the file is never sent to the pool)
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
    local site_dir="$1"
    local wp_root="$site_dir"

    # Detect WP root (may be in public_html/). When it is, the OUTER site dir is
    # not the docroot but must NOT stay www-data-OWNED: a popped www-data owning
    # the parent can swap the public_html docroot for one it controls, defeating
    # the read-only-source moat. Normalize the outer dir to deploy_user:www-data
    # 750 (www-data keeps group r-x = traverse only). Non-recursive so the docroot
    # tree (hardened below) and any legit www-data siblings are left intact.
    if [ -f "${wp_root}/public_html/wp-config.php" ]; then
        wp_root="${wp_root}/public_html"
        _gd_own "$site_dir" "${GEODEPLOY_DEPLOY_USER}" www-data
        _gd_mode "$site_dir" 750
    fi
    [ -f "${wp_root}/wp-config.php" ] || return 0

    # 1. All source: ${GEODEPLOY_DEPLOY_USER}:www-data 750/640
    # (www-data reads, never writes).
    # A hardcoded owner here would
    # silently fail on every non-author host (WP source retains
    # whatever ownership the prior install left — often root or
    # www-data — and the WordPress hardening's "deploy_user owns
    # source" invariant breaks).
    # Guarded: a settled site is ~40k files of which typically single digits
    # have drifted. Unguarded this forked one chmod per file per site every
    # five minutes — ~40k processes a cycle to correct about eleven of them.
    # .htaccess is excluded from the 640 file pass because steps 3-5 below own
    # it (root:www-data + immutable); sweeping it here would fight them.
    # Ownership excludes what steps 2-4 own: the writable dirs (www-data:www-data)
    # and .htaccess (root:www-data, and immutable — a chown there cannot succeed
    # anyway). The old `chown -R` claimed all of it and steps 2-4 took it back on
    # every cycle; guarded, that would be a loop that never quiets.
    # The writable dirs are excluded THEMSELVES as well as their contents
    # (`-path DIR -o -path DIR/*`); step 2 owns the directory node too, so
    # matching only the contents would leave the five dir nodes oscillating.
    _gd_own_tree "$wp_root" "${GEODEPLOY_DEPLOY_USER}" www-data -not -name '.htaccess' \
        -not -path "${wp_root}/wp-content/uploads"    -not -path "${wp_root}/wp-content/uploads/*" \
        -not -path "${wp_root}/wp-content/cache"      -not -path "${wp_root}/wp-content/cache/*" \
        -not -path "${wp_root}/wp-content/upgrade"    -not -path "${wp_root}/wp-content/upgrade/*" \
        -not -path "${wp_root}/wp-content/wflogs"     -not -path "${wp_root}/wp-content/wflogs/*" \
        -not -path "${wp_root}/wp-content/gcore-logs" -not -path "${wp_root}/wp-content/gcore-logs/*"
    _gd_mode_tree "$wp_root" 750 -type d \
        -not -path '*/uploads/*' -not -path '*/cache/*' -not -path '*/upgrade/*' -not -path '*/wflogs/*' -not -path '*/gcore-logs/*'
    _gd_mode_tree "$wp_root" 640 -type f -not -name '.htaccess' \
        -not -path '*/uploads/*' -not -path '*/cache/*' -not -path '*/upgrade/*' -not -path '*/wflogs/*' -not -path '*/gcore-logs/*'

    # 2. Writable dirs: uploads, cache, upgrade, wflogs, gcore-logs (www-data:www-data).
    #    gcore-logs is where gCore writes structured per-manager logs; without
    #    group-write it is logging-blind (errors only reach the apache log). It is
    #    NOT web-served (wp-content deny), but gets the PHP-exec block below anyway.
    for writable_dir in \
        "${wp_root}/wp-content/uploads" \
        "${wp_root}/wp-content/cache" \
        "${wp_root}/wp-content/upgrade" \
        "${wp_root}/wp-content/gcore-logs" \
        "${wp_root}/wp-content/wflogs"; do
        if [[ -d "$writable_dir" ]]; then
            # .htaccess here is owned by step 3 (root:www-data, immutable).
            _gd_own_tree "$writable_dir" www-data www-data -not -name '.htaccess'
            _gd_mode_tree "$writable_dir" 750 -type d
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
            # Rewrite ONLY when the content actually differs. This used to
            # unlock, re-tee and re-lock the file every cycle, so the blocker's
            # mtime advanced every five minutes on every site — churn that a
            # file-integrity baseline reads as a perpetually-modified file.
            if [[ "$(cat "$htaccess" 2>/dev/null)" != "$_GEODEPLOY_PHP_BLOCK" ]]; then
                _gd_priv /usr/bin/chattr -i "$htaccess" 2>/dev/null || true
                echo "$_GEODEPLOY_PHP_BLOCK" | _gd_priv /usr/bin/tee "$htaccess" > /dev/null 2>&1
                _gd_own "$htaccess" root www-data
                _gd_mode "$htaccess" 640
                _gd_priv /usr/bin/chattr +i "$htaccess" 2>/dev/null || true
            elif ! lsattr -d "$htaccess" 2>/dev/null | cut -d' ' -f1 | grep -q i; then
                # Content is right but the immutable bit was lost — restore it
                # without touching the content.
                _gd_own "$htaccess" root www-data
                _gd_mode "$htaccess" 640
                _gd_priv /usr/bin/chattr +i "$htaccess" 2>/dev/null || true
            fi
        fi
    done

    # 4. Root .htaccess: root-owned, immutable.
    # Unlock only when ownership/mode/immutability actually needs correcting;
    # the unconditional -i/+i pair ran on every site every cycle for nothing.
    if [[ -f "${wp_root}/.htaccess" ]]; then
        local _root_ht="${wp_root}/.htaccess"
        local _ht_state _ht_immutable=0
        _ht_state=$(stat -c '%U:%G %a' "$_root_ht" 2>/dev/null)
        lsattr -d "$_root_ht" 2>/dev/null | cut -d' ' -f1 | grep -q i && _ht_immutable=1
        if [[ "$_ht_state" != "root:www-data 640" || "$_ht_immutable" -eq 0 ]]; then
            _gd_priv /usr/bin/chattr -i "$_root_ht" 2>/dev/null || true
            _gd_own "$_root_ht" root www-data
            _gd_mode "$_root_ht" 640
            _gd_priv /usr/bin/chattr +i "$_root_ht" 2>/dev/null || true
        fi
    fi

    # 5. .geodineum/ config: ${GEODEPLOY_DEPLOY_USER}:www-data
    # (www-data reads config, can't modify).
    if [[ -d "${wp_root}/.geodineum" ]]; then
        _gd_own_tree "${wp_root}/.geodineum" "${GEODEPLOY_DEPLOY_USER}" www-data
        _gd_mode_tree "${wp_root}/.geodineum" 750 -type d
        _gd_mode_tree "${wp_root}/.geodineum" 640 -type f
    fi

    # Best-effort hardening MUST NOT return non-zero. The trailing `if`
    # above evaluates to false on any site without a .geodineum/ dir, so
    # without this the function returns 1 — and under the installer's
    # `set -e` (where the call is unguarded) that silently ABORTS the
    # whole install mid-step, before Phase 10. Explicit success.
    return 0
}

# Harden ALL WordPress sites under /var/www/
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

# Fix /etc/geodineum config directory permissions
# =============================================================================
# Security model (current — supersedes the pre-2026-06 "www-data in no group,
# 0600 www-data creds, 0644 config" model; that predates the narrow-group rework):
#   - www-data is NOT in the broad `geodineum`/`geodineum-creds` groups (so a PHP
#     compromise can't read daemon/admin/service secrets), but IS in surgical
#     single-purpose groups granting exactly what gCore needs to read:
#       geodineum-web       → per-site ValKey client cred (root:geodineum-web 0640)
#       geodineum-dash      → read-only dashboard ACL token (gnode:geodineum-dash 0640)
#       geodineum-bootstrap → bootstrap.env + PHP component envs (0640)
#       geodineum-code      → shared gCore/gTemplate source (read)
#   - Secrets are 0640 owned root/gnode + a narrow reader group (NOT 0600-per-user,
#     NOT 0644-world). The "others" bit is strict-deny across the board.
#   - Directory traversal: o+x ONLY where www-data must reach its own files
#     (credentials/ is 0751 traverse-no-list); listing needs group membership.
#
# File classification:
#   PUBLIC (644)  — no secrets, www-data and all components need to read
#   INTERNAL (640) — no secrets, but only daemon/geodineum-group needs to read
#   SECRET (600)  — credentials, per-owner only
#
# If a file doesn't fit these categories, add it explicitly below with a comment.
# =============================================================================
geodeploy_fix_config_perms() {
    local config_root="${1:-/etc/geodineum}"

    [[ ! -d "$config_root" ]] && return 0

    # ── Root directory: traversable by everyone (o+x) ──
    # www-data needs to traverse to reach credentials/ and read bootstrap.env
    _gd_own "$config_root" root geodineum
    _gd_mode "$config_root" 751

    # ── bootstrap.env: strict-deny posture (operator security stance 2026-06-03) ──
    # Owner: root (only root writes). Group: geodineum-bootstrap (a narrow
    # group containing ONLY the legitimate readers: www-data, gnode, deploy
    # user, geodine). Mode: 0640. World bit + group-write bit are strict-deny.
    #
    # Replaces the pre-2026-06-03 pattern of `root:root 0644` (world-
    # readable). The 0644 leak gave reconnaissance — anyone on the host could
    # read the file's existence/contents (VALKEY host/port/creds_path) and
    # build a deployment topology map. The narrow group below keeps PHP-side
    # read access (gCore bootstrap-loader needs it) without exposing the
    # file to every uid on the host.
    #
    # gNode daemon's `ecosystem_config.rs` strict-deny check accepts only
    # 0640 (or 0600 root-only). Any drift to 0644/0666/etc. → FATAL at
    # daemon startup.
    if [[ -f "${config_root}/bootstrap.env" ]]; then
        _gd_own "${config_root}/bootstrap.env" root geodineum-bootstrap
        _gd_mode "${config_root}/bootstrap.env" 0640

        # 2026-06-03 content-drift self-heal: detect any keys outside the
        # strict whitelist (legacy "shared paths/settings" dumping ground
        # from pre-D.x design — kills the gnode-daemon at startup because
        # the Rust loader fatals on non-whitelisted keys). Rewrite with
        # canonical 3-key shape, preserving VALKEY_* values from disk.
        local _extra
        # `|| true`: under set -e + pipefail a no-match grep (the NORMAL
        # case — no drift) makes the whole substitution fail and aborts
        # the run.
        _extra=$(grep -E "^[A-Z_]+=" "${config_root}/bootstrap.env" 2>/dev/null \
            | grep -vE "^(VALKEY_HOST|VALKEY_PORT|VALKEY_CREDS_PATH)=" \
            | head -1 || true)
        if [[ -n "$_extra" ]]; then
            geodeploy_log "bootstrap.env: content drift detected, rewriting to strict 3-key shape"
            local _host _port _creds _ts
            _host=$(grep -E '^VALKEY_HOST=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            _port=$(grep -E '^VALKEY_PORT=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            _creds=$(grep -E '^VALKEY_CREDS_PATH=' "${config_root}/bootstrap.env" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
            # Defaults if any key was missing entirely from the drifted file.
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

    # ── components/: per-component env files ──
    # Default: INTERNAL (640 gnode:geodineum) — daemon configs.
    # PHP-readable exceptions get root:geodineum-bootstrap 0640 (NOT world-
    # readable 0644 — same narrow-group reasoning as bootstrap.env above).
    if [[ -d "${config_root}/components" ]]; then
        # Directory itself: gnode:geodineum-bootstrap 0750 (was 0755 — the
        # world-traverse bit gave nothing legitimate; geodineum-bootstrap
        # members already traverse via the group bit).
        _gd_own "${config_root}/components" gnode geodineum-bootstrap
        _gd_mode "${config_root}/components" 0750
        _gd_own_tree "${config_root}/components" gnode geodineum-bootstrap -mindepth 1 -type d
        _gd_mode_tree "${config_root}/components" 0750 -mindepth 1 -type d

        # Files: default INTERNAL (640 gnode:geodineum) — daemon-only reads.
        # The exceptions below (receipt key, PHP-readable env, a component's own
        # env) are re-asserted AFTER this default, so they must also be excluded
        # from it — otherwise each cycle sets the default and then corrects it,
        # and the drift guard can never go quiet on those paths.
        _gd_own_tree "${config_root}/components" gnode geodineum -type f \
            -not -name 'receipt_signing.key' \
            -not -path "${config_root}/components/gCore/gcore.env" \
            -not -path "${config_root}/components/gTemplate/gtemplate.env" \
            -not -path "${config_root}/components/geodineum-comms/geodineum-comms.env"
        _gd_mode_tree "${config_root}/components" 0640 -type f \
            -not -name 'receipt_signing.key'

        # Per-node private signing key: gnode-only, never group-readable
        local _receipt_key="${config_root}/components/gnode-daemon/receipt_signing.key"
        if [[ -f "$_receipt_key" ]]; then
            _gd_own "$_receipt_key" gnode gnode
            _gd_mode "$_receipt_key" 0600
        fi

        # PHP-readable component configs: root:geodineum-bootstrap 0640
        # (NOT world-readable 0644). www-data is a member of geodineum-bootstrap
        # via install.sh phase_users_groups — reads via group bit, not via
        # the "others" bit. Each PHP env file contains non-secret settings
        # (cache driver, debug flags, paths) but the file's existence still
        # reveals deployment shape, so the narrow-group reasoning applies.
        for php_env in \
            "${config_root}/components/gCore/gcore.env" \
            "${config_root}/components/gTemplate/gtemplate.env"; do
            if [[ -f "$php_env" ]]; then
                _gd_own "$php_env" root geodineum-bootstrap
                _gd_mode "$php_env" 0640
            fi
        done

        # A component that runs under its OWN identity must be able to read its
        # own env file. The default above (gnode:geodineum) is unreadable to
        # such a service — geodineum-comms is in groups geodineum-comms +
        # geodineum-bootstrap, NOT geodineum — and because the unit uses
        # `EnvironmentFile=-`, the failure is SILENT: the daemon starts, the
        # token is simply absent, and Telegram/SMTP never come up. Group the
        # file to the component's own identity so it can read it.
        _comms_env="${config_root}/components/geodineum-comms/geodineum-comms.env"
        if [[ -f "$_comms_env" ]] && getent group geodineum-comms >/dev/null 2>&1; then
            _gd_own "$_comms_env" root geodineum-comms
            _gd_mode "$_comms_env" 0640
        fi
    fi

    # ── credentials/ ──
    # Owner root:geodineum-creds 0751 (was 0750 previously).
    # o+x allows www-data to TRAVERSE the dir to reach
    # valkey_client_<site>.password files (which are gnode:www-data 0640).
    # Listing requires geodineum-creds membership (no o+r). Admin +
    # daemon credentials remain unreadable from www-data via their
    # per-file 0640 root:geodineum-creds / gnode:geodineum-creds modes.
    if [[ -d "${config_root}/credentials" ]]; then
        _gd_own "${config_root}/credentials" root geodineum-creds
        _gd_mode "${config_root}/credentials" 0751
    fi

    # ── dashboard/ (www-data accessible via geodineum-dash) ──
    # The dir + its single credential (geodineum-dashboard.txt — the read-only
    # geodineum_dashboard ACL token) are the ONLY /etc/geodineum secret location
    # www-data may read; gCore's wp-admin module pages connect through it.
    # Create the dir if absent and re-assert dir + cred perms every cycle so
    # drift self-heals. The backing group membership is healed by
    # geodeploy_ensure_dash_members; the cred CONTENT + ACL are provisioned by
    # install.sh::provision_dashboard_acl (this pass never invents a secret).
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

    # ── sites/: per-site config (gnode:www-data 0750) ──
    # www-data needs traverse for PHP ConfigLoader resolution. gnode
    # group is the writer (daemon manages site state at runtime).
    if [[ -d "${config_root}/sites" ]]; then
        _gd_own "${config_root}/sites" gnode www-data
        _gd_mode "${config_root}/sites" 0750
        _gd_own_tree "${config_root}/sites" gnode www-data -mindepth 1
        _gd_mode_tree "${config_root}/sites" 0750 -mindepth 1 -type d
        _gd_mode_tree "${config_root}/sites" 0640 -type f
    fi

    # ── services/: standalone service config (gnode:gnode 0750) ──
    if [[ -d "${config_root}/services" ]]; then
        _gd_own "${config_root}/services" gnode gnode
        _gd_mode "${config_root}/services" 0750
        _gd_own_tree "${config_root}/services" gnode gnode -mindepth 1
        _gd_mode_tree "${config_root}/services" 0750 -mindepth 1 -type d
        _gd_mode_tree "${config_root}/services" 0640 -type f
    fi
}

# Re-assert Geodineum-BAK perms so the valkey-backup timer (User=gnode) can
# actually run. BAK is NOT in CORE_REPOS, so the normal repo sweep never touches
# it — an operator edit that leaves backup-valkey.sh owned by a non-gnode user
# silently breaks the timer with 203/EXEC (Permission denied) and nothing heals
# it. Scripts → root:gnode 0750 (gnode execs via the group, no world bits);
# backups/ → gnode:gnode (the service writes RDBs there as gnode).
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

# Fix centralized log directory permissions at /var/log/geodineum/
# Each subdirectory is owned by its writer, group geodineum for cross-read.
# Writers can only write to their own subdirs. No cross-writing.
geodeploy_fix_log_perms() {
    local log_root="${1:-${GEODINEUM_LOG_ROOT}}"

    [[ ! -d "$log_root" ]] && return 0

    # Root directory: root:geodineum (nobody writes to root, only subdirs)
    _gd_own "$log_root" root geodineum
    _gd_mode "$log_root" 750

    # Daemon logs: gnode:geodineum (gnode writes, geodineum reads)
    for dir in gnode valkey; do
        _gd_own_tree "${log_root}/${dir}" gnode geodineum
    done

    # COMMS logs → geodineum-comms:geodineum (COMMS daemon
    # writes under its own user now, geodineum group reads)
    _gd_own_tree "${log_root}/comms" geodineum-comms geodineum

    # PHP/web logs: www-data:geodineum (www-data writes, geodineum reads)
    for dir in gcore apache wordpress themes; do
        _gd_own_tree "${log_root}/${dir}" www-data geodineum
    done

    # Deploy orchestrator log: <deploy_user>:geodineum. MUST be deploy-user-owned,
    # never root — the orchestrator runs git AS the deploy user with `2>>LOG`
    # redirects, so a root-owned log denies those appends ("/bin/sh: cannot
    # create ...: Permission denied"). geodineum group lets the operator read.
    _gd_own_tree "${log_root}/deploy" "${GEODEPLOY_DEPLOY_USER}" geodineum

    # Extra log-dir ownership from the deployment-local overlay.
    if declare -F geodeploy_fix_log_extras >/dev/null; then
        geodeploy_fix_log_extras "$log_root"
    fi

    # Ensure 750/640 across all (owner writes, group reads, others nothing).
    # The deploy dir is EXCLUDED from the 750 pass — it carries setgid (2750,
    # restored below) and a blanket 750 would strip it every cycle, then the
    # restore would re-add it, so the pair never converged and the guard could
    # never go quiet.
    _gd_mode_tree "$log_root" 750 -type d -not -path "${log_root}/deploy"
    _gd_mode_tree "$log_root" 640 -type f
    # Restore setgid on the deploy dir so files the orchestrator and the
    # deploy user create there inherit the geodineum group (operator read).
    _gd_mode "${log_root}/deploy" 2750
}

# =============================================================================
# Credential provisioning — called by `geodineum register`
# =============================================================================
# Sets credential file ownership to match the service's runtime user.
# The runtime user must be a member of the geodineum group for directory
# traversal. The file itself is 600 (owner-only read).
#
# Model:
#   /etc/geodineum/credentials/         root:geodineum 750  (group traverses)
#   valkey_client_<site_id>.password    <runtime_user>:<runtime_user> 600
#
# This means:
#   - gnode reads daemon/comms/backup credentials
#   - www-data reads PHP site credentials
#   - geodine reads its own credential
#   - A new service user reads its own credential
#   - No service can read another service's credential

geodeploy_fix_credential() {
    local cred_file="$1"
    local runtime_user="$2"

    if [[ ! -f "$cred_file" ]]; then
        return 1
    fi

    _gd_own "$cred_file" "$runtime_user" "$runtime_user"
    _gd_mode "$cred_file" 600
}

# Fix ALL credential files to match their intended runtime user.
# Called during deploy cycles and by fix-permissions.sh.
#
# ─── PERMISSION / ACL MODEL — 3 COORDINATED LOCATIONS (keep in sync) ─────────
# This function is [3] of three places that define the ValKey cred-ownership +
# client ACL model; they MUST change together (fixing one alone is what caused
# the geodine NOAUTH crash-loop). Canonical model: ~/gh/PERMISSION_MODEL.md.
#   [1] gNode/scripts/register-site.sh   — web-site creds + ACL grant
#   [2] gNode/scripts/onboard-service.sh — service/component creds + ACL grant
#   [3] THIS function — deploy-time enforcement of cred ownership from the
#       per-cred .owner sidecars (root:group:mode), NO www-data default.
# ────────────────────────────────────────────────────────────────────────────
geodeploy_fix_all_credentials() {
    local creds_dir="${1:-/etc/geodineum/credentials}"

    [[ ! -d "$creds_dir" ]] && return 0

    # Dir mode MUST match install.sh's contract: root:geodineum-creds
    # 0751. The o+x bit is traverse-ONLY (no listing) and is what lets
    # www-data (PHP client creds), geodineum-comms, and other service
    # users reach their own 0600/0640 files without broad group
    # memberships. This function previously forced 0750 — the first
    # orchestrator cycle after a long outage stripped the traverse bit
    # and broke every non-group cred consumer at once (COMMS NOAUTH
    # crash-loop; PHP sites silently degraded).
    _gd_own "$creds_dir" root geodineum-creds
    _gd_mode "$creds_dir" 0751

    # Daemon credentials → gnode:gnode 600
    for f in \
        "${creds_dir}/valkey_daemon.password" \
        "${creds_dir}/valkey.password" \
        "${creds_dir}/valkey_client.password"; do
        [[ -f "$f" ]] && geodeploy_fix_credential "$f" "gnode"
    done

    # COMMS credentials → root:geodineum-comms 0640. The COMMS
    # daemon runs as its own user now (NOT gnode); root owns so the
    # daemon can't rewrite its own credentials, group grants read.
    # Covers the ValKey ACL password + SMTP creds the dispatcher reads.
    for f in \
        "${creds_dir}/valkey_comms.password" \
        "${creds_dir}"/smtp_comms.*; do
        if [[ -f "$f" ]]; then
            _gd_own "$f" root geodineum-comms
            _gd_mode "$f" 0640
        fi
    done

    # Client credentials → ownership declared by a per-cred .owner sidecar
    # (root:group:mode) written at provisioning. The sidecar is the single
    # source of truth, so this pass can NEVER clobber a service's cred back to
    # www-data (the bug that crash-looped geodine for 187 restarts). The
    # legacy "default to www-data" is GONE. Model:
    #   web-site cred     → root:geodineum-web 0640 (www-data reads via the
    #                       single-member geodineum-web group)
    #   service/component → root:geodineum 0640     (its runtime user is in
    #                       geodineum; www-data is NOT, so a web compromise
    #                       cannot read service creds)
    # No sidecar → ownership is PRESERVED untouched (zero-breakage rollout;
    # the migration writes sidecars, then this pass enforces them).
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

    # .htaccess is ALWAYS root:www-data (uniform rule, no per-dir exceptions)
    for f in "${creds_dir}/.htaccess" "${creds_dir}/nginx-deny.conf"; do
        if [[ -f "$f" ]]; then
            _gd_own "$f" root www-data
            _gd_mode "$f" 640
        fi
    done
}

# =============================================================================
# Pro extension helpers
# =============================================================================
geodeploy_deploy_pro() {
    local manifest="$1"

    [[ ! -f "$manifest" ]] && return 0

    local parsed
    parsed=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
for e in d.get('pro', []):
    print('{name}|{branch}|{remote}|{type}'.format(**e))
" "$manifest" 2>/dev/null) || {
        geodeploy_log "MANIFEST: ERROR parse-failed"
        return 1
    }

    echo "$parsed" | while IFS='|' read -r name branch remote comp_type; do
        [[ -z "$name" ]] && continue

        local pro_dir="${GEODINEUM_ROOT}/pro/${comp_type}/${name}"

        # Clone if missing
        if [[ ! -d "$pro_dir" ]]; then
            if geodeploy_as_deploy git clone --branch "$branch" "$remote" "$pro_dir" 2>> "$GEODEPLOY_LOG"; then
                geodeploy_log "pro/${name}: CLONE success"
            else
                geodeploy_log "pro/${name}: ERROR clone-failed"
                continue
            fi
        fi

        # Skip symlinks (local dev packages)
        [[ -L "$pro_dir" ]] && continue
        [[ ! -d "${pro_dir}/.git" ]] && continue

        cd "$pro_dir" || continue

        geodeploy_fetch "$branch" || continue
        geodeploy_has_changes "$branch" || continue

        local revs changed
        IFS='|' read -r local_rev remote_rev count <<< "$(geodeploy_get_revs "$branch")"

        geodeploy_handle_dirty "$_GD_DIRTY" "pro/${name}" || continue

        changed=$(geodeploy_get_changed "$branch")
        if geodeploy_pull "$branch"; then
            geodeploy_log "pro/${name}: PULL ${local_rev}→${remote_rev} (${count} commits)"

            # Type-based actions
            case "$comp_type" in
                gCore)
                    if echo "$changed" | grep -qE '\.php$'; then
                        geodeploy_action_opcache_clear "pro/${name}"
                    fi
                    geodeploy_fix_perms "$pro_dir" "${GEODEPLOY_DEPLOY_USER}" "www-data"
                    ;;
                gNode)
                    if echo "$changed" | grep -qE '\.lua$'; then
                        geodeploy_action_lua_reload "pro/${name}"
                    fi
                    geodeploy_fix_perms "$pro_dir" "${GEODEPLOY_DEPLOY_USER}" "gnode"
                    ;;
            esac
        else
            geodeploy_log "pro/${name}: ERROR pull-failed"
        fi

        geodeploy_stash_pop "pro/${name}"
    done
}

# =============================================================================
# Symlink management — ensure declared links exist after pull
# =============================================================================
# Reads the 'links' section from geodeploy.yaml and creates/verifies symlinks.
# Runs on every deploy (not trigger-based) because symlinks are infrastructure.
#
# geodeploy.yaml format:
#   links:
#     - target: /home/<deploy-user>/models
#       link: models
#     - target: /home/<deploy-user>/datasets
#       link: datasets
#
# Paths relative to repo root. Target must exist. Link is created if missing.

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
            # Symlink exists — verify target
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

    # core.fileMode=false: installer owns perms, not git — else the perms pass's chmods read as phantom-dirty every cycle (blocks pulls, forces needless reset)
    geodeploy_as_deploy git config core.fileMode false 2>/dev/null || true

    # Track the branch the repo is ACTUALLY checked out on — never a hardcoded
    # default. The orchestrator's CORE_REPOS pin "main", but a test server may
    # be deployed on a feature branch. Force-syncing
    # such a checkout onto main clobbers the deployed branch (and the old
    # merge+stash path turned it into committed conflict markers — the root of
    # the gTemplate corruption). Honor the checked-out branch; fall back to the
    # configured branch only when HEAD is detached.
    local current_branch
    current_branch=$(geodeploy_as_deploy git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
        branch="$current_branch"
    fi

    # Fetch
    geodeploy_fetch "$branch" || {
        geodeploy_log "${name}: ERROR fetch-failed"
        return 1
    }

    # Check for changes
    if ! geodeploy_has_changes "$branch"; then
        # No new commits — but ownership may still have drifted (a chown
        # refused by a stale sudoers whitelist, root-owned files from manual
        # sudo edits, …). fix_perms used to run ONLY on pull, so a quiet
        # repo kept wrong ownership forever: after a sudoers group skew,
        # gCube/gTemplate/gNode-Client could sit drifted for a week because
        # they had nothing to pull. Detect-then-converge: one find that stops
        # at the first wrong-owner/group entry (clean tree = one cheap scan,
        # .git and cargo's target/ stay unmanaged as in fix_perms itself).
        #
        # The detector must exclude EXACTLY what fix_perms declines to converge,
        # or it reports drift that no run can ever clear. .htaccess and
        # nginx-deny.conf are deliberately root:www-data (fix_perms keeps them
        # readable to Apache, which fails closed with a 403 otherwise) — while
        # they were in scope here every repo re-ran the full sweep every five
        # minutes forever: 528 "drift detected" lines in one log, each dragging
        # ~40k chmod spawns across /var/www behind it. A guard that disagrees
        # with the enforcer is not a guard.
        if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
            geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml" || true
        fi
        if [[ -n "$(find "$repo_dir" -not -path '*/.git*' -not -path '*/target*' \
                -not -name '.htaccess' -not -name 'nginx-deny.conf' \
                \( ! -group "$_GD_GROUP" -o ! -user "$_GD_OWNER" \) -print -quit 2>/dev/null)" ]]; then
            geodeploy_log "${name}: ownership drift detected (no new commits) — converging to ${_GD_OWNER}:${_GD_GROUP}"
            geodeploy_fix_perms "$repo_dir" "$_GD_OWNER" "$_GD_GROUP"
        fi
        return 0
    fi

    # Load descriptor or use defaults
    if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
        geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml"
    fi

    # Record pre-deploy rev for rollback
    local pre_deploy_rev
    pre_deploy_rev=$(geodeploy_as_deploy git rev-parse HEAD 2>/dev/null)
    IFS='|' read -r local_rev remote_rev count <<< "$(geodeploy_get_revs "$branch")"

    # Handle dirty tree
    geodeploy_handle_dirty "$_GD_DIRTY" "$name" || return 0

    # Get changed files before pull
    local changed
    changed=$(geodeploy_get_changed "$branch")

    # Pull
    if geodeploy_pull "$branch"; then
        geodeploy_log "${name}: PULL ${local_rev}→${remote_rev} (${count} commits)"

        # Re-parse the descriptor — the pull may have CHANGED
        # geodeploy.yaml, and ownership/service values must come from
        # the version just deployed, not the one we read pre-pull.
        # (First observed when a group change rode in a deploy: the
        # cycle applied the OLD group, and with no further commits the
        # has-changes gate meant no later cycle ever corrected it.)
        if [[ -f "${repo_dir}/geodeploy.yaml" ]]; then
            geodeploy_parse_descriptor "${repo_dir}/geodeploy.yaml" || true
        fi

        # Run triggered actions (build etc). Restart is NOT executed
        # here — it's queued in _GD_RESTART_QUEUED and runs after the
        # permission passes below, so the service never starts against
        # a binary it can't read.
        geodeploy_match_and_run "$repo_dir" "$name" "$changed"

        # Fix permissions
        geodeploy_fix_perms "$repo_dir" "$_GD_OWNER" "$_GD_GROUP"
        geodeploy_fix_binaries "$repo_dir" "$name"

        # Ensure declared symlinks (geodeploy.yaml: links section)
        geodeploy_ensure_links "$repo_dir" "$name"

        # Special cases
        if [[ "$name" == "Geodineum-BAK" ]]; then
            geodeploy_fix_bak_dirs "$repo_dir"
        fi
        if [[ "$name" == "gNode" ]]; then
            geodeploy_fix_gnode_dirs "$repo_dir"
        fi
        if [[ "$name" == "Geodineum-COMMS" ]]; then
            geodeploy_fix_comms_dirs "$repo_dir"
        fi
        # Shared-source components: fix_perms guaranteed the geodineum-code GROUP
        # owns the tree, but not that its CONSUMERS are members. Converge that
        # here so a worker/fresh host can't end up with source in a group nobody
        # is in (the silent-500 / geodine-crash class).
        if [[ "$_GD_GROUP" == "geodineum-code" ]]; then
            geodeploy_ensure_code_members
        fi
        # Component-specific fix-ups from the deployment-local overlay.
        if declare -F geodeploy_fix_extras >/dev/null; then
            geodeploy_fix_extras "$name" "$repo_dir"
        fi

        # Deferred service restart — only now, with ownership, modes,
        # executable bits, and runtime dirs all settled.
        if [[ -n "${_GD_RESTART_QUEUED:-}" ]]; then
            geodeploy_action_restart "$_GD_RESTART_QUEUED"
            _GD_RESTART_QUEUED=""
        fi

        # Publish resolved manifest values to the ValKey registry so
        # `geodineum describe` / `geodineum logs <svc>` can look up the
        # service without re-parsing YAML. Best-effort, silent on failure
        # (ValKey down, missing admin creds, no name field in manifest).
        local _registry_lib="${GEODINEUM_ROOT}/Geodineum/lib/manifest-registry.sh"
        if [[ -f "${repo_dir}/geodeploy.yaml" && -r "$_registry_lib" ]]; then
            # shellcheck source=/dev/null
            source "$_registry_lib"
            manifest_publish_registry "${repo_dir}/geodeploy.yaml" 2>/dev/null || true
        fi
    else
        geodeploy_log "${name}: ERROR pull-failed ${local_rev}→${remote_rev}"
    fi

    # Restore stashed changes
    geodeploy_stash_pop "$name"
}

# =============================================================================
# Post-deploy guardrail: verify the web tree is still Apache-readable.
# =============================================================================
# Detection, NOT routine restarts. After the perm pass, every web-served repo
# must be group www-data (the web server's PRIMARY group — present in every
# worker unconditionally). A file that drifts to a supplementary group (e.g.
# the retired geodineum-web) reads only for workers that happen to carry that
# group, producing intermittent "(13)Permission denied: .htaccess
# pcfg_openfile" 500s. This logs a loud WARNING if the invariant breaks so a
# regression surfaces in the deploy log instead of a downed wp-admin.
# Pure stat/find — no sudo, no service restart.
geodeploy_verify_web_readable() {
    local root="${1:-${GEODINEUM_ROOT:-/opt/geodineum}}"
    local repo drift dirs_no_x
    # Web components discovered from the manifest group, so comprehensive
    # installs are covered without naming their components in this source.
    local -a repos=(gCore gTemplate gCube gNode-Client) _wd _wn
    for _wd in "${root}"/*/; do
        _wn="$(basename "$_wd")"
        [[ " ${repos[*]} " == *" ${_wn} "* ]] && continue
        grep -qE 'group:[[:space:]]*geodineum-code' "${_wd}geodeploy.yaml" 2>/dev/null \
            && repos+=("$_wn")
    done
    for repo in "${repos[@]}"; do
        [[ -d "${root}/${repo}" ]] || continue
        # Files whose group is neither www-data nor geodineum-code (the shared
        # source-read group www-data belongs to — the canonical model). A file
        # in some OTHER group is real drift Apache may not be able to read.
        drift=$(find "${root}/${repo}" -type f ! -group www-data ! -group geodineum-code ! -path '*/.git/*' 2>/dev/null | head -1)
        # Dirs www-data can't traverse via owner/group/other (no x for group www-data).
        dirs_no_x=$(find "${root}/${repo}" -type d ! -perm -g+x ! -path '*/.git/*' 2>/dev/null | head -1)
        if [[ -n "$drift" ]]; then
            geodeploy_log "WEB-PERM WARNING: ${repo} has non-www-data group files (e.g. ${drift#${root}/}). Apache reads may fail intermittently — run: sudo ${root}/Geodineum/scripts/fix-permissions.sh"
        fi
        if [[ -n "$dirs_no_x" ]]; then
            geodeploy_log "WEB-PERM WARNING: ${repo} has non-traversable dir (e.g. ${dirs_no_x#${root}/}). Apache cannot reach files below it."
        fi
    done
}

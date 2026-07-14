#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# Geodineum Uninstall Script (Tier-4 4.1)
# =============================================================================
#
# Symmetric inverse of install.sh's 11-phase flow. LIFO action order:
#   1. systemd unit disable + stop (geodineum-managed units)
#   2. ValKey / Redis purge (apt packages + source-build artifacts +
#      config/state/log dirs + valkey system user). Runs BEFORE unit-file
#      removal so `systemctl stop` can still resolve the units.
#   3. systemd unit file removal + daemon-reload (sweeps any units left
#      behind; the daemon-reload picks up the deleted set in one pass)
#   4. /etc/geodineum/ removal (credentials, bootstrap.env, components/*.env)
#   5. /var/lib/valkey-gnode (with backup-snapshot-first prompt)
#   6. /opt/geodineum/ (operator-confirmed; contains all components)
#   7. /etc/sudoers.d/geodineum drop-in
#   8. geodineum group + service users (gnode, deploy_user) — operator-confirmed
#
# Safety posture:
# - Commit-by-default : plain `uninstall.sh` actually deletes.
#     Pass --dry-run to preview without changes.
#   - Refuses if any geodineum systemd unit is active without --force.
#   - Always offers backup-snapshot-first before deleting ValKey data.
#   - Idempotent: re-running on a partially uninstalled state proceeds cleanly.
#
# Invariants:
#   - F (SECRETS_VIA_FILE_PATH): never `cat` credential files into logs;
#     only the path is referenced.
#   - G (SET_EUO_PIPEFAIL): line 2 `set -euo pipefail` (this script).
#   - ABSOLUTE_PATH_FOR_PRIVILEGED_TOOLS: /usr/bin/<tool> for sudo-trusted ops.
#
# Usage:
#   sudo ./uninstall.sh [--dry-run] [--commit] [--force] [--keep-data]
#                       [--keep-users] [--quiet]
#
# Examples:
#   sudo ./uninstall.sh                # dry-run preview (default)
#   sudo ./uninstall.sh --commit       # actually delete (with prompts)
#   sudo ./uninstall.sh --commit --force --quiet --keep-data
#                                      # full unattended uninstall, keeping
#                                      # ValKey data and the geodineum group
# =============================================================================

# =============================================================================
# Colors + Logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

QUIET="false"

log_info()    { [[ "$QUIET" != "true" ]] && echo -e "${CYAN}[INFO]${NC} $1" || true; }
log_success() { [[ "$QUIET" != "true" ]] && echo -e "${GREEN}  OK${NC}  $1" || true; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1" >&2; }
log_step()    { [[ "$QUIET" != "true" ]] && { echo ""; echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; } || true; }
log_dry()     { echo -e "${YELLOW}[DRY]${NC} Would: $1"; }

# =============================================================================
# Shared installer primitives 
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "${SCRIPT_DIR}/lib/component-primitives.sh" ]]; then
    # shellcheck source=lib/component-primitives.sh
    source "${SCRIPT_DIR}/lib/component-primitives.sh"
else
    log_error "Missing required library: ${SCRIPT_DIR}/lib/component-primitives.sh"
    exit 1
fi

# =============================================================================
# Defaults
# =============================================================================

DRY_RUN="false"       # commit by default; pass --dry-run to preview
FORCE="false"         # legacy no-op alias kept for backward-compat
KEEP_DATA="false"     # preserve /var/lib/valkey-gnode
KEEP_USERS="false"    # preserve geodineum group + service users

# Canonical paths (symmetric inverse of install.sh's track_path_if_new sites).
# Listed in REVERSE installer order so deletion is LIFO.
INSTALLER_PATHS=(
    "/usr/local/bin/geodineum"
    "/usr/local/bin/gcli"
    "/usr/local/lib/geodineum"
    "/etc/geodineum"
    "/var/log/geodineum"
)

# Optional manifest path. If install.sh persists INSTALLED_PATHS at success
# (forward-compat from 4.1.a manifest-write commit), prefer the manifest
# over the hardcoded list — preserves co-located unrelated files.
MANIFEST_PATH="/etc/geodineum/installed.manifest"

# Systemd units the installer creates (Tier-2 2.8 sandbox-hardened set).
# stop+disable in LIFO order (timers before services they trigger).
UNINSTALL_UNITS=(
    "valkey-backup.timer"
    "valkey-backup.service"
    "geodineum-comms.service"
    "gnode-daemon.service"
    "valkey-gnode.service"
)

# Systemd unit file globs to sweep after stop+disable.
UNIT_FILE_GLOBS=(
    "/etc/systemd/system/geodineum-*.service"
    "/etc/systemd/system/geodineum-*.timer"
    "/etc/systemd/system/valkey-*.service"
    "/etc/systemd/system/valkey-*.timer"
    "/etc/systemd/system/gnode-*.service"
    "/etc/systemd/system/gnode-*.timer"
)

# =============================================================================
# Helpers
# =============================================================================

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Geodineum uninstaller — symmetric inverse of install.sh.

Options:
  --dry-run        Preview actions without deleting.
  --keep-data      Preserve /var/lib/valkey-gnode (skip data deletion prompt).
  --keep-users     Preserve geodineum group + service users.
  --quiet          Suppress info/success log lines (errors + warnings still print).
  --commit         (no-op alias kept for backward-compat — commit is now default)
  --force          (no-op alias kept for backward-compat — auto-stops active units)
  -h, --help       This message.

Safety:
  Default mode is COMMIT (actually delete). Pass --dry-run to preview only.
  Active geodineum systemd units are stopped automatically.
  Always prompts before deleting /var/lib/valkey-gnode unless --keep-data.

Exit codes:
  0   success (or dry-run completed cleanly)
  1   precondition failure (not root, active service without --force, etc.)
  2   user cancelled at confirm prompt
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root. Try: sudo $0 $*"
        exit 1
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "prompt: ${prompt} (auto-NO in dry-run)"
        return 1
    fi
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local reply
    read -r -p "  ${prompt} ${hint}: " reply
    reply="${reply:-$default}"
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# Run-or-dry helper: prints what would happen in dry-run; executes in commit.
do_or_dry() {
    local desc="$1"
    shift
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$desc"
    else
        log_info "$desc"
        "$@"
    fi
}

# =============================================================================
# Arg parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    DRY_RUN="true"; shift ;;
            --commit)     DRY_RUN="false"; shift ;;
            --force)      FORCE="true"; shift ;;
            --keep-data)  KEEP_DATA="true"; shift ;;
            --keep-users) KEEP_USERS="true"; shift ;;
            --quiet)      QUIET="true"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

# =============================================================================
# Banner
# =============================================================================

banner() {
    [[ "$QUIET" == "true" ]] && return 0
    echo ""
    echo -e "${YELLOW}    ╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}    ║${NC}  ${BOLD}${YELLOW}Geodineum Uninstaller${NC}                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ║${NC}  ${DIM}symmetric inverse of install.sh (11-phase LIFO)${NC} ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ╚═════════════════════════════════════════════════╝${NC}"
    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}DRY-RUN MODE${NC} — no changes will be made."
    else
        echo -e "  ${RED}COMMIT MODE${NC} — changes WILL be applied."
        echo -e "  ${DIM}(pass --dry-run to preview without changes)${NC}"
    fi
    echo ""
}

# =============================================================================
# Pre-flight checks
# =============================================================================

preflight() {
    log_step "Pre-flight checks"

    # active geodineum units stopped automatically. Pre-fix
    # required --force to proceed; for ops doing repeated install/
    # uninstall cycles this added friction without adding safety.
    local active_units=()
    for unit in "${UNINSTALL_UNITS[@]}"; do
        if /usr/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
            active_units+=("$unit")
        fi
    done

    if [[ ${#active_units[@]} -gt 0 ]]; then
        log_warning "Active geodineum systemd units detected (will be stopped in Phase 1):"
        for u in "${active_units[@]}"; do
            echo -e "    ${YELLOW}●${NC} $u"
        done
    else
        log_success "No active geodineum units detected."
    fi
}

# =============================================================================
# Phase 1: systemd unit disable + stop
# =============================================================================

phase_systemd_stop() {
    log_step "Phase 1/8 — systemd unit disable + stop"

    for unit in "${UNINSTALL_UNITS[@]}"; do
        if /usr/bin/systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
            do_or_dry "systemctl stop ${unit}"   /usr/bin/systemctl stop "$unit" 2>/dev/null || true
            do_or_dry "systemctl disable ${unit}" /usr/bin/systemctl disable "$unit" 2>/dev/null || true
        fi
        # Clear any lingering failed state — stop/disable do NOT reset it, so a
        # unit that died failed would otherwise show as "not-found failed" in
        # systemctl list-units after its file is removed (untidy, confuses the
        # post-uninstall verify). Runs unconditionally (unit may already be
        # removed but still failed in systemd's memory).
        do_or_dry "systemctl reset-failed ${unit}" /usr/bin/systemctl reset-failed "$unit" 2>/dev/null || true
    done
}

# =============================================================================
# Phase 2: systemd unit file removal + daemon-reload
# =============================================================================

phase_systemd_remove() {
    log_step "Phase 3/8 — systemd unit file removal"

    local found_any="false"
    for glob in "${UNIT_FILE_GLOBS[@]}"; do
        # Use /usr/bin/find for absolute-path safety per ABSOLUTE_PATH invariant.
        local matches
        matches=$(/usr/bin/find /etc/systemd/system/ -maxdepth 1 -name "${glob##*/}" -print 2>/dev/null || true)
        while IFS= read -r unit_file; do
            [[ -z "$unit_file" ]] && continue
            do_or_dry "rm ${unit_file}" /usr/bin/rm -f "$unit_file"
            found_any="true"
        done <<<"$matches"
    done

    if [[ "$found_any" == "true" ]]; then
        do_or_dry "systemctl daemon-reload" /usr/bin/systemctl daemon-reload
    else
        log_info "No geodineum unit files found."
    fi
}

# =============================================================================
# Phase 3: ValKey / Redis purge (apt + source-build artifacts)
# =============================================================================
#
# Removes BOTH the apt-installed redis-server / valkey-server packages AND
# the source-built Valkey artifacts the installer drops at /usr/local/bin/
# (added when Ubuntu 22.04 lacks `valkey-server` in apt). Idempotent —
# re-running on a clean state just no-ops every step.
#
# What gets removed:
#   - apt: redis-server, redis-tools, redis, redis-sentinel
#   - apt: valkey-server, valkey-tools, valkey
#   - source-build binaries:
#       /usr/local/bin/valkey-server
#       /usr/local/bin/valkey-cli
#       /usr/local/bin/redis-cli   (compat symlink the installer creates)
#   - source-build systemd unit:
#       /etc/systemd/system/valkey-server.service
#   - config + state dirs:
#       /etc/valkey, /etc/redis
#       /var/lib/valkey, /var/lib/redis  (NB: /var/lib/valkey-gnode is the
#       gNode-managed daemon dir handled separately in phase_valkey_data)
#       /var/log/valkey, /var/log/redis
#       /var/run/redis
#   - the `valkey` system user (created by the source-build path)

phase_valkey_redis_purge() {
    log_step "Phase 2/8 — ValKey / Redis purge"

    local apt_pkgs=(redis-server redis-tools redis redis-sentinel
                    valkey-server valkey-tools valkey)
    local apt_units=(redis-server.service redis-server@.service
                     redis-sentinel.service redis-sentinel@.service
                     valkey-server.service)
    local source_unit="/etc/systemd/system/valkey-server.service"

    # ------ Stop + disable any running instances ------
    for unit in "${apt_units[@]}" valkey-server.service; do
        if /usr/bin/systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
            do_or_dry "systemctl stop ${unit}"    /usr/bin/systemctl stop "$unit" 2>/dev/null || true
            do_or_dry "systemctl disable ${unit}" /usr/bin/systemctl disable "$unit" 2>/dev/null || true
        fi
    done

    # ------ Unmask any unit gNode's install-gnode-service.sh may
    # have masked previously. Without this, mask state survives uninstall
    # and the next install run hits "already masked" → set -e crash.
    # Symmetric uninstall requirement.
    for unit in valkey.service valkey-gnode.service; do
        if /usr/bin/systemctl is-enabled "$unit" 2>/dev/null | grep -q "^masked$"; then
            do_or_dry "systemctl unmask ${unit}" \
                /usr/bin/systemctl unmask "$unit" 2>/dev/null || true
        fi
    done

    # ------ Defensive: kill any orphaned processes whose unit files
    # have already been removed (covers re-running after a previous
    # uninstall that did partial work, or a manual `rm` of unit files
    # leaving the binary running). The binary may have been deleted but
    # Linux keeps the process + its mmap'd binary until pid exits, so
    # the process can keep listening on port 47445 indefinitely.
    #
    # SIGTERM → 2-second grace → SIGKILL escalation. Why not SIGTERM
    # alone: with `appendonly yes` in valkey.conf, valkey catches
    # SIGTERM and tries to flush the AOF file before exit. If the AOF
    # directory (e.g. /var/lib/valkey) was deleted in a prior partial
    # uninstall, the flush blocks forever and SIGTERM never completes.
    # SIGKILL is uncatchable + bypasses the AOF-flush handler so the
    # port + pid are guaranteed to free.
    local _need_kill="false"
    for proc in valkey-server redis-server; do
        if /usr/bin/pgrep -f "^/usr/local/bin/${proc}\b" >/dev/null 2>&1 \
            || /usr/bin/pgrep -x "${proc}" >/dev/null 2>&1; then
            _need_kill="true"
            do_or_dry "pkill -TERM ${proc} (orphaned process holding port)" \
                /usr/bin/pkill -TERM -f "^/usr/local/bin/${proc}\b" 2>/dev/null || true
            do_or_dry "pkill -TERM -x ${proc} (apt-installed catch-all)" \
                /usr/bin/pkill -TERM -x "${proc}" 2>/dev/null || true
        fi
    done

    if [[ "$_need_kill" == "true" ]] && [[ "$DRY_RUN" == "false" ]]; then
        # 2-second grace for clean shutdown — most processes exit here.
        sleep 2
        # Anything still listening on 47445 likely caught SIGTERM and is
        # stuck on a syscall (AOF flush to deleted dir is the typical
        # case). Escalate to SIGKILL.
        for proc in valkey-server redis-server; do
            if /usr/bin/pgrep -f "^/usr/local/bin/${proc}\b" >/dev/null 2>&1 \
                || /usr/bin/pgrep -x "${proc}" >/dev/null 2>&1; then
                log_warning "${proc} ignored SIGTERM after 2s grace — escalating to SIGKILL"
                /usr/bin/pkill -KILL -f "^/usr/local/bin/${proc}\b" 2>/dev/null || true
                /usr/bin/pkill -KILL -x "${proc}" 2>/dev/null || true
            fi
        done
        sleep 1
    fi

    # ------ pre-purge unstick for half-configured packages ------
    # Delegated to lib/component-primitives.sh::ensure_package_purgeable.
    if [[ "$DRY_RUN" != "true" ]]; then
        local pkg
        for pkg in "${apt_pkgs[@]}"; do
            case "$pkg" in
                valkey-server|valkey)
                    ensure_package_purgeable "$pkg" valkey /etc/valkey \
                        /var/lib/valkey "Valkey Server"
                    ;;
                redis-server|redis-tools|redis|redis-sentinel)
                    ensure_package_purgeable "$pkg" redis /etc/redis \
                        /var/lib/redis "Redis Server"
                    ;;
            esac
        done
    fi

    # ------ apt purge — config files, state files, package metadata ------
    # Detection broadened from 'ok installed' (ii only) to any 'i*' state
    # so half-configured/unpacked packages also qualify. Pre-flight above
    # will have moved iF/iU packages to ii or fully removed.
    if /usr/bin/command -v apt-get >/dev/null 2>&1; then
        local installed=()
        for pkg in "${apt_pkgs[@]}"; do
            if /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}\n' "$pkg" 2>/dev/null | grep -qE '^i'; then
                installed+=("$pkg")
            fi
        done
        if [[ ${#installed[@]} -gt 0 ]]; then
            do_or_dry "apt-get purge -y ${installed[*]}" \
                /usr/bin/apt-get purge -y -qq "${installed[@]}" 2>/dev/null || true
        else
            log_info "No apt-installed redis/valkey packages found."
        fi
    fi

    # ------ Clear dpkg-statoverride entries for valkey/redis ------
    # The valkey-server package's postinst registers statoverride records
    # for /var/log/valkey, /var/lib/valkey, etc. These records live in
    # /var/lib/dpkg/statoverride and persist independently of apt purge.
    # After we remove the valkey system user (below) and `rm -rf` the
    # owned dirs, those records become orphaned — they point at a user
    # who no longer exists. The next `apt install` of ANY package then
    # aborts in pre-configure with:
    #
    #   dpkg: unrecoverable fatal error, aborting:
    #    unknown system user 'valkey' in statoverride file; the system
    #    user got removed before the override
    #
    # Worse, a subsequent `apt install valkey-server` succeeds at the
    # archive level but the package gets stuck in half-configured state
    # because postinst's own statoverride calls fail. Symptom on a
    # downstream operator's box: install.sh fails Phase 4 with
    # "/etc/valkey/valkey.conf missing despite installed package".
    #
    # We clear our package's statoverride entries here, while the valkey
    # user still exists (so the --remove call is safe), and BEFORE the
    # `rm -rf` below removes the paths the records reference.
    if /usr/bin/command -v dpkg-statoverride >/dev/null 2>&1; then
        local stale_paths
        stale_paths=$(/usr/bin/dpkg-statoverride --list 2>/dev/null \
            | /usr/bin/awk '($1 == "valkey" || $2 == "valkey" || $1 == "redis" || $2 == "redis" || $NF ~ /^\/(etc|var\/(lib|log|run))\/(valkey|redis)(\/|$)/) {print $NF}')
        if [[ -n "$stale_paths" ]]; then
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                do_or_dry "dpkg-statoverride --remove ${path}" \
                    /usr/bin/dpkg-statoverride --remove "$path" 2>/dev/null || true
            done <<< "$stale_paths"
        fi
    fi

    # ------ Source-build Valkey: binaries + symlink + systemd unit ------
    local source_artifacts=(
        "/usr/local/bin/valkey-server"
        "/usr/local/bin/valkey-cli"
        "/usr/local/bin/redis-cli"
        "$source_unit"
    )
    local removed_unit_file="false"
    for path in "${source_artifacts[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
            do_or_dry "rm ${path}" /usr/bin/rm -f "$path"
            [[ "$path" == "$source_unit" ]] && removed_unit_file="true"
        fi
    done
    if [[ "$removed_unit_file" == "true" ]]; then
        do_or_dry "systemctl daemon-reload" /usr/bin/systemctl daemon-reload
    fi

    # ------ Config + log dirs ------
    # NOTE: /var/lib/valkey (the persistent data dir + relocated aclfile) is
    # intentionally NOT purged here — it's handled by phase_valkey_data
    # (Phase 5), which honors --keep-data and offers a backup snapshot first.
    # Purging it here would ignore --keep-data and delete data unconditionally.
    local data_dirs=(
        "/etc/redis"
        "/var/lib/redis"
        "/var/log/redis"
        "/var/run/redis"
        "/etc/valkey"
        "/var/log/valkey"
        # COMMS per-site SQLite persistence (message log, not
        # precious operator data — ValKey RDB has its own --keep-data
        # phase; this doesn't).
        "/var/lib/geodineum-comms"
    )
    for dir in "${data_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            do_or_dry "rm -rf ${dir}" /usr/bin/rm -rf "$dir"
        fi
    done

    # ------ valkey system user (source-build only — apt path doesn't
    # create one; --keep-users honored as a safety override) ------
    if [[ "$KEEP_USERS" != "true" ]] && /usr/bin/getent passwd valkey >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove 'valkey' system user (source-build artifact)?" y; then
            do_or_dry "userdel valkey" /usr/sbin/userdel valkey 2>/dev/null || true
        fi
    fi

    # ------ apt autoremove orphaned deps (libjemalloc2, lua-bitop, etc.) ------
    if /usr/bin/command -v apt-get >/dev/null 2>&1; then
        do_or_dry "apt-get autoremove -y" /usr/bin/apt-get autoremove -y -qq 2>/dev/null || true
    fi
}

# =============================================================================
# Phase 4: /etc/geodineum/ removal (credentials, bootstrap.env, components)
# =============================================================================

phase_etc_geodineum() {
    log_step "Phase 4/8 — /etc/geodineum/ removal"

    if [[ ! -d /etc/geodineum ]]; then
        log_info "/etc/geodineum/ already absent."
        return 0
    fi

    # Invariant F — secrets-via-file-path. Reference paths only; never cat
    # credential files into logs.
    if [[ -d /etc/geodineum/credentials ]]; then
        local cred_count
        cred_count=$(find /etc/geodineum/credentials -type f 2>/dev/null | wc -l)
        log_info "Credential files present at /etc/geodineum/credentials/ (${cred_count} files)"
        log_info "  (paths only — contents NOT logged per file-secrets invariant)"
    fi

    if [[ "$KEEP_DATA" == "true" ]]; then
        log_info "--keep-data: preserving /etc/geodineum/credentials/"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "rm /etc/geodineum/* (keep credentials/)"
        else
            log_info "rm /etc/geodineum/* (keep credentials/)"
            find /etc/geodineum -mindepth 1 -maxdepth 1 -not -name credentials -exec /usr/bin/rm -rf {} +
        fi
    else
        do_or_dry "rm -rf /etc/geodineum/" /usr/bin/rm -rf /etc/geodineum/
    fi
}

# =============================================================================
# Phase 5: /var/lib/valkey (with backup-snapshot prompt)
# =============================================================================

phase_valkey_data() {
    log_step "Phase 5/8 — /var/lib/valkey (data)"

    # the data dir is /var/lib/valkey (valkey.conf `dir` + the relocated
    # aclfile). Previously, this targeted a non-existent /var/lib/valkey-gnode, so
    # --keep-data was a no-op and Phase 2 deleted the real data unconditionally.
    local data_dir="/var/lib/valkey"
    if [[ ! -d "$data_dir" ]]; then
        log_info "${data_dir} already absent."
        return 0
    fi

    if [[ "$KEEP_DATA" == "true" ]]; then
        log_info "--keep-data passed — preserving ${data_dir}"
        return 0
    fi

    # Always offer backup-snapshot-first per primer SAFETY directive.
    log_warning "About to delete ValKey persistent data at ${data_dir}"
    local sz
    sz=$(/usr/bin/du -sh "$data_dir" 2>/dev/null | /usr/bin/awk '{print $1}' || echo "unknown")
    log_info "Approximate size: ${sz}"

    if [[ "$DRY_RUN" == "false" ]] && confirm "Snapshot ${data_dir} to /var/backups/valkey-uninstall-$(/usr/bin/date +%Y%m%d-%H%M%S).tar.gz first?" y; then
        local snapshot="/var/backups/valkey-uninstall-$(/usr/bin/date +%Y%m%d-%H%M%S).tar.gz"
        /usr/bin/mkdir -p /var/backups
        /usr/bin/tar -czf "$snapshot" -C / "var/lib/valkey" 2>/dev/null || {
            log_error "Snapshot failed — aborting. ${data_dir} preserved."
            exit 1
        }
        log_success "Snapshot saved: ${snapshot}"
    fi

    if [[ "$DRY_RUN" == "true" ]] || confirm "Proceed with ${data_dir} deletion?"; then
        do_or_dry "rm -rf ${data_dir}" /usr/bin/rm -rf "$data_dir"
    else
        log_info "Skipped ${data_dir} deletion (operator declined)."
    fi
}

# =============================================================================
# Phase 5: /opt/geodineum/ (operator-confirmed; contains all components)
# =============================================================================

phase_opt_geodineum() {
    log_step "Phase 6/8 — /opt/geodineum/ (component installs)"

    local install_root="/opt/geodineum"
    if [[ ! -d "$install_root" ]]; then
        log_info "${install_root} already absent."
        return 0
    fi

    log_warning "About to delete component install root at ${install_root}"
    log_info "  (contains: Geodineum, gCore, gTemplate, gNode, gNode-Client, COMMS, BAK, ...)"

    # detect dedicated mount. Operators frequently mount /opt/geodineum
    # on its own partition (LVM logical volume, ZFS dataset, separate disk)
    # to isolate component code from / and apply different fs options
    # (noatime, quota, etc.). In that case `rm -rf /opt/geodineum` either
    # fails (busy mount) or — worse — succeeds at removing the mount-point
    # directory while the kernel keeps the mount live but orphaned. The
    # right inverse is to empty the mount, not unmount it; the operator
    # owns the partition itself.
    local is_mountpoint=false
    if /usr/bin/mountpoint -q "$install_root" 2>/dev/null; then
        is_mountpoint=true
        log_info "${install_root} is a dedicated mount — will empty contents, not remove dir"
    fi

    if [[ "$DRY_RUN" == "true" ]] || confirm "Proceed with ${install_root} deletion?"; then
        if [[ "$is_mountpoint" == "true" ]]; then
            # -mindepth 1 protects the mount point; -xdev keeps us inside
            # this filesystem only (skips any nested bind-mounts the
            # operator may have set up under /opt/geodineum/).
            do_or_dry "find ${install_root} -mindepth 1 -xdev -delete" \
                /usr/bin/find "$install_root" -mindepth 1 -xdev -delete
        else
            do_or_dry "rm -rf ${install_root}" /usr/bin/rm -rf "$install_root"
        fi
    else
        log_info "Skipped ${install_root} deletion (operator declined)."
    fi

    # Sweep CLI symlinks (created by install.sh post-Phase-N).
    for sym in /usr/local/bin/geodineum /usr/local/bin/gcli; do
        if [[ -L "$sym" || -f "$sym" ]]; then
            do_or_dry "rm ${sym}" /usr/bin/rm -f "$sym"
        fi
    done

    # Sweep bootstrap-loader.sh (Tier-1 1.14.f / 1.14.g).
    if [[ -d /usr/local/lib/geodineum ]]; then
        do_or_dry "rm -rf /usr/local/lib/geodineum/" /usr/bin/rm -rf /usr/local/lib/geodineum/
    fi
}

# =============================================================================
# Phase 6: /etc/sudoers.d/geodineum drop-in
# =============================================================================

phase_sudoers() {
    log_step "Phase 7/8 — sudoers drop-in removal"

    # install.sh Phase 8 writes /etc/sudoers.d/geodineum-deploy (rendered
    # from templates/sudoers-geodeploy.tpl). Older runs may have left
    # /etc/sudoers.d/geodineum too. Remove both.
    for drop_in in \
        "/etc/sudoers.d/geodineum-deploy" \
        "/etc/sudoers.d/geodineum"; do
        if [[ -f "$drop_in" ]]; then
            do_or_dry "rm ${drop_in}" /usr/bin/rm -f "$drop_in"
        else
            log_info "${drop_in} already absent."
        fi
    done
}

# =============================================================================
# Phase 7b: geodeploy auto-deploy cron entry 
# =============================================================================
phase_geodeploy_cron() {
    log_step "Phase 7b/8 — geodeploy auto-deploy cron"

    local deploy_user=""
    if [[ -r /etc/geodineum/deploy.env ]]; then
        deploy_user=$(/usr/bin/awk -F= '/^DEPLOY_USER=/{print $2}' /etc/geodineum/deploy.env)
    fi

    local cleaned=0
    while IFS=: read -r u _ _ _ _ _ _; do
        [[ "$u" == "root" || "$u" == "$deploy_user" ]] || continue
        if /usr/bin/crontab -u "$u" -l 2>/dev/null \
                | /usr/bin/grep -q "geodeploy-orchestrator\|auto-deploy\.sh"; then
            log_info "Removing geodeploy cron for user '${u}'"
            do_or_dry "crontab -u ${u} (filter geodeploy-orchestrator)" \
                bash -c "/usr/bin/crontab -u '$u' -l 2>/dev/null \
                    | /usr/bin/grep -v 'geodeploy-orchestrator\|auto-deploy\\.sh' \
                    | /usr/bin/crontab -u '$u' -" || true
            cleaned=$((cleaned + 1))
        fi
    done < <(/usr/bin/getent passwd)

    if [[ "$cleaned" -eq 0 ]]; then
        log_info "No geodeploy cron entries found."
    fi

    for crond_file in /etc/cron.d/geodeploy /etc/cron.d/geodineum-auto-deploy; do
        if [[ -f "$crond_file" ]]; then
            do_or_dry "rm ${crond_file}" /usr/bin/rm -f "$crond_file"
        fi
    done
}

# =============================================================================
# Phase 7: geodineum group + service users (operator-confirmed)
# =============================================================================

phase_users_group() {
    log_step "Phase 8/8 — geodineum group + service users"

    if [[ "$KEEP_USERS" == "true" ]]; then
        log_info "--keep-users passed — preserving geodineum group + service users."
        return 0
    fi

    # Service users created by install.sh: gnode (Phase 0 deploy_user pattern).
    # deploy_user is variable per install — read from /etc/passwd by GID match
    # before geodineum group is removed.
    local gnode_uid=""
    if /usr/bin/getent passwd gnode >/dev/null 2>&1; then
        gnode_uid=$(/usr/bin/getent passwd gnode | /usr/bin/awk -F: '{print $3}')
    fi

    if [[ -n "$gnode_uid" ]]; then
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove service user 'gnode' (uid=${gnode_uid})?" n; then
            do_or_dry "userdel gnode" /usr/sbin/userdel gnode 2>/dev/null || true
        fi
    fi

    # Dedicated COMMS service user (created by install.sh
    # alongside the narrow groups).
    if /usr/bin/getent passwd geodineum-comms >/dev/null 2>&1; then
        local comms_uid
        comms_uid=$(/usr/bin/getent passwd geodineum-comms | /usr/bin/awk -F: '{print $3}')
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove service user 'geodineum-comms' (uid=${comms_uid})?" n; then
            do_or_dry "userdel geodineum-comms" /usr/sbin/userdel geodineum-comms 2>/dev/null || true
        fi
    fi

    # Ecosystem groups (narrow-group hardening).
    # Order matters: remove narrowest first, broadest last. Empty groups
    # are auto-deleted; groups with remaining members are preserved with
    # an info note (manual gpasswd -d to vacate).
    #
    # Narrow web/client groups:
    #   geodineum-web    — Apache-readable WP stack (themes + gCore)
    #   geodineum-client — gNode-Client PHP library readers
    # COMMS group:
    #   geodineum-comms  — COMMS daemon runtime identity (cred reads)
    for grp in geodineum-comms geodineum-web geodineum-client geodineum-bootstrap geodineum-dash geodineum-creds geodineum; do
        if /usr/bin/getent group "$grp" >/dev/null 2>&1; then
            local members
            members=$(/usr/bin/getent group "$grp" | /usr/bin/awk -F: '{print $4}')
            if [[ -z "$members" ]]; then
                if [[ "$DRY_RUN" == "true" ]] || confirm "Remove empty group '${grp}'?" y; then
                    do_or_dry "groupdel ${grp}" /usr/sbin/groupdel "$grp" 2>/dev/null || true
                fi
            else
                log_warning "Group '${grp}' still has members: ${members}"
                log_info "  (preserved — manually clean with: gpasswd -d <user> ${grp})"
            fi
        fi
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    [[ "$QUIET" == "true" ]] && return 0
    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║${NC}          ${BOLD}Dry-Run Complete${NC}                          ${YELLOW}║${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  Re-run without ${BOLD}--dry-run${NC} to apply changes."
    else
        echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║${NC}          ${BOLD}Uninstall Complete${NC}                        ${GREEN}║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  Geodineum has been removed from this system."
        echo "  Pre-existing co-located files NOT in the install manifest"
        echo "  have been preserved."
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    require_root "$@"
    banner
    preflight
    phase_systemd_stop
    phase_valkey_redis_purge
    phase_systemd_remove
    # Cron removal must run BEFORE phase_etc_geodineum deletes
    # /etc/geodineum/deploy.env — that's how we identify whose
    # crontab to filter without scanning every user on the system.
    phase_geodeploy_cron
    phase_etc_geodineum
    phase_valkey_data
    phase_opt_geodineum
    phase_sudoers
    phase_users_group
    print_summary
}

main "$@"

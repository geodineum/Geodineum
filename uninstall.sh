#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# Geodineum Uninstall Script
# =============================================================================
# Removes what install.sh created, in reverse order. Deletes by default
# (--dry-run previews) and is safe to re-run on a partly uninstalled host.
# Credential files are referenced by path only, never printed.
#
# Usage:
#   sudo ./uninstall.sh [--dry-run] [--keep-data] [--keep-users] [--quiet]
#
# Examples:
#   sudo ./uninstall.sh --dry-run      # preview
#   sudo ./uninstall.sh                # delete (with prompts)
#   sudo ./uninstall.sh --quiet --keep-data
#                                      # unattended, keeping ValKey data
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
KEEP_DATA="false"     # preserve /var/lib/valkey-gnode
KEEP_USERS="false"    # preserve geodineum group + service users

INSTALLER_PATHS=(
    "/usr/local/bin/geodineum"
    "/usr/local/bin/gcli"
    "/usr/local/lib/geodineum"
    "/etc/geodineum"
    "/var/log/geodineum"
)

MANIFEST_PATH="/etc/geodineum/installed.manifest"

# Timers before the services they trigger.
UNINSTALL_UNITS=(
    "valkey-backup.timer"
    "valkey-backup.service"
    "geodineum-comms.service"
    "gnode-daemon.service"
    "valkey-gnode.service"
)

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
  -h, --help       This message.

Safety:
  Default mode is COMMIT (actually delete). Pass --dry-run to preview only.
  Active geodineum systemd units are stopped automatically.
  Always prompts before deleting /var/lib/valkey-gnode unless --keep-data.

Exit codes:
  0   success (or dry-run completed cleanly)
  1   precondition failure (not root, etc.)
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
        # stop/disable keep a failed state; clear it even if the file is gone.
        do_or_dry "systemctl reset-failed ${unit}" /usr/bin/systemctl reset-failed "$unit" 2>/dev/null || true
    done
}

# =============================================================================
# Phase 3: systemd unit file removal + daemon-reload
# =============================================================================

phase_systemd_remove() {
    log_step "Phase 3/8 — systemd unit file removal"

    local found_any="false"
    for glob in "${UNIT_FILE_GLOBS[@]}"; do
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
# Phase 2: ValKey / Redis purge (apt + source-build artifacts)
# =============================================================================
# Runs before unit-file removal so systemctl can still resolve the units.

phase_valkey_redis_purge() {
    log_step "Phase 2/8 — ValKey / Redis purge"

    local apt_pkgs=(redis-server redis-tools redis redis-sentinel
                    valkey-server valkey-tools valkey)
    local apt_units=(redis-server.service redis-server@.service
                     redis-sentinel.service redis-sentinel@.service
                     valkey-server.service)
    local source_unit="/etc/systemd/system/valkey-server.service"

    for unit in "${apt_units[@]}" valkey-server.service; do
        if /usr/bin/systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
            do_or_dry "systemctl stop ${unit}"    /usr/bin/systemctl stop "$unit" 2>/dev/null || true
            do_or_dry "systemctl disable ${unit}" /usr/bin/systemctl disable "$unit" 2>/dev/null || true
        fi
    done

    # A mask left by gNode's service install would survive into the next install.
    for unit in valkey.service valkey-gnode.service; do
        if /usr/bin/systemctl is-enabled "$unit" 2>/dev/null | grep -q "^masked$"; then
            do_or_dry "systemctl unmask ${unit}" \
                /usr/bin/systemctl unmask "$unit" 2>/dev/null || true
        fi
    done

    # Orphaned processes whose unit files are gone. SIGKILL follows SIGTERM:
    # an AOF flush into an already-deleted data dir blocks shutdown forever.
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
        sleep 2
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

    # Half-configured packages must be unstuck before apt can purge them.
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

    # Any 'i*' dpkg state counts as installed, not only 'ii'.
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

    # Clear valkey/redis statoverrides while the valkey user still exists: an
    # override naming a deleted user makes every later apt install abort.
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

    # /var/lib/valkey is left to phase_valkey_data, which honours --keep-data.
    local data_dirs=(
        "/etc/redis"
        "/var/lib/redis"
        "/var/log/redis"
        "/var/run/redis"
        "/etc/valkey"
        "/var/log/valkey"
        "/var/lib/geodineum-comms"
    )
    for dir in "${data_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            do_or_dry "rm -rf ${dir}" /usr/bin/rm -rf "$dir"
        fi
    done

    if [[ "$KEEP_USERS" != "true" ]] && /usr/bin/getent passwd valkey >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove 'valkey' system user (source-build artifact)?" y; then
            do_or_dry "userdel valkey" /usr/sbin/userdel valkey 2>/dev/null || true
        fi
    fi

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

    # valkey.conf `dir`, which also holds the aclfile
    local data_dir="/var/lib/valkey"
    if [[ ! -d "$data_dir" ]]; then
        log_info "${data_dir} already absent."
        return 0
    fi

    if [[ "$KEEP_DATA" == "true" ]]; then
        log_info "--keep-data passed — preserving ${data_dir}"
        return 0
    fi

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
# Phase 6: /opt/geodineum/ (operator-confirmed; contains all components)
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

    # A dedicated mount is emptied, not removed: the operator owns the partition.
    local is_mountpoint=false
    if /usr/bin/mountpoint -q "$install_root" 2>/dev/null; then
        is_mountpoint=true
        log_info "${install_root} is a dedicated mount — will empty contents, not remove dir"
    fi

    if [[ "$DRY_RUN" == "true" ]] || confirm "Proceed with ${install_root} deletion?"; then
        if [[ "$is_mountpoint" == "true" ]]; then
            # -xdev skips nested mounts under the install root
            do_or_dry "find ${install_root} -mindepth 1 -xdev -delete" \
                /usr/bin/find "$install_root" -mindepth 1 -xdev -delete
        else
            do_or_dry "rm -rf ${install_root}" /usr/bin/rm -rf "$install_root"
        fi
    else
        log_info "Skipped ${install_root} deletion (operator declined)."
    fi

    for sym in /usr/local/bin/geodineum /usr/local/bin/gcli; do
        if [[ -L "$sym" || -f "$sym" ]]; then
            do_or_dry "rm ${sym}" /usr/bin/rm -f "$sym"
        fi
    done

    if [[ -d /usr/local/lib/geodineum ]]; then
        do_or_dry "rm -rf /usr/local/lib/geodineum/" /usr/bin/rm -rf /usr/local/lib/geodineum/
    fi
}

# =============================================================================
# Phase 7: /etc/sudoers.d drop-ins
# =============================================================================

phase_sudoers() {
    log_step "Phase 7/8 — sudoers drop-in removal"

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
# Phase 8: geodineum group + service users (operator-confirmed)
# =============================================================================

phase_users_group() {
    log_step "Phase 8/8 — geodineum group + service users"

    if [[ "$KEEP_USERS" == "true" ]]; then
        log_info "--keep-users passed — preserving geodineum group + service users."
        return 0
    fi

    local gnode_uid=""
    if /usr/bin/getent passwd gnode >/dev/null 2>&1; then
        gnode_uid=$(/usr/bin/getent passwd gnode | /usr/bin/awk -F: '{print $3}')
    fi

    if [[ -n "$gnode_uid" ]]; then
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove service user 'gnode' (uid=${gnode_uid})?" n; then
            do_or_dry "userdel gnode" /usr/sbin/userdel gnode 2>/dev/null || true
        fi
    fi

    if /usr/bin/getent passwd geodineum-comms >/dev/null 2>&1; then
        local comms_uid
        comms_uid=$(/usr/bin/getent passwd geodineum-comms | /usr/bin/awk -F: '{print $3}')
        if [[ "$DRY_RUN" == "true" ]] || confirm "Remove service user 'geodineum-comms' (uid=${comms_uid})?" n; then
            do_or_dry "userdel geodineum-comms" /usr/sbin/userdel geodineum-comms 2>/dev/null || true
        fi
    fi

    # Narrowest first, broadest last; a group that still has members is kept.
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
    # Before phase_etc_geodineum: deploy.env names the user whose crontab to filter.
    phase_geodeploy_cron
    phase_etc_geodineum
    phase_valkey_data
    phase_opt_geodineum
    phase_sudoers
    phase_users_group
    print_summary
}

main "$@"

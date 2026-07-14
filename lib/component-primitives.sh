#!/usr/bin/env bash
# =============================================================================
# component-primitives.sh — installer/uninstaller reusable primitives
# =============================================================================
#
# harvested from the installer's valkey-specific recovery helpers. Same
# shape applies to any system-daemon component that's installed via apt
# (or a similar package manager) and registers system user(s), data dirs,
# and conffiles. Future components — additional gNode extensions, gCore
# pro managers, standalone daemons — wire through these instead of
# carrying per-component branches in install.sh.
#
# Sourced by install.sh and uninstall.sh in both Geodineum and
# Geodineum-pro. Keep the API surface small and stable; let real usage
# from the next 2-3 components shape any extensions.
#
# Logging contract: callers provide log_info, log_warning, log_error,
# log_success, log_step. log_detail is optional; this file installs a
# fallback below if the caller hasn't defined one.
# =============================================================================

# Avoid sourcing twice — guard against multiple `source` calls.
if [[ "${_GEODINEUM_COMPONENT_PRIMITIVES_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_GEODINEUM_COMPONENT_PRIMITIVES_LOADED=1

# Fallback for log_detail — uninstall.sh doesn't define it, install.sh does.
if ! declare -F log_detail >/dev/null 2>&1; then
    log_detail() { log_info "  $1"; }
fi

# ─── Primitive 1 ─────────────────────────────────────────────────────────
# Clear orphaned dpkg-statoverride records — entries that reference a
# system user/group which no longer exists on this host. Without this,
# every subsequent `apt install` of ANY package aborts in pre-configure
# with "unknown system user 'X' in statoverride file".
#
# Idempotent: only clears records whose principal is genuinely missing.
# Skips cleanup entirely if the principal still exists (which means the
# records are still valid).
#
# Arguments: 1+ principal names (users or groups). Both ownership fields
# of each statoverride record are checked.
#
# Returns: number of records cleared is reported via log_info; function
# exits 0 either way.
#
# Example:
#   clear_orphaned_statoverrides valkey redis
clear_orphaned_statoverrides() {
    /usr/bin/command -v dpkg-statoverride >/dev/null 2>&1 || return 0

    local principal cleared=0
    for principal in "$@"; do
        # If the principal exists, its records are not orphaned.
        if /usr/bin/getent passwd "$principal" >/dev/null 2>&1 \
                || /usr/bin/getent group "$principal" >/dev/null 2>&1; then
            continue
        fi

        local user group _mode path
        while IFS=' ' read -r user group _mode path; do
            [[ -z "$path" ]] && continue
            if [[ "$user" == "$principal" || "$group" == "$principal" ]]; then
                /usr/bin/dpkg-statoverride --remove "$path" 2>/dev/null \
                    && { log_detail "Cleared orphaned statoverride: ${path} (was ${user}:${group})"; cleared=$((cleared + 1)); }
            fi
        done < <(/usr/bin/dpkg-statoverride --list 2>/dev/null)
    done

    (( cleared > 0 )) && log_info "Removed ${cleared} orphaned dpkg-statoverride record(s)"
    return 0
}

# ─── Primitive 2 ─────────────────────────────────────────────────────────
# Create a system user idempotently. Same shape as Debian preinst's
# adduser invocation — a manually-created user is indistinguishable from
# one created by the package maintainer's preinst script.
#
# Use when:
#   - A package's preinst would normally create this user but didn't run
#     (e.g. recovery after a half-purged state).
#   - A component without an apt package needs a dedicated system user
#     for systemd's User= directive.
#
# Arguments:
#   $1  username (required)
#   $2  home directory (required — used by --home, no actual dir created)
#   $3  GECOS string (display name shown by `getent passwd`)
#   $4  shell (optional, default: /bin/false)
#
# Returns 0 on success or if user already exists. 1 if adduser failed.
ensure_system_user() {
    local username="$1" home="$2" gecos="$3" shell="${4:-/bin/false}"
    if /usr/bin/getent passwd "$username" >/dev/null 2>&1; then
        return 0
    fi
    log_info "Creating '${username}' system user"
    /usr/sbin/adduser --system --quiet \
        --home "$home" --no-create-home \
        --shell "$shell" --group --gecos "$gecos" \
        "$username" 2>/dev/null || {
            log_warning "adduser failed for '${username}'"
            return 1
        }
    return 0
}

# ─── Primitive 3 ─────────────────────────────────────────────────────────
# Create data directories with consistent ownership/mode. Idempotent: dirs
# that already exist are left alone (ownership not re-asserted — use a
# dedicated permission-fix step if that's needed).
#
# Use for /var/lib/<component>, /var/log/<component>, etc. The owner must
# exist before this is called (ensure_system_user first).
#
# Arguments:
#   $1  owner user (required, must exist)
#   $2  group (required, must exist)
#   $3  mode (e.g. 0750)
#   $4+ directory paths
#
# Returns 0 normally, 1 if owner doesn't exist.
ensure_data_dirs() {
    local owner="$1" group="$2" mode="$3"
    shift 3
    if ! /usr/bin/getent passwd "$owner" >/dev/null 2>&1; then
        log_warning "Owner '${owner}' does not exist — skipping data-dir creation"
        return 1
    fi
    local d
    for d in "$@"; do
        if [[ ! -d "$d" ]]; then
            /usr/bin/install -d -o "$owner" -g "$group" -m "$mode" "$d"
            log_detail "Created ${d} (owner ${owner}:${group} ${mode})"
        fi
    done
}

# ─── Primitive 4 ─────────────────────────────────────────────────────────
# Recover a half-configured (iF) or unpacked-but-not-configured (iU) apt
# package. Without recovery, dpkg keeps re-attempting the broken configure
# step on every apt call, cascading-fail every apt operation on the host.
#
# Two layers handled:
#
#   1. Missing /etc/<pkg>/ directory. Many packages' postinst run
#      `find /etc/<pkg> ...`. If the dir was rm -rf'd, find exits 1,
#      postinst aborts, package stays 'iF'. Fix: create the empty dir
#      before `dpkg --configure -a`.
#
#   2. Missing conffile. dpkg marks conffiles as obsolete after manual
#      deletion and refuses to re-extract on plain reinstall/configure.
#      After `--configure -a` succeeds, if the conffile is still absent,
#      escalate to `apt install --reinstall -o Dpkg::Options::=--force-confmiss`.
#
# Arguments:
#   $1  package name
#   $2  conffile parent dir (e.g. /etc/valkey) — pass "" to skip Layer 1
#   $3  expected conffile path (e.g. /etc/valkey/valkey.conf) — pass "" to skip Layer 2
#
# Returns 0 if package is now in a configured state (or wasn't broken),
# 1 if recovery couldn't unstick it.
ensure_package_configured() {
    local pkg="$1" conf_dir="${2:-}" conf_file="${3:-}"
    local pkg_status

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")

    # 'iF' = wanted=install, status=half-configured
    # 'iU' = wanted=install, status=unpacked (config not yet attempted)
    if [[ ! "$pkg_status" =~ ^i[FU] ]]; then
        return 0
    fi

    log_info "${pkg} in ${pkg_status} state — completing configure"

    # Layer 1: ensure conffile parent dir exists.
    if [[ -n "$conf_dir" && ! -d "$conf_dir" ]]; then
        /usr/bin/install -d -m 0755 "$conf_dir"
        log_detail "Created ${conf_dir} (missing — required by postinst's find)"
    fi

    /usr/bin/dpkg --configure -a 2>&1 | /usr/bin/grep -vE '^$|deb-systemd-invoke' || true

    # Layer 2: force conffile re-extraction if still absent.
    if [[ -n "$conf_file" && ! -f "$conf_file" ]]; then
        log_info "${conf_file} still missing — forcing re-extraction (--force-confmiss)"
        /usr/bin/apt-get install --reinstall -y -qq \
            -o Dpkg::Options::="--force-confmiss" "$pkg" 2>&1 \
            | /usr/bin/grep -vE '^$|deb-systemd-invoke' || true

        if [[ -f "$conf_file" ]]; then
            log_success "Restored ${conf_file} via --force-confmiss"
        else
            log_warning "${conf_file} could not be restored automatically"
            log_info "Manual recovery: sudo apt-get purge -y ${pkg} && sudo apt-get install -y ${pkg}"
        fi
    fi

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")
    if [[ "$pkg_status" =~ ^i[FU] ]]; then
        log_warning "${pkg} still in ${pkg_status} state after recovery attempt"
        return 1
    fi
    return 0
}

# ─── Primitive 5 ─────────────────────────────────────────────────────────
# Force a half-configured (iF/iU) package into a state where `apt-get
# purge` can complete. Counterpart to ensure_package_configured but used
# by uninstall.sh — for uninstall we'd rather drop the package than fix
# it, so the fallback is `dpkg --purge --force-all` instead of
# --force-confmiss reinstall.
#
# Without this, `apt purge` on an iF package can fail because purge runs
# postrm, which may break for the same reasons configure failed (missing
# user, missing dir).
#
# Arguments:
#   $1  package name
#   $2  username the package's maintainer scripts expect (pass "" to skip)
#   $3  conffile parent dir for postrm find (pass "" to skip)
#   $4  user home dir (used if username needs to be created)
#   $5  user GECOS (used if username needs to be created)
#
# Returns 0 once the package is no longer in iF/iU, even if that was
# achieved via force-purge.
ensure_package_purgeable() {
    local pkg="$1" username="${2:-}" conf_dir="${3:-}" home="${4:-}" gecos="${5:-}"
    local pkg_status

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")
    [[ "$pkg_status" =~ ^i[FU] ]] || return 0

    log_info "${pkg} is in '${pkg_status}' state — preparing for clean purge"

    # Restore postrm prerequisites if they're missing.
    if [[ -n "$username" ]] && ! /usr/bin/getent passwd "$username" >/dev/null 2>&1; then
        ensure_system_user "$username" "${home:-/nonexistent}" "${gecos:-${username} service}" \
            2>/dev/null || true
    fi
    if [[ -n "$conf_dir" && ! -d "$conf_dir" ]]; then
        /usr/bin/install -d -m 0755 "$conf_dir"
    fi

    # Best-effort clean configure first.
    /usr/bin/dpkg --configure -a 2>/dev/null || true

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")
    if [[ "$pkg_status" =~ ^i[FU] ]]; then
        log_warning "${pkg} still '${pkg_status}' — force-purging via dpkg"
        /usr/bin/dpkg --purge --force-all "$pkg" 2>/dev/null || true
    fi
}

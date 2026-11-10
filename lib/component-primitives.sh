#!/usr/bin/env bash
# =============================================================================
# component-primitives.sh — recovery helpers for apt-installed system daemons
# =============================================================================
# Sourced by install.sh and uninstall.sh; callers provide log_info, log_warning, log_error, log_success.

if [[ "${_GEODINEUM_COMPONENT_PRIMITIVES_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
_GEODINEUM_COMPONENT_PRIMITIVES_LOADED=1

if ! declare -F log_detail >/dev/null 2>&1; then
    log_detail() { log_info "  $1"; }
fi

# Usage: clear_orphaned_statoverrides <user|group>...; a record naming a missing principal makes every apt install abort.
clear_orphaned_statoverrides() {
    /usr/bin/command -v dpkg-statoverride >/dev/null 2>&1 || return 0

    local principal cleared=0
    for principal in "$@"; do
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

# Usage: ensure_system_user <name> <home (not created)> <gecos> [shell]; same shape as a Debian preinst adduser.
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

# Usage: ensure_data_dirs <owner> <group> <mode> <dir>...; existing dirs are left as they are.
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

# Usage: ensure_package_configured <pkg> [conf_dir] [conf_file]; completes an iF/iU package, which otherwise breaks every apt call.
ensure_package_configured() {
    local pkg="$1" conf_dir="${2:-}" conf_file="${3:-}"
    local pkg_status

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")

    if [[ ! "$pkg_status" =~ ^i[FU] ]]; then
        return 0
    fi

    log_info "${pkg} in ${pkg_status} state — completing configure"

    # Many postinst scripts run `find /etc/<pkg>`, which fails when the dir is gone.
    if [[ -n "$conf_dir" && ! -d "$conf_dir" ]]; then
        /usr/bin/install -d -m 0755 "$conf_dir"
        log_detail "Created ${conf_dir} (missing — required by postinst's find)"
    fi

    /usr/bin/dpkg --configure -a 2>&1 | /usr/bin/grep -vE '^$|deb-systemd-invoke' || true

    # dpkg will not re-extract a deleted conffile without --force-confmiss.
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

# Usage: ensure_package_purgeable <pkg> [user] [conf_dir] [home] [gecos]; restores what postrm needs, else force-purges.
ensure_package_purgeable() {
    local pkg="$1" username="${2:-}" conf_dir="${3:-}" home="${4:-}" gecos="${5:-}"
    local pkg_status

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")
    [[ "$pkg_status" =~ ^i[FU] ]] || return 0

    log_info "${pkg} is in '${pkg_status}' state — preparing for clean purge"

    if [[ -n "$username" ]] && ! /usr/bin/getent passwd "$username" >/dev/null 2>&1; then
        ensure_system_user "$username" "${home:-/nonexistent}" "${gecos:-${username} service}" \
            2>/dev/null || true
    fi
    if [[ -n "$conf_dir" && ! -d "$conf_dir" ]]; then
        /usr/bin/install -d -m 0755 "$conf_dir"
    fi

    /usr/bin/dpkg --configure -a 2>/dev/null || true

    pkg_status=$(/usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || echo "")
    if [[ "$pkg_status" =~ ^i[FU] ]]; then
        log_warning "${pkg} still '${pkg_status}' — force-purging via dpkg"
        /usr/bin/dpkg --purge --force-all "$pkg" 2>/dev/null || true
    fi
}

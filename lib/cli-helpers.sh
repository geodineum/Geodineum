#!/bin/bash
# =============================================================================
# cli-helpers.sh — helpers for manifest-declared CLI handler scripts (cli.commands[].handler)
# =============================================================================
# Usage: source "${GEODINEUM_LIB:-/usr/local/lib/geodineum}/cli-helpers.sh"  (also loads common.sh)
# =============================================================================

[[ -n "${_GEODINEUM_CLI_HELPERS_SH:-}" ]] && return 0
_GEODINEUM_CLI_HELPERS_SH=1

_cli_helpers_find_lib_dir() {
    local p
    for p in \
        "${GEODINEUM_LIB:-/usr/local/lib/geodineum}" \
        "${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib" \
        "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; do
        if [[ -n "$p" && -f "$p/common.sh" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

_GD_LIB="$(_cli_helpers_find_lib_dir)" || {
    echo "ERROR: cli-helpers.sh: cannot find common.sh on the conventional search path" >&2
    return 1
}

# shellcheck source=common.sh
source "$_GD_LIB/common.sh"

if [[ -f "$_GD_LIB/manifest-registry.sh" ]]; then
    # shellcheck source=manifest-registry.sh
    source "$_GD_LIB/manifest-registry.sh"
fi

# =============================================================================
# ValKey wrappers, one per user class
# =============================================================================

# Admin user: required for ACL commands, which gnode_daemon (-@dangerous) cannot run.
valkey_admin_cli() {
    local pw_file="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"
    if [[ ! -r "$pw_file" ]]; then
        log_error "Admin password not readable: $pw_file"
        log_info "  (run as root, or join group geodineum-creds)"
        return 1
    fi
    REDISCLI_AUTH="$(cat "$pw_file")" valkey-cli -p "${VALKEY_PORT:-47445}" --no-auth-warning "$@"
}

valkey_daemon_cli() {
    local pw_file="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey_daemon.password"
    if [[ ! -r "$pw_file" ]]; then
        log_error "Daemon password not readable: $pw_file"
        log_info "  (run as root or gnode user, or as a member of geodineum-creds)"
        return 1
    fi
    REDISCLI_AUTH="$(cat "$pw_file")" valkey-cli -p "${VALKEY_PORT:-47445}" --user gnode_daemon --no-auth-warning "$@"
}

# Usage: valkey_client_cli <site_id> <args...>
valkey_client_cli() {
    local site_id="$1"; shift
    if [[ -z "$site_id" ]]; then
        log_error "valkey_client_cli: site_id required"
        return 2
    fi
    local pw_file="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey_client_${site_id}.password"
    if [[ ! -r "$pw_file" ]]; then
        log_error "Client password not readable: $pw_file"
        return 1
    fi
    REDISCLI_AUTH="$(cat "$pw_file")" valkey-cli -p "${VALKEY_PORT:-47445}" --user "gnode_client_${site_id}" --no-auth-warning "$@"
}

# =============================================================================
# Manifest registry lookup
# =============================================================================

# Usage: registry_field <service-name> <field>
registry_field() {
    local svc="$1" field="$2"
    [[ -n "$svc" && -n "$field" ]] || return 2
    if declare -F manifest_get_field >/dev/null 2>&1; then
        manifest_get_field "$svc" "$field"
    else
        return 1
    fi
}

registry_has() {
    local svc="$1"
    [[ -n "$svc" ]] || return 2
    if declare -F manifest_list_registered >/dev/null 2>&1; then
        manifest_list_registered 2>/dev/null | /usr/bin/grep -Fxq "$svc"
    else
        return 1
    fi
}

# =============================================================================
# Site-id resolution
# =============================================================================

resolve_site_id_from_domain() {
    local domain="$1"
    [[ -n "$domain" ]] || return 1
    echo "$domain" | sed 's/\./_/g'
}

# site_id from the argument, else $GEODINEUM_SITE_ID, else a $PWD under /var/www/<domain>.
resolve_site_id() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return 0
    fi
    if [[ -n "${GEODINEUM_SITE_ID:-}" ]]; then
        echo "$GEODINEUM_SITE_ID"
        return 0
    fi
    if [[ "$PWD" =~ ^/var/www/([^/]+) ]]; then
        resolve_site_id_from_domain "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# =============================================================================
# Graceful degradation
# =============================================================================

# Usage: with_fallback <primary> <fallback> [--] <args...>
with_fallback() {
    local primary="$1" fallback="${2:-}"
    shift 2 || true
    [[ "${1:-}" == "--" ]] && shift

    if [[ -z "$primary" || ! -x "$primary" ]]; then
        log_error "with_fallback: primary not executable: $primary"
        return 2
    fi

    if "$primary" "$@"; then
        return 0
    fi
    local rc=$?

    if [[ -n "$fallback" && -x "$fallback" ]]; then
        log_warning "Primary handler exited ${rc}; invoking fallback: $(basename "$fallback")"
        "$fallback" "$@"
        return $?
    fi

    return $rc
}

# =============================================================================
# Sudo gate
# =============================================================================

# Usage: require_sudo "<short reason>"
require_sudo() {
    local reason="${1:-this operation}"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "${reason} requires sudo"
        log_info "  Re-run with: sudo geodineum <command> ..."
        exit 1
    fi
}

# =============================================================================
# Deploy-user resolution
# =============================================================================
declare -F resolve_deploy_user >/dev/null 2>&1 || resolve_deploy_user() {
    local user="${DEPLOY_USER:-}"
    if [[ -z "$user" ]] && [[ -r /etc/geodineum/deploy.env ]]; then
        user=$(grep '^DEPLOY_USER=' /etc/geodineum/deploy.env 2>/dev/null | cut -d= -f2)
    fi
    user="${user:-${SUDO_USER:-$(whoami)}}"
    echo "$user"
}

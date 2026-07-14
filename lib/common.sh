#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — Shared Utilities
# =================================
# Colors, logging, bootstrap.env loading, validation helpers.
# Sourced by all lib/*.sh modules — never executed directly.
#

# (strict mode declared at top of file post-1.14.f)

# =============================================================================
# Paths
# =============================================================================

# Resolve CLI root (parent of lib/)
GEODINEUM_CLI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ecosystem paths (all overridable via environment for portable deployments)
GEODINEUM_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"
GEODINEUM_CONFIG_ROOT="${GEODINEUM_CONFIG_ROOT:-/etc/geodineum}"
GEODINEUM_CREDENTIALS_DIR="${GEODINEUM_CREDENTIALS_DIR:-${GEODINEUM_CONFIG_ROOT}/credentials}"
GEODINEUM_WEB_ROOT="${GEODINEUM_WEB_ROOT:-/var/www}"
GEODINEUM_DISCOVERY_CONF="${GEODINEUM_DISCOVERY_CONF:-${GEODINEUM_CONFIG_ROOT}/components/gnode-daemon/discovery-paths.conf}"

# Component paths
GNODE_PATH="${GEODINEUM_ROOT}/gNode"
GNODE_SCRIPTS="${GNODE_PATH}/scripts"
GTEMPLATE_PATH="${GEODINEUM_ROOT}/gTemplate"
GCORE_PATH="${GEODINEUM_ROOT}/gCore"

# ValKey
VALKEY_HOST="${VALKEY_HOST:-127.0.0.1}"
VALKEY_PORT="${VALKEY_PORT:-47445}"

# =============================================================================
# Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# Logging
# =============================================================================

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}  OK${NC}  $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1" >&2; }
log_step()    { echo ""; echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; }
log_detail()  { echo -e "    ${DIM}$1${NC}"; }
log_dry()     { echo -e "${YELLOW}[DRY-RUN]${NC} Would: $1"; }

# =============================================================================
# Bootstrap (canonical ecosystem loader)
# =============================================================================
#
# Soft-load so the CLI itself can run on hosts without /etc/geodineum/ (e.g.,
# pre-install). Subcommands that need ValKey re-load strictly themselves.

GEODINEUM_LIB="${GEODINEUM_LIB:-/usr/local/lib/geodineum}"
if [[ -r "${GEODINEUM_LIB}/bootstrap-loader.sh" ]]; then
    # shellcheck source=/usr/local/lib/geodineum/bootstrap-loader.sh
    source "${GEODINEUM_LIB}/bootstrap-loader.sh"
    load_ecosystem_config 2>/dev/null || true
fi

# =============================================================================
# Validation
# =============================================================================

# Validate site_id: lowercase, numbers, underscores only
validate_site_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[a-z][a-z0-9_]*$ ]]; then
        log_error "Invalid site ID: '${id}'"
        log_error "Must start with lowercase letter, contain only [a-z0-9_]"
        return 1
    fi
}

# Validate domain: basic DNS-like check
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        log_error "Invalid domain: '${domain}'"
        return 1
    fi
}

# Validate DTAP environment
validate_environment() {
    local env="$1"
    case "$env" in
        testing|staging|acceptance|production) return 0 ;;
        *)
            log_error "Invalid environment: '${env}'"
            log_error "Must be one of: testing, staging, acceptance, production"
            return 1
            ;;
    esac
}

# =============================================================================
# Ecosystem Detection
# =============================================================================

# Check if a component exists at expected path
check_component() {
    local name="$1"
    local path="$2"
    if [[ -d "$path" ]]; then
        log_success "$name found at ${path}"
        return 0
    else
        log_warning "$name not found at ${path}"
        return 1
    fi
}

# Check if a named component is installed
# Usage: component_available "geodine" && run_geodine_cmd || echo "not installed"
component_available() {
    # Only released components are listed here — listing unreleased
    # ones would falsely report them as installable on operator hosts.
    local name="$1"
    case "$name" in
        gnode|gnode-daemon) [[ -d "${GEODINEUM_ROOT}/gNode" ]] ;;
        gnode-client)       [[ -d "${GEODINEUM_ROOT}/gNode-Client" ]] ;;
        gcore)              [[ -d "${GEODINEUM_ROOT}/gCore" ]] ;;
        gtemplate)          [[ -d "${GEODINEUM_ROOT}/gTemplate" ]] ;;
        gcube)              [[ -d "${GEODINEUM_ROOT}/gCube" ]] ;;
        comms|geodineum-comms) [[ -d "${GEODINEUM_ROOT}/Geodineum-COMMS" ]] ;;
        bak|geodineum-bak)  [[ -d "${GEODINEUM_ROOT}/Geodineum-BAK" ]] ;;
        *)                  return 1 ;;
    esac
}

# Guard a feature that requires a component not installed
require_component() {
    local name="$1"
    local feature="${2:-This feature}"
    if ! component_available "$name"; then
        log_error "${feature} requires ${name}, which is not installed."
        log_info "${name} is not part of this release."
        return 1
    fi
}

# Check if gNode daemon is available
require_gnode() {
    if [[ ! -x "${GNODE_SCRIPTS}/onboard-service.sh" ]]; then
        log_error "gNode not found at ${GNODE_PATH}"
        log_error "Install gNode first: sudo ./install.sh --profile standard"
        return 1
    fi
}

# Check if ValKey is reachable
check_valkey() {
    if [[ -x "${GNODE_SCRIPTS}/valkey-cli-secure.sh" ]]; then
        if "${GNODE_SCRIPTS}/valkey-cli-secure.sh" PING 2>/dev/null | grep -q "PONG"; then
            return 0
        fi
    fi
    return 1
}

# =============================================================================
# Sudo Handling
# =============================================================================

# Check if we need and have sudo
require_sudo() {
    local reason="${1:-This operation}"
    if [[ $EUID -ne 0 ]]; then
        log_error "${reason} requires root privileges"
        log_error "Re-run with sudo"
        exit 1
    fi
}

# =============================================================================
# Domain → Site ID Conversion
# =============================================================================

# Convert domain to site_id (dots → underscores, lowercase)
domain_to_site_id() {
    local domain="$1"
    echo "$domain" | tr '.' '_' | tr '-' '_' | tr '[:upper:]' '[:lower:]'
}

# =============================================================================
# Summary Display
# =============================================================================

print_summary_header() {
    local title="$1"
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    printf "${GREEN}║${NC}  ${BOLD}%-49s${NC}${GREEN}║${NC}\n" "$title"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_kv() {
    local key="$1"
    local value="$2"
    printf "  ${DIM}%-22s${NC} %s\n" "$key:" "$value"
}

# =============================================================================
# Template Rendering
# =============================================================================

# =============================================================================
# .geodineum/ Directory Management
# =============================================================================
#
# The .geodineum/ directory is the service-local footprint of the Geodineum
# ecosystem. Every registered service gets one in its root directory.
#
# Structure:
#   .geodineum/
#     ├── .htaccess              (Apache: Deny from all)
#     ├── nginx-deny.conf        (nginx: location block snippet)
#     ├── credentials/
#     │   └── valkey_client_{site_id}.password → /etc/geodineum/credentials/...
#     ├── config.yaml            (unified: identity, environment, valkey, capabilities, metadata)
#     ├── gnode_services.yaml    (23D capability config — daemon discovers this)
#     ├── config-schema.yaml     (developer config option schema — generated on import)
#     └── .registered            (marker: ISO timestamp + sha256 of config)
#

# Deploy web-deny rules (.htaccess + nginx snippet) to a directory.
# Idempotent — skips if already present and current.
deploy_web_deny() {
    local dir="$1"
    local label="${2:-Geodineum ecosystem directory}"

    [[ ! -d "$dir" ]] && return 0

    # Apache
    local htaccess="${dir}/.htaccess"
    if [[ ! -f "$htaccess" ]] || ! grep -q "Geodineum" "$htaccess" 2>/dev/null; then
        cat > "$htaccess" << HTEOF
# ${label} — no web access
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order deny,allow
    Deny from all
</IfModule>
HTEOF
        # root:www-data 640 — Apache (www-data) MUST be able to read every
        # .htaccess it's configured to honor; if it can't, Apache fails
        # closed ("unable to read htaccess file, denying access to be safe")
        # which silently 403s the whole subtree. www-data is deliberately
        # NOT in the broad `geodineum` group, so root:geodineum made these
        # files unreadable — fine by accident for deny-dirs, fatal for the
        # theme asset .htaccess that must ALLOW static files.
        chown root:www-data "$htaccess" 2>/dev/null || true
        chmod 640 "$htaccess" 2>/dev/null || true
    fi

    # nginx
    # Accept any existing file that already denies — several component repos
    # TRACK a nginx-deny.conf whose header lacks the word "Geodineum", and
    # rewriting those dirtied every /opt working tree, blocking all future
    # ff-only pulls (geodeploy and install re-runs silently stopped updating).
    local ngconf="${dir}/nginx-deny.conf"
    if [[ ! -f "$ngconf" ]] || ! grep -q "deny all" "$ngconf" 2>/dev/null; then
        local dirname
        dirname=$(basename "$dir")
        cat > "$ngconf" << NGEOF
# ${label} — no web access
# Include in your nginx server block or add the rule directly.
location ~ /${dirname} {
    deny all;
    return 404;
}
NGEOF
        chown root:geodineum "$ngconf" 2>/dev/null || true
        chmod 640 "$ngconf" 2>/dev/null || true
    fi
}

# Deploy web-deny rules to ALL ecosystem directories that www-data must not serve.
# www-data is in the geodineum group for credential file access, but a compromised
# PHP process should never be able to serve source code or infrastructure files.
harden_ecosystem_dirs() {
    local root="${GEODINEUM_ROOT:-/opt/geodineum}"
    local config_root="${GEODINEUM_CONFIG_ROOT:-/etc/geodineum}"
    local hardened=0

    # Root-level catch-all
    deploy_web_deny "$root" "Geodineum ecosystem root"

    # Infrastructure components (NEVER web-served). The for-loop
    # existence check guards against missing dirs.
    local -a infra_dirs=(
        "gNode"
        "Geodineum"
        "Geodineum-COMMS"
        "Geodineum-BAK"
        "gNode-Client"
    )
    for d in "${infra_dirs[@]}"; do
        if [[ -d "${root}/${d}" ]]; then
            deploy_web_deny "${root}/${d}" "${d} — infrastructure"
            hardened=$((hardened + 1))
        fi
    done

    # Pro extension dirs (guarded by existence check — harmless when
    # absent; kept for forward-compat).
    for ext_root in "${root}/pro/gNode" "${root}/pro/gCore"; do
        if [[ -d "$ext_root" ]]; then
            deploy_web_deny "$ext_root" "Pro extensions"
            for ext_dir in "${ext_root}"/*/; do
                [[ -d "$ext_dir" ]] && deploy_web_deny "$ext_dir" "$(basename "$ext_dir") — extension"
                hardened=$((hardened + 1))
            done
        fi
    done

    # PHP components — served by WordPress via autoloader/symlink, but the
    # source directories themselves should not be directly browsable.
    local -a php_dirs=(
        "gCore"
        "gTemplate"
        "gCube"
    )
    for d in "${php_dirs[@]}"; do
        if [[ -d "${root}/${d}" ]]; then
            # Protect sensitive subdirs (don't block root — WordPress symlinks need it)
            for subdir in scripts tests docs .git; do
                [[ -d "${root}/${d}/${subdir}" ]] && deploy_web_deny "${root}/${d}/${subdir}" "${d}/${subdir}"
            done
            hardened=$((hardened + 1))
        fi
    done

    # Standalone services
    if [[ -d "${root}/services" ]]; then
        deploy_web_deny "${root}/services" "Standalone services"
        for svc_dir in "${root}/services"/*/; do
            [[ -d "$svc_dir" ]] && deploy_web_deny "$svc_dir" "$(basename "$svc_dir") — service"
        done
    fi

    # Config + credentials directory
    if [[ -d "$config_root" ]]; then
        deploy_web_deny "$config_root" "Geodineum config (credentials)"
        [[ -d "${config_root}/credentials" ]] && \
            deploy_web_deny "${config_root}/credentials" "Geodineum credentials"
    fi

    echo "$hardened"
}

# Detect the owner of a directory (returns "user:group").
detect_dir_owner() {
    local path="$1"
    local owner group
    owner=$(stat -c '%U' "$path" 2>/dev/null) || owner="root"
    group=$(stat -c '%G' "$path" 2>/dev/null) || group="root"
    echo "${owner}:${group}"
}

# Ensure a user is in the geodineum group (ecosystem-level access).
# The geodineum group grants access to .geodineum/ dirs and credential symlinks.
# Warns if not; does not modify groups automatically.
ensure_geodineum_group() {
    local user="$1"
    [[ "$user" == "root" || "$user" == "gnode" ]] && return 0

    if id -nG "$user" 2>/dev/null | grep -qw geodineum; then
        return 0
    fi

    log_warning "User '${user}' is not in the geodineum group"
    log_info "Add with: sudo usermod -aG geodineum ${user}"
    log_info "Required for service access to .geodineum/ and credential symlinks"
    return 1
}

# Create the .geodineum/ directory skeleton with .htaccess protection.
# Call BEFORE onboarding. Config and credentials are written by later steps.
# Ownership inherits from the service root directory owner with group=geodineum.
create_geodineum_dir() {
    local service_path="$1"
    local site_id="$2"
    local environment="${3:-testing}"
    local geodineum_dir="${service_path}/.geodineum"

    mkdir -p "${geodineum_dir}/credentials" || {
        log_error "Failed to create ${geodineum_dir}"
        return 1
    }

    # Web server protection — blocks all HTTP access to .geodineum/
    # Critical when .geodineum/ sits inside a web root (e.g. /var/www/).

    # Apache (.htaccess)
    cat > "${geodineum_dir}/.htaccess" << 'HTEOF'
# Geodineum ecosystem directory — no web access
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order deny,allow
    Deny from all
</IfModule>
HTEOF

    # nginx (snippet — include from server block or add to site config)
    cat > "${geodineum_dir}/nginx-deny.conf" << 'NGEOF'
# Geodineum ecosystem directory — no web access
# Include this in your nginx server block:
#   include /path/to/.geodineum/nginx-deny.conf;
# Or add this location block directly:
#   location ~ /\.geodineum { deny all; return 404; }
location ~ /\.geodineum {
    deny all;
    return 404;
}
NGEOF

    # Ownership: service root owner + geodineum group
    local svc_owner
    svc_owner=$(stat -c '%U' "$service_path" 2>/dev/null) || svc_owner="root"

    chown -R "${svc_owner}:geodineum" "$geodineum_dir" 2>/dev/null || {
        chown -R "${svc_owner}" "$geodineum_dir" 2>/dev/null || true
    }
    chmod 751 "$geodineum_dir" 2>/dev/null || true
    chmod 751 "${geodineum_dir}/credentials" 2>/dev/null || true

    ensure_geodineum_group "$svc_owner" || true

    log_success "Created ${geodineum_dir}/ (${svc_owner}:geodineum)"
    return 0
}

# Generate the unified config.yaml inside .geodineum/.
# This is the service's canonical configuration — identity, environment,
# ValKey connection, capabilities, metadata, and COMMS settings.
# Reads CAP_* variables from the current environment.
# Call AFTER capabilities have been resolved.
generate_geodineum_config() {
    local service_path="$1"
    local site_id="$2"
    local environment="${3:-testing}"
    local description="${4:-Geodineum service}"
    local service_type="${5:-service}"
    local tier="${6:-SERVICE}"
    local lang="${7:-}"
    local geodineum_dir="${service_path}/.geodineum"
    local config_file="${geodineum_dir}/config.yaml"

    cat > "$config_file" << CFGEOF
# =============================================================================
# Geodineum Unified Service Configuration
# =============================================================================
# Canonical config for this service. Cached in ValKey at {site_id}:config:site.
# Changes via: geodineum config set, geodineum env set, or edit + sync.
#
# Generated by: geodineum CLI
# Updated: $(date -Iseconds)
# =============================================================================

version: "2.0.0"
site_id: "${site_id}"

# --- Identity ---
identity:
  type: ${service_type}
  tier: ${tier}
  display_name: "${site_id}"
  description: "${description}"
  owner: ""${lang:+
  language: "${lang}"}

# --- Environment & Gating ---
environment:
  active: ${environment}
  viewkey: ""
  viewkey_expiry: 86400

# --- ValKey Connection ---
valkey:
  host: "${VALKEY_HOST:-127.0.0.1}"
  port: ${VALKEY_PORT:-47445}
  user: "gnode_client_${site_id}"
  password_file: "${geodineum_dir}/credentials/valkey_client_${site_id}.password"

# --- gNode Topology Capabilities ---
capabilities:
  protocol: ${CAP_PROTOCOL:-http_rest}
  native_format: ${CAP_FORMAT:-json}
  api_version: ${CAP_API_VERSION:-v1}
  contract_stability: ${CAP_STABILITY:-stable}
  clearance_required: ${CAP_CLEARANCE:-public}
  auth_method: ${CAP_AUTH:-session_cookie}
  data_sensitivity: ${CAP_SENSITIVITY:-internal}
  service_scope: ${CAP_SCOPE:-client_facing}
  domain_primary: ${CAP_DOMAIN:-content}
  domain_secondary: ${CAP_DOMAIN_SECONDARY:-template}
  specialization: ${CAP_SPECIALIZATION:-generalist}
  throughput_tier: ${CAP_THROUGHPUT:-standard}
  latency_class: ${CAP_LATENCY:-responsive}
  reliability_tier: ${CAP_RELIABILITY:-standard}
  pipeline_stage: ${CAP_PIPELINE_STAGE:-deliver}
  execution_priority: ${CAP_PRIORITY:-normal}

# --- Service Metadata ---
metadata:
  created_by: geodineum-cli
  registered_at: $(date -Iseconds)

# --- Registration ---
registration:
  method: smart
  check_hash_before_register: true
  sync_to_valkey: true
  valkey_config_ttl: 86400

# --- Notifications (Geodineum-COMMS) ---
# Uncomment and configure to enable notifications.
# comms:
#   enabled: true
#   channels:
#     email:
#       enabled: true
#       config:
#         smtp_host: "127.0.0.1"
#         smtp_port: 25
#         from_email: "noreply@example.com"
#       recipients:
#         - email: "admin@example.com"
#           types: ["all"]
CFGEOF

    chmod 640 "$config_file" 2>/dev/null || true
    log_success "Generated .geodineum/config.yaml (unified)"
    return 0
}

# Finalize .geodineum/ after onboarding completes.
# Creates credential symlink (password file now exists) and .registered marker.
finalize_geodineum_dir() {
    local service_path="$1"
    local site_id="$2"
    local environment="${3:-testing}"
    local geodineum_dir="${service_path}/.geodineum"

    # Credential symlink — same filename as the source for clarity
    local cred_filename="valkey_client_${site_id}.password"
    local cred_source="${GEODINEUM_CREDENTIALS_DIR}/${cred_filename}"
    local cred_link="${geodineum_dir}/credentials/${cred_filename}"
    if [[ -f "$cred_source" ]]; then
        ln -sf "$cred_source" "$cred_link"
        log_success "Credential symlink: credentials/${cred_filename}"
    else
        log_warning "Credential file not found: ${cred_source}"
        log_info "Symlink will resolve after onboarding creates the password"
    fi

    # .registered marker
    local config_hash="none"
    if [[ -f "${geodineum_dir}/gnode_services.yaml" ]]; then
        config_hash=$(sha256sum "${geodineum_dir}/gnode_services.yaml" 2>/dev/null | cut -d' ' -f1)
    fi
    cat > "${geodineum_dir}/.registered" << REGEOF
# Geodineum Registration Marker
registered_at: $(date -Iseconds)
site_id: ${site_id}
environment: ${environment}
config_hash: ${config_hash}
REGEOF

    # Preserve ownership from create step (service owner:gnode)
    local svc_owner
    svc_owner=$(stat -c '%U' "$service_path" 2>/dev/null) || svc_owner="root"
    chown -R "${svc_owner}:geodineum" "$geodineum_dir" 2>/dev/null || true
    chmod 751 "$geodineum_dir" 2>/dev/null || true
    chmod 751 "${geodineum_dir}/credentials" 2>/dev/null || true
    find "$geodineum_dir" -maxdepth 1 -type f -exec chmod 640 {} \; 2>/dev/null || true

    log_success "Finalized .geodineum/ (${svc_owner}:geodineum, registered)"
    return 0
}

# Find the .geodineum directory for a given site_id.
# Searches known paths and discovery-paths.conf.
find_geodineum_dir() {
    local site_id="$1"
    local domain
    domain=$(echo "$site_id" | sed 's/_/./g')

    for candidate in \
        "${GEODINEUM_WEB_ROOT}/${domain}/.geodineum" \
        "${GEODINEUM_WEB_ROOT}/${domain}/public_html/.geodineum" \
        "${GEODINEUM_ROOT}/services/${site_id}/.geodineum"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Check discovery-paths.conf entries
    local disc_conf="$GEODINEUM_DISCOVERY_CONF"
    if [[ -f "$disc_conf" ]]; then
        while IFS= read -r path; do
            [[ -z "$path" || "$path" == \#* ]] && continue
            if [[ -d "$path" ]] && [[ -f "${path}/.registered" ]]; then
                local reg_site
                reg_site=$(grep "^site_id:" "${path}/.registered" 2>/dev/null | sed 's/^site_id: *//')
                if [[ "$reg_site" == "$site_id" ]]; then
                    echo "$path"
                    return 0
                fi
            fi
        done < "$disc_conf"
    fi

    return 1
}

# Resolve service path for a site_id (auto-detect WordPress sites).
resolve_service_path() {
    local site_id="$1"
    local domain
    domain=$(echo "$site_id" | sed 's/_/./g')

    # WordPress at {web_root}/{domain}
    if [[ -d "${GEODINEUM_WEB_ROOT}/${domain}" ]]; then
        echo "${GEODINEUM_WEB_ROOT}/${domain}"
        return 0
    fi

    # WordPress at {web_root}/{domain}/public_html
    if [[ -d "${GEODINEUM_WEB_ROOT}/${domain}/public_html" ]]; then
        echo "${GEODINEUM_WEB_ROOT}/${domain}/public_html"
        return 0
    fi

    # Standalone service
    if [[ -d "${GEODINEUM_ROOT}/services/${site_id}" ]]; then
        echo "${GEODINEUM_ROOT}/services/${site_id}"
        return 0
    fi

    return 1
}

# =============================================================================
# WordPress Integration (mu-plugin + parent theme)
# =============================================================================

# Wire up gCore mu-plugin and gTemplate parent theme for a WordPress site.
# Creates symlinks and the loader PHP file. Idempotent — safe to re-run.
# Returns 0 if WordPress detected and wired, 1 if not a WordPress site.
setup_wordpress_integration() {
    local service_path="$1"
    local wp_root="$service_path"

    # Is this a WordPress site?
    if [[ ! -f "${wp_root}/wp-config.php" ]] && [[ ! -f "${wp_root}/wp-load.php" ]]; then
        return 1  # Not WordPress
    fi

    local mu_dir="${wp_root}/wp-content/mu-plugins"
    local themes_dir="${wp_root}/wp-content/themes"
    local gcore_source="${GEODINEUM_ROOT}/gCore/gcore-mu"
    local gtemplate_source="${GEODINEUM_ROOT}/gTemplate"
    local changes=0

    # Verify gCore exists in the ecosystem
    if [[ ! -d "$gcore_source" ]]; then
        log_warning "gCore not found at ${gcore_source} — skipping mu-plugin setup"
        log_info "Install gCore first: geodineum install --components gcore"
        return 0
    fi

    # 1. Create mu-plugins directory if needed
    if [[ ! -d "$mu_dir" ]]; then
        mkdir -p "$mu_dir"
        chown www-data:www-data "$mu_dir"
        chmod 750 "$mu_dir"
    fi

    # 2. Symlink gcore-mu → /opt/geodineum/gCore/gcore-mu
    local mu_link="${mu_dir}/gcore-mu"
    if [[ -L "$mu_link" ]] && [[ "$(readlink "$mu_link")" == "$gcore_source" ]]; then
        log_detail "mu-plugin symlink already correct"
    else
        [[ -e "$mu_link" || -L "$mu_link" ]] && rm -f "$mu_link"
        ln -s "$gcore_source" "$mu_link"
        log_success "Symlinked mu-plugin: gcore-mu → ${gcore_source}"
        changes=$((changes + 1))
    fi

    # 3. Create gcore-mu.php loader
    local mu_loader="${mu_dir}/gcore-mu.php"
    if [[ ! -f "$mu_loader" ]] || ! grep -q "gcore-loader.php" "$mu_loader" 2>/dev/null; then
        cat > "$mu_loader" << 'LOADEREOF'
<?php
/**
 * gCore MU-Plugin Loader
 * Auto-generated by: geodineum register
 */
require_once __DIR__ . '/gcore-mu/gcore-loader.php';
LOADEREOF
        chown www-data:www-data "$mu_loader"
        chmod 640 "$mu_loader"
        log_success "Created mu-plugin loader: gcore-mu.php"
        changes=$((changes + 1))
    else
        log_detail "mu-plugin loader already exists"
    fi

    # 4. Remove any disabled loader (leftover from manual disabling)
    if [[ -f "${mu_dir}/gcore-loader.php.disabled" ]]; then
        rm -f "${mu_dir}/gcore-loader.php.disabled"
        log_success "Removed disabled loader (superseded by gcore-mu.php)"
    fi

    # 5. Symlink parent theme gtemplate-wp → /opt/geodineum/gTemplate
    if [[ -d "$gtemplate_source" ]]; then
        local theme_link="${themes_dir}/gtemplate-wp"
        if [[ -L "$theme_link" ]] && [[ "$(readlink "$theme_link")" == "$gtemplate_source" ]]; then
            log_detail "Parent theme symlink already correct"
        else
            [[ -e "$theme_link" || -L "$theme_link" ]] && rm -rf "$theme_link"
            ln -s "$gtemplate_source" "$theme_link"
            log_success "Symlinked parent theme: gtemplate-wp → ${gtemplate_source}"
            changes=$((changes + 1))
        fi
    else
        log_warning "gTemplate not found at ${gtemplate_source} — skipping parent theme"
        log_info "Install gTemplate: geodineum install --components gtemplate-wp"
    fi

    if [[ $changes -eq 0 ]]; then
        log_detail "WordPress integration already configured"
    fi

    return 0
}

# =============================================================================
# Template Rendering
# =============================================================================

# Simple {{VAR}} substitution from exported shell variables
render_template() {
    local template_file="$1"
    local output_file="$2"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file}"
        return 1
    fi

    local content
    content="$(cat "$template_file")"

    # Replace all known {{VAR}} placeholders
    # Identity
    content="${content//\{\{SERVICE_NAME\}\}/${SERVICE_NAME:-}}"
    content="${content//\{\{SERVICE_ID\}\}/${SERVICE_ID:-}}"
    content="${content//\{\{SITE_ID\}\}/${SITE_ID:-}}"
    content="${content//\{\{SERVICE_DESCRIPTION\}\}/${SERVICE_DESCRIPTION:-}}"
    content="${content//\{\{SERVICE_TIER\}\}/${SERVICE_TIER:-}}"
    content="${content//\{\{SERVICE_LANG\}\}/${SERVICE_LANG:-}}"
    content="${content//\{\{SERVICE_ENV\}\}/${SERVICE_ENV:-}}"
    content="${content//\{\{SERVICE_TYPE\}\}/${SERVICE_TYPE:-standalone-service}}"
    content="${content//\{\{SERVICE_DOMAIN\}\}/${SERVICE_DOMAIN:-}}"
    content="${content//\{\{TEMPLATE_NAME\}\}/${TEMPLATE_NAME:-}}"
    content="${content//\{\{DOMAIN\}\}/${DOMAIN:-}}"
    content="${content//\{\{GCORE_ENTRY\}\}/${GCORE_ENTRY:-/opt/geodineum/gCore/gcore-standalone.php}}"
    # Capabilities
    content="${content//\{\{CAP_PROTOCOL\}\}/${CAP_PROTOCOL:-}}"
    content="${content//\{\{CAP_FORMAT\}\}/${CAP_FORMAT:-}}"
    content="${content//\{\{CAP_STABILITY\}\}/${CAP_STABILITY:-}}"
    content="${content//\{\{CAP_CLEARANCE\}\}/${CAP_CLEARANCE:-}}"
    content="${content//\{\{CAP_AUTH\}\}/${CAP_AUTH:-}}"
    content="${content//\{\{CAP_SENSITIVITY\}\}/${CAP_SENSITIVITY:-}}"
    content="${content//\{\{CAP_SCOPE\}\}/${CAP_SCOPE:-}}"
    content="${content//\{\{CAP_DOMAIN\}\}/${CAP_DOMAIN:-}}"
    content="${content//\{\{CAP_DOMAIN_SECONDARY\}\}/${CAP_DOMAIN_SECONDARY:-}}"
    content="${content//\{\{CAP_SPECIALIZATION\}\}/${CAP_SPECIALIZATION:-}}"
    content="${content//\{\{CAP_THROUGHPUT\}\}/${CAP_THROUGHPUT:-}}"
    content="${content//\{\{CAP_LATENCY\}\}/${CAP_LATENCY:-}}"
    content="${content//\{\{CAP_RELIABILITY\}\}/${CAP_RELIABILITY:-}}"
    content="${content//\{\{CAP_PIPELINE_STAGE\}\}/${CAP_PIPELINE_STAGE:-}}"
    content="${content//\{\{CAP_PRIORITY\}\}/${CAP_PRIORITY:-}}"

    echo "$content" > "$output_file" || { log_error "Failed to write ${output_file}"; return 1; }
}

# =============================================================================
# CLI Handler Utilities
# =============================================================================

resolve_deploy_user() {
    local user="${DEPLOY_USER:-}"
    if [[ -z "$user" ]] && [[ -r /etc/geodineum/deploy.env ]]; then
        user=$(grep '^DEPLOY_USER=' /etc/geodineum/deploy.env 2>/dev/null | cut -d= -f2)
    fi
    user="${user:-${SUDO_USER:-$(whoami)}}"
    echo "$user"
}

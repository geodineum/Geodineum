#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — Environment Management
# ========================================
# Change DTAP environments, manage viewkeys, show gate status.
#
# DTAP model:
#   testing     → viewkey-gated, "Under Development" screen
#   staging     → viewkey-gated, environment badge visible
#   acceptance  → viewkey-gated, final review
#   production  → public, no gate
#
# Requires: common.sh sourced first
#

# =============================================================================
# Helpers
# =============================================================================

# Find the site's YAML config file
find_site_config() {
    local site_id="$1"
    local domain
    domain=$(echo "$site_id" | sed 's/_/./g')

    # Resolution order: centralized → WordPress fallback → service fallback
    for candidate in \
        "${GEODINEUM_CONFIG_ROOT}/sites/${site_id}/config.yaml" \
        "${GEODINEUM_CONFIG_ROOT}/services/${site_id}/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/.geodineum/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/wp-config-geodineum.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/wp-config-gtemplate.yaml" \
        "${GEODINEUM_ROOT}/services/${site_id}/.geodineum/config.yaml" \
        "${GEODINEUM_ROOT}/services/${site_id}/.env"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Read current environment from YAML config
# Supports both v1 (metadata.environment) and v2 (environment.active) formats
read_yaml_env() {
    local config_file="$1"
    if [[ "$config_file" == *.yaml ]]; then
        # v2 format: environment.active
        local v2
        v2=$(grep -E "^\s+active:" "$config_file" 2>/dev/null | head -1 | sed 's/.*active:\s*//' | tr -d '"' | tr -d "'")
        if [[ -n "$v2" ]]; then
            echo "$v2"
            return
        fi
        # v1 format: metadata.environment
        grep -E "^\s+environment:" "$config_file" 2>/dev/null | head -1 | sed 's/.*environment:\s*//' | tr -d '"' | tr -d "'"
    elif [[ "$config_file" == *.env ]]; then
        grep "^GNODE_ENVIRONMENT=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"'
    fi
}

# Read current viewkey from YAML config
read_yaml_viewkey() {
    local config_file="$1"
    if [[ "$config_file" == *.yaml ]]; then
        grep -E "^\s+viewkey:" "$config_file" 2>/dev/null | head -1 | sed 's/.*viewkey:\s*//' | tr -d '"' | tr -d "'"
    fi
}

# Update environment in YAML config (handles both v1 and v2 formats)
write_yaml_env() {
    local config_file="$1"
    local new_env="$2"

    if [[ "$config_file" == *.yaml ]]; then
        # v2 format: environment.active
        if grep -q "^\s*active:" "$config_file" 2>/dev/null; then
            sed -i "s/^\(\s*active:\s*\).*/\1${new_env}/" "$config_file"
        fi
        # v1 format: metadata.environment (also update for backward compat)
        if grep -q "^\s*environment:" "$config_file" 2>/dev/null; then
            sed -i "s/^\(\s*environment:\s*\).*/\1${new_env}/" "$config_file"
        fi
    elif [[ "$config_file" == *.env ]]; then
        sed -i "s/^GNODE_ENVIRONMENT=.*/GNODE_ENVIRONMENT=\"${new_env}\"/" "$config_file"
    fi
}

# Update viewkey in YAML config
write_yaml_viewkey() {
    local config_file="$1"
    local viewkey="$2"

    if [[ "$config_file" == *.yaml ]]; then
        if grep -q "^\s*viewkey:" "$config_file" 2>/dev/null; then
            sed -i "s|^\(\s*viewkey:\s*\).*|\1\"${viewkey}\"|" "$config_file"
        else
            # Add viewkey under security section
            if grep -q "^security:" "$config_file" 2>/dev/null; then
                sed -i "/^security:/a\\  viewkey: \"${viewkey}\"" "$config_file"
            else
                echo -e "\nsecurity:\n  viewkey: \"${viewkey}\"\n  viewkey_expiry: 86400" >> "$config_file"
            fi
        fi
    fi
}

# Generate a secure viewkey
generate_viewkey() {
    openssl rand -base64 24 | tr -d '=+/' | cut -c1-20
}

# Canonical ValKey site_id: PHP's get_site_id_from_domain() builds it as the
# domain with '.' and '-' replaced by '_'. Accept either the domain (dots) or
# the already-underscored id; tr normalizes both to the one true key form.
# The dots/underscore mismatch was the root cause of the "config flipped but
# runtime stayed staging" bug — the cred file and ValKey keys silently missed.
valkey_site_id() {
    printf '%s' "$1" | tr '.-' '__'
}

# Run valkey-cli for env writes. Prefer the per-site client credential; fall
# back to the admin credential (default user) so it works whenever run as root.
# site_id MUST be the canonical (underscore) form. Returns 2 if no credential
# is readable.
_valkey_env_cli() {
    local site_id="$1"; shift
    local client_pw="${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${site_id}.password"
    local admin_pw="${GEODINEUM_CREDENTIALS_DIR}/valkey.password"
    local pass
    local user_flag=()
    if [[ -r "$client_pw" ]]; then
        pass=$(cat "$client_pw"); user_flag=(--user "gnode_client_${site_id}")
    elif [[ -r "$admin_pw" ]]; then
        pass=$(cat "$admin_pw")            # default/admin user, no --user flag
    else
        return 2
    fi
    REDISCLI_AUTH="$pass" valkey-cli -p "${VALKEY_PORT:-47445}" "${user_flag[@]}" --no-auth-warning "$@"
}

# Can we reach ValKey with a usable credential? (pre-flight before mutating)
valkey_env_reachable() {
    [[ "$(_valkey_env_cli "$1" PING 2>/dev/null)" == "PONG" ]]
}

# Stamp active_environment + invalidate the cached registration config, then
# VERIFY the cache key is actually gone. Runtime env (gtemplate_detect_environment)
# reads metadata.environment from {site_id}:config:registration, so clearing it
# is what makes the flip take effect. Returns non-zero unless verified.
# site_id MUST be the canonical (underscore) form.
update_valkey_env() {
    local site_id="$1"
    local new_env="$2"

    _valkey_env_cli "$site_id" HSET "gnode:site:${site_id}:meta" "active_environment" "$new_env" >/dev/null 2>&1
    _valkey_env_cli "$site_id" DEL \
        "{${site_id}}:config:registration" "{${site_id}}:config:version:registration" >/dev/null 2>&1

    local exists
    exists=$(_valkey_env_cli "$site_id" EXISTS "{${site_id}}:config:registration" 2>/dev/null)
    [[ "$exists" == "0" ]]
}

# Reconcile the geometric env coordinate (dim-20) with the new active_environment,
# and notify the daemon. The two env stores otherwise diverge: env set updates
# active_environment, but dim-20 was embedded once at registration (defaulting to
# production). Re-registering with --env re-embeds dim-20. The entity id IS the
# site_id, so GNODE_REGISTER_CAPABILITY_VECTOR upserts in place (no duplicate) and
# touches ONLY the topology entity — never creds/viewkey/wp-admin. Best-effort: a
# failure leaves active_environment correct (what PHP reads) and the daemon
# reconverges on its next periodic discovery scan.
reembed_dim20_and_broadcast() {
    local site_id="$1"
    local new_env="$2"
    local dcred="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey_daemon.password"
    local port="${VALKEY_PORT:-47445}"

    # Re-register with the SAME profile the entity already has (m.type), so only
    # env changes — all other capabilities are preserved. Default to 'web'.
    local profile="web"
    if [[ -r "$dcred" ]] && command -v python3 >/dev/null 2>&1; then
        local entity_json detected
        entity_json=$(REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
            FCALL GNODE_TOPO_GET_ENTITY 1 "{${site_id}}:gnode:services" "$site_id" 2>/dev/null)
        detected=$(printf '%s' "$entity_json" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("m") or {}).get("type") or "")
except Exception: print("")' 2>/dev/null)
        [[ -n "$detected" ]] && profile="$detected"
    fi

    if geodineum topology register service "$site_id" "$profile" --env "$new_env" >/dev/null 2>&1; then
        log_success "Topology: dim-20 re-embedded (${profile} profile → ${new_env})"
    else
        log_warning "Could not re-embed dim-20 — geometric placement may lag active_environment"
        log_info "  Re-run: sudo geodineum topology register service ${site_id} ${profile} --env ${new_env}"
    fi

    # Best-effort broadcast → immediate daemon stream-discovery refresh.
    if [[ -r "$dcred" ]]; then
        local ts; ts=$(date +%s)
        REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
            XADD "{${site_id}}:gnode:broadcast:global" '*' \
            type environment_changed \
            data "{\"type\":\"environment_changed\",\"site_id\":\"${site_id}\",\"new_environment\":\"${new_env}\",\"timestamp\":${ts}}" \
            >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# geodineum env set
# =============================================================================

cmd_env_set() {
    local site_id=""
    local new_env=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat << 'EOF'
Usage: geodineum env set <site_id> <environment>

Change a site's DTAP environment. Non-production environments are
automatically gated behind a viewkey (generated if not set).

Environments:
  testing       Viewkey-gated, "Under Development" screen
  staging       Viewkey-gated, environment badge visible
  acceptance    Viewkey-gated, final review before launch
  production    Public — gate removed

Examples:
  sudo geodineum env set geodineum_com staging
  sudo geodineum env set geodineum_com production
EOF
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$site_id" ]]; then
                    site_id="$1"
                elif [[ -z "$new_env" ]]; then
                    new_env="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$site_id" ]] || [[ -z "$new_env" ]]; then
        log_error "Usage: geodineum env set <site_id> <environment>"
        exit 1
    fi

    validate_environment "$new_env" || exit 1

    # Find config
    local config_file
    config_file=$(find_site_config "$site_id") || {
        log_error "No config found for site '${site_id}'"
        log_info "Looked in ${GEODINEUM_WEB_ROOT}/, ${GEODINEUM_ROOT}/services/, ${GEODINEUM_CONFIG_ROOT}/sites/"
        exit 1
    }

    # Canonical ValKey site_id + pre-flight: confirm we can reach ValKey BEFORE
    # touching the config, so we never leave the file flipped but the runtime
    # cache stale (the failure that shipped geodineum.com "production" in the
    # config while it kept serving the staging viewkey gate).
    local vk_site_id
    vk_site_id=$(valkey_site_id "$site_id")
    if ! valkey_env_reachable "$vk_site_id"; then
        log_error "Cannot reach ValKey to complete the switch (no readable credential or daemon down)."
        log_error "  Run as root; needs ${GEODINEUM_CREDENTIALS_DIR}/valkey.password (admin) or"
        log_error "  ${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${vk_site_id}.password readable."
        log_error "  No changes made."
        exit 1
    fi

    local current_env
    current_env=$(read_yaml_env "$config_file")

    echo ""
    echo -e "  ${BOLD}Environment Change${NC}"
    echo ""
    print_kv "Site" "$site_id"
    print_kv "Config" "$config_file"
    print_kv "Current" "${current_env:-unknown}"
    print_kv "Target" "$new_env"
    echo ""

    if [[ "$current_env" == "$new_env" ]]; then
        # Config already matches, but the runtime reads env from the ValKey
        # cache — which can have drifted (e.g. a prior half-applied switch that
        # updated the file but not ValKey). Re-invalidate so config and runtime
        # are guaranteed consistent instead of trusting the file blindly.
        log_info "Config already ${new_env}; re-syncing ValKey cache to match"
        if update_valkey_env "$vk_site_id" "$new_env"; then
            reembed_dim20_and_broadcast "$site_id" "$new_env"
            php -r "opcache_reset();" 2>/dev/null && log_success "PHP OPcache cleared" || true
            log_success "Runtime re-synced to ${new_env}"
            return 0
        fi
        log_error "ValKey re-sync FAILED — runtime may still serve a stale environment."
        exit 1
    fi

    # Warn on production → non-production (site goes behind gate)
    if [[ "$current_env" == "production" ]] && [[ "$new_env" != "production" ]]; then
        log_warning "Site will be gated behind viewkey (hidden from public)"
    fi

    # Warn on non-production → production (gate removed)
    if [[ "$current_env" != "production" ]] && [[ "$new_env" == "production" ]]; then
        log_warning "Site will become publicly accessible (gate removed)"
    fi

    # 1. Update config file
    log_step "Updating Configuration"

    write_yaml_env "$config_file" "$new_env" || {
        log_error "Failed to update ${config_file}"
        exit 1
    }
    log_success "Config: environment → ${new_env}"

    # 2. Generate viewkey for non-production if not set
    if [[ "$new_env" != "production" ]]; then
        local current_viewkey
        current_viewkey=$(read_yaml_viewkey "$config_file")

        if [[ -z "$current_viewkey" ]]; then
            local new_viewkey
            new_viewkey=$(generate_viewkey)
            write_yaml_viewkey "$config_file" "$new_viewkey"
            log_success "Viewkey generated: ${new_viewkey}"
        else
            log_success "Viewkey already set"
        fi
    fi

    # 3. Invalidate the cached registration config + stamp active_environment.
    # REQUIRED for the switch to take effect: gtemplate_detect_environment()
    # reads env from that cache, not the YAML. Pre-flighted above, so a failure
    # here is exceptional — fail loudly instead of reporting a false success.
    if update_valkey_env "$vk_site_id" "$new_env"; then
        log_success "ValKey: cache invalidated + active_environment → ${new_env}  (site_id: ${vk_site_id})"
    else
        log_error "ValKey cache invalidation FAILED — runtime still serves '${current_env}', not '${new_env}'."
        log_error "  The config file was written but {${vk_site_id}}:config:registration was not cleared,"
        log_error "  so gtemplate_detect_environment() keeps returning the old value."
        exit 1
    fi

    # 3b. Reconcile dim-20 (geometric env coordinate) with active_environment +
    #     notify the daemon. Without this the two env stores diverge.
    reembed_dim20_and_broadcast "$site_id" "$new_env"

    # 4. Clear PHP OPcache so the change takes effect immediately
    php -r "opcache_reset();" 2>/dev/null && log_success "PHP OPcache cleared" || true

    # Summary
    echo ""
    if [[ "$new_env" != "production" ]]; then
        local viewkey
        viewkey=$(read_yaml_viewkey "$config_file")
        local domain
        domain=$(echo "$site_id" | sed 's/_/./g')

        echo -e "  ${BOLD}Site is now gated.${NC} Visitors see a gate screen with viewkey prompt."
        echo ""
        echo -e "  Viewkey:  ${CYAN}${viewkey}${NC}"
        echo -e "  URL:      ${CYAN}https://${domain}/${NC}"
        echo ""
        echo -e "  ${DIM}Enter the viewkey on the gate screen to access the site.${NC}"
        echo -e "  ${DIM}Cookie lasts 24h. Logged-in WP users bypass the gate.${NC}"
    else
        echo -e "  ${BOLD}Site is now public.${NC} No viewkey required."
    fi
    echo ""
}

# =============================================================================
# geodineum env show
# =============================================================================

cmd_env_show() {
    local site_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: geodineum env show <site_id>"
                exit 0
                ;;
            -*)  log_error "Unknown option: $1"; exit 1 ;;
            *)   site_id="$1"; shift ;;
        esac
    done

    if [[ -z "$site_id" ]]; then
        log_error "Usage: geodineum env show <site_id>"
        exit 1
    fi

    local config_file
    config_file=$(find_site_config "$site_id") || {
        log_error "No config found for site '${site_id}'"
        exit 1
    }

    local current_env
    current_env=$(read_yaml_env "$config_file")
    local viewkey
    viewkey=$(read_yaml_viewkey "$config_file")
    local domain
    domain=$(echo "$site_id" | sed 's/_/./g')

    echo ""
    echo -e "  ${BOLD}Environment Status${NC}"
    echo ""
    print_kv "Site" "$site_id"
    print_kv "Domain" "$domain"
    print_kv "Config" "$config_file"
    print_kv "Environment" "$current_env"

    if [[ "$current_env" != "production" ]]; then
        local gate_status="${GREEN}GATED${NC}"
        echo -e "  ${DIM}Gate:                 ${NC} ${gate_status} (viewkey required)"

        if [[ -n "$viewkey" ]]; then
            print_kv "Viewkey" "$viewkey"
            echo ""
            echo -e "  ${DIM}Enter viewkey on the gate screen at${NC} ${CYAN}https://${domain}/${NC}"
        else
            echo -e "  ${DIM}Viewkey:              ${NC} ${YELLOW}not set${NC} (run: geodineum env viewkey ${site_id} --generate)"
        fi
    else
        echo -e "  ${DIM}Gate:                 ${NC} ${YELLOW}PUBLIC${NC} (no gate)"
    fi

    echo ""
}

# =============================================================================
# geodineum env viewkey
# =============================================================================

cmd_env_viewkey() {
    local site_id=""
    local do_generate=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --generate|-g)  do_generate=true; shift ;;
            --help|-h)
                cat << 'EOF'
Usage: geodineum env viewkey <site_id> [--generate]

Show or generate a viewkey for non-production environments.
The viewkey allows access through the environment gate without logging in.

Options:
  --generate, -g    Generate a new viewkey (replaces existing)

Examples:
  geodineum env viewkey geodineum_com              # Show current
  sudo geodineum env viewkey geodineum_com --generate  # Generate new
EOF
                exit 0
                ;;
            -*)  log_error "Unknown option: $1"; exit 1 ;;
            *)   site_id="$1"; shift ;;
        esac
    done

    if [[ -z "$site_id" ]]; then
        log_error "Usage: geodineum env viewkey <site_id> [--generate]"
        exit 1
    fi

    local config_file
    config_file=$(find_site_config "$site_id") || {
        log_error "No config found for site '${site_id}'"
        exit 1
    }

    if [[ "$do_generate" == "true" ]]; then
        local new_viewkey
        new_viewkey=$(generate_viewkey)
        write_yaml_viewkey "$config_file" "$new_viewkey" || {
            log_error "Failed to write viewkey to ${config_file}"
            exit 1
        }
        php -r "opcache_reset();" 2>/dev/null || true

        local domain
        domain=$(echo "$site_id" | sed 's/_/./g')

        echo ""
        log_success "Viewkey generated: ${new_viewkey}"
        echo ""
        echo -e "  ${BOLD}Access URL:${NC}"
        echo -e "    ${CYAN}https://${domain}/?viewkey=${new_viewkey}${NC}"
        echo ""
    else
        local viewkey
        viewkey=$(read_yaml_viewkey "$config_file")

        if [[ -n "$viewkey" ]]; then
            local domain
            domain=$(echo "$site_id" | sed 's/_/./g')
            echo ""
            print_kv "Viewkey" "$viewkey"
            echo ""
            echo -e "  ${DIM}Enter viewkey on the gate screen at${NC} ${CYAN}https://${domain}/${NC}"
            echo ""
        else
            echo ""
            log_warning "No viewkey set"
            log_info "Generate one: sudo geodineum env viewkey ${site_id} --generate"
            echo ""
        fi
    fi
}

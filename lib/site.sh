#!/bin/bash
# Commit 1.14.f: strict mode added; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — New Site Command
# =================================
# Deploys a WordPress site by wrapping gTemplate's install script
# and gNode's onboard-service.sh into a single command.
#
# Requires: common.sh sourced first
#

# =============================================================================
# geodineum new site
# =============================================================================

cmd_new_site() {
    local domain=""
    local theme=""
    local theme_path=""
    local environment="testing"
    local owner=""
    local no_ssl=false
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --theme)      theme="$2"; shift 2 ;;
            --theme-path) theme_path="$2"; shift 2 ;;
            --env)        environment="$2"; shift 2 ;;
            --owner)      owner="$2"; shift 2 ;;
            --no-ssl)     no_ssl=true; shift ;;
            --dry-run)    dry_run=true; shift ;;
            --help|-h)    usage_new_site; exit 0 ;;
            -*)           log_error "Unknown option: $1"; usage_new_site; exit 1 ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$domain" ]]; then
        log_error "Domain is required"
        usage_new_site
        exit 1
    fi

    validate_domain "$domain" || exit 1
    validate_environment "$environment" || exit 1

    local site_id
    site_id="$(domain_to_site_id "$domain")"

    # Validate the theme by locating its source (a WP theme carries a
    # style.css theme header) rather than a hardcoded name list — so any
    # installed child theme is accepted and none are enumerated here.
    if [[ -n "$theme" && -z "$theme_path" ]]; then
        local _tcap _found=""
        _tcap="g$(echo "${theme#g}" | sed 's/.*/\u&/')"
        local _tc
        for _tc in "${GEODINEUM_ROOT}/${theme}" "${GEODINEUM_ROOT}/${_tcap}"; do
            if [[ -f "${_tc}/style.css" ]] && grep -qiE '^[[:space:]]*Theme Name:' "${_tc}/style.css" 2>/dev/null; then
                _found="$_tc"; break
            fi
        done
        if [[ -z "$_found" ]]; then
            log_error "Unknown or uninstalled theme: ${theme}"
            local _avail _an
            _avail=""
            for _tc in "${GEODINEUM_ROOT}"/*/; do
                _an="$(basename "$_tc")"
                [[ -f "${_tc}style.css" ]] && grep -qiE '^[[:space:]]*Theme Name:' "${_tc}style.css" 2>/dev/null \
                    && _avail="${_avail:+$_avail, }$(echo "$_an" | tr 'A-Z' 'a-z')"
            done
            [[ -n "$_avail" ]] && log_error "Available: ${_avail}"
            exit 1
        fi
    fi

    # =================================================================
    # Banner + plan
    # =================================================================

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${BOLD}Geodineum Site Deployment${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    print_kv "Domain" "$domain"
    print_kv "Site ID" "$site_id"
    print_kv "Environment" "$environment"
    print_kv "Theme" "${theme:-gtemplate-wp (parent only)}"
    print_kv "SSL" "$(if [[ "$no_ssl" == "true" ]]; then echo "skip"; else echo "certbot"; fi)"
    [[ -n "$owner" ]] && print_kv "Owner/Tenant" "$owner"
    echo ""

    # =================================================================
    # Detect ecosystem
    # =================================================================

    log_step "Detecting Ecosystem"

    # Find gTemplate install script
    local install_script=""
    for candidate in \
        "${GTEMPLATE_PATH}/scripts/install-geodineum.sh" \
        "${GEODINEUM_ROOT}/gTemplate/scripts/install-geodineum.sh"; do
        if [[ -x "$candidate" ]]; then
            install_script="$candidate"
            break
        fi
    done

    if [[ -z "$install_script" ]]; then
        log_error "gTemplate install script not found"
        log_error "Install gTemplate first: sudo geodineum install --components gtemplate-wp"
        exit 1
    fi
    log_success "gTemplate installer: ${install_script}"

    # Find onboard-service.sh
    local onboard_script=""
    for candidate in \
        "${GNODE_SCRIPTS}/onboard-service.sh" \
        "${GEODINEUM_ROOT}/gNode/scripts/onboard-service.sh"; do
        if [[ -x "$candidate" ]]; then
            onboard_script="$candidate"
            break
        fi
    done

    if [[ -z "$onboard_script" ]]; then
        log_warning "gNode onboard-service.sh not found — will skip stream/discovery setup"
    else
        log_success "gNode onboarding: ${onboard_script}"
    fi

    # Check ValKey
    if check_valkey; then
        log_success "ValKey reachable on port ${VALKEY_PORT}"
    else
        log_warning "ValKey not reachable — ACL and stream setup may fail"
    fi

    # =================================================================
    # Dry-run summary
    # =================================================================

    if [[ "$dry_run" == "true" ]]; then
        log_step "Dry-Run Summary"
        log_dry "Run gTemplate installer for ${domain}"
        log_dry "Create ${GEODINEUM_WEB_ROOT}/${domain}/.geodineum/ (credentials, config, capabilities)"
        [[ -n "$onboard_script" ]] && log_dry "Run onboard-service.sh for ${site_id}"
        [[ -n "$owner" ]] && log_dry "Set tenant owner: ${owner}"
        echo ""
        log_info "No changes made (dry-run mode)"
        return 0
    fi

    # =================================================================
    # Step 1: WordPress deployment via gTemplate
    # =================================================================

    require_sudo "Site deployment"

    log_step "Step 1/3: WordPress Deployment"
    log_info "Delegating to gTemplate installer..."

    local wp_args=("$domain")

    if [[ -n "$theme" ]]; then
        wp_args+=(--theme "$theme")

        # Auto-detect theme path if not specified
        if [[ -z "$theme_path" ]]; then
            # Try production path first, then common locations
            for tp_candidate in \
                "${GEODINEUM_ROOT}/${theme}" \
                "${GEODINEUM_ROOT}/g$(echo "${theme#g}" | sed 's/.*/\u&/')"; do
                if [[ -d "$tp_candidate" ]]; then
                    theme_path="$tp_candidate"
                    break
                fi
            done
        fi

        if [[ -n "$theme_path" ]]; then
            wp_args+=(--theme-path "$theme_path")
        fi
    fi

    wp_args+=("$environment")

    log_detail "Running: ${install_script} ${wp_args[*]}"
    if ! "$install_script" "${wp_args[@]}"; then
        log_error "WordPress deployment failed — skipping gNode onboarding"
        log_info "Fix the issues above, then run onboarding manually:"
        log_info "  ${onboard_script:-onboard-service.sh} ${site_id} --environment ${environment}"
        exit 1
    fi

    # =================================================================
    # Step 2: Create .geodineum/ + gNode onboarding
    # =================================================================

    local wp_root="${GEODINEUM_WEB_ROOT}/${domain}"
    local geodineum_dir="${wp_root}/.geodineum"

    if [[ -n "$onboard_script" ]]; then
        log_step "Step 2/3: gNode Service Onboarding"

        # Create .geodineum/ in WordPress root
        log_info "Creating .geodineum/ in ${wp_root}..."
        create_geodineum_dir "$wp_root" "$site_id" "$environment" || {
            log_warning "Could not create .geodineum/ — continuing with onboarding"
        }

        # Generate gnode_services.yaml with WordPress defaults
        local services_yaml="${geodineum_dir}/gnode_services.yaml"
        if [[ ! -f "$services_yaml" ]] && [[ -d "$geodineum_dir" ]]; then
            # Try to find existing wp-config-geodineum.yaml for capabilities
            local wp_yaml=""
            for yp_candidate in \
                "${wp_root}/wp-config-geodineum.yaml" \
                "${GCORE_PATH}/config/geometric_topology.yaml"; do
                if [[ -f "$yp_candidate" ]]; then
                    wp_yaml="$yp_candidate"
                    break
                fi
            done

            if [[ -n "$wp_yaml" ]]; then
                local format
                format=$(detect_yaml_format "$wp_yaml" 2>/dev/null || echo "unknown")
                if [[ "$format" == "flat" ]]; then
                    # Source register.sh functions for YAML conversion
                    source "${GEODINEUM_CLI_ROOT}/lib/register.sh" 2>/dev/null || true
                    while IFS='=' read -r key val; do
                        local cap_var
                        cap_var=$(map_flat_key_to_cap "$key" 2>/dev/null || echo "")
                        [[ -n "$cap_var" ]] && export "$cap_var=$val"
                    done < <(extract_flat_capabilities "$wp_yaml")
                    CAP_ENVIRONMENT="$environment"
                    generate_services_yaml "$site_id" "$services_yaml" \
                        "WordPress site" "SERVICE" "wordpress-site" "php"
                    log_success "Generated .geodineum/gnode_services.yaml from ${wp_yaml}"
                elif [[ "$format" == "daemon" ]]; then
                    cp "$wp_yaml" "$services_yaml"
                    log_success "Copied existing capabilities to .geodineum/"
                fi
            else
                # Use WordPress preset defaults
                source "${GEODINEUM_CLI_ROOT}/lib/service.sh" 2>/dev/null || true
                apply_preset "wordpress" 2>/dev/null || true
                CAP_ENVIRONMENT="$environment"
                generate_services_yaml "$site_id" "$services_yaml" \
                    "WordPress site" "SERVICE" "wordpress-site" "php"
                log_success "Generated .geodineum/gnode_services.yaml (wordpress preset)"
            fi
        fi

        # Onboard with .geodineum/ as discovery path
        local onboard_args=("$site_id" --environment "$environment")
        [[ -d "$geodineum_dir" ]] && onboard_args+=(--yaml "$geodineum_dir")
        [[ -n "$owner" ]] && onboard_args+=(--owner "$owner")

        log_detail "Running: ${onboard_script} ${onboard_args[*]}"
        "$onboard_script" "${onboard_args[@]}" || {
            log_warning "gNode onboarding had issues — see output above"
            log_info "You can retry: ${onboard_script} ${onboard_args[*]}"
        }

        # Finalize .geodineum/ (credential symlink + .registered marker)
        finalize_geodineum_dir "$wp_root" "$site_id" "$environment" || {
            log_warning "Could not finalize .geodineum/"
        }
    else
        log_step "Step 2/3: gNode Service Onboarding (skipped)"
        log_warning "gNode not installed — skipping stream/discovery setup"
        log_info "Run later: geodineum install --components gnode-daemon"
    fi

    # =================================================================
    # Step 3: gShield security hardening
    # =================================================================

    local shield_script=""
    for candidate in \
        "${GEODINEUM_ROOT}/gShield/scripts/deploy-security.sh" \
        "${GEODINEUM_ROOT}/gShield/scripts/deploy.sh"; do
        if [[ -x "$candidate" ]]; then
            shield_script="$candidate"
            break
        fi
    done

    if [[ -n "$shield_script" ]]; then
        log_step "Step 3/3: Security Hardening (gShield)"
        log_info "Deploying .htaccess rules, upload protection, honeypot traps..."
        "$shield_script" "${GEODINEUM_WEB_ROOT}/${domain}" || {
            log_warning "gShield deployment had issues — see output above"
            log_info "Deploy manually: sudo ${shield_script} /var/www/${domain}"
        }
    else
        log_step "Step 3/3: Security Hardening (skipped)"
        log_warning "gShield not installed — deploy security manually"
        log_info "Install: sudo geodineum install --components gshield"
    fi

    # =================================================================
    # Summary
    # =================================================================

    print_summary_header "Site Deployed Successfully"

    print_kv "Domain" "$domain"
    print_kv "Site ID" "$site_id"
    print_kv "Environment" "$environment"
    print_kv "Web Root" "${GEODINEUM_WEB_ROOT}/${domain}"
    print_kv ".geodineum" "$geodineum_dir"
    print_kv "Credentials" "${geodineum_dir}/credentials/valkey_client_${site_id}.password"
    echo ""

    echo -e "  ${BOLD}Next steps:${NC}"
    if [[ "$no_ssl" == "true" ]]; then
        echo "    1. Set up SSL: sudo certbot --apache -d ${domain}"
    fi
    if [[ "$environment" == "testing" ]]; then
        echo "    - Site is in testing mode (ViewKey-gated)"
        echo "    - Promote: geodineum env set ${site_id} production"
    fi
    echo "    - Dashboard: https://${domain}/wp-admin/"
    echo "    - Info: geodineum info ${site_id}"
    echo ""
}

# =============================================================================
# Usage
# =============================================================================

usage_new_site() {
    cat << 'EOF'
Usage: geodineum new site <domain> [options]

Deploys a complete WordPress site with gNode integration:
  - WordPress + database + Apache vhost + SSL
  - gCore MU-plugin + parent theme + child theme
  - ValKey ACL user + streams + service discovery

Arguments:
  <domain>                  Domain name (e.g., example.com)

Options:
  --theme <name>            Child theme (e.g. gcube); any installed child theme
  --theme-path <path>       Custom theme source path (auto-detected if omitted)
  --env <environment>       DTAP environment (default: testing)
  --owner <tenant_id>       Tenant/owner for cross-site discovery
  --no-ssl                  Skip SSL certificate setup
  --dry-run                 Preview actions without making changes
  --help, -h                Show this help message

Examples:
  sudo geodineum new site geodineum.com --theme gcube --env production
  sudo geodineum new site test.example.com --theme gcube --env testing --no-ssl
  sudo geodineum new site myapp.com --owner acme_corp --dry-run
EOF
}

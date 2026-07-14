#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — New Service + List Commands
# =============================================
# Scaffolds a standalone gNode service with capability presets,
# bootstrap code, and automatic onboarding.
#
# Requires: common.sh sourced first
#

# =============================================================================
# Capability Presets
# =============================================================================

# Sets CAP_* variables based on template name
apply_preset() {
    local preset="$1"

    # Shared defaults
    CAP_FORMAT="json"
    CAP_STABILITY="beta"
    CAP_CLEARANCE="authenticated"
    CAP_AUTH="bearer_token"
    CAP_SENSITIVITY="internal"
    CAP_SPECIALIZATION="focused"
    CAP_THROUGHPUT="standard"
    CAP_RELIABILITY="standard"
    CAP_PIPELINE_STAGE="process"
    CAP_PRIORITY="normal"
    CAP_DOMAIN_SECONDARY="platform"

    case "$preset" in
        http-api)
            CAP_PROTOCOL="http_rest"
            CAP_SCOPE="client_facing"
            CAP_DOMAIN="content"
            CAP_LATENCY="interactive"
            SERVICE_TIER="SERVICE"
            SERVICE_DESCRIPTION="HTTP API service"
            ;;
        worker)
            CAP_PROTOCOL="gnode_stream"
            CAP_SCOPE="worker"
            CAP_DOMAIN="compute"
            CAP_LATENCY="patient"
            CAP_PRIORITY="background"
            SERVICE_TIER="SERVICE"
            SERVICE_DESCRIPTION="Background worker service"
            ;;
        inference)
            CAP_PROTOCOL="gnode_stream"
            CAP_SCOPE="daemon"
            CAP_DOMAIN="ml_inference"
            CAP_LATENCY="responsive"
            CAP_THROUGHPUT="professional"
            CAP_SPECIALIZATION="specialist"
            CAP_PRIORITY="high"
            SERVICE_TIER="SERVICE"
            SERVICE_DESCRIPTION="ML inference service"
            ;;
        pipeline-ingest)
            CAP_PROTOCOL="http_rest"
            CAP_SCOPE="worker"
            CAP_DOMAIN="integration"
            CAP_LATENCY="patient"
            CAP_PIPELINE_STAGE="ingest"
            CAP_PRIORITY="normal"
            SERVICE_TIER="PIPELINE"
            SERVICE_DESCRIPTION="Data ingest pipeline"
            ;;
        wordpress)
            CAP_PROTOCOL="http_rest"
            CAP_SCOPE="client_facing"
            CAP_DOMAIN="content"
            CAP_DOMAIN_SECONDARY="template"
            CAP_LATENCY="responsive"
            CAP_THROUGHPUT="professional"
            CAP_RELIABILITY="high"
            CAP_STABILITY="stable"
            CAP_CLEARANCE="public"
            CAP_AUTH="session_cookie"
            CAP_SPECIALIZATION="generalist"
            CAP_PIPELINE_STAGE="deliver"
            SERVICE_TIER="SERVICE"
            SERVICE_DESCRIPTION="WordPress site"
            ;;
        *)
            log_error "Unknown preset: ${preset}"
            log_error "Available: http-api, worker, inference, wordpress"
            exit 1
            ;;
    esac
}

# render_template is defined in common.sh

# =============================================================================
# geodineum new service
# =============================================================================

cmd_new_service() {
    local name=""
    local lang="php"
    local template="http-api"
    local service_path=""
    local environment="testing"
    local owner=""
    local dry_run=false
    local use_gcore=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang)     lang="$2"; shift 2 ;;
            --template) template="$2"; shift 2 ;;
            --path)     service_path="$2"; shift 2 ;;
            --env)      environment="$2"; shift 2 ;;
            --owner)    owner="$2"; shift 2 ;;
            --gcore)    use_gcore=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --help|-h)  usage_new_service; exit 0 ;;
            -*)         log_error "Unknown option: $1"; usage_new_service; exit 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate
    if [[ -z "$name" ]]; then
        log_error "Service name is required"
        usage_new_service
        exit 1
    fi

    validate_site_id "$name" || exit 1
    validate_environment "$environment" || exit 1

    case "$lang" in
        php|python|node) ;;
        *)
            log_error "Unsupported language: ${lang}"
            log_error "Available: php, python, node"
            exit 1
            ;;
    esac

    if [[ "$use_gcore" == "true" ]] && [[ "$lang" != "php" ]]; then
        log_error "--gcore requires --lang php (gCore is a PHP framework)"
        exit 1
    fi

    # Set paths and variables
    service_path="${service_path:-${GEODINEUM_ROOT}/services/${name}}"

    # Export variables for template rendering
    SERVICE_NAME="$name"
    SERVICE_ID="${name}"
    SITE_ID="${name}"
    SERVICE_LANG="$lang"
    SERVICE_ENV="$environment"
    TEMPLATE_NAME="$template"

    # Apply capability preset
    apply_preset "$template"

    local templates_dir="${GEODINEUM_CLI_ROOT}/templates"

    # =================================================================
    # Banner + plan
    # =================================================================

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${BOLD}Geodineum Service Scaffold${NC}                             ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    print_kv "Service" "$name"
    print_kv "Language" "$lang"
    print_kv "Template" "$template"
    [[ "$use_gcore" == "true" ]] && print_kv "Bootstrap" "gCore framework (standalone)"
    print_kv "Tier" "$SERVICE_TIER"
    print_kv "Environment" "$environment"
    print_kv "Path" "$service_path"
    [[ -n "$owner" ]] && print_kv "Owner/Tenant" "$owner"
    echo ""

    # =================================================================
    # Pre-flight checks
    # =================================================================

    log_step "Pre-flight Checks"

    if [[ -d "$service_path" ]]; then
        log_warning "Directory already exists: ${service_path}"
        log_info "Existing files will not be overwritten"
    fi

    require_gnode

    if [[ "$use_gcore" == "true" ]]; then
        if [[ -f "${GEODINEUM_ROOT}/gCore/gcore-standalone.php" ]]; then
            log_success "gCore standalone entry found"
        else
            log_warning "gCore not found at ${GEODINEUM_ROOT}/gCore — bootstrap will fail until gCore is installed"
        fi
    fi

    if check_valkey; then
        log_success "ValKey reachable on port ${VALKEY_PORT}"
    else
        log_warning "ValKey not reachable — onboarding may fail"
    fi

    local geodineum_dir="${service_path}/.geodineum"

    # =================================================================
    # Dry-run summary
    # =================================================================

    if [[ "$dry_run" == "true" ]]; then
        log_step "Dry-Run Summary"
        log_dry "Create directory: ${service_path}/src"
        log_dry "Create .geodineum/ (credentials, config.yaml, gnode_services.yaml)"
        log_dry "Generate: src/bootstrap.${lang} (${lang} bootstrap)"
        log_dry "Generate: .env (service configuration)"
        log_dry "Run: onboard-service.sh ${name} --yaml ${geodineum_dir}"
        [[ -n "$owner" ]] && log_dry "Set tenant owner: ${owner}"
        echo ""
        log_info "No changes made (dry-run mode)"
        return 0
    fi

    # Only require sudo if the target path isn't user-writable
    local parent_dir
    parent_dir="$(dirname "$service_path")"
    if [[ ! -w "$parent_dir" ]] && [[ $EUID -ne 0 ]]; then
        require_sudo "Service scaffolding in ${service_path}"
    fi

    # =================================================================
    # Step 1/4: Create directory structure + .geodineum/
    # =================================================================

    log_step "Step 1/4: Creating Directory Structure"

    mkdir -p "${service_path}/src" || { log_error "Failed to create ${service_path}/src"; exit 1; }
    log_success "Created ${service_path}/src/"

    create_geodineum_dir "$service_path" "$name" "$environment" || {
        log_error "Failed to create .geodineum/"
        exit 1
    }

    # =================================================================
    # Step 2/4: Generate configuration and bootstrap files
    # =================================================================

    log_step "Step 2/4: Generating Configuration"

    # Unified config.yaml → .geodineum/
    SERVICE_TYPE="standalone-service"
    CAP_ENVIRONMENT="$environment"
    generate_geodineum_config "$service_path" "$name" "$environment" \
        "$SERVICE_DESCRIPTION" "$SERVICE_TYPE" "$SERVICE_TIER" "$lang"

    # gnode_services.yaml → .geodineum/
    local yaml_out="${geodineum_dir}/gnode_services.yaml"
    if [[ -f "$yaml_out" ]]; then
        log_warning "gnode_services.yaml already exists — skipping"
    else
        render_template "${templates_dir}/gnode_services.yaml.tpl" "$yaml_out" || { log_error "Failed to render gnode_services.yaml"; exit 1; }
        log_success "Generated .geodineum/gnode_services.yaml (${template} preset)"
    fi

    # Bootstrap file
    local bootstrap_ext=""
    case "$lang" in
        php)    bootstrap_ext="php" ;;
        python) bootstrap_ext="py" ;;
        node)   bootstrap_ext="js" ;;
    esac

    local bootstrap_out="${service_path}/src/bootstrap.${bootstrap_ext}"
    local bootstrap_tpl="${templates_dir}/bootstrap.${bootstrap_ext}.tpl"
    if [[ "$use_gcore" == "true" ]]; then
        bootstrap_tpl="${templates_dir}/bootstrap-gcore.php.tpl"
        GCORE_ENTRY="${GEODINEUM_ROOT}/gCore/gcore-standalone.php"
    fi

    if [[ -f "$bootstrap_out" ]]; then
        log_warning "bootstrap.${bootstrap_ext} already exists — skipping"
    elif [[ -f "$bootstrap_tpl" ]]; then
        render_template "$bootstrap_tpl" "$bootstrap_out" || { log_error "Failed to render bootstrap.${bootstrap_ext}"; exit 1; }
        log_success "Generated src/bootstrap.${bootstrap_ext}"
    else
        log_warning "No bootstrap template for ${lang} — skipping"
    fi

    # .env file
    local env_out="${service_path}/.env"
    if [[ -f "$env_out" ]]; then
        log_warning ".env already exists — skipping"
    else
        cat > "$env_out" << ENVEOF
# ${name} — Service Configuration
# Generated by: geodineum new service ${name}

GNODE_SITE_ID="${name}"
GNODE_ENVIRONMENT="${environment}"

# ValKey connection (auto-resolved from .geodineum/config.yaml)
# VALKEY_HOST="127.0.0.1"
# VALKEY_PORT="47445"
ENVEOF
        log_success "Generated .env"
    fi

    # =================================================================
    # Step 3/4: gNode onboarding
    # =================================================================

    log_step "Step 3/4: gNode Onboarding"

    local onboard_script="${GNODE_SCRIPTS}/onboard-service.sh"
    local onboard_args=("$name" --yaml "$geodineum_dir" --environment "$environment")

    [[ -n "$owner" ]] && onboard_args+=(--owner "$owner")

    log_detail "Running: ${onboard_script} ${onboard_args[*]}"
    "$onboard_script" "${onboard_args[@]}" || {
        log_warning "Onboarding had issues — see output above"
        log_info "Retry: ${onboard_script} ${onboard_args[*]}"
    }

    # =================================================================
    # Step 4/4: Finalize .geodineum/ + permissions
    # =================================================================

    log_step "Step 4/4: Finalizing"

    finalize_geodineum_dir "$service_path" "$name" "$environment" || {
        log_warning "Could not finalize .geodineum/ — credentials may not be symlinked"
    }

    # Service directory permissions (excluding .geodineum which has its own ownership)
    local svc_owner
    svc_owner=$(stat -c '%U' "$service_path" 2>/dev/null) || svc_owner="root"
    chown "${svc_owner}:geodineum" "$service_path" 2>/dev/null || true
    chown "${svc_owner}:geodineum" "${service_path}/src" 2>/dev/null || true
    chown -R "${svc_owner}:geodineum" "${service_path}/src" 2>/dev/null || true
    find "$service_path" -maxdepth 1 -type f -exec chown "${svc_owner}:geodineum" {} \; 2>/dev/null || true
    find "$service_path" -type d -exec chmod 750 {} \; 2>/dev/null || true
    find "$service_path" -type f -exec chmod 640 {} \; 2>/dev/null || true
    log_success "Permissions set: ${svc_owner}:geodineum 750/640"

    # =================================================================
    # Summary
    # =================================================================

    print_summary_header "Service Created Successfully"

    print_kv "Service" "$name"
    print_kv "Path" "$service_path"
    print_kv ".geodineum" "$geodineum_dir"
    print_kv "Config" "${geodineum_dir}/gnode_services.yaml"
    print_kv "Bootstrap" "${service_path}/src/bootstrap.${bootstrap_ext}"
    print_kv "Credentials" "${geodineum_dir}/credentials/valkey_client_${name}.password"
    echo ""

    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    1. Edit src/bootstrap.${bootstrap_ext} with your service logic"
    echo "    2. Edit .geodineum/gnode_services.yaml to refine capabilities"
    echo "    3. Daemon discovers the service within ~120s (or restart daemon)"
    echo "    4. Test: geodineum info ${name}"
    echo ""
}

# =============================================================================
# geodineum list
# =============================================================================

cmd_list() {
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=true; shift ;;
            --help|-h) echo "Usage: geodineum list [--json]"; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Find valkey-cli-secure.sh
    local cli=""
    for candidate in \
        "${GNODE_SCRIPTS}/valkey-cli-secure.sh" \
        "${GEODINEUM_ROOT}/gNode/scripts/valkey-cli-secure.sh"; do
        if [[ -x "$candidate" ]]; then
            cli="$candidate"
            break
        fi
    done

    if [[ -z "$cli" ]]; then
        log_error "valkey-cli-secure.sh not found"
        log_error "Is gNode installed?"
        exit 1
    fi

    # Query the site registry (SET, not KEYS pattern)
    local registry_keys
    registry_keys=$("$cli" SMEMBERS "gnode:sites:registry" 2>/dev/null) || {
        log_error "Failed to query ValKey — is it running?"
        exit 1
    }

    if [[ "$json_mode" == "true" ]]; then
        echo "{"
        echo "  \"sites\": ["
        local first=true
        while IFS= read -r site_id; do
            [[ -z "$site_id" ]] && continue
            local meta_key="gnode:site:${site_id}:meta"
            local data
            data=$("$cli" HGETALL "$meta_key" 2>/dev/null)

            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi

            # Parse HGETALL alternating key/value pairs into JSON
            echo -n "    {\"site_id\": \"${site_id}\""
            local field=""
            while IFS= read -r line; do
                if [[ -z "$field" ]]; then
                    field="$line"
                else
                    echo -n ", \"${field}\": \"${line}\""
                    field=""
                fi
            done <<< "$data"
            echo -n "}"
        done <<< "$registry_keys"
        echo ""
        echo "  ]"
        echo "}"
    else
        echo ""
        echo -e "${BOLD}Registered Sites & Services${NC}"
        echo -e "${DIM}─────────────────────────────────────────────────────${NC}"
        printf "  ${BOLD}%-25s %-15s %-15s${NC}\n" "SITE ID" "ENVIRONMENT" "STATUS"
        echo -e "  ${DIM}─────────────────────────────────────────────────${NC}"

        local count=0
        while IFS= read -r site_id; do
            [[ -z "$site_id" ]] && continue
            local meta_key="gnode:site:${site_id}:meta"
            local env_val status_val

            env_val=$("$cli" HGET "$meta_key" "active_environment" 2>/dev/null || echo "unknown")
            status_val=$("$cli" HGET "$meta_key" "status" 2>/dev/null || echo "unknown")

            # Color the status
            local status_colored="$status_val"
            case "$status_val" in
                active)      status_colored="${GREEN}active${NC}" ;;
                inactive)    status_colored="${YELLOW}inactive${NC}" ;;
                maintenance) status_colored="${RED}maintenance${NC}" ;;
            esac

            printf "  %-25s %-15s " "$site_id" "$env_val"
            echo -e "$status_colored"
            ((count++))
        done <<< "$registry_keys"

        if [[ $count -eq 0 ]]; then
            echo -e "  ${DIM}No services registered${NC}"
        fi
        echo ""
        echo -e "  ${DIM}${count} service(s) registered${NC}"
        echo ""
    fi
}

# =============================================================================
# Usage
# =============================================================================

usage_new_service() {
    cat << 'EOF'
Usage: geodineum new service <name> [options]

Scaffolds a standalone gNode service with:
  - Directory structure at /opt/geodineum/services/<name>/
  - gnode_services.yaml with capability preset
  - Bootstrap code in your chosen language
  - ValKey ACL user + streams + discovery registration

Arguments:
  <name>                    Service name (lowercase, a-z0-9_)

Options:
  --lang <language>         Bootstrap language: php, python, node (default: php)
  --template <preset>       Capability preset (default: http-api):
                              http-api  — REST API, client-facing, interactive latency
                              worker    — Stream-based, background processing
                              inference — ML inference, high throughput
  --path <dir>              Custom install path (default: /opt/geodineum/services/<name>)
  --env <environment>       DTAP environment (default: testing)
  --owner <tenant_id>       Tenant/owner for cross-site discovery
  --gcore                   Bootstrap with the full gCore framework via
                            gcore-standalone.php (PHP only, no WordPress)
  --dry-run                 Preview actions without making changes
  --help, -h                Show this help message

Examples:
  sudo geodineum new service my_api --lang php --template http-api
  sudo geodineum new service my_app --gcore --env production
  sudo geodineum new service ml_worker --lang python --template inference --owner acme
  sudo geodineum new service my_api --dry-run
EOF
}

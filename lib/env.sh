#!/bin/bash
set -euo pipefail

# Environment commands: change a site's DTAP environment, manage viewkeys, show the gate. Requires common.sh.

# =============================================================================
# Helpers
# =============================================================================

# Find the site's YAML config file
find_site_config() {
    local site_id="$1"
    local domain
    domain=$(echo "$site_id" | sed 's/_/./g')

    for candidate in \
        "${GEODINEUM_CONFIG_ROOT}/sites/${site_id}/config.yaml" \
        "${GEODINEUM_CONFIG_ROOT}/services/${site_id}/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/.geodineum/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/public_html/.geodineum/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/wp-config-geodineum.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/public_html/wp-config-geodineum.yaml" \
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

# Read the environment: environment.active, else metadata.environment, else GNODE_ENVIRONMENT.
read_yaml_env() {
    local config_file="$1"
    if [[ "$config_file" == *.yaml ]]; then
        local v2
        v2=$(grep -E "^\s+active:" "$config_file" 2>/dev/null | head -1 | sed 's/.*active:\s*//' | tr -d '"' | tr -d "'")
        if [[ -n "$v2" ]]; then
            echo "$v2"
            return
        fi
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

# Print "file<TAB>field" for every recorded environment value (field: a yq path or GNODE_ENVIRONMENT).
site_env_targets() {
    local site_id="$1" domain f p
    domain=$(echo "$site_id" | sed 's/_/./g')
    for f in \
        "${GEODINEUM_CONFIG_ROOT}/sites/${site_id}/config.yaml" \
        "${GEODINEUM_CONFIG_ROOT}/services/${site_id}/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/.geodineum/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/public_html/.geodineum/config.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/wp-config-geodineum.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/public_html/wp-config-geodineum.yaml" \
        "${GEODINEUM_WEB_ROOT}/${domain}/wp-config-gtemplate.yaml" \
        "${GEODINEUM_ROOT}/services/${site_id}/.geodineum/config.yaml"; do
        [[ -f "$f" ]] || continue
        for p in .environment.active .metadata.environment; do
            [[ "$(yq e "${p} | tag" "$f" 2>/dev/null)" == '!!str' ]] && printf '%s\t%s\n' "$f" "$p"
        done
    done
    f="${GEODINEUM_ROOT}/services/${site_id}/.env"
    [[ -f "$f" ]] && grep -q '^GNODE_ENVIRONMENT=' "$f" && printf '%s\t%s\n' "$f" GNODE_ENVIRONMENT
    return 0
}

# One recorded value set to new_env in a staged copy: only that line changes, or nothing does.
_stage_env_edit() {
    local staged="$1" field="$2" new_env="$3" n tmp
    tmp="${staged}.edit"
    if [[ "$field" == GNODE_ENVIRONMENT ]]; then
        sed "s/^GNODE_ENVIRONMENT=.*/GNODE_ENVIRONMENT=\"${new_env}\"/" "$staged" > "$tmp"
        [[ "$(grep -c '^GNODE_ENVIRONMENT="'"${new_env}"'"$' "$tmp")" == 1 ]] || { rm -f "$tmp"; return 1; }
    else
        # Find the line with awk: yq's `line` is offset by leading comments.
        n=$(awk -v top="${field#.}" 'BEGIN { split(top, k, "."); t = k[1]; c = k[2] }
            $0 ~ "^" t ":[[:space:]]*$" { inb = 1; next }
            inb && /^[^[:space:]#]/ { inb = 0 }
            inb && $0 ~ "^[[:space:]]+" c ":" { print NR; exit }' "$staged")
        [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
        sed "${n}s/^\([[:space:]]*[A-Za-z_]*:[[:space:]]*\)\([\"']\{0,1\}\)[A-Za-z]*\([\"']\{0,1\}\)/\1\2${new_env}\3/" "$staged" > "$tmp"
        [[ "$(yq e "${field} = \"${new_env}\"" "$staged" 2>/dev/null)" == "$(yq e '.' "$tmp" 2>/dev/null)" ]] || { rm -f "$tmp"; return 1; }
    fi
    [[ "$(diff "$staged" "$tmp" | grep -c '^[<>]')" -le 2 ]] || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$staged"
}

# Write new_env into every recorded place or none; ENV_STAGE keeps the originals for restore_site_env.
write_site_env() {
    local site_id="$1" new_env="$2" stage f field i=0 line
    stage=$(mktemp -d) || return 1
    declare -A slot=()
    while IFS=$'\t' read -r f field; do
        [[ -n "$f" ]] || continue
        if [[ -z "${slot[$f]:-}" ]]; then
            i=$((i + 1)); slot[$f]=$i
            cp -p "$f" "${stage}/orig.${i}" && cp "$f" "${stage}/new.${i}" && printf '%s\n' "$f" > "${stage}/path.${i}" || { rm -rf "$stage"; return 1; }
        fi
        _stage_env_edit "${stage}/new.${slot[$f]}" "$field" "$new_env" \
            || { log_error "Cannot set ${field} in ${f} exactly; nothing written"; rm -rf "$stage"; return 1; }
    done < <(site_env_targets "$site_id")
    (( i > 0 )) || { log_error "No environment recorded for ${site_id}"; rm -rf "$stage"; return 1; }
    for line in "${stage}"/path.*; do
        i=${line##*.}; f=$(<"$line")
        cat "${stage}/new.${i}" > "$f" || { restore_site_env "$stage"; return 1; }
        log_success "Config: ${f} → ${new_env}"
    done
    ENV_STAGE="$stage"
}

# Put every file write_site_env changed back as it was.
restore_site_env() {
    local stage="$1" line i
    [[ -d "$stage" ]] || return 0
    for line in "${stage}"/path.*; do
        [[ -e "$line" ]] || continue
        i=${line##*.}; cat "${stage}/orig.${i}" > "$(<"$line")" && log_warning "Restored $(<"$line")"
    done
    rm -rf "$stage"
}

# Update viewkey in YAML config
write_yaml_viewkey() {
    local config_file="$1"
    local viewkey="$2"

    if [[ "$config_file" == *.yaml ]]; then
        if grep -q "^\s*viewkey:" "$config_file" 2>/dev/null; then
            sed -i "s|^\(\s*viewkey:\s*\).*|\1\"${viewkey}\"|" "$config_file"
        else
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

# The ValKey site_id, as PHP's get_site_id_from_domain() builds it: '.' and '-' become '_'.
valkey_site_id() {
    printf '%s' "$1" | tr '.-' '__'
}

# valkey-cli as the site's client, else as admin; returns 2 when neither credential is readable.
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

valkey_env_reachable() {
    [[ "$(_valkey_env_cli "$1" PING 2>/dev/null)" == "PONG" ]]
}

# Stamp active_environment and clear {site_id}:config:registration, which the runtime reads the environment from.
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

# Best effort: re-register the topology entity with the new environment and notify the daemon.
reembed_dim20_and_broadcast() {
    local site_id="$1"
    local new_env="$2"
    local dcred="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey_daemon.password"
    local port="${VALKEY_PORT:-47445}"

    # Keep the entity's existing shape so only the environment changes.
    local profile="web"
    if [[ -r "$dcred" ]] && command -v python3 >/dev/null 2>&1; then
        local ns="${GNODE_TOPOLOGY_NAMESPACE:-geodineum}" entity_json detected
        entity_json=$(REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
            HGET "{${ns}}:gnode:constellation:entities" "$site_id" 2>/dev/null)
        detected=$(printf '%s' "$entity_json" | python3 -c 'import sys,json
try:
    e=json.load(sys.stdin); sh=str(e.get("sh",""))
    print({"3.1":"web","3.2":"headless","3.3":"service"}.get(sh) or (e.get("m") or {}).get("type") or "")
except Exception: print("")' 2>/dev/null)
        [[ -n "$detected" ]] && profile="$detected"
    fi

    if geodineum topology register service "$site_id" "$profile" --env "$new_env" >/dev/null 2>&1; then
        log_success "Topology: environment slot re-embedded (${profile} → ${new_env})"
    else
        log_warning "Could not re-embed the environment slot — the topology may lag active_environment"
        log_info "  Re-run: sudo geodineum topology register service ${site_id} ${profile} --env ${new_env}"
    fi

    # The intent carries the environment too; left stale, the reconciler reports drift.
    if [[ -r "$dcred" ]] && command -v python3 >/dev/null 2>&1; then
        local ins="${GNODE_TOPOLOGY_NAMESPACE:-geodineum}" intent
        intent=$(REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
            HGET "{${ins}}:gnode:registrations" "$site_id" 2>/dev/null)
        if [[ -n "$intent" ]]; then
            intent=$(printf '%s' "$intent" | NEW_ENV="$new_env" python3 -c 'import sys,json,os
i=json.load(sys.stdin); i["environment"]=os.environ["NEW_ENV"]; print(json.dumps(i,separators=(",",":")))' 2>/dev/null) || intent=""
            if [[ -n "$intent" ]] && REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
                    HSET "{${ins}}:gnode:registrations" "$site_id" "$intent" >/dev/null 2>&1; then
                log_success "Registration intent: environment → ${new_env}"
            else
                log_warning "Registration intent not updated — re-run: sudo geodineum env set ${site_id} ${new_env}"
            fi
        fi
    fi

    if [[ -r "$dcred" ]]; then
        local ts; ts=$(date +%s)
        REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
            XADD "{${site_id}}:gnode:broadcast:global" '*' \
            type environment_changed \
            data "{\"type\":\"environment_changed\",\"site_id\":\"${site_id}\",\"new_environment\":\"${new_env}\",\"timestamp\":${ts}}" \
            >/dev/null 2>&1 || true
    fi
}

# Config readers compare their APCu entry against this counter, so one bump invalidates every worker.
bump_constellation_generation() {
    local site_id="$1"
    local reason="$2"
    local dcred="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey_daemon.password"
    local port="${VALKEY_PORT:-47445}"
    if [[ ! -r "$dcred" ]]; then
        log_warning "Generation not bumped (daemon credential unreadable) — web tier serves stale config for up to 300 s"
        return 0
    fi
    local gen
    gen=$(REDISCLI_AUTH="$(cat "$dcred")" valkey-cli -p "$port" --user gnode_daemon \
        FCALL GNODE_CONSTELLATION_GENERATION_INCR 0 "$site_id" "$reason" 2>&1) || gen=""
    gen="${gen#(integer) }"
    if [[ "$gen" =~ ^[0-9]+$ ]]; then
        log_success "Constellation generation → ${gen} (APCu config invalidated on every worker)"
    else
        log_warning "Generation bump failed (${gen:-no reply}) — web tier serves stale config for up to 300 s"
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
  sudo geodineum env set example_com staging
  sudo geodineum env set example_com production
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

    local config_file
    config_file=$(find_site_config "$site_id") || {
        log_error "No config found for site '${site_id}'"
        log_info "Looked in ${GEODINEUM_WEB_ROOT}/, ${GEODINEUM_ROOT}/services/, ${GEODINEUM_CONFIG_ROOT}/sites/"
        exit 1
    }

    # Check ValKey first, so the config never changes while the runtime cache stays stale.
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
        # The runtime reads the ValKey cache, which can differ from the file: re-sync it.
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

    if [[ "$current_env" == "production" ]] && [[ "$new_env" != "production" ]]; then
        log_warning "Site will be gated behind viewkey (hidden from public)"
    fi

    if [[ "$current_env" != "production" ]] && [[ "$new_env" == "production" ]]; then
        log_warning "Site will become publicly accessible (gate removed)"
    fi

    # 1. Every file that records the environment, all or none.
    log_step "Updating Configuration"

    local env_stage
    write_site_env "$site_id" "$new_env" || exit 1
    env_stage="$ENV_STAGE"

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

    # 3. The runtime reads the environment from the ValKey cache, not the YAML.
    if update_valkey_env "$vk_site_id" "$new_env"; then
        log_success "ValKey: cache invalidated + active_environment → ${new_env}  (site_id: ${vk_site_id})"
    else
        log_error "ValKey cache invalidation FAILED — runtime still serves '${current_env}', not '${new_env}'."
        log_error "  {${vk_site_id}}:config:registration was not cleared; the config files are put back."
        restore_site_env "$env_stage"
        exit 1
    fi
    rm -rf "$env_stage"

    # 3b. Topology environment slot.
    reembed_dim20_and_broadcast "$site_id" "$new_env"

    # 3c. Cached config on every worker.
    bump_constellation_generation "$vk_site_id" "env:${new_env}"

    # 4. PHP OPcache.
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
  geodineum env viewkey example_com              # Show current
  sudo geodineum env viewkey example_com --generate  # Generate new
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

    local config_file domain_dir
    domain_dir="${GEODINEUM_WEB_ROOT}/$(echo "$site_id" | sed 's/_/./g')"
    # The gate reads wp-config-geodineum.yaml on a WordPress site; the key lives there.
    for config_file in "${domain_dir}/wp-config-geodineum.yaml" "${domain_dir}/public_html/wp-config-geodineum.yaml" ""; do
        [[ -z "$config_file" || -f "$config_file" ]] && break
    done
    [[ -n "$config_file" ]] || config_file=$(find_site_config "$site_id") || {
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

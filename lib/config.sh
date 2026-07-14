#!/bin/bash
#
# Geodineum CLI — Config Management Commands
# =============================================
# Read, write, and import service configuration via ValKey.
# Changes propagate to running services via PUBLISH notifications.
#
# Two config namespaces per service:
#   {site_id}:config:capabilities   — 23D topology dimensions (service identity)
#   {site_id}:config:app            — application config imported from service files
#
# Config authority chain:
#   WRITE: geodineum config set / geodineum config import (only writer)
#   STORE: ValKey hashes under {site_id}:config:*
#   READ:  Any service via gNode-Client or ValKey directly
#   NOTIFY: PUBLISH {site_id}:config:changed <namespace>:<key>
#
# Requires: common.sh sourced first
#

# =============================================================================
# Capability dimension schema (valid values for topology dimensions)
# =============================================================================

CAPABILITY_SCHEMA=(
    "protocol|http_rest|graphql|grpc|gnode_stream|websocket|mqtt"
    "native_format|json|xml|protobuf|msgpack|html|binary"
    "api_version|v1|v2|v3|beta|alpha|latest"
    "contract_stability|stable|beta|alpha|experimental|deprecated"
    "clearance_required|public|authenticated|elevated|admin|system"
    "auth_method|none|session_cookie|bearer_token|api_key|mtls|oauth2"
    "data_sensitivity|public|internal|confidential|restricted|secret"
    "service_scope|client_facing|daemon|worker|internal|partner"
    "domain_primary|content|compute|ml_inference|integration|storage|auth|payment|communication"
    "domain_secondary|template|platform|data|cache|search|messaging|monitoring"
    "specialization|generalist|focused|specialist"
    "throughput_tier|minimal|standard|professional|enterprise|unlimited"
    "latency_class|interactive|responsive|patient|batch|async"
    "reliability_tier|minimal|standard|high|critical"
    "pipeline_stage|ingest|transform|process|deliver|archive"
    "execution_priority|background|low|normal|high|critical"
    "service_tier|TOOL|SERVICE|PIPELINE|INFRASTRUCTURE|ORCHESTRATOR"
    "environment|testing|staging|acceptance|production"
)

get_valid_values() {
    local dim="$1"
    for entry in "${CAPABILITY_SCHEMA[@]}"; do
        local name="${entry%%|*}"
        if [[ "$name" == "$dim" ]]; then
            echo "${entry#*|}" | tr '|' ' '
            return 0
        fi
    done
    return 1
}

validate_capability_value() {
    local dim="$1"
    local val="$2"
    local valid
    valid=$(get_valid_values "$dim") || return 0  # unknown dim — allow any value
    for v in $valid; do
        [[ "$v" == "$val" ]] && return 0
    done
    log_error "Invalid value '${val}' for dimension '${dim}'"
    log_error "Valid values: ${valid}"
    return 1
}

# =============================================================================
# Config file scanning & parsing (YAML, INI, TOML, PHP, dotenv)
# =============================================================================

# Scan a service root for config files.
# Args: path [depth] [extra_includes] [extra_excludes] [include_env]
# Extra includes/excludes are comma-separated glob patterns.
scan_config_files() {
    local path="$1"
    local max_depth="${2:-3}"
    local extra_includes="${3:-}"
    local extra_excludes="${4:-}"
    local include_env="${5:-false}"

    # Build the include pattern string for eval
    local name_expr='-name "*.yaml" -o -name "*.yml" -o -name "*.ini" -o -name "*.conf" -o -name "*.toml" -o -name "wp-config.php" -o -name "config.php"'
    [[ "$include_env" == "true" ]] && name_expr="${name_expr} -o -name \"*.env\""

    if [[ -n "$extra_includes" ]]; then
        IFS=',' read -ra extra_pats <<< "$extra_includes"
        for pat in "${extra_pats[@]}"; do
            pat=$(echo "$pat" | tr -d ' ')
            [[ -n "$pat" ]] && name_expr="${name_expr} -o -name \"${pat}\""
        done
    fi

    # Build exclude expression
    local excl_expr='-not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.geodineum/*" -not -path "*/target/*" -not -path "*/__pycache__/*" -not -name "docker-compose*" -not -name "*.lock"'

    if [[ -n "$extra_excludes" ]]; then
        IFS=',' read -ra excl_pats <<< "$extra_excludes"
        for pat in "${excl_pats[@]}"; do
            pat=$(echo "$pat" | tr -d ' ')
            [[ -n "$pat" ]] && excl_expr="${excl_expr} -not -name \"${pat}\""
        done
    fi

    eval "find \"$path\" -maxdepth $max_depth -type f \\( $name_expr \\) $excl_expr 2>/dev/null" | sort
}

# Parse a YAML file into flat key=value pairs (section.key format)
# Only handles simple key: value and one-level nesting.
parse_yaml_to_kv() {
    local file="$1"
    local prefix="${2:-}"
    local current_section=""

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Remove inline comments
        line=$(echo "$line" | sed 's/\s*#.*//')

        # Detect section (no leading whitespace, ends with colon, no value)
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]*$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Detect top-level key: value (no leading whitespace)
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]+(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val=$(echo "$val" | tr -d '"' | tr -d "'")
            [[ -z "$val" ]] && continue
            if [[ -n "$prefix" ]]; then
                echo "${prefix}.${key}=${val}"
            else
                echo "${key}=${val}"
            fi
            current_section=""
            continue
        fi

        # Detect nested key: value (leading whitespace, under a section)
        if [[ -n "$current_section" ]] && [[ "$line" =~ ^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]+(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val=$(echo "$val" | tr -d '"' | tr -d "'")
            [[ -z "$val" ]] && continue
            if [[ -n "$prefix" ]]; then
                echo "${prefix}.${current_section}.${key}=${val}"
            else
                echo "${current_section}.${key}=${val}"
            fi
            continue
        fi
    done < "$file"
}

# Parse an INI file into flat key=value pairs (section.key format)
parse_ini_to_kv() {
    local file="$1"
    local prefix="${2:-}"
    local current_section="general"

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*[#\;] ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Detect [section]
        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\] ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Detect key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_.-]*)([[:space:]]*=[[:space:]]*)(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[3]}"
            val=$(echo "$val" | tr -d '"' | tr -d "'")
            [[ -z "$val" ]] && continue
            if [[ -n "$prefix" ]]; then
                echo "${prefix}.${current_section}.${key}=${val}"
            else
                echo "${current_section}.${key}=${val}"
            fi
        fi
    done < "$file"
}

# Parse PHP define() constants into key=value pairs.
# Handles: define('KEY', 'value'); and define('KEY', 123);
parse_php_defines_to_kv() {
    local file="$1"
    local prefix="${2:-}"

    grep -oP "define\s*\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]?([^'\")]+)['\"]?\s*\)" "$file" 2>/dev/null | \
    while IFS= read -r match; do
        local key val
        key=$(echo "$match" | grep -oP "(?<=\()['\"]([^'\"]+)['\"]" | tr -d "'" | tr -d '"')
        val=$(echo "$match" | grep -oP ",\s*['\"]?([^'\")]+)['\"]?\s*\)" | sed "s/^,\s*//" | sed "s/\s*)//" | tr -d "'" | tr -d '"')
        [[ -z "$key" || -z "$val" ]] && continue
        if [[ -n "$prefix" ]]; then
            echo "${prefix}.${key}=${val}"
        else
            echo "${key}=${val}"
        fi
    done
}

# Parse PHP array config files into key=value pairs.
# Handles: 'key' => 'value' and 'key' => 123
parse_php_array_to_kv() {
    local file="$1"
    local prefix="${2:-}"

    grep -oP "['\"]([a-zA-Z_][a-zA-Z0-9_]*)['\"]\\s*=>\\s*['\"]?([^'\",\\)]+)['\"]?" "$file" 2>/dev/null | \
    while IFS= read -r match; do
        local key val
        key=$(echo "$match" | grep -oP "^['\"]([^'\"]+)['\"]" | tr -d "'" | tr -d '"')
        val=$(echo "$match" | grep -oP "=>\\s*['\"]?([^'\",]+)" | sed "s/^=>\\s*//" | tr -d "'" | tr -d '"' | sed 's/\s*$//')
        [[ -z "$key" || -z "$val" ]] && continue
        # Skip array/closure values
        [[ "$val" == *"["* || "$val" == *"function"* || "$val" == *"=>"* ]] && continue
        if [[ -n "$prefix" ]]; then
            echo "${prefix}.${key}=${val}"
        else
            echo "${key}=${val}"
        fi
    done
}

# Parse TOML files into key=value pairs.
# Handles: key = "value", [section], key = 123, key = true
parse_toml_to_kv() {
    local file="$1"
    local prefix="${2:-}"
    local current_section=""

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Detect [section] or [section.subsection]
        if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\] ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        # Detect key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val=$(echo "$val" | tr -d '"' | tr -d "'")
            # Skip array/table values
            [[ "$val" == "["* ]] && continue
            [[ -z "$val" ]] && continue

            local full_key="$key"
            [[ -n "$current_section" ]] && full_key="${current_section}.${key}"
            if [[ -n "$prefix" ]]; then
                echo "${prefix}.${full_key}=${val}"
            else
                echo "${full_key}=${val}"
            fi
        fi
    done < "$file"
}

# Parse dotenv files into key=value pairs.
parse_dotenv_to_kv() {
    local file="$1"
    local prefix="${2:-}"

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # Match KEY=value (with optional export prefix)
        if [[ "$line" =~ ^(export[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[2]}"
            local val="${BASH_REMATCH[3]}"
            val=$(echo "$val" | tr -d '"' | tr -d "'")
            [[ -z "$val" ]] && continue
            if [[ -n "$prefix" ]]; then
                echo "${prefix}.${key}=${val}"
            else
                echo "${key}=${val}"
            fi
        fi
    done < "$file"
}

# Route a file to the appropriate parser based on extension and content.
# Handles unreadable files gracefully (returns empty).
parse_config_file() {
    local file="$1"
    local prefix="${2:-}"

    # Skip unreadable files
    if [[ ! -r "$file" ]]; then
        return 0
    fi

    case "$file" in
        *.yaml|*.yml)
            parse_yaml_to_kv "$file" "$prefix"
            ;;
        *.ini|*.conf)
            parse_ini_to_kv "$file" "$prefix"
            ;;
        *.toml)
            parse_toml_to_kv "$file" "$prefix"
            ;;
        *.env|*.env.*)
            parse_dotenv_to_kv "$file" "$prefix"
            ;;
        *.php)
            # Try define() first, then array syntax
            local defines
            defines=$(parse_php_defines_to_kv "$file" "$prefix" 2>/dev/null) || defines=""
            if [[ -n "$defines" ]]; then
                echo "$defines"
            else
                parse_php_array_to_kv "$file" "$prefix" 2>/dev/null || true
            fi
            ;;
    esac
}

# =============================================================================
# Config Schema — type inference and generation
# =============================================================================

# Infer the type of a config value.
infer_value_type() {
    local val="$1"
    # Boolean
    case "${val,,}" in
        true|false|yes|no|on|off|1|0)
            echo "boolean"
            return 0
            ;;
    esac
    # Integer
    if [[ "$val" =~ ^-?[0-9]+$ ]]; then
        echo "integer"
        return 0
    fi
    # Float
    if [[ "$val" =~ ^-?[0-9]+\.[0-9]+$ ]]; then
        echo "float"
        return 0
    fi
    # URL
    if [[ "$val" =~ ^https?:// ]]; then
        echo "url"
        return 0
    fi
    # Path
    if [[ "$val" == /* ]] || [[ "$val" == ./* ]]; then
        echo "path"
        return 0
    fi
    # Email
    if [[ "$val" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo "email"
        return 0
    fi
    echo "string"
}

# Infer the section/group for a config key based on its namespace.
infer_section() {
    local key="$1"
    # Use the second segment if prefixed (e.g., wp-config.capabilities.protocol → capabilities)
    local parts
    IFS='.' read -ra parts <<< "$key"
    if [[ ${#parts[@]} -ge 3 ]]; then
        echo "${parts[1]}"
    elif [[ ${#parts[@]} -ge 2 ]]; then
        echo "${parts[0]}"
    else
        echo "general"
    fi
}

# Extract the short key name (last segment).
short_key() {
    local key="$1"
    echo "${key##*.}"
}

# Generate a config-schema.yaml from scanned key-value pairs.
# Input: array of "key=value" strings via all_kvs global.
# Output: YAML schema file.
generate_config_schema() {
    local output_file="$1"
    local site_id="$2"
    local -n kvs_ref=$3  # nameref to array

    cat > "$output_file" << 'SCHEMAHEAD'
# =============================================================================
# Geodineum Config Schema
# =============================================================================
# Describes the configurable options for this service.
# The CLI uses this to validate values, show descriptions, and present options.
#
# Developers: add your service's config options here so they appear in
#   geodineum config list <site_id>
#   geodineum config set <site_id> <key> <value>
#
# Type reference:
#   string    — free-form text
#   integer   — whole number (optional min/max)
#   float     — decimal number (optional min/max)
#   boolean   — true/false
#   enum      — one of a fixed set of values (list in 'values')
#   url       — URL string
#   path      — filesystem path
#   email     — email address
#
# Each option can have:
#   type:         (required) value type
#   default:      (optional) default value
#   description:  (optional) human-readable description
#   section:      (optional) grouping for display
#   values:       (required for enum) list of valid values
#   min/max:      (optional for integer/float) bounds
#   sensitive:    (optional) if true, value is masked in output
#   restart:      (optional) if true, requires service restart to take effect
# =============================================================================

SCHEMAHEAD

    echo "schema_version: \"1.0.0\"" >> "$output_file"
    echo "site_id: \"${site_id}\"" >> "$output_file"
    echo "" >> "$output_file"
    echo "options:" >> "$output_file"

    # Track sections for grouping
    local prev_section=""

    for kv in "${kvs_ref[@]}"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        local vtype section skey

        vtype=$(infer_value_type "$val")
        section=$(infer_section "$key")
        skey=$(short_key "$key")

        # Section comment
        if [[ "$section" != "$prev_section" ]]; then
            echo "" >> "$output_file"
            echo "  # --- ${section} ---" >> "$output_file"
            prev_section="$section"
        fi

        echo "  ${key}:" >> "$output_file"
        echo "    type: ${vtype}" >> "$output_file"
        echo "    default: \"${val}\"" >> "$output_file"
        echo "    description: \"\"" >> "$output_file"
        echo "    section: ${section}" >> "$output_file"

        # For booleans, suggest enum-like values
        if [[ "$vtype" == "boolean" ]]; then
            echo "    values: [true, false]" >> "$output_file"
        fi
    done

    chmod 640 "$output_file" 2>/dev/null || true
}

# Read a config-schema.yaml and return info about a specific key.
# Returns: type|default|description|section|values
schema_lookup() {
    local schema_file="$1"
    local lookup_key="$2"

    [[ ! -f "$schema_file" ]] && return 1

    local in_key=false
    local s_type="" s_default="" s_desc="" s_section="" s_values=""

    while IFS= read -r line; do
        # Match the key header (2-space indent, key followed by colon)
        if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z_][a-zA-Z0-9_./-]*):[[:space:]]*$ ]]; then
            if [[ "$in_key" == "true" ]]; then
                # We were in our key and hit the next one — done
                break
            fi
            if [[ "${BASH_REMATCH[1]}" == "$lookup_key" ]]; then
                in_key=true
            fi
            continue
        fi

        if [[ "$in_key" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+type:[[:space:]]+(.+)$ ]]; then
                s_type="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+default:[[:space:]]+(.+)$ ]]; then
                s_default=$(echo "${BASH_REMATCH[1]}" | tr -d '"')
            elif [[ "$line" =~ ^[[:space:]]+description:[[:space:]]+(.+)$ ]]; then
                s_desc=$(echo "${BASH_REMATCH[1]}" | tr -d '"')
            elif [[ "$line" =~ ^[[:space:]]+section:[[:space:]]+(.+)$ ]]; then
                s_section="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+values:[[:space:]]+\[(.+)\]$ ]]; then
                s_values="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$schema_file"

    [[ "$in_key" != "true" ]] && return 1
    echo "${s_type}|${s_default}|${s_desc}|${s_section}|${s_values}"
    return 0
}

# Filter out sensitive-looking keys.
# Matches common secret patterns but avoids false positives on config dimension names
# like auth_method, api_version, clearance_required, etc.
is_sensitive_key() {
    local key="$1"
    local lower
    lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *password*|*passwd*|*secret*|*_token|*_token.*|*.token|*credential*|*private_key*|*apikey*|*api_key*|*access_key*|*secret_key*)
            return 0  # true — is sensitive
            ;;
    esac
    return 1  # false — not sensitive
}

# =============================================================================
# ValKey helpers
# =============================================================================

valkey_cmd() {
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
        log_error "valkey-cli-secure.sh not found — is gNode installed?"
        return 1
    fi

    "$cli" "$@"
}

# =============================================================================
# geodineum config set <site_id> <key> <value>
# =============================================================================

cmd_config_set() {
    local site_id=""
    local key=""
    local value=""
    local namespace="auto"
    local sync_yaml=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace) namespace="$2"; shift 2 ;;
            --sync-yaml) sync_yaml=true; shift ;;
            --help|-h)   usage_config_set; exit 0 ;;
            -*)          log_error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$site_id" ]]; then
                    site_id="$1"
                elif [[ -z "$key" ]]; then
                    key="$1"
                elif [[ -z "$value" ]]; then
                    value="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$site_id" || -z "$key" || -z "$value" ]]; then
        log_error "Usage: geodineum config set <site_id> <key> <value>"
        exit 1
    fi

    validate_site_id "$site_id" || exit 1

    # Auto-detect namespace: if it's a known capability dimension → capabilities, else → app
    local hash_key
    if [[ "$namespace" == "auto" ]]; then
        if get_valid_values "$key" >/dev/null 2>&1; then
            namespace="capabilities"
        else
            namespace="app"
        fi
    fi

    case "$namespace" in
        capabilities|cap)
            hash_key="{${site_id}}:config:capabilities"
            validate_capability_value "$key" "$value" || exit 1
            ;;
        app|application)
            hash_key="{${site_id}}:config:app"
            ;;
        *)
            hash_key="{${site_id}}:config:${namespace}"
            ;;
    esac

    # Validate against schema if available
    if [[ "$namespace" == "app" ]]; then
        local gdir
        gdir=$(find_geodineum_dir "$site_id" 2>/dev/null) || gdir=""
        local schema_file="${gdir}/config-schema.yaml"
        if [[ -f "$schema_file" ]]; then
            local schema_info
            schema_info=$(schema_lookup "$schema_file" "$key" 2>/dev/null) || schema_info=""
            if [[ -n "$schema_info" ]]; then
                local s_type s_values
                s_type=$(echo "$schema_info" | cut -d'|' -f1)
                s_values=$(echo "$schema_info" | cut -d'|' -f5)
                # Validate enum values
                if [[ -n "$s_values" ]]; then
                    local valid=false
                    IFS=', ' read -ra vals <<< "$s_values"
                    for v in "${vals[@]}"; do
                        v=$(echo "$v" | tr -d ' ')
                        [[ "$v" == "$value" ]] && valid=true
                    done
                    if [[ "$valid" != "true" ]]; then
                        log_warning "Value '${value}' not in schema values: ${s_values}"
                        log_info "Setting anyway — edit config-schema.yaml to update valid values"
                    fi
                fi
                # Validate integer
                if [[ "$s_type" == "integer" ]] && ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
                    log_warning "Schema expects integer for '${key}', got '${value}'"
                fi
            fi
        fi
    fi

    # Set in ValKey
    local result
    result=$(valkey_cmd HSET "$hash_key" "$key" "$value" 2>&1) || {
        log_error "Failed to set config in ValKey: ${result}"
        exit 1
    }

    # Publish change notification
    valkey_cmd PUBLISH "{${site_id}}:config:changed" "${namespace}:${key}" >/dev/null 2>&1 || true

    log_success "Set ${namespace}/${key} = ${value} for ${site_id}"
    log_detail "ValKey: HSET ${hash_key} ${key} ${value}"

    # Optionally sync to .geodineum/gnode_services.yaml (capabilities only)
    if [[ "$sync_yaml" == "true" ]] && [[ "$namespace" == "capabilities" ]]; then
        local gdir
        gdir=$(find_geodineum_dir "$site_id" 2>/dev/null) || gdir=""
        if [[ -n "$gdir" ]] && [[ -f "${gdir}/gnode_services.yaml" ]]; then
            local yaml_file="${gdir}/gnode_services.yaml"
            if grep -q "name: \"${key}\"" "$yaml_file" 2>/dev/null; then
                awk -v name="$key" -v val="$value" '
                    /name:/ && index($0, "\"" name "\"") {
                        print; getline;
                        sub(/value: *"[^"]*"/, "value: \"" val "\"");
                        print; next
                    }
                    { print }
                ' "$yaml_file" > "${yaml_file}.tmp" && mv "${yaml_file}.tmp" "$yaml_file"
                log_success "Synced to ${yaml_file}"
            fi
        fi
    fi

    echo ""
    log_info "Services pick up changes via ConfigWatcher"
}

# =============================================================================
# geodineum config get <site_id> [key]
# =============================================================================

cmd_config_get() {
    local site_id=""
    local key=""
    local namespace=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace) namespace="$2"; shift 2 ;;
            --help|-h) usage_config_get; exit 0 ;;
            -*)        log_error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$site_id" ]]; then
                    site_id="$1"
                elif [[ -z "$key" ]]; then
                    key="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$site_id" ]]; then
        log_error "Usage: geodineum config get <site_id> [key] [--namespace app|capabilities]"
        exit 1
    fi

    validate_site_id "$site_id" || exit 1

    # If no namespace specified, search both
    local namespaces=("capabilities" "app")
    [[ -n "$namespace" ]] && namespaces=("$namespace")

    if [[ -n "$key" ]]; then
        # Get single value — check each namespace
        for ns in "${namespaces[@]}"; do
            local hash_key="{${site_id}}:config:${ns}"
            local result
            result=$(valkey_cmd HGET "$hash_key" "$key" 2>&1)
            if [[ -n "$result" ]] && [[ "$result" != "(nil)" ]]; then
                echo "${ns}/${key}: ${result}"
                return 0
            fi
        done
        log_warning "No value for '${key}' on ${site_id}"
    else
        # Get all values from all namespaces
        for ns in "${namespaces[@]}"; do
            local hash_key="{${site_id}}:config:${ns}"
            local result
            result=$(valkey_cmd HGETALL "$hash_key" 2>&1) || continue
            [[ -z "$result" ]] && continue

            echo -e "\n${BOLD}${ns}${NC} (${hash_key})"
            echo -e "${DIM}─────────────────────────────────────────────${NC}"

            local field=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ -z "$field" ]]; then
                    field="$line"
                else
                    printf "  ${DIM}%-30s${NC} %s\n" "${field}:" "$line"
                    field=""
                fi
            done <<< "$result"
        done
        echo ""
    fi
}

# =============================================================================
# geodineum config list <site_id>
# =============================================================================

cmd_config_list() {
    local site_id=""
    local json_mode=false
    local show_schema=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)   json_mode=true; shift ;;
            --schema) show_schema=true; shift ;;
            --help|-h) usage_config_list; exit 0 ;;
            -*)       log_error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$site_id" ]]; then
                    site_id="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Schema mode
    if [[ "$show_schema" == "true" ]]; then
        echo -e "${BOLD}Topology Capability Dimensions${NC}"
        echo -e "${DIM}═══════════════════════════════════════════════════════════════${NC}"
        for entry in "${CAPABILITY_SCHEMA[@]}"; do
            local name="${entry%%|*}"
            local values="${entry#*|}"
            printf "  ${BOLD}%-24s${NC} %s\n" "$name" "$(echo "$values" | tr '|' ', ')"
        done
        echo ""
        echo -e "${DIM}Application config keys are free-form (imported from service config files).${NC}"
        echo ""
        return 0
    fi

    if [[ -z "$site_id" ]]; then
        log_error "Usage: geodineum config list <site_id> [--json] [--schema]"
        exit 1
    fi

    validate_site_id "$site_id" || exit 1

    local cap_key="{${site_id}}:config:capabilities"
    local app_key="{${site_id}}:config:app"

    local cap_data app_data
    cap_data=$(valkey_cmd HGETALL "$cap_key" 2>&1) || cap_data=""
    app_data=$(valkey_cmd HGETALL "$app_key" 2>&1) || app_data=""

    local gdir
    gdir=$(find_geodineum_dir "$site_id" 2>/dev/null) || gdir=""

    if [[ "$json_mode" == "true" ]]; then
        echo "{"
        echo "  \"site_id\": \"${site_id}\","

        # Capabilities
        echo "  \"capabilities\": {"
        local field="" first=true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ -z "$field" ]]; then
                field="$line"
            else
                [[ "$first" == "true" ]] && first=false || echo ","
                echo -n "    \"${field}\": \"${line}\""
                field=""
            fi
        done <<< "$cap_data"
        echo ""
        echo "  },"

        # App config
        echo "  \"app\": {"
        field="" first=true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ -z "$field" ]]; then
                field="$line"
            else
                [[ "$first" == "true" ]] && first=false || echo ","
                echo -n "    \"${field}\": \"${line}\""
                field=""
            fi
        done <<< "$app_data"
        echo ""
        echo "  },"

        echo "  \"geodineum_dir\": \"${gdir:-not found}\""
        echo "}"
    else
        echo ""
        echo -e "${BOLD}Config: ${site_id}${NC}"
        echo -e "${DIM}═══════════════════════════════════════════════════════${NC}"

        # Capabilities
        echo ""
        echo -e "  ${BOLD}Topology Capabilities${NC} (${cap_key})"
        echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
        if [[ -n "$cap_data" ]]; then
            local field=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ -z "$field" ]]; then
                    field="$line"
                else
                    printf "  ${DIM}%-30s${NC} %s\n" "${field}:" "$line"
                    field=""
                fi
            done <<< "$cap_data"
        else
            echo -e "  ${DIM}(none)${NC}"
        fi

        # App config (with schema descriptions if available)
        local schema_file=""
        [[ -n "$gdir" ]] && schema_file="${gdir}/config-schema.yaml"

        echo ""
        echo -e "  ${BOLD}Application Config${NC} (${app_key})"
        echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
        if [[ -n "$app_data" ]]; then
            local field=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ -z "$field" ]]; then
                    field="$line"
                else
                    local desc_suffix=""
                    # Look up description in schema
                    if [[ -f "$schema_file" ]]; then
                        local schema_info
                        schema_info=$(schema_lookup "$schema_file" "$field" 2>/dev/null) || schema_info=""
                        if [[ -n "$schema_info" ]]; then
                            local s_desc
                            s_desc=$(echo "$schema_info" | cut -d'|' -f3)
                            [[ -n "$s_desc" ]] && desc_suffix=" ${DIM}# ${s_desc}${NC}"
                        fi
                    fi
                    printf "  ${DIM}%-30s${NC} %s" "${field}:" "$line"
                    [[ -n "$desc_suffix" ]] && echo -en "$desc_suffix"
                    echo ""
                    field=""
                fi
            done <<< "$app_data"
        else
            echo -e "  ${DIM}(none — run: geodineum config import ${site_id})${NC}"
        fi

        # .geodineum status
        echo ""
        echo -e "  ${BOLD}.geodineum${NC}"
        echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
        if [[ -n "$gdir" ]] && [[ -d "$gdir" ]]; then
            echo -e "  ${GREEN}●${NC} ${gdir}"
            [[ -f "${gdir}/gnode_services.yaml" ]] && echo -e "  ${GREEN}●${NC} gnode_services.yaml"
            [[ -f "${gdir}/config.yaml" ]] && echo -e "  ${GREEN}●${NC} config.yaml (bootstrap)"
        else
            echo -e "  ${YELLOW}●${NC} Not found"
        fi

        echo ""
        echo -e "  ${DIM}Tip: geodineum config list --schema     (show topology dimensions)${NC}"
        echo -e "  ${DIM}      geodineum config import ${site_id}  (import app config from files)${NC}"
        echo ""
    fi
}

# =============================================================================
# geodineum config import <site_id> [--path <dir>]
# =============================================================================

cmd_config_import() {
    local site_id=""
    local scan_path=""
    local scan_depth=3
    local include_patterns=""
    local exclude_patterns=""
    local include_env=false
    local dry_run=false
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)        scan_path="$2"; shift 2 ;;
            --depth)       scan_depth="$2"; shift 2 ;;
            --include)     include_patterns="$2"; shift 2 ;;
            --exclude)     exclude_patterns="$2"; shift 2 ;;
            --include-env) include_env=true; shift ;;
            --dry-run)     dry_run=true; shift ;;
            --force)       force=true; shift ;;
            --help|-h)     usage_config_import; exit 0 ;;
            -*)            log_error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$site_id" ]]; then
                    site_id="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$site_id" ]]; then
        log_error "Usage: geodineum config import <site_id> [--path <dir>]"
        exit 1
    fi

    validate_site_id "$site_id" || exit 1

    # Resolve scan path
    if [[ -z "$scan_path" ]]; then
        scan_path=$(resolve_service_path "$site_id") || {
            # Try .geodineum parent
            local gdir
            gdir=$(find_geodineum_dir "$site_id" 2>/dev/null) || gdir=""
            if [[ -n "$gdir" ]]; then
                scan_path=$(dirname "$gdir")
            fi
        }
    fi

    if [[ -z "$scan_path" ]] || [[ ! -d "$scan_path" ]]; then
        log_error "Cannot determine service path for '${site_id}'"
        log_error "Specify --path <service_root_directory>"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${BOLD}Config Import${NC}                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_kv "Site ID" "$site_id"
    print_kv "Scan path" "$scan_path"
    print_kv "Depth" "$scan_depth"
    [[ -n "$include_patterns" ]] && print_kv "Include" "$include_patterns"
    [[ -n "$exclude_patterns" ]] && print_kv "Exclude" "$exclude_patterns"
    [[ "$include_env" == "true" ]] && print_kv ".env files" "included"
    echo ""

    # Find config files
    log_step "Scanning for config files"

    local config_files
    config_files=$(scan_config_files "$scan_path" "$scan_depth" "$include_patterns" "$exclude_patterns" "$include_env")

    if [[ -z "$config_files" ]]; then
        log_info "No config files (.yaml, .yml, .ini, .conf) found in ${scan_path}"
        return 0
    fi

    local file_count=0
    local key_count=0
    local skipped_count=0
    local hash_key="{${site_id}}:config:app"

    # Collect all key-value pairs
    local -a all_kvs=()

    while IFS= read -r config_file; do
        [[ -z "$config_file" ]] && continue
        file_count=$((file_count + 1))

        local relative_path="${config_file#${scan_path}/}"
        # Create a prefix from the filename (without extension)
        local basename_no_ext
        basename_no_ext=$(basename "$config_file" | sed 's/\.[^.]*$//')
        local prefix="$basename_no_ext"

        if [[ ! -r "$config_file" ]]; then
            log_detail "Skipping: ${relative_path} (not readable)"
            continue
        fi

        log_detail "Scanning: ${relative_path}"

        local kvs=""
        kvs=$(parse_config_file "$config_file" "$prefix")

        while IFS='=' read -r key val; do
            [[ -z "$key" || -z "$val" ]] && continue

            # Filter out sensitive keys
            if is_sensitive_key "$key"; then
                log_detail "  ${YELLOW}SKIP${NC} ${key} (sensitive)"
                skipped_count=$((skipped_count + 1))
                continue
            fi

            all_kvs+=("${key}=${val}")
            key_count=$((key_count + 1))
        done <<< "$kvs"

    done <<< "$config_files"

    echo ""
    log_info "Found: ${file_count} files, ${key_count} config keys, ${skipped_count} skipped (sensitive)"

    if [[ $key_count -eq 0 ]]; then
        log_info "Nothing to import"
        return 0
    fi

    # Show preview
    echo ""
    echo -e "  ${BOLD}Keys to import → ${hash_key}${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
    local shown=0
    for kv in "${all_kvs[@]}"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        printf "  ${DIM}%-35s${NC} %s\n" "${k}:" "$v"
        shown=$((shown + 1))
        if [[ $shown -ge 30 ]] && [[ ${#all_kvs[@]} -gt 35 ]]; then
            echo -e "  ${DIM}... and $((${#all_kvs[@]} - shown)) more${NC}"
            break
        fi
    done
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run — no changes made"
        return 0
    fi

    # Confirm unless --force
    if [[ "$force" != "true" ]]; then
        echo -en "  Import ${key_count} keys into ValKey? [${BOLD}Y${NC}/n] "
        local answer
        read -r answer < /dev/tty
        if [[ "${answer,,}" == "n" || "${answer,,}" == "no" ]]; then
            log_info "Import cancelled"
            return 0
        fi
    fi

    # Import to ValKey
    log_step "Importing to ValKey"

    local imported=0
    for kv in "${all_kvs[@]}"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        valkey_cmd HSET "$hash_key" "$k" "$v" >/dev/null 2>&1 && imported=$((imported + 1)) || {
            log_warning "Failed to set: ${k}"
        }
    done

    # Publish change notification
    valkey_cmd PUBLISH "{${site_id}}:config:changed" "app:import" >/dev/null 2>&1 || true

    # Generate config-schema.yaml in .geodineum/
    local gdir
    gdir=$(find_geodineum_dir "$site_id" 2>/dev/null) || gdir=""
    local schema_file=""
    if [[ -n "$gdir" ]] && [[ -d "$gdir" ]]; then
        schema_file="${gdir}/config-schema.yaml"
        if [[ ! -f "$schema_file" ]] || [[ "$force" == "true" ]]; then
            log_step "Generating config schema"
            generate_config_schema "$schema_file" "$site_id" all_kvs
            log_success "Generated ${schema_file}"
            log_info "Edit descriptions and types to refine — the CLI uses this for validation"
        else
            log_info "config-schema.yaml already exists (use --force to regenerate)"
        fi
    fi

    print_summary_header "Config Imported"
    print_kv "Site ID" "$site_id"
    print_kv "ValKey hash" "$hash_key"
    print_kv "Files scanned" "$file_count"
    print_kv "Keys imported" "$imported"
    print_kv "Keys skipped" "$skipped_count (sensitive)"
    [[ -n "$schema_file" ]] && print_kv "Schema" "$schema_file"
    echo ""

    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    geodineum config get ${site_id}                 # view all config"
    echo "    geodineum config set ${site_id} <key> <value>   # change a value"
    [[ -n "$schema_file" ]] && echo "    Edit ${schema_file} to add descriptions and refine types"
    echo ""
}

# =============================================================================
# Usage
# =============================================================================

usage_config_set() {
    cat << 'EOF'
Usage: geodineum config set <site_id> <key> <value> [options]

Set a config value for a site. Writes to ValKey and notifies running services.

Known topology dimensions (protocol, latency_class, etc.) are validated and
stored in the capabilities hash. All other keys go to the app config hash.

Arguments:
  <site_id>       Service identifier
  <key>           Config key (dimension name or app config key)
  <value>         New value

Options:
  --namespace <ns>  Force namespace: capabilities, app, or custom
  --sync-yaml       Also update .geodineum/gnode_services.yaml (capabilities only)
  --help, -h        Show this help

Examples:
  geodineum config set example_site throughput_tier enterprise
  geodineum config set my_api database.pool_size 20
  geodineum config set ml_worker model.batch_size 64 --namespace app
EOF
}

usage_config_get() {
    cat << 'EOF'
Usage: geodineum config get <site_id> [key] [--namespace app|capabilities]

Get config value(s) from ValKey. Searches both capabilities and app namespaces.

Examples:
  geodineum config get example_site                       # All config
  geodineum config get example_site throughput_tier        # Topology dimension
  geodineum config get example_site database.pool_size     # App config
  geodineum config get my_api --namespace app             # App config only
EOF
}

usage_config_list() {
    cat << 'EOF'
Usage: geodineum config list <site_id> [--json] [--schema]

Show all configuration for a site from ValKey and .geodineum/.

Options:
  --json          Machine-readable JSON output
  --schema        Show all available topology dimensions and valid values
  --help, -h      Show this help

Examples:
  geodineum config list example_site        # Full config overview
  geodineum config list --schema           # Show dimension schema
EOF
}

usage_config_import() {
    cat << 'EOF'
Usage: geodineum config import <site_id> [options]

Scan a service's root directory for config files and import their
key-value pairs into the service's ValKey keyspace ({site_id}:config:app).

Scanned by default: .yaml, .yml, .ini, .conf, .toml
Skipped by default: .env (opt-in with --include-env), vendor/, node_modules/
Sensitive keys (password, secret, token, etc.) are automatically skipped.

Arguments:
  <site_id>           Service identifier

Options:
  --path <dir>        Service root to scan (auto-detected if omitted)
  --depth <N>         Directory scan depth (default: 3)
  --include <globs>   Additional file patterns, comma-separated (e.g. "*.json,*.properties")
  --exclude <globs>   Skip file patterns, comma-separated (e.g. "test-*.yaml,*fixture*")
  --include-env       Also scan .env files (off by default — may contain secrets)
  --dry-run           Preview what would be imported
  --force             Skip confirmation prompt
  --help, -h          Show this help

Examples:
  geodineum config import example_site                              # Auto-detect
  geodineum config import my_api --path /opt/my-api --depth 5      # Deeper scan
  geodineum config import ml_worker --include "*.json" --dry-run   # Include JSON
  geodineum config import my_app --exclude "test-*,*fixture*"      # Skip test configs
  geodineum config import legacy_app --include-env                 # Include .env files
EOF
}

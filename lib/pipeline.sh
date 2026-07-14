#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — New Pipeline Command
# ======================================
# Creates a data pipeline — a service variant with ingest capabilities,
# source URL, and optional cron scheduling.
#
# Requires: common.sh sourced first
#

# =============================================================================
# geodineum new pipeline
# =============================================================================

cmd_new_pipeline() {
    local name=""
    local source_url=""
    local schedule="*/5 * * * *"
    local lang="python"
    local service_path=""
    local environment="testing"
    local owner=""
    local dry_run=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)   source_url="$2"; shift 2 ;;
            --schedule) schedule="$2"; shift 2 ;;
            --lang)     lang="$2"; shift 2 ;;
            --path)     service_path="$2"; shift 2 ;;
            --env)      environment="$2"; shift 2 ;;
            --owner)    owner="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --help|-h)  usage_new_pipeline; exit 0 ;;
            -*)         log_error "Unknown option: $1"; usage_new_pipeline; exit 1 ;;
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
        log_error "Pipeline name is required"
        usage_new_pipeline
        exit 1
    fi

    if [[ -z "$source_url" ]]; then
        log_error "--source <url> is required for pipelines"
        exit 1
    fi

    validate_site_id "$name" || exit 1
    validate_environment "$environment" || exit 1

    case "$lang" in
        php|python) ;;
        *)
            log_error "Pipelines support php or python (got: ${lang})"
            exit 1
            ;;
    esac

    # Set paths
    service_path="${service_path:-${GEODINEUM_ROOT}/services/${name}}"

    # =================================================================
    # Banner + plan
    # =================================================================

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${BOLD}Geodineum Data Pipeline${NC}                                ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    print_kv "Pipeline" "$name"
    print_kv "Source" "$source_url"
    print_kv "Schedule" "$schedule"
    print_kv "Language" "$lang"
    print_kv "Environment" "$environment"
    print_kv "Path" "$service_path"
    [[ -n "$owner" ]] && print_kv "Owner/Tenant" "$owner"
    echo ""

    # =================================================================
    # Pre-flight
    # =================================================================

    log_step "Pre-flight Checks"

    if [[ -d "$service_path" ]]; then
        log_warning "Directory already exists: ${service_path}"
        log_info "Existing files will not be overwritten"
    fi

    require_gnode

    if check_valkey; then
        log_success "ValKey reachable on port ${VALKEY_PORT}"
    else
        log_warning "ValKey not reachable — onboarding may fail"
    fi

    # =================================================================
    # Dry-run
    # =================================================================

    if [[ "$dry_run" == "true" ]]; then
        log_step "Dry-Run Summary"
        log_dry "Create directory: ${service_path}/{config,src}"
        log_dry "Generate: config/gnode_services.yaml (pipeline-ingest preset)"
        local dry_ext="py"; [[ "$lang" == "php" ]] && dry_ext="php"
        log_dry "Generate: src/pipeline.${dry_ext} (pipeline bootstrap with source URL)"
        log_dry "Generate: .env (pipeline configuration)"
        log_dry "Run: onboard-service.sh ${name} --yaml ${service_path}/config"
        log_dry "Install cron: ${schedule} → src/pipeline.${dry_ext}"
        [[ -n "$owner" ]] && log_dry "Set tenant owner: ${owner}"
        echo ""
        log_info "No changes made (dry-run mode)"
        return 0
    fi

    # =================================================================
    # Step 1: Scaffold using service machinery with pipeline preset
    # =================================================================

    require_sudo "Pipeline scaffolding in ${service_path}"

    log_step "Step 1/4: Creating Directory Structure"

    mkdir -p "${service_path}/config"
    mkdir -p "${service_path}/src"
    mkdir -p "${service_path}/logs"
    log_success "Created ${service_path}/{config,src,logs}"

    # =================================================================
    # Step 2: Generate pipeline-specific files
    # =================================================================

    log_step "Step 2/4: Generating Configuration"

    # Set template variables
    SERVICE_NAME="$name"
    SERVICE_ID="$name"
    SITE_ID="$name"
    SERVICE_LANG="$lang"
    SERVICE_ENV="$environment"
    TEMPLATE_NAME="pipeline-ingest"

    # Apply pipeline-ingest preset inline (avoid re-sourcing service.sh)
    CAP_FORMAT="json"
    CAP_STABILITY="beta"
    CAP_CLEARANCE="authenticated"
    CAP_AUTH="bearer_token"
    CAP_SENSITIVITY="internal"
    CAP_SPECIALIZATION="focused"
    CAP_THROUGHPUT="standard"
    CAP_RELIABILITY="standard"
    CAP_DOMAIN_SECONDARY="platform"
    CAP_PROTOCOL="http_rest"
    CAP_SCOPE="worker"
    CAP_DOMAIN="integration"
    CAP_LATENCY="patient"
    CAP_PIPELINE_STAGE="ingest"
    CAP_PRIORITY="normal"
    SERVICE_TIER="PIPELINE"
    SERVICE_DESCRIPTION="Data ingest pipeline"

    local templates_dir="${GEODINEUM_CLI_ROOT}/templates"

    # gnode_services.yaml
    local yaml_out="${service_path}/config/gnode_services.yaml"
    if [[ -f "$yaml_out" ]]; then
        log_warning "gnode_services.yaml already exists — skipping"
    else
        render_template "${templates_dir}/gnode_services.yaml.tpl" "$yaml_out" || { log_error "Failed to render YAML"; exit 1; }
        log_success "Generated config/gnode_services.yaml (pipeline-ingest preset)"
    fi

    # Pipeline script (language-specific)
    local pipeline_ext=""
    case "$lang" in
        php)    pipeline_ext="php" ;;
        python) pipeline_ext="py" ;;
    esac

    local pipeline_out="${service_path}/src/pipeline.${pipeline_ext}"
    if [[ -f "$pipeline_out" ]]; then
        log_warning "pipeline.${pipeline_ext} already exists — skipping"
    else
        generate_pipeline_script "$pipeline_out" "$lang" "$name" "$source_url" "$environment"
        log_success "Generated src/pipeline.${pipeline_ext}"
    fi

    # .env file
    local env_out="${service_path}/.env"
    if [[ -f "$env_out" ]]; then
        log_warning ".env already exists — skipping"
    else
        cat > "$env_out" << ENVEOF
# ${name} — Pipeline Configuration
# Generated by: geodineum new pipeline ${name}

GNODE_SITE_ID="${name}"
GNODE_ENVIRONMENT="${environment}"
PIPELINE_SOURCE_URL="${source_url}"
PIPELINE_SCHEDULE="${schedule}"

# ValKey connection (auto-resolved from bootstrap.env)
# VALKEY_HOST="127.0.0.1"
# VALKEY_PORT="47445"
ENVEOF
        log_success "Generated .env"
    fi

    # =================================================================
    # Step 3: gNode onboarding
    # =================================================================

    log_step "Step 3/4: gNode Onboarding"

    local onboard_script="${GNODE_SCRIPTS}/onboard-service.sh"
    local onboard_args=("$name" --yaml "${service_path}/config" --environment "$environment")

    [[ -n "$owner" ]] && onboard_args+=(--owner "$owner")

    log_detail "Running: ${onboard_script} ${onboard_args[*]}"
    "$onboard_script" "${onboard_args[@]}" || {
        log_warning "Onboarding had issues — see output above"
    }

    # =================================================================
    # Step 4: Permissions + cron
    # =================================================================

    log_step "Step 4/4: Permissions & Scheduling"

    chown -R gnode:gnode "$service_path"
    find "$service_path" -type d -exec chmod 750 {} \;
    find "$service_path" -type f -exec chmod 640 {} \;
    log_success "Permissions set: gnode:gnode 750/640"

    # Install cron job
    # Note: gnode user has /usr/sbin/nologin shell, so we use /bin/bash -c explicitly
    local cron_cmd=""
    case "$lang" in
        php)    cron_cmd="/usr/bin/php ${service_path}/src/pipeline.php" ;;
        python) cron_cmd="/usr/bin/python3 ${service_path}/src/pipeline.py" ;;
    esac

    local cron_line="${schedule} root /bin/su -s /bin/bash gnode -c '${cron_cmd}' >> ${service_path}/logs/pipeline.log 2>&1"
    local cron_file="/etc/cron.d/geodineum-${name}"

    cat > "$cron_file" << CRONEOF || { log_error "Failed to create cron file"; exit 1; }
# Geodineum pipeline: ${name}
# Generated by: geodineum new pipeline ${name}
# Source: ${source_url}
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

${cron_line}
CRONEOF
    chmod 644 "$cron_file"
    log_success "Installed cron: ${cron_file}"
    log_detail "Schedule: ${schedule}"

    # =================================================================
    # Summary
    # =================================================================

    print_summary_header "Pipeline Created Successfully"

    print_kv "Pipeline" "$name"
    print_kv "Source" "$source_url"
    print_kv "Schedule" "$schedule"
    print_kv "Path" "$service_path"
    print_kv "Script" "${service_path}/src/pipeline.${pipeline_ext}"
    print_kv "Logs" "${service_path}/logs/pipeline.log"
    print_kv "Cron" "$cron_file"
    print_kv "Credentials" "${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${name}.password"
    echo ""

    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    1. Edit src/pipeline.${pipeline_ext} with your transformation logic"
    echo "    2. Test manually: sudo -u gnode ${cron_cmd}"
    echo "    3. Monitor: tail -f ${service_path}/logs/pipeline.log"
    echo "    4. Status: geodineum status --site ${name}"
    echo ""
}

# =============================================================================
# Pipeline Script Generator
# =============================================================================

generate_pipeline_script() {
    local output="$1"
    local lang="$2"
    local name="$3"
    local source_url="$4"
    local environment="$5"

    case "$lang" in
        python)
            cat > "$output" << 'PYEOF'
#!/usr/bin/env python3
"""
__NAME__ — Data Pipeline

Generated by: geodineum new pipeline __NAME__
Source: __SOURCE_URL__

Fetches data from source, transforms it, and publishes to gNode stream.
Runs on schedule via cron.

Requires: pip install redis requests
"""

import json
import logging
import os
import sys
import time
import uuid
from pathlib import Path

import redis
import requests

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("__NAME__")


def load_config() -> dict:
    env_file = Path(__file__).parent.parent / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip().strip('"'))

    site_id = os.getenv("GNODE_SITE_ID", "__NAME__")
    return {
        "site_id": site_id,
        "environment": os.getenv("GNODE_ENVIRONMENT", "__ENV__"),
        "source_url": os.getenv("PIPELINE_SOURCE_URL", "__SOURCE_URL__"),
        "valkey_host": os.getenv("VALKEY_HOST", "127.0.0.1"),
        "valkey_port": int(os.getenv("VALKEY_PORT", "47445")),
        "cred_dir": os.getenv("GEODINEUM_CREDENTIALS_DIR", "/etc/geodineum/credentials"),
    }


def connect_valkey(config: dict) -> redis.Redis:
    kwargs = {
        "host": config["valkey_host"],
        "port": config["valkey_port"],
        "decode_responses": True,
    }
    pass_file = Path(config["cred_dir"]) / f"valkey_client_{config['site_id']}.password"
    if pass_file.exists():
        kwargs["username"] = f"gnode_client_{config['site_id']}"
        kwargs["password"] = pass_file.read_text().strip()
    return redis.Redis(**kwargs)


def fetch_data(source_url: str) -> list[dict]:
    """Fetch data from source. Customize this for your data source."""
    log.info(f"Fetching from {source_url}")
    response = requests.get(source_url, timeout=30)
    response.raise_for_status()
    data = response.json()
    # Adapt: your source may return a list, dict with 'items' key, etc.
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and "items" in data:
        return data["items"]
    return [data]


def transform(records: list[dict]) -> list[dict]:
    """Transform fetched records. Customize this for your use case."""
    # Example: pass through with timestamp
    for record in records:
        record["_ingested_at"] = time.time()
    return records


def publish(client: redis.Redis, stream: str, records: list[dict]) -> int:
    """Publish transformed records to gNode stream."""
    count = 0
    for record in records:
        cmd_id = f"ingest_{uuid.uuid4().hex[:8]}"
        client.xadd(stream, {
            "id": cmd_id,
            "cmd": "echo",
            "params": json.dumps({"data": record}),
        })
        count += 1
    return count


def main():
    config = load_config()
    client = connect_valkey(config)
    stream = f"{config['site_id']}:gnode:unified:{config['environment']}"

    try:
        records = fetch_data(config["source_url"])
        log.info(f"Fetched {len(records)} records")

        transformed = transform(records)
        log.info(f"Transformed {len(transformed)} records")

        published = publish(client, stream, transformed)
        log.info(f"Published {published} records to {stream}")

    except requests.RequestException as e:
        log.error(f"Fetch failed: {e}")
        sys.exit(1)
    except redis.RedisError as e:
        log.error(f"ValKey error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF
            # Replace placeholders
            # Escape sed special chars in variables to prevent injection
            local esc_name esc_url esc_env
            esc_name=$(printf '%s\n' "$name" | sed 's/[&/\]/\\&/g')
            esc_url=$(printf '%s\n' "$source_url" | sed 's/[&/\]/\\&/g')
            esc_env=$(printf '%s\n' "$environment" | sed 's/[&/\]/\\&/g')
            sed -i "s|__NAME__|${esc_name}|g" "$output"
            sed -i "s|__SOURCE_URL__|${esc_url}|g" "$output"
            sed -i "s|__ENV__|${esc_env}|g" "$output"
            ;;

        php)
            cat > "$output" << 'PHPEOF'
<?php
/**
 * __NAME__ — Data Pipeline
 *
 * Generated by: geodineum new pipeline __NAME__
 * Source: __SOURCE_URL__
 *
 * Fetches data from source, transforms it, and publishes to gNode stream.
 * Runs on schedule via cron.
 */

declare(strict_types=1);

// Load environment
$dotenv = __DIR__ . '/../.env';
if (file_exists($dotenv)) {
    foreach (file($dotenv, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (str_starts_with(trim($line), '#')) continue;
        if (str_contains($line, '=')) putenv(trim($line));
    }
}

$config = [
    'site_id'     => getenv('GNODE_SITE_ID') ?: '__NAME__',
    'environment' => getenv('GNODE_ENVIRONMENT') ?: '__ENV__',
    'source_url'  => getenv('PIPELINE_SOURCE_URL') ?: '__SOURCE_URL__',
    'valkey_host' => getenv('VALKEY_HOST') ?: '127.0.0.1',
    'valkey_port' => (int)(getenv('VALKEY_PORT') ?: 47445),
];

// Connect to ValKey
$credDir = getenv('GEODINEUM_CREDENTIALS_DIR') ?: '/etc/geodineum/credentials';
$passFile = "{$credDir}/valkey_client_{$config['site_id']}.password";

$redis = new Redis();
$redis->connect($config['valkey_host'], $config['valkey_port']);
if (file_exists($passFile)) {
    $redis->auth(["gnode_client_{$config['site_id']}", trim(file_get_contents($passFile))]);
}

$stream = "{$config['site_id']}:gnode:unified:{$config['environment']}";

// Fetch
echo "[" . date('Y-m-d H:i:s') . "] Fetching from {$config['source_url']}\n";
$response = @file_get_contents($config['source_url']);
if ($response === false) {
    echo "[ERROR] Fetch failed\n";
    exit(1);
}
$records = json_decode($response, true);
if (!is_array($records)) {
    $records = [$records];
}
echo "[INFO] Fetched " . count($records) . " records\n";

// Transform (customize this)
foreach ($records as &$record) {
    $record['_ingested_at'] = time();
}
unset($record);

// Publish
$count = 0;
foreach ($records as $record) {
    $redis->xAdd($stream, '*', [
        'id'     => 'ingest_' . bin2hex(random_bytes(4)),
        'cmd'    => 'echo',
        'params' => json_encode(['data' => $record]),
    ]);
    $count++;
}
echo "[INFO] Published {$count} records to {$stream}\n";
PHPEOF
            # Escape sed special chars in variables to prevent injection
            local esc_name esc_url esc_env
            esc_name=$(printf '%s\n' "$name" | sed 's/[&/\]/\\&/g')
            esc_url=$(printf '%s\n' "$source_url" | sed 's/[&/\]/\\&/g')
            esc_env=$(printf '%s\n' "$environment" | sed 's/[&/\]/\\&/g')
            sed -i "s|__NAME__|${esc_name}|g" "$output"
            sed -i "s|__SOURCE_URL__|${esc_url}|g" "$output"
            sed -i "s|__ENV__|${esc_env}|g" "$output"
            ;;
    esac
}

# =============================================================================
# Usage
# =============================================================================

usage_new_pipeline() {
    cat << 'EOF'
Usage: geodineum new pipeline <name> --source <url> [options]

Creates a data pipeline (service variant) with:
  - Ingest capability preset (pipeline_stage=ingest, domain=integration)
  - Source URL baked into the bootstrap script
  - Cron job for scheduled execution
  - Full gNode onboarding (ACL + streams + discovery)

Arguments:
  <name>                    Pipeline name (lowercase, a-z0-9_)

Required:
  --source <url>            Data source URL

Options:
  --schedule <cron>         Cron schedule (default: "*/5 * * * *")
  --lang <language>         Bootstrap language: php, python (default: python)
  --path <dir>              Custom install path (default: /opt/geodineum/services/<name>)
  --env <environment>       DTAP environment (default: testing)
  --owner <tenant_id>       Tenant/owner for cross-site discovery
  --dry-run                 Preview actions without making changes
  --help, -h                Show this help message

Examples:
  sudo geodineum new pipeline stock_feed --source https://api.example.com/feed
  sudo geodineum new pipeline logs_ingest --source https://logs.internal/api --schedule "*/1 * * * *"
  sudo geodineum new pipeline ml_data --source https://data.example.com/v2 --lang php --owner acme
EOF
}

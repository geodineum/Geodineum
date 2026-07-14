#!/bin/bash
# =============================================================================
# manifest-registry.sh — ValKey registry of resolved manifest values
# =============================================================================
# A service's `geodeploy.yaml` declares some values explicitly and inherits
# others from convention. This library publishes the RESOLVED values (override
# OR convention default) to a ValKey hash per service so downstream consumers
# (`geodineum logs <svc>`, `geodineum describe <svc>`, BAK introspection) can
# look up everything via one HGETALL without re-parsing YAML.
#
# Sourced by: geodineum (cmd_manifest_sync, cmd_describe, cmd_logs), and the
# geodeploy-orchestrator post-pull hook (D-10).
#
# Keys:
#   geodineum:registry:_index           SET of service names
#   geodineum:registry:<name>           HASH of resolved fields per service
#
# Failure model: best-effort. If ValKey is down or admin creds unreadable,
# publish silently skips — the deploy itself is not affected.
# =============================================================================

# Guard against double-sourcing
[[ -n "${_GEODINEUM_MANIFEST_REGISTRY_SH:-}" ]] && return 0
_GEODINEUM_MANIFEST_REGISTRY_SH=1

# ---- internals ---------------------------------------------------------------

_manifest_valkey_cli() {
    # Run valkey-cli as the default/admin user with the password from the
    # standard credential file. Silent + best-effort.
    local pw_file="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"
    [[ -r "$pw_file" ]] || return 1
    local pw port
    pw=$(cat "$pw_file") || return 1
    port="${VALKEY_PORT:-47445}"
    REDISCLI_AUTH="$pw" valkey-cli -p "$port" --no-auth-warning "$@"
}

_yq_get() {
    # Read a path from a YAML file with a fallback default.
    # Usage: _yq_get <file> <yq-path> <fallback>
    local f="$1" path="$2" fallback="$3"
    local v
    v=$(yq eval "$path // \"__NULL__\"" "$f" 2>/dev/null) || v="__NULL__"
    if [[ -z "$v" || "$v" == "null" || "$v" == "__NULL__" ]]; then
        printf '%s' "$fallback"
    else
        printf '%s' "$v"
    fi
}

# ---- public API --------------------------------------------------------------

# Resolve a manifest's values (override or convention default) and publish to
# ValKey as a single hash. Idempotent — calling repeatedly is safe.
# Returns 0 on publish success, 1 on validation/IO failure, silent on ValKey
# unreachable.
manifest_publish_registry() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1
    command -v yq &>/dev/null || return 1

    local name
    name=$(yq eval '.name // ""' "$manifest_path" 2>/dev/null)
    [[ -n "$name" && "$name" != "null" ]] || return 1  # silent: not a v1 manifest

    # Resolve every field — explicit value or convention default.
    local version description tier language
    version=$(_yq_get     "$manifest_path" ".version"     "0.0.0")
    description=$(_yq_get "$manifest_path" ".description" "")
    tier=$(_yq_get        "$manifest_path" ".tier"        "1")
    language=$(_yq_get    "$manifest_path" ".language"    "other")

    local log_path log_journald
    log_path=$(_yq_get     "$manifest_path" ".log.path"           "/var/log/geodineum/${name}/${name}.log")
    log_journald=$(_yq_get "$manifest_path" ".log.journald_unit"  "")

    local config_keyspace
    config_keyspace=$(_yq_get "$manifest_path" ".config.keyspace" "{site_id}:${name}:config:*")

    local auto_enabled auto_branch
    auto_enabled=$(_yq_get "$manifest_path" ".auto.enabled" "false")
    auto_branch=$(_yq_get  "$manifest_path" ".auto.branch"  "auto")

    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || echo "")

    # Publish — single HSET atomically replaces all fields. Best-effort.
    _manifest_valkey_cli SADD "geodineum:registry:_index" "$name" >/dev/null 2>&1 || return 0
    _manifest_valkey_cli HSET "geodineum:registry:${name}" \
        version           "$version" \
        description       "$description" \
        tier              "$tier" \
        language          "$language" \
        log_path          "$log_path" \
        log_journald      "$log_journald" \
        config_keyspace   "$config_keyspace" \
        auto_enabled      "$auto_enabled" \
        auto_branch       "$auto_branch" \
        manifest_path     "$manifest_path" \
        published_at      "$timestamp" \
        >/dev/null 2>&1

    return 0
}

# Scan all manifests under $GEODINEUM_ROOT and publish each. Echoes count.
manifest_publish_all() {
    local root="${GEODINEUM_ROOT:-/opt/geodineum}"
    local published=0 skipped=0
    local f
    for f in "${root}"/*/geodeploy.yaml; do
        [[ -f "$f" ]] || continue
        if manifest_publish_registry "$f"; then
            published=$((published + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
    printf 'published=%d skipped=%d\n' "$published" "$skipped"
}

# Read a single field from the registry. Echoes value or empty.
# Usage: manifest_get_field <name> <field>
manifest_get_field() {
    local name="$1" field="$2"
    _manifest_valkey_cli HGET "geodineum:registry:${name}" "$field" 2>/dev/null
}

# List all registered service names. One per line.
manifest_list_registered() {
    _manifest_valkey_cli SMEMBERS "geodineum:registry:_index" 2>/dev/null
}

# Read the full registry hash for a service. Echoes alternating key/value lines.
manifest_describe_raw() {
    local name="$1"
    _manifest_valkey_cli HGETALL "geodineum:registry:${name}" 2>/dev/null
}

# Drop a service from the registry. For deregistration.
manifest_drop_registry() {
    local name="$1"
    _manifest_valkey_cli DEL "geodineum:registry:${name}" >/dev/null 2>&1
    _manifest_valkey_cli SREM "geodineum:registry:_index" "$name" >/dev/null 2>&1
}

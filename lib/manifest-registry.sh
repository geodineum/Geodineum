#!/bin/bash
# =============================================================================
# manifest-registry.sh — ValKey registry of resolved manifest values
# =============================================================================
# geodineum:registry:<name> (HASH) and geodineum:registry:_index (SET); best-effort, never fails a deploy.
# =============================================================================

[[ -n "${_GEODINEUM_MANIFEST_REGISTRY_SH:-}" ]] && return 0
_GEODINEUM_MANIFEST_REGISTRY_SH=1

# ---- internals ---------------------------------------------------------------

_manifest_valkey_cli() {
    local pw_file="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"
    [[ -r "$pw_file" ]] || return 1
    local pw port
    pw=$(cat "$pw_file") || return 1
    port="${VALKEY_PORT:-47445}"
    REDISCLI_AUTH="$pw" valkey-cli -p "$port" --no-auth-warning "$@"
}

_yq_get() {
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

# Publish a manifest's resolved values (declared, else convention default); idempotent.
manifest_publish_registry() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1
    command -v yq &>/dev/null || return 1

    local name
    name=$(yq eval '.name // ""' "$manifest_path" 2>/dev/null)
    [[ -n "$name" && "$name" != "null" ]] || return 1  # silent: not a v1 manifest

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

# Usage: manifest_get_field <name> <field>
manifest_get_field() {
    local name="$1" field="$2"
    _manifest_valkey_cli HGET "geodineum:registry:${name}" "$field" 2>/dev/null
}

manifest_list_registered() {
    _manifest_valkey_cli SMEMBERS "geodineum:registry:_index" 2>/dev/null
}

manifest_describe_raw() {
    local name="$1"
    _manifest_valkey_cli HGETALL "geodineum:registry:${name}" 2>/dev/null
}

manifest_drop_registry() {
    local name="$1"
    _manifest_valkey_cli DEL "geodineum:registry:${name}" >/dev/null 2>&1
    _manifest_valkey_cli SREM "geodineum:registry:_index" "$name" >/dev/null 2>&1
}

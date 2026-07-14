#!/bin/bash
# =============================================================================
# manifest-policy.sh — Static policy for manifest-declared ACL grants
# =============================================================================
# v1 enforcement layer for LAYER 5 (data) of the modular manifest. Reads the
# `data.consumes` / `data.produces` sections from a service's geodeploy.yaml,
# interpolates {site_id}/{service}/{ecosystem} placeholders, and validates each
# pattern against the static namespace policy. Refused patterns abort the
# composition with a clear stderr diagnostic.
#
# Consumed by: register-site.sh (when refactored to manifest-driven mode),
# `geodineum validate` (extended), and any tooling that needs to know what
# ACL grants a manifest implies.
#
# Daemon-mediated runtime negotiation (planned) replaces the static checks with
# an FCALL → vet → ACL-SETUSER → audit flow. v1 stays static.
#
# Static policy v1 — allowed namespaces (after interpolation):
#   1. Service's own namespace:      {<site_id>}:<service>:*  and  {<site_id>}:*
#   2. Per-site gnode bus:           {<site_id>}:gnode:*
#   3. Per-site gcore config:        {<site_id>}:gcore:*
#   4. Ecosystem bus:                {<ecosystem>}:gnode:*
#   5. Shared default config space:  {default}:gnode:*  and  {default}:gcore:*
#   6. Environment-tagged streams:   {testing|staging|acceptance|production}:gnode:*
#   7. Geodineum shared topology:    {geodineum}:gnode:*
#   8. Legacy/migration alias:       gnode:*  and  topology:*  and  membership:*
#                                    template:*  and  error:<site_id>:*
#                                    cache:<site_id>:*  and  session:<site_id>:*
#
# Anything outside this set is REFUSED. No silent narrowing — refuse and fail.
# =============================================================================

# Guard against double-sourcing
[[ -n "${_GEODINEUM_MANIFEST_POLICY_SH:-}" ]] && return 0
_GEODINEUM_MANIFEST_POLICY_SH=1

# ---- Interpolation ---------------------------------------------------------

# Substitute {site_id}, {service}, {ecosystem} placeholders.
# Echoes the interpolated pattern.
# Usage: policy_interpolate <pattern> <site_id> [service-name] [ecosystem]
policy_interpolate() {
    local pattern="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-geodineum}"
    local p="$pattern"
    p="${p//\{site_id\}/${site_id}}"
    p="${p//\{service\}/${service_name}}"
    p="${p//\{ecosystem\}/${ecosystem}}"
    printf '%s' "$p"
}

# ---- Allowed prefix list ---------------------------------------------------

# Print the well-known allowed pattern prefixes (one per line, after
# interpolation). Used for prefix-matching in policy_validate_pattern.
_policy_well_known_prefixes() {
    local site_id="$1"
    local service_name="${2:-$site_id}"
    local ecosystem="${3:-geodineum}"
    cat <<EOF
{${site_id}}:${service_name}:
{${site_id}}:gnode:
{${site_id}}:gcore:
{${site_id}}:bundle:
{${site_id}}:cache:
{${site_id}}:metrics:
{${site_id}}:state:
{${site_id}}:events:
{${site_id}}:notify:
{${site_id}}:results:
{${site_id}}:
{${ecosystem}}:gnode:
{default}:gnode:
{default}:gcore:
{testing}:gnode:
{staging}:gnode:
{acceptance}:gnode:
{production}:gnode:
{geodineum}:gnode:
gnode:
gnode:routing:
topology:
template:
membership:
error:${site_id}:
cache:${site_id}:
session:${site_id}:
${site_id}:error:
${site_id}:cache:
${site_id}:session:
${site_id}:gnode:
${site_id}:
EOF
}

# ---- Validation ------------------------------------------------------------

# Validate a single (interpolated) pattern against the static policy.
# Strips ACL grammar prefixes (`~` for keys, `&` for channels) before matching.
# Returns 0 if allowed; prints a diagnostic to stderr and returns 1 if refused.
# Usage: policy_validate_pattern <interpolated-pattern> <site_id> [service] [ecosystem]
policy_validate_pattern() {
    local pattern="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-geodineum}"

    # Strip ACL grammar prefix for the namespace check.
    # `~` and `&` need character-class form ([~] / [&]) because bash performs
    # tilde-expansion inside ${var#pattern} otherwise — leaving the leading
    # `~` un-stripped (every valid pattern would then look "outside namespace").
    local p="$pattern"
    p="${p#[~]}"
    p="${p#[&]}"

    # Empty / null / wildcard-only patterns are refused (would broaden grants)
    if [[ -z "$p" || "$p" == "*" ]]; then
        echo "  POLICY DENY: empty or wildcard-all pattern: '$pattern'" >&2
        return 1
    fi

    local prefix
    while IFS= read -r prefix; do
        [[ -n "$prefix" ]] || continue
        if [[ "$p" == "$prefix"* ]]; then
            return 0
        fi
    done < <(_policy_well_known_prefixes "$site_id" "$service_name" "$ecosystem")

    echo "  POLICY DENY: pattern outside service namespace + well-known set: '$pattern'" >&2
    return 1
}

# ---- Manifest readers ------------------------------------------------------

# Extract a list field from a manifest's data section.
# Usage: policy_read_patterns <manifest_path> <yq-path>
# Echoes one pattern per line (empty output if section missing).
policy_read_patterns() {
    local manifest_path="$1" yq_path="$2"
    [[ -f "$manifest_path" ]] || return 1
    command -v yq &>/dev/null || return 1
    yq eval "${yq_path}[] // empty" "$manifest_path" 2>/dev/null
}

# ---- Grant composition -----------------------------------------------------

# Compose validated, interpolated keyspace patterns from a manifest.
# Reads .data.consumes.{streams,keys} (read-only) and .data.produces.{streams,keys}
# (read-write). v1 ValKey ACL does not distinguish RW from RO for keys at the
# pattern level, so both sets are output as `~<pattern>` prefixes; the
# distinction lives in the manifest as documentation + future audit hook.
# Echoes one ACL grant token per line (`~{site}:svc:*`). Refuses the whole
# composition on any policy violation.
# Usage: policy_compose_key_grants <manifest_path> <site_id> [service] [ecosystem]
policy_compose_key_grants() {
    local manifest_path="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-geodineum}"

    local raw interp
    local failed=0
    local out=()

    for yq_path in '.data.consumes.streams' '.data.consumes.keys' \
                   '.data.produces.streams' '.data.produces.keys'; do
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            interp=$(policy_interpolate "$raw" "$site_id" "$service_name" "$ecosystem")
            if policy_validate_pattern "$interp" "$site_id" "$service_name" "$ecosystem"; then
                out+=("~${interp}")
            else
                failed=$((failed + 1))
            fi
        done < <(policy_read_patterns "$manifest_path" "$yq_path")
    done

    # Optional well-known ecosystem grants if requested via the manifest
    if [[ "$(yq eval '.data.ecosystem_well_known // false' "$manifest_path" 2>/dev/null)" == "true" ]]; then
        # These are well-known and unconditionally allowed when explicitly opted in
        out+=("~{${site_id}}:gnode:*")
        out+=("~{${ecosystem}}:gnode:*")
        out+=("~{default}:gnode:*")
        out+=("~{default}:gcore:*")
    fi

    if [[ $failed -gt 0 ]]; then
        echo "  POLICY REFUSE: ${failed} pattern(s) violated namespace policy; ACL not composed" >&2
        return 1
    fi

    printf '%s\n' "${out[@]}"
}

# Compose validated, interpolated channel (pub/sub) grants from a manifest.
# Channels MUST be prefixed with `&` in ACL grammar; manifests declare them
# that way too, so we forward the prefix.
# Usage: policy_compose_channel_grants <manifest_path> <site_id> [service] [ecosystem]
policy_compose_channel_grants() {
    local manifest_path="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-geodineum}"

    local raw interp
    local failed=0
    local out=()

    for yq_path in '.data.consumes.channels' '.data.produces.channels'; do
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            # Strip a leading & in the raw pattern; we re-add it after interpolation
            local raw_stripped="${raw#[&]}"
            interp=$(policy_interpolate "$raw_stripped" "$site_id" "$service_name" "$ecosystem")
            if policy_validate_pattern "&${interp}" "$site_id" "$service_name" "$ecosystem"; then
                out+=("&${interp}")
            else
                failed=$((failed + 1))
            fi
        done < <(policy_read_patterns "$manifest_path" "$yq_path")
    done

    if [[ "$(yq eval '.data.ecosystem_well_known // false' "$manifest_path" 2>/dev/null)" == "true" ]]; then
        out+=("&{${ecosystem}}:gnode:broadcast:*")
    fi

    if [[ $failed -gt 0 ]]; then
        echo "  POLICY REFUSE: ${failed} channel pattern(s) violated namespace policy" >&2
        return 1
    fi

    printf '%s\n' "${out[@]}"
}

# ---- Convenience: does the manifest have a usable data section? -----------

# Returns 0 if the manifest declares at least one stream/key/channel anywhere
# in data.consumes or data.produces. Used to decide whether to engage the
# manifest-driven flow at all.
# Usage: policy_manifest_has_data <manifest_path>
policy_manifest_has_data() {
    local manifest_path="$1"
    [[ -f "$manifest_path" ]] || return 1
    command -v yq &>/dev/null || return 1
    local n
    n=$(yq eval '
        ((.data.consumes.streams // [])  | length) +
        ((.data.consumes.keys // [])     | length) +
        ((.data.consumes.channels // []) | length) +
        ((.data.produces.streams // [])  | length) +
        ((.data.produces.keys // [])     | length) +
        ((.data.produces.channels // []) | length)
    ' "$manifest_path" 2>/dev/null)
    [[ "$n" -gt 0 ]] 2>/dev/null
}

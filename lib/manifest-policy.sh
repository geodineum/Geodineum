#!/bin/bash
# =============================================================================
# manifest-policy.sh — static namespace policy for manifest-declared ACL grants
# =============================================================================
# Interpolates a manifest's consumes/produces patterns and refuses any outside the
# allowed prefixes below; one refusal aborts the whole composition.
# =============================================================================

[[ -n "${_GEODINEUM_MANIFEST_POLICY_SH:-}" ]] && return 0
_GEODINEUM_MANIFEST_POLICY_SH=1

# ---- Interpolation ---------------------------------------------------------

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

# Usage: policy_manifest_constellation <manifest_path> [default]
policy_manifest_constellation() {
    local manifest_path="$1" dflt="${2:-${GNODE_TOPOLOGY_NAMESPACE:-geodineum}}" c=""
    if [[ -f "$manifest_path" ]] && command -v yq &>/dev/null; then
        c=$(yq eval '.gnode.constellation // ""' "$manifest_path" 2>/dev/null | tr -d '"')
    fi
    [[ -n "$c" && "$c" != "null" ]] && printf '%s' "$c" || printf '%s' "$dflt"
}

# ---- Allowed prefix list ---------------------------------------------------

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
$( [[ "$ecosystem" == "geodineum" ]] && cat <<LEGACY
{default}:gnode:
{default}:gcore:
{testing}:gnode:
{staging}:gnode:
{acceptance}:gnode:
{production}:gnode:
gnode:
gnode:routing:
topology:
template:
membership:
LEGACY
)
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

# ---- Grant form ------------------------------------------------------------
# Only the daemon writes the shared topology: read-only (%R~) except the service's own heartbeat key.
# Usage: policy_key_grant_form <interpolated-pattern> <site_id> [ecosystem]
policy_key_grant_form() {
    local p="$1"
    local site_id="$2"
    local ecosystem="${3:-geodineum}"
    case "$p" in
        "{${ecosystem}}:gnode:heartbeat:"*":${site_id}:"*|"{geodineum}:gnode:heartbeat:"*":${site_id}:"*)
            printf '~%s' "$p" ;;
        "{${ecosystem}}:gnode:"*|"{geodineum}:gnode:"*)
            printf '%%R~%s' "$p" ;;
        *)
            printf '~%s' "$p" ;;
    esac
}

# ---- Validation ------------------------------------------------------------

# Usage: policy_validate_pattern <interpolated-pattern> <site_id> [service] [ecosystem]
policy_validate_pattern() {
    local pattern="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-geodineum}"

    # Bracketed, or bash tilde-expands the pattern and nothing is stripped.
    local p="$pattern"
    p="${p#[~]}"
    p="${p#[&]}"

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

# Usage: policy_read_patterns <manifest_path> <yq-path>; one pattern per line.
policy_read_patterns() {
    local manifest_path="$1" yq_path="$2"
    [[ -f "$manifest_path" ]] || return 1
    command -v yq &>/dev/null || return 1
    # Newer yq rejects the `[] // empty` form.
    yq eval "(${yq_path} // [])[]" "$manifest_path" 2>/dev/null
}

# ---- Grant composition -----------------------------------------------------

# One ACL key grant per line; any policy violation refuses the whole composition.
# Usage: policy_compose_key_grants <manifest_path> <site_id> [service] [ecosystem]
policy_compose_key_grants() {
    local manifest_path="$1"
    local site_id="$2"
    local service_name="${3:-$site_id}"
    local ecosystem="${4:-$(policy_manifest_constellation "$manifest_path")}"

    local raw interp
    local failed=0
    local out=()

    # geodeploy.yaml nests under data:; gnode_services.yaml uses top-level consumes:/produces:.
    for yq_path in '.data.consumes.streams' '.data.consumes.keys' \
                   '.data.produces.streams' '.data.produces.keys' \
                   '.consumes' '.produces'; do
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            interp=$(policy_interpolate "$raw" "$site_id" "$service_name" "$ecosystem")
            if policy_validate_pattern "$interp" "$site_id" "$service_name" "$ecosystem"; then
                out+=("$(policy_key_grant_form "$interp" "$site_id" "$ecosystem")")
            else
                failed=$((failed + 1))
            fi
        done < <(policy_read_patterns "$manifest_path" "$yq_path")
    done

    # data.ecosystem_well_known: own gnode namespace, read-only topology, own heartbeat key.
    if [[ "$(yq eval '.data.ecosystem_well_known // false' "$manifest_path" 2>/dev/null)" == "true" ]]; then
        out+=("~{${site_id}}:gnode:*")
        out+=("%R~{${ecosystem}}:gnode:*")
        out+=("~{${ecosystem}}:gnode:heartbeat:*:${site_id}:*")
        if [[ "$ecosystem" == "geodineum" ]]; then
            out+=("~{default}:gnode:*")
            out+=("~{default}:gcore:*")
        fi
    fi

    if [[ $failed -gt 0 ]]; then
        echo "  POLICY REFUSE: ${failed} pattern(s) violated namespace policy; ACL not composed" >&2
        return 1
    fi

    printf '%s\n' "${out[@]}"
}

# One ACL channel grant (&-prefixed) per line.
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

    # Every client publishes bundle invalidations here, whatever its manifest declares.
    out+=("&${site_id}:events:invalidate")

    if [[ $failed -gt 0 ]]; then
        echo "  POLICY REFUSE: ${failed} channel pattern(s) violated namespace policy" >&2
        return 1
    fi

    printf '%s\n' "${out[@]}"
}

# ---- Does the manifest declare any stream, key or channel? -----------------

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
        ((.data.produces.channels // []) | length) +
        ((.consumes // []) | length) +
        ((.produces // []) | length)
    ' "$manifest_path" 2>/dev/null)
    [[ "$n" -gt 0 ]] 2>/dev/null
}

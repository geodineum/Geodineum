#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

# =============================================================================
# Geodineum Ecosystem Bootstrap Loader (canonical, shared)
# =============================================================================
#
# Single-route config loader for every Geodineum component. Implements the
# two-tier model documented in REMEDIATION_PLAN_DEEP.md commit 0.1:
#
#   Tier 1 (disk):   /etc/geodineum/bootstrap.env
#                    root:geodineum-bootstrap 0640 (or 0600 root-only).
#                    Strict-deny posture (operator stance 2026-06-03):
#                    world-readable + group-writable REJECTED. The
#                    geodineum-bootstrap narrow group contains only the
#                    legitimate readers (www-data, gnode, geodine,
#                    deploy_user).
#                    Exactly 3 whitelisted keys:
#                       VALKEY_HOST
#                       VALKEY_PORT
#                       VALKEY_CREDS_PATH
#                    Strict regex parse, never `source`'d.
#
#   Tier 2 (ValKey): geodineum:bootstrap:<KEY>  (flat string values)
#                    geodineum:bootstrap:_index (SET of populated KEYs)
#                    Populated by the installer; read by every consumer.
#
# Canonical install location:
#   /usr/local/lib/geodineum/bootstrap-loader.sh   (root:root 0755)
#
# Dev override:
#   GEODINEUM_LIB=~/gh/Geodineum-pro/lib
#
# Public API (consumer):
#   load_ecosystem_config            # disk + ValKey, the one-call wrapper
#   load_bootstrap_disk_tier         # disk only (3 keys)
#   load_bootstrap_valkey_tier       # ValKey only (assumes disk tier loaded)
#
# Public API (installer-only, requires root + admin creds):
#   write_disk_bootstrap <host> <port> <creds_path>
#   populate_valkey_tier             # reads `KEY=value` lines from stdin
#
# This file is `source`'d by callers. It does NOT run anything on its own.
# Callers should `set -euo pipefail` themselves; this file does not modify
# the caller's shell options beyond exporting config variables.
# =============================================================================

# Canonical disk file location. Override via env for testing.
: "${GEODINEUM_BOOTSTRAP_FILE:=/etc/geodineum/bootstrap.env}"

# Whitelisted disk-tier keys. Order matters for required-key checks below.
__GEODINEUM_DISK_KEYS=(VALKEY_HOST VALKEY_PORT VALKEY_CREDS_PATH)

# ValKey key namespace (tier 2). Global, no hash-tag.
__GEODINEUM_VK_PREFIX="geodineum:bootstrap:"
__GEODINEUM_VK_INDEX="${__GEODINEUM_VK_PREFIX}_index"

# Internal: write a FATAL line to stderr and exit non-zero.
__geodineum_fatal() {
    echo "FATAL: bootstrap-loader: $*" >&2
    return 1
}

# -----------------------------------------------------------------------------
# load_bootstrap_disk_tier
# -----------------------------------------------------------------------------
# Verify ownership/mode of the disk file, parse exactly 3 whitelisted KEY=value
# lines, export them. Fail-fast on any drift, missing key, or unexpected line.
# -----------------------------------------------------------------------------
load_bootstrap_disk_tier() {
    local f="$GEODINEUM_BOOTSTRAP_FILE"
    [[ -f "$f" ]] || { __geodineum_fatal "$f missing — installer not run?"; return 1; }

    local uid mode
    uid=$(stat -c "%u" "$f" 2>/dev/null) \
        || { __geodineum_fatal "stat failed on $f"; return 1; }
    mode=$(stat -c "%a" "$f" 2>/dev/null) \
        || { __geodineum_fatal "stat failed on $f"; return 1; }

    # Allow loosened ownership in dev mode (GEODINEUM_BOOTSTRAP_DEV=1) so the
    # loader is testable without root. Never honor this in production.
    if [[ "${GEODINEUM_BOOTSTRAP_DEV:-0}" != "1" ]]; then
        # Owner MUST be root. Group identity is install-defined (canonically
        # geodineum-bootstrap, a narrow group of legitimate readers). We
        # don't hardcode the group name here — if the group is wrong, the
        # `read < "$f"` further down would fail with EACCES and emit a
        # clearer error than a string compare.
        [[ "$uid" == "0" ]] \
            || { __geodineum_fatal "$f ownership drift (got uid=$uid, want 0 — owner must be root, group must be geodineum-bootstrap)"; return 1; }
        # Strict-deny mode policy: 0640 (root:geodineum-bootstrap rw-r-----)
        # or 0600 (root-only rw-------). Anything else — especially 0644
        # which exposes deployment topology to "others" — REJECTED.
        [[ "$mode" == "640" || "$mode" == "600" ]] \
            || { __geodineum_fatal "$f mode drift (got $mode, want 0640 or 0600 — strict-deny on world-readable / group-writable)"; return 1; }
    fi

    # Reset the 3 whitelisted vars so a partial parse can't inherit stale values.
    local key
    for key in "${__GEODINEUM_DISK_KEYS[@]}"; do
        unset "$key"
    done

    local lineno=0 line stripped k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        # Strip leading/trailing whitespace.
        stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        # Skip blank + comment lines.
        [[ -z "$stripped" ]] && continue
        [[ "${stripped:0:1}" == "#" ]] && continue

        # Strict shape: KEY=value, value has no whitespace and no shell metachars.
        if ! [[ "$stripped" =~ ^([A-Z_][A-Z0-9_]*)=([^[:space:]\"\'\$\`\\]+)$ ]]; then
            __geodineum_fatal "$f line $lineno rejected (bad shape): $line"
            return 1
        fi
        k="${BASH_REMATCH[1]}"
        v="${BASH_REMATCH[2]}"

        # Whitelist the key.
        local found=0 wk
        for wk in "${__GEODINEUM_DISK_KEYS[@]}"; do
            [[ "$k" == "$wk" ]] && { found=1; break; }
        done
        if [[ "$found" -eq 0 ]]; then
            __geodineum_fatal "$f line $lineno rejected (key '$k' not whitelisted)"
            return 1
        fi

        export "$k=$v"
    done < "$f"

    # All required keys must be present.
    for key in "${__GEODINEUM_DISK_KEYS[@]}"; do
        if [[ -z "${!key:-}" ]]; then
            __geodineum_fatal "$f missing required key: $key"
            return 1
        fi
    done

    # VALKEY_PORT must be a positive integer.
    if ! [[ "$VALKEY_PORT" =~ ^[1-9][0-9]*$ ]]; then
        __geodineum_fatal "VALKEY_PORT not a positive integer: $VALKEY_PORT"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# __geodineum_resolve_valkey_password
# -----------------------------------------------------------------------------
# Internal: emit a path to a readable ValKey password file. Honors
# VALKEY_PASSWORD_FILE override; otherwise tries daemon then admin creds in
# VALKEY_CREDS_PATH. Returns 0 on success and prints the path; 1 on miss.
# -----------------------------------------------------------------------------
__geodineum_resolve_valkey_password() {
    if [[ -n "${VALKEY_PASSWORD_FILE:-}" ]] && [[ -r "$VALKEY_PASSWORD_FILE" ]]; then
        printf '%s' "$VALKEY_PASSWORD_FILE"
        return 0
    fi
    local candidate
    for candidate in valkey_daemon.password valkey.password; do
        if [[ -r "${VALKEY_CREDS_PATH}/${candidate}" ]]; then
            printf '%s' "${VALKEY_CREDS_PATH}/${candidate}"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# __geodineum_valkey_cli
# -----------------------------------------------------------------------------
# Internal: invoke valkey-cli with auth + connection from the disk tier.
# Caller passes the command + args. Stdout = command output. Stderr passes
# through. Returns valkey-cli's exit status.
# -----------------------------------------------------------------------------
__geodineum_valkey_cli() {
    local pwfile
    if ! pwfile=$(__geodineum_resolve_valkey_password); then
        __geodineum_fatal "no readable ValKey password file under ${VALKEY_CREDS_PATH:-?} (set VALKEY_PASSWORD_FILE or run as a user with creds access)"
        return 1
    fi
    local user_arg=()
    case "$(basename "$pwfile")" in
        valkey_daemon.password) user_arg=(--user gnode_daemon) ;;
        # admin password: default user; no --user flag
    esac
    valkey-cli \
        -h "$VALKEY_HOST" \
        -p "$VALKEY_PORT" \
        "${user_arg[@]}" \
        --no-auth-warning \
        -a "$(cat "$pwfile")" \
        "$@"
}

# -----------------------------------------------------------------------------
# load_bootstrap_valkey_tier
# -----------------------------------------------------------------------------
# Iterate geodineum:bootstrap:_index, GET each key, export under its bare name.
# Assumes load_bootstrap_disk_tier already ran (uses VALKEY_HOST/PORT/CREDS_PATH).
# Fail-fast on ValKey unreachable, index missing, or any indexed key GET-fail.
# -----------------------------------------------------------------------------
load_bootstrap_valkey_tier() {
    [[ -n "${VALKEY_HOST:-}" ]] \
        || { __geodineum_fatal "load_bootstrap_disk_tier must run before load_bootstrap_valkey_tier"; return 1; }

    # Probe reachability + auth.
    local pong
    pong=$(__geodineum_valkey_cli PING 2>&1) \
        || { __geodineum_fatal "ValKey unreachable at ${VALKEY_HOST}:${VALKEY_PORT}: $pong"; return 1; }
    [[ "$pong" == "PONG" ]] \
        || { __geodineum_fatal "ValKey ping returned unexpected: $pong"; return 1; }

    # Read the index. Empty SET (uninitialized) is acceptable for first-boot,
    # but we treat missing-index as an installer-incompleteness fault.
    local index_keys
    index_keys=$(__geodineum_valkey_cli SMEMBERS "$__GEODINEUM_VK_INDEX") \
        || { __geodineum_fatal "SMEMBERS $__GEODINEUM_VK_INDEX failed"; return 1; }

    if [[ -z "$index_keys" ]]; then
        # First-boot tolerance: index empty means installer hasn't run
        # populate_valkey_tier yet. Disk tier alone is enough to reach ValKey.
        return 0
    fi

    local k v
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        # Defense-in-depth: indexed key names must match KEY syntax.
        if ! [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            __geodineum_fatal "indexed key name rejected: $k"
            return 1
        fi
        v=$(__geodineum_valkey_cli GET "${__GEODINEUM_VK_PREFIX}${k}") \
            || { __geodineum_fatal "GET ${__GEODINEUM_VK_PREFIX}${k} failed"; return 1; }
        export "$k=$v"
    done <<< "$index_keys"

    return 0
}

# -----------------------------------------------------------------------------
# load_ecosystem_config
# -----------------------------------------------------------------------------
# One-call wrapper: disk tier then ValKey tier. The canonical entry point.
# -----------------------------------------------------------------------------
load_ecosystem_config() {
    load_bootstrap_disk_tier || return 1
    load_bootstrap_valkey_tier || return 1
    return 0
}

# -----------------------------------------------------------------------------
# write_disk_bootstrap <host> <port> <creds_path>
# -----------------------------------------------------------------------------
# INSTALLER ONLY. Writes the canonical 3-key disk file with strict perms.
# Caller must run as root.
# -----------------------------------------------------------------------------
write_disk_bootstrap() {
    local host="$1" port="$2" creds="$3"

    [[ "$EUID" -eq 0 ]] \
        || { __geodineum_fatal "write_disk_bootstrap requires root"; return 1; }

    # Validate args before writing.
    [[ "$host" =~ ^[A-Za-z0-9.\-]+$ ]] \
        || { __geodineum_fatal "invalid VALKEY_HOST: $host"; return 1; }
    [[ "$port" =~ ^[1-9][0-9]*$ ]] \
        || { __geodineum_fatal "invalid VALKEY_PORT: $port"; return 1; }
    [[ "$creds" =~ ^/[A-Za-z0-9._/-]+$ ]] \
        || { __geodineum_fatal "invalid VALKEY_CREDS_PATH: $creds"; return 1; }

    local dir
    dir=$(dirname "$GEODINEUM_BOOTSTRAP_FILE")
    [[ -d "$dir" ]] || mkdir -p "$dir"

    # Write atomically via temp file in same dir (rename is POSIX-atomic).
    local tmp
    tmp=$(mktemp "${dir}/.bootstrap.env.XXXXXX") \
        || { __geodineum_fatal "mktemp failed"; return 1; }
    {
        printf 'VALKEY_HOST=%s\n' "$host"
        printf 'VALKEY_PORT=%s\n' "$port"
        printf 'VALKEY_CREDS_PATH=%s\n' "$creds"
    } > "$tmp"
    # Strict-deny posture (operator security stance 2026-06-03):
    # root owner, narrow geodineum-bootstrap group, mode 0640. NEVER
    # world-readable. The geodineum-bootstrap group is created at
    # install time (see install.sh phase_users_groups) and contains ONLY
    # the legitimate readers (www-data, gnode, deploy user, geodine) —
    # least-privilege so a compromised web-server account doesn't gain
    # the broader operator group's access scope.
    #
    # gNode daemon's ecosystem_config.rs strict-deny check accepts only
    # 0640 or 0600. Any drift here → daemon FATAL at startup.
    chown root:geodineum-bootstrap "$tmp" || {
        # geodineum-bootstrap group may not yet exist on a fresh install
        # before phase_users_groups has run. Fall back to root:root 0600
        # (root-only) — strictly tighter than the target 0640, so the
        # daemon's mode check still passes (0600 is one of the accepted
        # values). install.sh will fix up the group on the next run.
        chown root:root "$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" "$GEODINEUM_BOOTSTRAP_FILE"
        return 0
    }
    chmod 0640 "$tmp"
    mv "$tmp" "$GEODINEUM_BOOTSTRAP_FILE"
    return 0
}

# -----------------------------------------------------------------------------
# populate_valkey_tier
# -----------------------------------------------------------------------------
# INSTALLER ONLY. Reads KEY=value lines from stdin and SETs each as
# geodineum:bootstrap:<KEY>, then SADD's KEY to geodineum:bootstrap:_index.
# Existing index entries for keys NOT present in this stdin batch are removed
# (idempotent re-run semantics: stdin defines the complete authoritative set).
#
# Requires disk tier loaded (uses VALKEY_HOST/PORT/CREDS_PATH) and admin creds
# (valkey.password readable in $VALKEY_CREDS_PATH).
# -----------------------------------------------------------------------------
populate_valkey_tier() {
    [[ -n "${VALKEY_HOST:-}" ]] \
        || { __geodineum_fatal "load_bootstrap_disk_tier must run before populate_valkey_tier"; return 1; }
    [[ -r "${VALKEY_CREDS_PATH}/valkey.password" ]] \
        || { __geodineum_fatal "populate_valkey_tier requires admin creds at ${VALKEY_CREDS_PATH}/valkey.password"; return 1; }

    # Force admin auth for SET operations (override any daemon-cred default).
    local prev_pwfile="${VALKEY_PASSWORD_FILE:-}"
    export VALKEY_PASSWORD_FILE="${VALKEY_CREDS_PATH}/valkey.password"

    local lineno=0 line k v
    declare -A wanted_keys=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        local stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        [[ -z "$stripped" ]] && continue
        [[ "${stripped:0:1}" == "#" ]] && continue
        if ! [[ "$stripped" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            __geodineum_fatal "populate_valkey_tier stdin line $lineno rejected: $line"
            export VALKEY_PASSWORD_FILE="$prev_pwfile"
            return 1
        fi
        k="${BASH_REMATCH[1]}"
        v="${BASH_REMATCH[2]}"
        # Strip surrounding double quotes from value if present.
        if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
            v="${v:1:-1}"
        fi
        # Reject the disk-tier keys: they live ONLY on disk.
        local wk
        for wk in "${__GEODINEUM_DISK_KEYS[@]}"; do
            if [[ "$k" == "$wk" ]]; then
                __geodineum_fatal "key '$k' is disk-tier-only; refuse to populate to ValKey"
                export VALKEY_PASSWORD_FILE="$prev_pwfile"
                return 1
            fi
        done
        __geodineum_valkey_cli SET "${__GEODINEUM_VK_PREFIX}${k}" "$v" >/dev/null \
            || { __geodineum_fatal "SET ${__GEODINEUM_VK_PREFIX}${k} failed"; export VALKEY_PASSWORD_FILE="$prev_pwfile"; return 1; }
        wanted_keys["$k"]=1
    done

    # Reconcile the index: prune any previously-indexed key not in this batch.
    local existing
    existing=$(__geodineum_valkey_cli SMEMBERS "$__GEODINEUM_VK_INDEX") || existing=""
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        if [[ -z "${wanted_keys[$k]:-}" ]]; then
            __geodineum_valkey_cli SREM "$__GEODINEUM_VK_INDEX" "$k" >/dev/null || true
            __geodineum_valkey_cli DEL "${__GEODINEUM_VK_PREFIX}${k}" >/dev/null || true
        fi
    done <<< "$existing"

    # Add wanted keys to the index.
    for k in "${!wanted_keys[@]}"; do
        __geodineum_valkey_cli SADD "$__GEODINEUM_VK_INDEX" "$k" >/dev/null \
            || { __geodineum_fatal "SADD $__GEODINEUM_VK_INDEX $k failed"; export VALKEY_PASSWORD_FILE="$prev_pwfile"; return 1; }
    done

    export VALKEY_PASSWORD_FILE="$prev_pwfile"
    return 0
}

#!/bin/bash
set -euo pipefail

# =============================================================================
# Geodineum bootstrap loader, sourced by every component
# =============================================================================
# Disk tier: /etc/geodineum/bootstrap.env, root-owned 0640 or 0600, exactly VALKEY_HOST, VALKEY_PORT, VALKEY_CREDS_PATH.
# ValKey tier: geodineum:bootstrap:<KEY>, indexed by the SET geodineum:bootstrap:_index.

: "${GEODINEUM_BOOTSTRAP_FILE:=/etc/geodineum/bootstrap.env}"

__GEODINEUM_DISK_KEYS=(VALKEY_HOST VALKEY_PORT VALKEY_CREDS_PATH)

__GEODINEUM_VK_PREFIX="geodineum:bootstrap:"
__GEODINEUM_VK_INDEX="${__GEODINEUM_VK_PREFIX}_index"

__geodineum_fatal() {
    echo "FATAL: bootstrap-loader: $*" >&2
    return 1
}

# Verify the disk file's owner and mode, then parse and export exactly the whitelisted keys.
load_bootstrap_disk_tier() {
    local f="$GEODINEUM_BOOTSTRAP_FILE"
    [[ -f "$f" ]] || { __geodineum_fatal "$f missing — installer not run?"; return 1; }

    local uid mode
    uid=$(stat -c "%u" "$f" 2>/dev/null) \
        || { __geodineum_fatal "stat failed on $f"; return 1; }
    mode=$(stat -c "%a" "$f" 2>/dev/null) \
        || { __geodineum_fatal "stat failed on $f"; return 1; }

    # GEODINEUM_BOOTSTRAP_DEV=1 skips the owner and mode checks, for tests without root.
    if [[ "${GEODINEUM_BOOTSTRAP_DEV:-0}" != "1" ]]; then
        [[ "$uid" == "0" ]] \
            || { __geodineum_fatal "$f ownership drift (got uid=$uid, want 0 — owner must be root, group must be geodineum-bootstrap)"; return 1; }
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

# Print a readable password file: VALKEY_PASSWORD_FILE, else daemon then admin creds.
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

# Export every key in the bootstrap index under its bare name; needs the disk tier loaded.
load_bootstrap_valkey_tier() {
    [[ -n "${VALKEY_HOST:-}" ]] \
        || { __geodineum_fatal "load_bootstrap_disk_tier must run before load_bootstrap_valkey_tier"; return 1; }

    local pong
    pong=$(__geodineum_valkey_cli PING 2>&1) \
        || { __geodineum_fatal "ValKey unreachable at ${VALKEY_HOST}:${VALKEY_PORT}: $pong"; return 1; }
    [[ "$pong" == "PONG" ]] \
        || { __geodineum_fatal "ValKey ping returned unexpected: $pong"; return 1; }

    local index_keys
    index_keys=$(__geodineum_valkey_cli SMEMBERS "$__GEODINEUM_VK_INDEX") \
        || { __geodineum_fatal "SMEMBERS $__GEODINEUM_VK_INDEX failed"; return 1; }

    if [[ -z "$index_keys" ]]; then
        # Before the installer populates the index, the disk tier alone is enough.
        return 0
    fi

    local k v
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
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

# The entry point: disk tier, then ValKey tier.
load_ecosystem_config() {
    load_bootstrap_disk_tier || return 1
    load_bootstrap_valkey_tier || return 1
    return 0
}

# Installer only, as root: write_disk_bootstrap <host> <port> <creds_path>
write_disk_bootstrap() {
    local host="$1" port="$2" creds="$3"

    [[ "$EUID" -eq 0 ]] \
        || { __geodineum_fatal "write_disk_bootstrap requires root"; return 1; }

    [[ "$host" =~ ^[A-Za-z0-9.\-]+$ ]] \
        || { __geodineum_fatal "invalid VALKEY_HOST: $host"; return 1; }
    [[ "$port" =~ ^[1-9][0-9]*$ ]] \
        || { __geodineum_fatal "invalid VALKEY_PORT: $port"; return 1; }
    [[ "$creds" =~ ^/[A-Za-z0-9._/-]+$ ]] \
        || { __geodineum_fatal "invalid VALKEY_CREDS_PATH: $creds"; return 1; }

    local dir
    dir=$(dirname "$GEODINEUM_BOOTSTRAP_FILE")
    [[ -d "$dir" ]] || mkdir -p "$dir"

    local tmp
    tmp=$(mktemp "${dir}/.bootstrap.env.XXXXXX") \
        || { __geodineum_fatal "mktemp failed"; return 1; }
    {
        printf 'VALKEY_HOST=%s\n' "$host"
        printf 'VALKEY_PORT=%s\n' "$port"
        printf 'VALKEY_CREDS_PATH=%s\n' "$creds"
    } > "$tmp"
    # The gNode daemon refuses to start unless this file is 0640 or 0600.
    chown root:geodineum-bootstrap "$tmp" || {
        # Without the group yet, root-only 0600 is tighter and still accepted.
        chown root:root "$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" "$GEODINEUM_BOOTSTRAP_FILE"
        return 0
    }
    chmod 0640 "$tmp"
    mv "$tmp" "$GEODINEUM_BOOTSTRAP_FILE"
    return 0
}

# Installer only, with admin creds: stdin KEY=value lines become the complete ValKey tier.
populate_valkey_tier() {
    [[ -n "${VALKEY_HOST:-}" ]] \
        || { __geodineum_fatal "load_bootstrap_disk_tier must run before populate_valkey_tier"; return 1; }
    [[ -r "${VALKEY_CREDS_PATH}/valkey.password" ]] \
        || { __geodineum_fatal "populate_valkey_tier requires admin creds at ${VALKEY_CREDS_PATH}/valkey.password"; return 1; }

    # SET needs admin auth, not the daemon credential.
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

    # Prune keys indexed before but absent from this batch.
    local existing
    existing=$(__geodineum_valkey_cli SMEMBERS "$__GEODINEUM_VK_INDEX") || existing=""
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        if [[ -z "${wanted_keys[$k]:-}" ]]; then
            __geodineum_valkey_cli SREM "$__GEODINEUM_VK_INDEX" "$k" >/dev/null || true
            __geodineum_valkey_cli DEL "${__GEODINEUM_VK_PREFIX}${k}" >/dev/null || true
        fi
    done <<< "$existing"

    for k in "${!wanted_keys[@]}"; do
        __geodineum_valkey_cli SADD "$__GEODINEUM_VK_INDEX" "$k" >/dev/null \
            || { __geodineum_fatal "SADD $__GEODINEUM_VK_INDEX $k failed"; export VALKEY_PASSWORD_FILE="$prev_pwfile"; return 1; }
    done

    export VALKEY_PASSWORD_FILE="$prev_pwfile"
    return 0
}

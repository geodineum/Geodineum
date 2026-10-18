#!/bin/bash
#
# Geodineum CLI — Deregister Command
# ===================================
# The one route that removes a service: the inverse of `geodineum register`.
# ValKey (intent, topology, keys, identity) through gNode's deregister-service.sh;
# this host through the registration ledger (lib/common.sh), newest first.
#
# Requires: common.sh sourced first
#

usage_deregister() {
    cat <<'EOF'
Usage: sudo geodineum deregister <id> [--purge-data] [--keep-acl] [--keep-cache] [--dry-run] [--force]

Removes a registered site, app or daemon from its constellation and from this host:
  1. stops its heartbeat and the units registration created
  2. ValKey: registration intent, topology entity + placements, keys, identity
  3. undoes what registration created on this host, newest first (vhost,
     certificate, units, env file, system user + group, manifest)
  4. removes the registration marker and the discovery entry
  5. checks that nothing is left, and names what was kept

Data registration created (docroot, service dir, COMMS history) is kept unless
--purge-data. Nothing registration did not create is ever removed.

  --purge-data   also remove the data registration created
  --keep-acl     keep the ValKey identity (ACL user + credential file)
  --keep-cache   keep cache and rate-limit keys
  --dry-run      show the plan, change nothing
  --force        no confirmation prompt

A node leaves with `geodineum node remove`; a framework component with its installer.
EOF
}

_dr_vk() {
    REDISCLI_AUTH="$(<"${GEODINEUM_CREDENTIALS_DIR}/valkey.password")" \
        valkey-cli --no-auth-warning --raw -h "$VALKEY_HOST" -p "$VALKEY_PORT" "$@"
}

# A ledger target is removed only inside these roots, and never a root itself.
_dr_safe_path() {
    local p="$1" root
    [[ "$p" == /* && "$p" != *..* ]] || return 1
    # A codebase's .geodineum/ can be anywhere; only what registration created in it is listed.
    [[ "$p" == */.geodineum || "$p" == */.geodineum/* ]] && return 0
    for root in "$GEODINEUM_WEB_ROOT" "${GEODINEUM_ROOT}/services" \
        "${GEODINEUM_CONFIG_ROOT}/manifests" "${GEODINEUM_CONFIG_ROOT}/services" "${GEODINEUM_CONFIG_ROOT}/heartbeat" /etc/systemd/system; do
        [[ "$p" == "$root"/?* ]] && return 0
    done
    return 1
}

_dr_unit_name_ok() { [[ "$1" =~ ^geodineum-[A-Za-z0-9_.@-]+\.(service|timer)$ ]]; }

# Undo one ledger line. Prints nothing on success; returns 1 when it could not.
_dr_undo() {
    local id="$1" kind="$2" t="$3"
    case "$kind" in
        unit)
            _dr_unit_name_ok "$t" || return 1
            systemctl disable --now "$t" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$t"
            DR_RELOAD_SYSTEMD=1 ;;
        vhost)
            [[ "$t" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
            a2dissite "${t}.conf" "${t}-le-ssl.conf" >/dev/null 2>&1 || true
            rm -f "/etc/apache2/sites-available/${t}.conf" "/etc/apache2/sites-available/${t}-le-ssl.conf"
            DR_RELOAD_APACHE=1 ;;
        cert)
            [[ "$t" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
            command -v certbot >/dev/null 2>&1 || return 1
            certbot delete --cert-name "$t" --non-interactive >/dev/null 2>&1 ;;
        user)
            [[ "$t" == "$id" ]] || return 1
            id "$t" >/dev/null 2>&1 || return 0
            userdel "$t" ;;
        group)
            [[ "$t" == "$id" ]] || return 1
            getent group "$t" >/dev/null 2>&1 || return 0
            groupdel "$t" ;;
        file)
            _dr_safe_path "$t" || return 1
            rm -f "$t" ;;
        dir)
            _dr_safe_path "$t" || return 1
            rm -rf "$t" ;;
        discovery)
            _dr_drop_discovery "$t" ;;
        geodineum-dir)
            # The registration marker and credential link; the manifest and the
            # directory itself go only through their own file/dir lines.
            [[ "$(basename "$t")" == .geodineum || "$t" == "${GEODINEUM_CONFIG_ROOT}/manifests/"?* ]] || return 1
            rm -f "$t/.registered"
            rm -rf "$t/credentials"
            _dr_drop_discovery "$t" ;;
        *) return 1 ;;
    esac
}

_dr_drop_discovery() {
    local conf="$GEODINEUM_DISCOVERY_CONF" d="$1"
    [[ -f "$conf" ]] || return 0
    local tmp="${conf}.tmp.$$"
    if [[ "$(basename "$d")" == .geodineum ]]; then
        grep -vxF -e "$d" -e "$(dirname "$d")" "$conf" > "$tmp" || true
    else
        grep -vxF -e "$d" "$conf" > "$tmp" || true
    fi
    if ! cmp -s "$conf" "$tmp"; then
        cat "$tmp" > "$conf"
        log_success "Discovery entry removed: $d"
    fi
    rm -f "$tmp"
}

# What is left of <id> after a deregister. Prints each residue; returns the count.
_dr_residue() {
    local id="$1" keep_acl="$2" n=0 c k
    shift 2
    local -a cs=("$@")
    for c in "${cs[@]}"; do
        [[ "$(_dr_vk HEXISTS "{$c}:gnode:constellation:entities" "$id")" == 1 ]] && { echo "  topology entity in {$c}"; n=$((n + 1)); }
        k="$(_dr_vk HSCAN "{$c}:gnode:constellation:entities" 0 MATCH "${id}@*" COUNT 1000 | sed -n '2~2p' | grep -c . || true)"
        [[ "$k" -gt 0 ]] && { echo "  $k placement(s) in {$c}"; n=$((n + 1)); }
        [[ "$(_dr_vk HEXISTS "{$c}:gnode:registrations" "$id")" == 1 ]] && { echo "  registration intent in {$c}"; n=$((n + 1)); }
    done
    if [[ "$keep_acl" != true ]]; then
        [[ -n "$(_dr_vk ACL GETUSER "gnode_client_${id}" 2>/dev/null)" ]] && { echo "  ACL user gnode_client_${id}"; n=$((n + 1)); }
        [[ -e "${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${id}.password" ]] && { echo "  credential file"; n=$((n + 1)); }
    fi
    local shared=0 keys
    [[ "$(_dr_vk EXISTS "{$id}:gnode:constellation:meta")" == 1 ]] && shared=1
    keys="$(_dr_vk --scan --pattern "{${id}}:*" | { if [[ $shared -eq 1 ]]; then grep -vE "^\{${id}\}:gnode:(constellation|heartbeat|registrations|cluster|grants|schema|topo|services)(:|$)"; else cat; fi; } | grep -c . || true)"
    [[ "$keys" -gt 0 ]] && { echo "  $keys key(s) under {${id}}:*"; n=$((n + 1)); }
    [[ "$(_dr_vk EXISTS "gnode:site:${id}:meta")" == 1 ]] && { echo "  gnode:site:${id}:meta"; n=$((n + 1)); }
    [[ "$(_dr_vk SISMEMBER gnode:sites:registry "$id")" == 1 ]] && { echo "  gnode:sites:registry entry"; n=$((n + 1)); }
    local ledger="${GEODINEUM_REGISTRATIONS_DIR}/${id}.tsv"
    if [[ -f "$ledger" ]]; then
        k="$(grep -c "^config"$'\t' "$ledger" || true)"
        [[ "$k" -gt 0 ]] && { echo "  $k ledger entr$([[ $k -eq 1 ]] && echo y || echo ies) not undone (${ledger})"; n=$((n + 1)); }
    fi
    return "$n"
}

cmd_deregister() {
    local id="" purge=false keep_acl=false keep_cache=false dry_run=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-data) purge=true ;;
            --keep-acl)   keep_acl=true ;;
            --keep-cache) keep_cache=true ;;
            --dry-run)    dry_run=true ;;
            --force)      force=true ;;
            --remove-acl) log_error "--remove-acl is gone: deregister removes the identity unless --keep-acl"; exit 2 ;;
            -h|--help)    usage_deregister; exit 0 ;;
            -*)           log_error "Unknown option: $1"; usage_deregister; exit 2 ;;
            *)            [[ -z "$id" ]] || { log_error "Unexpected argument: $1"; exit 2; }; id="$1" ;;
        esac
        shift
    done
    [[ -n "$id" ]] || { usage_deregister; exit 2; }
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { log_error "Not a service id: '$id'"; exit 2; }
    require_sudo "Deregistration"

    local valkey_part="${GNODE_SCRIPTS}/deregister-service.sh"
    [[ -x "$valkey_part" ]] || { log_error "gNode's deregister-service.sh not found at ${valkey_part}"; exit 1; }
    # shellcheck source=/dev/null
    source "${GNODE_SCRIPTS}/cli/constellation.sh"
    local -a cs
    mapfile -t cs < <(gnode_cli_constellations)

    # Only services deregister; nodes and components have their own way out.
    local c sh
    for c in "${cs[@]}"; do
        sh="$(_dr_vk HGET "{$c}:gnode:constellation:entities" "$id" | python3 -I -c 'import json,sys
d = sys.stdin.read().strip()
print(json.loads(d).get("sh", "") if d else "")' 2>/dev/null)"
        case "$sh" in
            1)     log_error "'$id' is a node in {$c}: use  sudo geodineum node remove $id"; exit 2 ;;
            2)     log_error "'$id' is a framework component in {$c}; it leaves with its installer"; exit 2 ;;
            4.*)   log_error "'$id' is a placement in {$c}; it goes with its service or its node"; exit 2 ;;
        esac
    done

    local ledger="${GEODINEUM_REGISTRATIONS_DIR}/${id}.tsv"
    local -a lines=() stop=()
    [[ -f "$ledger" ]] && mapfile -t lines < <(tac "$ledger")
    local line cls kind t gdir=""
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r cls kind t <<< "$line"
        [[ "$kind" == unit ]] && stop+=("$t")
        [[ "$kind" == geodineum-dir && -z "$gdir" ]] && gdir="$t"
    done
    [[ -n "$gdir" ]] || gdir="$(find_geodineum_dir "$id" 2>/dev/null || true)"
    # The framework's heartbeat for this id, whoever installed it.
    local hb
    for hb in "geodineum-${id}-heartbeat.timer" "geodineum-heartbeat@${id}.timer"; do
        [[ " ${stop[*]} " == *" $hb "* ]] && continue
        [[ -n "$(systemctl list-unit-files --no-legend "$hb" 2>/dev/null)" ]] && stop+=("$hb")
    done
    local comms_dir="${GEODINEUM_COMMS_DATA_DIR:-/var/lib/geodineum-comms}/${id}"

    echo ""
    log_step "Deregister ${id} (constellations: ${cs[*]})"
    local -a vflags=()
    [[ "$keep_acl" == true ]] && vflags+=(--keep-acl)
    [[ "$keep_cache" == true ]] && vflags+=(--keep-cache)
    local vplan
    vplan="$("$valkey_part" "$id" --dry-run "${vflags[@]}" 2>&1)" || { echo "$vplan"; log_error "ValKey plan failed; nothing changed"; exit 1; }
    echo "$vplan"
    if [[ "$vplan" == *"Nothing in ValKey for '$id'"* && ${#lines[@]} -eq 0 && ${#stop[@]} -eq 0 \
          && ( -z "$gdir" || ! -d "$gdir" ) && ! -d "$comms_dir" ]]; then
        log_info "Nothing is registered as '${id}' here or in ValKey"
        return 0
    fi
    echo ""
    echo "  on this host ($(gnode_cli_node_id)):"
    [[ ${#stop[@]} -gt 0 ]] && echo "    stop        ${stop[*]}"
    [[ ${#lines[@]} -eq 0 ]] && echo "    ledger      none (registered before the ledger, or nothing created here)"
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r cls kind t <<< "$line"
        case "$cls" in
            config) echo "    remove      $kind $t" ;;
            data)   [[ "$purge" == true ]] && echo "    purge       $kind $t" || echo "    keep        $kind $t  (data; --purge-data removes it)" ;;
            *)      echo "    keep        $kind $t  (shared)" ;;
        esac
    done
    [[ -n "$gdir" ]] && echo "    unmark      $gdir"
    [[ -d "$comms_dir" ]] && { [[ "$purge" == true ]] && echo "    purge       COMMS history $comms_dir" || echo "    keep        COMMS history $comms_dir  (data)"; }
    [[ "$dry_run" == true ]] && { echo ""; log_info "Dry run — nothing changed"; return 0; }

    if [[ "$force" != true ]]; then
        local answer
        echo -en "\n  ${RED}Deregister ${id}?${NC} [y/${BOLD}N${NC}] "
        read -r answer < /dev/tty
        [[ "${answer,,}" == y || "${answer,,}" == yes ]] || { log_info "Cancelled"; return 0; }
    fi

    log_step "1/5 Stop"
    local u
    for u in "${stop[@]}"; do
        systemctl disable --now "$u" >/dev/null 2>&1 && log_success "stopped $u" || log_warning "could not stop $u"
    done

    log_step "2/5 ValKey"
    "$valkey_part" "$id" --force "${vflags[@]}" || {
        log_error "The ValKey part did not finish; this host is left as it was. Fix the cause and re-run."
        return 1
    }

    log_step "3/5 Undo what registration created here"
    DR_RELOAD_SYSTEMD=0 DR_RELOAD_APACHE=0
    local -a kept=()
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r cls kind t <<< "$line"
        if [[ "$cls" == keep || ( "$cls" == data && "$purge" != true ) ]]; then
            kept+=("$line"); continue
        fi
        if _dr_undo "$id" "$kind" "$t"; then log_success "$kind $t"
        else log_error "could not undo: $kind $t"; kept+=("$line"); fi
    done
    for hb in "geodineum-${id}-heartbeat.service" "geodineum-${id}-heartbeat.timer"; do
        [[ -f "/etc/systemd/system/$hb" ]] && { rm -f "/etc/systemd/system/$hb"; DR_RELOAD_SYSTEMD=1; log_success "unit $hb"; }
    done
    [[ "$DR_RELOAD_SYSTEMD" == 1 ]] && systemctl daemon-reload
    if [[ "$DR_RELOAD_APACHE" == 1 ]]; then
        apachectl configtest >/dev/null 2>&1 && systemctl reload apache2 \
            || log_warning "apache configtest failed after removing the vhost — check: apachectl configtest"
    fi
    if [[ ${#kept[@]} -gt 0 ]]; then
        printf '%s\n' "${kept[@]}" | tac > "$ledger"
    else
        rm -f "$ledger"
    fi

    log_step "4/5 Registration marker"
    if [[ -n "$gdir" && -d "$gdir" ]]; then
        _dr_undo "$id" geodineum-dir "$gdir" && log_success "unmarked $gdir" || log_warning "left $gdir marked (unexpected path)"
    fi
    if [[ -d "$comms_dir" && "$purge" == true ]]; then
        rm -rf "$comms_dir" && log_success "COMMS history $comms_dir"
    fi

    log_step "5/5 Residue"
    local residue rc
    residue="$(_dr_residue "$id" "$keep_acl" "${cs[@]}")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "none"
    else
        echo "$residue"
        log_error "${rc} residue item(s) — re-run  sudo geodineum deregister ${id}  to finish"
    fi
    if [[ ${#kept[@]} -gt 0 ]]; then
        echo "  kept by design (${ledger}):"
        printf '    %s\n' "${kept[@]//$'\t'/ }"
    fi
    [[ -d "$comms_dir" ]] && echo "    COMMS history ${comms_dir}"
    return "$rc"
}

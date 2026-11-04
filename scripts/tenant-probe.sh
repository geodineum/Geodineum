#!/bin/bash
# on aesir, as root: every ordered pair (A, B) of pooled sites tries to reach the other on every
# layer and must be refused everywhere (SPEC-SITE-STUDIO S0c). Read-only on the live constellation:
# writes are tried with ACL DRYRUN, reads as the site's own ValKey user. Nightly from
# geodineum-tenant-probe.timer (install-tenant-probe.sh); by hand:
#   sudo bash scripts/tenant-probe.sh [--layers valkey,files,php,store,http] [--alert-site <site>] [--no-alert]
# A throwaway run (tests/tenant-probe/local.sh): --sites a,b --creds <dir> --port <n> --layers valkey
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${TENANT_PROBE_LIB:-$HERE/../lib/site-pool.sh}"; [[ -f "$LIB" ]] || LIB="$HERE/tenant-probe.lib.sh"
# shellcheck source=../lib/site-pool.sh
source "$LIB"

RECORDS="$SITE_POOL_RECORDS"; CREDS="$SITE_POOL_CREDS"; PORT="${VALKEY_PORT:-47445}"; ENVN=production
LAYERS=valkey,files,php,store,http; ALERT_SITE="${TENANT_PROBE_ALERT_SITE:-}"; ALERT=1; STATE=/var/lib/geodineum/tenant-probe
SITES_OPT=""; C=geodineum
while [[ $# -gt 0 ]]; do case "$1" in
    --records) RECORDS="$2"; shift 2 ;; --creds) CREDS="$2"; shift 2 ;; --port) PORT="$2"; shift 2 ;;
    --env) ENVN="$2"; shift 2 ;; --layers) LAYERS="$2"; shift 2 ;; --alert-site) ALERT_SITE="$2"; shift 2 ;;
    --no-alert) ALERT=0; shift ;; --state) STATE="$2"; shift 2 ;; --sites) SITES_OPT="$2"; shift 2 ;;
    --constellation) C="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; done
has() { [[ ",$LAYERS," == *",$1,"* ]]; }

ADMIN="$CREDS/valkey.password"
[[ -r "$ADMIN" ]] || { echo "cannot read $ADMIN: run as root" >&2; exit 1; }
vk() { REDISCLI_AUTH="$(<"$ADMIN")" valkey-cli --no-auth-warning --raw -p "$PORT" "$@" 2>&1; }
vk_as() { # <user> <password file> <cmd...>
    local u="$1" f="$2"; shift 2
    REDISCLI_AUTH="$(<"$f")" valkey-cli --no-auth-warning --raw -p "$PORT" --user "$u" "$@" 2>&1
}
dryrun() { vk ACL DRYRUN "$@" | head -1; }   # OK, or the refusal

# ---- the sites -----------------------------------------------------------------------------
declare -a IDS=() USERS=() KINDS=() PHPS=() DOCS=() BASEDIRS=() POOLS=()
if [[ -n "$SITES_OPT" ]]; then
    IFS=, read -r -a IDS <<<"$SITES_OPT"
    for id in "${IDS[@]}"; do USERS+=("$(site_pool_user "$id")"); KINDS+=(""); PHPS+=(""); DOCS+=(""); BASEDIRS+=(""); POOLS+=(""); done
else
    for f in "$RECORDS"/*.env; do
        [[ -f "$f" ]] || continue
        site_pool_read "$f" || { echo "  ..   skip $(basename "$f"): unreadable record"; continue; }
        IDS+=("$SP_SITE_ID"); USERS+=("$SP_SITE_USER"); KINDS+=("$SP_KIND"); PHPS+=("$SP_PHP"); DOCS+=("$SP_DOCROOTS")
        BASEDIRS+=("$(site_pool_basedir)"); POOLS+=("/etc/php/$SP_PHP/fpm/pool.d/site-$SP_SITE_ID.conf")
    done
fi
N=${#IDS[@]}
(( N >= 2 )) || { echo "fewer than two sites ($N): nothing to keep apart" >&2; exit 1; }

# ---- bookkeeping ---------------------------------------------------------------------------
checks=0; failed=(); notes=0
ok()   { checks=$((checks+1)); echo "  ok   $*"; }
bad()  { checks=$((checks+1)); echo "  FAIL $*"; failed+=("$*"); }
note() { notes=$((notes+1)); echo "  ..   $*"; }
refused() { [[ "$1" == *NOPERM* || "$1" == *"no permissions"* ]]; }
rnd() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
echo "== on $(hostname -s): tenant probe, $N sites, $((N*(N-1))) ordered pairs, layers $LAYERS"

# ---- valkey: A's users against B's keys -----------------------------------------------------
if has valkey; then
    echo "-- valkey"
    for ((i=0; i<N; i++)); do
        A="${IDS[$i]}"; UA="gnode_client_$A"; PA="$CREDS/valkey_client_$A.password"
        if [[ ! -r "$PA" ]]; then bad "$A: no credential at $(basename "$PA") (cannot probe as $A)"; continue; fi
        r=$(vk_as "$UA" "$PA" EXISTS "{$A}:site:content")
        [[ "$r" == 0 || "$r" == 1 ]] && ok "$A reads its own tag (control)" || bad "$A cannot read its own tag: $r"
        PORTAL_A=$(ls "$CREDS"/portal-*/"$A.password" 2>/dev/null | head -1 || true)
        for ((j=0; j<N; j++)); do
            (( i == j )) && continue
            B="${IDS[$j]}"
            r=$(vk_as "$UA" "$PA" EXISTS "{$B}:site:content"); refused "$r" && ok "$A -> {$B}: EXISTS refused" || bad "$A -> {$B}: EXISTS answered: $r"
            r=$(vk_as "$UA" "$PA" EXISTS "$B:site:content"); refused "$r" && ok "$A -> $B:* (brace-less alias) refused" || bad "$A -> $B:site:content answered: $r"
            r=$(vk_as "$UA" "$PA" XLEN "{$B}:gnode:unified:$ENVN"); refused "$r" && ok "$A -> {$B} unified stream refused" || bad "$A -> {$B} unified stream answered: $r"
            r=$(dryrun "$UA" SET "{$B}:edit:token:probe" x); [[ "$r" != OK ]] && ok "$A -> {$B} edit token write refused (dry run)" || bad "$A may write {$B}:edit:token:*"
            r=$(dryrun "$UA" XADD "{$B}:gnode:comms:$ENVN" '*' a 1); [[ "$r" != OK ]] && ok "$A -> {$B} comms write refused (dry run)" || bad "$A may XADD to {$B}:gnode:comms"
            r=$(dryrun "$UA" FCALL_RO gnode_probe 1 "{$B}:x"); [[ "$r" != OK ]] && ok "$A -> {$B} function call refused (dry run)" || bad "$A may FCALL_RO on a {$B} key"
            if [[ -n "$PORTAL_A" ]]; then
                r=$(vk_as "portal_$A" "$PORTAL_A" HGETALL "{$B}:site:content"); refused "$r" && ok "portal_$A -> {$B} content refused" || bad "portal_$A -> {$B} content answered: $r"
                r=$(dryrun "portal_$A" SET "{$B}:edit:token:probe" x EX 60); [[ "$r" != OK ]] && ok "portal_$A -> {$B} edit token refused (dry run)" || bad "portal_$A may mint edit tokens for {$B}"
            fi
        done
        if [[ -n "$PORTAL_A" ]]; then
            r=$(dryrun "portal_$A" SET "{$A}:edit:token:probe" x EX 60); [[ "$r" == OK ]] && ok "portal_$A mints edit tokens for its own site (control)" || note "portal_$A has no edit-token grant yet (client-site.sh portal)"
        fi
    done
fi

# ---- files: A's unix user against B's files -------------------------------------------------
if has files && [[ -z "$SITES_OPT" ]]; then
    echo "-- files"
    for ((i=0; i<N; i++)); do
        A="${IDS[$i]}"; UA="${USERS[$i]}"
        id "$UA" >/dev/null 2>&1 || { bad "$A: no unix user $UA"; continue; }
        runuser -u "$UA" -- test -r "$CREDS/valkey_client_$A.password" && ok "$UA reads its own credential (control)" || bad "$UA cannot read its own credential"
        for ((j=0; j<N; j++)); do
            (( i == j )) && continue
            B="${IDS[$j]}"
            runuser -u "$UA" -- test -r "$CREDS/valkey_client_$B.password" && bad "$UA reads $B's credential" || ok "$UA -> $B credential refused"
            pb=$(ls "$CREDS"/portal-*/"$B.password" 2>/dev/null | head -1 || true)
            [[ -n "$pb" ]] && { runuser -u "$UA" -- test -r "$pb" && bad "$UA reads $B's portal credential" || ok "$UA -> $B portal credential refused"; }
            [[ -d "$SITE_POOL_STATE/$B" ]] && { runuser -u "$UA" -- test -w "$SITE_POOL_STATE/$B/tmp" && bad "$UA writes $B's tmp" || ok "$UA -> $B tmp refused"; }
        done
    done
fi

# ---- php: open_basedir as the pool runs it --------------------------------------------------
if has php && [[ -z "$SITES_OPT" ]]; then
    echo "-- php"
    for ((i=0; i<N; i++)); do
        A="${IDS[$i]}"; UA="${USERS[$i]}"; BD="${BASEDIRS[$i]}"; PHPB="/usr/bin/php${PHPS[$i]}"
        [[ -x "$PHPB" ]] || PHPB=$(command -v php || true)
        [[ -n "$PHPB" ]] || { note "no php binary for $A"; continue; }
        [[ -f "${POOLS[$i]}" ]] && { grep -q '^php_admin_value\[open_basedir\]' "${POOLS[$i]}" && ok "$A pool sets open_basedir" || bad "$A pool has no open_basedir line"; }
        ini="/etc/php/${PHPS[$i]}/fpm/conf.d/96-geodineum-site-pools.ini"
        [[ -f "$ini" ]] && grep -qx 'opcache.validate_permission=1' "$ini" && ok "$A php ${PHPS[$i]}: opcache.validate_permission=1" || bad "$A php ${PHPS[$i]}: opcache.validate_permission=1 missing ($ini)"
        probe_read() { runuser -u "$UA" -- "$PHPB" -n -d "open_basedir=$BD" -d display_errors=0 -r 'exit(@file_get_contents($argv[1]) === false ? 3 : 0);' -- "$1" 2>/dev/null; echo $?; }
        # a world-readable file outside the basedir: only open_basedir can refuse it
        r=$(probe_read /etc/hostname); [[ "$r" == 3 ]] && ok "$UA under its open_basedir cannot read /etc/hostname" || bad "$UA under open_basedir read /etc/hostname (exit $r): open_basedir not effective"
        own="$CREDS/valkey_client_$A.password"
        r=$(probe_read "$own"); [[ "$r" == 0 ]] && ok "$UA under its open_basedir reads its own credential (control)" || bad "$UA under open_basedir cannot read its own credential (exit $r)"
        for ((j=0; j<N; j++)); do
            (( i == j )) && continue
            B="${IDS[$j]}"
            r=$(probe_read "$CREDS/valkey_client_$B.password"); [[ "$r" == 3 ]] && ok "$UA php -> $B credential refused" || bad "$UA php read $B's credential"
            for d in ${DOCS[$j]}; do r=$(probe_read "$d/index.php"); [[ "$r" == 3 ]] && ok "$UA php -> $B docroot refused" || bad "$UA php read $d/index.php"; break; done
        done
    done
fi

# ---- store: read-back through the relay, as A -----------------------------------------------
if has store; then
    echo "-- store"
    ask() { # <site> <id> <params json>
        local f="$CREDS/valkey_client_$1.password" r="" k
        vk_as "gnode_client_$1" "$f" XADD "{$1}:gnode:unified:$ENVN" '*' t c id "$2" c store_list p "$3" ss "$1" sn tenant-probe ts "$(date +%s%3N)" _rt geodineum_store >/dev/null
        for k in $(seq 30); do r=$(vk_as "gnode_client_$1" "$f" GET "{$1}:res:$2"); [[ -n "$r" && "$r" != "(nil)" ]] && break; sleep 0.5; done
        printf '%s' "$r"
    }
    stamp=$(date +%s)
    for ((i=0; i<N; i++)); do
        A="${IDS[$i]}"; [[ -r "$CREDS/valkey_client_$A.password" ]] || continue
        r=$(ask "$A" "probe-$stamp-own" '{"kind":"site.content","limit":100}')
        if [[ -z "$r" ]]; then note "$A: no answer from STORE in 15 s (relay or STORE down; unproven tonight)"; continue; fi
        if [[ "$r" == *label:persistence* ]]; then note "$A holds no persistence: read-back not open to it (good, nothing to probe)"; continue; fi
        others=$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(",".join(sorted({x.get("site","") for x in (r.get("result") or {}).get("records",[])} - {sys.argv[2]})))' "$r" "$A" 2>/dev/null || echo "unparseable")
        [[ -z "$others" ]] && ok "$A store_list answers only $A's rows" || bad "$A store_list returned rows of: $others"
        r=$(ask "$A" "probe-$stamp-mail" '{"kind":"mail.message","limit":1}')
        [[ "$r" == *"not served"* ]] && ok "$A cannot list mail.message (refused by name)" || bad "$A store_list mail.message was not refused: ${r:0:160}"
    done
fi

# ---- http: an edit token nobody minted ------------------------------------------------------
if has http && [[ -z "$SITES_OPT" ]]; then
    echo "-- http"
    for ((i=0; i<N; i++)); do
        [[ "${KINDS[$i]}" == wp ]] && continue
        A="${IDS[$i]}"
        # shellcheck disable=SC2086
        hosts=$(for f in $(site_pool_vhosts ${DOCS[$i]}); do sed -nE 's/^\s*ServerName\s+//p' "$f"; done | sort -u)
        for h in $hosts; do
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$h:443:127.0.0.1" "https://$h/_edit/enter?t=$(rnd)" || echo 000)
            case "$code" in
                403) ok "https://$h/_edit/enter with a random token -> 403" ;;
                404) note "https://$h has no /_edit yet (template not redeployed)" ;;
                *) bad "https://$h/_edit/enter with a random token -> $code" ;;
            esac
        done
    done
fi

# ---- the record and the alert ----------------------------------------------------------------
nf=${#failed[@]}
echo "== $checks checks, $nf failed, $notes notes"
mkdir -p "$STATE" && chmod 0750 "$STATE"
day=$(date -u +%F); now=$(date -u -Is)
python3 -I - "$STATE/$day.json" "$now" "$(hostname -s)" "$checks" "$nf" "$LAYERS" "${IDS[*]}" "${failed[@]}" <<'PY'
import json, sys
out, now, host, checks, nf, layers, sites, *failed = sys.argv[1:]
rec = {"ts": now, "host": host, "sites": sites.split(), "layers": layers, "checks": int(checks), "failed": failed}
with open(out, "w") as f: json.dump(rec, f, indent=1)
PY
chmod 0640 "$STATE/$day.json"; ln -sfn "$day.json" "$STATE/last.json"
prev_fp=$(cat "$STATE/alert.fp" 2>/dev/null || true); prev_at=$(cat "$STATE/alert.at" 2>/dev/null || echo 0)
fp=$( (( nf )) && printf '%s\n' "${failed[@]}" | sha256sum | cut -c1-16 || echo clean)
if [[ -n "$ALERT_SITE" ]]; then
    vk XADD "{$ALERT_SITE}:probe:events" MAXLEN '~' 400 '*' pz 1 t probe.tenant site_id "$ALERT_SITE" ts "$(date +%s%3N)" \
        host "$(hostname -s)" checks "$checks" failed "$nf" sites "${IDS[*]}" summary "$(printf '%s; ' "${failed[@]:0:20}")" >/dev/null && echo "  ..   recorded on {$ALERT_SITE}:probe:events (STORE keeps probe.tenant 730 d)"
    send() { # <priority> <subject> <body>
        vk XADD "{$ALERT_SITE}:gnode:comms:$ENVN" '*' site_id "$ALERT_SITE" environment "$ENVN" type alert priority "$1" timestamp "$now" \
            sender '{"name":"tenant probe"}' subject "$2" body "$3" metadata '{"source":"tenant-probe","form_type":"alert"}' dispatch '{"channels":["email"]}' >/dev/null
    }
    if (( ALERT )); then
        if (( nf )) && { [[ "$fp" != "$prev_fp" ]] || (( $(date +%s) - prev_at > 21600 )); }; then
            send 2 "[tenant probe] $nf of $checks checks FAILED on $(hostname -s)" "$(printf '%s\n' "${failed[@]}")"$'\n\n'"$STATE/$day.json"
            date +%s > "$STATE/alert.at"; echo "  ..   alert sent to {$ALERT_SITE}'s recipients"
        elif (( ! nf )) && [[ -n "$prev_fp" && "$prev_fp" != clean ]]; then
            send 4 "[tenant probe] recovered: $checks checks pass on $(hostname -s)" "Every pair of sites is refused on every layer again."; echo "  ..   recovery notice sent"
        fi
    fi
    printf '%s' "$fp" > "$STATE/alert.fp"
fi
exit $(( nf > 0 ))

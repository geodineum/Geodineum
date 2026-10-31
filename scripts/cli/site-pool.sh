#!/bin/bash
# geodineum site pool — move one site onto its own PHP-FPM pool and Unix user, check it, or move it back.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../../lib/site-pool.sh
source "$HERE/../../lib/site-pool.sh"
HOST="on $(hostname -s):"

usage() {
    cat <<'EOF'
Usage: sudo geodineum site pool <site_id> [plan|apply|verify|revert|show] [options]

  plan      (default) print what apply would do
  apply     create the site user, its pool and socket, point the site's vhosts at it
  verify    check the pool serves the site and the site reads only its own credential
  revert    point the vhosts back at the shared pool and remove the record (--purge also removes the user)
  show      print the record

Options (apply; stored in /etc/geodineum/web/<site_id>.env and reused by later runs):
  --docroot <dir>     a docroot of this site id; repeat for a preview copy (default /var/www/<domain from id>)
  --kind wp|standalone
  --pro               let the site load /opt/geodineum/pro/gCore
  --dash              add the site user to geodineum-dash
  --max-children <n>  default 8
  --no-basedir        leave open_basedir off (to tell its breakage apart from the user switch)
EOF
}

ID="${1:-}"
[[ -z "$ID" || "$ID" == -h || "$ID" == --help ]] && { usage; [[ -z "$ID" ]] && exit 2; exit 0; }
[[ "$ID" =~ ^[a-z0-9_]+$ ]] || { echo "site_id must be [a-z0-9_]+" >&2; exit 2; }
shift
ACTION=plan; [[ $# -gt 0 && "$1" != --* ]] && { ACTION="$1"; shift; }
DOCROOTS=() KIND="" PRO="" DASH="" MAXC="" BASEDIR="" PURGE=0
while [[ $# -gt 0 ]]; do case "$1" in
    --docroot) DOCROOTS+=("${2%/}"); shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --pro) PRO=1; shift ;;
    --dash) DASH=1; shift ;;
    --max-children) MAXC="$2"; shift 2 ;;
    --no-basedir) BASEDIR=0; shift ;;
    --purge) PURGE=1; shift ;;
    *) usage; exit 2 ;;
esac; done
[[ "$ACTION" =~ ^(plan|apply|verify|revert|show)$ ]] || { usage; exit 2; }
[[ $EUID -eq 0 || "$ACTION" == plan || "$ACTION" == show ]] || { echo "$HOST needs root: sudo geodineum site pool $ID $ACTION" >&2; exit 1; }

U="$(site_pool_user "$ID")"
REC="$SITE_POOL_RECORDS/$ID.env"
PHPV="$(site_pool_phpv)"
FPM="php${PHPV}-fpm"
POOL="/etc/php/$PHPV/fpm/pool.d/site-$ID.conf"
SOCK="/run/php/site-$ID.sock"
CRED="$SITE_POOL_CREDS/valkey_client_$ID.password"
INC="$SITE_POOL_APACHE/php-$ID.conf"
APPLY=0; [[ "$ACTION" == apply ]] && APPLY=1

say() { echo "$HOST [site pool $ID] $*"; }
run() { echo "  + $*"; if (( APPLY )); then "$@"; fi; }

load_record() {
    if site_pool_read "$REC" 2>/dev/null; then :; else
        SP_SITE_ID="$ID" SP_SITE_USER="$U" SP_KIND="" SP_DOCROOTS="" SP_PRO=0 SP_DASH=0 SP_MAX_CHILDREN="" SP_BASEDIR=1 SP_EXTRA_BASEDIR="" SP_CRED_OWNER_BEFORE=""
    fi
    (( ${#DOCROOTS[@]} )) && SP_DOCROOTS="${DOCROOTS[*]}"
    [[ -z "$SP_DOCROOTS" ]] && SP_DOCROOTS="/var/www/$(sed 's/_/./g' <<< "$ID")"
    [[ -n "$KIND" ]] && SP_KIND="$KIND"
    if [[ -z "$SP_KIND" ]]; then
        SP_KIND=standalone
        for d in $SP_DOCROOTS; do [[ -f "$d/wp-config.php" || -f "$d/public_html/wp-config.php" ]] && SP_KIND=wp; done
    fi
    [[ "$SP_KIND" == standalone && -z "$SP_WRITABLE" ]] && SP_WRITABLE="uploads"
    [[ -n "$PRO" ]] && SP_PRO="$PRO"
    [[ -n "$DASH" ]] && SP_DASH="$DASH"
    [[ -n "$MAXC" ]] && SP_MAX_CHILDREN="$MAXC"
    [[ -n "$BASEDIR" ]] && SP_BASEDIR="$BASEDIR"
    # shellcheck disable=SC2086
    [[ "$SP_KIND" == wp ]] && SP_EXTRA_BASEDIR="$(site_pool_detect_extra $SP_DOCROOTS)"
    SP_SITE_USER="$U"
    return 0
}

write_record() {
    install -d -m 0750 -o root -g root "$SITE_POOL_RECORDS"
    umask 027
    cat > "$REC" <<EOF
SITE_ID="$SP_SITE_ID"
SITE_USER="$SP_SITE_USER"
KIND="$SP_KIND"
DOCROOTS="$SP_DOCROOTS"
WRITABLE="$SP_WRITABLE"
PRO="$SP_PRO"
DASH="$SP_DASH"
MAX_CHILDREN="${SP_MAX_CHILDREN:-8}"
BASEDIR="$SP_BASEDIR"
EXTRA_BASEDIR="$SP_EXTRA_BASEDIR"
CRED_OWNER_BEFORE="$SP_CRED_OWNER_BEFORE"
EOF
    chmod 0640 "$REC"
}

traverse_acl() {   # <dir> -> u:$U:--x unless the user already passes
    [[ -d "$1" ]] || return 0
    runuser -u "$U" -- test -x "$1" 2>/dev/null || setfacl -m "u:$U:--x" "$1"
}

tree_acl() {   # <docroot>
    find "$1" -not -type l -not -name .htaccess -exec setfacl -m "u:$U:rX" {} + 2>/dev/null || true
    find "$1" -type d -exec setfacl -d -m "u:$U:rX,o::---" {} + 2>/dev/null || true
}

vhost_files() {
    # shellcheck disable=SC2086
    site_pool_vhosts $SP_DOCROOTS
}

do_apply() {
    say "user $U, php $PHPV, kind $SP_KIND, docroots: $SP_DOCROOTS"
    local d f
    for d in $SP_DOCROOTS; do [[ -d "$d" ]] || { say "STOP: no docroot $d"; exit 1; }; done
    [[ -f "$CRED" ]] || { say "STOP: no credential $CRED (register the site first)"; exit 1; }
    command -v setfacl >/dev/null || { say "STOP: setfacl missing (apt install acl)"; exit 1; }
    [[ -n "$PHPV" && -x "$(command -v "php-fpm$PHPV")" ]] || { say "STOP: php-fpm$PHPV not found"; exit 1; }
    local vh; vh="$(vhost_files)"
    [[ -n "$vh" ]] || { say "STOP: no enabled vhost has DocumentRoot in $SP_DOCROOTS"; exit 1; }
    for g in geodineum-code geodineum-bootstrap; do getent group "$g" >/dev/null || { say "STOP: group $g missing"; exit 1; }; done
    local sweep_lib="$HERE/../../lib/geodeploy.sh" age
    if [[ -f "$sweep_lib" ]]; then
        grep -c site_pool_owner_for "$sweep_lib" >/dev/null || { say "STOP: the deploy sweep here does not know site pools yet; it would hand the writable dirs back to www-data"; exit 1; }
        age=$(( $(date +%s) - $(stat -c %Y "$sweep_lib") ))
        (( age >= 600 || ! APPLY )) || { say "STOP: the sweep learned site pools $((age / 60)) min ago; it runs the old code one more cycle. Retry in $(( (600 - age) / 60 + 1 )) min"; exit 1; }
    fi

    say "1. opcache checks file permissions per pool (global, once)"
    local ini="/etc/php/$PHPV/fpm/conf.d/96-geodineum-site-pools.ini"
    if [[ ! -f "$ini" ]]; then
        echo "  + write $ini: opcache.validate_permission=1, opcache.validate_root=1"
        (( APPLY )) && printf 'opcache.validate_permission=1\nopcache.validate_root=1\n' > "$ini" && chmod 0644 "$ini"
    else echo "  = $ini present"; fi

    say "2. system user and group $U"
    if ! getent group "$U" >/dev/null; then run groupadd --system "$U"; else echo "  = group exists"; fi
    if ! id "$U" >/dev/null 2>&1; then
        run useradd --system --gid "$U" --home-dir "$SITE_POOL_STATE/$ID/home" --no-create-home --shell /usr/sbin/nologin "$U"
    else echo "  = user exists"; fi
    local groups="geodineum-code,geodineum-bootstrap"
    [[ "$SP_DASH" == 1 ]] && groups+=",geodineum-dash"
    run usermod -aG "$groups" "$U"

    say "3. record $REC"
    [[ -z "$SP_CRED_OWNER_BEFORE" ]] && SP_CRED_OWNER_BEFORE="$(stat -c '%U:%G:%a' "$CRED")"
    if (( APPLY )); then write_record; else echo "  + write record (credential before: $SP_CRED_OWNER_BEFORE)"; fi

    say "4. state $SITE_POOL_STATE/$ID and logs $SITE_POOL_LOGS/$ID"
    if (( APPLY )); then
        install -d -m 0750 -o root -g root "$SITE_POOL_STATE"
        install -d -m 0700 -o "$U" -g "$U" "$SITE_POOL_STATE/$ID"
        for d in sessions tmp cache home; do install -d -m 0700 -o "$U" -g "$U" "$SITE_POOL_STATE/$ID/$d"; done
        install -d -m 2750 -o root -g geodineum "$SITE_POOL_LOGS"
        install -d -m 2750 -o "$U" -g geodineum "$SITE_POOL_LOGS/$ID"
        traverse_acl "$(dirname "$SITE_POOL_STATE")"; traverse_acl "$SITE_POOL_STATE"
        traverse_acl "$(dirname "$SITE_POOL_LOGS")"; traverse_acl "$SITE_POOL_LOGS"
    else echo "  + create sessions tmp cache home (0700 $U), log dir ($U:geodineum 2750), traverse ACLs"; fi

    say "5. docroots: $U reads through an ACL; writable dirs become $U:www-data"
    for d in $SP_DOCROOTS; do
        if (( APPLY )); then
            traverse_acl "$(dirname "$d")"
            tree_acl "$d"
            while IFS= read -r f; do
                find "$f" -not -type l -not -name .htaccess -exec chown "$U:www-data" {} +
                find "$f" -type d -exec chmod 2750 {} +
                find "$f" -type f -not -name .htaccess -exec chmod 0640 {} +
            done < <(site_pool_writable_dirs "$d")
        else
            echo "  + ACL u:$U:rX (and default) on $d; traverse on $(dirname "$d")"
            site_pool_writable_dirs "$d" | sed "s/^/  + chown -R $U:www-data, 2750\/0640: /"
        fi
    done

    say "6. credential $CRED -> root:$U 0640"
    run chgrp "$U" "$CRED"
    run chmod 0640 "$CRED"
    echo "  + sidecar ${CRED}.owner = root:$U:640"
    if (( APPLY )); then printf 'root:%s:640\n' "$U" > "$CRED.owner"; chown root:geodineum-creds "$CRED.owner"; chmod 0644 "$CRED.owner"; fi

    say "7. pool $POOL"
    if (( APPLY )); then
        site_pool_conf "$PHPV" > "$POOL"; chmod 0644 "$POOL"
        if ! "php-fpm$PHPV" -t >/dev/null 2>&1; then
            "php-fpm$PHPV" -t || true; rm -f "$POOL"; say "STOP: php-fpm rejected the pool; removed it"; exit 1
        fi
        systemctl reload "$FPM"
        for _ in $(seq 20); do [[ -S "$SOCK" ]] && break; sleep 0.5; done
        [[ -S "$SOCK" ]] || { say "STOP: $SOCK did not appear (journalctl -u $FPM)"; exit 1; }
    else site_pool_conf "$PHPV" | sed 's/^/    /'; fi

    say "8. apache: $INC, included by each vhost"
    if (( APPLY )); then
        install -d -m 0750 -o root -g root "$SITE_POOL_APACHE"
        site_pool_handler_conf "$ID" > "$INC"; chmod 0640 "$INC"
    fi
    for f in $vh; do
        if grep -qF "Include $INC" "$f"; then echo "  = $f"; continue; fi
        echo "  + $f"
        if (( APPLY )); then
            [[ -f "$f.bak-site-pool" ]] || cp -p "$f" "$f.bak-site-pool"
            sed -i "s#^\([[:space:]]*\)</VirtualHost>#\1    Include $INC\n\1</VirtualHost>#" "$f"
        fi
    done
    if (( APPLY )); then
        if ! apache2ctl configtest >/dev/null 2>&1; then
            apache2ctl configtest || true
            for f in $vh; do [[ -f "$f.bak-site-pool" ]] && cp -p "$f.bak-site-pool" "$f"; done
            say "STOP: apache rejected the config; vhosts restored, the pool stays (revert removes it)"; exit 1
        fi
        systemctl reload apache2
    fi
    (( APPLY )) || { echo; echo "$HOST plan only. Re-run with apply."; exit 0; }
    do_verify
}

do_verify() {
    site_pool_read "$REC" || { say "no record $REC"; exit 1; }
    local fail=0 h code f other
    ok() { echo "  OK   $*"; }
    bad() { echo "  FAIL $*"; fail=1; }
    say "verify"
    [[ -S "$SOCK" ]] && ok "socket $SOCK" || bad "no socket $SOCK"
    for f in $(vhost_files); do grep -qF "Include $INC" "$f" && ok "vhost $f includes the handler" || bad "vhost $f lacks Include $INC"; done
    local hosts
    hosts=$(for f in $(vhost_files); do sed -nE 's/^\s*Server(Name|Alias)\s+//p' "$f"; done | tr ' ' '\n' | sort -u)
    for h in $hosts; do
        for p in / /wp-cron.php; do
            [[ "$p" == /wp-cron.php && "$SP_KIND" != wp ]] && continue
            code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$h:443:127.0.0.1" "https://$h$p" || echo 000)
            [[ "$code" =~ ^(200|301|302|303|401|403)$ ]] && ok "https://$h$p -> $code" || bad "https://$h$p -> $code"
        done
    done
    if ps -o user= -C "php-fpm$PHPV" | grep -cxF "$U" >/dev/null; then ok "php workers run as $U"; else bad "no php worker runs as $U (no PHP request reached the pool?)"; fi
    runuser -u "$U" -- test -r "$CRED" && ok "$U reads its credential" || bad "$U cannot read $CRED"
    runuser -u www-data -- test -r "$CRED" && bad "www-data still reads $CRED" || ok "www-data cannot read the credential"
    other=$(ls "$SITE_POOL_CREDS"/valkey_client_*.password 2>/dev/null | grep -vF "$CRED" | head -1 || true)
    if [[ -n "$other" ]]; then runuser -u "$U" -- test -r "$other" && bad "$U reads $(basename "$other")" || ok "$U cannot read another site's credential"; fi
    local log="$SITE_POOL_LOGS/$ID/php-error.log"
    if [[ -f "$log" ]]; then
        echo "  ..   $(wc -l < "$log") lines in $log, $(grep -c open_basedir "$log" || true) about open_basedir; last 5:"
        tail -n 5 "$log" | cut -c1-240 | sed 's/^/       /'
    else echo "  ..   no PHP errors logged yet ($log)"; fi
    exit $fail
}

do_revert() {
    site_pool_read "$REC" || { say "no record $REC; nothing to revert"; exit 1; }
    APPLY=1
    local f d before_g before_m
    say "1. vhosts back to the shared pool"
    for f in $(vhost_files); do grep -qF "Include $INC" "$f" && run sed -i "\#Include ${INC//./\\.}#d" "$f"; done
    rm -f "$INC"
    apache2ctl configtest >/dev/null 2>&1 || { apache2ctl configtest || true; say "STOP: apache config invalid after removing the include"; exit 1; }
    run systemctl reload apache2
    say "2. pool removed"
    run rm -f "$POOL"
    run systemctl reload "$FPM"
    say "3. credential back to ${SP_CRED_OWNER_BEFORE:-root:geodineum-web:640}"
    IFS=: read -r _ before_g before_m <<< "${SP_CRED_OWNER_BEFORE:-root:geodineum-web:640}"
    run chown "root:$before_g" "$CRED"
    run chmod "$before_m" "$CRED"
    printf 'root:%s:%s\n' "$before_g" "$before_m" > "$CRED.owner"
    say "4. writable dirs back to www-data, ACL entries for $U removed"
    for d in $SP_DOCROOTS; do
        while IFS= read -r f; do find "$f" -not -type l -not -name .htaccess -exec chown www-data:www-data {} +; done < <(site_pool_writable_dirs "$d")
        find "$d" -not -type l -not -name .htaccess -exec setfacl -x "u:$U" {} + 2>/dev/null || true
        find "$d" -type d -exec setfacl -d -x "u:$U" {} + 2>/dev/null || true
        setfacl -x "u:$U" "$(dirname "$d")" 2>/dev/null || true
    done
    run rm -f "$REC"
    if (( PURGE )); then
        say "5. purge user, group and state"
        for d in "$(dirname "$SITE_POOL_STATE")" "$SITE_POOL_STATE" "$(dirname "$SITE_POOL_LOGS")" "$SITE_POOL_LOGS"; do setfacl -x "u:$U" "$d" 2>/dev/null || true; done
        run rm -rf "${SITE_POOL_STATE:?}/$ID"
        run userdel "$U"
        getent group "$U" >/dev/null && run groupdel "$U"
        echo "  = logs kept in $SITE_POOL_LOGS/$ID"
    else echo "  = user $U kept (revert --purge removes it)"; fi
    say "reverted; the next deploy sweep restores the www-data owners it manages"
}

load_record
case "$ACTION" in
    plan|apply) do_apply ;;
    verify) do_verify ;;
    revert) do_revert ;;
    show) if [[ -r "$REC" ]]; then cat "$REC"; else echo "no record $REC (or not readable without sudo)"; fi ;;
esac

#!/bin/bash
# geodineum site pools — close the shared www-data pool once every PHP site runs its own.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../../lib/site-pool.sh
source "$HERE/../../lib/site-pool.sh"
HOST="on $(hostname -s):"
BACKUPS=/var/backups/geodineum-site-pools
PRO_TREE=/opt/geodineum/pro/gCore
LEAVE="geodineum-web geodineum-client geodineum-dash geodineum-bootstrap"

usage() {
    cat <<'EOF'
Usage: sudo geodineum site pools [plan|close|reopen]

  plan    (default) check every PHP vhost has its own pool and print what close would do
  close   the global PHP handler points at an unreachable [_idle] pool (503, never source),
          the shared pool and the stock www pool go, an FPM left without pools stops,
          www-data keeps only geodineum-code, and the Pro tree becomes geodineum-pro
          (members: the records with PRO="1")
  reopen  put back what the last close changed (from its backup)
EOF
}

ACTION="${1:-plan}"
[[ "$ACTION" =~ ^(plan|close|reopen)$ ]] || { usage; exit 2; }
[[ $EUID -eq 0 ]] || { echo "$HOST needs root: sudo geodineum site pools $ACTION" >&2; exit 1; }
APPLY=0; [[ "$ACTION" == close ]] && APPLY=1
say() { echo "$HOST [site pools] $*"; }
run() { echo "  + $*"; if (( APPLY )); then "$@"; fi; }

# The PHP the records run on (all one version, or the newest of them), where [_idle] lives.
records_phpv() {
    local f v=""
    for f in /etc/php/*/fpm/pool.d/site-*.conf; do [[ -f "$f" ]] && v+="$(cut -d/ -f4 <<< "$f")"$'\n'; done
    sort -uV <<< "$v" | sed '/^$/d' | tail -1
}

idle_conf() {
    cat <<EOF
; written by geodineum site pools close: FPM needs one pool to start; no vhost reaches this one
[_idle]
user = nobody
group = nogroup
listen = $SITE_POOL_IDLE_SOCK
listen.owner = root
listen.group = root
listen.mode = 0600
pm = ondemand
pm.max_children = 1
pm.process_idle_timeout = 10s
php_admin_value[open_basedir] = /nonexistent
EOF
}

handler_conf() {
    cat <<EOF
# written by geodineum site pools close. Each site's vhost includes
# /etc/apache2/geodineum/php-<id>.conf, whose SetHandler overrides this one. A vhost without it
# reaches the [_idle] socket Apache cannot open: 503, never the PHP source. (A global
# "Require all denied" here would also deny every site's PHP: the per-site section sets no Require.)
<IfModule proxy_fcgi_module>
    <IfModule setenvif_module>
        SetEnvIfNoCase ^Authorization\$ "(.+)" HTTP_AUTHORIZATION=\$1
    </IfModule>
    <FilesMatch "\.ph(?:ar|p|tml)\$">
        SetHandler "proxy:unix:$SITE_POOL_IDLE_SOCK|fcgi://localhost"
    </FilesMatch>
    <FilesMatch "\.phps\$">
        Require all denied
    </FilesMatch>
    <FilesMatch "^\.ph(?:ar|p|ps|tml)\$">
        Require all denied
    </FilesMatch>
</IfModule>
EOF
}

# Enabled vhosts that would serve PHP but include no per-site handler.
uncovered_vhosts() {
    local f t dr
    for f in /etc/apache2/sites-enabled/*.conf; do
        [[ -f "$f" ]] || continue
        t=$(readlink -f "$f")
        grep -cE "^\s*Include\s+$SITE_POOL_APACHE/php-" "$t" >/dev/null && continue
        while IFS= read -r dr; do
            dr="${dr//\"/}"
            [[ -d "$dr" ]] || continue
            if find "$dr" -maxdepth 3 -name '*.php' -print -quit 2>/dev/null | grep -c . >/dev/null; then
                echo "$t ($dr)"
            fi
        done < <(sed -nE 's/^\s*DocumentRoot\s+(\S+).*/\1/p' "$t")
    done
}

do_close() {
    local phpv fpm f v u stop=0 bk
    phpv=$(records_phpv)
    say "checks"
    if site_pool_closed; then say "already closed ($SITE_POOL_HANDLER points at $SITE_POOL_IDLE_SOCK)"; exit 0; fi
    [[ -n "$phpv" ]] || { say "STOP: no site pool exists yet"; exit 1; }
    fpm="php${phpv}-fpm"
    systemctl is-active --quiet "$fpm" && echo "  OK   $fpm runs the site pools" || { echo "  FAIL $fpm is not active"; stop=1; }
    local unc; unc=$(uncovered_vhosts)
    if [[ -z "$unc" ]]; then echo "  OK   every enabled vhost with PHP includes its own pool handler"
    else echo "  FAIL vhosts with PHP but no pool (they would answer 503):"; sed 's/^/         /' <<< "$unc"; stop=1; fi
    for f in "$SITE_POOL_RECORDS"/*.env; do
        [[ -f "$f" ]] || continue
        v=$(basename "$f" .env)
        [[ -S "/run/php/site-$v.sock" ]] && echo "  OK   $v socket" || { echo "  FAIL $v has a record but no socket"; stop=1; }
    done
    if (( EUID == 0 )) && crontab -l -u www-data >/dev/null 2>&1; then
        echo "  FAIL www-data has a crontab (crontab -l -u www-data); its jobs lose the groups below"; stop=1
    else echo "  OK   www-data has no crontab"; fi
    local why
    if why=$(site_pool_sweep_wait 'site_pool_flag_users DASH'); then
        echo "  OK   the deploy sweep no longer adds www-data to geodineum-dash"
    else echo "  FAIL $why (it would put www-data back in geodineum-dash and restart the web tier)"; stop=1; fi
    (( stop )) && { say "STOP: nothing changed"; exit 1; }

    bk="$BACKUPS/close-$(date -u +%Y%m%dT%H%M%SZ)"
    say "1. backup to $bk"
    if (( APPLY )); then
        install -d -m 0700 -o root -g root "$BACKUPS" "$bk"
        cp -p "$SITE_POOL_HANDLER" "$bk/"
        for f in /etc/php/*/fpm/pool.d/geodineum.conf /etc/php/*/fpm/pool.d/www.conf; do
            [[ -f "$f" ]] && cp -p "$f" "$bk/$(cut -d/ -f4 <<< "$f")-$(basename "$f")"
        done
        id -nG www-data | tr ' ' '\n' > "$bk/www-data.groups"
        [[ -d "$PRO_TREE" ]] && stat -c %G "$PRO_TREE" > "$bk/pro-tree.group"
        systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1, $2}' > "$bk/fpm-units"
        echo "$bk" > "$BACKUPS/last-close"
    fi

    say "2. [_idle] pool on php $phpv ($SITE_POOL_IDLE_SOCK, root 0600)"
    if (( APPLY )); then
        idle_conf > "/etc/php/$phpv/fpm/pool.d/_idle.conf"; chmod 0644 "/etc/php/$phpv/fpm/pool.d/_idle.conf"
    else idle_conf | sed 's/^/    /'; fi

    say "3. global handler $SITE_POOL_HANDLER -> [_idle]"
    if (( APPLY )); then
        handler_conf > "$SITE_POOL_HANDLER"; chmod 0644 "$SITE_POOL_HANDLER"
        if ! apache2ctl configtest >/dev/null 2>&1; then
            apache2ctl configtest || true
            cp -p "$bk/$(basename "$SITE_POOL_HANDLER")" "$SITE_POOL_HANDLER"
            rm -f "/etc/php/$phpv/fpm/pool.d/_idle.conf"
            say "STOP: apache rejected the handler; restored"; exit 1
        fi
    fi

    say "4. shared pools out"
    for f in /etc/php/*/fpm/pool.d/geodineum.conf /etc/php/*/fpm/pool.d/www.conf; do
        [[ -f "$f" ]] && run rm -f "$f"
    done
    if (( APPLY )); then
        "php-fpm$phpv" -t >/dev/null 2>&1 || { "php-fpm$phpv" -t || true; say "STOP: php-fpm$phpv rejects its pools; reopen restores"; exit 1; }
        systemctl reload "$fpm"
        for _ in $(seq 20); do [[ -S "$SITE_POOL_IDLE_SOCK" ]] && break; sleep 0.5; done
        systemctl reload apache2
    else echo "  + reload $fpm, reload apache2"; fi
    for f in /etc/php/*/fpm/pool.d; do
        v=$(cut -d/ -f4 <<< "$f")
        [[ "$v" == "$phpv" ]] && continue
        systemctl is-enabled --quiet "php$v-fpm" 2>/dev/null || systemctl is-active --quiet "php$v-fpm" 2>/dev/null || continue
        if ls "$f"/*.conf 2>/dev/null | grep -vE '/(geodineum|www)\.conf$' | grep -c . >/dev/null; then
            run systemctl reload "php$v-fpm"
        else
            run systemctl disable --now "php$v-fpm"
        fi
    done

    say "5. www-data keeps only geodineum-code"
    for g in $LEAVE; do
        id -nG www-data | tr ' ' '\n' | grep -cx "$g" >/dev/null && run gpasswd -d www-data "$g"
    done

    say "6. Pro tree $PRO_TREE -> group geodineum-pro"
    if [[ -d "$PRO_TREE" ]]; then
        getent group geodineum-pro >/dev/null || run groupadd --system geodineum-pro
        for u in $(site_pool_flag_users PRO) geodine; do
            id "$u" >/dev/null 2>&1 || continue
            run usermod -aG geodineum-pro "$u"
        done
        run chgrp -R geodineum-pro "$PRO_TREE"
    else echo "  = no Pro tree"; fi

    say "7. PHP-FPM reload (workers pick up the groups) and apache reload"
    if (( APPLY )); then
        for f in $(systemctl list-units 'php*-fpm.service' --state=active --no-legend | awk '{print $1}'); do systemctl reload "$f"; done
        systemctl reload apache2
        sleep 2
    else echo "  + reload every active php*-fpm, reload apache2"; echo; echo "$HOST plan only. Re-run with close."; exit 0; fi

    do_check
}

do_check() {
    local fail=0 f v out
    say "check"
    for f in "$SITE_POOL_RECORDS"/*.env; do
        [[ -f "$f" ]] || continue
        v=$(basename "$f" .env)
        if out=$(bash "$HERE/site-pool.sh" "$v" verify 2>&1); then echo "  OK   $v verify"
        else echo "  FAIL $v verify:"; grep FAIL <<< "$out" | sed 's/^/     /'; fail=1; fi
    done
    echo "  ..   $(id www-data)"
    systemctl list-units 'php*-fpm.service' --no-legend --all | awk '{print "  ..   " $1, $3, $4}'
    (( fail )) && say "a site failed: sudo geodineum site pools reopen puts the shared pool back"
    exit $fail
}

do_reopen() {
    local bk f v g
    bk=$(cat "$BACKUPS/last-close" 2>/dev/null || true)
    [[ -n "$bk" && -d "$bk" ]] || { say "no close backup ($BACKUPS/last-close)"; exit 1; }
    APPLY=1
    say "reopen from $bk"
    run cp -p "$bk/$(basename "$SITE_POOL_HANDLER")" "$SITE_POOL_HANDLER"
    for f in "$bk"/*-geodineum.conf "$bk"/*-www.conf; do
        [[ -f "$f" ]] || continue
        v=$(basename "$f" | cut -d- -f1)
        run cp -p "$f" "/etc/php/$v/fpm/pool.d/$(basename "$f" | cut -d- -f2-)"
    done
    run rm -f /etc/php/*/fpm/pool.d/_idle.conf
    while read -r f g; do
        [[ "$g" == enabled ]] && { run systemctl enable "$f"; run systemctl restart "$f"; }
    done < "$bk/fpm-units"
    for g in $(cat "$bk/www-data.groups"); do getent group "$g" >/dev/null && run usermod -aG "$g" www-data; done
    if [[ -f "$bk/pro-tree.group" && -d "$PRO_TREE" ]]; then run chgrp -R "$(cat "$bk/pro-tree.group")" "$PRO_TREE"; fi
    apache2ctl configtest >/dev/null 2>&1 || { apache2ctl configtest || true; say "STOP: apache config invalid"; exit 1; }
    for f in $(systemctl list-units 'php*-fpm.service' --state=active --no-legend | awk '{print $1}'); do run systemctl reload "$f"; done
    run systemctl reload apache2
    say "reopened; geodineum-pro is left in place (empty of effect: the Pro tree is back on its old group)"
}

case "$ACTION" in
    plan|close) do_close ;;
    reopen) do_reopen ;;
esac

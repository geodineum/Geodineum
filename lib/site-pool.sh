#!/bin/bash
# One PHP-FPM pool and one Unix user per site (SPEC-SITE-POOLS). Desired state per site lives
# in ${SITE_POOL_RECORDS}/<site_id>.env; a site without a record keeps the shared www-data pool.

SITE_POOL_RECORDS="${SITE_POOL_RECORDS:-/etc/geodineum/web}"
SITE_POOL_STATE="${SITE_POOL_STATE:-/var/lib/geodineum-sites}"
SITE_POOL_LOGS="${SITE_POOL_LOGS:-/var/log/geodineum/sites}"
SITE_POOL_APACHE="${SITE_POOL_APACHE:-/etc/apache2/geodineum}"
SITE_POOL_CREDS="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}"
SITE_POOL_WP_WRITABLE="wp-content/uploads wp-content/cache wp-content/upgrade wp-content/gcore-logs wp-content/wflogs"

site_pool_user() {   # <site_id>
    local u="web_$1"
    (( ${#u} > 32 )) && u="${u:0:25}_$(printf %s "$1" | sha256sum | cut -c1-6)"
    printf '%s' "$u"
}

SITE_POOL_HANDLER="${SITE_POOL_HANDLER:-/etc/apache2/conf-available/geodineum-php-fpm.conf}"
SITE_POOL_IDLE_SOCK=/run/php/_idle.sock

# The PHP a new record starts on: the version whose FPM holds the shared pool (geodineum-fpm.sock)
# or, once closed, the [_idle] pool; installing another php-fpm never moves a site by itself.
site_pool_phpv() {
    local f v=""
    f=$(grep -lE 'geodineum-fpm\.sock|^\[_idle\]' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | sort -V | tail -1 || true)
    [[ -n "$f" ]] && v=$(cut -d/ -f4 <<< "$f")
    [[ -z "$v" ]] && v=$(ls -d /etc/php/*/fpm/pool.d 2>/dev/null | sed 's#/etc/php/\([^/]*\)/.*#\1#' | sort -V | tail -1)
    printf '%s' "${SITE_POOL_PHPV:-$v}"
}

# The deploy sweep's own copy of its library (it runs from the installer clone under /opt), and
# whether it has known <pattern> for two cycles (it sources its library before pulling it).
site_pool_sweep_wait() {   # <pattern> -> prints why not, returns 1; silent and 0 when ready
    local lib="${GEODINEUM_ROOT:-/opt/geodineum}/Geodineum/lib/geodeploy.sh" age
    [[ -f "$lib" ]] || return 0
    grep -cF "$1" "$lib" >/dev/null || { echo "the deploy sweep ($lib) does not have this change yet (git -C ${lib%/lib/*} log -1)"; return 1; }
    age=$(( $(date +%s) - $(stat -c %Y "$lib") ))
    (( age >= 600 )) || { echo "the deploy sweep took this change $((age / 60)) min ago and runs the old code one more cycle; retry in $(( (600 - age) / 60 + 1 )) min"; return 1; }
    return 0
}

# The site users whose record sets a flag: site_pool_flag_users PRO|DASH
site_pool_flag_users() {
    local f
    for f in "$SITE_POOL_RECORDS"/*.env; do
        [[ -f "$f" ]] || continue
        ( site_pool_read "$f" 2>/dev/null || exit 0; v="SP_$1"; [[ "${!v:-0}" == 1 && -n "$SP_SITE_USER" ]] && echo "$SP_SITE_USER" ) || true
    done
    return 0
}

# Closed: the global handler sends PHP to the unreachable [_idle] socket; no shared pool remains.
site_pool_closed() {
    grep -c "$SITE_POOL_IDLE_SOCK" "$SITE_POOL_HANDLER" >/dev/null 2>&1
}

# Reads KEY="value" lines into SP_<KEY>; no expansion, no sourcing.
site_pool_read() {   # <record file>
    local line k v
    SP_SITE_ID="" SP_SITE_USER="" SP_KIND="" SP_DOCROOTS="" SP_WRITABLE="" SP_PRO=0 SP_DASH=0
    SP_MAX_CHILDREN="" SP_BASEDIR=1 SP_EXTRA_BASEDIR="" SP_CRED_OWNER_BEFORE="" SP_PHP=""
    [[ -r "$1" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"$ ]] || continue
        k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
        case "$k" in
            SITE_ID|SITE_USER|KIND|DOCROOTS|WRITABLE|PRO|DASH|MAX_CHILDREN|BASEDIR|EXTRA_BASEDIR|CRED_OWNER_BEFORE|PHP)
                printf -v "SP_$k" '%s' "$v" ;;
        esac
    done < "$1"
    [[ -n "$SP_SITE_ID" && -n "$SP_SITE_USER" ]]
}

# The site user a directory belongs to, or nothing. Used by the deploy sweep.
site_pool_owner_for() {   # <dir>
    local dir="${1%/}" f d
    for f in "$SITE_POOL_RECORDS"/*.env; do
        [[ -f "$f" ]] || continue
        site_pool_read "$f" || continue
        for d in $SP_DOCROOTS; do
            if [[ "$dir" == "$d" || "$dir" == "$d/public_html" || "$dir" == "$d/public" ]]; then printf '%s\n' "$SP_SITE_USER"; return 0; fi
        done
    done
    return 1
}

site_pool_writable_dirs() {   # <docroot> -> absolute existing writable dirs
    local root="$1" rel base
    base="$root"; [[ -f "$root/public_html/wp-config.php" ]] && base="$root/public_html"
    for rel in ${SP_WRITABLE:-$SITE_POOL_WP_WRITABLE}; do
        [[ -d "$base/$rel" ]] && printf '%s\n' "$base/$rel"
    done
    return 0
}

site_pool_basedir() {   # uses SP_*; prints the open_basedir value
    local parts=() d
    for d in $SP_DOCROOTS; do parts+=("$d"); done
    parts+=("$SITE_POOL_STATE/$SP_SITE_ID" "$SITE_POOL_LOGS/$SP_SITE_ID"
            /opt/geodineum/gCore /opt/geodineum/gNode-Client
            /etc/geodineum/bootstrap.env /etc/geodineum/components/gCore/gcore.env
            "$SITE_POOL_CREDS/valkey_client_${SP_SITE_ID}.password")
    for d in $SP_EXTRA_BASEDIR; do parts+=("$d"); done
    [[ "$SP_PRO" == 1 ]] && parts+=(/opt/geodineum/pro/gCore)
    local IFS=:; printf '%s' "${parts[*]}"
}

# /opt trees a WordPress site links in (themes, plugins, mu-plugins), resolved.
site_pool_detect_extra() {   # <docroot>...
    local root base l out=()
    for root in "$@"; do
        base="$root"; [[ -f "$root/public_html/wp-config.php" ]] && base="$root/public_html"
        while IFS= read -r l; do
            l=$(readlink -f "$l") || continue
            case "$l" in /opt/geodineum/gCore|/opt/geodineum/gCore/*|/opt/geodineum/gNode-Client*) ;; /opt/*) out+=("$l") ;; esac
        done < <(find "$base/wp-content/themes" "$base/wp-content/plugins" "$base/wp-content/mu-plugins" -maxdepth 1 -type l 2>/dev/null)
    done
    printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//'
}

site_pool_conf() {   # uses SP_*; prints the pool file
    local phpv="$1" id="$SP_SITE_ID" u="$SP_SITE_USER" st="$SITE_POOL_STATE/$SP_SITE_ID" lg="$SITE_POOL_LOGS/$SP_SITE_ID"
    cat <<EOF
; written by geodineum site pool — edit the record in $SITE_POOL_RECORDS/$id.env instead
[$id]
user = $u
group = $u
listen = /run/php/site-$id.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = ${SP_MAX_CHILDREN:-8}
pm.process_idle_timeout = 30s
pm.max_requests = 500
request_terminate_timeout = 30s
request_slowlog_timeout = 15s
slowlog = $lg/php-slow.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[error_log] = $lg/php-error.log
php_admin_value[session.save_path] = $st/sessions
php_admin_value[session.gc_probability] = 1
php_admin_value[sys_temp_dir] = $st/tmp
php_admin_value[upload_tmp_dir] = $st/tmp
php_admin_flag[session.upload_progress.enabled] = off
env[HOME] = $st/home
env[TMPDIR] = $st/tmp
env[GCORE_SITE_ID] = $id
env[GCORE_LOG_PATH] = $lg
env[GCORE_CACHE_PATH] = $st/cache
env[VALKEY_PASSWORD_FILE] = $SITE_POOL_CREDS/valkey_client_$id.password
EOF
    if [[ "$SP_BASEDIR" == 1 ]]; then
        printf 'php_admin_value[open_basedir] = %s\n' "$(site_pool_basedir)"
        # gCore reads its own pool's list here: an ini_get() in shared code returns another pool's value.
        printf 'env[GCORE_OPEN_BASEDIR] = %s\n' "$(site_pool_basedir)"
    fi
    return 0
}

site_pool_handler_conf() {   # <site_id>
    local host="site-${1//_/-}"
    cat <<EOF
# written by geodineum site pool
<Proxy "unix:/run/php/site-$1.sock|fcgi://$host">
    ProxySet timeout=35
</Proxy>
<FilesMatch "\.php$">
    SetHandler "proxy:unix:/run/php/site-$1.sock|fcgi://$host"
</FilesMatch>
EOF
}

# Every enabled vhost file serving one of the docroots.
site_pool_vhosts() {   # <docroot>...
    local d f
    for d in "$@"; do
        for f in /etc/apache2/sites-enabled/*.conf; do
            [[ -f "$f" ]] || continue
            grep -lE "^\s*DocumentRoot\s+\"?${d//./\\.}(/public_html|/public)?/?\"?\s*$" "$f" 2>/dev/null || true
        done
    done | xargs -r -n1 readlink -f | sort -u
}

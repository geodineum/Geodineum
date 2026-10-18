#!/bin/bash
#
# Geodineum CLI — Register
# ========================
# The one route that brings a service onto the constellation.
#   NEW        a skeleton of the kind asked for, every integration point wired
#              (lib/service-taxonomy.sh: the type matrix and its rows)
#   INTEGRATE  scan an existing codebase, say what it has and what it lacks,
#              then apply only the missing parts, through the same rows
# Registering again (a changed manifest, another environment) is the same
# command; there is no separate update verb.
#
# Requires: common.sh sourced first
#

usage_register() {
    cat <<'USAGE'
Usage: sudo geodineum register [<path>|<domain>|<name>] [--new <type> | --integrate] [options]

With no mode, register asks: set up a NEW service, or INTEGRATE an existing one.
A path to an existing directory means INTEGRATE.

NEW — a skeleton with its integration points wired (manifest, identity, topology,
heartbeat, COMMS, the beacon or form endpoint where there is a front end):
  public:   website-wp | website-static | app-pwa | webapp-gcore   (need a domain)
  internal: app | daemon | scheduled | gcore-service | custom
  --new <type>             the type (asked if omitted)
  --env <tier>             testing|staging|acceptance|production — REQUIRED, never assumed
  --lang <l>               bash|python|node|php (app, daemon, scheduled)
  --port <n>               app: the 127.0.0.1 port it serves (its /health is probed)
  --schedule <when>        scheduled: a systemd calendar expression (hourly, daily, *:0/15)
  --probe <p>              heartbeat probe: unit:<u> | tcp:<h>:<p> | http:<url> | pid:<f> | cmd:</abs>
  --theme <name>           website-wp child theme
  --mail-domain <d> | --no-mail   DKIM sender identity (public types default to their domain)
  --form | --no-form       COMMS form endpoint (website-static)
  --node <name>            register on this master for a service that runs on <name>
  --worker                 on that node: its files and units only
  --path <dir> --owner <tenant> --notify-email <addr> --no-ssl
  --matrix                 print the type matrix

INTEGRATE — scan, report, then apply only what is missing:
  --integrate [<path>]     the codebase (default: the positional path)
  --name <id>              its id (default: the manifest's, else the directory name)
  --env <tier>             as above (default: the manifest's environment)
  --type <type>            override the inferred type
  --probe <p>, --port <n>  override the heartbeat probe

Both: --dry-run (plan only) · --yes (no questions; --env and the type required)

Examples:
  sudo geodineum register                                        # asks
  sudo geodineum register example.com --new website-static --env production
  sudo geodineum register api_worker --new app --lang python --port 8090 --env testing
  sudo geodineum register nightly_sync --new scheduled --schedule daily --env production
  sudo geodineum register ~/gh/RINO/CourseMatch --env production   # integrate
  sudo geodineum deregister <id>                                 # the inverse
USAGE
}

# =============================================================================
# Detection — language and framework of an existing codebase
# =============================================================================
express_detect_language() {
    local path="$1"

    # Check for definitive project files first
    [[ -f "${path}/composer.json" ]] && { echo "php"; return 0; }
    [[ -f "${path}/wp-config.php" ]] && { echo "php"; return 0; }
    [[ -f "${path}/Cargo.toml" ]] && { echo "rust"; return 0; }
    [[ -f "${path}/go.mod" ]] && { echo "go"; return 0; }
    [[ -f "${path}/pyproject.toml" ]] && { echo "python"; return 0; }
    [[ -f "${path}/requirements.txt" ]] && { echo "python"; return 0; }
    [[ -f "${path}/setup.py" ]] && { echo "python"; return 0; }
    [[ -f "${path}/package.json" ]] && { echo "node"; return 0; }
    [[ -f "${path}/Gemfile" ]] && { echo "ruby"; return 0; }
    [[ -f "${path}/build.gradle" ]] || [[ -f "${path}/pom.xml" ]] && { echo "java"; return 0; }

    # Fall back to file extension counting (depth-limited)
    local counts=()
    local php_n py_n js_n rs_n go_n
    php_n=$(find "$path" -maxdepth 3 -name "*.php" 2>/dev/null | wc -l)
    py_n=$(find "$path" -maxdepth 3 -name "*.py" 2>/dev/null | wc -l)
    js_n=$(find "$path" -maxdepth 3 \( -name "*.js" -o -name "*.ts" \) -not -path "*/node_modules/*" 2>/dev/null | wc -l)
    rs_n=$(find "$path" -maxdepth 3 -name "*.rs" 2>/dev/null | wc -l)
    go_n=$(find "$path" -maxdepth 3 -name "*.go" 2>/dev/null | wc -l)

    local max=0 lang="unknown"
    for pair in "php:${php_n}" "python:${py_n}" "node:${js_n}" "rust:${rs_n}" "go:${go_n}"; do
        local l="${pair%%:*}" n="${pair##*:}"
        if [[ $n -gt $max ]]; then
            max=$n
            lang="$l"
        fi
    done

    echo "$lang"
}

express_detect_framework() {
    local path="$1"
    local lang="$2"

    case "$lang" in
        php)
            [[ -f "${path}/wp-config.php" ]] || [[ -f "${path}/wp-load.php" ]] && { echo "wordpress"; return 0; }
            grep -q '"laravel/framework"' "${path}/composer.json" 2>/dev/null && { echo "laravel"; return 0; }
            grep -q '"symfony/framework-bundle"' "${path}/composer.json" 2>/dev/null && { echo "symfony"; return 0; }
            grep -q '"slim/slim"' "${path}/composer.json" 2>/dev/null && { echo "slim"; return 0; }
            echo "php-generic"
            ;;
        python)
            grep -qi "fastapi" "${path}/requirements.txt" "${path}/pyproject.toml" 2>/dev/null && { echo "fastapi"; return 0; }
            grep -qi "django" "${path}/requirements.txt" "${path}/pyproject.toml" 2>/dev/null && { echo "django"; return 0; }
            grep -qi "flask" "${path}/requirements.txt" "${path}/pyproject.toml" 2>/dev/null && { echo "flask"; return 0; }
            echo "python-generic"
            ;;
        node)
            grep -q '"next"' "${path}/package.json" 2>/dev/null && { echo "nextjs"; return 0; }
            grep -q '"express"' "${path}/package.json" 2>/dev/null && { echo "express"; return 0; }
            grep -q '"fastify"' "${path}/package.json" 2>/dev/null && { echo "fastify"; return 0; }
            grep -q '"@nestjs/core"' "${path}/package.json" 2>/dev/null && { echo "nestjs"; return 0; }
            echo "node-generic"
            ;;
        rust)
            grep -q 'axum' "${path}/Cargo.toml" 2>/dev/null && { echo "axum"; return 0; }
            grep -q 'actix' "${path}/Cargo.toml" 2>/dev/null && { echo "actix"; return 0; }
            grep -q 'rocket' "${path}/Cargo.toml" 2>/dev/null && { echo "rocket"; return 0; }
            grep -q 'tokio' "${path}/Cargo.toml" 2>/dev/null && { echo "rust-async"; return 0; }
            echo "rust-generic"
            ;;
        go)
            grep -q 'gin-gonic' "${path}/go.mod" 2>/dev/null && { echo "gin"; return 0; }
            grep -q 'labstack/echo' "${path}/go.mod" 2>/dev/null && { echo "echo"; return 0; }
            grep -q 'go-chi/chi' "${path}/go.mod" 2>/dev/null && { echo "chi"; return 0; }
            echo "go-generic"
            ;;
        *)
            echo "generic"
            ;;
    esac
}

# =============================================================================
# INTEGRATE — what an existing codebase already has, and what it lacks
# =============================================================================
# Sets SCAN_* for the report and the plan. Reads only: files under the path,
# unit files in /etc/systemd/system, the apache vhosts, this host's credential
# and ledger, and (as root) the constellation in ValKey.

integrate_scan() {
    local path="$1" f
    SCAN_PATH="$path" SCAN_MANIFEST="" SCAN_SHAPE="" SCAN_CONSTELLATION="" SCAN_ID="" SCAN_ENV=""
    SCAN_LANG="" SCAN_FRAMEWORK="" SCAN_GNODE="" SCAN_WP=false SCAN_UNIT="" SCAN_TIMER="" SCAN_USER=""
    SCAN_PORT="" SCAN_HEARTBEAT="" SCAN_VHOST="" SCAN_DOMAIN="" SCAN_CRED=false SCAN_ENTITY="" SCAN_REGISTERED=false
    SCAN_DRIFT=false SCAN_FOREIGN=()

    for f in "$path/.geodineum/gnode_services.yaml" "$path/gnode_services.yaml" "$path/config/gnode_services.yaml"; do
        [[ -f "$f" ]] && { SCAN_MANIFEST="$f"; break; }
    done
    if [[ -n "$SCAN_MANIFEST" ]] && command -v yq >/dev/null 2>&1; then
        SCAN_SHAPE="$(yq eval '.gnode.shape // ""' "$SCAN_MANIFEST" 2>/dev/null)"
        SCAN_CONSTELLATION="$(yq eval '.gnode.constellation // ""' "$SCAN_MANIFEST" 2>/dev/null)"
        SCAN_ID="$(yq eval '.services[0].id // .gnode.heartbeat // ""' "$SCAN_MANIFEST" 2>/dev/null)"
        SCAN_ENV="$(yq eval '.environment // ""' "$SCAN_MANIFEST" 2>/dev/null)"
        SCAN_SHAPE="${SCAN_SHAPE/#null/}" SCAN_CONSTELLATION="${SCAN_CONSTELLATION/#null/}"
        SCAN_ID="${SCAN_ID/#null/}" SCAN_ENV="${SCAN_ENV/#null/}"
    fi
    [[ -n "$SCAN_ID" ]] || { SCAN_ID="$(basename "$path" | tr '[:upper:].-' '[:lower:]__')"; }

    SCAN_LANG="$(express_detect_language "$path")"
    SCAN_FRAMEWORK="$(express_detect_framework "$path" "$SCAN_LANG")"
    [[ -f "$path/wp-config.php" || -f "$path/wp-load.php" || -f "$path/public_html/wp-config.php" ]] && SCAN_WP=true
    if [[ -f "$path/composer.json" ]] && grep -q '"gcore/gnode-client"' "$path/composer.json" 2>/dev/null; then SCAN_GNODE="gNode-Client (composer)"
    elif grep -rqlE 'gcore-(standalone|loader)\.php' "$path" --include=*.php 2>/dev/null; then SCAN_GNODE="gCore"
    fi

    # How it runs: an operator unit that names this path.
    local u sd="${GEODINEUM_SYSTEMD_DIR:-/etc/systemd/system}"
    for u in "$sd"/*.service "$sd"/*.timer; do
        [[ -f "$u" ]] || continue
        grep -qE "^(WorkingDirectory|ExecStart)=.*${path%/}(/|\$| )" "$u" 2>/dev/null || continue
        case "$u" in
            *.timer) SCAN_TIMER="$(basename "$u")" ;;
            *) [[ -z "$SCAN_UNIT" && "$(basename "$u")" != geodineum-heartbeat@* ]] && SCAN_UNIT="$(basename "$u")" ;;
        esac
    done
    if [[ -n "$SCAN_UNIT" ]]; then
        local base="${SCAN_UNIT%.service}"
        [[ -f "$sd/${base}.timer" ]] && SCAN_TIMER="${base}.timer"
        SCAN_USER="$(sed -n 's/^User=//p' "$sd/$SCAN_UNIT" | head -n1)"
        SCAN_PORT="$(sed -nE 's/^Environment=.*\bPORT=([0-9]+).*/\1/p; s/^ExecStart=.*--port[ =]([0-9]+).*/\1/p' "$sd/$SCAN_UNIT" | head -n1)"
    fi
    [[ -z "$SCAN_PORT" && -f "$path/.env" ]] && SCAN_PORT="$(sed -nE 's/^PORT=([0-9]+).*/\1/p' "$path/.env" | head -n1)"

    if [[ -n "$(systemctl list-unit-files --no-legend "geodineum-heartbeat@${SCAN_ID}.timer" 2>/dev/null)" ]]; then SCAN_HEARTBEAT="geodineum-heartbeat@${SCAN_ID}.timer"
    elif grep -rqE ':gnode:heartbeat:' "$path" --include=*.{py,js,ts,php,rs,go,sh} 2>/dev/null; then SCAN_HEARTBEAT="in its own code"
    fi

    local v
    for v in "${GEODINEUM_APACHE_SITES:-/etc/apache2/sites-enabled}"/*.conf; do
        [[ -f "$v" ]] || continue
        grep -qE "^\s*DocumentRoot\s+${path%/}(/|\$)" "$v" 2>/dev/null || continue
        SCAN_VHOST="$v"; SCAN_DOMAIN="$(sed -nE 's/^\s*ServerName\s+(\S+).*/\1/p' "$v" | head -n1)"; break
    done

    [[ -e "${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SCAN_ID}.password" ]] && SCAN_CRED=true
    if [[ -f "$path/.geodineum/.registered" ]]; then
        SCAN_REGISTERED=true
        local was now
        was="$(sed -n 's/^config_hash: //p' "$path/.geodineum/.registered")"
        now="$( [[ -n "$SCAN_MANIFEST" ]] && sha256sum "$SCAN_MANIFEST" | cut -d' ' -f1 )"
        if [[ -n "$was" && -n "$now" && "$was" != "$now" ]]; then SCAN_DRIFT=true; fi
    fi
    if [[ $EUID -eq 0 && -r "${GEODINEUM_CREDENTIALS_DIR}/valkey.password" ]]; then
        # shellcheck source=/dev/null
        source "${GNODE_SCRIPTS}/cli/constellation.sh" 2>/dev/null || true
        local c
        while IFS= read -r c; do
            [[ "$(REDISCLI_AUTH="$(<"${GEODINEUM_CREDENTIALS_DIR}/valkey.password")" valkey-cli --no-auth-warning --raw -h "$VALKEY_HOST" -p "$VALKEY_PORT" HEXISTS "{$c}:gnode:constellation:entities" "$SCAN_ID" 2>/dev/null)" == 1 ]] && { SCAN_ENTITY="$c"; break; }
        done < <(gnode_cli_constellations 2>/dev/null)
    fi

    # Streams it names that are not its own: grant requests, never grants.
    local k
    while IFS= read -r k; do
        if [[ -n "$k" && "$k" != "{${SCAN_ID}}"* ]]; then SCAN_FOREIGN+=("$k"); fi
    done < <(grep -rhoE '"\{[a-z0-9_]+\}:[A-Za-z0-9:_*.-]+"' "$path" --include=*.{py,js,ts,php,rs,go,sh} 2>/dev/null | tr -d '"' | sort -u | head -n 20)
    return 0
}

# The type an existing service is closest to.
integrate_type() {
    if [[ "$SCAN_WP" == true ]]; then echo website-wp
    elif [[ -n "$SCAN_TIMER" ]]; then echo scheduled
    elif [[ "$SCAN_SHAPE" == site || ( -n "$SCAN_VHOST" && -z "$SCAN_UNIT" ) ]]; then echo website-static
    elif [[ "$SCAN_SHAPE" == app || ( -n "$SCAN_UNIT" && -n "$SCAN_PORT" ) ]]; then echo app
    elif [[ -n "$SCAN_UNIT" || "$SCAN_SHAPE" == daemon ]]; then echo daemon
    else echo custom
    fi
}

register_integrate() {
    local path="" id="" env="" type="" yes=false dry=false probe="" port=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)    id="$2"; shift 2 ;;
            --env)     env="$2"; shift 2 ;;
            --type|--new) type="$2"; shift 2 ;;
            --probe)   probe="$2"; shift 2 ;;
            --port)    port="$2"; shift 2 ;;
            --yes|-y)  yes=true; shift ;;
            --dry-run) dry=true; shift ;;
            -*) log_error "Unknown option for --integrate: $1"; exit 2 ;;
            *) [[ -z "$path" ]] || { log_error "Unexpected argument: $1"; exit 2; }; path="$1"; shift ;;
        esac
    done
    [[ -n "$path" ]] || { log_error "--integrate needs the path of the codebase"; exit 2; }
    [[ -d "$path" ]] || { log_error "Not a directory: $path"; exit 2; }
    path="$(cd "$path" && pwd -P)"

    integrate_scan "$path"
    [[ -n "$id" ]] && SCAN_ID="$id"
    [[ -n "$port" ]] && SCAN_PORT="$port"
    validate_site_id "$SCAN_ID" || exit 1
    [[ -n "$type" ]] || type="$(integrate_type)"
    taxonomy_is_type "$type" || { log_error "Unknown type '$type' (types: ${GEO_SERVICE_TYPES[*]})"; exit 2; }
    env="${env:-$SCAN_ENV}"

    # What it has, what it lacks, and what register will do about each.
    local -a has=() missing=() plan=() rows=()
    [[ -n "$SCAN_MANIFEST" ]] && has+=("manifest (${SCAN_SHAPE:-no gnode: block}${SCAN_CONSTELLATION:+, constellation ${SCAN_CONSTELLATION}})") \
        || { missing+=("manifest"); plan+=("write .geodineum/gnode_services.yaml (shape from the type, own namespace only)"); rows+=(manifest); }
    [[ -n "$SCAN_UNIT" ]] && has+=("systemd unit ${SCAN_UNIT}${SCAN_USER:+ (User=${SCAN_USER})}")
    [[ -n "$SCAN_TIMER" ]] && has+=("timer ${SCAN_TIMER}")
    [[ -n "$SCAN_VHOST" ]] && has+=("vhost ${SCAN_DOMAIN:-$(basename "$SCAN_VHOST")}")
    [[ -n "$SCAN_GNODE" ]] && has+=("speaks gNode via ${SCAN_GNODE}")
    if [[ "$SCAN_CRED" == true || -n "$SCAN_ENTITY" ]]; then
        local ent=""; if [[ -n "$SCAN_ENTITY" ]]; then ent=" + topology entity in {${SCAN_ENTITY}}"; fi
        has+=("identity${ent}")
        local why=""; if [[ "$SCAN_DRIFT" == true ]]; then why=", grants recomposed (the manifest changed)"; fi
        plan+=("re-register: identity kept, topology and intent refreshed${why}")
    else
        missing+=("ValKey identity" "topology registration")
        plan+=("onboard: identity (own namespace grants), streams, topology entity and intent")
    fi
    rows+=(onboard)
    if [[ -n "$SCAN_HEARTBEAT" ]]; then
        has+=("heartbeat (${SCAN_HEARTBEAT})")
    elif [[ "$type" != website-* && "$type" != custom ]]; then
        local hp="${probe}"
        # An existing app serves what it serves: probe its port, unless --probe names a URL.
        [[ -z "$hp" && -n "$SCAN_PORT" ]] && hp="tcp:127.0.0.1:${SCAN_PORT}"
        [[ -z "$hp" && -n "$SCAN_TIMER" ]] && hp="unit:${SCAN_TIMER}"
        [[ -z "$hp" && -n "$SCAN_UNIT" ]] && hp="unit:${SCAN_UNIT}"
        if [[ -n "$hp" ]]; then
            missing+=("heartbeat"); plan+=("heartbeat while ${hp} passes (the probe is the proof)"); rows+=(heartbeat); probe="$hp"
        else
            missing+=("heartbeat (nothing to probe: give --probe)")
        fi
    fi
    [[ "$SCAN_WP" == true ]] && plan+=("wire WordPress: gCore mu-plugin + gTemplate parent theme")

    echo ""
    echo -e "${BOLD}${SCAN_ID}${NC} at ${path}"
    echo "  what it is    ${SCAN_LANG}${SCAN_FRAMEWORK:+ (${SCAN_FRAMEWORK})} · closest type: ${type}${SCAN_PORT:+ · port ${SCAN_PORT}}"
    echo "  has           $( IFS=';'; echo "${has[*]:-nothing Geodineum-specific}" | sed 's/;/ · /g')"
    echo "  missing       $( IFS=';'; echo "${missing[*]:-nothing}" | sed 's/;/ · /g')"
    local i=1 p
    for p in "${plan[@]}"; do echo "  will ${i}.     ${p}"; i=$((i + 1)); done
    if [[ ${#SCAN_FOREIGN[@]} -gt 0 ]]; then
        echo "  other namespaces its code names (never granted here; request them:  sudo geodineum grants request ${SCAN_ID} <pattern>):"
        printf '                %s\n' "${SCAN_FOREIGN[@]}"
    fi
    if [[ -z "$env" && "$dry" == true ]]; then
        echo "  environment   — (pass --env; the manifest names none)"
        echo ""; log_info "Dry run — nothing changed"; return 0
    fi
    if [[ -z "$env" ]]; then
        [[ "$yes" == true || ! -t 0 ]] && { log_error "No environment: pass --env (nothing is assumed)"; exit 2; }
        read -r -p "  DTAP environment (testing|staging|acceptance|production): " env
    fi
    validate_environment "$env" || exit 1
    [[ "$dry" == true ]] && { echo ""; log_info "Dry run — nothing changed"; return 0; }
    require_sudo "Registration"
    if [[ "$yes" != true ]]; then
        local go; read -r -p "  Proceed? [Y/n] " go < /dev/tty
        [[ -z "$go" || "$go" =~ ^[Yy] ]] || { log_info "Cancelled — nothing changed"; return 0; }
    fi

    # Through the same rows as NEW, so the ledger records what this created.
    SVC_TYPE="$type" SVC_NAME="$SCAN_ID" SVC_PATH="$path" SVC_ENV="$env" SVC_DOMAIN="${SCAN_DOMAIN}"
    SVC_PROFILE="${GEO_TYPE_PROFILE[$type]}" SVC_LANG="$SCAN_LANG" SVC_PORT="$SCAN_PORT" SVC_PROBE="$probe"
    SVC_UNIT="$SCAN_UNIT" SVC_NODE="" SVC_WORKER=false SVC_DRY_RUN=false SVC_YES=true SVC_FORM=false
    SVC_OWNER="" SVC_NOTIFY_EMAIL="" SVC_MAIL_DOMAIN="" SVC_THEME="" SVC_NO_SSL=true
    SVC_MANIFEST_DIR="$(dirname "${SCAN_MANIFEST:-$path/.geodineum/gnode_services.yaml}")"
    # shellcheck source=/dev/null
    source "${GNODE_SCRIPTS}/cli/constellation.sh" 2>/dev/null || true
    SVC_CONSTELLATION="${SCAN_CONSTELLATION:-$(gnode_cli_constellation 2>/dev/null || echo geodineum)}"
    # The credential is read by the user the service already runs as.
    SVC_GROUP="geodineum"
    if [[ -n "$SCAN_USER" ]] && id "$SCAN_USER" >/dev/null 2>&1; then SVC_GROUP="$(id -gn "$SCAN_USER")"; fi
    case "$type" in website-*|app-pwa|webapp-gcore) SVC_CRED_GROUP="geodineum-web" ;; *) SVC_CRED_GROUP="$SVC_GROUP" ;; esac
    [[ "$SCAN_DRIFT" == true ]] && SVC_REGRANT=true

    local r
    for r in "${rows[@]}"; do log_step "${r}"; "ensure_${r}"; done
    [[ "$SCAN_WP" == true ]] && { log_step "WordPress integration"; setup_wordpress_integration "$path"; }

    print_summary_header "Registered: ${SCAN_ID}"
    echo "    sudo geodineum status ${SCAN_ID}"
    echo "    sudo geodineum deregister ${SCAN_ID}     # the inverse"
    echo ""
}

# =============================================================================
# geodineum register — the router
# =============================================================================

cmd_register() {
    local mode="" type="" target="" ; local -a rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new)       mode=new; if [[ $# -gt 1 && "$2" != -* ]]; then type="$2"; shift; fi; shift ;;
            --integrate) mode=integrate; shift ;;
            --matrix)    source "${LIB_DIR:-${GEODINEUM_CLI_ROOT}/lib}/service-taxonomy.sh"; taxonomy_print_matrix; return 0 ;;
            -h|--help)   usage_register; return 0 ;;
            --*)         rest+=("$1"); if [[ $# -gt 1 && "$2" != -* && "$1" =~ ^--(env|lang|port|schedule|probe|theme|mail-domain|node|path|owner|notify-email|name|type|domain)$ ]]; then rest+=("$2"); shift; fi; shift ;;
            *)           [[ -z "$target" ]] || { log_error "Unexpected argument: $1"; return 2; }; target="$1"; shift ;;
        esac
    done
    # shellcheck source=/dev/null
    source "${GEODINEUM_CLI_ROOT}/lib/service-taxonomy.sh"

    if [[ -z "$mode" ]]; then
        if [[ -n "$target" && -d "$target" ]]; then
            mode=integrate
        elif [[ -t 0 ]]; then
            echo ""
            echo -e "${BOLD}Register a service${NC}"
            echo "  1) Set up a NEW service       a skeleton of the kind you choose, wired to Geodineum"
            echo "  2) INTEGRATE an existing one  scan its code, show what it lacks, add only that"
            local m; read -r -p "  Choice [1-2]: " m < /dev/tty
            case "$m" in 1) mode=new ;; 2) mode=integrate ;; *) log_error "Nothing chosen"; return 2 ;; esac
            if [[ "$mode" == integrate && -z "$target" ]]; then
                read -r -p "  Path of the codebase: " target < /dev/tty
            fi
        else
            log_error "Non-interactive: pass --new <type> or a path to integrate"
            return 2
        fi
    fi

    if [[ "$mode" == new ]]; then
        local -a a=()
        [[ -n "$type" ]] && a+=(--type "$type")
        [[ -n "$target" ]] && a+=("$target")
        register_new "${a[@]}" "${rest[@]}"
    else
        register_integrate "$target" "${rest[@]}"
    fi
}

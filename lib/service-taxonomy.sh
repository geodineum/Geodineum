#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — Service Taxonomy (geodineum service new)
# ==========================================================
# The interview asks WHAT IT IS; the requirement matrix decides WHAT RUNS;
# the paved road (provision → register → heartbeat → mail-verify → verify)
# is the same for every type. The matrix is DATA — interview, engine, and
# docs all read the tables below; there is no second copy.
#
# Types:
#   PUBLIC    website-wp | website-static | app-pwa
#   INTERNAL  daemon | gcore-service | custom
#
# Requires: common.sh sourced first. site.sh is lazy-loaded for the
# WordPress delegate row.
#

# =============================================================================
# Taxonomy — the requirement matrix as data
# =============================================================================

GEO_SERVICE_TYPES=(website-wp website-static app-pwa daemon gcore-service custom)

declare -A GEO_TYPE_LABEL=(
    [website-wp]="WordPress website (full CMS + gCore runtime)"
    [website-static]="Static website (plain files, optional COMMS form endpoint)"
    [app-pwa]="App / PWA (static shell + web-app manifest + service worker)"
    [daemon]="Daemon (systemd unit, own system user)"
    [gcore-service]="gCore service (PHP headless, no WordPress)"
    [custom]="Custom (mesh identity only — bring your own runtime)"
)

declare -A GEO_TYPE_VISIBILITY=(
    [website-wp]=public
    [website-static]=public
    [app-pwa]=public
    [daemon]=internal
    [gcore-service]=internal
    [custom]=internal
)

# Capability profile driving the 30-dim topology vector (manifest profile:).
declare -A GEO_TYPE_PROFILE=(
    [website-wp]=web
    [website-static]=web
    [app-pwa]=web
    [daemon]=service
    [gcore-service]=service
    [custom]=service
)

# Credential sidecar model: which group may read the ValKey credential.
# web    → geodineum-web (sole member www-data — the PHP/web reader)
# shared → geodineum (internal, www-data must NOT read)
# own    → the service's own single-member group (created with the user)
declare -A GEO_TYPE_CRED_GROUP=(
    [website-wp]=geodineum-web
    [website-static]=geodineum-web
    [app-pwa]=geodineum-web
    [daemon]=OWN
    [gcore-service]=geodineum
    [custom]=geodineum
)

# Executable rows per type, in order. Each row is an ensure_<row> function
# below wrapping EXISTING machinery; onboarding is always the last row —
# every type ends on the same paved road.
declare -A GEO_TYPE_ROWS=(
    [website-wp]="mail wp_stack notify"
    [website-static]="docroot skeleton_static form_endpoint vhost manifest mail onboard web_perms"
    [app-pwa]="docroot skeleton_pwa form_endpoint vhost manifest mail onboard web_perms"
    [daemon]="own_user service_dirs manifest systemd_unit heartbeat mail onboard"
    [gcore-service]="code_group service_dirs gcore_bootstrap manifest systemd_unit heartbeat mail onboard"
    [custom]="manifest mail onboard"
)

# Delegated provisioning (--node): only the master-side rows run here; the
# filesystem rows belong to the worker and are printed as a checklist.
GEO_DELEGATED_ROWS="manifest mail onboard"

taxonomy_is_type() {
    local t
    for t in "${GEO_SERVICE_TYPES[@]}"; do [[ "$t" == "$1" ]] && return 0; done
    return 1
}

# Print the requirement matrix (docs/help surface reads the same data).
taxonomy_print_matrix() {
    local t
    echo ""
    printf "  %-16s %-9s %-9s %-14s %s\n" "TYPE" "SCOPE" "PROFILE" "CRED GROUP" "ROWS"
    for t in "${GEO_SERVICE_TYPES[@]}"; do
        printf "  %-16s %-9s %-9s %-14s %s\n" "$t" \
            "${GEO_TYPE_VISIBILITY[$t]}" "${GEO_TYPE_PROFILE[$t]}" \
            "${GEO_TYPE_CRED_GROUP[$t]}" "${GEO_TYPE_ROWS[$t]}"
    done
    echo ""
}

# =============================================================================
# Row implementations — thin wrappers over existing machinery
# =============================================================================
# All rows read the SVC_* globals resolved by cmd_service_new and honour
# SVC_DRY_RUN. A failed row aborts the run (fail-loud, no silent partials).

# --- website-wp: delegate wholesale to the existing WordPress paved path ----
ensure_wp_stack() {
    source "${GEODINEUM_CLI_ROOT}/lib/site.sh"
    local -a args=("$SVC_DOMAIN" --env "$SVC_ENV")
    [[ -n "$SVC_THEME" ]] && args+=(--theme "$SVC_THEME")
    [[ -n "$SVC_OWNER" ]] && args+=(--owner "$SVC_OWNER")
    [[ "$SVC_NO_SSL" == "true" ]] && args+=(--no-ssl)
    [[ "$SVC_DRY_RUN" == "true" ]] && args+=(--dry-run)
    cmd_new_site "${args[@]}"
}

# --- notify: wire the COMMS email channel after the WP paved path ----------
# The WordPress delegate onboards without --notify-email; a second onboarding
# pass is idempotent (identity/streams skip) and adds the channel + the
# dispatch-verification probe.
ensure_notify() {
    [[ -n "$SVC_NOTIFY_EMAIL" ]] || { log_info "Notify: skipped (no --notify-email)"; return 0; }
    local onboard="${GNODE_SCRIPTS}/onboard-service.sh"
    [[ -x "$onboard" ]] || onboard="${GEODINEUM_ROOT}/gNode/scripts/onboard-service.sh"
    [[ -x "$onboard" ]] || { log_warning "onboard-service.sh not found — set recipients later"; return 0; }
    local -a args=("$SVC_NAME" --environment "$SVC_ENV" --notify-email "$SVC_NOTIFY_EMAIL")
    [[ "$SVC_DRY_RUN" == "true" ]] && args+=(--dry-run)
    "$onboard" "${args[@]}"
}

# --- docroot: /var/www/<domain>/public_html + uploads OUTSIDE the docroot ---
ensure_docroot() {
    local root="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Create ${root}/public_html + ${root}/uploads (root:www-data 750)"
        return 0
    fi
    mkdir -p "${root}/public_html" "${root}/uploads"
    chown root:www-data "$root" "${root}/public_html"
    chown www-data:www-data "${root}/uploads"
    chmod 750 "$root" "${root}/public_html" "${root}/uploads"
    # DTAP tier as a root-owned file: staging/production flips are an operator
    # action, never a code edit. The form endpoint fails safe without it.
    printf '%s\n' "$SVC_ENV" > "${root}/.env-tier"
    chown root:www-data "${root}/.env-tier"
    chmod 640 "${root}/.env-tier"
    log_success "Docroot: ${root}/public_html (uploads kept outside)"
}

# --- static skeleton -------------------------------------------------------
ensure_skeleton_static() {
    local docroot="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}/public_html"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Render static skeleton into ${docroot}"
        return 0
    fi
    if [[ -f "${docroot}/index.html" ]]; then
        log_warning "index.html already exists — skipping skeleton"
        return 0
    fi
    DOMAIN="$SVC_DOMAIN" SITE_ID="$SVC_NAME" \
        render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/index.html.tpl" \
        "${docroot}/index.html"
    mkdir -p "${docroot}/assets"
    log_success "Static skeleton rendered (index.html + assets/)"
}

# --- PWA skeleton: static shell + web-app manifest + service worker --------
ensure_skeleton_pwa() {
    local docroot="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}/public_html"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Render PWA skeleton into ${docroot}"
        return 0
    fi
    if [[ -f "${docroot}/index.html" ]]; then
        log_warning "index.html already exists — skipping skeleton"
    else
        DOMAIN="$SVC_DOMAIN" SITE_ID="$SVC_NAME" \
            render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/index.html.tpl" \
            "${docroot}/index.html"
    fi
    mkdir -p "${docroot}/assets"
    if [[ ! -f "${docroot}/manifest.webmanifest" ]]; then
        cat > "${docroot}/manifest.webmanifest" << MANEOF
{
  "name": "${SVC_DOMAIN}",
  "short_name": "${SVC_NAME}",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#111111",
  "icons": []
}
MANEOF
    fi
    if [[ ! -f "${docroot}/sw.js" ]]; then
        cat > "${docroot}/sw.js" << 'SWEOF'
// Minimal offline-first service worker. Extend the cache list as the app grows.
const CACHE = 'app-v1';
const ASSETS = ['/', '/index.html', '/manifest.webmanifest'];
self.addEventListener('install', (e) => {
    e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
});
self.addEventListener('fetch', (e) => {
    e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
});
SWEOF
    fi
    log_success "PWA skeleton rendered (manifest.webmanifest + sw.js)"
}

# --- form endpoint: generalized COMMS producer (the palacio pattern) --------
ensure_form_endpoint() {
    [[ "$SVC_FORM" == "true" ]] || { log_info "Form endpoint: skipped (--no-form)"; return 0; }
    local root="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}"
    local docroot="${root}/public_html"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Render form/submit.php producing to {${SVC_NAME}}:gnode:comms:{env}"
        return 0
    fi
    if [[ -f "${docroot}/form/submit.php" ]]; then
        log_warning "form/submit.php already exists — skipping"
        return 0
    fi
    mkdir -p "${docroot}/form"
    SITE_ID="$SVC_NAME" DOMAIN="$SVC_DOMAIN" \
    TIER_FILE="${root}/.env-tier" \
    CREDENTIAL_FILE="${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password" \
        render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/form-submit.php.tpl" \
        "${docroot}/form/submit.php"
    log_success "Form endpoint: form/submit.php → {${SVC_NAME}}:gnode:comms:{env}"
}

# --- apache vhost + certbot -------------------------------------------------
ensure_vhost() {
    local docroot="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}/public_html"
    local conf="/etc/apache2/sites-available/${SVC_DOMAIN}.conf"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Write ${conf}, a2ensite, reload apache"
        [[ "$SVC_NO_SSL" != "true" ]] && log_dry "certbot --apache -d ${SVC_DOMAIN}"
        return 0
    fi
    if [[ ! -d /etc/apache2/sites-available ]]; then
        log_error "Apache not installed — a public service type needs a web server"
        return 1
    fi
    # www alias only for apex domains
    local www_alias=""
    [[ "$(tr -dc '.' <<< "$SVC_DOMAIN" | wc -c)" -eq 1 ]] && www_alias="www.${SVC_DOMAIN}"
    if [[ -f "$conf" ]]; then
        log_warning "vhost already exists: ${conf} — left untouched"
    else
        cat > "$conf" << VHEOF
<VirtualHost *:80>
    ServerName ${SVC_DOMAIN}
${www_alias:+    ServerAlias ${www_alias}
}    DocumentRoot ${docroot}

    <Directory ${docroot}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <DirectoryMatch "/\.">
        Require all denied
    </DirectoryMatch>

    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
        Header always set Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/${SVC_DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${SVC_DOMAIN}_access.log combined
</VirtualHost>
VHEOF
        chmod 640 "$conf"
        a2ensite "${SVC_DOMAIN}.conf" >/dev/null
        log_success "vhost written + enabled: ${conf}"
    fi
    apachectl configtest >/dev/null 2>&1 && systemctl reload apache2 \
        || { log_error "apache configtest failed — vhost not live"; return 1; }
    if [[ "$SVC_NO_SSL" == "true" ]]; then
        log_info "SSL skipped (--no-ssl). Later: sudo certbot --apache -d ${SVC_DOMAIN}"
    elif command -v certbot >/dev/null 2>&1; then
        local -a cb=(certbot --apache -d "$SVC_DOMAIN")
        [[ -n "$www_alias" ]] && cb+=(-d "$www_alias")
        [[ "$SVC_YES" == "true" ]] && cb+=(--non-interactive --agree-tos)
        "${cb[@]}" || {
            log_warning "certbot did not complete (DNS not pointed yet?)"
            log_info "Re-run later: sudo certbot --apache -d ${SVC_DOMAIN}"
        }
    else
        log_warning "certbot not installed — site is HTTP-only"
    fi
}

# --- own system user + group (daemon pattern) --------------------------------
ensure_own_user() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Create system user+group '${SVC_NAME}' (no shell, no home login)"
        return 0
    fi
    getent group "$SVC_NAME" >/dev/null 2>&1 || groupadd --system "$SVC_NAME"
    id "$SVC_NAME" >/dev/null 2>&1 || \
        useradd --system --gid "$SVC_NAME" --home-dir "$SVC_PATH" \
            --no-create-home --shell /usr/sbin/nologin "$SVC_NAME"
    log_success "System user: ${SVC_NAME}:${SVC_NAME}"
}

# --- geodineum-code membership (gCore consumers read shared source) ----------
ensure_code_group() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Create user '${SVC_NAME}' + add to geodineum-code (reads gCore source)"
        return 0
    fi
    ensure_own_user
    if getent group geodineum-code >/dev/null 2>&1; then
        usermod -aG geodineum-code "$SVC_NAME"
        log_success "User ${SVC_NAME} added to geodineum-code"
    else
        log_warning "geodineum-code group missing — gCore source may be unreadable for ${SVC_NAME}"
    fi
    # Cred model for this type is root:geodineum:640 — the runtime user reads
    # it through geodineum membership (NEVER www-data).
    if getent group geodineum >/dev/null 2>&1; then
        usermod -aG geodineum "$SVC_NAME"
    fi
}

# --- service dirs: /opt/geodineum/services/<name> ----------------------------
ensure_service_dirs() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Create ${SVC_PATH}/{src,.geodineum} (root:${SVC_GROUP} 750)"
        return 0
    fi
    mkdir -p "${SVC_PATH}/src"
    create_geodineum_dir "$SVC_PATH" "$SVC_NAME" "$SVC_ENV"
    chown "root:${SVC_GROUP}" "$SVC_PATH" "${SVC_PATH}/src"
    chmod 750 "$SVC_PATH" "${SVC_PATH}/src"
    log_success "Service root: ${SVC_PATH}"
}

# --- gCore bootstrap (PHP headless) ------------------------------------------
ensure_gcore_bootstrap() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Render src/bootstrap.php (gCore standalone entry)"
        return 0
    fi
    local out="${SVC_PATH}/src/bootstrap.php"
    if [[ -f "$out" ]]; then
        log_warning "bootstrap.php already exists — skipping"
        return 0
    fi
    SERVICE_NAME="$SVC_NAME" SERVICE_ID="$SVC_NAME" SITE_ID="$SVC_NAME" \
    SERVICE_ENV="$SVC_ENV" \
        render_template "${GEODINEUM_CLI_ROOT}/templates/bootstrap-gcore.php.tpl" "$out"
    log_success "gCore bootstrap: src/bootstrap.php"
}

# --- unified onboarding manifest (one schema — profile/env/consumes/produces)
ensure_manifest() {
    local dir manifest
    if [[ -n "$SVC_NODE" ]]; then
        # Delegated: the manifest lives on the master (policy source for the
        # ACL composition); the service's files live on the worker.
        dir="/etc/geodineum/manifests/${SVC_NAME}"
    else
        dir="${SVC_PATH}/.geodineum"
    fi
    manifest="${dir}/gnode_services.yaml"
    SVC_MANIFEST_DIR="$dir"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Write unified manifest ${manifest} (profile=${SVC_PROFILE} env=${SVC_ENV})"
        return 0
    fi
    mkdir -p "$dir"
    if [[ -f "$manifest" ]]; then
        log_warning "Manifest already exists — left untouched: ${manifest}"
        return 0
    fi
    local produces_extra=""
    [[ "$SVC_FORM" == "true" ]] && produces_extra="
  - \"{${SVC_NAME}}:forms:*\"         # submission archive + rate-limit counters"
    cat > "$manifest" << MFEOF
# Geodineum onboarding manifest — ONE schema (profile + environment +
# consumes/produces drive registration and the composed ValKey ACL).
# Contract: CONTRACTS/SERVICE_ONBOARDING.md

profile: ${SVC_PROFILE}
environment: ${SVC_ENV}

services:
  - id: "${SVC_NAME}"
    metadata:
      description: "${GEO_TYPE_LABEL[$SVC_TYPE]}"
      type: "${SVC_TYPE}"
      tier: "SERVICE"
      created_by: "geodineum service new"

# Own-namespace only (braces literal = hash-tag). Anything foreign is
# refused at onboarding — request cross-service access via the grant loop.
consumes: []
produces:
  - "{${SVC_NAME}}:gnode:comms:*"   # notifications → COMMS dispatch${produces_extra}
MFEOF
    chmod 640 "$manifest"
    log_success "Manifest: ${manifest} (profile=${SVC_PROFILE}, env=${SVC_ENV})"
}

# --- systemd unit: one generic template + per-service env file --------------
ensure_systemd_unit() {
    local unit="/etc/systemd/system/geodineum-${SVC_NAME}.service"
    local envfile="/etc/geodineum/services/${SVC_NAME}.env"
    local run_user="$SVC_NAME"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Install ${unit} (User=${run_user}, ExecStart=${SVC_PATH}/run) + ${envfile}"
        return 0
    fi
    mkdir -p /etc/geodineum/services
    if [[ ! -f "$envfile" ]]; then
        cat > "$envfile" << ENVEOF
GNODE_SITE_ID=${SVC_NAME}
GNODE_ENVIRONMENT=${SVC_ENV}
VALKEY_HOST=${VALKEY_HOST:-127.0.0.1}
VALKEY_PORT=${VALKEY_PORT:-47445}
VALKEY_USER=gnode_client_${SVC_NAME}
VALKEY_PASSWORD_FILE=${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password
ENVEOF
        chown "root:${SVC_GROUP}" "$envfile"
        chmod 640 "$envfile"
    fi
    if [[ ! -x "${SVC_PATH}/run" ]]; then
        cat > "${SVC_PATH}/run" << 'RUNEOF'
#!/bin/bash
# Service entrypoint — replace with the real process (long-running, foreground).
set -euo pipefail
echo "geodineum service '${GNODE_SITE_ID}' has no implementation yet" >&2
echo "replace $(dirname "$0")/run with the real entrypoint" >&2
sleep infinity
RUNEOF
        chown "root:${SVC_GROUP}" "${SVC_PATH}/run"
        chmod 750 "${SVC_PATH}/run"
    fi
    if [[ -f "$unit" ]]; then
        log_warning "Unit already exists — left untouched: ${unit}"
    else
        cat > "$unit" << UNITEOF
[Unit]
Description=Geodineum service: ${SVC_NAME}
After=network.target valkey-gnode.service

[Service]
Type=simple
User=${run_user}
Group=${SVC_GROUP}
EnvironmentFile=${envfile}
WorkingDirectory=${SVC_PATH}
ExecStart=${SVC_PATH}/run
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SVC_PATH}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF
        chmod 644 "$unit"
        systemctl daemon-reload
        systemctl enable "geodineum-${SVC_NAME}.service" >/dev/null 2>&1 || true
        log_success "Unit installed + enabled (not started — deploy code first): ${unit}"
    fi
}

# --- heartbeat wiring: timer pair, honest by construction --------------------
# SETEX only while the main unit is ACTIVE (ExecCondition gate) — a written
# timer must never report a dead service green.
ensure_heartbeat() {
    local hb_service="/etc/systemd/system/geodineum-${SVC_NAME}-heartbeat.service"
    local hb_timer="/etc/systemd/system/geodineum-${SVC_NAME}-heartbeat.timer"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Install heartbeat timer (60s SETEX, gated on geodineum-${SVC_NAME}.service active)"
        return 0
    fi
    local hb_script="${SVC_PATH}/heartbeat.sh"
    if [[ ! -x "$hb_script" ]]; then
        cat > "$hb_script" << 'HSEOF'
#!/bin/bash
# Heartbeat sender — env comes from the unit's EnvironmentFile.
# Key contract: CONTRACTS/heartbeat.md (node segment = short hostname).
set -euo pipefail
node="$(hostname -s)"
REDISCLI_AUTH="$(cat "${VALKEY_PASSWORD_FILE}")" \
    valkey-cli -h "${VALKEY_HOST}" -p "${VALKEY_PORT}" --user "${VALKEY_USER}" \
    SETEX "{geodineum}:gnode:heartbeat:${GNODE_ENVIRONMENT}:${GNODE_SITE_ID}:${node}" \
    120 "{\"ts\":$(date +%s),\"node\":\"${node}\"}" >/dev/null
HSEOF
        chown "root:${SVC_GROUP}" "$hb_script"
        chmod 750 "$hb_script"
    fi
    if [[ ! -f "$hb_service" ]]; then
        cat > "$hb_service" << HBEOF
[Unit]
Description=Heartbeat for geodineum-${SVC_NAME} (green only while the service is active)

[Service]
Type=oneshot
User=${SVC_NAME}
Group=${SVC_GROUP}
EnvironmentFile=/etc/geodineum/services/${SVC_NAME}.env
ExecCondition=/bin/systemctl is-active --quiet geodineum-${SVC_NAME}.service
ExecStart=${hb_script}
HBEOF
        chmod 644 "$hb_service"
    fi
    if [[ ! -f "$hb_timer" ]]; then
        cat > "$hb_timer" << HTEOF
[Unit]
Description=Heartbeat schedule for geodineum-${SVC_NAME}

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
HTEOF
        chmod 644 "$hb_timer"
        systemctl daemon-reload
        systemctl enable --now "geodineum-${SVC_NAME}-heartbeat.timer" >/dev/null 2>&1 || true
    fi
    log_success "Heartbeat wired: {geodineum}:gnode:heartbeat:${SVC_ENV}:${SVC_NAME}:\$(hostname -s)"
}

# --- mail: DKIM + authorized sender domain (setup-mail-stack.sh) -------------
ensure_mail() {
    if [[ -z "$SVC_MAIL_DOMAIN" ]]; then
        log_info "Mail: skipped (no sender domain — --no-mail, or pass --mail-domain)"
        return 0
    fi
    local script="${GEODINEUM_CLI_ROOT}/scripts/setup-mail-stack.sh"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "setup-mail-stack.sh ${SVC_MAIL_DOMAIN} (DKIM + milter + authorized-domains)"
        return 0
    fi
    [[ -x "$script" ]] || { log_error "setup-mail-stack.sh not found at ${script}"; return 1; }
    "$script" "$SVC_MAIL_DOMAIN" || {
        log_error "Mail-stack provisioning failed for ${SVC_MAIL_DOMAIN}"
        return 1
    }
    log_info "Publish the printed DNS records, then verify: geodineum mail records ${SVC_MAIL_DOMAIN}"
}

# --- the paved road: onboard (identity + streams + register + mail probe) ---
ensure_onboard() {
    local onboard="${GNODE_SCRIPTS}/onboard-service.sh"
    [[ -x "$onboard" ]] || onboard="${GEODINEUM_ROOT}/gNode/scripts/onboard-service.sh"
    if [[ ! -x "$onboard" ]]; then
        log_error "onboard-service.sh not found — is gNode installed?"
        return 1
    fi
    local cred_group="${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}"
    [[ "$cred_group" == "OWN" ]] && cred_group="$SVC_NAME"
    local -a args=("$SVC_NAME" --environment "$SVC_ENV" --cred-group "$cred_group")
    [[ -n "$SVC_MANIFEST_DIR" ]] && args+=(--yaml "$SVC_MANIFEST_DIR")
    [[ -n "$SVC_OWNER" ]] && args+=(--owner "$SVC_OWNER")
    [[ -n "$SVC_NOTIFY_EMAIL" ]] && args+=(--notify-email "$SVC_NOTIFY_EMAIL")
    [[ "$SVC_DRY_RUN" == "true" ]] && args+=(--dry-run)
    log_detail "Running: ${onboard} ${args[*]}"
    "$onboard" "${args[@]}" || {
        log_error "Onboarding failed — service is NOT registered"
        return 1
    }
    if [[ "$SVC_DRY_RUN" != "true" && -z "$SVC_NODE" && -d "${SVC_PATH}/.geodineum" ]]; then
        finalize_geodineum_dir "$SVC_PATH" "$SVC_NAME" "$SVC_ENV" || true
    fi
    if [[ -n "$SVC_NODE" && "$SVC_DRY_RUN" != "true" ]]; then
        _print_delegation_bundle
    fi
}

# Delegated provisioning hand-off: the master minted identity + streams;
# the worker installs the credential and runs the filesystem rows.
_print_delegation_bundle() {
    local cred_file="${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password"
    [[ -r "$cred_file" ]] || { log_error "Credential missing after onboarding: ${cred_file}"; return 1; }
    local password reader_group
    password="$(cat "$cred_file")"
    reader_group="${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}"
    case "$reader_group" in
        geodineum-web) reader_group="www-data" ;;   # web reader on the worker
        OWN)           reader_group="$SVC_NAME" ;;
    esac
    echo ""
    echo "  ┌─ Delegated provisioning: '${SVC_NAME}' minted for node '${SVC_NODE}' ─────"
    echo "  │  ACL user : gnode_client_${SVC_NAME}"
    echo "  │  auth     : ${password}"
    echo "  └───────────────────────────────────────────────────────────────────────"
    echo ""
    echo "  On '${SVC_NODE}', install the credential:"
    echo "    sudo geodineum credential add --service ${SVC_NAME} --auth '${password}' --group ${reader_group}"
    echo "    (equivalent: sudo ./scripts/add-service-credential.sh, same flags)"
    echo ""
    echo "  Then complete the worker-side rows for type '${SVC_TYPE}':"
    local row
    for row in ${GEO_TYPE_ROWS[$SVC_TYPE]}; do
        case "$row" in manifest|mail|onboard) continue ;; esac
        echo "    - ${row}"
    done
    echo "  (run 'geodineum service new ${SVC_NAME} --type ${SVC_TYPE} --env ${SVC_ENV}' there,"
    echo "   or apply the rows by hand; the identity above is already live)"
    echo ""
}

# --- locktight perms pass (web types, always last file-touching row) ---------
ensure_web_perms() {
    local root="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Locktight ${root}: dirs 750, files 640, root:www-data (uploads www-data-owned)"
        return 0
    fi
    chown -R root:www-data "${root}/public_html"
    find "${root}/public_html" -type d -exec chmod 750 {} +
    find "${root}/public_html" -type f -exec chmod 640 {} +
    chown -R www-data:www-data "${root}/uploads" 2>/dev/null || true
    chmod 750 "${root}/uploads" 2>/dev/null || true
    log_success "Permissions locked: root:www-data 750/640, no world bits"
}

# =============================================================================
# Matrix engine
# =============================================================================

# Rows run WITHOUT a `||` guard on purpose: guarding the call suppresses
# errexit inside the row (bash semantics), and a half-applied row that keeps
# going is exactly the silent partial this design forbids. Any failure kills
# the run at the failing command, right under the row header.
taxonomy_apply() {
    local rows="${GEO_TYPE_ROWS[$SVC_TYPE]}"
    [[ -n "$SVC_NODE" ]] && rows="$GEO_DELEGATED_ROWS"
    local row n=0 total
    total=$(wc -w <<< "$rows")
    for row in $rows; do
        n=$((n + 1))
        log_step "Row ${n}/${total}: ${row}"
        "ensure_${row}"
    done
    log_success "All ${total} rows applied (every row is idempotent — safe to re-run)"
}

# =============================================================================
# Interview
# =============================================================================

_ask() {
    # _ask <prompt> <default> — echoes the answer; non-interactive uses default
    local prompt="$1" default="${2:-}"
    local answer=""
    if [[ "$SVC_YES" == "true" || ! -t 0 ]]; then
        echo "$default"
        return 0
    fi
    read -r -p "$prompt" answer || true
    echo "${answer:-$default}"
}

_interview_type() {
    [[ -n "$SVC_TYPE" ]] && return 0
    if [[ "$SVC_YES" == "true" || ! -t 0 ]]; then
        log_error "--type is required in non-interactive mode"
        log_error "Types: ${GEO_SERVICE_TYPES[*]}"
        exit 1
    fi
    echo ""
    echo -e "${BOLD}What are you setting up?${NC}"
    echo "  1) Public   — serves visitors over HTTP (website, app)"
    echo "  2) Internal — infrastructure (daemon, headless service)"
    echo "  3) Custom   — mesh identity only (bring your own runtime)"
    local scope
    scope="$(_ask "  Choice [1-3]: " "")"
    case "$scope" in
        1)
            echo ""
            echo -e "${BOLD}Which public type?${NC}"
            echo "  1) ${GEO_TYPE_LABEL[website-wp]}"
            echo "  2) ${GEO_TYPE_LABEL[website-static]}"
            echo "  3) ${GEO_TYPE_LABEL[app-pwa]}"
            case "$(_ask "  Choice [1-3]: " "")" in
                1) SVC_TYPE=website-wp ;;
                2) SVC_TYPE=website-static ;;
                3) SVC_TYPE=app-pwa ;;
                *) log_error "No type chosen"; exit 1 ;;
            esac
            ;;
        2)
            echo ""
            echo -e "${BOLD}Which internal type?${NC}"
            echo "  1) ${GEO_TYPE_LABEL[daemon]}"
            echo "  2) ${GEO_TYPE_LABEL[gcore-service]}"
            echo "  3) ${GEO_TYPE_LABEL[custom]}"
            case "$(_ask "  Choice [1-3]: " "")" in
                1) SVC_TYPE=daemon ;;
                2) SVC_TYPE=gcore-service ;;
                3) SVC_TYPE=custom ;;
                *) log_error "No type chosen"; exit 1 ;;
            esac
            ;;
        3) SVC_TYPE=custom ;;
        *) log_error "No scope chosen"; exit 1 ;;
    esac
}

cmd_service_new() {
    SVC_TYPE=""
    SVC_NAME=""
    SVC_DOMAIN=""
    SVC_ENV=""
    SVC_PATH=""
    SVC_OWNER=""
    SVC_THEME=""
    SVC_NOTIFY_EMAIL=""
    SVC_MAIL_DOMAIN=""
    SVC_MAIL_SET=""
    SVC_FORM=""
    SVC_NODE=""
    SVC_NO_SSL=false
    SVC_DRY_RUN=false
    SVC_YES=false
    SVC_MANIFEST_DIR=""

    local positional=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)         SVC_TYPE="$2"; shift 2 ;;
            --domain)       SVC_DOMAIN="$2"; shift 2 ;;
            --env)          SVC_ENV="$2"; shift 2 ;;
            --path)         SVC_PATH="$2"; shift 2 ;;
            --owner)        SVC_OWNER="$2"; shift 2 ;;
            --theme)        SVC_THEME="$2"; shift 2 ;;
            --notify-email) SVC_NOTIFY_EMAIL="$2"; shift 2 ;;
            --mail-domain)  SVC_MAIL_DOMAIN="$2"; SVC_MAIL_SET=true; shift 2 ;;
            --no-mail)      SVC_MAIL_DOMAIN=""; SVC_MAIL_SET=true; shift ;;
            --form)         SVC_FORM=true; shift ;;
            --no-form)      SVC_FORM=false; shift ;;
            --node)         SVC_NODE="$2"; shift 2 ;;
            --no-ssl)       SVC_NO_SSL=true; shift ;;
            --dry-run)      SVC_DRY_RUN=true; shift ;;
            --yes|-y)       SVC_YES=true; shift ;;
            --matrix)       taxonomy_print_matrix; exit 0 ;;
            --help|-h)      usage_service_new; exit 0 ;;
            -*)             log_error "Unknown option: $1"; usage_service_new; exit 1 ;;
            *)
                if [[ -z "$positional" ]]; then
                    positional="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # A positional with a dot is a domain; otherwise it is the service name.
    if [[ -n "$positional" ]]; then
        if [[ "$positional" == *.* ]]; then
            SVC_DOMAIN="$positional"
        else
            SVC_NAME="$positional"
        fi
    fi

    _interview_type
    if ! taxonomy_is_type "$SVC_TYPE"; then
        log_error "Unknown type: '${SVC_TYPE}'"
        log_error "Types: ${GEO_SERVICE_TYPES[*]}"
        exit 1
    fi

    # Public types need a domain; the site id derives from it.
    if [[ "${GEO_TYPE_VISIBILITY[$SVC_TYPE]}" == "public" ]]; then
        if [[ -z "$SVC_DOMAIN" ]]; then
            SVC_DOMAIN="$(_ask "Domain (e.g. example.com): " "")"
        fi
        [[ -n "$SVC_DOMAIN" ]] || { log_error "A public type needs --domain"; exit 1; }
        validate_domain "$SVC_DOMAIN" || exit 1
        SVC_NAME="$(domain_to_site_id "$SVC_DOMAIN")"
    else
        if [[ -z "$SVC_NAME" ]]; then
            SVC_NAME="$(_ask "Service name (lowercase, a-z0-9_): " "")"
        fi
        [[ -n "$SVC_NAME" ]] || { log_error "A service name is required"; exit 1; }
        validate_site_id "$SVC_NAME" || exit 1
    fi

    # DTAP environment: explicit or abort — nothing is assumed.
    if [[ -z "$SVC_ENV" ]]; then
        SVC_ENV="$(_ask "DTAP environment (testing|staging|acceptance|production): " "")"
    fi
    if [[ -z "$SVC_ENV" ]]; then
        log_error "No environment given — pass --env <tier>. Nothing is assumed:"
        log_error "a silent default has DTAP-gated production services before."
        exit 1
    fi
    validate_environment "$SVC_ENV" || exit 1

    # Mail: public types default to their own domain; internal types opt in.
    if [[ -z "$SVC_MAIL_SET" ]]; then
        if [[ "${GEO_TYPE_VISIBILITY[$SVC_TYPE]}" == "public" && -z "$SVC_NODE" ]]; then
            local mail_answer
            mail_answer="$(_ask "Provision DKIM sender identity for ${SVC_DOMAIN}? [Y/n]: " "y")"
            [[ "$mail_answer" =~ ^[Yy] ]] && SVC_MAIL_DOMAIN="$SVC_DOMAIN"
        fi
    fi

    # Form endpoint: static defaults on, app-pwa defaults off.
    if [[ -z "$SVC_FORM" ]]; then
        case "$SVC_TYPE" in
            website-static)
                local form_answer
                form_answer="$(_ask "Include a COMMS form endpoint (contact/quote form)? [Y/n]: " "y")"
                [[ "$form_answer" =~ ^[Yy] ]] && SVC_FORM=true || SVC_FORM=false
                ;;
            *) SVC_FORM=false ;;
        esac
    fi

    # Resolve paths + derived values.
    SVC_PROFILE="${GEO_TYPE_PROFILE[$SVC_TYPE]}"
    SVC_GROUP="geodineum"
    case "$SVC_TYPE" in
        daemon|gcore-service) SVC_GROUP="$SVC_NAME" ;;
    esac
    if [[ -z "$SVC_PATH" ]]; then
        if [[ "${GEO_TYPE_VISIBILITY[$SVC_TYPE]}" == "public" ]]; then
            SVC_PATH="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}"
        else
            SVC_PATH="${GEODINEUM_ROOT}/services/${SVC_NAME}"
        fi
    fi

    # =================================================================
    # Banner + plan
    # =================================================================

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${BOLD}Geodineum Service Onboarding${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_kv "Type" "${SVC_TYPE} (${GEO_TYPE_VISIBILITY[$SVC_TYPE]})"
    print_kv "Service" "$SVC_NAME"
    [[ -n "$SVC_DOMAIN" ]] && print_kv "Domain" "$SVC_DOMAIN"
    print_kv "Environment" "$SVC_ENV"
    print_kv "Profile" "$SVC_PROFILE"
    print_kv "Cred group" "$([ "${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}" == OWN ] && echo "$SVC_NAME" || echo "${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}")"
    print_kv "Mail" "${SVC_MAIL_DOMAIN:-skip}"
    [[ "$SVC_FORM" == "true" ]] && print_kv "Form endpoint" "form/submit.php → COMMS"
    [[ -n "$SVC_NODE" ]] && print_kv "Delegated to" "$SVC_NODE (master mints, worker installs)"
    [[ -n "$SVC_OWNER" ]] && print_kv "Owner/Tenant" "$SVC_OWNER"
    local rows_plan="${GEO_TYPE_ROWS[$SVC_TYPE]}"
    [[ -n "$SVC_NODE" ]] && rows_plan="$GEO_DELEGATED_ROWS"
    print_kv "Rows" "$rows_plan"
    echo ""

    if [[ "$SVC_DRY_RUN" != "true" ]]; then
        require_sudo "Service onboarding"
        if [[ "$SVC_YES" != "true" && -t 0 ]]; then
            local go
            go="$(_ask "Proceed? [Y/n]: " "y")"
            [[ "$go" =~ ^[Yy] ]] || { log_info "Aborted — nothing was changed"; exit 0; }
        fi
    fi

    # No `||` guard: it would suppress errexit inside the engine and let a
    # failed row scroll past (see taxonomy_apply). A failure aborts here.
    taxonomy_apply

    # =================================================================
    # Summary
    # =================================================================

    print_summary_header "Service Onboarded"
    print_kv "Type" "$SVC_TYPE"
    print_kv "Service" "$SVC_NAME"
    [[ -n "$SVC_DOMAIN" ]] && print_kv "URL" "https://${SVC_DOMAIN}/"
    print_kv "Environment" "$SVC_ENV"
    if [[ -z "$SVC_NODE" ]]; then
        print_kv "Credential" "${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password"
    fi
    echo ""
    echo -e "  ${BOLD}Verify:${NC}"
    echo "    geodineum info ${SVC_NAME}"
    echo "    sudo geodineum grants show ${SVC_NAME}"
    case "$SVC_TYPE" in
        daemon|gcore-service)
            echo "    # deploy your code, then:"
            echo "    sudo systemctl start geodineum-${SVC_NAME}"
            ;;
    esac
    if [[ "$SVC_ENV" != "production" ]]; then
        echo "    # promote when ready: geodineum env set ${SVC_NAME} production"
    fi
    echo ""
}

# =============================================================================
# Usage
# =============================================================================

usage_service_new() {
    cat << EOF
Usage: geodineum service new [<domain-or-name>] [options]

Taxonomy-driven service onboarding. The interview asks what the service IS;
a per-type requirement matrix decides what runs; every type ends on the same
paved road (provision → register → heartbeat → mail-verify → verify).

Types (--type):
  public:   website-wp | website-static | app-pwa
  internal: daemon | gcore-service | custom

Options:
  --type <type>            Service type (interactive interview if omitted)
  --domain <domain>        Domain (public types; a dotted positional works too)
  --env <tier>             DTAP environment — REQUIRED, never assumed
                           (testing|staging|acceptance|production)
  --path <dir>             Service root (default: /var/www/<domain> or
                           /opt/geodineum/services/<name>)
  --owner <tenant>         Tenant/owner for cross-site discovery
  --theme <name>           Child theme (website-wp only)
  --notify-email <addr>    Wire a COMMS email channel + dispatch-verify it
  --mail-domain <domain>   Provision DKIM sender identity for this domain
  --no-mail                Skip the mail row
  --form / --no-form       Include the COMMS form endpoint (static default: on)
  --node <name>            Delegated provisioning: mint identity + credential
                           on this master for a worker node to install
  --no-ssl                 Skip certbot
  --matrix                 Print the requirement matrix and exit
  --dry-run                Preview all rows without changing anything
  --yes, -y                Non-interactive (requires --type and --env)
  --help, -h               Show this help

Examples:
  sudo geodineum service new                                  # interview
  sudo geodineum service new example.com --type website-static --env production
  sudo geodineum service new worker1 --type daemon --env production --yes
  sudo geodineum service new ml_api --type daemon --env production --node gpu-node-1
  geodineum service new --matrix
EOF
}

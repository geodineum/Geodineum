#!/bin/bash
# Strict mode; sourced libs no longer
# silent-fail when called from a context that does not pre-set -euo.
set -euo pipefail

#
# Geodineum CLI — Service Taxonomy (the NEW branch of geodineum register)
# ==========================================================
# The interview asks WHAT IT IS; the requirement matrix decides WHAT RUNS;
# the paved road (provision → register → heartbeat → mail-verify → verify)
# is the same for every type. The matrix is DATA — interview, engine, and
# docs all read the tables below; there is no second copy.
#
# Types:
#   PUBLIC    website-wp | website-static | app-pwa | webapp-gcore
#   INTERNAL  daemon | gcore-service | custom
#
# Requires: common.sh sourced first. site.sh is lazy-loaded for the
# WordPress delegate row.
#

# =============================================================================
# Taxonomy — the requirement matrix as data
# =============================================================================

GEO_SERVICE_TYPES=(website-wp website-static app-pwa webapp-gcore app daemon scheduled gcore-service custom)

declare -A GEO_TYPE_LABEL=(
    [website-wp]="WordPress website (full CMS + gCore runtime)"
    [website-static]="Static website (plain files, optional COMMS form endpoint)"
    [app-pwa]="App / PWA (static shell + web-app manifest + service worker)"
    [webapp-gcore]="gCore web app (PHP on the shared framework, public, no WordPress)"
    [app]="App (an HTTP service on its own port behind a proxy: own user, unit, health probe)"
    [daemon]="Daemon (systemd unit, own system user)"
    [scheduled]="Scheduled job (runs on a timer under its own user, then exits)"
    [gcore-service]="gCore service (PHP headless, no WordPress)"
    [custom]="Custom (mesh identity only — bring your own runtime)"
)

declare -A GEO_TYPE_VISIBILITY=(
    [website-wp]=public
    [website-static]=public
    [app-pwa]=public
    [webapp-gcore]=public
    [app]=internal
    [daemon]=internal
    [scheduled]=internal
    [gcore-service]=internal
    [custom]=internal
)

# Capability profile: the manifest profile: word the one topology declares by name.
declare -A GEO_TYPE_PROFILE=(
    [website-wp]=web
    [website-static]=web
    [app-pwa]=web
    [webapp-gcore]=web
    [app]=headless
    [daemon]=service
    [scheduled]=service
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
    [webapp-gcore]=geodineum-web
    [app]=OWN
    [daemon]=OWN
    [scheduled]=OWN
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
    [webapp-gcore]="docroot web_code_group skeleton_gcore gcore_bootstrap form_endpoint vhost manifest mail onboard web_perms"
    [app]="own_user service_dirs manifest systemd_unit mail onboard heartbeat"
    [daemon]="own_user service_dirs manifest systemd_unit mail onboard heartbeat"
    [scheduled]="own_user service_dirs manifest systemd_timer mail onboard heartbeat"
    [gcore-service]="code_group service_dirs gcore_bootstrap manifest systemd_unit mail onboard heartbeat"
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
# All rows read the SVC_* globals resolved by register_new / register_integrate and honour
# SVC_DRY_RUN. A failed row aborts the run (fail-loud, no silent partials).

# --- website-wp: delegate wholesale to the existing WordPress paved path ----
ensure_wp_stack() {
    source "${GEODINEUM_CLI_ROOT}/lib/site.sh"
    local -a args=("$SVC_DOMAIN" --env "$SVC_ENV")
    [[ -n "$SVC_THEME" ]] && args+=(--theme "$SVC_THEME")
    [[ -n "$SVC_OWNER" ]] && args+=(--owner "$SVC_OWNER")
    [[ "$SVC_NO_SSL" == "true" ]] && args+=(--no-ssl)
    [[ "$SVC_DRY_RUN" == "true" ]] && args+=(--dry-run)
    [[ "$SVC_YES" == "true" ]] && args+=(--yes)
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
    ledger_mkdir "$SVC_NAME" data "${root}/public_html" "${root}/uploads"
    chown root:www-data "$root" "${root}/public_html"
    chown www-data:www-data "${root}/uploads"
    chmod 750 "$root" "${root}/public_html" "${root}/uploads"
    # DTAP tier as a root-owned file: staging/production flips are an operator
    # action, never a code edit. The form endpoint fails safe without it.
    ledger_file "$SVC_NAME" data "${root}/.env-tier"
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
    else
        ledger_file "$SVC_NAME" data "${docroot}/index.html"
        DOMAIN="$SVC_DOMAIN" SITE_ID="$SVC_NAME" \
            render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/index.html.tpl" \
            "${docroot}/index.html"
        ledger_mkdir "$SVC_NAME" data "${docroot}/assets"
        log_success "Static skeleton rendered (index.html + assets/)"
    fi
    ensure_visit_beacon
}

# Cookieless analytics endpoint — every public type gets one; the counters
# land in the site's own {site}:* keyspace and surface in `geodineum status --visitors`.
ensure_visit_beacon() {
    local docroot="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}/public_html"
    if [[ -f "${docroot}/g/hit.php" ]]; then
        log_warning "g/hit.php already exists — skipping"
        return 0
    fi
    ledger_mkdir "$SVC_NAME" data "${docroot}/g"
    ledger_file "$SVC_NAME" data "${docroot}/g/hit.php"
    SITE_ID="$SVC_NAME" DOMAIN="$SVC_DOMAIN" \
    CREDENTIAL_FILE="${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password" \
        render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/hit.php.tpl" \
        "${docroot}/g/hit.php"
    log_success "Visitor beacon: g/hit.php → GNODE_ANALYTICS_HIT ({${SVC_NAME}}:visits/pagecounts/...)"
}

# --- web code group: www-data must read the shared gCore source ------------
# A public gCore app runs as www-data and reads /opt/geodineum/gCore through
# geodineum-code. Assert the membership instead of assuming it: on a node
# where the group drifted, onboarding would succeed and the app would fail at
# runtime looking like a ValKey problem.
ensure_web_code_group() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Assert www-data ∈ geodineum-code (reads gCore source)"
        return 0
    fi
    if ! getent group geodineum-code >/dev/null 2>&1; then
        log_error "geodineum-code group missing — a gCore web app cannot read the framework source"
        log_error "  The installer creates it (perm-model); re-run install or add the group first"
        return 1
    fi
    if id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx geodineum-code; then
        log_success "www-data ∈ geodineum-code (gCore source readable)"
        return 0
    fi
    usermod -aG geodineum-code www-data
    log_success "www-data added to geodineum-code"
    # Supplementary groups are read at process start: running FPM workers
    # keep the old set until respawned.
    local unit
    for unit in php8.3-fpm php8.4-fpm php-fpm; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl reload "$unit" 2>/dev/null \
                && log_success "${unit} reloaded (workers pick up the new group)" \
                || log_warning "${unit} reload failed — reload it by hand before serving this app"
            break
        fi
    done
}

# --- gCore web skeleton: front controller in docroot, app code outside -----
# public_html/index.php is the only PHP the web server can reach; it requires
# ../src/bootstrap.php (rendered by the gcore_bootstrap row), which boots the
# framework through gcore-standalone.php. Application code lives in src/.
ensure_skeleton_gcore() {
    local root="${GEODINEUM_WEB_ROOT}/${SVC_DOMAIN}"
    local docroot="${root}/public_html"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Create ${root}/src (root:www-data 750) + render public_html/index.php front controller"
        return 0
    fi
    ledger_mkdir "$SVC_NAME" data "${root}/src"
    chown root:www-data "${root}/src"
    chmod 750 "${root}/src"
    if [[ -f "${docroot}/index.php" ]]; then
        log_warning "index.php already exists — skipping front controller"
    else
        ledger_file "$SVC_NAME" data "${docroot}/index.php"
        DOMAIN="$SVC_DOMAIN" SITE_ID="$SVC_NAME" SERVICE_ENV="$SVC_ENV" \
            render_template "${GEODINEUM_CLI_ROOT}/templates/webapp-gcore/index.php.tpl" \
            "${docroot}/index.php"
        log_success "Front controller: public_html/index.php → ../src/bootstrap.php"
    fi
    ensure_visit_beacon
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
        ledger_file "$SVC_NAME" data "${docroot}/index.html"
        DOMAIN="$SVC_DOMAIN" SITE_ID="$SVC_NAME" \
            render_template "${GEODINEUM_CLI_ROOT}/templates/static-site/index.html.tpl" \
            "${docroot}/index.html"
    fi
    ledger_mkdir "$SVC_NAME" data "${docroot}/assets"
    if [[ ! -f "${docroot}/manifest.webmanifest" ]]; then
        ledger_file "$SVC_NAME" data "${docroot}/manifest.webmanifest"
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
        ledger_file "$SVC_NAME" data "${docroot}/sw.js"
        cat > "${docroot}/sw.js" << 'SWEOF'
// Minimal offline-first service worker. Extend the cache list as the app grows.
// The /g/ analytics beacon is never cached — a hit that lands in the cache
// is a hit that never lands in the counters.
const CACHE = 'app-v1';
const ASSETS = ['/', '/index.html', '/manifest.webmanifest'];
self.addEventListener('install', (e) => {
    e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
});
self.addEventListener('fetch', (e) => {
    if (new URL(e.request.url).pathname.startsWith('/g/')) { return; }
    e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
});
SWEOF
    fi
    ensure_visit_beacon
    log_success "PWA skeleton rendered (manifest.webmanifest + sw.js)"
}

# --- form endpoint: generalized COMMS producer --------------------------------
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
    ledger_mkdir "$SVC_NAME" data "${docroot}/form"
    ledger_file "$SVC_NAME" data "${docroot}/form/submit.php"
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
        ledger_add "$SVC_NAME" config vhost "$SVC_DOMAIN"
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
        local had_cert=false
        [[ -d "/etc/letsencrypt/live/${SVC_DOMAIN}" ]] && had_cert=true
        if "${cb[@]}"; then
            [[ "$had_cert" == true ]] || ledger_add "$SVC_NAME" config cert "$SVC_DOMAIN"
        else
            log_warning "certbot did not complete (DNS not pointed yet?)"
            log_info "Re-run later: sudo certbot --apache -d ${SVC_DOMAIN}"
        fi
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
    if ! getent group "$SVC_NAME" >/dev/null 2>&1; then
        groupadd --system "$SVC_NAME"
        ledger_add "$SVC_NAME" config group "$SVC_NAME"
    fi
    if ! id "$SVC_NAME" >/dev/null 2>&1; then
        useradd --system --gid "$SVC_NAME" --home-dir "$SVC_PATH" \
            --no-create-home --shell /usr/sbin/nologin "$SVC_NAME"
        ledger_add "$SVC_NAME" config user "$SVC_NAME"
    fi
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
    ledger_mkdir "$SVC_NAME" data "${SVC_PATH}/src"
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
    # Self-sufficient: the web types have no service_dirs row before this one.
    ledger_mkdir "$SVC_NAME" data "$(dirname "$out")"
    ledger_file "$SVC_NAME" data "$out"
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
    ledger_mkdir "$SVC_NAME" config "$dir"
    ledger_add "$SVC_NAME" config geodineum-dir "$dir"
    # finalize_geodineum_dir symlinks the credential into credentials/ after
    # onboarding — the subdir must exist for every local manifest home.
    [[ -z "$SVC_NODE" ]] && mkdir -p "${dir}/credentials"
    if [[ -f "$manifest" ]]; then
        log_warning "Manifest already exists — left untouched: ${manifest}"
        return 0
    fi
    local produces_extra=""
    [[ "$SVC_FORM" == "true" ]] && produces_extra="
  - \"{${SVC_NAME}}:forms:*\"         # submission archive + rate-limit counters"
    ledger_file "$SVC_NAME" config "$manifest"
    cat > "$manifest" << MFEOF
# Geodineum onboarding manifest — ONE schema (profile + environment +
# consumes/produces drive registration and the composed ValKey ACL).
# Contract: CONTRACTS/SERVICE_ONBOARDING.md

profile: ${SVC_PROFILE}
environment: ${SVC_ENV}

$(CAP_LANGUAGE="${SVC_LANG:-php}" gnode_block_yaml "${SVC_PROFILE}" "${SVC_NAME}" "${SVC_CONSTELLATION}")

services:
  - id: "${SVC_NAME}"
    metadata:
      description: "${GEO_TYPE_LABEL[$SVC_TYPE]}"
      type: "${SVC_TYPE}"
      tier: "SERVICE"
      created_by: "geodineum register"

# Own-namespace only (braces literal = hash-tag). Anything foreign is
# refused at onboarding — request cross-service access via the grant loop.
consumes: []
produces:
  - "{${SVC_NAME}}:gnode:comms:*"   # notifications → COMMS dispatch${produces_extra}
MFEOF
    chmod 640 "$manifest"
    log_success "Manifest: ${manifest} (profile=${SVC_PROFILE}, env=${SVC_ENV})"
}

# --- runnable skeleton: src/main.<lang> + run, per kind --------------------
# kind: daemon (long-running, stops on SIGTERM) | app (a tiny HTTP server on
# SVC_PORT answering /health, so the heartbeat probe has something to probe) |
# scheduled (does one run and exits). The operator replaces src/main.* with the
# real code; run stays.
_skeleton_main() {
    local kind="$1" lang="$2" out="$3" port="${SVC_PORT:-8080}"
    case "${lang}:${kind}" in
        python:app) cat > "$out" << PYEOF
"""${SVC_NAME}: replace with the app. /health is what the heartbeat probes."""
import http.server, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/health"
        self.send_response(200 if ok else 404); self.end_headers()
        self.wfile.write(b"ok\n" if ok else b"")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ.get("PORT", "${port}"))), H).serve_forever()
PYEOF
            ;;
        python:scheduled) cat > "$out" << PYEOF
"""${SVC_NAME}: one run of the job; the timer starts it again."""
import os
print(f"{os.environ.get('GNODE_SITE_ID')}: run complete", flush=True)
PYEOF
            ;;
        python:*) cat > "$out" << PYEOF
"""${SVC_NAME}: replace with the service. Stops cleanly on SIGTERM."""
import os, signal, time
running = True
def stop(*_):
    global running; running = False
signal.signal(signal.SIGTERM, stop)
print(f"{os.environ.get('GNODE_SITE_ID')} started", flush=True)
while running:
    time.sleep(1)
PYEOF
            ;;
        node:app) cat > "$out" << JSEOF
// ${SVC_NAME}: replace with the app. /health is what the heartbeat probes.
require("http").createServer((q, r) => { r.writeHead(q.url === "/health" ? 200 : 404); r.end(q.url === "/health" ? "ok\n" : ""); })
  .listen(Number(process.env.PORT || ${port}), "127.0.0.1");
JSEOF
            ;;
        node:scheduled) cat > "$out" << JSEOF
// ${SVC_NAME}: one run of the job; the timer starts it again.
console.log(\`\${process.env.GNODE_SITE_ID}: run complete\`);
JSEOF
            ;;
        node:*) cat > "$out" << JSEOF
// ${SVC_NAME}: replace with the service. Stops cleanly on SIGTERM.
console.log(\`\${process.env.GNODE_SITE_ID} started\`);
const t = setInterval(() => {}, 1000);
process.on("SIGTERM", () => { clearInterval(t); process.exit(0); });
JSEOF
            ;;
        php:scheduled) cat > "$out" << PHPEOF
<?php
// ${SVC_NAME}: one run of the job; the timer starts it again.
echo getenv('GNODE_SITE_ID') . ": run complete\n";
PHPEOF
            ;;
        php:*) cat > "$out" << PHPEOF
<?php
// ${SVC_NAME}: replace with the service.
echo getenv('GNODE_SITE_ID') . " started\n";
while (true) { sleep(1); }
PHPEOF
            ;;
        *:scheduled) cat > "$out" << SHEOF
#!/bin/bash
# ${SVC_NAME}: one run of the job; the timer starts it again.
echo "\${GNODE_SITE_ID}: run complete"
SHEOF
            ;;
        *) cat > "$out" << SHEOF
#!/bin/bash
# ${SVC_NAME}: replace with the service. Stops cleanly on SIGTERM.
trap 'exit 0' TERM
echo "\${GNODE_SITE_ID} started"
while :; do sleep 1; done
SHEOF
            ;;
    esac
}

# Env file + src/main.<lang> + run: shared by the unit and the timer rows.
_svc_env_and_run() {
    local kind="$1"
    local envfile="/etc/geodineum/services/${SVC_NAME}.env"
    mkdir -p /etc/geodineum/services
    if [[ ! -f "$envfile" ]]; then
        ledger_file "$SVC_NAME" config "$envfile"
        cat > "$envfile" << ENVEOF
GNODE_SITE_ID=${SVC_NAME}
GNODE_ENVIRONMENT=${SVC_ENV}
GNODE_TOPOLOGY_NAMESPACE=${SVC_CONSTELLATION}
VALKEY_HOST=${VALKEY_HOST:-127.0.0.1}
VALKEY_PORT=${VALKEY_PORT:-47445}
VALKEY_USER=gnode_client_${SVC_NAME}
VALKEY_PASSWORD_FILE=${GEODINEUM_CREDENTIALS_DIR}/valkey_client_${SVC_NAME}.password
${SVC_PORT:+PORT=${SVC_PORT}}
ENVEOF
        chown "root:${SVC_GROUP}" "$envfile"
        chmod 640 "$envfile"
    fi
    local lang="${SVC_LANG:-bash}" ext interp
    case "$lang" in
        python) ext=py interp=python3 ;;
        node)   ext=js interp=node ;;
        php)    ext=php interp=php ;;
        *)      lang=bash ext=sh interp=bash ;;
    esac
    local main="${SVC_PATH}/src/main.${ext}"
    if [[ ! -f "$main" ]]; then
        ledger_mkdir "$SVC_NAME" data "${SVC_PATH}/src"
        ledger_file "$SVC_NAME" data "$main"
        _skeleton_main "$kind" "$lang" "$main"
        chown "root:${SVC_GROUP}" "$main"
        chmod 640 "$main"
    fi
    if [[ ! -f "${SVC_PATH}/run" ]]; then
        ledger_file "$SVC_NAME" data "${SVC_PATH}/run"
        printf '#!/bin/bash\n# Entrypoint: replace src/main.%s with the real code; this stays.\nexec %s "$(dirname "$0")/src/main.%s"\n' "$ext" "$interp" "$ext" > "${SVC_PATH}/run"
        chown "root:${SVC_GROUP}" "${SVC_PATH}/run"
        chmod 750 "${SVC_PATH}/run"
    fi
}

# --- systemd unit: one generic template + per-service env file --------------
ensure_systemd_unit() {
    local unit="/etc/systemd/system/geodineum-${SVC_NAME}.service"
    local kind=daemon; [[ "$SVC_TYPE" == app ]] && kind=app
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Install ${unit} (User=${SVC_NAME}, ExecStart=${SVC_PATH}/run, ${SVC_LANG:-bash} skeleton) + /etc/geodineum/services/${SVC_NAME}.env"
        return 0
    fi
    _svc_env_and_run "$kind"
    if [[ -f "$unit" ]]; then
        log_warning "Unit already exists — left untouched: ${unit}"
    else
        cat > "$unit" << UNITEOF
[Unit]
Description=Geodineum service: ${SVC_NAME}
After=network.target valkey-gnode.service

[Service]
Type=simple
User=${SVC_NAME}
Group=${SVC_GROUP}
EnvironmentFile=/etc/geodineum/services/${SVC_NAME}.env
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
        ledger_add "$SVC_NAME" config unit "geodineum-${SVC_NAME}.service"
        systemctl daemon-reload
        systemctl enable "geodineum-${SVC_NAME}.service" >/dev/null 2>&1 || true
        log_success "Unit installed + enabled (not started — deploy code first): ${unit}"
    fi
}

# --- systemd timer: a oneshot unit and its schedule (scheduled jobs) --------
ensure_systemd_timer() {
    local unit="/etc/systemd/system/geodineum-${SVC_NAME}.service"
    local timer="/etc/systemd/system/geodineum-${SVC_NAME}.timer"
    local when="${SVC_SCHEDULE:-hourly}"
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Install ${unit} (oneshot, User=${SVC_NAME}) + ${timer} (OnCalendar=${when})"
        return 0
    fi
    systemd-analyze calendar "$when" >/dev/null 2>&1 || { log_error "--schedule '${when}' is not a systemd calendar expression (e.g. hourly, daily, *:0/15)"; return 1; }
    _svc_env_and_run scheduled
    if [[ ! -f "$unit" ]]; then
        cat > "$unit" << UNITEOF
[Unit]
Description=Geodineum scheduled job: ${SVC_NAME}

[Service]
Type=oneshot
User=${SVC_NAME}
Group=${SVC_GROUP}
EnvironmentFile=/etc/geodineum/services/${SVC_NAME}.env
WorkingDirectory=${SVC_PATH}
ExecStart=${SVC_PATH}/run
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SVC_PATH}
PrivateTmp=true
UNITEOF
        chmod 644 "$unit"
        ledger_add "$SVC_NAME" config unit "geodineum-${SVC_NAME}.service"
    fi
    if [[ ! -f "$timer" ]]; then
        cat > "$timer" << TIMEREOF
[Unit]
Description=Schedule for geodineum-${SVC_NAME}

[Timer]
OnCalendar=${when}
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF
        chmod 644 "$timer"
        ledger_add "$SVC_NAME" config unit "geodineum-${SVC_NAME}.timer"
        systemctl daemon-reload
        systemctl enable --now "geodineum-${SVC_NAME}.timer" >/dev/null 2>&1 || true
        log_success "Timer installed + enabled (${when}): ${timer}"
    fi
}

# --- heartbeat: the one probe-gated client (scripts/heartbeat) --------------
# Runs after onboard: the heartbeat runs with the credential's group, which only
# exists once onboarding has minted the credential.
ensure_heartbeat() {
    local probe="${SVC_PROBE:-}"
    if [[ -z "$probe" ]]; then
        case "$SVC_TYPE" in
            scheduled) probe="unit:geodineum-${SVC_NAME}.timer" ;;
            app) probe="${SVC_PORT:+http:http://127.0.0.1:${SVC_PORT}/health}"; probe="${probe:-unit:geodineum-${SVC_NAME}.service}" ;;
            *) probe="unit:${SVC_UNIT:-geodineum-${SVC_NAME}.service}" ;;
        esac
    fi
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Heartbeat {${SVC_CONSTELLATION}}:gnode:heartbeat:${SVC_ENV}:${SVC_NAME}:<node> while ${probe} passes"
        return 0
    fi
    local script="${GEODINEUM_CLI_ROOT}/scripts/heartbeat/install-heartbeat.sh"
    [[ -x "$script" ]] || { log_error "Heartbeat installer not found: ${script}"; return 1; }
    local spec="${GEODINEUM_CONFIG_ROOT}/heartbeat/${SVC_NAME}.env"
    local dropin="/etc/systemd/system/geodineum-heartbeat@${SVC_NAME}.service.d"
    ledger_file "$SVC_NAME" config "$spec"
    [[ -d "$dropin" ]] || ledger_add "$SVC_NAME" config dir "$dropin"
    "$script" "$SVC_NAME" --probe "$probe" --constellation "$SVC_CONSTELLATION" --environment "$SVC_ENV" --apply >/dev/null \
        || { log_error "Heartbeat install failed: ${script} ${SVC_NAME} --probe ${probe}"; return 1; }
    ledger_add "$SVC_NAME" config unit "geodineum-heartbeat@${SVC_NAME}.timer"
    log_success "Heartbeat: {${SVC_CONSTELLATION}}:gnode:heartbeat:${SVC_ENV}:${SVC_NAME}:<node> while ${probe} passes"
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
    ledger_add "$SVC_NAME" keep mail-domain "$SVC_MAIL_DOMAIN"
    log_info "Publish the printed DNS records, then verify: geodineum mail records ${SVC_MAIL_DOMAIN}"
}

# --- the paved road: onboard (identity + streams + register + mail probe) ---
ensure_onboard() {
    if [[ "$SVC_DRY_RUN" == "true" ]]; then
        log_dry "Onboard: identity gnode_client_${SVC_NAME} (own-namespace grants from the manifest), streams, topology entity ($(profile_to_shape "${SVC_PROFILE:-web}") in {${SVC_CONSTELLATION:-?}}) and its intent"
        return 0
    fi
    local onboard="${GNODE_SCRIPTS}/onboard-service.sh"
    [[ -x "$onboard" ]] || onboard="${GEODINEUM_ROOT}/gNode/scripts/onboard-service.sh"
    if [[ ! -x "$onboard" ]]; then
        log_error "onboard-service.sh not found — is gNode installed?"
        return 1
    fi
    local cred_group="${SVC_CRED_GROUP:-${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}}"
    [[ "$cred_group" == "OWN" ]] && cred_group="$SVC_NAME"
    local -a args=("$SVC_NAME" --environment "$SVC_ENV" --cred-group "$cred_group")
    [[ -n "$SVC_MANIFEST_DIR" ]] && args+=(--yaml "$SVC_MANIFEST_DIR")
    [[ -n "$SVC_OWNER" ]] && args+=(--owner "$SVC_OWNER")
    [[ -n "$SVC_NOTIFY_EMAIL" ]] && args+=(--notify-email "$SVC_NOTIFY_EMAIL")
    [[ "$SVC_DRY_RUN" == "true" ]] && args+=(--dry-run)
    [[ "${SVC_REGRANT:-false}" == "true" ]] && args+=(--regrant)
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
    local reader_group="${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}"
    case "$reader_group" in
        geodineum-web) reader_group="www-data" ;;   # web reader on the worker
        OWN)           reader_group="$SVC_NAME" ;;
    esac
    local owner="${SUDO_USER:-root}" home out
    home="$(getent passwd "$owner" | cut -d: -f6)"
    out="${home:-/root}/${SVC_NAME}.credential"
    ( umask 077; cat "$cred_file" > "$out" )
    chown "$owner" "$out" 2>/dev/null || true
    echo ""
    echo "  '${SVC_NAME}' is registered here for node '${SVC_NODE}'; its credential is in ${out} (0600)."
    echo "  on $(hostname -s):  scp ${out} <user>@${SVC_NODE}:"
    echo "  on ${SVC_NODE}:  sudo geodineum credential add --service ${SVC_NAME} --auth-file ~/${SVC_NAME}.credential --group ${reader_group}"
    echo "  on ${SVC_NODE}:  sudo geodineum register ${SVC_NAME} --new ${SVC_TYPE} --env ${SVC_ENV} --worker   # its files and units"
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
    # App code outside the docroot (webapp-gcore): same lock, never writable
    # by the runtime user.
    if [[ -d "${root}/src" ]]; then
        chown -R root:www-data "${root}/src"
        find "${root}/src" -type d -exec chmod 750 {} +
        find "${root}/src" -type f -exec chmod 640 {} +
    fi
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
    # On the worker of a delegated service: the host rows only (the master onboarded it).
    if [[ "$SVC_WORKER" == "true" ]]; then
        local r kept=""
        for r in $rows; do [[ " $GEO_DELEGATED_ROWS " == *" $r "* ]] || kept+="$r "; done
        rows="${kept% }"
    fi
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
    echo "  2) Internal — an app behind a proxy, a daemon, a scheduled job, a headless service"
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
            echo "  4) ${GEO_TYPE_LABEL[webapp-gcore]}"
            case "$(_ask "  Choice [1-4]: " "")" in
                1) SVC_TYPE=website-wp ;;
                2) SVC_TYPE=website-static ;;
                3) SVC_TYPE=app-pwa ;;
                4) SVC_TYPE=webapp-gcore ;;
                *) log_error "No type chosen"; exit 1 ;;
            esac
            ;;
        2)
            echo ""
            echo -e "${BOLD}Which internal type?${NC}"
            echo "  1) ${GEO_TYPE_LABEL[app]}"
            echo "  2) ${GEO_TYPE_LABEL[daemon]}"
            echo "  3) ${GEO_TYPE_LABEL[scheduled]}"
            echo "  4) ${GEO_TYPE_LABEL[gcore-service]}"
            echo "  5) ${GEO_TYPE_LABEL[custom]}"
            case "$(_ask "  Choice [1-5]: " "")" in
                1) SVC_TYPE=app ;;
                2) SVC_TYPE=daemon ;;
                3) SVC_TYPE=scheduled ;;
                4) SVC_TYPE=gcore-service ;;
                5) SVC_TYPE=custom ;;
                *) log_error "No type chosen"; exit 1 ;;
            esac
            ;;
        3) SVC_TYPE=custom ;;
        *) log_error "No scope chosen"; exit 1 ;;
    esac
}

register_new() {
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
    SVC_LANG="" SVC_SCHEDULE="" SVC_PORT="" SVC_PROBE="" SVC_UNIT="" SVC_WORKER=false SVC_CRED_GROUP="" SVC_REGRANT=false

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
            --worker)       SVC_WORKER=true; shift ;;
            --lang)         SVC_LANG="$2"; shift 2 ;;
            --schedule)     SVC_SCHEDULE="$2"; shift 2 ;;
            --port)         SVC_PORT="$2"; shift 2 ;;
            --probe)        SVC_PROBE="$2"; shift 2 ;;
            --no-ssl)       SVC_NO_SSL=true; shift ;;
            --dry-run)      SVC_DRY_RUN=true; shift ;;
            --yes|-y)       SVC_YES=true; shift ;;
            --matrix)       taxonomy_print_matrix; exit 0 ;;
            --help|-h)      usage_register; exit 0 ;;
            -*)             log_error "Unknown option: $1"; usage_register; exit 1 ;;
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

    # A runnable skeleton needs a language; an app also needs its port.
    case "$SVC_TYPE" in
        app|daemon|scheduled)
            [[ -n "$SVC_LANG" ]] || SVC_LANG="$(_ask "Language [bash|python|node|php] [$([[ $SVC_TYPE == app ]] && echo python || echo bash)]: " "$([[ $SVC_TYPE == app ]] && echo python || echo bash)")"
            [[ "$SVC_LANG" =~ ^(bash|python|node|php)$ ]] || { log_error "--lang must be bash, python, node or php"; exit 1; } ;;
        gcore-service) SVC_LANG=php ;;
    esac
    if [[ "$SVC_TYPE" == app && -z "$SVC_PORT" ]]; then
        SVC_PORT="$(_ask "Port it listens on, on 127.0.0.1 [8080]: " "8080")"
    fi
    [[ -z "$SVC_PORT" || "$SVC_PORT" =~ ^[0-9]{2,5}$ ]] || { log_error "--port must be a number"; exit 1; }
    if [[ "$SVC_TYPE" == scheduled && -z "$SVC_SCHEDULE" ]]; then
        SVC_SCHEDULE="$(_ask "Schedule (systemd calendar: hourly, daily, *:0/15) [hourly]: " "hourly")"
    fi
    # shellcheck source=/dev/null
    source "${GNODE_SCRIPTS}/cli/constellation.sh" 2>/dev/null || true
    SVC_CONSTELLATION="$(gnode_cli_constellation 2>/dev/null || echo "${GNODE_TOPOLOGY_NAMESPACE:-geodineum}")"

    # Resolve paths + derived values.
    SVC_PROFILE="${GEO_TYPE_PROFILE[$SVC_TYPE]}"
    SVC_GROUP="geodineum"
    case "$SVC_TYPE" in
        app|daemon|scheduled|gcore-service) SVC_GROUP="$SVC_NAME" ;;
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
    print_kv "Constellation" "$SVC_CONSTELLATION"
    print_kv "Profile" "$SVC_PROFILE"
    [[ -n "$SVC_LANG" ]] && print_kv "Language" "$SVC_LANG"
    [[ -n "$SVC_PORT" ]] && print_kv "Port" "127.0.0.1:${SVC_PORT}"
    [[ -n "$SVC_SCHEDULE" ]] && print_kv "Schedule" "$SVC_SCHEDULE"
    print_kv "Cred group" "$([ "${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}" == OWN ] && echo "$SVC_NAME" || echo "${GEO_TYPE_CRED_GROUP[$SVC_TYPE]}")"
    print_kv "Mail" "${SVC_MAIL_DOMAIN:-skip}"
    [[ "$SVC_FORM" == "true" ]] && print_kv "Form endpoint" "form/submit.php → COMMS"
    [[ -n "$SVC_NODE" ]] && print_kv "Delegated to" "$SVC_NODE (master mints, worker installs)"
    [[ -n "$SVC_OWNER" ]] && print_kv "Owner/Tenant" "$SVC_OWNER"
    local rows_plan="${GEO_TYPE_ROWS[$SVC_TYPE]}"
    [[ -n "$SVC_NODE" ]] && rows_plan="$GEO_DELEGATED_ROWS"
    [[ "$SVC_WORKER" == "true" ]] && rows_plan="(host rows only) ${rows_plan}"
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
    echo "    geodineum status ${SVC_NAME}"
    echo "    sudo geodineum grants show ${SVC_NAME}"
    case "$SVC_TYPE" in
        app|daemon|gcore-service)
            echo "    # replace ${SVC_PATH}/src/main.* with your code, then:"
            echo "    sudo systemctl start geodineum-${SVC_NAME}"
            ;;
        scheduled)
            echo "    # replace ${SVC_PATH}/src/main.* with the job; it runs ${SVC_SCHEDULE:-hourly}:"
            echo "    systemctl list-timers geodineum-${SVC_NAME}.timer"
            ;;
        webapp-gcore)
            echo "    # app code: ${SVC_PATH}/src (outside the docroot)"
            echo "    # front controller: ${SVC_PATH}/public_html/index.php → ../src/bootstrap.php"
            echo "    curl -sI https://${SVC_DOMAIN}/ | head -1"
            ;;
    esac
    if [[ "$SVC_ENV" != "production" ]]; then
        echo "    # promote when ready: geodineum env set ${SVC_NAME} production"
    fi
    echo ""
}


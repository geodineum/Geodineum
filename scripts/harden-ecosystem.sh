#!/bin/bash
#
# Geodineum Ecosystem Hardening
# ==============================
# Deploys web-deny rules (.htaccess + nginx-deny.conf) to ALL ecosystem
# directories across dev and prod, ensures they're not gitignored, and
# stages them for commit.
#
# Why: www-data is in the geodineum group for credential file access.
# A compromised PHP process could read source code and infrastructure files.
# These rules prevent those directories from ever being served via HTTP.
#
# Run from anywhere. Handles both dev (~/gh/) and prod (/opt/geodineum/).
# Safe to re-run (idempotent).
#
# Usage:
#   sudo ./scripts/harden-ecosystem.sh [--dry-run]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Configuration
# =============================================================================

# Source common.sh for path variables if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_ROOT="$(dirname "$SCRIPT_DIR")"
[[ -f "${CLI_ROOT}/lib/common.sh" ]] && source "${CLI_ROOT}/lib/common.sh" 2>/dev/null || true

# Dev repos (git-tracked — deploy + fix .gitignore + git add)
DEV_ROOT="${GEODINEUM_DEV_ROOT:-${HOME}/gh}"
DEV_REPOS=(
    "${DEV_ROOT}/gNode"
    "${DEV_ROOT}/Geodineum"
    "${DEV_ROOT}/Geodineum-COMMS"
    "${DEV_ROOT}/Geodineum-BAK"
    "${DEV_ROOT}/gCore"
    "${DEV_ROOT}/gCube"
    "${DEV_ROOT}/gTemplate"
    "${DEV_ROOT}/gNode-Client"
)

# Additional web/theme components present in this checkout, discovered by
# their manifest group so comprehensive setups are covered without naming
# their components in this source.
for _wd in "${DEV_ROOT}"/*/; do
    _wn="$(basename "$_wd")"
    case " ${DEV_REPOS[*]} " in *" ${DEV_ROOT}/${_wn} "*) continue ;; esac
    grep -qE 'group:[[:space:]]*geodineum-code' "${_wd}geodeploy.yaml" 2>/dev/null \
        && DEV_REPOS+=("${DEV_ROOT}/${_wn}")
done

# Extension checkouts under pro/ (existence-guarded; covers any installed set)
for _ext_dir in "${DEV_ROOT}"/pro/*/*/; do
    [[ -d "$_ext_dir" ]] && DEV_DIRS+=("${_ext_dir%/}")
done
# Deployment-local additions (space-separated absolute paths)
for _extra_dir in ${GEODINEUM_EXTRA_HARDEN_DIRS:-}; do
    DEV_DIRS+=("$_extra_dir")
done

# Prod dirs (not git-modified — deploy only)
PROD_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"
PROD_DIRS=(
    "${PROD_ROOT}"
    "${PROD_ROOT}/gNode"
    "${PROD_ROOT}/Geodineum"
    "${PROD_ROOT}/Geodineum-COMMS"
    "${PROD_ROOT}/Geodineum-BAK"
    "${PROD_ROOT}/gNode-Client"
    "${PROD_ROOT}/services"
)

for _ext_dir in "${PROD_ROOT}"/pro/*/*/; do
    [[ -d "$_ext_dir" ]] && PROD_DIRS+=("${_ext_dir%/}")
done
for _extra_dir in ${GEODINEUM_EXTRA_HARDEN_DIRS:-}; do
    PROD_DIRS+=("${PROD_ROOT}/${_extra_dir##*/}")
done

# Config dir (no git — deploy only)
CONFIG_ROOT="${GEODINEUM_CONFIG_ROOT:-/etc/geodineum}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}  OK${NC}  $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_fix()     { echo -e "${GREEN} FIX${NC}  $1"; }
log_skip()    { echo -e "${DIM} ---${NC}  $1"; }
log_dry()     { echo -e "${YELLOW}[DRY]${NC} $1"; }

deployed=0
gitignore_fixed=0
git_staged=0

# =============================================================================
# Functions
# =============================================================================

# Theme repos (WordPress-symlinked) need a smart-deny .htaccess that
# allows static-asset extensions while still denying PHP execution + sensitive
# files. Listed by basename — kept tight so we don't accidentally smart-deny
# a non-theme repo that should be blanket-denied.
__is_theme_repo() {
    # A WordPress theme (symlinked into wp-content/themes) carries a
    # style.css theme header. Detected structurally so child themes aren't
    # enumerated by name in this source.
    [[ -f "$1/style.css" ]] && grep -qiE '^[[:space:]]*Theme Name:' "$1/style.css" 2>/dev/null
}

# Write .htaccess to a directory
#
# Posture:
#   - Theme repos at top level → smart-deny (allow CSS/JS/fonts/manifests,
#     deny PHP + dotfiles + sensitive extensions). Apache follows the
#     WP symlink from /var/www/<site>/wp-content/themes/<theme>/ and reads
#     THIS file to serve theme assets; a blanket Require all denied breaks
#     every page render (canary regression root cause).
#   - Everything else → blanket-deny (no web-served content, defensive).
#     Subdirs of theme repos (scripts/, tests/) also get blanket-deny.
write_htaccess() {
    local dir="$1"
    local label="${2:-Geodineum}"
    local htaccess="${dir}/.htaccess"
    local is_theme=false
    if __is_theme_repo "$dir"; then
        is_theme=true
    fi

    # Idempotency: skip if a managed file with the right posture is already
    # in place. Theme files contain "child theme" or "parent theme" comments;
    # blanket-deny files contain "no web access".
    if [[ -f "$htaccess" ]]; then
        if $is_theme && grep -q "theme.*WordPress symlinks\|theme — WordPress symlinks" "$htaccess" 2>/dev/null; then
            return 0  # smart-deny already in place
        fi
        if ! $is_theme && grep -q "Geodineum\|denied\|Deny from all" "$htaccess" 2>/dev/null; then
            return 0  # blanket-deny already in place
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would write: ${htaccess}"
        return 0
    fi

    if $is_theme; then
        cat > "$htaccess" << 'HTEOF'
# Theme repo — WordPress symlinks /var/www/<site>/wp-content/themes/<theme>
# into this directory. Apache follows the symlink and reads this .htaccess
# when serving theme assets. Posture: allow static assets, deny code + dotfiles.

# Static asset whitelist (CSS, JS, fonts, images, PWA manifests, sourcemaps)
<FilesMatch "\.(css|js|map|woff2?|ttf|eot|otf|svg|png|jpe?g|gif|webp|ico|webmanifest|html|xml)$">
    Require all granted
</FilesMatch>

# PHP files are require-included by WordPress, NEVER URL-requested directly
<FilesMatch "\.(php|phtml|phps)$">
    Require all denied
</FilesMatch>

# Dotfiles (.git, .gitignore, .env, .htaccess itself)
<FilesMatch "^\.">
    Require all denied
</FilesMatch>

# Sensitive file extensions (config, logs, scripts, build artifacts)
<FilesMatch "\.(env|log|md|sh|bash|yaml|yml|toml|lock|bak|swp|orig|rs|rb|py)$">
    Require all denied
</FilesMatch>
HTEOF
    else
        cat > "$htaccess" << HTEOF
# ${label} — no web access
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order deny,allow
    Deny from all
</IfModule>
HTEOF
    fi
    # root:www-data — Apache (www-data, NOT in the broad geodineum group)
    # must read every .htaccess it honors, or it fails closed and 403s the
    # whole subtree ("unable to read htaccess file, denying to be safe").
    chown root:www-data "$htaccess" 2>/dev/null || true
    chmod 640 "$htaccess" 2>/dev/null || true
    deployed=$((deployed + 1))
}

# Write nginx-deny.conf to a directory
write_nginx_deny() {
    local dir="$1"
    local label="${2:-Geodineum}"
    local ngconf="${dir}/nginx-deny.conf"

    if [[ -f "$ngconf" ]] && grep -q "Geodineum\|deny all" "$ngconf" 2>/dev/null; then
        return 0  # already protected
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would write: ${ngconf}"
        return 0
    fi

    local dirname
    dirname=$(basename "$dir")
    cat > "$ngconf" << NGEOF
# ${label} — no web access
location ~ /${dirname} {
    deny all;
    return 404;
}
NGEOF
    chown root:geodineum "$ngconf" 2>/dev/null || true
    chmod 640 "$ngconf" 2>/dev/null || true
}

# Deploy both deny files to a directory and its sensitive subdirs
harden_dir() {
    local dir="$1"
    local label="${2:-$(basename "$dir")}"

    [[ ! -d "$dir" ]] && return 0

    write_htaccess "$dir" "$label"
    write_nginx_deny "$dir" "$label"

    # Also protect sensitive subdirs
    for subdir in scripts tests docs .git bin daemon src; do
        if [[ -d "${dir}/${subdir}" ]]; then
            write_htaccess "${dir}/${subdir}" "${label}/${subdir}"
            write_nginx_deny "${dir}/${subdir}" "${label}/${subdir}"
        fi
    done
}

# Ensure .htaccess and nginx-deny.conf are NOT gitignored in a repo.
# Fixes the .gitignore if needed.
fix_gitignore() {
    local repo_dir="$1"
    local gitignore="${repo_dir}/.gitignore"

    [[ ! -f "$gitignore" ]] && return 0

    local needs_fix=false

    # Check if .htaccess is ignored (any pattern that would match)
    if grep -qE '^\/?\.htaccess$' "$gitignore" 2>/dev/null; then
        needs_fix=true
    fi

    # Check if nginx-deny.conf is ignored
    if grep -qE '^nginx-deny\.conf$|^\*\.conf$' "$gitignore" 2>/dev/null; then
        needs_fix=true
    fi

    if [[ "$needs_fix" != "true" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would fix .gitignore in ${repo_dir}"
        return 0
    fi

    # Remove any line that ignores .htaccess at root level
    if grep -qE '^\/?\.htaccess$' "$gitignore" 2>/dev/null; then
        # Replace the ignore with a negation (keep .htaccess tracked)
        sed -i '/^\/?\.htaccess$/d' "$gitignore"
        log_fix "Removed .htaccess ignore from ${gitignore}"
        gitignore_fixed=$((gitignore_fixed + 1))
    fi

    # Ensure security files are explicitly NOT ignored (negation patterns)
    local marker="# Geodineum security — web-deny rules must be tracked"
    if ! grep -q "$marker" "$gitignore" 2>/dev/null; then
        cat >> "$gitignore" << 'GIEOF'

# Geodineum security — web-deny rules must be tracked
!**/.htaccess
!**/nginx-deny.conf
GIEOF
        log_fix "Added negation rules to ${gitignore}"
        gitignore_fixed=$((gitignore_fixed + 1))
    fi
}

# Stage .htaccess and nginx-deny.conf files in a git repo
git_stage_deny_files() {
    local repo_dir="$1"

    [[ ! -d "${repo_dir}/.git" ]] && return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        local count
        count=$(find "$repo_dir" \( -name ".htaccess" -o -name "nginx-deny.conf" \) -not -path "*/.git/*" 2>/dev/null | wc -l)
        [[ $count -gt 0 ]] && log_dry "Would stage ${count} deny files in $(basename "$repo_dir")"
        return 0
    fi

    # Stage all .htaccess and nginx-deny.conf files (excluding .git internals)
    local files
    files=$(find "$repo_dir" \( -name ".htaccess" -o -name "nginx-deny.conf" \) -not -path "*/.git/*" 2>/dev/null || true)

    if [[ -n "$files" ]]; then
        local count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            git -C "$repo_dir" add "$f" 2>/dev/null && count=$((count + 1)) || true
        done <<< "$files"

        # Also stage .gitignore if it was modified
        if git -C "$repo_dir" diff --name-only .gitignore 2>/dev/null | grep -q ".gitignore"; then
            git -C "$repo_dir" add .gitignore 2>/dev/null || true
        fi

        if [[ $count -gt 0 ]]; then
            log_success "Staged ${count} deny files in $(basename "$repo_dir")"
            git_staged=$((git_staged + count))
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${BOLD}Geodineum Ecosystem Hardening${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
echo ""

# ── Phase 1: Dev repos (deploy + fix gitignore + git stage) ──

echo -e "${BOLD}Phase 1: Dev Repos${NC} (${DEV_ROOT}/)"
echo ""

for repo in "${DEV_REPOS[@]}"; do
    if [[ ! -d "$repo" ]]; then
        continue
    fi

    local_name=$(basename "$repo")
    log_info "Processing: ${local_name}"

    # Deploy deny files
    harden_dir "$repo" "$local_name"

    # Fix .gitignore
    fix_gitignore "$repo"

    # Stage in git
    git_stage_deny_files "$repo"
done

echo ""

# ── Phase 2: Prod dirs (deploy only — no git modifications) ──

echo -e "${BOLD}Phase 2: Prod Dirs${NC} (${PROD_ROOT}/)"
echo ""

for dir in "${PROD_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        continue
    fi

    local_name=$(basename "$dir")
    log_info "Processing: ${local_name}"
    harden_dir "$dir" "$local_name — production"
done

# Prod standalone services
if [[ -d "${PROD_ROOT}/services" ]]; then
    for svc_dir in "${PROD_ROOT}/services"/*/; do
        [[ -d "$svc_dir" ]] || continue
        harden_dir "$svc_dir" "$(basename "$svc_dir") — service"
    done
fi

# Prod PHP components (sensitive subdirs only) — discovered by manifest
# group so comprehensive installs are covered without naming components here.
prod_php_comps=(gCore gTemplate gCube)
for _pd in "${PROD_ROOT}"/*/; do
    _pn="$(basename "$_pd")"
    case " ${prod_php_comps[*]} " in *" ${_pn} "*) continue ;; esac
    grep -qE 'group:[[:space:]]*geodineum-code' "${_pd}geodeploy.yaml" 2>/dev/null \
        && prod_php_comps+=("$_pn")
done
for php_comp in "${prod_php_comps[@]}"; do
    comp_dir="${PROD_ROOT}/${php_comp}"
    [[ ! -d "$comp_dir" ]] && continue
    for subdir in scripts tests docs .git bin; do
        if [[ -d "${comp_dir}/${subdir}" ]]; then
            write_htaccess "${comp_dir}/${subdir}" "${php_comp}/${subdir} — production"
            write_nginx_deny "${comp_dir}/${subdir}" "${php_comp}/${subdir} — production"
        fi
    done
done

echo ""

# ── Phase 3: Config + credentials ──

echo -e "${BOLD}Phase 3: Config & Credentials${NC} (${CONFIG_ROOT}/)"
echo ""

if [[ -d "$CONFIG_ROOT" ]]; then
    harden_dir "$CONFIG_ROOT" "Geodineum config"
    [[ -d "${CONFIG_ROOT}/credentials" ]] && \
        harden_dir "${CONFIG_ROOT}/credentials" "Geodineum credentials"
    [[ -d "${CONFIG_ROOT}/components" ]] && \
        harden_dir "${CONFIG_ROOT}/components" "Geodineum component config"
fi

echo ""

# ── Summary ──

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Summary${NC}"
echo -e "  Deny files deployed:   ${GREEN}${deployed}${NC}"
echo -e "  .gitignore fixes:      ${GREEN}${gitignore_fixed}${NC}"
echo -e "  Files staged in git:   ${GREEN}${git_staged}${NC}"
echo ""

if [[ $git_staged -gt 0 ]]; then
    echo -e "${BOLD}Next:${NC} Review and commit the staged files:"
    echo ""
    for repo in "${DEV_REPOS[@]}"; do
        [[ ! -d "${repo}/.git" ]] && continue
        staged_count=$(cd "$repo" && git diff --cached --name-only 2>/dev/null | wc -l)
        if [[ $staged_count -gt 0 ]]; then
            echo "  cd ${repo} && git status --short"
        fi
    done
    echo ""
    echo "  Then commit each repo with:"
    echo "    git commit -m 'Deploy web-deny rules (defense-in-depth for www-data group access)'"
    echo ""
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}No changes were made (dry-run mode).${NC}"
    echo "Run without --dry-run to apply."
    echo ""
fi

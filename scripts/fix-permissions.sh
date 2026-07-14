#!/bin/bash
#
# Geodineum Permission Fix
# =========================
# One-shot script to fix all permission issues found during audit.
# Safe to re-run (idempotent). Must run as root.
#
# Issues addressed:
#   1. Web-read files root:root → root:www-data 640 (Apache www-data must read .htaccess)
#   2. World-readable dirs/files → 750/640 with geodineum group
#   3. Non-PHP service repos group www-data → gnode (not PHP-autoloaded)
#   4. Stale backup files with wrong ownership
#   5. ${GEODINEUM_ROOT}/services/ root:root → root:geodineum
#
# Usage:
#   sudo ./scripts/fix-permissions.sh [--dry-run]
#

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Deploy-user is no longer hardcoded as
# `august`. Resolve from the GEODEPLOY_DEPLOY_USER env (matches
# lib/geodeploy.sh:28) with safe-fallback.
DEPLOY_USER="${GEODEPLOY_DEPLOY_USER:-${SUDO_USER:-${USER}}}"
if [[ -z "$DEPLOY_USER" ]] || ! id "$DEPLOY_USER" &>/dev/null; then
    echo "FATAL: deploy user '$DEPLOY_USER' does not exist on this host. Set GEODEPLOY_DEPLOY_USER explicitly." >&2
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_fix()     { echo -e "${GREEN} FIX${NC}  $1"; }
log_skip()    { echo -e "${DIM} ---${NC}  $1 (already correct)"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_dry()     { echo -e "${YELLOW}[DRY]${NC}  $1"; }
log_step()    { echo ""; echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }

fixes=0

# Run a fix command (or log it in dry-run mode)
fix() {
    local desc="$1"
    shift
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$desc"
    else
        "$@" && log_fix "$desc" || log_warn "FAILED: $desc"
    fi
    fixes=$((fixes + 1))
}

# Conditional fix — only if current state doesn't match expected
fix_ownership() {
    local path="$1"
    local expected_owner="$2"
    local expected_mode="$3"
    local desc="${4:-$path}"
    local recursive="${5:-false}"

    [[ ! -e "$path" ]] && return 0

    local current_owner current_mode
    current_owner=$(stat -c '%U:%G' "$path" 2>/dev/null)
    current_mode=$(stat -c '%a' "$path" 2>/dev/null)

    local needs_fix=false
    [[ "$current_owner" != "$expected_owner" ]] && needs_fix=true
    [[ "$current_mode" != "$expected_mode" ]] && needs_fix=true

    if [[ "$needs_fix" != "true" ]]; then
        return 0
    fi

    local owner_part="${expected_owner}"
    if [[ "$recursive" == "true" ]]; then
        fix "${desc}: ${current_owner} ${current_mode} → ${expected_owner} ${expected_mode}" \
            chown -R "$owner_part" "$path"
        fix "${desc}: dirs → ${expected_mode}" \
            find "$path" -type d -exec chmod "$expected_mode" {} \;
        local file_mode="${expected_mode%0}0"  # 750 → 740... no
        # For recursive, set dirs to expected_mode and files to -10 (750→640)
        local fmode
        case "$expected_mode" in
            750) fmode=640 ;;
            700) fmode=600 ;;
            *) fmode=640 ;;
        esac
        fix "${desc}: files → ${fmode}" \
            find "$path" -type f -exec chmod "$fmode" {} \;
    else
        if [[ "$current_owner" != "$expected_owner" ]]; then
            fix "${desc}: ${current_owner} → ${expected_owner}" \
                chown "$owner_part" "$path"
        fi
        if [[ "$current_mode" != "$expected_mode" ]]; then
            fix "${desc}: ${current_mode} → ${expected_mode}" \
                chmod "$expected_mode" "$path"
        fi
    fi
}

# =============================================================================
# Checks
# =============================================================================

# Source common.sh for path variables if available
FIX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_CLI_ROOT="$(dirname "$FIX_SCRIPT_DIR")"
[[ -f "${FIX_CLI_ROOT}/lib/common.sh" ]] && source "${FIX_CLI_ROOT}/lib/common.sh" 2>/dev/null || true

# Path variables (use common.sh values or defaults)
GEODINEUM_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"
GEODINEUM_CONFIG_ROOT="${GEODINEUM_CONFIG_ROOT:-/etc/geodineum}"
GEODINEUM_CREDENTIALS_DIR="${GEODINEUM_CREDENTIALS_DIR:-${GEODINEUM_CONFIG_ROOT}/credentials}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR]${NC}  Must run as root: sudo $0"
    exit 1
fi

# Verify groups exist
if ! getent group geodineum >/dev/null 2>&1; then
    echo -e "${RED}[ERR]${NC}  geodineum group does not exist"
    exit 1
fi
if ! getent group gnode >/dev/null 2>&1; then
    echo -e "${RED}[ERR]${NC}  gnode group does not exist"
    exit 1
fi

echo ""
echo -e "${BOLD}Geodineum Permission Fix${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"

# =============================================================================
# 1. Web-read files: root:root → root:www-data 640
#    Apache runs as www-data, which is NOT in the broad `geodineum` group
#    (deliberate blast-radius limit). An .htaccess Apache cannot READ makes
#    Apache fail closed — "unable to read htaccess file, denying access to
#    be safe" — silently 403ing the whole subtree. So every .htaccess (and
#    nginx-deny.conf) must be www-data-readable: root:www-data 640.
#    (Pre-fix this set root:geodineum on a false "www-data is in geodineum"
#    premise — fine by accident for deny-dirs, fatal for theme asset dirs.)
# =============================================================================

log_step "1. Web-read files (root:www-data 640 — Apache must read .htaccess)"

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    fix_ownership "$f" "root:www-data" "640" "$(echo "$f" | sed "s|/opt/geodineum/||")"
done < <(find "${GEODINEUM_ROOT}" "${GEODINEUM_CONFIG_ROOT}" \( -name ".htaccess" -o -name "nginx-deny.conf" \) 2>/dev/null)

# =============================================================================
# 2. ${GEODINEUM_CONFIG_ROOT}/ — remove world access
# =============================================================================

log_step "2. ${GEODINEUM_CONFIG_ROOT}/ (no world access)"

fix_ownership "${GEODINEUM_CONFIG_ROOT}"               "root:geodineum"  "750" "${GEODINEUM_CONFIG_ROOT}/"
fix_ownership "${GEODINEUM_CONFIG_ROOT}/components"     "gnode:geodineum" "750" "${GEODINEUM_CONFIG_ROOT}/components/"
fix_ownership "${GEODINEUM_CONFIG_ROOT}/bootstrap.env"  "gnode:geodineum" "640" "bootstrap.env"

# components subdirs
for d in ${GEODINEUM_CONFIG_ROOT}/components/*/; do
    [[ -d "$d" ]] || continue
    fix_ownership "$d" "gnode:geodineum" "750" "$(basename "$d")/"
    find "$d" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r f; do
        fix_ownership "$f" "gnode:geodineum" "640" "$(basename "$d")/$(basename "$f")"
    done
done

# Credentials dir: gnode:geodineum so ecosystem members can traverse
# Files inside keep their own ownership (gnode:gnode for daemon, gnode:www-data for clients)
fix_ownership "${GEODINEUM_CONFIG_ROOT}/credentials" "gnode:geodineum" "750" "credentials/"

# Sites dir
fix_ownership "${GEODINEUM_CONFIG_ROOT}/sites" "gnode:geodineum" "750" "sites/"

# Clean up stale backups
for bak in ${GEODINEUM_CONFIG_ROOT}/*.bak-*; do
    [[ -f "$bak" ]] || continue
    fix_ownership "$bak" "root:geodineum" "640" "$(basename "$bak")"
done

# =============================================================================
# 3. ${GEODINEUM_ROOT}/services/ — root:root → root:geodineum
# =============================================================================

log_step "3. ${GEODINEUM_ROOT}/services/"

fix_ownership "${GEODINEUM_ROOT}/services" "root:geodineum" "750" "services/"

# Fix any service subdirs
for svc in ${GEODINEUM_ROOT}/services/*/; do
    [[ -d "$svc" ]] || continue
    fix_ownership "$svc" "root:geodineum" "750" "services/$(basename "$svc")/"
done

# =============================================================================
# 5. Daemon binary must be executable by gnode
# =============================================================================

log_step "5. Daemon binary"

DAEMON_BIN="${GEODINEUM_ROOT}/gNode/daemon/target/release/gnode-daemon"
if [[ -f "$DAEMON_BIN" ]]; then
    fix_ownership "$DAEMON_BIN" "gnode:gnode" "750" "gnode-daemon binary"
fi

# =============================================================================
# 6. auto-deploy.sh — runs as  via cron
# =============================================================================

log_step "6. auto-deploy.sh"

if [[ -f "${GEODINEUM_ROOT}/auto-deploy.sh" ]]; then
    fix_ownership "${GEODINEUM_ROOT}/auto-deploy.sh" ":geodineum" "750" "auto-deploy.sh"
fi

# =============================================================================
# 7. Verify www-data is NOT in gnode group
# =============================================================================

log_step "7. Group membership audit"

if id -nG www-data 2>/dev/null | grep -qw gnode; then
    fix "Remove www-data from gnode group" \
        gpasswd -d www-data gnode
else
    log_skip "www-data not in gnode group"
fi

# www-data belongs to its single-purpose groups only: geodineum-code (read
# shared source) and geodineum-web (read web-site creds). It must NOT be in the
# broad geodineum group — a web RCE must not gain ecosystem-wide read.
for g in geodineum-code geodineum-web; do
    getent group "$g" >/dev/null 2>&1 || groupadd --system "$g"
    if ! id -nG www-data 2>/dev/null | grep -qw "$g"; then
        fix "Add www-data to $g group" usermod -aG "$g" www-data
    else
        log_skip "www-data in $g group"
    fi
done
if id -nG www-data 2>/dev/null | grep -qw geodineum; then
    fix "Remove www-data from geodineum group (blast-radius isolation)" \
        gpasswd -d www-data geodineum
else
    log_skip "www-data not in geodineum group"
fi

# =============================================================================
# 8. Infrastructure repos: ensure august:gnode (not www-data)
#    These are not PHP-autoloaded. Only deploy user + daemon need access.
# =============================================================================

log_step "8. Infrastructure component groups"

for repo in gNode Geodineum-BAK; do
    dir="${GEODINEUM_ROOT}/${repo}"
    [[ ! -d "$dir" ]] && continue
    current=$(stat -c '%G' "$dir" 2>/dev/null)
    if [[ "$current" != "gnode" ]]; then
        fix "${repo}: ${current} → gnode" \
            chown -R "":gnode "$dir"
        find "$dir" -type d -exec chmod 750 {} \; 2>/dev/null
        find "$dir" -type f -exec chmod 640 {} \; 2>/dev/null
        find "$dir" -name "*.sh" -exec chmod 750 {} \; 2>/dev/null
    else
        log_skip "${repo} group already gnode"
    fi
done

# Geodineum-COMMS runs under its own user — group is
# geodineum-comms, NOT gnode. Runtime-writable subdirs (.gnode/, logs/)
# stay geodineum-comms-OWNED (service writes as geodineum-comms).
comms_dir="${GEODINEUM_ROOT}/Geodineum-COMMS"
if [[ -d "$comms_dir" ]]; then
    current=$(stat -c '%G' "$comms_dir" 2>/dev/null)
    if [[ "$current" != "geodineum-comms" ]]; then
        fix "Geodineum-COMMS: ${current} → geodineum-comms" \
            chown -R "":geodineum-comms "$comms_dir"
        find "$comms_dir" -type d -exec chmod 750 {} \; 2>/dev/null
        find "$comms_dir" -type f -exec chmod 640 {} \; 2>/dev/null
        find "$comms_dir" -name "*.sh" -exec chmod 750 {} \; 2>/dev/null
        chmod 750 "$comms_dir/target/release/geodineum-comms" 2>/dev/null
    else
        log_skip "Geodineum-COMMS group already geodineum-comms"
    fi
    for subdir in "$comms_dir/.gnode" "$comms_dir/logs"; do
        if [[ -d "$subdir" ]]; then
            fix_ownership "$subdir" "geodineum-comms:geodineum-comms" "750" "COMMS/$(basename "$subdir")/" "true"
        fi
    done
fi

# Geodineum-BAK: backups/ and logs/ must be gnode-OWNED (service writes as gnode)
for subdir in "${GEODINEUM_ROOT}/Geodineum-BAK/backups" "${GEODINEUM_ROOT}/Geodineum-BAK/logs"; do
    if [[ -d "$subdir" ]]; then
        fix_ownership "$subdir" "gnode:gnode" "750" "BAK/$(basename "$subdir")/" "true"
    fi
done

# gShield: the file-scan cargo binaries lose +x to the 640 file-sweep like every
# other release binary, but nothing restored them — the daily scan then died
# with a misleading "Binary not found". Restore +x on the release binaries.
gshield_rel="${GEODINEUM_ROOT}/gShield/gshield-geov/target/release"
if [[ -d "$gshield_rel" ]]; then
    for bin in gshield-file-scan gshield-file-learn gshield-learn gshield-score; do
        [[ -f "$gshield_rel/$bin" ]] && chmod 0750 "$gshield_rel/$bin" 2>/dev/null
    done
fi

# =============================================================================
# 9. Shared source (framework + library + themes): group geodineum-code — the
#    SINGLE source-read class. NOT www-data: that conflates source with the
#    web-credentials group and would force services into www-data to use the
#    library. www-data + geodine read via geodineum-code membership.
# =============================================================================

log_step "9. Shared-source component groups (geodineum-code)"

getent group geodineum-code >/dev/null 2>&1 || groupadd --system geodineum-code
for u in www-data geodine; do
    id "$u" >/dev/null 2>&1 || continue
    id -nG "$u" 2>/dev/null | grep -qw geodineum-code && continue
    fix "Add $u to geodineum-code group" usermod -aG geodineum-code "$u"
done

# Web components discovered from the manifest group so comprehensive
# installs are covered without enumerating their components in this source.
web_repos=(gCore gTemplate gCube gNode-Client)
for _wd in "${GEODINEUM_ROOT}"/*/; do
    _wn="$(basename "$_wd")"
    [[ " ${web_repos[*]} " == *" ${_wn} "* ]] && continue
    grep -qE 'group:[[:space:]]*geodineum-code' "${_wd}geodeploy.yaml" 2>/dev/null \
        && web_repos+=("$_wn")
done
for repo in "${web_repos[@]}"; do
    dir="${GEODINEUM_ROOT}/${repo}"
    [[ ! -d "$dir" ]] && continue
    current=$(stat -c '%G' "$dir" 2>/dev/null)
    if [[ "$current" != "geodineum-code" ]]; then
        fix "${repo}: ${current} → geodineum-code" \
            chown -R "":geodineum-code "$dir"
        find "$dir" -type d -exec chmod 2750 {} \; 2>/dev/null
        find "$dir" -type f -exec chmod 640 {} \; 2>/dev/null
    else
        log_skip "${repo} group already geodineum-code"
    fi
done

# =============================================================================
# 10. .git dirs in prod repos must be august-owned (git pull requires write)
# =============================================================================

log_step "10. .git directory ownership"

for gitdir in ${GEODINEUM_ROOT}/*/.git; do
    [[ -d "$gitdir" ]] || continue
    repo=$(basename "$(dirname "$gitdir")")
    current_owner=$(stat -c '%U' "$gitdir" 2>/dev/null)
    if [[ "$current_owner" != "$DEPLOY_USER" ]]; then
        fix "${repo}/.git: ${current_owner} → ${DEPLOY_USER}" \
            chown -R "$DEPLOY_USER" "$gitdir"
    fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Summary: ${fixes} fixes applied${NC}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}No changes were made (dry-run mode).${NC}"
    echo "Run without --dry-run to apply."
else
    echo -e "${BOLD}Verification:${NC}"
    echo "  # Check web-deny files are readable by Apache"
    echo "  sudo -u www-data cat ${GEODINEUM_ROOT}/.htaccess"
    echo ""
    echo "  # Check no world-readable files remain"
    echo "  find ${GEODINEUM_ROOT} /etc/geodineum -maxdepth 1 -perm -o+r 2>/dev/null"
    echo ""
    echo "  # Check group memberships"
    echo "  groups www-data"
    echo ""
    echo -e "  ${DIM}Restart Apache to pick up .htaccess changes: sudo systemctl reload apache2${NC}"
fi
echo ""

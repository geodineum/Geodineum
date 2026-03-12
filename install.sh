#!/bin/bash
#
# Geodineum Installer
# ====================
# Central entry point for installing the Geodineum ecosystem.
#
# Fetches components from GitHub, resolves dependencies, installs
# to /opt/geodineum/, and optionally deploys a WordPress site.
#
# Usage:
#   # Interactive — guided setup
#   sudo ./install.sh
#
#   # Install specific profile
#   sudo ./install.sh --profile standard
#
#   # Install specific components
#   sudo ./install.sh --components gcore,gtemplate-wp,giris
#
#   # Full site deployment (installs components + WordPress + SSL + gNode)
#   sudo ./install.sh --site geodineum.com --theme giris --env production
#
#   # Dry run — show what would be installed
#   sudo ./install.sh --profile full --dry-run
#
# Requirements:
#   - sudo access
#   - git, curl, PHP 8.x, Apache2, MySQL/MariaDB
#   - Domain DNS pointing to server (for SSL)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/geodineum"
COMPONENTS_FILE="${SCRIPT_DIR}/components.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}  OK${NC}  $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1"; }
log_step()    { echo ""; echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; }

# Defaults
PROFILE=""
COMPONENTS=""
SITE_DOMAIN=""
SITE_THEME=""
SITE_THEME_PATH=""
SITE_ENV="staging"
DRY_RUN=false
SKIP_BUILD=false
GITHUB_ORG_BASE="https://github.com"

#######################################
# Banner
#######################################

banner() {
    echo ""
    echo -e "${CYAN}    ╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}    ║${NC}                                                   ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}     ${BOLD}G E O D I N E U M${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                   ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}     Geometric topology for the spatial web        ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                   ${CYAN}║${NC}"
    echo -e "${CYAN}    ╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
}

#######################################
# Argument Parsing
#######################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)      PROFILE="$2"; shift 2 ;;
            --components)   COMPONENTS="$2"; shift 2 ;;
            --site)         SITE_DOMAIN="$2"; shift 2 ;;
            --theme)        SITE_THEME="$2"; shift 2 ;;
            --theme-path)   SITE_THEME_PATH="$2"; shift 2 ;;
            --env)          SITE_ENV="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --skip-build)   SKIP_BUILD=true; shift ;;
            --help|-h)      usage; exit 0 ;;
            *)              log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    echo "Usage: sudo $0 [options]"
    echo ""
    echo "Options:"
    echo "  --profile <name>        Install a predefined set: minimal, standard, full"
    echo "  --components <list>     Comma-separated components to install"
    echo "  --site <domain>         Deploy a WordPress site after component install"
    echo "  --theme <name>          Child theme slug (e.g., giris, gcube, gtesseract)"
    echo "  --theme-path <path>     Path to child theme source (auto-fetched if omitted)"
    echo "  --env <environment>     DTAP environment: testing, staging, acceptance, production"
    echo "  --dry-run               Show what would be installed without doing it"
    echo "  --skip-build            Skip compilation steps (use existing binaries)"
    echo "  --help, -h              Show this help"
    echo ""
    echo "Profiles:"
    echo "  minimal     gTemplate-wp + gCore + gNode-Client (free-tier, no daemon)"
    echo "  standard    Full stack with gNode daemon + ValKey"
    echo "  full        Everything including premium modules + notifications"
    echo ""
    echo "Examples:"
    echo "  # Guided interactive installation"
    echo "  sudo $0"
    echo ""
    echo "  # Install standard stack + deploy geodineum.com with gIris theme"
    echo "  sudo $0 --profile standard --site geodineum.com --theme giris --env production"
    echo ""
    echo "  # Just install gCore framework"
    echo "  sudo $0 --components gcore"
    echo ""
    echo "  # See what full profile would install"
    echo "  sudo $0 --profile full --dry-run"
}

#######################################
# Component Resolution
#######################################

# Map component name → GitHub repo
get_repo() {
    case "$1" in
        gnode-daemon)   echo "geodineum/gNode" ;;
        gnode-client)   echo "geodineum/gNode-Client" ;;
        gcore)          echo "geodineum/gCore" ;;
        gcore-premium)  echo "geodineum/gCore-Premium" ;;
        gtemplate-wp)   echo "geodineum/gTemplate" ;;
        gcube)          echo "geodineum/gCube" ;;
        gtesseract)     echo "geodineum/gTesseract" ;;
        giris)          echo "nierto/gIris" ;;
        gnode-comms)    echo "geodineum/gNode-COMMS" ;;
        gshield)        echo "geodineum/gShield" ;;
        *)              echo "" ;;
    esac
}

# Map component name → install directory name
get_install_dir() {
    case "$1" in
        gnode-daemon)   echo "gNode" ;;
        gnode-client)   echo "gNode-Client" ;;
        gcore)          echo "gCore" ;;
        gcore-premium)  echo "premium/gCore" ;;
        gtemplate-wp)   echo "gTemplate-wp" ;;
        gcube)          echo "gCube" ;;
        gtesseract)     echo "gTesseract" ;;
        giris)          echo "gIris" ;;
        gnode-comms)    echo "gNode-COMMS" ;;
        gshield)        echo "gShield" ;;
        *)              echo "" ;;
    esac
}

# Get dependencies for a component (returns space-separated list)
get_deps() {
    case "$1" in
        gnode-daemon)   echo "valkey" ;;
        gnode-client)   echo "valkey" ;;
        gcore)          echo "gnode-client" ;;
        gcore-premium)  echo "gcore" ;;
        gtemplate-wp)   echo "gcore" ;;
        gcube)          echo "gtemplate-wp" ;;
        gtesseract)     echo "gtemplate-wp" ;;
        giris)          echo "gtemplate-wp" ;;
        gnode-comms)    echo "gnode-daemon" ;;
        *)              echo "" ;;
    esac
}

# Resolve profile to component list
get_profile_components() {
    case "$1" in
        minimal)    echo "gnode-client gcore gtemplate-wp" ;;
        standard)   echo "gnode-daemon gnode-client gcore gtemplate-wp" ;;
        full)       echo "gnode-daemon gnode-client gcore gcore-premium gtemplate-wp gnode-comms gshield" ;;
        *)          log_error "Unknown profile: $1"; exit 1 ;;
    esac
}

# Resolve full dependency tree (topological sort)
resolve_dependencies() {
    local requested=($@)
    local resolved=()
    local seen=()

    resolve_one() {
        local comp="$1"

        # Skip if already resolved
        for r in "${resolved[@]}"; do
            [[ "$r" == "$comp" ]] && return
        done

        # Skip external deps (valkey)
        [[ "$comp" == "valkey" ]] && return

        # Check for cycles
        for s in "${seen[@]}"; do
            [[ "$s" == "$comp" ]] && return
        done
        seen+=("$comp")

        # Resolve dependencies first
        local deps=$(get_deps "$comp")
        for dep in $deps; do
            resolve_one "$dep"
        done

        resolved+=("$comp")
    }

    for comp in "${requested[@]}"; do
        resolve_one "$comp"
    done

    echo "${resolved[@]}"
}

#######################################
# Component Installation
#######################################

fetch_component() {
    local name="$1"
    local repo=$(get_repo "$name")
    local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"

    if [[ -z "$repo" ]]; then
        log_warning "Unknown component: ${name} (skipping)"
        return 1
    fi

    if [[ -d "$install_dir" ]] && [[ -d "${install_dir}/.git" ]]; then
        log_info "Updating ${name} (${install_dir})"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_success "[dry-run] Would git pull ${repo}"
            return 0
        fi
        cd "$install_dir"
        git pull --ff-only origin main 2>/dev/null || git pull --ff-only 2>/dev/null || {
            log_warning "Pull failed for ${name} — using existing version"
        }
        log_success "${name} updated"
    else
        log_info "Fetching ${name} from ${repo}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_success "[dry-run] Would clone ${GITHUB_ORG_BASE}/${repo}.git → ${install_dir}"
            return 0
        fi
        mkdir -p "$(dirname "$install_dir")"
        git clone "${GITHUB_ORG_BASE}/${repo}.git" "$install_dir" 2>/dev/null || {
            # Try SSH if HTTPS fails
            git clone "git@github.com:${repo}.git" "$install_dir" || {
                log_error "Failed to clone ${repo}"
                return 1
            }
        }
        log_success "${name} fetched"
    fi

    # Set permissions: owner root/deploy, group www-data, 750/640
    chgrp -R www-data "$install_dir" 2>/dev/null || true
    find "$install_dir" -type d ! -path '*/.git/*' -exec chmod 750 {} \; 2>/dev/null || true
    find "$install_dir" -type f ! -path '*/.git/*' -exec chmod 640 {} \; 2>/dev/null || true

    return 0
}

post_install() {
    local name="$1"
    local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"

    case "$name" in
        gnode-daemon)
            if [[ "$SKIP_BUILD" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
                log_info "Building gNode daemon (this may take a few minutes)..."
                if [[ -f "${install_dir}/daemon/Cargo.toml" ]]; then
                    cd "${install_dir}/daemon"
                    cargo build --release 2>&1 | tail -3
                    log_success "gNode daemon built"
                fi

                # Install systemd service if script exists
                if [[ -x "${install_dir}/scripts/install-gnode-service.sh" ]]; then
                    "${install_dir}/scripts/install-gnode-service.sh" 2>/dev/null || true
                fi
            fi
            ;;

        gcore)
            if [[ "$DRY_RUN" != "true" ]] && [[ -f "${install_dir}/composer.json" ]]; then
                log_info "Running composer install for gCore..."
                cd "$install_dir"
                composer install --no-dev --optimize-autoloader 2>/dev/null || {
                    log_warning "Composer install failed — run manually: cd ${install_dir} && composer install"
                }
            fi
            ;;

        gtemplate-wp)
            if [[ "$DRY_RUN" != "true" ]] && [[ -f "${install_dir}/composer.json" ]]; then
                log_info "Running composer install for gTemplate-wp..."
                cd "$install_dir"
                composer install --no-dev --optimize-autoloader 2>/dev/null || true
            fi
            ;;
    esac
}

#######################################
# Prerequisites Check
#######################################

check_prerequisites() {
    log_step "Checking Prerequisites"

    local missing=()

    # Root check
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
    log_success "Running as root"

    # git
    if command -v git &>/dev/null; then
        log_success "git $(git --version | awk '{print $3}')"
    else
        log_error "git not found"
        missing+=("git")
    fi

    # PHP
    if command -v php &>/dev/null; then
        log_success "PHP $(php -v | head -1 | awk '{print $2}')"

        # Check extensions
        for ext in redis json mbstring; do
            if php -m 2>/dev/null | grep -qi "^${ext}$"; then
                log_success "  ext-${ext}"
            else
                log_warning "  ext-${ext} not found (required for gCore)"
            fi
        done
    else
        log_error "PHP not found"
        missing+=("php")
    fi

    # Composer
    if command -v composer &>/dev/null; then
        log_success "Composer $(composer --version 2>/dev/null | awk '{print $3}')"
    else
        log_warning "Composer not found (needed for gCore/gTemplate-wp)"
    fi

    # Apache
    if systemctl is-active --quiet apache2 2>/dev/null; then
        log_success "Apache2 running"
    else
        log_warning "Apache2 not running (needed for site deployment)"
    fi

    # MySQL
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
        log_success "MySQL/MariaDB running"
    else
        log_warning "MySQL/MariaDB not running (needed for WordPress)"
    fi

    # ValKey
    if systemctl is-active --quiet valkey-gnode 2>/dev/null; then
        log_success "ValKey (valkey-gnode) running"
    else
        log_warning "ValKey not running (needed for gNode integration)"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing critical prerequisites: ${missing[*]}"
        exit 1
    fi

    # Create install root
    if [[ ! -d "$INSTALL_ROOT" ]]; then
        log_info "Creating ${INSTALL_ROOT}"
        mkdir -p "$INSTALL_ROOT"
        chmod 750 "$INSTALL_ROOT"
        chgrp www-data "$INSTALL_ROOT"
    fi
    log_success "Install root: ${INSTALL_ROOT}"
}

#######################################
# Interactive Mode
#######################################

interactive_setup() {
    log_step "Setup Mode"

    echo ""
    echo "  Available profiles:"
    echo ""
    echo -e "    ${BOLD}1) minimal${NC}    — Theme + framework only (no real-time features)"
    echo -e "    ${BOLD}2) standard${NC}   — Full stack with gNode daemon + ValKey"
    echo -e "    ${BOLD}3) full${NC}        — Everything including premium modules"
    echo ""

    local choice
    read -p "  Select profile [1-3, default: 2]: " -n 1 choice
    echo ""

    case "${choice:-2}" in
        1) PROFILE="minimal" ;;
        2) PROFILE="standard" ;;
        3) PROFILE="full" ;;
        *) PROFILE="standard" ;;
    esac

    log_info "Selected profile: ${PROFILE}"

    # Ask about site deployment
    echo ""
    local deploy
    read -p "  Deploy a WordPress site? [y/N]: " -n 1 deploy
    echo ""

    if [[ "$deploy" =~ ^[Yy]$ ]]; then
        read -p "  Domain name: " SITE_DOMAIN
        echo ""
        echo "  Available child themes:"
        echo -e "    ${BOLD}1) giris${NC}       — Three.js twisted toroid (geodineum.com)"
        echo -e "    ${BOLD}2) gcube${NC}       — CSS 3D cube (6 faces)"
        echo -e "    ${BOLD}3) gtesseract${NC}  — CSS 4D tesseract (8 cells)"
        echo -e "    ${BOLD}4) none${NC}        — Parent theme standalone"
        echo ""

        local theme_choice
        read -p "  Select theme [1-4, default: 4]: " -n 1 theme_choice
        echo ""

        case "${theme_choice:-4}" in
            1) SITE_THEME="giris" ;;
            2) SITE_THEME="gcube" ;;
            3) SITE_THEME="gtesseract" ;;
            4) SITE_THEME="" ;;
        esac

        read -p "  Environment [testing/staging/acceptance/production, default: staging]: " SITE_ENV
        SITE_ENV="${SITE_ENV:-staging}"
    fi
}

#######################################
# Main
#######################################

main() {
    parse_args "$@"
    banner

    # Interactive mode if no profile/components specified
    if [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]] && [[ -z "$SITE_DOMAIN" ]]; then
        interactive_setup
    fi

    check_prerequisites

    # Resolve component list
    local component_list=()

    if [[ -n "$PROFILE" ]]; then
        component_list=($(get_profile_components "$PROFILE"))
    fi

    if [[ -n "$COMPONENTS" ]]; then
        IFS=',' read -ra extra <<< "$COMPONENTS"
        component_list+=("${extra[@]}")
    fi

    # Add theme to components if deploying a site
    if [[ -n "$SITE_THEME" ]]; then
        component_list+=("$SITE_THEME")
    fi

    # Resolve dependencies
    local resolved=($(resolve_dependencies "${component_list[@]}"))

    if [[ ${#resolved[@]} -eq 0 ]]; then
        log_error "No components to install"
        exit 1
    fi

    # Show plan
    log_step "Installation Plan"
    echo ""
    for comp in "${resolved[@]}"; do
        local repo=$(get_repo "$comp")
        local dir=$(get_install_dir "$comp")
        local status="fetch"
        if [[ -d "${INSTALL_ROOT}/${dir}/.git" ]]; then
            status="update"
        fi
        printf "    %-20s %-30s %s\n" "$comp" "$repo" "[${status}]"
    done
    echo ""

    if [[ -n "$SITE_DOMAIN" ]]; then
        echo -e "  ${BOLD}Site deployment:${NC}"
        echo "    Domain:      ${SITE_DOMAIN}"
        echo "    Theme:       ${SITE_THEME:-gtemplate-wp (standalone)}"
        echo "    Environment: ${SITE_ENV}"
        echo ""
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run — no changes will be made"
        echo ""
    fi

    # Confirm
    if [[ "$DRY_RUN" != "true" ]]; then
        local proceed
        read -p "  Proceed? [Y/n]: " -n 1 proceed
        echo ""
        if [[ "$proceed" =~ ^[Nn]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Fetch and install components
    log_step "Installing Components"

    for comp in "${resolved[@]}"; do
        fetch_component "$comp" || continue
        post_install "$comp"
    done

    # Deploy site if requested
    if [[ -n "$SITE_DOMAIN" ]] && [[ "$DRY_RUN" != "true" ]]; then
        log_step "Deploying WordPress Site"

        local install_script="${INSTALL_ROOT}/gTemplate-wp/scripts/install-geodineum.sh"

        if [[ ! -x "$install_script" ]]; then
            log_error "Site installer not found at ${install_script}"
            log_info "Run manually after gTemplate-wp is installed:"
            log_info "  sudo ${install_script} ${SITE_DOMAIN} --theme ${SITE_THEME} --env ${SITE_ENV}"
            exit 1
        fi

        local theme_args=""
        if [[ -n "$SITE_THEME" ]]; then
            local theme_path="${INSTALL_ROOT}/$(get_install_dir "$SITE_THEME")"
            theme_args="--theme ${SITE_THEME} --theme-path ${theme_path}"
        fi

        "$install_script" "$SITE_DOMAIN" $theme_args "$SITE_ENV"
    fi

    # Summary
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}          ${BOLD}Installation Complete${NC}                      ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Components installed to: ${INSTALL_ROOT}/"
    echo ""

    for comp in "${resolved[@]}"; do
        local dir=$(get_install_dir "$comp")
        if [[ -d "${INSTALL_ROOT}/${dir}" ]]; then
            echo -e "    ${GREEN}●${NC} ${comp} → ${INSTALL_ROOT}/${dir}"
        else
            echo -e "    ${YELLOW}○${NC} ${comp} (dry-run)"
        fi
    done

    echo ""

    if [[ -n "$SITE_DOMAIN" ]]; then
        echo "  Site: https://${SITE_DOMAIN}"
    fi

    echo ""
    echo "  Documentation: https://github.com/geodineum/geodineum"
    echo ""
}

main "$@"

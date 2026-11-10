#!/bin/bash
#
# Geodineum Ecosystem Installer
# ==============================
# One-command installation for the entire Geodineum ecosystem.
#
# Usage:
#   sudo ./install.sh                              # Interactive setup wizard
#   sudo ./install.sh --profile minimal            # Smaller component set
#   sudo ./install.sh --components gcore,gcube     # Install specific components
#   sudo ./install.sh --dry-run                    # Preview without changes
#   sudo ./install.sh --yes                        # Non-interactive
#
# Requirements:
#   - sudo access (or root)
#   - Ubuntu/Debian (apt) — other distros: install prereqs manually
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
INSTALL_ROOT="${GEODINEUM_ROOT:-/opt/geodineum}"
GNODE_SCRIPTS=""  # set after gNode is located

# =============================================================================
# Colors + Logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}  OK${NC}  $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC}  $1" >&2; }
log_step()    { echo ""; echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; }
log_detail()  { echo -e "    ${DIM}$1${NC}"; }
log_dry()     { echo -e "${YELLOW}[DRY]${NC} Would: $1"; }

# =============================================================================
# Shared installer primitives
# =============================================================================
if [[ -r "${LIB_DIR}/component-primitives.sh" ]]; then
    # shellcheck source=lib/component-primitives.sh
    source "${LIB_DIR}/component-primitives.sh"
else
    log_error "Missing required library: ${LIB_DIR}/component-primitives.sh"
    log_info "This file ships with the installer; if you're running from a custom"
    log_info "checkout, ensure lib/component-primitives.sh is present."
    exit 1
fi

# Sourced early: main() calls validate_domain.
if [[ -r "${LIB_DIR}/common.sh" ]]; then
    source "${LIB_DIR}/common.sh"
fi

# =============================================================================
# Defaults
# =============================================================================

# Empty so a plain `sudo ./install.sh` enters the interactive wizard.
PROFILE=""
COMPONENTS=""
# Optional even in the standard profile: a joining node may get notifications from elsewhere.
WITH_COMMS=true
COMMS_EXPLICIT=false
SITE_DOMAIN=""
SITE_THEME=""
SITE_ENV=""
DRY_RUN=false
SKIP_BUILD=false
YES_MODE=false
# Wizard state
DEPLOY_TIER=""            # web | full | compute | replica (when joining constellation)
MASTER_IP=""              # constellation master's VPN IP (non-interactive join)
JOIN_BUNDLE=""            # file written by `geodineum node add` on the master
VALKEY_REPLICA="false"    # true if this node runs a ValKey replica
SKIP_LOCAL_VALKEY="false" # true if using remote ValKey only (web / full / compute node)
CONSTELLATION_DAEMON_PW=""  # master's valkey_daemon.password, pasted during a join install
CONSTELLATION_REPLICA_PW="" # master's valkey_replica.password, pasted during a replica join
CONSTELLATION_NODE_USER=""  # this node's own ValKey ACL user, minted by the master's `expand`
CONSTELLATION_NODE_PW=""    # its password (empty = fall back to the shared gnode_daemon login)
GNODE_NODE_ID=""            # this node's unique id / consumer name (default: hostname on a join, "master" otherwise)
# Clone URL choice: docs/GITHUB_AUTH.md.
GIT_PROTOCOL="${GEODINEUM_GIT_PROTOCOL:-}"
GITHUB_TOKEN="${GEODINEUM_GITHUB_TOKEN:-}"

# Component ref: --branch, then GEODINEUM_BRANCH, then this checkout's branch, else origin's default.
GEODINEUM_BRANCH="${GEODINEUM_BRANCH:-}"
if [[ -z "$GEODINEUM_BRANCH" ]] && [[ -d "${SCRIPT_DIR}/.git" ]]; then
    _detected_branch=$(/usr/bin/git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -n "$_detected_branch" ]] && [[ "$_detected_branch" != "HEAD" ]]; then
        GEODINEUM_BRANCH="$_detected_branch"
    fi
    unset _detected_branch
fi
if [[ "$GIT_PROTOCOL" == "ssh" ]]; then
    GITHUB_CLONE_PREFIX="git@github.com:"
    GITHUB_CLONE_SUFFIX=".git"
elif [[ -n "$GITHUB_TOKEN" ]]; then
    GITHUB_CLONE_PREFIX="https://x-access-token:${GITHUB_TOKEN}@github.com/"
    GITHUB_CLONE_SUFFIX=".git"
else
    GITHUB_CLONE_PREFIX="https://github.com/"
    GITHUB_CLONE_SUFFIX=".git"
fi

# Deploy user (populated by Phase 0)
DEPLOY_USER=""
DEPLOY_HOME=""

# Detected state (populated by Phase 1)
HAS_GIT=false
HAS_PHP=false
HAS_COMPOSER=false
HAS_CARGO=false
HAS_APACHE=false
HAS_MYSQL=false
HAS_VALKEY=false
HAS_SYSTEMD=false
VALKEY_RUNNING=false
GNODE_INSTALLED=false
CONFIG_EXISTS=false

# =============================================================================
# Banner + Usage
# =============================================================================

banner() {
    # Each body row pads to 56 visible columns so the right border lines up.
    echo ""
    echo -e "${YELLOW}    ╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}    ║${NC}                                                        ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ║${NC}          ${BOLD}${YELLOW}G  E  O  D  I  N  E  U  M${NC}                     ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ║${NC}          ${DIM}geometric topology for the spatial web${NC}        ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ║${NC}                                                        ${YELLOW}║${NC}"
    echo -e "${YELLOW}    ╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    echo "Usage: sudo $0 [options]"
    echo ""
    echo "Interactive setup wizard (2 steps):"
    echo "  1. Constellation — new deployment or join existing"
    echo "  2. Components — standard (all) or custom selection"
    echo ""
    echo "Options:"
    echo "  --profile <name>        Install predefined set: minimal, standard, compute"
    echo "  --components <list>     Comma-separated components to install"
    echo "  --no-comms              Exclude Geodineum-COMMS (use a dedicated SMTP"
    echo "                          node, or notifications from the constellation master)"
    echo "  --with-comms            Force-include Geodineum-COMMS (non-interactive)"
    echo "  --install-root <path>   Production install location (default: /opt/geodineum)"
    echo "  --constellation-name <n> Name of a new constellation (default: geodineum; a-z, 0-9, _)"
    echo "  --deploy-tier <tier>    web, full, compute, or replica (join an existing constellation)"
    echo "  --master-ip <ip>        Constellation master's VPN IP (with --deploy-tier; e.g. 10.66.0.1)"
    echo "  --join <bundle>         Join the constellation whose master ran 'geodineum node add' (the file it wrote)"
    echo "  --site <domain>         Deploy a WordPress site after install"
    echo "  --theme <name>          Child theme: gcube (default)"
    echo "  --env <environment>     DTAP: testing, staging, acceptance, production (default: the site's recorded one; a new site: testing)"
    echo "  --dry-run               Preview without making changes"
    echo "  --skip-build            Skip compilation (use existing binaries)"
    echo "  --branch <ref>          Git branch/tag to fetch for ALL component repos"
    echo "                          (default: each repo's main), e.g. --branch my-feature-branch"
    echo "  --yes, -y               Non-interactive (accept defaults)"
    echo "  --help, -h              Show this help"
    echo ""
    echo "Environment variables:"
    echo "  GEODINEUM_ROOT          Production install root (default: /opt/geodineum)"
    echo "  GEODINEUM_GITHUB_TOKEN  GitHub personal access token (for HTTPS clone)"
    echo "  GEODINEUM_BRANCH        Same as --branch (env-var form)"
    echo ""
    echo "Profiles:"
    echo "  minimal     WordPress themes + gCore framework (no daemon)"
    echo "  standard    Full stack: daemon + ValKey + framework + themes + notifications + backup"
    echo "  compute     gNode daemon only — no web server, PHP, or database"
    echo ""
    echo "Examples:"
    echo "  sudo $0                                     # Interactive guided setup"
    echo "  sudo $0 --profile standard --yes            # Non-interactive standard"
    echo "  sudo $0 --install-root /srv/geodineum       # Custom install location"
    echo "  sudo $0 --deploy-tier replica --master-ip 10.66.0.1  # Join existing"
    echo "  sudo $0 --deploy-tier compute --master-ip 10.66.0.1 --yes  # Non-web worker"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)      PROFILE="$2"; shift 2 ;;
            --components)   COMPONENTS="$2"; shift 2 ;;
            --no-comms)     WITH_COMMS=false; COMMS_EXPLICIT=true; shift ;;
            --with-comms)   WITH_COMMS=true;  COMMS_EXPLICIT=true; shift ;;
            --site)         SITE_DOMAIN="$2"; shift 2 ;;
            --theme)        SITE_THEME="$2"; shift 2 ;;
            --env)          SITE_ENV="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --skip-build)   SKIP_BUILD=true; shift ;;
            --yes|-y)       YES_MODE=true; shift ;;
            --constellation-name) GNODE_TOPOLOGY_NAMESPACE="$2"; CONSTELLATION_NAME_SET=true; shift 2 ;;
            --deploy-tier)  DEPLOY_TIER="$2"; shift 2 ;;
            --master-ip)    MASTER_IP="$2"; shift 2 ;;
            --join)         JOIN_BUNDLE="$2"; shift 2 ;;
            --install-root) INSTALL_ROOT="$2"; shift 2 ;;
            --branch)       GEODINEUM_BRANCH="$2"; shift 2 ;;
            --help|-h)      banner; usage; exit 0 ;;
            *)              log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

# =============================================================================
# Prompt helper (respects --yes mode)
# =============================================================================

confirm() {
    local prompt="$1"
    local default="${2:-y}"

    if [[ "$YES_MODE" == "true" ]]; then
        return 0
    fi

    local response
    if [[ "$default" == "y" ]]; then
        read -p "  ${prompt} [Y/n]: " -n 1 -r response
    else
        read -p "  ${prompt} [y/N]: " -n 1 -r response
    fi
    echo ""

    if [[ "$default" == "y" ]]; then
        [[ ! "$response" =~ ^[Nn]$ ]]
    else
        [[ "$response" =~ ^[Yy]$ ]]
    fi
}

# =============================================================================
# Install root validation — ensure custom paths are usable
# =============================================================================

validate_install_root() {
    local path="$1"
    local required_mb="${2:-2048}"  # 2GB default minimum

    if [[ "${path:0:1}" != "/" ]]; then
        log_error "Install root must be an absolute path: ${path}"
        return 1
    fi

    local check_target="$path"
    if [[ ! -d "$path" ]]; then
        check_target=$(dirname "$path")
        while [[ ! -d "$check_target" && "$check_target" != "/" ]]; do
            check_target=$(dirname "$check_target")
        done
    fi

    if [[ "$DRY_RUN" != "true" ]] && [[ ! -w "$check_target" ]]; then
        log_error "Install root not writable: ${check_target}"
        log_info "Check permissions or run with sudo"
        return 1
    fi

    local mount_opts
    mount_opts=$(findmnt -n -o OPTIONS --target "$check_target" 2>/dev/null || echo "")
    if [[ -n "$mount_opts" ]] && echo "$mount_opts" | grep -q "noexec"; then
        log_error "Filesystem mounted noexec at ${check_target} — gNode daemon cannot execute"
        log_info "Choose a different install root or remount without noexec"
        return 1
    fi

    local avail_mb
    avail_mb=$(df -Pm "$check_target" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$avail_mb" ]] && [[ "$avail_mb" -lt "$required_mb" ]]; then
        log_warning "Install root has only ${avail_mb}MB available (recommended: ${required_mb}MB+)"
        log_info "Install may fail during component fetch/build"
    fi

    return 0
}

# =============================================================================
# Component Resolution
# =============================================================================

get_repo() {
    case "$1" in
        gnode-daemon)       echo "geodineum/gNode" ;;
        gnode-client)       echo "geodineum/gNode-Client" ;;
        gcore)              echo "geodineum/gCore" ;;
        gtemplate-wp)       echo "geodineum/gTemplate" ;;
        gcube)              echo "geodineum/gCube" ;;
        geodineum-comms)    echo "geodineum/Geodineum-COMMS" ;;
        geodineum-bak)      echo "geodineum/Geodineum-BAK" ;;
        *)                  echo "" ;;
    esac
}

get_install_dir() {
    case "$1" in
        gnode-daemon)       echo "gNode" ;;
        gnode-client)       echo "gNode-Client" ;;
        gcore)              echo "gCore" ;;
        gtemplate-wp)       echo "gTemplate" ;;
        gcube)              echo "gCube" ;;
        geodineum-comms)    echo "Geodineum-COMMS" ;;
        geodineum-bak)      echo "Geodineum-BAK" ;;
        *)                  echo "" ;;
    esac
}

get_deps() {
    case "$1" in
        gnode-daemon)       echo "valkey" ;;
        gnode-client)       echo "valkey" ;;
        gcore)              echo "gnode-client" ;;
        gtemplate-wp)       echo "gcore" ;;
        gcube)              echo "gtemplate-wp" ;;
        geodineum-comms)    echo "gnode-daemon" ;;
        geodineum-bak)      echo "" ;;
        *)                  echo "" ;;
    esac
}

get_profile_components() {
    case "$1" in
        minimal)    echo "gnode-client gcore gtemplate-wp" ;;
        standard)   echo "gnode-daemon gnode-client gcore gtemplate-wp gcube geodineum-comms geodineum-bak" ;;
        compute)    echo "gnode-daemon" ;;
        *)          log_error "Unknown profile: $1 (available: minimal, standard, compute)"; exit 1 ;;
    esac
}

# Maps --deploy-tier to profile + ValKey flags; keep in sync with the wizard's tier cases.
apply_deploy_tier() {
    [[ -z "$DEPLOY_TIER" ]] && return 0
    case "$DEPLOY_TIER" in
        web)
            [[ -z "$PROFILE" ]] && PROFILE="minimal"
            SKIP_LOCAL_VALKEY="true"
            ;;
        full)
            [[ -z "$PROFILE" ]] && PROFILE="standard"
            SKIP_LOCAL_VALKEY="true"
            ;;
        compute)
            [[ -z "$PROFILE" ]] && PROFILE="compute"
            SKIP_LOCAL_VALKEY="true"
            ;;
        replica)
            [[ -z "$PROFILE" ]] && PROFILE="standard"
            VALKEY_REPLICA="true"
            log_warning "Replica tier is EXPERIMENTAL (no read/write split yet — writes must reach the master)."
            ;;
        *)
            log_error "Unknown --deploy-tier: ${DEPLOY_TIER} (expected: web | full | compute | replica)"
            exit 1
            ;;
    esac
    if [[ -n "$MASTER_IP" ]]; then
        VALKEY_HOST="$MASTER_IP"
        VALKEY_PORT="${VALKEY_PORT:-47445}"
    fi
    if [[ "$SKIP_LOCAL_VALKEY" == "true" || "$VALKEY_REPLICA" == "true" ]] && [[ -z "${VALKEY_HOST:-}" ]]; then
        log_error "Joining a constellation requires the master's VPN IP — pass --master-ip <ip> (or set VALKEY_HOST)."
        exit 1
    fi
    log_info "Deploy tier: ${DEPLOY_TIER} (profile=${PROFILE:-?}, master ValKey=${VALKEY_HOST:-unset}:${VALKEY_PORT:-47445})"
}

resolve_dependencies() {
    local requested=($@)
    local resolved=()
    local seen=()

    resolve_one() {
        local comp="$1"
        for r in "${resolved[@]:-}"; do [[ "$r" == "$comp" ]] && return; done
        [[ "$comp" == "valkey" ]] && return
        for s in "${seen[@]:-}"; do [[ "$s" == "$comp" ]] && return; done
        seen+=("$comp")
        local deps
        deps=$(get_deps "$comp")
        for dep in $deps; do resolve_one "$dep"; done
        resolved+=("$comp")
    }

    for comp in "${requested[@]}"; do resolve_one "$comp"; done
    echo "${resolved[@]}"
}

needs_daemon() {
    for comp in "$@"; do
        [[ "$comp" == "gnode-daemon" ]] && return 0
    done
    return 1
}

needs_php() {
    for comp in "$@"; do
        case "$comp" in
            gcore|gtemplate-wp|gnode-client) return 0 ;;
        esac
    done
    return 1
}

# True when WordPress (Apache, MySQL, wp-cli) is needed.
needs_wordpress() {
    for comp in "$@"; do
        case "$comp" in
            gtemplate-wp|gcube) return 0 ;;
        esac
    done
    [[ -n "$SITE_DOMAIN" ]] && return 0
    return 1
}

has_gcore() {
    for comp in "$@"; do
        [[ "$comp" == "gcore" ]] && return 0
    done
    return 1
}

# =============================================================================
# PHASE 0: Deploy User Setup
# =============================================================================
# The installer runs as root; git and cargo run as the deploy user.

# Loads a passphrase-protected deploy key into an ssh-agent once, so clones do not each prompt.
ensure_ssh_agent_loaded() {
    local key="$1"
    local user="$2"

    if [[ ! -r "$key" ]]; then
        log_warning "Deploy key ${key} not readable — skipping ssh-agent setup"
        return 0
    fi

    # Succeeds only for a passphrase-free key.
    if sudo -u "$user" ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
        log_detail "Deploy key has no passphrase — ssh-agent not needed"
        return 0
    fi

    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    local agent_env="${user_home}/.ssh/.geodineum-agent.env"

    if [[ -r "$agent_env" ]]; then
        # shellcheck source=/dev/null
        source "$agent_env" 2>/dev/null
        if [[ -n "${SSH_AGENT_PID:-}" ]] && kill -0 "$SSH_AGENT_PID" 2>/dev/null \
           && [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
            local key_fp
            key_fp=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}')
            if [[ -n "$key_fp" ]] && \
               sudo -u "$user" env SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l 2>/dev/null | \
               grep -qF "$key_fp"; then
                log_success "Deploy key already loaded in ssh-agent (pid ${SSH_AGENT_PID})"
                export SSH_AUTH_SOCK SSH_AGENT_PID
                return 0
            fi
        fi
        rm -f "$agent_env"
    fi

    log_info "Starting ssh-agent for ${user} (deploy key is passphrase-protected)..."

    local agent_out
    agent_out=$(sudo -u "$user" ssh-agent -s 2>/dev/null) || {
        log_warning "Could not start ssh-agent for ${user} — per-clone passphrase prompts will fire"
        return 1
    }

    install -m 0600 -o "$user" -g "$user" /dev/null "$agent_env"
    printf '%s\n' "$agent_out" > "$agent_env"
    chown "${user}:${user}" "$agent_env"
    chmod 0600 "$agent_env"

    # shellcheck source=/dev/null
    source "$agent_env" 2>/dev/null

    log_info "Adding deploy key to agent — you'll be prompted for the passphrase ONCE."
    if ! sudo -u "$user" env SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add "$key" </dev/tty; then
        log_warning "ssh-add failed — per-clone passphrase prompts will fire"
        kill "$SSH_AGENT_PID" 2>/dev/null || true
        rm -f "$agent_env"
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1
    fi

    log_success "Deploy key loaded in ssh-agent (pid ${SSH_AGENT_PID}); subsequent clones won't prompt"

    export SSH_AUTH_SOCK SSH_AGENT_PID

    trap 'sudo -u '"$user"' kill "$SSH_AGENT_PID" 2>/dev/null || true; rm -f "'"$agent_env"'" 2>/dev/null || true' EXIT
}

# sudo -u that keeps SSH_AUTH_SOCK, so git reaches the loaded ssh-agent.
sudo_as_user() {
    local target_user="$1"; shift
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        sudo --preserve-env=SSH_AUTH_SOCK -u "$target_user" "$@"
    else
        sudo -u "$target_user" "$@"
    fi
}

phase_deploy_user() {
    log_step "Phase 0: Deploy User"

    local current_user="${SUDO_USER:-$(whoami)}"

    echo ""
    echo -e "  You are running as ${BOLD}${current_user}${NC}."
    echo -e "  The deploy user will own all source code and run auto-deploy."
    echo ""

    if [[ "$YES_MODE" == "true" ]]; then
        DEPLOY_USER="$current_user"
        log_info "Using current user: ${DEPLOY_USER} (--yes mode)"
    else
        local use_current
        read -p "  Deploy as ${current_user}? [Y/n]: " -n 1 use_current
        echo ""

        if [[ "${use_current:-Y}" =~ ^[Nn]$ ]]; then
            echo ""
            local new_user
            read -p "  Enter deploy username (will be created if needed): " new_user

            if [[ -z "$new_user" ]]; then
                log_error "No username provided"
                exit 1
            fi

            DEPLOY_USER="$new_user"

            if ! id -u "$DEPLOY_USER" &>/dev/null; then
                log_info "Creating user ${DEPLOY_USER}..."
                useradd --system --create-home --shell /bin/bash "$DEPLOY_USER"
                log_success "Created user ${DEPLOY_USER}"
            fi
        else
            DEPLOY_USER="$current_user"
        fi
    fi

    DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" 2>/dev/null | cut -d: -f6)

    if [[ -z "$DEPLOY_HOME" ]]; then
        log_error "Cannot determine home directory for ${DEPLOY_USER}"
        exit 1
    fi

    # One group per resource class (least privilege); www-data never joins a broad group.
    getent group gnode               &>/dev/null || groupadd --system gnode
    getent group geodineum           &>/dev/null || groupadd --system geodineum
    getent group geodineum-creds     &>/dev/null || groupadd --system geodineum-creds
    getent group geodineum-dash      &>/dev/null || groupadd --system geodineum-dash
    getent group geodineum-bootstrap &>/dev/null || groupadd --system geodineum-bootstrap
    # geodineum-web reads web-site credentials; geodineum-code reads shared source only.
    getent group geodineum-web       &>/dev/null || groupadd --system geodineum-web
    getent group geodineum-code      &>/dev/null || groupadd --system geodineum-code

    # Dedicated COMMS identity, so a compromised gateway is not the daemon.
    getent group geodineum-comms     &>/dev/null || groupadd --system geodineum-comms
    if ! getent passwd geodineum-comms &>/dev/null; then
        useradd --system --gid geodineum-comms --no-create-home \
                --home-dir /opt/geodineum/Geodineum-COMMS \
                --shell /usr/sbin/nologin geodineum-comms 2>/dev/null || \
            log_warning "Could not create geodineum-comms user — COMMS will fall back to manual setup"
    fi

    usermod -aG geodineum           "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-creds     "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-dash      "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-bootstrap "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG gnode               "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG systemd-journal     "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG www-data            "$DEPLOY_USER" 2>/dev/null || true

    # geodineum-bootstrap grants bootstrap.env read only; add a member only for a real read need.
    local _hosts_sites=1
    [[ "${DEPLOY_TIER:-}" == compute || "${DEPLOY_TIER:-}" == replica ]] && _hosts_sites=0
    (( _hosts_sites )) && usermod -aG geodineum-bootstrap www-data 2>/dev/null || true
    usermod -aG geodineum-bootstrap gnode    2>/dev/null || true
    if id geodineum-comms >/dev/null 2>&1; then
        usermod -aG geodineum-bootstrap geodineum-comms 2>/dev/null || true
    fi
    if id geodine >/dev/null 2>&1; then
        usermod -aG geodineum-bootstrap geodine 2>/dev/null || true
    fi

    # Group changes reach Apache/PHP-FPM only after their restart later in the install.
    if (( _hosts_sites )); then
        usermod -aG geodineum-web    www-data 2>/dev/null || true
        usermod -aG geodineum-code   www-data 2>/dev/null || true
    fi
    if id geodine >/dev/null 2>&1; then
        usermod -aG geodineum-code geodine 2>/dev/null || true
    fi
    log_success "${DEPLOY_USER} is in groups: geodineum, geodineum-creds, geodineum-dash, geodineum-bootstrap, gnode, systemd-journal, www-data"
    log_info "geodineum-bootstrap members: www-data, gnode, ${DEPLOY_USER}$(id geodineum-comms >/dev/null 2>&1 && echo ', geodineum-comms')$(id geodine >/dev/null 2>&1 && echo ', geodine')"
    log_info "geodineum-web members:       www-data (web-site creds only)"
    log_info "geodineum-code members:      www-data$(id geodine >/dev/null 2>&1 && echo ', geodine') (shared source only)"

    # Cron-driven auto-deploy has no SUDO_USER, so the deploy identity is recorded here.
    install -d -m 0751 -o root -g geodineum /etc/geodineum
    cat > /etc/geodineum/deploy.env <<EOF_DEPLOY_ENV
DEPLOY_USER=${DEPLOY_USER}
DEPLOY_HOME=${DEPLOY_HOME}
EOF_DEPLOY_ENV
    # Not a secret, but never world-readable; read by the deploy user.
    chmod 0640 /etc/geodineum/deploy.env
    chown root:geodineum-bootstrap /etc/geodineum/deploy.env
    log_detail "Persisted deploy identity to /etc/geodineum/deploy.env (root:geodineum-bootstrap 0640)"

    # --- SSH deploy key setup ---
    local ssh_dir="${DEPLOY_HOME}/.ssh"
    local deploy_key="${ssh_dir}/id_ed25519_geodeploy"

    if [[ -f "$deploy_key" ]]; then
        log_success "Deploy key exists: ${deploy_key}"
    else
        echo ""
        echo -e "  ${BOLD}SSH Deploy Key${NC}"
        echo -e "  A read-only SSH key is needed for pulling repos from GitHub."
        echo -e "  This key will ONLY be used for auto-deploy (pull-only access)."
        echo ""

        local key_choice
        read -p "  Generate a new deploy key? [Y/n]: " -n 1 key_choice
        echo ""

        if [[ "${key_choice:-Y}" =~ ^[Yy]$ ]] || [[ -z "$key_choice" ]]; then
            mkdir -p "$ssh_dir"
            chown "$DEPLOY_USER:$DEPLOY_USER" "$ssh_dir"
            chmod 700 "$ssh_dir"

            su - "$DEPLOY_USER" -c "ssh-keygen -t ed25519 -f '${deploy_key}' -N '' -C 'geodeploy@$(hostname) read-only'" 2>/dev/null
            chmod 600 "$deploy_key"
            chmod 644 "${deploy_key}.pub"
            log_success "Deploy key generated"
            echo ""
            echo -e "  ${BOLD}Public key (upload this to GitHub as a deploy key or machine user):${NC}"
            echo ""
            cat "${deploy_key}.pub"
            echo ""

            if [[ "$YES_MODE" != "true" ]]; then
                read -p "  Press Enter after adding the key to GitHub..." _
            fi
        else
            echo ""
            echo -e "  ${BOLD}Paste your SSH public key (one line):${NC}"
            local user_pubkey
            read -r user_pubkey

            if [[ -n "$user_pubkey" ]]; then
                mkdir -p "$ssh_dir"
                echo "$user_pubkey" > "${deploy_key}.pub"
                chown "$DEPLOY_USER:$DEPLOY_USER" "$ssh_dir" "${deploy_key}.pub"
                chmod 700 "$ssh_dir"
                chmod 644 "${deploy_key}.pub"
                log_success "Public key saved"
                log_warning "Private key must be placed at ${deploy_key} (600 permissions)"

                if [[ "$YES_MODE" != "true" ]]; then
                    read -p "  Press Enter after placing the private key..." _
                fi
            fi
        fi
    fi

    ensure_ssh_agent_loaded "$deploy_key" "$DEPLOY_USER"

    # --- SSH config for github-deploy host alias ---
    local ssh_config="${ssh_dir}/config"
    if ! grep -q "Host github-deploy" "$ssh_config" 2>/dev/null; then
        cat >> "$ssh_config" << SSHEOF

# Geodeploy: read-only pull access for auto-deploy
Host github-deploy
  HostName github.com
  User git
  IdentityFile ${deploy_key}
  IdentitiesOnly yes
SSHEOF
        chown "$DEPLOY_USER:$DEPLOY_USER" "$ssh_config"
        chmod 600 "$ssh_config"
        log_success "SSH config: github-deploy host alias added"
    else
        log_success "SSH config: github-deploy alias already configured"
    fi

    # --- Resolve GitHub clone protocol ---
    log_info "Resolving GitHub clone protocol..."
    if [[ "$GIT_PROTOCOL" == "ssh" ]] && [[ -f "${deploy_key}" ]]; then
        log_success "SSH (GEODINEUM_GIT_PROTOCOL=ssh + deploy key present)"
        GITHUB_CLONE_PREFIX="git@github-deploy:"
        GITHUB_CLONE_SUFFIX=".git"
    elif [[ "$GIT_PROTOCOL" == "https" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        log_success "HTTPS+PAT (GEODINEUM_GIT_PROTOCOL=https + token set)"
        GITHUB_CLONE_PREFIX="https://x-access-token:${GITHUB_TOKEN}@github.com/"
        GITHUB_CLONE_SUFFIX=".git"
    elif [[ -f "${deploy_key}" ]] && grep -q "Host github-deploy" "$ssh_config" 2>/dev/null; then
        # Not probed with `ssh -T`: under su it gives false negatives.
        log_success "SSH via github-deploy (deploy key + alias present)"
        GITHUB_CLONE_PREFIX="git@github-deploy:"
        GITHUB_CLONE_SUFFIX=".git"
    elif su - "$DEPLOY_USER" -c "ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1" | grep -qi "successfully authenticated"; then
        log_success "Deploy user's own SSH key authenticates to github.com — using that"
        GITHUB_CLONE_PREFIX="git@github.com:"
        GITHUB_CLONE_SUFFIX=".git"
    else
        log_warning "No SSH path available — falling back to HTTPS"
        log_info "To use SSH, generate a deploy key (see docs/GITHUB_AUTH.md)."
        log_info "To use a PAT, set GEODINEUM_GITHUB_TOKEN before re-running."
        GITHUB_CLONE_PREFIX="https://github.com/"
        GITHUB_CLONE_SUFFIX=".git"
    fi

    log_success "Deploy user: ${DEPLOY_USER} (home: ${DEPLOY_HOME})"
}

# =============================================================================
# PHASE 1: System Detection
# =============================================================================

phase_detection() {
    log_step "Phase 1/10: System Detection"

    if command -v git &>/dev/null; then
        HAS_GIT=true
        log_success "git $(git --version 2>/dev/null | awk '{print $3}')"
    else
        log_warning "git not found"
    fi

    if command -v php &>/dev/null; then
        HAS_PHP=true
        local php_ver
        php_ver=$(timeout 5 php -v 2>/dev/null </dev/null | head -1 | awk '{print $2}')
        log_success "PHP ${php_ver:-unknown}"
        local php_modules
        php_modules=$(timeout 5 php -m 2>/dev/null </dev/null || echo "")
        for ext in redis json mbstring mysqli curl xml igbinary yaml; do
            if echo "$php_modules" | grep -qi "^${ext}$"; then
                log_detail "ext-${ext} loaded"
            else
                log_detail "ext-${ext} MISSING"
            fi
        done
    else
        log_warning "PHP not found"
    fi

    # stdin from /dev/null avoids composer's interactive "Do not run as root" prompt.
    if command -v composer &>/dev/null; then
        HAS_COMPOSER=true
        local comp_ver
        comp_ver=$(composer --version --no-interaction 2>/dev/null </dev/null | awk '{print $3}' || echo "unknown")
        log_success "Composer ${comp_ver}"
    else
        log_warning "Composer not found"
    fi

    local cargo_bin=""
    if command -v cargo &>/dev/null; then
        cargo_bin="cargo"
    else
        # Under sudo, cargo is in the calling user's home, not root's.
        local real_user="${SUDO_USER:-}"
        if [[ -n "$real_user" ]]; then
            local real_home
            real_home=$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)
            if [[ -x "${real_home}/.cargo/bin/cargo" ]]; then
                cargo_bin="${real_home}/.cargo/bin/cargo"
                export PATH="${real_home}/.cargo/bin:${PATH}"
            fi
        fi
    fi
    if [[ -n "$cargo_bin" ]]; then
        HAS_CARGO=true
        log_success "cargo $($cargo_bin --version 2>/dev/null </dev/null | awk '{print $2}')"
    else
        log_warning "Rust/cargo not found"
    fi

    if command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=true
        log_success "systemd available"
    else
        log_warning "systemd not found (services won't auto-start)"
    fi

    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet apache2 2>/dev/null; then
        HAS_APACHE=true
        log_success "Apache2 running"
    elif command -v apache2 &>/dev/null || command -v apachectl &>/dev/null; then
        HAS_APACHE=true
        log_success "Apache2 installed (not running)"
    else
        log_detail "Apache2 not installed"
    fi

    if [[ "$HAS_SYSTEMD" == "true" ]] && (systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null); then
        HAS_MYSQL=true
        log_success "MySQL/MariaDB running"
    elif command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
        HAS_MYSQL=true
        log_success "MySQL/MariaDB installed (not running)"
    else
        log_detail "MySQL/MariaDB not installed"
    fi

    if command -v wp &>/dev/null; then
        log_success "WP-CLI found"
    else
        log_detail "WP-CLI not installed"
    fi

    if command -v certbot &>/dev/null; then
        log_success "certbot found"
    else
        log_detail "certbot not installed"
    fi

    detect_valkey

    if [[ -x "${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon" ]]; then
        GNODE_INSTALLED=true
        GNODE_SCRIPTS="${INSTALL_ROOT}/gNode/scripts"
        log_success "gNode daemon binary found"
    elif [[ -d "${INSTALL_ROOT}/gNode" ]]; then
        GNODE_SCRIPTS="${INSTALL_ROOT}/gNode/scripts"
        log_warning "gNode repo found but not built"
    else
        log_detail "gNode not yet installed"
    fi

    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet gnode-daemon 2>/dev/null; then
        log_success "gNode daemon running"
    fi

    if [[ -d "/etc/geodineum" ]] && [[ -f "/etc/geodineum/bootstrap.env" ]]; then
        CONFIG_EXISTS=true
        log_success "/etc/geodineum/ configured"
        local _gdn_lib="${GEODINEUM_LIB:-/usr/local/lib/geodineum}"
        if [[ -r "${_gdn_lib}/bootstrap-loader.sh" ]]; then
            # shellcheck source=/usr/local/lib/geodineum/bootstrap-loader.sh
            source "${_gdn_lib}/bootstrap-loader.sh"
            load_ecosystem_config 2>/dev/null || true
        elif [[ -r "${SCRIPT_DIR}/lib/bootstrap-loader.sh" ]]; then
            # shellcheck source=lib/bootstrap-loader.sh
            source "${SCRIPT_DIR}/lib/bootstrap-loader.sh"
            load_ecosystem_config 2>/dev/null || true
        fi
    else
        log_detail "/etc/geodineum/ not yet created"
    fi

    if [[ -d "$INSTALL_ROOT" ]]; then
        local comp_count
        comp_count=$(find "$INSTALL_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        log_success "${INSTALL_ROOT}/ exists (${comp_count} components)"
    else
        log_detail "${INSTALL_ROOT}/ not yet created"
    fi
}

detect_valkey() {
    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet valkey-gnode 2>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey running (valkey-gnode service, port 47445)"
        return
    fi

    if pgrep -x valkey-server &>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey process detected (valkey-server)"
        return
    fi

    if command -v docker &>/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi valkey; then
            HAS_VALKEY=true
            VALKEY_RUNNING=true
            log_success "ValKey running (Docker container)"
            return
        fi
    fi

    if command -v valkey-server &>/dev/null; then
        HAS_VALKEY=true
        log_success "valkey-server binary found (not running)"
        return
    fi

    if timeout 2 bash -c "echo PING | nc -q 1 127.0.0.1 47445 2>/dev/null" | grep -q PONG 2>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey responding on port 47445"
        return
    fi

    log_warning "ValKey not detected"
}

# Worker-side WireGuard setup for a join; every step is non-fatal and can be finished by hand.
wizard_constellation_wireguard_prep() {
    local master_ip="${VALKEY_HOST:-10.66.0.1}"
    local wg_dir="/etc/wireguard"
    local wg_key="${wg_dir}/wg-geodineum.key"
    local wg_pub="${wg_dir}/wg-geodineum.pub"
    local wg_conf="${wg_dir}/wg-geodineum.conf"
    local peer_name; peer_name="$(hostname -s 2>/dev/null || echo worker)"

    echo ""
    echo -e "  ${BOLD}WireGuard VPN (worker side)${NC}"
    echo -e "  ${DIM}This node reaches the constellation's ValKey only over an encrypted${NC}"
    echo -e "  ${DIM}WireGuard tunnel to the master. Preparing this node's key now.${NC}"
    echo ""

    if ! command -v wg >/dev/null 2>&1; then
        log_info "Installing wireguard-tools..."
        NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
            apt-get install -y wireguard-tools >/dev/null 2>&1 \
            || log_warning "wireguard-tools install failed — run: apt install wireguard-tools"
    fi

    install -d -m 700 "$wg_dir" 2>/dev/null || true
    if [[ ! -s "$wg_key" ]] && command -v wg >/dev/null 2>&1; then
        ( umask 077; wg genkey > "$wg_key" ) \
            && wg pubkey < "$wg_key" > "$wg_pub" \
            && log_success "Generated WireGuard keypair" \
            || log_warning "keygen failed — run: wg genkey | tee $wg_key | wg pubkey > $wg_pub"
    elif [[ -s "$wg_key" ]]; then
        [[ -s "$wg_pub" ]] || wg pubkey < "$wg_key" > "$wg_pub" 2>/dev/null || true
        log_info "Reusing existing WireGuard key ($wg_key)"
    fi

    local my_pub my_ip
    my_pub="$(cat "$wg_pub" 2>/dev/null || echo '<no-key>')"
    my_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this-node-public-ip>')"

    echo ""
    echo -e "  ${BOLD}On the MASTER (a separate shell), register this worker:${NC}"
    echo -e "       sudo geodineum node add ${peer_name} ${my_ip}:51820 --pubkey \"${my_pub}\""
    echo -e "  ${DIM}It prints this node's WireGuard lines; paste them below.${NC}"
    echo ""

    if [[ "${YES_MODE:-false}" == "true" ]]; then
        log_info "Non-interactive: after the master's node add, place the lines it printed at ${wg_conf}, then:"
        log_info "  sudo systemctl enable --now wg-quick@wg-geodineum"
        return 0
    fi

    echo -e "  ${BOLD}Then paste that config below${NC} ${DIM}and press Ctrl-D on a blank line${NC}"
    echo -e "  ${DIM}(or just Ctrl-D to skip and finish WireGuard by hand later):${NC}"
    local pasted=""
    pasted="$(cat || true)"
    if [[ -z "${pasted//[[:space:]]/}" ]]; then
        log_info "No config pasted — finish WireGuard before the daemon starts:"
        log_info "  save the lines the master's node add printed to ${wg_conf}, then: systemctl enable --now wg-quick@wg-geodineum"
        return 0
    fi
    printf '%s\n' "$pasted" > "$wg_conf" 2>/dev/null || { log_warning "could not write ${wg_conf}"; return 0; }
    if grep -q 'WORKER_PRIVATE_KEY' "$wg_conf" 2>/dev/null; then
        local priv; priv="$(cat "$wg_key" 2>/dev/null || true)"
        [[ -n "$priv" ]] && sed -i "s|WORKER_PRIVATE_KEY|${priv}|" "$wg_conf" 2>/dev/null || true
    fi
    chmod 600 "$wg_conf" 2>/dev/null || true
    log_info "Saved ${wg_conf} — bringing the tunnel up..."
    systemctl enable --now wg-quick@wg-geodineum 2>/dev/null || true
    if ping -c2 -W2 "$master_ip" >/dev/null 2>&1; then
        log_success "WireGuard tunnel up — master ${master_ip} reachable over the VPN"
    else
        log_warning "Tunnel configured but ${master_ip} not yet reachable — check the master add-peer + the pasted config."
    fi
}

# Captures the master's ValKey password(s) for daemon tiers; phase_config writes them to disk.
wizard_constellation_credentials() {
    case "$DEPLOY_TIER" in
        full|compute|replica) ;;
        *) return 0 ;;
    esac

    echo ""
    echo -e "  ${BOLD}Master ValKey credential${NC}"
    echo -e "  ${DIM}This node's daemon authenticates to the master's ValKey. On the MASTER, run:${NC}"
    echo -e "       sudo cat /etc/geodineum/credentials/valkey_daemon.password"
    echo ""

    if [[ "${YES_MODE:-false}" == "true" ]]; then
        log_info "Non-interactive: place the master's valkey_daemon.password at"
        log_info "  /etc/geodineum/credentials/valkey_daemon.password before the daemon starts."
        return 0
    fi

    local pw=""
    read -r -s -p "  Paste the master's valkey_daemon.password (hidden, Enter to skip): " pw || true
    echo ""
    if [[ -n "$pw" ]]; then
        CONSTELLATION_DAEMON_PW="$pw"
        log_success "Daemon credential captured — written during configuration."
    else
        log_warning "Skipped — place it at /etc/geodineum/credentials/valkey_daemon.password before the daemon starts."
    fi

    if [[ "$DEPLOY_TIER" == "replica" ]]; then
        echo ""
        echo -e "  ${DIM}Replica also needs the master's replication password. On the MASTER, run:${NC}"
        echo -e "       sudo cat /etc/geodineum/credentials/valkey_replica.password"
        local rpw=""
        read -r -s -p "  Paste the master's valkey_replica.password (hidden, Enter to skip): " rpw || true
        echo ""
        if [[ -n "$rpw" ]]; then
            CONSTELLATION_REPLICA_PW="$rpw"
            log_success "Replica credential captured."
        fi
    fi
}

# Applies a `geodineum node add` bundle (file path or base64 line); non-zero if it is not one.
wizard_apply_constellation_bundle() {
    local b64="$1"
    [[ -f "$b64" ]] && b64="$(tr -d '[:space:]' < "$b64")"
    local decoded
    decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
    if [[ "$decoded" != *GEODINEUM-CONSTELLATION-BUNDLE* ]]; then
        log_error "Not a constellation bundle"
        return 1
    fi
    # A joined node serves what its master serves, under the name it was given.
    local _b_name _b_master _b_cs _b_tier
    _b_name="$(printf '%s\n' "$decoded" | sed -n 's/^name=//p' | head -1)"
    _b_master="$(printf '%s\n' "$decoded" | sed -n 's/^master_ip=//p' | head -1)"
    _b_cs="$(printf '%s\n' "$decoded" | sed -n 's/^constellations=//p' | head -1)"
    _b_tier="$(printf '%s\n' "$decoded" | sed -n 's/^tier=//p' | head -1)"
    if [[ -n "$_b_cs" ]]; then
        if [[ "${CONSTELLATION_NAME_SET:-false}" == "true" && ",${_b_cs}," != *",${GNODE_TOPOLOGY_NAMESPACE},"* ]]; then
            log_error "--constellation-name ${GNODE_TOPOLOGY_NAMESPACE} is not served by this master (it serves ${_b_cs})"
            return 2
        fi
        if [[ "${CONSTELLATION_NAME_SET:-false}" == "true" ]]; then
            # The named one becomes this node's primary; the rest follow in the master's order.
            local _rest; _rest="$(tr ',' '\n' <<< "$_b_cs" | grep -vxF "$GNODE_TOPOLOGY_NAMESPACE" | paste -sd, -)"
            GNODE_CONSTELLATIONS="${GNODE_TOPOLOGY_NAMESPACE}${_rest:+,${_rest}}"
        else
            GNODE_CONSTELLATIONS="$_b_cs"
            GNODE_TOPOLOGY_NAMESPACE="${_b_cs%%,*}"
        fi
        log_info "Constellations (from the master): ${GNODE_CONSTELLATIONS}"
    fi
    [[ -n "$_b_name" && -z "${GNODE_NODE_ID:-}" ]] && GNODE_NODE_ID="$_b_name"
    [[ -n "$_b_master" && -z "${MASTER_IP:-}" ]] && MASTER_IP="$_b_master"
    [[ -n "$_b_tier" && -z "${DEPLOY_TIER:-}" ]] && DEPLOY_TIER="$_b_tier"

    local wg_conf="/etc/wireguard/wg-geodineum.conf"
    if ! command -v wg-quick >/dev/null 2>&1; then
        log_info "Installing wireguard-tools for the constellation tunnel"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools >/dev/null 2>&1 \
            || { log_error "Could not install wireguard-tools"; return 1; }
    fi
    install -d -m 700 /etc/wireguard 2>/dev/null || true
    printf '%s\n' "$decoded" \
        | awk '/^---WIREGUARD---/{f=1;next} /^---VALKEY_DAEMON_PASSWORD---/{f=0} f' > "$wg_conf"
    chmod 600 "$wg_conf" 2>/dev/null || true
    CONSTELLATION_DAEMON_PW="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_DAEMON_PASSWORD---/{f=1;next} /^---VALKEY_REPLICA_PASSWORD---/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"
    # The replica section ends at the node-identity block, or at ===END=== when there is none.
    CONSTELLATION_REPLICA_PW="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_REPLICA_PASSWORD---/{f=1;next} /^---VALKEY_NODE_USER---/{f=0} /^===END===/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"

    # Optional per-node ValKey identity; without it the node uses the shared gnode_daemon login.
    CONSTELLATION_NODE_USER="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_NODE_USER---/{f=1;next} /^---VALKEY_NODE_PASSWORD---/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"
    CONSTELLATION_NODE_PW="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_NODE_PASSWORD---/{f=1;next} /^===END===/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"

    if [[ -n "$CONSTELLATION_NODE_USER" ]] && [[ -n "$CONSTELLATION_NODE_PW" ]]; then
        log_success "Bundle applied — WireGuard config + credentials captured (identity: ${CONSTELLATION_NODE_USER})."
    else
        log_success "Bundle applied — WireGuard config + credentials captured."
        log_info "No per-node ValKey identity in this bundle — using the shared gnode_daemon login."
    fi
    systemctl enable --now wg-quick@wg-geodineum 2>/dev/null || true
    local master_ip="${VALKEY_HOST:-10.66.0.1}"
    if ping -c2 -W2 "$master_ip" >/dev/null 2>&1; then
        log_success "WireGuard tunnel up — master ${master_ip} reachable over the VPN"
    else
        log_warning "Tunnel configured but ${master_ip} not yet reachable — check the endpoint you gave to 'expand'."
    fi
    return 0
}

# The name is the hash tag on every topology key, so an existing host keeps its name.
ask_constellation_name() {
    local existing=/etc/geodineum/components/gnode-daemon/daemon.env cur=""
    [[ -r "$existing" ]] && cur="$(sed -n 's/^GNODE_CONSTELLATIONS="\{0,1\}\([^",]*\).*/\1/p' "$existing" | sed -n 1p)"
    if [[ -n "$cur" ]]; then
        GNODE_TOPOLOGY_NAMESPACE="$cur"
        log_info "Constellation name: ${cur} (kept from ${existing})"
        return 0
    fi
    if [[ "${CONSTELLATION_NAME_SET:-false}" != "true" && "$YES_MODE" != "true" ]]; then
        local _ans
        echo -e "  ${DIM}The name tags every topology key ({name}:gnode:…); it cannot change later without a migration.${NC}"
        read -r -p "  Constellation name [geodineum]: " _ans
        GNODE_TOPOLOGY_NAMESPACE="${_ans:-geodineum}"
    fi
    GNODE_TOPOLOGY_NAMESPACE="${GNODE_TOPOLOGY_NAMESPACE:-geodineum}"
    if [[ ! "$GNODE_TOPOLOGY_NAMESPACE" =~ ^[a-z][a-z0-9_]{1,31}$ ]]; then
        log_error "Constellation name '${GNODE_TOPOLOGY_NAMESPACE}' is invalid: lowercase letter first, then a-z, 0-9, _ (2-32 characters)"
        exit 1
    fi
    GNODE_CONSTELLATIONS="$GNODE_TOPOLOGY_NAMESPACE"
    log_info "Constellation name: ${GNODE_TOPOLOGY_NAMESPACE}"
}

# Worker enrollment: the `node add` bundle, else manual WireGuard and credential entry.
wizard_constellation_join() {
    local master_ip="${VALKEY_HOST:-10.66.0.1}"

    # Uninstall keeps /etc/wireguard, so a reinstall may already have a working tunnel.
    if ip link show wg-geodineum >/dev/null 2>&1 && ping -c1 -W2 "$master_ip" >/dev/null 2>&1; then
        log_success "WireGuard already up — master ${master_ip} reachable; skipping WireGuard setup."
        wizard_constellation_credentials
        return 0
    fi

    local me_ip me_name
    me_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this-ip>')"
    me_name="$(hostname -s 2>/dev/null || echo worker)"

    echo ""
    echo -e "  ${BOLD}Constellation enrollment${NC}"
    echo -e "  ${DIM}Easiest — on the MASTER run:${NC}"
    echo -e "       sudo geodineum node add ${me_name} ${me_ip}:51820"
    echo -e "  ${DIM}then give the path of the bundle file it writes (copy it here first).${NC}"
    echo ""

    if [[ "${YES_MODE:-false}" != "true" ]]; then
        local bundle=""
        read -r -p "  Bundle file path, or the bundle line (Enter to set up manually): " bundle || true
        if [[ -n "$bundle" ]]; then
            if wizard_apply_constellation_bundle "$bundle"; then
                return 0
            fi
            log_warning "That wasn't a valid bundle — falling back to manual setup."
        fi
    fi

    wizard_constellation_wireguard_prep
    wizard_constellation_credentials
}

# =============================================================================
# PHASE 2: Profile Selection
# =============================================================================

phase_selection() {
    log_step "Phase 2/10: Setup Wizard"

    if [[ "$YES_MODE" == "true" ]] && [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]]; then
        PROFILE="standard"
        log_info "Profile: standard (--yes default)"
        [[ -z "${MASTER_IP:-}" ]] && ask_constellation_name
        return
    fi

    if [[ -n "$PROFILE" ]] || [[ -n "$COMPONENTS" ]]; then
        [[ -n "$PROFILE" ]] && log_info "Profile: ${PROFILE}"
        [[ -n "$COMPONENTS" ]] && log_info "Components: ${COMPONENTS}"
        [[ -z "${MASTER_IP:-}" ]] && ask_constellation_name
        return
    fi

    # ─── Step 1: Constellation ─────────────────────────────────

    echo ""
    echo -e "  ${BOLD}Step 1: What are you setting up?${NC}"
    echo ""
    echo -e "    ${BOLD}1) New constellation${NC}      Set up a new Geodineum deployment"
    echo -e "       ${DIM}Fresh install — creates all infrastructure from scratch${NC}"
    echo ""
    echo -e "    ${BOLD}2) Join constellation${NC}     Connect to an existing private Geodineum constellation"
    echo -e "       ${DIM}Joins an existing ecosystem — configure connection to the master node${NC}"
    echo ""

    local constellation_choice
    read -p "  Select [1-2, default: 1]: " -n 1 constellation_choice
    echo ""

    case "${constellation_choice:-1}" in
        2)
            echo ""
            echo -e "  ${BOLD}What role will this node serve?${NC}"
            echo ""
            echo -e "    ${BOLD}a) Web${NC}            gCore + services only — no daemon, no local ValKey"
            echo -e "       ${DIM}Lightest footprint. For satellite sites or PHP services${NC}"
            echo -e "       ${DIM}that just need stream access to the constellation.${NC}"
            echo ""
            echo -e "    ${BOLD}b) Replica${NC}        Local ValKey replica + gNode daemon — read-heavy workloads"
            echo -e "       ${DIM}Local reads, VPN writes. Ideal for caching, content serving,${NC}"
            echo -e "       ${DIM}and services that need fast topology queries.${NC}"
            echo ""
            echo -e "    ${BOLD}c) Full node${NC}      gNode daemon + full component stack — no local ValKey"
            echo -e "       ${DIM}Full processing power. Uses master's ValKey over WireGuard VPN.${NC}"
            echo -e "       ${DIM}For distributed topologies and high-availability setups.${NC}"
            echo ""
            echo -e "    ${BOLD}d) Compute${NC}        gNode daemon only — no web server, no PHP, no database"
            echo -e "       ${DIM}Never faces the internet. Reaches the constellation solely over${NC}"
            echo -e "       ${DIM}the WireGuard VPN. For inference, workers, and pipelines.${NC}"
            echo ""

            local tier_choice
            read -p "  Select [a/b/c/d, default: c]: " -n 1 tier_choice
            echo ""

            case "${tier_choice:-c}" in
                a|A) DEPLOY_TIER="web" ;;
                b|B) DEPLOY_TIER="replica" ;;
                d|D) DEPLOY_TIER="compute" ;;
                *)   DEPLOY_TIER="full" ;;
            esac

            log_info "Deployment tier: ${DEPLOY_TIER}"

            echo ""
            echo -e "  ${BOLD}Constellation connection${NC}"
            echo -e "  ${DIM}The master runs 'geodineum node add' for this node and provides${NC}"
            echo -e "  ${DIM}a WireGuard VPN IP. ValKey is only reachable via the VPN.${NC}"
            echo ""
            local master_vpn_ip
            read -p "  Master VPN IP [10.66.0.1]: " master_vpn_ip
            VALKEY_HOST="${master_vpn_ip:-10.66.0.1}"
            VALKEY_PORT="47445"
            echo ""
            log_info "Constellation: ${VALKEY_HOST}:${VALKEY_PORT} (via WireGuard VPN)"

            apply_deploy_tier

            # Unique per node: it is the daemon's consumer name in the shared group.
            local _def_node; _def_node="$(hostname -s 2>/dev/null || echo worker)"
            if [[ "$YES_MODE" == "true" ]]; then
                GNODE_NODE_ID="${GNODE_NODE_ID:-$_def_node}"
            else
                local _node_ans
                read -r -p "  Node ID for this node [${_def_node}]: " _node_ans
                GNODE_NODE_ID="${_node_ans:-$_def_node}"
            fi
            log_info "Node ID: ${GNODE_NODE_ID}"

            wizard_constellation_join
            ;;
        *)
            log_info "Constellation: new (standalone deployment)"
            ask_constellation_name
            ;;
    esac

    # ─── Install root ──────────────────────────────────────────

    echo ""
    echo -e "  ${BOLD}Production install location${NC}"
    echo ""
    while true; do
        local prod_path
        read -p "  Install root [${INSTALL_ROOT}]: " prod_path
        local candidate="${prod_path:-$INSTALL_ROOT}"
        if validate_install_root "$candidate"; then
            INSTALL_ROOT="$candidate"
            break
        fi
        echo ""
        log_warning "Please choose a different install root"
        echo ""
    done
    log_info "Install root: ${INSTALL_ROOT}"

    # ─── Step 2: Component Selection ───────────────────────────

    if [[ -n "$PROFILE" ]]; then
        log_info "Profile: ${PROFILE} (set by deployment tier)"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Step 2: What to install?${NC}"
    echo ""
    echo -e "    ${BOLD}1) Standard${NC}       All Chapter 1 components ${GREEN}<- recommended${NC}"
    echo -e "       ${DIM}ValKey + gNode daemon + gCore + gTemplate + gCube + COMMS + BAK${NC}"
    echo -e "       ${DIM}Everything you need to deploy geometric WordPress sites${NC}"
    echo ""
    echo -e "    ${BOLD}2) Minimal${NC}        Theme + framework only (no daemon)"
    echo -e "       ${DIM}gCore + gTemplate + gNode-Client — lightweight mode${NC}"
    echo ""
    echo -e "    ${BOLD}3) Custom${NC}         Choose individual components"
    echo -e "       ${DIM}Select exactly what you need${NC}"
    echo ""

    local comp_choice
    read -p "  Select [1-3, default: 1]: " -n 1 comp_choice
    echo ""

    case "${comp_choice:-1}" in
        2)
            PROFILE="minimal"
            log_info "Selected: minimal"
            ;;
        3)
            wizard_custom_selection
            ;;
        *)
            PROFILE="standard"
            log_info "Selected: standard (all Chapter 1 components)"
            ;;
    esac

    # ─── Child Theme ───────────────────────────────────────────

    if [[ -z "$SITE_THEME" ]] && [[ "$PROFILE" == "standard" || "$PROFILE" == "minimal" ]]; then
        echo ""
        echo -e "  ${BOLD}Include a child theme?${NC}"
        echo ""
        echo -e "    ${BOLD}1) gcube${NC}       CSS 3D cube (6 faces)"
        echo -e "    ${BOLD}2) none${NC}        Parent theme only (gTemplate)"
        echo ""

        local theme_choice
        read -p "  Select theme [1-2, default: 1]: " -n 1 theme_choice
        echo ""

        case "${theme_choice:-1}" in
            2) ;;
            *) COMPONENTS="${COMPONENTS:+${COMPONENTS},}gcube" ;;
        esac
    fi

    # ─── Notification daemon (optional, even in standard) ──────
    if [[ "$PROFILE" == "standard" ]] && [[ "$COMMS_EXPLICIT" != "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Include the notification daemon (Geodineum-COMMS)?${NC}"
        echo -e "    ${DIM}Email / Telegram / SMS. Decline if this node uses a dedicated${NC}"
        echo -e "    ${DIM}SMTP node or shares notifications from the constellation master.${NC}"
        echo ""
        local comms_choice
        read -p "  Include Geodineum-COMMS? [Y/n]: " -n 1 comms_choice
        echo ""
        case "${comms_choice}" in
            n|N) WITH_COMMS=false; log_info "Geodineum-COMMS will be skipped" ;;
            *)   WITH_COMMS=true ;;
        esac
    fi
}

wizard_custom_selection() {
    echo ""
    echo -e "  ${BOLD}Select components to install:${NC}"
    echo ""

    local -a available=(
        "gnode-daemon|Geometric topology engine + stream processor"
        "gnode-client|PHP client library for gNode"
        "gcore|Manager-of-managers PHP framework"
        "gtemplate-wp|WordPress parent theme"
        "gcube|WordPress child theme (3D cube)"
        "geodineum-comms|Notification daemon (email, Telegram)"
        "geodineum-bak|Backup and log rotation"
    )

    local -a selected=()
    local idx=1

    for entry in "${available[@]}"; do
        local name="${entry%%|*}"
        local desc="${entry#*|}"
        printf "    ${BOLD}%d)${NC} %-20s ${DIM}%s${NC}\n" "$idx" "$name" "$desc"
        idx=$((idx + 1))
    done

    echo ""
    echo -e "  ${DIM}Enter numbers separated by spaces (e.g., 1 2 3 4 5):${NC}"
    local choices
    read -p "  Components: " choices

    for c in $choices; do
        local i=$((c - 1))
        if [[ $i -ge 0 ]] && [[ $i -lt ${#available[@]} ]]; then
            local name="${available[$i]%%|*}"
            selected+=("$name")
        fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        log_warning "No components selected — defaulting to standard"
        PROFILE="standard"
        return
    fi

    COMPONENTS=$(IFS=','; echo "${selected[*]}")
    log_info "Selected: ${COMPONENTS}"
}

# =============================================================================
# PHASE 3: Prerequisites
# =============================================================================

phase_prerequisites() {
    local resolved=($@)

    log_step "Phase 3/10: Prerequisites"

    local HAS_APT=false
    if command -v apt-get &>/dev/null; then
        HAS_APT=true
    fi

    if [[ "$EUID" -ne 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_warning "Not running as root (dry-run mode — continuing)"
        else
            log_error "This installer must be run as root (sudo)"
            exit 1
        fi
    else
        log_success "Running as root"
    fi

    apt_install() {
        local description="$1"; shift
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "apt-get install -y $*"
            return 0
        elif [[ "$HAS_APT" != "true" ]]; then
            log_error "${description} required but apt-get is not available"
            log_info "Install manually: $*"
            return 1
        fi
        apt-get install -y -qq "$@" || {
            log_error "Failed to install: $*"
            return 1
        }
        return 0
    }

    local APT_UPDATED=false
    apt_update() {
        if [[ "$APT_UPDATED" != "true" ]] && [[ "$HAS_APT" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
            log_info "Updating package lists..."
            apt-get update -qq
            APT_UPDATED=true
        fi
    }

    # ─── Core tools (always needed) ──────────────────────────

    if [[ "$HAS_GIT" != "true" ]]; then
        log_info "Installing git..."
        apt_update
        apt_install "git" git || exit 1
        log_success "git installed"
    fi

    if ! command -v jq &>/dev/null; then
        log_info "Installing jq..."
        apt_update
        apt_install "jq" jq || log_warning "jq install failed — config seeding will need manual jq install"
    fi

    # yq reads the CLI sections of each component's geodeploy.yaml.
    if ! command -v yq &>/dev/null; then
        log_info "Installing yq..."
        local yq_arch="amd64"
        case "$(uname -m)" in
            aarch64|arm64) yq_arch="arm64" ;;
            x86_64)        yq_arch="amd64" ;;
        esac
        local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"
        if curl -fsSL "$yq_url" -o /usr/local/bin/yq 2>/dev/null && chmod +x /usr/local/bin/yq; then
            log_success "yq installed ($(yq --version 2>/dev/null | head -1))"
        else
            log_warning "yq install failed — CLI component commands will be unavailable"
            rm -f /usr/local/bin/yq 2>/dev/null || true
        fi
    fi

    # `geodineum validate` needs Draft 2020-12 (jsonschema >= 4); some distros package 3.x.
    _need_jsonschema_v4=0
    if ! python3 -c 'import jsonschema' &>/dev/null; then
        log_info "Installing python3-jsonschema (apt)..."
        apt_install "python3-jsonschema" python3-jsonschema || \
            log_warning "python3-jsonschema install failed — \`geodineum validate\` will be unavailable until installed"
        _need_jsonschema_v4=1
    fi
    if python3 -c 'import jsonschema' &>/dev/null; then
        if ! python3 -c 'import jsonschema; getattr(jsonschema, "Draft202012Validator")' &>/dev/null; then
            _need_jsonschema_v4=1
        fi
    fi
    if [[ $_need_jsonschema_v4 -eq 1 ]]; then
        log_info "Upgrading jsonschema to 4.x (Draft 2020-12 support) via pip..."
        if ! command -v pip3 &>/dev/null; then
            apt_install "python3-pip" python3-pip 2>/dev/null || true
        fi
        if command -v pip3 &>/dev/null; then
            # PEP 668 hosts need --break-system-packages; older pip rejects it, hence the retry.
            pip3 install --break-system-packages --quiet 'jsonschema>=4.0' 2>/dev/null \
                || pip3 install --quiet 'jsonschema>=4.0' 2>/dev/null \
                || log_warning "jsonschema upgrade failed — \`geodineum validate\` will report 'no Draft202012Validator'"
            if python3 -c 'import jsonschema; getattr(jsonschema, "Draft202012Validator")' &>/dev/null; then
                log_success "jsonschema >= 4.x available"
            fi
        else
            log_warning "pip3 unavailable — cannot upgrade jsonschema; \`geodineum validate\` will fail"
        fi
    fi
    unset _need_jsonschema_v4

    # redis-py >= 4.3: gNode's capabilities are ValKey FUNCTIONs and older clients lack fcall().
    _need_redis_43=0
    if ! python3 -c 'import redis' &>/dev/null; then
        log_info "Installing python3-redis (apt)..."
        apt_install "python3-redis" python3-redis || \
            log_warning "python3-redis install failed — pipeline workers and receipt verification will be unavailable until installed"
        _need_redis_43=1
    fi
    if python3 -c 'import redis' &>/dev/null; then
        python3 -c 'import redis, sys; sys.exit(0 if hasattr(redis.Redis, "fcall") else 1)' &>/dev/null \
            || _need_redis_43=1
    else
        _need_redis_43=1
    fi
    if [[ $_need_redis_43 -eq 1 ]]; then
        log_info "Ensuring redis-py >= 4.3 (ValKey FUNCTION/fcall support) via pip..."
        if ! command -v pip3 &>/dev/null; then
            apt_install "python3-pip" python3-pip 2>/dev/null || true
        fi
        if command -v pip3 &>/dev/null; then
            pip3 install --break-system-packages --quiet 'redis>=4.3' 2>/dev/null \
                || pip3 install --quiet 'redis>=4.3' 2>/dev/null \
                || log_warning "redis-py upgrade failed — FCALL-based tooling will report 'no fcall()'"
            if python3 -c 'import redis, sys; sys.exit(0 if hasattr(redis.Redis, "fcall") else 1)' &>/dev/null; then
                log_success "redis-py >= 4.3 available (fcall supported)"
            fi
        else
            log_warning "pip3 unavailable — cannot ensure redis-py >= 4.3"
        fi
    fi
    unset _need_redis_43

    if ! python3 -c 'import requests' &>/dev/null; then
        log_info "Installing python3-requests (apt)..."
        apt_install "python3-requests" python3-requests || \
            log_warning "python3-requests install failed — generated pipeline workers will not start"
    fi

    if ! command -v curl &>/dev/null; then
        log_info "Installing curl..."
        apt_update
        apt_install "curl" curl || exit 1
        log_success "curl installed"
    fi

    # Composer needs unzip.
    if ! command -v unzip &>/dev/null; then
        apt_update
        apt_install "unzip" unzip 2>/dev/null || true
    fi

    # ─── Rust/cargo (for gnode-daemon) ───────────────────────

    if needs_daemon "${resolved[@]}" && [[ "$HAS_CARGO" != "true" ]] && [[ "$SKIP_BUILD" != "true" ]]; then
        log_info "Rust/cargo needed for gNode daemon"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "Install Rust via rustup"
        elif confirm "Install Rust toolchain via rustup?"; then
            local real_user="${SUDO_USER:-}"
            if [[ -z "$real_user" ]] || [[ "$real_user" == "root" ]]; then
                real_user="root"
            fi
            local real_home
            real_home=$(getent passwd "$real_user" | cut -d: -f6)
            if [[ -z "$real_home" ]]; then
                log_error "Cannot determine home directory for user '${real_user}'"
                log_info "Install Rust manually: https://rustup.rs"
            else
                sudo -u "$real_user" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y' || {
                    log_error "Rust installation failed"
                    log_info "Install manually: https://rustup.rs"
                    exit 1
                }
                export PATH="${real_home}/.cargo/bin:${PATH}"
                if command -v cargo &>/dev/null; then
                    HAS_CARGO=true
                    log_success "Rust installed: $(cargo --version 2>/dev/null | awk '{print $2}')"
                else
                    log_warning "Rust installed but cargo not in PATH — you may need to re-login"
                fi
            fi
        else
            log_warning "Skipping Rust — daemon won't build. Use --skip-build to use existing binary."
        fi
    fi

    # System libraries the Rust crates link against (COMMS needs libssl-dev for openssl-sys).
    if needs_daemon "${resolved[@]}" && [[ "$SKIP_BUILD" != "true" ]] && [[ "$HAS_APT" == "true" ]]; then
        log_info "Installing Rust build dependencies (build-essential, pkg-config, libssl-dev, libsystemd-dev)..."
        apt_update
        apt_install "Rust build deps" \
            build-essential pkg-config libssl-dev libsystemd-dev \
            || log_warning "Rust build deps install had issues — Cargo may fail downstream"
    fi

    # ─── PHP + extensions ────────────────────────────────────

    if needs_php "${resolved[@]}" && [[ "$HAS_PHP" != "true" ]]; then
        log_info "PHP needed for gCore/themes"
        apt_update
        if confirm "Install PHP 8.x and required extensions?"; then
            # gTemplate's config loader needs php-yaml.
            apt_install "PHP" php php-cli php-fpm php-redis php-mbstring php-xml \
                php-curl php-zip php-intl php-igbinary php-yaml php-apcu || exit 1
            # Bundled into PHP 8 on some distros, so failure is fine.
            apt_install "php-json" php-json 2>/dev/null || true
            HAS_PHP=true
            log_success "PHP installed with extensions"
        fi
    fi

    if needs_wordpress "${resolved[@]}" && [[ "$HAS_PHP" == "true" ]]; then
        if ! php -m 2>/dev/null | grep -qi "^mysqli$"; then
            log_info "Installing php-mysql for WordPress..."
            apt_update
            apt_install "php-mysql" php-mysql || log_warning "php-mysql install failed"
        fi
    fi

    if needs_php "${resolved[@]}" && [[ "$HAS_COMPOSER" != "true" ]]; then
        log_info "Composer needed for PHP dependencies"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "Install Composer globally"
        elif confirm "Install Composer?"; then
            local expected_sig
            expected_sig=$(curl -sS https://composer.github.io/installer.sig 2>/dev/null)
            php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
            local actual_sig
            actual_sig=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
            if [[ "$expected_sig" == "$actual_sig" ]]; then
                php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
                rm -f /tmp/composer-setup.php
                HAS_COMPOSER=true
                log_success "Composer installed"
            else
                log_error "Composer installer signature mismatch — skipping"
                rm -f /tmp/composer-setup.php
            fi
        fi
    fi

    # ─── Apache2 (for WordPress sites) ───────────────────────

    if needs_wordpress "${resolved[@]}" && [[ "$HAS_APACHE" != "true" ]]; then
        log_info "Apache2 needed for WordPress"
        apt_update
        if confirm "Install Apache2 web server?"; then
            apt_install "Apache2" apache2 || exit 1

            if [[ "$DRY_RUN" != "true" ]]; then
                a2enmod rewrite headers expires ssl proxy_fcgi setenvif http2 2>/dev/null || true
                # Stock FPM conf until ensure_php_fpm swaps in the pool; mod_php would pin prefork and disable HTTP/2.
                local fpm_conf
                fpm_conf=$(find /etc/apache2/conf-available -name "php*-fpm.conf" 2>/dev/null | head -1)
                if [[ -n "$fpm_conf" ]]; then
                    a2enconf "$(basename "$fpm_conf" .conf)" 2>/dev/null || true
                fi
                systemctl enable apache2 2>/dev/null || true
                systemctl restart apache2 2>/dev/null || true
            fi
            HAS_APACHE=true
            log_success "Apache2 installed and configured"
        fi
    fi

    # ─── MySQL/MariaDB (for WordPress database) ──────────────

    if needs_wordpress "${resolved[@]}" && [[ "$HAS_MYSQL" != "true" ]]; then
        log_info "MySQL/MariaDB needed for WordPress"
        apt_update
        if confirm "Install MariaDB server?"; then
            apt_install "MariaDB" mariadb-server mariadb-client || exit 1
            if [[ "$DRY_RUN" != "true" ]]; then
                systemctl enable mariadb 2>/dev/null || systemctl enable mysql 2>/dev/null || true
                systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
            fi
            HAS_MYSQL=true
            log_success "MariaDB installed and running"
        fi
    fi

    # ─── Certbot (for SSL certificates) ──────────────────────

    if needs_wordpress "${resolved[@]}"; then
        if ! command -v certbot &>/dev/null; then
            log_info "Installing certbot for SSL certificates..."
            apt_update
            apt_install "certbot" certbot python3-certbot-apache 2>/dev/null || \
                log_warning "certbot install failed — SSL setup will need to be done manually"
        fi
    fi

    # ─── WP-CLI (for WordPress management) ───────────────────

    if needs_wordpress "${resolved[@]}"; then
        local wp_cli_found=false
        for wp_candidate in /usr/local/bin/wp /usr/bin/wp "${SUDO_USER:+/home/${SUDO_USER}/bin/wp}"; do
            if [[ -x "$wp_candidate" ]]; then
                wp_cli_found=true
                log_success "wp-cli found at ${wp_candidate}"
                break
            fi
        done

        if [[ "$wp_cli_found" != "true" ]]; then
            log_info "Installing WP-CLI..."
            if [[ "$DRY_RUN" == "true" ]]; then
                log_dry "Download wp-cli.phar to /usr/local/bin/wp"
            else
                # 0755: the site installer runs `sudo -u www-data wp`; the phar holds no secrets.
                curl -sS -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
                    chmod 0755 /tmp/wp-cli.phar && \
                    mv /tmp/wp-cli.phar /usr/local/bin/wp && \
                    chown root:root /usr/local/bin/wp && \
                    log_success "WP-CLI installed" || \
                    log_warning "WP-CLI install failed — WordPress management will be manual"
            fi
        fi
    fi

    # ─── WireGuard + fail2ban (constellation networking) ────

    if ! command -v wg &>/dev/null; then
        log_info "Installing wireguard-tools (for constellation VPN)..."
        apt_update
        apt_install "wireguard-tools" wireguard-tools 2>/dev/null || \
            log_warning "wireguard-tools install failed — the mesh setup (first geodineum node add) installs it on demand"
    else
        log_success "wireguard-tools already installed"
    fi

    if ! command -v fail2ban-client &>/dev/null; then
        log_info "Installing fail2ban (defense-in-depth for ValKey)..."
        apt_update
        apt_install "fail2ban" fail2ban 2>/dev/null || \
            log_warning "fail2ban install failed — constellation will run without brute-force protection"
    else
        log_success "fail2ban already installed"
    fi

    # ─── Install root directory ──────────────────────────────

    if [[ ! -d "$INSTALL_ROOT" ]]; then
        log_info "Creating ${INSTALL_ROOT}"
        if [[ "$DRY_RUN" != "true" ]]; then
            track_path_if_new "$INSTALL_ROOT"
            mkdir -p "$INSTALL_ROOT"
        fi
    fi
    # The deploy user clones into the install root, so it must own it.
    if [[ "$DRY_RUN" != "true" ]] && [[ -d "$INSTALL_ROOT" ]]; then
        local _owner="${DEPLOY_USER:-${SUDO_USER:-root}}"
        local _group="geodineum"
        if ! /usr/bin/getent group "$_group" >/dev/null 2>&1; then
            _group="$_owner"
        fi
        chown "${_owner}:${_group}" "$INSTALL_ROOT"
        chmod 0775 "$INSTALL_ROOT"
    fi
    log_success "Install root: ${INSTALL_ROOT}"
}

# =============================================================================
# PHASE 4: ValKey Setup
# =============================================================================

# Keeps valkey-gnode.service the only ValKey unit: other units are removed from /etc or masked.
purge_legacy_valkey_units() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "purge legacy valkey units (valkey.service, valkey-server.service)"
        return 0
    fi

    local _purged=0
    local _legacy
    for _legacy in valkey valkey-server; do
        systemctl list-unit-files "${_legacy}.service" 2>/dev/null | grep -q "${_legacy}.service" || continue

        systemctl stop    "${_legacy}.service" 2>/dev/null || true
        systemctl disable "${_legacy}.service" 2>/dev/null || true

        # The apt-owned copy in /lib is masked, not deleted, so apt can still remove it.
        if [[ -f "/etc/systemd/system/${_legacy}.service" ]]; then
            rm -f "/etc/systemd/system/${_legacy}.service"
            log_detail "Removed legacy unit /etc/systemd/system/${_legacy}.service"
            _purged=$((_purged + 1))
        elif [[ -f "/lib/systemd/system/${_legacy}.service" ]]; then
            systemctl mask "${_legacy}.service" 2>/dev/null || true
            log_detail "Masked apt-upstream unit ${_legacy}.service"
            _purged=$((_purged + 1))
        fi
    done

    if [[ $_purged -gt 0 ]]; then
        systemctl daemon-reload
        log_success "Purged ${_purged} legacy ValKey systemd unit(s) — valkey-gnode.service is canonical"
    fi
    return 0
}

# Writes valkey-gnode.service for the installed binary unless the unit already exists.
ensure_canonical_valkey_unit() {
    local unit_path="/etc/systemd/system/valkey-gnode.service"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "write ${unit_path} (canonical gNode-flavored ValKey unit)"
        return 0
    fi

    if [[ -f "$unit_path" ]] && grep -q "^ExecStart=" "$unit_path"; then
        return 0  # already canonical
    fi

    local valkey_bin="" valkey_cli_bin=""
    local _cand
    for _cand in /usr/local/bin/valkey-server /usr/bin/valkey-server; do
        if [[ -x "$_cand" ]]; then
            valkey_bin="$_cand"
            valkey_cli_bin="${_cand%-server}-cli"
            break
        fi
    done
    if [[ -z "$valkey_bin" ]]; then
        log_error "ensure_canonical_valkey_unit: no valkey-server binary found"
        return 1
    fi

    cat > "$unit_path" <<UNIT_EOF
[Unit]
Description=Valkey In-Memory Data Store (Geodineum / gNode)
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
ExecStart=${valkey_bin} /etc/valkey/valkey.conf
ExecStop=${valkey_cli_bin} -p 47445 shutdown nosave
Restart=on-failure
RestartSec=2s
User=valkey
Group=valkey
UMask=0027
RuntimeDirectory=valkey
RuntimeDirectoryMode=0755
LimitNOFILE=65536

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/valkey /var/log/valkey

[Install]
WantedBy=multi-user.target
UNIT_EOF
    systemctl daemon-reload
    log_detail "Wrote canonical unit ${unit_path} (ExecStart=${valkey_bin})"
    return 0
}

# valkey-cli without a local server: nodes using a remote ValKey still shell out to it.
ensure_valkey_cli() {
    /usr/bin/command -v valkey-cli >/dev/null 2>&1 && return 0
    log_info "Installing valkey-cli (client only — server stays remote)"
    if apt-get install -y -qq valkey-tools >/dev/null 2>&1 \
        && /usr/bin/command -v valkey-cli >/dev/null 2>&1; then
        ln -sf "$(command -v valkey-cli)" /usr/local/bin/redis-cli 2>/dev/null || true
        log_success "valkey-cli installed via apt (valkey-tools)"
        return 0
    fi
    local valkey_ver="${GEODINEUM_VALKEY_VERSION:-8.0.2}"
    apt-get install -y -qq build-essential curl tar >/dev/null 2>&1 || true
    local tmp
    tmp=$(mktemp -d -t valkey-cli-build.XXXXXX)
    if /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 \
            "https://github.com/valkey-io/valkey/archive/refs/tags/${valkey_ver}.tar.gz" \
            -o "${tmp}/valkey.tar.gz" \
        && (cd "$tmp" && tar xzf valkey.tar.gz \
            && cd "valkey-${valkey_ver}" \
            && make -C src valkey-cli BUILD_TLS=no -j"$(nproc)" >/dev/null 2>&1 \
            && install -m 0755 src/valkey-cli /usr/local/bin/valkey-cli \
            && ln -sf /usr/local/bin/valkey-cli /usr/local/bin/redis-cli); then
        rm -rf "$tmp"
        log_success "valkey-cli ${valkey_ver} built and installed (client only)"
        return 0
    fi
    rm -rf "$tmp"
    log_warning "valkey-cli install failed — bootstrap-loader + onboarding need it; install valkey-tools manually"
    return 1
}

# For distros without a valkey-server package; version via GEODINEUM_VALKEY_VERSION.
install_valkey_from_source() {
    local valkey_ver="${GEODINEUM_VALKEY_VERSION:-8.0.2}"
    log_info "Installing build dependencies (build-essential, pkg-config, libsystemd-dev)..."
    apt-get install -y -qq build-essential pkg-config libsystemd-dev curl tar 2>/dev/null || {
        log_error "Failed to install build dependencies for Valkey"
        return 1
    }

    local tmp
    tmp=$(mktemp -d -t valkey-build.XXXXXX)
    local tarball_url="https://github.com/valkey-io/valkey/archive/refs/tags/${valkey_ver}.tar.gz"

    log_info "Downloading Valkey ${valkey_ver} source from ${tarball_url}..."
    if ! /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 \
            "$tarball_url" -o "${tmp}/valkey.tar.gz"; then
        log_error "Failed to download Valkey source from GitHub"
        rm -rf "$tmp"
        return 1
    fi

    (
        cd "$tmp"
        tar xzf valkey.tar.gz
        cd "valkey-${valkey_ver}"
        log_info "Compiling Valkey ${valkey_ver} (this takes ~30-60 seconds)..."
        # USE_SYSTEMD=yes lets the unit use Type=notify.
        if ! make USE_SYSTEMD=yes BUILD_TLS=no -j"$(nproc)" >/dev/null 2>&1; then
            return 1
        fi

        install -m 0755 src/valkey-server /usr/local/bin/valkey-server
        install -m 0755 src/valkey-cli    /usr/local/bin/valkey-cli
        ln -sf /usr/local/bin/valkey-cli /usr/local/bin/redis-cli

        # The group can outlive an uninstall, so the user is bound to it explicitly.
        if ! getent group valkey >/dev/null 2>&1; then
            groupadd --system valkey
        fi
        if ! getent passwd valkey >/dev/null 2>&1; then
            useradd --system --gid valkey --no-create-home \
                --shell /usr/sbin/nologin valkey
        fi

        install -d -m 0755 /etc/valkey
        install -d -m 0750 -o valkey -g valkey /var/lib/valkey
        install -d -m 0755 -o valkey -g valkey /var/log/valkey

        cat > /etc/valkey/valkey.conf <<'VALKEY_CONF_EOF'
# Geodineum-managed Valkey config (source build).
# Port 47445 = the canonical Geodineum port (see CH1_DASHBOARD_PRIMER).
port 47445
bind 127.0.0.1 ::1
protected-mode yes
dir /var/lib/valkey
logfile /var/log/valkey/valkey-server.log
supervised systemd
daemonize no
appendonly yes
appendfsync everysec
maxmemory-policy allkeys-lru
VALKEY_CONF_EOF
        chown root:valkey /etc/valkey/valkey.conf
        chmod 0640 /etc/valkey/valkey.conf

        cat > /etc/systemd/system/valkey-gnode.service <<'VALKEY_UNIT_EOF'
[Unit]
Description=Valkey In-Memory Data Store (Geodineum / gNode)
After=network.target
# Fail-fast cascade limit: if the service fails 3 times within 60s,
# systemd stops retrying. Prevents the "100 instances in 45 seconds"
# spiral that bit a worker-host migration when port 47445 was transiently
# held by a stopping legacy unit.
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
ExecStop=/usr/local/bin/valkey-cli -p 47445 shutdown nosave
Restart=on-failure
RestartSec=2s
User=valkey
Group=valkey
UMask=0027
RuntimeDirectory=valkey
RuntimeDirectoryMode=0755
LimitNOFILE=65536

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/valkey /var/log/valkey

[Install]
WantedBy=multi-user.target
VALKEY_UNIT_EOF
        systemctl daemon-reload
        return 0
    )
    local rc=$?

    rm -rf "$tmp"
    return "$rc"
}

# Wrappers over lib/component-primitives.sh.
clear_orphaned_valkey_statoverrides() {
    clear_orphaned_statoverrides valkey redis
}

ensure_valkey_system_user() {
    ensure_system_user valkey /var/lib/valkey "Valkey Server"
}

ensure_valkey_package_configured() {
    ensure_package_configured valkey-server /etc/valkey /etc/valkey/valkey.conf
}

# `apt purge` removes these; /run/valkey comes from RuntimeDirectory= at each start.
ensure_valkey_data_dirs() {
    ensure_data_dirs valkey valkey 0750 /var/lib/valkey /var/log/valkey
}

# ACL SAVE needs an aclfile to persist users; call after the admin password, before the restart.
ensure_valkey_aclfile_configured() {
    local conf_file="/etc/valkey/valkey.conf"
    # ProtectSystem=strict makes /etc read-only to the daemon; /var/lib/valkey is writable.
    local acl_file="/var/lib/valkey/users.acl"
    local admin_pwfile="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"

    if [[ ! -f "$conf_file" ]]; then
        return 0
    fi

    # In aclfile mode users.acl, not requirepass, governs the default user; no comment lines allowed.
    local admin_password=""
    if [[ -s "$admin_pwfile" ]]; then
        admin_password="$(cat "$admin_pwfile")"
    fi

    if [[ -z "$admin_password" ]]; then
        log_warning "Admin password not yet present at ${admin_pwfile} — skipping aclfile setup"
        log_info "Call ensure_valkey_admin_password_set BEFORE ensure_valkey_aclfile_configured"
        return 0
    fi

    umask 077
    local tmp
    tmp=$(/usr/bin/mktemp)
    printf 'user default on >%s ~* &* +@all\n' "$admin_password" > "$tmp"
    /usr/bin/install -m 0640 -o valkey -g valkey "$tmp" "$acl_file"
    /usr/bin/rm -f "$tmp"
    log_detail "Wrote ${acl_file} with default user (admin password preserved)"

    if /usr/bin/grep -qE '^[[:space:]]*aclfile[[:space:]]' "$conf_file"; then
        /usr/bin/sed -i "s|^[[:space:]]*aclfile[[:space:]].*|aclfile ${acl_file}|" "$conf_file"
        log_detail "ValKey aclfile updated in ${conf_file}"
    else
        printf '\naclfile %s\n' "$acl_file" >> "$conf_file"
        log_detail "ValKey aclfile appended to ${conf_file}"
    fi


    return 0
}

# Generates or reuses the ValKey admin password and sets requirepass to it.
ensure_valkey_admin_password_set() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local pwfile="${cred_dir}/valkey.password"
    local conf_file="/etc/valkey/valkey.conf"

    if [[ ! -f "$conf_file" ]]; then
        log_warning "No ${conf_file} — skipping admin password setup"
        return 0
    fi

    # 0751 on every run: www-data traverses to its own client password; per-file modes hide the rest.
    if getent group geodineum-creds >/dev/null 2>&1; then
        install -d -m 0751 -o root -g geodineum-creds "$cred_dir"
    else
        install -d -m 0751 "$cred_dir"
    fi

    local password
    if [[ -s "$pwfile" ]]; then
        password="$(cat "$pwfile")"
        log_detail "Re-using existing ValKey admin password (${pwfile})"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$pwfile"
        chmod 0640 "$pwfile" 2>/dev/null || true
        chown "root:geodineum-creds" "$pwfile" 2>/dev/null || true
        log_success "Generated ValKey admin password at ${pwfile}"
    fi

    if grep -qE '^[[:space:]]*requirepass[[:space:]]' "$conf_file"; then
        sed -i "s|^[[:space:]]*requirepass[[:space:]].*|requirepass ${password}|" "$conf_file"
        log_detail "ValKey requirepass updated in ${conf_file}"
    else
        printf '\n# Admin password (Geodineum Phase 4)\nrequirepass %s\n' \
            "$password" >> "$conf_file"
        log_detail "ValKey requirepass appended to ${conf_file}"
    fi

    return 0
}

verify_valkey_admin_auth() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local pwfile="${cred_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ ! -r "$pwfile" ]]; then
        log_warning "ValKey admin password file unreadable at ${pwfile}"
        return 1
    fi

    local i
    for i in 1 2 3 4 5; do
        if REDISCLI_AUTH="$(cat "$pwfile")" valkey-cli -p "$valkey_port" PING 2>/dev/null \
                | grep -q '^PONG$'; then
            log_success "ValKey admin auth verified (PING → PONG on port ${valkey_port})"
            return 0
        fi
        sleep 1
    done

    log_warning "ValKey admin auth verification failed (PING did not return PONG within 5s)"
    log_info "Inspect: REDISCLI_AUTH=\"\$(sudo cat ${pwfile})\" valkey-cli -p ${valkey_port} PING"
    log_info "Inspect: sudo journalctl -u valkey-server --no-pager -n 50"
    return 1
}

phase_valkey() {
    local resolved=($@)

    local needs_valkey=false
    for comp in "${resolved[@]}"; do
        case "$comp" in
            gnode-daemon|gnode-client) needs_valkey=true ;;
        esac
    done

    if [[ "$needs_valkey" != "true" ]]; then
        log_step "Phase 4/10: ValKey Setup (skipped — not needed for this profile)"
        return
    fi

    if [[ "$SKIP_LOCAL_VALKEY" == "true" ]]; then
        log_step "Phase 4/10: ValKey Setup (remote ValKey via VPN — client tools only)"
        log_info "This node connects to the master's ValKey at ${VALKEY_HOST}:${VALKEY_PORT}"
        log_info "Ensure WireGuard is configured: geodineum constellation --help"
        [[ "$DRY_RUN" == "true" ]] || ensure_valkey_cli || true
        return
    fi

    log_step "Phase 4/10: ValKey Setup"

    # A running ValKey still has to meet the auth contract: requirepass, admin password, authenticated PING.
    if [[ "$VALKEY_RUNNING" == "true" ]]; then
        log_info "ValKey already running — verifying Geodineum auth contract"
        ensure_valkey_data_dirs
        ensure_valkey_admin_password_set
        ensure_valkey_aclfile_configured

        # Without admin auth there is no CONFIG SET, so a restart applies requirepass.
        if [[ -f /etc/valkey/valkey.conf ]]; then
            systemctl restart valkey-gnode 2>/dev/null || true
        fi

        if verify_valkey_admin_auth; then
            log_success "ValKey running and authenticated"
            # users.acl was rewritten with the default user only, so the service users are provisioned again.
            if [[ "$VALKEY_REPLICA" != "true" ]]; then
                provision_daemon_acl
                provision_comms_acl
                provision_dashboard_acl
                provision_replica_acl
            fi
            return 0
        fi

        log_warning "ValKey is running but Geodineum auth not yet satisfied"
        log_info "Falling through to full Phase 4 setup (port + ACLs + restart)"
        VALKEY_RUNNING=false
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Detect or install ValKey"
        return
    fi

    local smart_setup=""
    for candidate in \
        "${INSTALL_ROOT}/gNode/scripts/setup-valkey-smart.sh" \
        "${GNODE_SCRIPTS}/setup-valkey-smart.sh"; do
        if [[ -x "$candidate" ]]; then
            smart_setup="$candidate"
            break
        fi
    done

    if [[ -n "$smart_setup" ]]; then
        log_info "Delegating to ValKey smart setup..."
        log_detail "${smart_setup}"
        "$smart_setup" || {
            log_warning "Smart setup had issues — see output above"
        }
        detect_valkey
        return
    fi

    echo ""
    echo "  ${BOLD}ValKey installation method:${NC}"
    echo ""
    echo -e "    ${BOLD}1) native${NC}     Install valkey-server via apt (recommended)"
    echo -e "    ${BOLD}2) docker${NC}     Run ValKey in Docker container"
    echo -e "    ${BOLD}3) skip${NC}       I'll set up ValKey myself"
    echo ""

    local valkey_choice
    if [[ "$YES_MODE" == "true" ]]; then
        valkey_choice="1"
    else
        read -p "  Select [1-3, default: 1]: " -n 1 valkey_choice || true
        echo ""
    fi

    if [[ ! "${valkey_choice:-1}" =~ ^[123]$ ]]; then
        log_warning "Invalid choice '${valkey_choice}' — defaulting to (1) native"
        valkey_choice="1"
    fi

    case "${valkey_choice:-1}" in
        1)
            log_info "Installing Valkey..."

            purge_legacy_valkey_units

            # ── dpkg pre-flight ────────────────────────────────────────────
            # Repairs state an earlier uninstall can leave, which would fail every later apt run; order matters.
            clear_orphaned_valkey_statoverrides
            ensure_valkey_system_user
            if ! ensure_valkey_package_configured; then
                log_error "Could not unblock valkey-server install state"
                log_info "Manual recovery (in order):"
                log_info "  sudo apt-get purge -y valkey-server"
                log_info "  sudo rm -rf /etc/valkey /var/lib/valkey /var/log/valkey"
                log_info "  sudo apt-get install -y valkey-server"
                log_info "Then re-run install.sh."
                return 1
            fi

            # apt valkey-server, then apt valkey, then a source build; an installed redis-server is replaced.
            if dpkg -l redis-server 2>/dev/null | grep -q "^ii"; then
                log_info "redis-server detected — switching to Valkey (per operator preference)"
                systemctl stop redis-server 2>/dev/null || true
                systemctl disable redis-server 2>/dev/null || true
                apt-get purge -y -qq redis-server redis-tools 2>/dev/null || true
                rm -f /usr/local/bin/redis-cli  # only if it was a symlink we made
            fi

            local valkey_pkg=""
            if apt-get install -y -qq valkey-server 2>/dev/null; then
                valkey_pkg="valkey-server"
                log_success "valkey-server installed via apt"
            elif apt-get install -y -qq valkey 2>/dev/null; then
                valkey_pkg="valkey"
                log_success "valkey installed via apt"
            else
                log_info "Valkey not in apt — building from source..."
                if install_valkey_from_source; then
                    valkey_pkg="valkey-source"
                    log_success "Valkey built from source"
                else
                    log_warning "Valkey source build failed"
                    log_info "Fallbacks:"
                    log_info "  Docker:  docker run -d -p 47445:6379 valkey/valkey:latest"
                    log_info "  Manual:  https://valkey.io/topics/installation/"
                    return
                fi
            fi
            export VALKEY_PKG="$valkey_pkg"

            # After an earlier purge, a plain reinstall does not restore the conffile.
            if [[ "$valkey_pkg" =~ ^valkey(-server)?$ ]] \
                    && [[ ! -f /etc/valkey/valkey.conf ]] \
                    && dpkg -L "$valkey_pkg" 2>/dev/null | grep -qx /etc/valkey/valkey.conf; then
                log_warning "/etc/valkey/valkey.conf missing despite installed ${valkey_pkg} — repairing"
                if apt-get install --reinstall -y -qq \
                        -o Dpkg::Options::="--force-confmiss" "$valkey_pkg" >/dev/null 2>&1 \
                        && [[ -f /etc/valkey/valkey.conf ]]; then
                    log_success "Restored /etc/valkey/valkey.conf via dpkg --force-confmiss"
                else
                    log_error "Could not restore /etc/valkey/valkey.conf"
                    log_info "Manual fix: sudo apt-get purge -y ${valkey_pkg} && sudo apt-get install -y ${valkey_pkg}"
                    return 1
                fi
            fi

            # The source build writes its own conf and unit; only the apt paths are adjusted here.
            local conf_file="/etc/valkey/valkey.conf"
            local svc_name="valkey-gnode"

            if [[ "$valkey_pkg" != "valkey-source" ]] && [[ -f "$conf_file" ]]; then
                sed -i "s/^port .*/port 47445/" "$conf_file"
                log_detail "Configured ${svc_name} port 47445 (in ${conf_file})"

                # The apt install brings back valkey-server.service.
                purge_legacy_valkey_units
                ensure_canonical_valkey_unit
            fi

            ensure_valkey_data_dirs

            # Both before the first start, so ValKey comes up authenticated.
            ensure_valkey_admin_password_set
            ensure_valkey_aclfile_configured

            systemctl enable "${svc_name}" 2>/dev/null || true
            systemctl restart "${svc_name}" 2>/dev/null || systemctl start "${svc_name}" 2>/dev/null || true

            if verify_valkey_admin_auth; then
                VALKEY_RUNNING=true
                HAS_VALKEY=true
                log_success "Valkey running on port 47445 (${svc_name})"
            else
                VALKEY_RUNNING=false
                HAS_VALKEY=false
                log_error "Valkey did not come up authenticated on port 47445"
                log_info "Inspect: sudo systemctl status ${svc_name} --no-pager"
                log_info "Inspect: sudo journalctl -u ${svc_name} --no-pager -n 80"
                log_info "Subsequent Phase 7 + Phase 9 + dashboard ACL will skip"
                # Later phases skip on VALKEY_RUNNING; the summary shows this phase failed.
                return 1
            fi
            ;;

        2)
            if ! command -v docker &>/dev/null; then
                log_error "Docker not found — install Docker first"
                return
            fi
            log_info "Starting ValKey in Docker..."
            docker run -d \
                --name valkey-gnode \
                --restart unless-stopped \
                -p 127.0.0.1:47445:6379 \
                valkey/valkey:latest \
                valkey-server --port 6379 2>/dev/null || {
                    log_warning "Docker start failed (container may already exist)"
                    docker start valkey-gnode 2>/dev/null || true
                }
            VALKEY_RUNNING=true
            HAS_VALKEY=true
            log_success "ValKey running in Docker (port 47445)"
            ;;

        3)
            log_info "Skipping ValKey setup — configure manually before starting gNode"
            ;;
    esac

    if [[ "$VALKEY_REPLICA" == "true" ]]; then
        configure_valkey_replica
    fi

    # ACL users are provisioned on the master only: a replica receives them by replication.
    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_daemon_acl
    fi

    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_comms_acl
    fi

    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_dashboard_acl
    fi

    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_replica_acl
    fi
}

# valkey-cli exits 0 when the server rejects a command, so the reply is checked instead.
valkey_admin_ok() {
    local pwfile="$1" port="$2"; shift 2
    local out
    out="$(REDISCLI_AUTH="$(cat "$pwfile")" valkey-cli -p "$port" "$@" 2>&1)"
    if [[ "$out" == "OK" ]]; then
        return 0
    fi
    log_warning "ValKey rejected: $* "
    log_warning "  server said: ${out}"
    return 1
}

# The daemon's own ValKey user (gnode_daemon), distinct from admin; re-runs reuse its password.
provision_daemon_acl() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local cred_file="${cred_dir}/valkey_daemon.password"
    local admin_pwfile="${cred_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"
    local gnode_credit_dir="${INSTALL_ROOT:-/opt/geodineum}/gNode/.gnode"
    local gnode_credit_file="${gnode_credit_dir}/valkey_daemon.password"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER gnode_daemon with @all -@dangerous; write ${cred_file} (0640 deploy:gnode); symlink to ${gnode_credit_file}"
        return
    fi

    if [[ ! -d "$cred_dir" ]]; then
        log_warning "Credential dir missing — skipping gnode_daemon ACL provisioning"
        return
    fi

    if [[ ! -r "$admin_pwfile" ]]; then
        log_warning "Admin ValKey password not yet readable at ${admin_pwfile} — skipping gnode_daemon ACL provisioning"
        return
    fi

    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        chmod 0640 "$cred_file" 2>/dev/null || true
        chown "gnode:geodineum-creds" "$cred_file" 2>/dev/null || true
        log_success "Generated gnode_daemon credential at ${cred_file}"
    fi

    # FUNCTION is not in @dangerous, so FLUSH and RESTORE are denied explicitly; defined only here.
    local acl_rule_file="/etc/geodineum/components/gnode-daemon/acl-daemon-tier.rule"
    local acl_daemon_tier=(
        on
        resetkeys "~*"
        resetchannels "&*"
        +@all
        -@dangerous
        "-function|flush"
        "-function|restore"
    )

    if ! valkey_admin_ok "$admin_pwfile" "$valkey_port" \
        ACL SETUSER gnode_daemon \
        resetpass ">${password}" \
        "${acl_daemon_tier[@]}"; then
        log_warning "ACL SETUSER gnode_daemon failed"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return 1
    fi

    install -d -m 0750 -o gnode -g "$(_components_group)" /etc/geodineum/components/gnode-daemon 2>/dev/null || true
    printf '%s\n' "${acl_daemon_tier[*]}" > "$acl_rule_file"
    chown root:gnode "$acl_rule_file" 2>/dev/null || true
    chmod 0640 "$acl_rule_file" 2>/dev/null || true

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    # A no-op on first install (gNode is not cloned yet); phase_services repeats it.
    ensure_daemon_credential_symlink

    log_success "ACL user gnode_daemon provisioned (full grants, @dangerous denied)"
}

# Replication-only ACL user for read replicas: replication commands are @dangerous, which the daemon user lacks.
provision_replica_acl() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local cred_file="${cred_dir}/valkey_replica.password"
    local admin_pwfile="${cred_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER gnode_replica nocommands +psync +replconf +ping; write ${cred_file} (0640 gnode:geodineum-creds)"
        return
    fi

    if [[ ! -d "$cred_dir" ]]; then
        log_warning "Credential dir missing — skipping gnode_replica ACL provisioning"
        return
    fi

    if [[ ! -r "$admin_pwfile" ]]; then
        log_warning "Admin ValKey password not yet readable at ${admin_pwfile} — skipping gnode_replica ACL provisioning"
        return
    fi

    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        chmod 0640 "$cred_file" 2>/dev/null || true
        chown "gnode:geodineum-creds" "$cred_file" 2>/dev/null || true
        log_success "Generated gnode_replica credential at ${cred_file}"
    fi

    if ! valkey_admin_ok "$admin_pwfile" "$valkey_port" \
        ACL SETUSER gnode_replica \
        on \
        resetpass ">${password}" \
        resetkeys \
        resetchannels \
        nocommands \
        +psync +replconf +ping; then
        log_warning "ACL SETUSER gnode_replica failed"
        return 1
    fi

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true
    log_success "ACL user gnode_replica provisioned (replication-only; copy ${cred_file} to workers)"
}

# The geodineum_comms ACL user; a rerun keeps its existing password.
provision_comms_acl() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local cred_file="${cred_dir}/valkey_comms.password"
    local admin_pwfile="${cred_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER geodineum_comms (allowlisted commands and keys); write ${cred_file} (0640 root:geodineum-comms)"
        return
    fi

    if [[ ! -d "$cred_dir" ]]; then
        log_warning "Credential dir missing — skipping geodineum_comms ACL provisioning"
        return
    fi

    if [[ ! -r "$admin_pwfile" ]]; then
        log_warning "Admin ValKey password not yet readable at ${admin_pwfile} — skipping geodineum_comms ACL provisioning"
        return
    fi

    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        log_success "Generated geodineum_comms credential at ${cred_file}"
    fi
    chmod 0640 "$cred_file" 2>/dev/null || true
    chown "root:geodineum-comms" "$cred_file" 2>/dev/null || true

    # An allowlist, because a denylist would grant every command ValKey adds later.
    local acl_comms_commands=(
        -@all
        # Streams: consume its work queue, ack it, and write receipts.
        +xread +xreadgroup +xadd +xack +xclaim +xautoclaim +xpending
        +xinfo +xlen +xtrim +xrange +xrevrange +xgroup +xdel
        # Functions: the ecosystem's read path is FCALL-only by policy.
        +fcall +fcall_ro
        # Strings / expiry: message state and the keyed rendezvous.
        +get +set +setex +setnx +psetex +del +exists +ttl +pttl +expire +pexpire
        +mget +mset +incr +decr +incrby +decrby +append
        # Hashes: delivery status, config, the receipt pubkey registry.
        +hget +hset +hgetall +hdel +hexists +hkeys +hvals +hincrby +hincrbyfloat
        +hmget +hmset +hsetnx +hlen +hscan
        # Lists / sets: retry queues and dedupe sets.
        +lrange +llen +lpush +rpush
        +sadd +smembers +sismember +srem +scard +sscan
        # Introspection it genuinely needs.
        +scan +type +object +ping +echo +time +auth +select
        # KEYS is O(N); DEBUG and CLIENT are operator tools, except harmless connection naming.
        -keys -debug -client
        "+client|id" "+client|getname" "+client|setname" "+client|setinfo"
    )
    local acl_comms_keys=(
        "~*:gnode:comms:*" "~*:comms:config" "~*:comms:retry:*"
        "~*:comms:messages:*" "~*:comms:stats:*"
        "~*:comms:context:*" "~*:comms:active_context:*"
        # Read, never write: discovery.
        "%R~gnode:site:*" "%R~gnode:sites:*" "%R~gnode:routing:*" "%R~topology:*"
        "%R~*:gnode:schema:*"
        # ...except the schema it publishes itself at start.
        "~*:gnode:schema:geodineum_comms:*" "~*:gnode:schema:_index"
        # Receipts: the pubkey registry and the receipt streams; both are needed to sign.
        "~*:gnode:receipt_pubkeys" "~*:gnode:receipts:*"
        # Its own heartbeat in every constellation it serves (CONTRACTS/heartbeat.md).
        "~*:gnode:heartbeat:*:comms:*"
    )
    if ! REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" \
        ACL SETUSER geodineum_comms \
        on \
        resetpass ">${password}" \
        resetkeys clearselectors "${acl_comms_keys[@]}" \
        resetchannels "&*" \
        "${acl_comms_commands[@]}" \
        >/dev/null; then
        log_warning "ACL SETUSER geodineum_comms failed — see output above"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return 1
    fi

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    log_success "ACL user geodineum_comms provisioned (allowlisted commands and keys)"
}

# Make gNode/.gnode a symlink to the credential store, so every credential there is visible to the daemon.
ensure_daemon_credential_symlink() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local gnode_root="${INSTALL_ROOT:-/opt/geodineum}/gNode"
    local link_path="${gnode_root}/.gnode"

    [[ -d "$gnode_root" ]] || return 0
    [[ -d "$cred_dir" ]]   || return 0

    if [[ -L "$link_path" ]] && [[ "$(readlink "$link_path")" == "$cred_dir" ]]; then
        return 0
    fi

    if [[ -L "$link_path" ]]; then
        rm -f "$link_path"
    elif [[ -d "$link_path" ]]; then
        rm -rf "$link_path"
    fi

    ln -s "$cred_dir" "$link_path"
    chown -h gnode:gnode "$link_path" 2>/dev/null || true
    log_detail "Daemon credential view: ${link_path} → ${cred_dir}"
}

# Read-only ACL user for the wp-admin dashboard, plus append to the operator audit log.
provision_dashboard_acl() {
    local creds_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    # Its own directory: the only credential location www-data can reach.
    local dash_dir="/etc/geodineum/dashboard"
    local cred_file="${dash_dir}/geodineum-dashboard.txt"
    local admin_pwfile="${creds_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER geodineum_dashboard with read-only + audit-log xadd; write ${cred_file} (0640 gnode:geodineum-dash)"
        return
    fi

    # Phase 7 creates this directory too, but this runs earlier.
    if [[ ! -d "$dash_dir" ]]; then
        if getent group geodineum-dash >/dev/null 2>&1; then
            install -d -m 0750 -o root -g geodineum-dash "$dash_dir"
        else
            install -d -m 0750 "$dash_dir"
            log_warning "geodineum-dash group missing — dashboard dir created without group ownership; Phase 7 will fix"
        fi
    fi

    if [[ ! -r "$admin_pwfile" ]]; then
        log_warning "Admin ValKey password not yet readable at ${admin_pwfile} — skipping geodineum_dashboard ACL provisioning"
        log_info "Re-run install.sh once ValKey admin credentials are populated"
        return
    fi

    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        chmod 0640 "$cred_file" 2>/dev/null || true
        chown "gnode:geodineum-dash" "$cred_file" 2>/dev/null || true
        log_success "Generated geodineum_dashboard credential at ${cred_file}"
    fi

    local admin_password
    admin_password="$(cat "$admin_pwfile")"

    # +xadd comes after -@write so it survives; the %W selector confines writes to the audit key.
    if ! REDISCLI_AUTH="$admin_password" valkey-cli -p "$valkey_port" \
        ACL SETUSER geodineum_dashboard \
        on \
        resetpass ">${password}" \
        resetkeys "%R~*" "%W~geodineum:audit-log:operator-actions" \
        resetchannels \
        +@read \
        -@write -@admin -@dangerous \
        -flushall -flushdb -shutdown -debug -config -script \
        +xadd +fcall_ro \
        >/dev/null; then
        log_warning "ACL SETUSER geodineum_dashboard failed — see output above"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return
    fi

    REDISCLI_AUTH="$admin_password" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    log_success "ACL user geodineum_dashboard provisioned (read-only + audit-log xadd)"
}

configure_valkey_replica() {
    log_step "Phase 4b/10: ValKey Replica Configuration"

    local replica_script="${INSTALL_ROOT}/gNode/scripts/setup-valkey-replica.sh"
    if [[ ! -x "$replica_script" ]]; then
        log_warning "setup-valkey-replica.sh not found at $replica_script"
        log_info "Configure replication manually after install"
        return
    fi

    local master_ip="${CONSTELLATION_MASTER_IP:-10.66.0.1}"
    local master_port="${CONSTELLATION_MASTER_PORT:-47445}"
    local master_pass_file="${CONSTELLATION_MASTER_PASSWORD_FILE:-/etc/geodineum/credentials/valkey_constellation.password}"

    if [[ "$YES_MODE" != "true" ]]; then
        echo ""
        echo "  ${BOLD}Replica setup — connect to constellation master:${NC}"
        read -p "    Master IP [${master_ip}]: " input
        master_ip="${input:-$master_ip}"
        read -p "    Master port [${master_port}]: " input
        master_port="${input:-$master_port}"
        read -p "    Master password file [${master_pass_file}]: " input
        master_pass_file="${input:-$master_pass_file}"
    fi

    if [[ ! -f "$master_pass_file" ]]; then
        log_warning "Master password file not found: $master_pass_file"
        log_info "Get it from the master with: sudo cat /etc/geodineum/credentials/valkey_daemon.password"
        log_info "Then save it to $master_pass_file (chmod 600 root:gnode) and re-run replica setup"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "$replica_script --master $master_ip --master-port $master_port --master-password-file $master_pass_file"
        return
    fi

    "$replica_script" \
        --master "$master_ip" \
        --master-port "$master_port" \
        --master-password-file "$master_pass_file" || {
        log_warning "Replica config failed — see output above"
        return
    }

    log_info "Restarting valkey-gnode to apply replica config..."
    systemctl restart valkey-gnode 2>/dev/null || \
        log_warning "Could not restart valkey-gnode — restart manually: sudo systemctl restart valkey-gnode"

    log_success "Local ValKey configured as replica of ${master_ip}:${master_port}"
    log_info "Lua functions auto-loaded on every restart via systemd ExecStartPost"
    log_info "Verify replication: REDISCLI_AUTH=... valkey-cli -p ${master_port} INFO replication"
}

# =============================================================================
# PHASE 5: Component Fetch
# =============================================================================

preflight_github_auth() {
    local test_repo="geodineum/Geodineum"
    local test_url="${GITHUB_CLONE_PREFIX}${test_repo}${GITHUB_CLONE_SUFFIX}"
    local check_user="${SUDO_USER:-$(whoami)}"

    log_info "Verifying GitHub auth (clone protocol: ${GIT_PROTOCOL:-https}, repo: ${test_repo})"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "git ls-remote ${test_url} HEAD (as ${check_user})"
        return 0
    fi

    if sudo_as_user "$check_user" git ls-remote --exit-code "$test_url" HEAD >/dev/null 2>&1; then
        log_success "GitHub auth OK (${GIT_PROTOCOL:-https} as ${check_user})"
        return 0
    fi

    log_error "Cannot reach ${test_repo} via ${GITHUB_CLONE_PREFIX}"
    echo ""
    echo -e "  Check that this host reaches github.com. For private forks, use either:"
    echo ""
    echo -e "    ${BOLD}A) SSH deploy key${NC} (recommended)"
    echo "       1. ssh-keygen -t ed25519 -f ~/.ssh/geodineum_deploy -N ''"
    echo "       2. Add ~/.ssh/geodineum_deploy.pub to each repo at:"
    echo "          https://github.com/<owner>/<repo>/settings/keys"
    echo "       3. Add to ~/.ssh/config:"
    echo "          Host github.com"
    echo "              IdentityFile ~/.ssh/geodineum_deploy"
    echo "              IdentitiesOnly yes"
    echo "       4. Re-run: sudo GEODINEUM_GIT_PROTOCOL=ssh ./install.sh"
    echo ""
    echo -e "    ${BOLD}B) Personal Access Token${NC}"
    echo "       1. Generate at https://github.com/settings/tokens?type=beta"
    echo "          (read-only, restricted to the geodineum/* repos)"
    echo "       2. Re-run: sudo GEODINEUM_GITHUB_TOKEN='ghp_xxx' ./install.sh"
    echo ""
    echo -e "  Full guide: ${BOLD}docs/GITHUB_AUTH.md${NC}"
    echo ""
    return 1
}

phase_fetch() {
    local resolved=($@)

    log_step "Phase 5/10: Fetching Components"

    preflight_github_auth || {
        log_error "GitHub authentication check failed — see docs/GITHUB_AUTH.md"
        exit 1
    }

    for comp in "${resolved[@]}"; do
        fetch_component "$comp" || {
            log_error "Failed to fetch ${comp} — cannot continue"
            exit 1
        }
    done

    # Later phases run geodeploy and the CLI from the installed copy, not from this clone.
    install_self_to_opt

    if [[ "${GEODINEUM_SKIP_CMS:-false}" != "true" ]]; then
        fetch_extension "gnode-cms" "geodineum/gNode-CMS" || {
            log_warning "Failed to clone gNode-CMS — daemon will build WITHOUT CMS handlers"
            log_info "Sites/services depending on CMS commands won't work until CMS is cloned + signed"
            log_info "Retry: GEODINEUM_SKIP_CMS=false ./install.sh"
        }
    else
        log_info "GEODINEUM_SKIP_CMS=true — skipping gNode-CMS clone (lean build)"
    fi

    if [[ -d "${INSTALL_ROOT}/gNode/scripts" ]]; then
        GNODE_SCRIPTS="${INSTALL_ROOT}/gNode/scripts"
    fi
}

# Clone or update a signed gNode extension under ${INSTALL_ROOT}/pro/gNode/.
fetch_extension() {
    local ext_name="$1"           # e.g. "gnode-cms"
    local ext_repo="$2"           # e.g. "geodineum/gNode-CMS"
    local ext_dir_name="${ext_repo##*/}"   # "gNode-CMS"
    local ext_parent="${INSTALL_ROOT}/pro/gNode"
    local ext_dir="${ext_parent}/${ext_dir_name}"
    local branch="${GEODINEUM_BRANCH:-}"
    local branch_label="${branch:-<default>}"

    install -d -m 0755 -o "${DEPLOY_USER:-root}" -g gnode "$ext_parent" 2>/dev/null \
        || install -d -m 0755 "$ext_parent"

    if [[ -d "${ext_dir}/.git" ]]; then
        log_info "Updating ${ext_dir_name} (branch: ${branch_label})"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_dry "cd ${ext_dir} && git pull --ff-only"
            return 0
        fi
        local pull_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
        cd "$ext_dir"
        sudo_as_user "$pull_user" /usr/bin/git fetch origin 2>/dev/null || true
        if [[ -n "$branch" ]]; then
            sudo_as_user "$pull_user" /usr/bin/git checkout "$branch" 2>/dev/null || \
            sudo_as_user "$pull_user" /usr/bin/git checkout -b "$branch" "origin/${branch}" 2>/dev/null || true
            sudo_as_user "$pull_user" /usr/bin/git pull --ff-only origin "$branch" 2>/dev/null || true
        else
            sudo_as_user "$pull_user" /usr/bin/git pull --ff-only 2>/dev/null || true
        fi
        log_success "${ext_dir_name} updated"
        return 0
    fi

    log_info "Cloning ${ext_dir_name} from ${ext_repo} (branch: ${branch_label})"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "git clone ${GITHUB_CLONE_PREFIX}${ext_repo}${GITHUB_CLONE_SUFFIX} ${ext_dir}"
        return 0
    fi
    local clone_branch_arg=""
    [[ -n "$branch" ]] && clone_branch_arg="--branch ${branch}"
    local clone_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
    local clone_rc=0
    if [[ -n "$clone_user" ]] && [[ "$clone_user" != "root" ]]; then
        sudo_as_user "$clone_user" /usr/bin/git clone ${clone_branch_arg} \
            "${GITHUB_CLONE_PREFIX}${ext_repo}${GITHUB_CLONE_SUFFIX}" \
            "$ext_dir" || clone_rc=$?
    else
        /usr/bin/git clone ${clone_branch_arg} \
            "${GITHUB_CLONE_PREFIX}${ext_repo}${GITHUB_CLONE_SUFFIX}" \
            "$ext_dir" || clone_rc=$?
    fi
    if [[ "$clone_rc" -ne 0 ]]; then
        log_error "Failed to clone ${ext_repo} (git exit ${clone_rc})"
        return 1
    fi
    log_success "${ext_dir_name} cloned"
}

# Install this installer repo at ${INSTALL_ROOT}/Geodineum: a git clone of origin when there is one, else rsync.
install_self_to_opt() {
    local target="${INSTALL_ROOT}/Geodineum"
    local source="${SCRIPT_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Mirror installer ${source} → ${target}"
        return 0
    fi

    if [[ -d "${source}/.git" ]]; then
        local origin_url
        origin_url=$(cd "$source" && git remote get-url origin 2>/dev/null || echo "")
        if [[ -n "$origin_url" ]]; then
            local pull_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
            mkdir -p "$(dirname "$target")"
            chown "${pull_user}:geodineum" "$(dirname "$target")" 2>/dev/null || true

            local branch="${GEODINEUM_BRANCH:-}"
            if [[ -d "${target}/.git" ]]; then
                log_info "Updating installer at ${target} (branch: ${branch:-<default>})"
                cd "$target"
                sudo_as_user "$pull_user" /usr/bin/git fetch origin 2>/dev/null || true
                if [[ -n "$branch" ]]; then
                    sudo_as_user "$pull_user" /usr/bin/git checkout "$branch" 2>/dev/null || \
                    sudo_as_user "$pull_user" /usr/bin/git checkout -b "$branch" "origin/${branch}" 2>/dev/null || true
                    sudo_as_user "$pull_user" /usr/bin/git pull --ff-only origin "$branch" 2>/dev/null || true
                else
                    sudo_as_user "$pull_user" /usr/bin/git pull --ff-only 2>/dev/null || true
                fi
            else
                log_info "Cloning installer from ${origin_url} → ${target} (branch: ${branch:-<default>})"
                local clone_argv=(/usr/bin/git clone)
                [[ -n "$branch" ]] && clone_argv+=(--branch "$branch")
                clone_argv+=(-- "$origin_url" "$target")
                if ! sudo_as_user "$pull_user" -- "${clone_argv[@]}"; then
                    log_warning "Installer clone to ${target} failed — falling back to rsync"
                    install_self_via_rsync "$source" "$target"
                    return $?
                fi
            fi
            chown -R "${pull_user}:geodineum" "$target" 2>/dev/null || true
            log_success "Installer deployed at ${target}"
            return 0
        fi
    fi

    install_self_via_rsync "$source" "$target"
}

install_self_via_rsync() {
    local source="$1" target="$2"
    if ! command -v rsync &>/dev/null; then
        apt-get install -y -qq rsync 2>/dev/null || {
            log_warning "rsync unavailable; skipping installer deploy to ${target}"
            log_info "Manual: cp -a ${source} ${target}"
            return 1
        }
    fi
    mkdir -p "$target"
    rsync -a --exclude=".git" --delete "${source}/" "${target}/"
    chown -R "${DEPLOY_USER:-${SUDO_USER:-root}}:geodineum" "$target" 2>/dev/null || true
    log_success "Installer rsync'd to ${target}"
    return 0
}

fetch_component() {
    local name="$1"
    local repo
    repo=$(get_repo "$name")
    local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"

    if [[ -z "$repo" ]]; then
        log_warning "Unknown component: ${name} (skipping)"
        return 1
    fi

    # Empty means the remote's default branch.
    local branch="${GEODINEUM_BRANCH:-}"
    local branch_label="${branch:-<default>}"

    if [[ -d "$install_dir" ]] && [[ -d "${install_dir}/.git" ]]; then
        log_info "Updating ${name} (branch: ${branch_label})"
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ -n "$branch" ]]; then
                log_dry "cd ${install_dir} && git fetch origin && git checkout ${branch} && git pull --ff-only origin ${branch}"
            else
                log_dry "git pull ${repo} in ${install_dir}"
            fi
            return 0
        fi
        cd "$install_dir"
        # Pull as the user whose SSH keys can reach the repos.
        local pull_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
        local git_err
        if [[ -n "$branch" ]]; then
            if ! git_err="$(sudo_as_user "$pull_user" git fetch origin 2>&1 >/dev/null)"; then
                log_warning "git fetch failed for ${name} — using existing tree"
                log_warning "  git: $(tail -n1 <<<"$git_err")"
                return 0
            fi
            if ! sudo_as_user "$pull_user" git rev-parse --verify "origin/${branch}" >/dev/null 2>&1; then
                log_error "Branch '${branch}' does not exist on origin/${name} — aborting"
                return 1
            fi
            sudo_as_user "$pull_user" git checkout "${branch}" 2>/dev/null || \
            sudo_as_user "$pull_user" git checkout -b "${branch}" "origin/${branch}" 2>/dev/null || {
                git_err="$(sudo_as_user "$pull_user" git checkout "${branch}" 2>&1 >/dev/null || true)"
                log_error "Failed to checkout ${branch} for ${name}"
                log_error "  git: $(tail -n1 <<<"$git_err")"
                return 1
            }
            if ! git_err="$(sudo_as_user "$pull_user" git pull --ff-only origin "${branch}" 2>&1 >/dev/null)"; then
                log_warning "ff-only pull failed for ${name}@${branch} — branch may have diverged locally"
                log_warning "  git: $(tail -n1 <<<"$git_err")"
            fi
        else
            sudo_as_user "$pull_user" git pull --ff-only origin main 2>/dev/null || \
            if ! git_err="$(sudo_as_user "$pull_user" git pull --ff-only 2>&1 >/dev/null)"; then
                log_warning "Pull failed for ${name} — using existing version"
                log_warning "  git: $(tail -n1 <<<"$git_err")"
            fi
        fi
        log_success "${name} updated"
    else
        log_info "Cloning ${name} from ${repo} (branch: ${branch_label})"
        if [[ "$DRY_RUN" == "true" ]]; then
            local dry_branch=""
            [[ -n "$branch" ]] && dry_branch=" --branch ${branch}"
            log_dry "git clone${dry_branch} ${GITHUB_CLONE_PREFIX}${repo}${GITHUB_CLONE_SUFFIX} → ${install_dir}"
            return 0
        fi
        mkdir -p "$(dirname "$install_dir")"
        # Clone as the same user as the update path, so the tree has one owner (git refuses "dubious ownership").
        local clone_branch_arg=""
        [[ -n "$branch" ]] && clone_branch_arg="--branch ${branch}"
        local clone_cmd="git clone ${clone_branch_arg} ${GITHUB_CLONE_PREFIX}${repo}${GITHUB_CLONE_SUFFIX} ${install_dir}"
        local clone_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
        local clone_rc=0
        if [[ -n "$clone_user" ]] && [[ "$clone_user" != "root" ]]; then
            sudo_as_user "$clone_user" $clone_cmd || clone_rc=$?
        else
            $clone_cmd || clone_rc=$?
        fi
        if [[ "$clone_rc" -ne 0 ]]; then
            log_error "Failed to clone ${repo}${branch:+ @ ${branch}} (git exit ${clone_rc})"
            log_info "Hint (SAML SSO): if your org enforces SSO, authorize the deploy key:"
            log_info "  → https://github.com/settings/keys → Configure SSO → Authorize"
            log_info "Hint (verify access): sudo -u ${clone_user} git ls-remote ${GITHUB_CLONE_PREFIX}${repo}${GITHUB_CLONE_SUFFIX} HEAD"
            if [[ -n "$branch" ]]; then
                log_info "Hint (verify branch): git ls-remote ${GITHUB_CLONE_PREFIX}${repo}${GITHUB_CLONE_SUFFIX} ${branch}"
            fi
            return 1
        fi
        log_success "${name} cloned"
    fi
    return 0
}

# =============================================================================
# PHASE 6: Build
# =============================================================================

# Draw a progress bar on /dev/tty from cargo output on stdin; pass errors, warnings and other lines to stdout.
_render_cargo_progress() {
    local label="$1" total="${2:-250}"
    local bar_full='████████████████████████████████████████'
    local bar_empty='········································'
    local width=40
    local count=0 pct filled crate

    printf "  [%s] %2d%% %-30.30s" "$bar_empty" 0 "starting..." >/dev/tty
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+Compiling[[:space:]]+([^[:space:]]+) ]]; then
            count=$((count + 1))
            crate="${BASH_REMATCH[1]}"
            pct=$(( count * 100 / total ))
            (( pct > 99 )) && pct=99
            filled=$(( pct * width / 100 ))
            printf "\r  [%s%s] %2d%% %-30.30s" \
                "${bar_full:0:filled}" "${bar_empty:0:$((width - filled))}" \
                "$pct" "$crate" >/dev/tty
        elif [[ "$line" =~ ^[[:space:]]+Updating ]]; then
            printf "\r  [%s] %2d%% %-30.30s" "$bar_empty" 0 "updating registry..." >/dev/tty
        elif [[ "$line" =~ ^[[:space:]]+(Locking|Downloading|Downloaded|Fresh|Adding) ]]; then
            :
        elif [[ "$line" =~ ^[[:space:]]+Finished ]]; then
            printf "\r  [%s] 100%% %-30.30s\n" "$bar_full" "${label} built" >/dev/tty
            printf "%s\n" "$line"
        elif [[ "$line" == error:* ]] || [[ "$line" == error\[* ]] || [[ "$line" == warning:* ]]; then
            printf "\r%-80s\r" "" >/dev/tty
            printf "%s\n" "$line"
        else
            printf "%s\n" "$line"
        fi
    done
    printf "\n" >/dev/tty 2>/dev/null || true
}

# Probes /dev/tty because stdout is a tee to the log, so `[[ -t 1 ]]` is always false.
_has_controlling_tty() {
    [[ "${NO_BUILD_PROGRESS:-}" != "1" ]] && ( exec 3>/dev/tty ) 2>/dev/null
}

# Estimate the crate count for the progress bar from `cargo tree`, which does not compile.
_count_cargo_crates() {
    local cargo_dir="$1" build_user="$2"
    shift 2
    local env_assigns=("$@")
    local total
    total=$( cd "$cargo_dir" && sudo -u "$build_user" env "${env_assigns[@]}" bash -c \
        '[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"; cargo tree --prefix none --edges normal 2>/dev/null | awk "NF{print \$1}" | sort -u | wc -l' \
        2>/dev/null )
    [[ ! "$total" =~ ^[0-9]+$ ]] && total=0
    (( total < 10 )) && total=250
    echo "$total"
}

# Run BUILD_CMD (anything wrapping `cargo build`) as BUILD_USER in CARGO_DIR behind the progress bar.
# Usage: build_cmd_with_progress LABEL CARGO_DIR BUILD_USER BUILD_CMD [ENV_KV ...]
build_cmd_with_progress() {
    local label="$1" cargo_dir="$2" build_user="$3" build_cmd="$4"
    shift 4
    local env_assigns=("$@")

    if ! _has_controlling_tty; then
        ( cd "$cargo_dir" && sudo -u "$build_user" env "${env_assigns[@]}" bash -c "$build_cmd" )
        return $?
    fi

    local total
    total=$(_count_cargo_crates "$cargo_dir" "$build_user" "${env_assigns[@]}")

    local status_file
    status_file=$(mktemp)

    set +e
    {
        ( cd "$cargo_dir" && sudo -u "$build_user" env "${env_assigns[@]}" bash -c "$build_cmd" 2>&1
          echo $? >"$status_file" )
    } | _render_cargo_progress "$label" "$total"
    set -e 2>/dev/null

    local rc=0
    [[ -s "$status_file" ]] && rc=$(cat "$status_file")
    rm -f "$status_file"
    return "$rc"
}

cargo_build_with_progress() {
    local label="$1" cargo_dir="$2" build_user="$3"
    shift 3
    build_cmd_with_progress "$label" "$cargo_dir" "$build_user" \
        '[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"; cargo build --release' \
        "$@"
}

phase_build() {
    local resolved=($@)

    log_step "Phase 6/10: Building Components"

    # gNode's build.sh needs the bootstrap loader and env, which Phase 7 would write too late.
    ensure_bootstrap_loader_installed
    ensure_bootstrap_env_written

    local rc=0
    for comp in "${resolved[@]}"; do
        build_component "$comp" || rc=$?
    done
    return $rc
}

# Install the shared helper libs to /usr/local/lib/geodineum/, the one path their consumers search.
ensure_bootstrap_loader_installed() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "install ${LIB_DIR}/{bootstrap-loader,common,cli-helpers,manifest-registry,manifest-policy,manifest-install,assert-env-readable}.sh → /usr/local/lib/geodineum/"
        return 0
    fi
    if [[ ! -f "${LIB_DIR}/bootstrap-loader.sh" ]]; then
        log_warning "bootstrap-loader.sh source not found at ${LIB_DIR}/bootstrap-loader.sh"
        return 1
    fi
    install -d -m 0755 -o root -g root /usr/local/lib/geodineum

    install -m 0755 -o root -g root \
        "${LIB_DIR}/bootstrap-loader.sh" \
        /usr/local/lib/geodineum/bootstrap-loader.sh

    local _helper
    for _helper in common.sh cli-helpers.sh manifest-registry.sh manifest-policy.sh manifest-install.sh assert-env-readable.sh; do
        if [[ -f "${LIB_DIR}/${_helper}" ]]; then
            install -m 0755 -o root -g root \
                "${LIB_DIR}/${_helper}" \
                "/usr/local/lib/geodineum/${_helper}"
        fi
    done

    log_success "Helper libs available at /usr/local/lib/geodineum/"
}

# Write /etc/geodineum/bootstrap.env with exactly the three keys the bootstrap loader accepts.
ensure_bootstrap_env_written() {
    local env_file="/etc/geodineum/bootstrap.env"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "write ${env_file} (3 whitelisted keys: VALKEY_HOST/PORT/CREDS_PATH)"
        return 0
    fi
    if [[ -s "$env_file" ]]; then
        # Any other key makes the daemon refuse to start.
        local extra_keys
        extra_keys=$(grep -E "^[A-Z_]+=" "$env_file" 2>/dev/null \
            | grep -vE "^(VALKEY_HOST|VALKEY_PORT|VALKEY_CREDS_PATH)=" \
            | cut -d= -f1 | tr '\n' ' ')
        if [[ -z "$extra_keys" ]]; then
            log_detail "bootstrap.env present with strict 3-key shape (no drift)"
            return 0
        fi
        log_warning "bootstrap.env content drift detected — non-whitelisted keys present:"
        log_warning "  ${extra_keys}"
        log_warning "These keys belong in ValKey Tier 2. The Rust"
        log_warning "bootstrap-loader strict-rejects anything outside {VALKEY_HOST,"
        log_warning "VALKEY_PORT, VALKEY_CREDS_PATH}, so the gnode-daemon would FATAL."
        log_warning "Backing up drifted file to ${env_file}.archived-$(date +%Y%m%d-%H%M%S)"
        cp "$env_file" "${env_file}.archived-$(date +%Y%m%d-%H%M%S)"
        # Keep the operator's ValKey values over the defaults.
        local _host _port _creds
        _host=$(grep -E '^VALKEY_HOST=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        _port=$(grep -E '^VALKEY_PORT=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        _creds=$(grep -E '^VALKEY_CREDS_PATH=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        [[ -n "$_host" ]]  && VALKEY_HOST="$_host"
        [[ -n "$_port" ]]  && VALKEY_PORT="$_port"
        [[ -n "$_creds" ]] && VALKEY_CREDS_PATH="$_creds"
    fi
    # o+x lets service users reach their group-readable files; same mode as lib/geodeploy.sh fix_config_perms.
    install -d -m 0751 -o root -g geodineum /etc/geodineum 2>/dev/null \
        || install -d -m 0751 /etc/geodineum
    local host="${VALKEY_HOST:-127.0.0.1}"
    local port="${VALKEY_PORT:-47445}"
    local creds="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    install -d -m 0750 -o root -g root "$creds" 2>/dev/null || true
    # Same shape as lib/bootstrap-loader.sh write_disk_bootstrap.
    cat > "$env_file" << EOF_BOOTSTRAP_ENV
VALKEY_HOST=${host}
VALKEY_PORT=${port}
VALKEY_CREDS_PATH=${creds}
EOF_BOOTSTRAP_ENV
    # Before the group exists, 0600 root:root is tighter and the daemon accepts it.
    if getent group geodineum-bootstrap >/dev/null 2>&1; then
        chown root:geodineum-bootstrap "$env_file"
        chmod 0640 "$env_file"
    else
        chown root:root "$env_file"
        chmod 0600 "$env_file"
        log_detail "bootstrap.env written 0600 root:root (geodineum-bootstrap group not yet created; will be normalized to 0640 by geodeploy on next cycle)"
    fi
    log_success "bootstrap.env pre-build write complete (${env_file})"
}

build_component() {
    local name="$1"
    local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"

    if [[ "$DRY_RUN" == "true" ]]; then
        case "$name" in
            gnode-daemon) log_dry "cargo build --release in ${install_dir}/daemon" ;;
            gcore|gtemplate-wp|gnode-client) log_dry "composer install in ${install_dir}" ;;
        esac
        return
    fi

    case "$name" in
        gnode-daemon)
            if [[ "$SKIP_BUILD" == "true" ]]; then
                if [[ -x "${install_dir}/daemon/target/release/gnode-daemon" ]]; then
                    log_success "gNode daemon binary exists (--skip-build)"
                else
                    log_warning "gNode daemon binary not found and --skip-build set"
                fi
                return
            fi

            if [[ ! -f "${install_dir}/daemon/Cargo.toml" ]]; then
                log_warning "Cargo.toml not found — cannot build daemon"
                return
            fi

            log_info "Building gNode daemon (this takes a few minutes on first build)..."

            # Without GNODE_EXT_DIR the daemon builds with no extensions.
            local ext_dir="${INSTALL_ROOT}/pro/gNode"
            local ext_dir_arg=""
            if [[ -d "$ext_dir" ]] && [[ -n "$(ls -A "$ext_dir" 2>/dev/null)" ]]; then
                ext_dir_arg="GNODE_EXT_DIR=${ext_dir}"
                log_detail "Building with signed extensions from ${ext_dir}/"
            fi

            # cargo and rustup live in the build user's home, not root's.
            local build_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
            local env_kv=()
            [[ -n "$ext_dir_arg" ]] && env_kv+=("$ext_dir_arg")

            if [[ -x "${install_dir}/scripts/build.sh" ]]; then
                if ! build_cmd_with_progress "gNode daemon" \
                        "${install_dir}/daemon" "$build_user" \
                        "cd ${install_dir} && bash scripts/build.sh" \
                        "${env_kv[@]}"; then
                    log_error "Daemon build failed"
                    return 1
                fi
            else
                if ! cargo_build_with_progress "gNode daemon" \
                        "${install_dir}/daemon" "$build_user" "${env_kv[@]}"; then
                    log_error "Cargo build failed"
                    return 1
                fi
            fi

            if [[ -x "${install_dir}/daemon/target/release/gnode-daemon" ]]; then
                GNODE_INSTALLED=true
                log_success "gNode daemon built"
            else
                log_error "Build completed but binary not found"
                return 1
            fi
            ;;

        gcore)
            if [[ -f "${install_dir}/composer.json" ]] && [[ "$HAS_COMPOSER" == "true" ]]; then
                log_info "Installing gCore PHP dependencies..."
                cd "$install_dir"
                composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null || {
                    log_warning "Composer install failed for gCore"
                }
                log_success "gCore dependencies installed"
            fi
            ;;

        gnode-client)
            if [[ -f "${install_dir}/composer.json" ]] && [[ "$HAS_COMPOSER" == "true" ]]; then
                log_info "Installing gNode-Client PHP dependencies..."
                cd "$install_dir"
                composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null || {
                    log_warning "Composer install failed for gNode-Client"
                }
                log_success "gNode-Client dependencies installed"
            fi
            ;;

        gtemplate-wp)
            if [[ -f "${install_dir}/composer.json" ]] && [[ "$HAS_COMPOSER" == "true" ]]; then
                log_info "Installing gTemplate PHP dependencies..."
                cd "$install_dir"
                composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null || true
                log_success "gTemplate dependencies installed"
            fi
            ;;

        geodineum-comms)
            if [[ "$SKIP_BUILD" == "true" ]]; then
                if [[ -x "${install_dir}/target/release/geodineum-comms" ]]; then
                    log_success "COMMS binary exists (--skip-build)"
                else
                    log_warning "COMMS binary not found and --skip-build set"
                fi
                return
            fi

            if [[ -f "${install_dir}/Cargo.toml" ]]; then
                log_info "Building Geodineum-COMMS notification daemon..."
                local build_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
                if cargo_build_with_progress "Geodineum-COMMS" \
                        "$install_dir" "$build_user"; then
                    log_success "Geodineum-COMMS built"
                else
                    log_warning "COMMS build failed (see cargo output above) — notifications will not be available"
                fi
            fi
            ;;

        geodineum-bak)
            log_info "Setting up backup and log rotation infrastructure..."

            # The backup service runs as gnode.
            track_path_if_new "${install_dir}/backups"
            track_path_if_new "${install_dir}/backups/valkey"
            track_path_if_new "${install_dir}/logs"
            mkdir -p "${install_dir}/backups/valkey" 2>/dev/null || true
            mkdir -p "${install_dir}/logs" 2>/dev/null || true
            chown -R gnode:gnode "${install_dir}/backups" "${install_dir}/logs" 2>/dev/null || true
            chmod 750 "${install_dir}/backups" "${install_dir}/backups/valkey" "${install_dir}/logs" 2>/dev/null || true

            if [[ -d "${install_dir}/config/logrotate" ]]; then
                for conf in "${install_dir}/config/logrotate"/*; do
                    [[ -f "$conf" ]] || continue
                    local conf_name
                    conf_name=$(basename "$conf")
                    cp "$conf" "/etc/logrotate.d/${conf_name}" 2>/dev/null && \
                        log_success "Logrotate: ${conf_name}" || \
                        log_warning "Could not install logrotate config: ${conf_name}"
                done
            fi

            cat > /etc/systemd/system/valkey-backup.service << BAKSVC
[Unit]
Description=ValKey RDB Backup for Geodineum
After=valkey-gnode.service
# Wants= so manual or timer-fired runs auto-start the
# ValKey unit if it isn't already up.
Wants=valkey-gnode.service

[Service]
Type=oneshot
User=gnode
Group=gnode
ExecStart=${INSTALL_ROOT}/Geodineum-BAK/scripts/backup-valkey.sh --keep 30 --backup-dir ${install_dir}/backups/valkey

# Sandbox hardening. Mirrors the unit checked
# into Geodineum-BAK/config/systemd/valkey-backup.service.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
RestrictSUIDSGID=true
ReadWritePaths=${install_dir}/backups

StandardOutput=journal
StandardError=journal
BAKSVC

            cat > /etc/systemd/system/valkey-backup.timer << BAKTMR
[Unit]
Description=Daily ValKey Backup Timer

[Timer]
OnCalendar=*-*-* 02:00:00 UTC
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
BAKTMR

            systemctl daemon-reload 2>/dev/null
            systemctl enable valkey-backup.timer 2>/dev/null && \
                log_success "ValKey backup timer: daily at 02:00" || \
                log_warning "Could not enable backup timer"
            systemctl start valkey-backup.timer 2>/dev/null || true

            _bak_lr_conf="${install_dir}/config/logrotate/logrotate-geodineum.conf"
            if [[ -f "$_bak_lr_conf" ]]; then
                install -m 0644 -o root -g root "$_bak_lr_conf" /etc/logrotate.d/geodineum 2>/dev/null && \
                    log_success "Log rotation configured (/etc/logrotate.d/geodineum)" || \
                    log_warning "Log rotation install had issues"
            else
                log_warning "logrotate-geodineum.conf not found — log rotation NOT configured"
            fi

            log_success "Geodineum-BAK: backup + log rotation installed"
            ;;
    esac
}

# =============================================================================
# PHASE 7: Centralized Config
# =============================================================================

# /etc/geodineum/components: the group the perms sweep converges to (geodeploy.sh), gnode until it exists.
_components_group() { getent group geodineum-bootstrap >/dev/null 2>&1 && echo geodineum-bootstrap || echo gnode; }

phase_config() {
    local resolved=($@)

    log_step "Phase 7/10: Centralized Configuration"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Install lib/bootstrap-loader.sh to /usr/local/lib/geodineum/"
        log_dry "Create /etc/geodineum/ directory structure"
        log_dry "Write /etc/geodineum/bootstrap.env (3 keys, root:geodineum-bootstrap 0640)"
        log_dry "Populate ValKey tier (geodineum:bootstrap:*) with operator config"
        if has_gcore "${resolved[@]}"; then
            log_dry "Generate gcore.env + /etc/geodineum/sites (web tier)"
        fi
        log_dry "Create gnode/geodineum users+groups, set credentials perms"
        return
    fi

    # ── 1. Install canonical loader to FHS path ───────────────────────────
    track_path_if_new /usr/local/lib/geodineum
    track_path_if_new /usr/local/lib/geodineum/bootstrap-loader.sh
    install -d -m 0755 -o root -g root /usr/local/lib/geodineum
    install -m 0755 -o root -g root \
        "${SCRIPT_DIR}/lib/bootstrap-loader.sh" \
        /usr/local/lib/geodineum/bootstrap-loader.sh
    log_success "Installed bootstrap-loader.sh to /usr/local/lib/geodineum/"

    # ── 2. Source the loader ──────────────────────────────────────────────
    # shellcheck source=/usr/local/lib/geodineum/bootstrap-loader.sh
    source /usr/local/lib/geodineum/bootstrap-loader.sh

    # ── 3. Create directory structure ──────────────────────────────────────
    # Only paths that did not exist are tracked, so a rollback leaves earlier installs alone.
    track_path_if_new /etc/geodineum
    track_path_if_new /etc/geodineum/components
    track_path_if_new /etc/geodineum/components/gnode-daemon
    track_path_if_new /etc/geodineum/components/gnode-daemon/nodes
    if has_gcore "${resolved[@]}"; then
        track_path_if_new /etc/geodineum/components/gCore
        track_path_if_new /etc/geodineum/sites
    fi

    # ── 3a. gnode user and geodineum group, before any install -d that chowns to them
    if ! id -u gnode &>/dev/null; then
        getent group gnode &>/dev/null || groupadd --system gnode
        useradd --system --gid gnode --home-dir /opt/geodineum \
            --no-create-home --shell /usr/sbin/nologin gnode
        if ! id -u gnode &>/dev/null; then
            log_error "Failed to create gnode system user"
            log_info "Create manually: sudo useradd --system --gid gnode gnode"
            exit 1
        fi
        log_success "Created gnode system user"
    fi

    if ! getent group geodineum &>/dev/null; then
        groupadd --system geodineum
        log_success "Created geodineum group"
    fi

    # ── 3b. Directories with ownership
    install -d -m 0751 -o root  -g geodineum /etc/geodineum
    install -d -m 0750 -o gnode -g "$(_components_group)"    /etc/geodineum/components
    install -d -m 0750 -o gnode -g "$(_components_group)"    /etc/geodineum/components/gnode-daemon
    install -d -m 0750 -o gnode -g "$(_components_group)"    /etc/geodineum/components/gnode-daemon/nodes
    if has_gcore "${resolved[@]}"; then
        install -d -m 0750 -o gnode -g "$(_components_group)"    /etc/geodineum/components/gCore
        install -d -m 0750 -o gnode -g www-data /etc/geodineum/sites
    fi

    local deploy_user="${SUDO_USER:-$(whoami)}"

    # www-data joins only geodineum-dash: PHP can read the read-only dashboard token, never other credentials.
    id -u gnode    &>/dev/null && true   # gnode in gnode primary only
    [[ "${DEPLOY_TIER:-}" == compute || "${DEPLOY_TIER:-}" == replica ]] || { id -u www-data &>/dev/null && usermod -aG geodineum-dash www-data 2>/dev/null || true; }
    id -u "$deploy_user" &>/dev/null && usermod -aG geodineum-creds "$deploy_user" 2>/dev/null || true
    id -u "$deploy_user" &>/dev/null && usermod -aG geodineum-dash  "$deploy_user" 2>/dev/null || true
    # gnode reads the admin credential for ACL work and rotates the dashboard token.
    id -u gnode &>/dev/null && usermod -aG geodineum-creds gnode 2>/dev/null || true
    id -u gnode &>/dev/null && usermod -aG geodineum-dash  gnode 2>/dev/null || true
    # The daemon reads bootstrap.env at start; the gnode user only exists from this phase on.
    id -u gnode &>/dev/null && usermod -aG geodineum-bootstrap gnode 2>/dev/null || true
    log_success "Group memberships:"
    log_detail "  gnode:           gnode (daemon-only)"
    log_detail "  geodineum-creds: gnode, ${deploy_user} (daemon + admin creds)"
    log_detail "  geodineum-dash:  gnode, www-data, ${deploy_user} (dashboard token)"
    log_detail "  geodineum-bootstrap: gnode (reads bootstrap.env at daemon start)"

    track_path_if_new /etc/geodineum/credentials
    install -d -m 0750 -o root -g geodineum-creds /etc/geodineum/credentials

    # Master ValKey credentials pasted during a join install; on a worker nothing else writes them.
    if [[ -n "${CONSTELLATION_DAEMON_PW:-}" ]]; then
        printf '%s' "$CONSTELLATION_DAEMON_PW" > /etc/geodineum/credentials/valkey_daemon.password
        chown gnode:geodineum-creds /etc/geodineum/credentials/valkey_daemon.password 2>/dev/null || true
        chmod 0640 /etc/geodineum/credentials/valkey_daemon.password
        log_success "Wrote master daemon credential (from join wizard)"
    fi
    if [[ -n "${CONSTELLATION_REPLICA_PW:-}" ]]; then
        printf '%s' "$CONSTELLATION_REPLICA_PW" > /etc/geodineum/credentials/valkey_replica.password
        chown gnode:geodineum-creds /etc/geodineum/credentials/valkey_replica.password 2>/dev/null || true
        chmod 0640 /etc/geodineum/credentials/valkey_replica.password
        log_success "Wrote master replica credential (from join wizard)"
    fi
    # This node's own ValKey identity from the master's `expand`, kept apart from the shared daemon login.
    if [[ -n "${CONSTELLATION_NODE_USER:-}" ]] && [[ -n "${CONSTELLATION_NODE_PW:-}" ]]; then
        printf '%s' "$CONSTELLATION_NODE_PW" > /etc/geodineum/credentials/valkey_node.password
        chown gnode:geodineum-creds /etc/geodineum/credentials/valkey_node.password 2>/dev/null || true
        chmod 0640 /etc/geodineum/credentials/valkey_node.password
        printf 'VALKEY_NODE_USER=%s\n' "$CONSTELLATION_NODE_USER" \
            > /etc/geodineum/components/gnode-daemon/node-identity.env
        chown root:gnode /etc/geodineum/components/gnode-daemon/node-identity.env 2>/dev/null || true
        chmod 0640 /etc/geodineum/components/gnode-daemon/node-identity.env
        log_success "Wrote per-node ValKey identity: ${CONSTELLATION_NODE_USER}"
    fi

    track_path_if_new /etc/geodineum/dashboard
    # The only credentials www-data can read live here, apart from credentials/.
    install -d -m 0750 -o root -g geodineum-dash /etc/geodineum/dashboard

    # ── 5. Resolve operator-supplied config values ────────────────────────
    local cfg_valkey_host="${VALKEY_HOST:-127.0.0.1}"
    local cfg_valkey_port="${VALKEY_PORT:-47445}"
    local cfg_valkey_creds_path="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"

    # ── 6. Tier 1: bootstrap.env on disk ──────────────────────────────────
    write_disk_bootstrap "$cfg_valkey_host" "$cfg_valkey_port" "$cfg_valkey_creds_path"
    log_success "Wrote /etc/geodineum/bootstrap.env (root:geodineum-bootstrap 0640, 3 strict keys)"

    # ── 7. Tier 2: config in ValKey ────────────────────────────────────────
    if [[ ! "${GNODE_TOPOLOGY_NAMESPACE:-geodineum}" =~ ^[a-z][a-z0-9_]{1,31}$ ]]; then
        log_error "Constellation name '${GNODE_TOPOLOGY_NAMESPACE}' is invalid: lowercase letter first, then a-z, 0-9, _ (2-32 characters)"
        exit 1
    fi
    if [[ -r "${cfg_valkey_creds_path}/valkey.password" ]]; then
        load_bootstrap_disk_tier
        if populate_valkey_tier <<EOF
GEODINEUM_CONFIG_ROOT=/etc/geodineum
GEODINEUM_CREDENTIALS_DIR=${cfg_valkey_creds_path}
GEODINEUM_COMPONENTS_DIR=/etc/geodineum/components
GEODINEUM_SITES_DIR=/etc/geodineum/sites
GEODINEUM_LOG_DIR=${GEODINEUM_LOG_DIR:-/var/log/geodineum}
GNODE_DIR=${GNODE_DIR:-/opt/geodineum/gNode}
GNODE_CLIENT_DIR=${GNODE_CLIENT_DIR:-/opt/geodineum/gNode-Client}
GCORE_DIR=${GCORE_DIR:-/opt/geodineum/gCore}
GCUBE_DIR=${GCUBE_DIR:-/opt/geodineum/gCube}
GNODE_DAEMON_BIN=${GNODE_DAEMON_BIN:-/opt/geodineum/gNode/daemon/target/release/gnode-daemon}
GNODE_FUNCTIONS_DIR=${GNODE_FUNCTIONS_DIR:-/opt/geodineum/gNode/daemon/functions}
GNODE_SCRIPTS_DIR=${GNODE_SCRIPTS_DIR:-/opt/geodineum/gNode/scripts}
GNODE_TOPOLOGY_NAMESPACE=${GNODE_TOPOLOGY_NAMESPACE:-geodineum}
GNODE_CONSTELLATIONS=${GNODE_CONSTELLATIONS:-${GNODE_TOPOLOGY_NAMESPACE:-geodineum}}
GNODE_STREAM_PREFIX=${GNODE_STREAM_PREFIX:-gnode}
GNODE_DEFAULT_ENVIRONMENT=${GNODE_DEFAULT_ENVIRONMENT:-production}
GNODE_LOG_LEVEL=${GNODE_LOG_LEVEL:-info}
GNODE_DEBUG=${GNODE_DEBUG:-false}
${CONSTELLATION_MASTER_IP:+CONSTELLATION_MASTER_IP=${CONSTELLATION_MASTER_IP}}
${CONSTELLATION_MASTER_PORT:+CONSTELLATION_MASTER_PORT=${CONSTELLATION_MASTER_PORT}}
${CONSTELLATION_MASTER_PASSWORD_FILE:+CONSTELLATION_MASTER_PASSWORD_FILE=${CONSTELLATION_MASTER_PASSWORD_FILE}}
EOF
        then
            log_success "Populated ValKey tier (geodineum:bootstrap:*) — re-run install.sh to update"
        else
            log_warning "ValKey tier population failed — re-run install.sh after ACL setup completes"
        fi
    elif [[ "$SKIP_LOCAL_VALKEY" == "true" ]]; then
        log_info "Worker node (remote ValKey) — tier population already done on the master; skipping"
    else
        log_warning "Admin ValKey password not yet readable at ${cfg_valkey_creds_path}/valkey.password"
        log_warning "Skipping ValKey tier population — re-run install.sh after credentials are in place"
    fi

    # ── 8. Component-specific gcore.env ───────────────────────────────────
    if has_gcore "${resolved[@]}" && [[ ! -f /etc/geodineum/components/gCore/gcore.env ]]; then
        cat > /etc/geodineum/components/gCore/gcore.env << 'GCEOF'
# gCore Component Configuration
# ==============================
# PUBLIC (640) — loaded by gCore bootstrap.php via putenv()
# NO SECRETS in this file.

GCORE_BASE_PATH="/opt/geodineum/gCore"
GCORE_LOG_PATH="/var/log/geodineum/gcore"
GCORE_CACHE_PATH="/var/cache/geodineum/gcore"
GCORE_DEBUG="false"
GCORE_DISPLAY_ERRORS="false"
GCORE_CACHE_TTL="3600"
GCORE_CACHE_DRIVER="valkey"
GCEOF
        chown gnode:www-data /etc/geodineum/components/gCore/gcore.env
        chmod 640 /etc/geodineum/components/gCore/gcore.env
    fi

    CONFIG_EXISTS=true
    log_success "/etc/geodineum/ configured (disk-minimal + ValKey-resident model)"
}

# =============================================================================
# Apache hardening
# =============================================================================

# mod_security2 with the OWASP Core Rule Set, no version disclosure, request limits.
ensure_apache_hardened() {
    if ! /usr/bin/command -v apache2 >/dev/null 2>&1; then
        return 0  # No Apache, nothing to harden
    fi

    log_info "Hardening Apache (mod_security2 + information-leak defaults)"

    if ! /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' libapache2-mod-security2 2>/dev/null | grep -q '^ii'; then
        log_detail "Installing libapache2-mod-security2 + modsecurity-crs"
        /usr/bin/apt-get install -y -qq libapache2-mod-security2 modsecurity-crs >/dev/null 2>&1 \
            || log_warning "mod_security2 apt install had issues — continuing without WAF"
    else
        log_detail "mod_security2 already installed"
    fi

    if [[ -f /etc/modsecurity/modsecurity.conf-recommended ]] && [[ ! -f /etc/modsecurity/modsecurity.conf ]]; then
        /usr/bin/cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
        # DetectionOnly until the operator has reviewed /var/log/apache2/modsec_audit.log.
        /usr/bin/sed -i 's|^SecRuleEngine DetectionOnly|SecRuleEngine DetectionOnly|;
                         s|^SecRuleEngine On|SecRuleEngine DetectionOnly|' \
                         /etc/modsecurity/modsecurity.conf
        log_detail "Initialized modsecurity.conf (SecRuleEngine DetectionOnly — review then flip to On)"
    fi

    cat > /etc/apache2/conf-available/geodineum-harden.conf <<'HARDEN_EOF'
# Geodineum Apache hardening 
# Information-leak suppression + request limits.
# Disable: sudo a2disconf geodineum-harden && systemctl reload apache2
# Enable:  sudo a2enconf geodineum-harden && systemctl reload apache2

# Stop advertising Apache version + OS in Server header and error pages.
ServerTokens Prod
ServerSignature Off

# Disable HTTP TRACE method (cross-site tracing attack vector).
TraceEnable Off

# Limit request body size (10 MB — fits WP media uploads, blocks
# slow-large-POST DoS). Operators with bigger upload needs override here.
LimitRequestBody 10485760

# Connection timeouts — kill slow-loris-style attacks.
Timeout 60
KeepAliveTimeout 5

# Disable directory listing site-wide (any explicit Options +Indexes wins).
<Directory />
    Options -Indexes
</Directory>
HARDEN_EOF

    # CRS rules 921110 and 932130 fire on legitimate wp-admin saves; the CRS WordPress package does not exclude them.
    cat > /etc/apache2/conf-available/modsecurity-wp-exclusions.conf <<'WPEXCL_EOF'
# ModSecurity OWASP CRS exclusions for the authenticated WordPress admin.
# Scoped to /wp-admin/ (auth-gated) so the CMS editor can save content without
# tripping protocol/RCE false-positives. Each line is a confirmed false-positive
# on a legitimate post.php save; keep the list minimal and justified.
<LocationMatch "/wp-admin/">
  SecRuleRemoveById 932130
  SecRuleRemoveById 921110
</LocationMatch>
# REST API (pretty-permalink form). The same protocol false-positives
# (HTTP-smuggling 921110, shell-expression 932130) fire on legitimate REST
# requests — JSON bodies and nested resource paths — pushing the anomaly score
# to a 403 and silently half-loading dashboards. SQLi/XSS/RCE stay ON.
<LocationMatch "/wp-json/">
  SecRuleRemoveById 932130
  SecRuleRemoveById 921110
</LocationMatch>
WPEXCL_EOF

    # The package's mod_evasive defaults read one HTTP/2 page load as a DoS; conf-enabled overrides them.
    cat > /etc/apache2/conf-available/geodineum-evasive.conf <<'EVASIVE_EOF'
<IfModule mod_evasive20.c>
    DOSPageCount        30
    DOSSiteCount        300
    DOSPageInterval     1
    DOSSiteInterval     1
    DOSBlockingPeriod   60
    DOSWhitelist        127.0.0.1
    DOSWhitelist        ::1
</IfModule>
EVASIVE_EOF

    /usr/sbin/a2enconf geodineum-harden >/dev/null 2>&1 || true
    /usr/sbin/a2enconf modsecurity-wp-exclusions >/dev/null 2>&1 || true
    /usr/sbin/a2enconf geodineum-evasive >/dev/null 2>&1 || true
    /usr/sbin/a2enmod security2 >/dev/null 2>&1 || true

    if /usr/sbin/apachectl configtest >/dev/null 2>&1; then
        /usr/bin/systemctl reload apache2 >/dev/null 2>&1
        log_success "Apache hardened (mod_security2 in DetectionOnly + info-leak suppression)"
    else
        log_warning "Apache config test failed — NOT reloading. Review:"
        /usr/sbin/apachectl configtest 2>&1 | sed 's/^/    /'
        log_info "Disable the hardening: sudo a2disconf geodineum-harden"
    fi
}

# Serve PHP from a dedicated FPM pool under mpm_event with HTTP/2; mod_php would pin Apache to prefork.
# Undo: a2dismod mpm_event && a2enmod mpm_prefork && systemctl restart apache2
ensure_php_fpm() {
    /usr/bin/command -v apache2 >/dev/null 2>&1 || return 0

    local phpv
    phpv=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null) || true
    if [[ -z "$phpv" ]]; then
        log_warning "PHP not found — skipping PHP-FPM setup"
        return 0
    fi

    log_info "Configuring PHP-FPM ${phpv} + mpm_event"

    if ! /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "php${phpv}-fpm" 2>/dev/null | grep -q '^ii'; then
        log_detail "Installing php${phpv}-fpm"
        /usr/bin/apt-get install -y -qq "php${phpv}-fpm" >/dev/null 2>&1 || {
            log_warning "php${phpv}-fpm install failed — keeping current PHP handler"
            return 0
        }
    fi
    /usr/bin/apt-get install -y -qq "php${phpv}-opcache" php-apcu >/dev/null 2>&1 || true
    /usr/sbin/phpenmod -v "$phpv" -s fpm opcache apcu 2>/dev/null || true

    local slowlog="/var/log/php${phpv}-fpm-geodineum-slow.log"
    [[ -f "$slowlog" ]] || /usr/bin/install -m 0640 -o root -g adm /dev/null "$slowlog" 2>/dev/null || true
    cat > "/etc/php/${phpv}/fpm/pool.d/geodineum.conf" <<POOL_EOF
[geodineum]
user = www-data
group = www-data
listen = /run/php/geodineum-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 40
pm.start_servers = 8
pm.min_spare_servers = 4
pm.max_spare_servers = 12
pm.max_requests = 500
; a request pinned on a dead backend dies here instead of holding a
; worker hostage; anything slower than 15s leaves a stack in the slowlog
request_terminate_timeout = 30s
request_slowlog_timeout = 15s
slowlog = ${slowlog}
pm.status_path = /fpm-status
POOL_EOF

    # Cache sizing is per-SAPI: CLI ini never reaches the pool.
    cat > "/etc/php/${phpv}/fpm/conf.d/95-geodineum.ini" <<'FPMINI_EOF'
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.jit=off
opcache.jit_buffer_size=0
apc.shm_size=128M
FPMINI_EOF

    # ProxySet timeout outlives request_terminate_timeout so FPM's kill fires first.
    cat > /etc/apache2/conf-available/geodineum-php-fpm.conf <<'FPMCONF_EOF'
<IfModule proxy_fcgi_module>
    <IfModule setenvif_module>
        SetEnvIfNoCase ^Authorization$ "(.+)" HTTP_AUTHORIZATION=$1
    </IfModule>
    <FilesMatch "\.ph(?:ar|p|tml)$">
        SetHandler "proxy:unix:/run/php/geodineum-fpm.sock|fcgi://localhost"
    </FilesMatch>
    <Proxy "unix:/run/php/geodineum-fpm.sock|fcgi://localhost">
        ProxySet timeout=35
    </Proxy>
    <FilesMatch "\.phps$">
        Require all denied
    </FilesMatch>
    <FilesMatch "^\.ph(?:ar|p|ps|tml)$">
        Require all denied
    </FilesMatch>
</IfModule>
FPMCONF_EOF

    # Overrides the package's mpm_event.conf without editing it.
    cat > /etc/apache2/conf-available/geodineum-mpm.conf <<'MPM_EOF'
<IfModule mpm_event_module>
    StartServers            3
    ServerLimit             8
    ThreadsPerChild         64
    ThreadLimit             64
    MaxRequestWorkers       512
    MinSpareThreads         64
    MaxSpareThreads         192
    MaxConnectionsPerChild  0
</IfModule>
<IfModule http2_module>
    Protocols h2 http/1.1
</IfModule>
MPM_EOF

    /usr/sbin/a2enmod proxy proxy_fcgi setenvif http2 >/dev/null 2>&1 || true
    /usr/sbin/a2enconf geodineum-php-fpm geodineum-mpm >/dev/null 2>&1 || true
    # The stock handler confs target the www pool and would win the handler merge.
    local stock_conf
    for stock_conf in /etc/apache2/conf-enabled/php*-fpm.conf; do
        [[ -e "$stock_conf" ]] || continue
        /usr/sbin/a2disconf "$(basename "$stock_conf" .conf)" >/dev/null 2>&1 || true
    done

    # Both pools stay up through the Apache switch.
    if ! "/usr/sbin/php-fpm${phpv}" -t >/dev/null 2>&1; then
        log_warning "php-fpm config test FAILED — removing geodineum pool, keeping stock handler"
        rm -f "/etc/php/${phpv}/fpm/pool.d/geodineum.conf"
        /usr/sbin/a2disconf geodineum-php-fpm >/dev/null 2>&1 || true
        /usr/sbin/a2enconf "php${phpv}-fpm" >/dev/null 2>&1 || true
        return 0
    fi
    systemctl enable "php${phpv}-fpm" >/dev/null 2>&1 || true
    systemctl restart "php${phpv}-fpm" >/dev/null 2>&1 || true

    local mod
    for mod in /etc/apache2/mods-enabled/php*.load; do
        [[ -e "$mod" ]] || continue
        /usr/sbin/a2dismod "$(basename "$mod" .load)" >/dev/null 2>&1 || true
    done
    if [[ -e /etc/apache2/mods-enabled/mpm_prefork.load ]]; then
        /usr/sbin/a2dismod mpm_prefork >/dev/null 2>&1 || true
        /usr/sbin/a2enmod mpm_event >/dev/null 2>&1 || true
    fi

    if /usr/sbin/apachectl configtest >/dev/null 2>&1; then
        systemctl restart apache2 >/dev/null 2>&1 || true
        # Only now has Apache stopped using the stock www pool.
        if [[ -f "/etc/php/${phpv}/fpm/pool.d/www.conf" ]]; then
            mv "/etc/php/${phpv}/fpm/pool.d/www.conf" \
               "/etc/php/${phpv}/fpm/pool.d/www.conf.disabled-by-geodineum" 2>/dev/null || true
            systemctl reload "php${phpv}-fpm" >/dev/null 2>&1 || true
        fi
        log_success "PHP-FPM ${phpv} pool active under mpm_event (HTTP/2 on)"
    else
        log_warning "Apache configtest failed after MPM swap — reverting to prefork"
        /usr/sbin/a2dismod mpm_event >/dev/null 2>&1 || true
        /usr/sbin/a2enmod mpm_prefork >/dev/null 2>&1 || true
        if /usr/sbin/apachectl configtest >/dev/null 2>&1; then
            systemctl restart apache2 >/dev/null 2>&1 || true
            log_info "Reverted: prefork + PHP-FPM (PHP still served; no HTTP/2). Review: apachectl configtest"
        else
            log_error "Apache configtest still failing — manual intervention required (apachectl configtest)"
        fi
    fi
}

# =============================================================================
# PHASE 8: Service Installation
# =============================================================================

phase_services() {
    local resolved=($@)
    local rc=0

    log_step "Phase 8/10: Service Installation"

    if [[ "$DRY_RUN" == "true" ]]; then
        if needs_daemon "${resolved[@]}"; then
            log_dry "Install gnode-daemon systemd service"
            log_dry "Set file permissions (gnode:gnode 750/640)"
        fi
        return
    fi

    if ! needs_daemon "${resolved[@]}"; then
        log_info "No daemon in this profile — skipping service setup"
        return
    fi

    # geodeploy.sh is the single authority for permissions.
    local geodeploy_lib="${INSTALL_ROOT}/Geodineum/lib/geodeploy.sh"
    if [[ -f "$geodeploy_lib" ]]; then
        GEODEPLOY_DEPLOY_USER="${DEPLOY_USER}"
        source "$geodeploy_lib"
        log_success "Loaded geodeploy permission library"
    else
        log_warning "geodeploy.sh not found at ${geodeploy_lib} — using inline fallback"
    fi

    log_info "Setting permissions per narrow-group model"

    # Fallback without geodeploy.sh: files 0640, scripts, binaries and shebang files 0750.
    __chmod_files_by_kind() {
        local root="$1"
        find "$root" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" \) -prune -o \
                     -type f -print0 2>/dev/null | xargs -0 chmod 0640 2>/dev/null
        find "$root" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" \) \
                     -exec chmod 0750 {} \; 2>/dev/null
        if [[ -d "$root/daemon/target/release" ]]; then
            find "$root/daemon/target/release" -maxdepth 1 -type f -executable \
                 -exec chmod 0750 {} \; 2>/dev/null
        fi
        if [[ -d "$root/target/release" ]]; then
            find "$root/target/release" -maxdepth 1 -type f -executable \
                 -exec chmod 0750 {} \; 2>/dev/null
        fi
        find "$root" -type f -not -name "*.sh" -not -name "*.bash" -not -name "*.py" \
             -not -path "*/.git/*" -not -path "*/target/*" \
             -exec sh -c 'head -c 2 "$1" 2>/dev/null | grep -q "^#!" && chmod 0750 "$1"' _ {} \; 2>/dev/null
    }

    for repo_dir in gNode Geodineum-BAK; do
        if [[ -d "${INSTALL_ROOT}/${repo_dir}" ]]; then
            if type geodeploy_fix_perms &>/dev/null; then
                geodeploy_fix_perms "${INSTALL_ROOT}/${repo_dir}" "${DEPLOY_USER}" "gnode"
                geodeploy_fix_binaries "${INSTALL_ROOT}/${repo_dir}" "$repo_dir"
            else
                chown -R "${DEPLOY_USER}:gnode" "${INSTALL_ROOT}/${repo_dir}"
                find "${INSTALL_ROOT}/${repo_dir}" -type d -exec chmod 2750 {} \;
                __chmod_files_by_kind "${INSTALL_ROOT}/${repo_dir}"
            fi
        fi
    done

    # COMMS has its own group; only its runtime-writable dirs belong to the service user.
    if [[ -d "${INSTALL_ROOT}/Geodineum-COMMS" ]]; then
        if type geodeploy_fix_perms &>/dev/null; then
            geodeploy_fix_perms "${INSTALL_ROOT}/Geodineum-COMMS" "${DEPLOY_USER}" "geodineum-comms"
            geodeploy_fix_binaries "${INSTALL_ROOT}/Geodineum-COMMS" "Geodineum-COMMS"
        else
            chown -R "${DEPLOY_USER}:geodineum-comms" "${INSTALL_ROOT}/Geodineum-COMMS"
            find "${INSTALL_ROOT}/Geodineum-COMMS" -type d -exec chmod 2750 {} \;
            __chmod_files_by_kind "${INSTALL_ROOT}/Geodineum-COMMS"
        fi
        for rw_dir in .gnode logs; do
            mkdir -p "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
            chown -R geodineum-comms:geodineum-comms "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
            chmod 2750 "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
        done
    fi

    if [[ -d "${INSTALL_ROOT}/Geodineum" ]]; then
        if type geodeploy_fix_perms &>/dev/null; then
            geodeploy_fix_perms "${INSTALL_ROOT}/Geodineum" "${DEPLOY_USER}" "geodineum"
        else
            chown -R "${DEPLOY_USER}:geodineum" "${INSTALL_ROOT}/Geodineum"
            find "${INSTALL_ROOT}/Geodineum" -type d -exec chmod 2750 {} \;
            __chmod_files_by_kind "${INSTALL_ROOT}/Geodineum"
        fi
    fi

    # Shared PHP source is group geodineum-code, not www-data, so services read it without joining the web tier.
    local -a wp_dirs=(gCore gTemplate gCube gNode-Client)
    local _cd _cn
    for _cd in "${INSTALL_ROOT}"/*/; do
        _cn="$(basename "$_cd")"
        [[ " ${wp_dirs[*]} " == *" ${_cn} "* ]] && continue
        grep -qE 'group:[[:space:]]*geodineum-code' "${_cd}geodeploy.yaml" 2>/dev/null \
            && wp_dirs+=("$_cn")
    done
    for wp_dir in "${wp_dirs[@]}"; do
        if [[ -d "${INSTALL_ROOT}/${wp_dir}" ]]; then
            if type geodeploy_fix_perms &>/dev/null; then
                geodeploy_fix_perms "${INSTALL_ROOT}/${wp_dir}" "${DEPLOY_USER}" "geodineum-code"
            else
                chown -R "${DEPLOY_USER}:geodineum-code" "${INSTALL_ROOT}/${wp_dir}"
                find "${INSTALL_ROOT}/${wp_dir}" -type d -exec chmod 2750 {} \;
                __chmod_files_by_kind "${INSTALL_ROOT}/${wp_dir}"
            fi
        fi
    done

    unset -f __chmod_files_by_kind
    log_success "Component permissions set per narrow-group model"

    log_info "Setting up centralized logs at /var/log/geodineum/..."
    track_path_if_new /var/log/geodineum
    for log_dir in gnode comms gcore gcore/sites apache wordpress themes valkey bak deploy; do
        track_path_if_new "/var/log/geodineum/${log_dir}"
        mkdir -p "/var/log/geodineum/${log_dir}"
    done
    if type geodeploy_fix_log_perms &>/dev/null; then
        geodeploy_fix_log_perms "/var/log/geodineum"
    fi
    log_success "Log directories created with correct ownership"

    if type geodeploy_fix_all_credentials &>/dev/null; then
        geodeploy_fix_all_credentials "/etc/geodineum/credentials"
        log_success "Credential ownership set (<runtime_user>:<runtime_user> 600)"
    fi

    # On a fresh install the gNode tree did not exist yet when Phase 4 tried this.
    ensure_daemon_credential_symlink

    local service_script="${GNODE_SCRIPTS}/install-gnode-service.sh"
    if [[ -x "$service_script" ]]; then
        log_info "Installing gNode systemd service..."
        # The node id must be unique and survive role changes, so it is never a role like "master".
        if [[ -z "$GNODE_NODE_ID" ]]; then
            GNODE_NODE_ID="$(hostname -s 2>/dev/null || echo unknown-node)"
            log_info "Node ID defaulted to ${GNODE_NODE_ID} (short hostname)"
        fi
        export GNODE_NODE_ID GNODE_CONSTELLATIONS
        if ! "$service_script"; then
            log_warning "Service installation had issues — see output above"
            rc=1
        fi
    else
        log_warning "install-gnode-service.sh not found — systemd service not installed"
        log_info "Start daemon manually: ${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon"
        rc=1
    fi

    if [[ -x "${INSTALL_ROOT}/Geodineum-COMMS/target/release/geodineum-comms" ]]; then
        local comms_service="/etc/systemd/system/geodineum-comms.service"

        # The daemon writes /var/lib/geodineum-comms; it only reads its root-owned env files.
        mkdir -p /var/lib/geodineum-comms 2>/dev/null || true
        chown -R geodineum-comms:geodineum-comms /var/lib/geodineum-comms 2>/dev/null || true
        chmod 0750 /var/lib/geodineum-comms 2>/dev/null || true
        if [[ -d /etc/geodineum/components/geodineum-comms ]]; then
            chown root:geodineum-comms /etc/geodineum/components/geodineum-comms 2>/dev/null || true
            chmod 0750 /etc/geodineum/components/geodineum-comms 2>/dev/null || true
            find /etc/geodineum/components/geodineum-comms -type f \
                 -exec chown root:geodineum-comms {} \; -exec chmod 0640 {} \; 2>/dev/null || true
        fi

        if [[ -f "${INSTALL_ROOT}/Geodineum-COMMS/config/geodineum-comms.service" ]]; then
            cp "${INSTALL_ROOT}/Geodineum-COMMS/config/geodineum-comms.service" "$comms_service"
            systemctl daemon-reload 2>/dev/null
            systemctl enable geodineum-comms 2>/dev/null && \
                log_success "geodineum-comms service enabled" || \
                log_warning "Could not enable geodineum-comms service"
        else
            log_info "COMMS service file not found — install manually"
        fi
    fi

    if [[ "$HAS_APACHE" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        ensure_apache_hardened
        ensure_php_fpm
    fi

    return $rc
}

# =============================================================================
# PHASE 9: Load Lua Functions
# =============================================================================

phase_functions() {
    local resolved=($@)
    local rc=0

    log_step "Phase 9/10: ValKey Lua Functions"

    if ! needs_daemon "${resolved[@]}"; then
        log_info "No daemon in this profile — skipping Lua function loading"
        return
    fi

    # Before the dry-run branch, so a dry run reports what a real run would do.
    if [[ "$SKIP_LOCAL_VALKEY" == "true" ]]; then
        log_info "Remote ValKey (constellation worker) — function libraries are managed on the master"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Load Lua functions into ValKey (base libraries + extension libraries)"
        return
    fi

    if [[ "$VALKEY_RUNNING" != "true" ]]; then
        log_warning "ValKey not running — cannot load Lua functions now"
        log_info "Load later: ${GNODE_SCRIPTS}/load-valkey-functions.sh"
        return 1
    fi

    local lua_script="${GNODE_SCRIPTS}/load-valkey-functions.sh"
    if [[ -x "$lua_script" ]]; then
        log_info "Loading Lua function libraries..."
        if ! "$lua_script"; then
            log_warning "Function loading had issues — see output above"
            log_info "Retry: ${lua_script}"
            rc=1
        fi
    else
        log_warning "load-valkey-functions.sh not found"
        rc=1
    fi

    # Connection settings go by environment: as flags they would have to precede the subcommand.
    local daemon_bin="${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon"
    if [[ -x "$daemon_bin" ]]; then
        log_info "Registering ecosystem tools in tool topology..."
        local daemon_pass_file="/etc/geodineum/credentials/valkey_daemon.password"
        if [[ -f "$daemon_pass_file" ]]; then
            if GNODE_REDIS_AUTH_FILE="$daemon_pass_file" \
               VALKEY_USER="gnode_daemon" \
               VALKEY_PORT="${VALKEY_PORT:-47445}" \
               "$daemon_bin" register-tools --tier tool; then
                log_success "Ecosystem components registered on the one topology (shape 2)"
            else
                log_warning "Tool registration had issues (see stderr above) — register later: VALKEY_USER=gnode_daemon GNODE_REDIS_AUTH_FILE=${daemon_pass_file} gnode-daemon register-tools --tier tool"
            fi
        else
            log_warning "Daemon password file not found ($daemon_pass_file) — skipping tool registration"
            log_info "Run later: VALKEY_USER=gnode_daemon GNODE_REDIS_AUTH_FILE=${daemon_pass_file} gnode-daemon register-tools --tier tool"
        fi
    fi

    return $rc
}

# =============================================================================
# PHASE 10: Verification
# =============================================================================

phase_verify() {
    local resolved=($@)

    log_step "Phase 10/10: Verification"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run complete — no changes were made"
        return
    fi

    local pass=0
    local fail=0

    for comp in "${resolved[@]}"; do
        local dir="${INSTALL_ROOT}/$(get_install_dir "$comp")"
        if [[ -d "$dir" ]]; then
            log_success "${comp} installed at ${dir}"
            ((pass++))
        else
            log_error "${comp} NOT found at ${dir}"
            ((fail++))
        fi
    done

    # A missing binary fails the Build phase in the summary, whatever the build reported.
    if needs_daemon "${resolved[@]}"; then
        if [[ -x "${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon" ]]; then
            log_success "gNode daemon binary executable"
            ((pass++))
        else
            log_warning "gNode daemon binary not found or not executable"
            ((fail++))
            PHASE_RESULTS["Build"]="FAIL"
        fi
    fi

    if [[ -f "/etc/geodineum/bootstrap.env" ]]; then
        log_success "/etc/geodineum/bootstrap.env exists"
        ((pass++))
    else
        log_warning "/etc/geodineum/bootstrap.env missing"
        ((fail++))
    fi

    # PING live rather than trust VALKEY_RUNNING from Phase 4.
    if needs_daemon "${resolved[@]}"; then
        # Workers have no admin password and a remote ValKey: use the daemon credential and VALKEY_HOST.
        local pwfile_v="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"
        local vk_user_v=""
        if [[ ! -r "$pwfile_v" ]]; then
            pwfile_v="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey_daemon.password"
            vk_user_v="gnode_daemon"
        fi
        local valkey_host_v="${VALKEY_HOST:-127.0.0.1}"
        local valkey_port_v="${VALKEY_PORT:-47445}"
        if [[ -r "$pwfile_v" ]] \
           && REDISCLI_AUTH="$(cat "$pwfile_v")" valkey-cli -h "$valkey_host_v" -p "$valkey_port_v" \
                ${vk_user_v:+--user "$vk_user_v"} PING 2>/dev/null \
              | grep -q '^PONG$'; then
            log_success "ValKey reachable (live PING → PONG @ ${valkey_host_v}:${valkey_port_v}${vk_user_v:+ as ${vk_user_v}})"
            ((pass++))
        else
            log_warning "ValKey not reachable (live PING @ ${valkey_host_v}:${valkey_port_v} failed)"
            ((fail++))
            PHASE_RESULTS["ValKey Setup"]="FAIL"
        fi
    fi

    if needs_daemon "${resolved[@]}" && [[ "$HAS_SYSTEMD" == "true" ]]; then
        if systemctl is-enabled --quiet gnode-daemon 2>/dev/null; then
            log_success "gnode-daemon service enabled"
            ((pass++))
        else
            log_warning "gnode-daemon service not enabled"
        fi
    fi

    local validate="${GNODE_SCRIPTS}/validate-geodineum-config.sh"
    if [[ -x "$validate" ]] && [[ "$CONFIG_EXISTS" == "true" ]]; then
        log_info "Running configuration validation..."
        if "$validate"; then
            log_success "Configuration validation passed"
            ((pass++))
        else
            log_warning "Configuration validation found issues (see output above)"
            log_info "Re-run with --fix to auto-correct: ${validate} --fix"
        fi
    fi

    echo ""
    log_info "Verification: ${pass} passed, ${fail} failed"
}

# =============================================================================
# Summary
# =============================================================================

# Extension load status from the schemas the daemon publishes; falls back to what is on disk.
print_cog_load_status() {
    local cms_path="${GNODE_EXT_CMS_PATH:-/opt/geodineum/pro/gNode/gNode-CMS}"
    local schemas=""

    local _cli=""
    if command -v valkey-cli >/dev/null 2>&1; then
        _cli="valkey-cli"
    elif command -v redis-cli >/dev/null 2>&1; then
        _cli="redis-cli"
    fi
    if [[ -n "$_cli" ]]; then
        schemas=$("$_cli" --no-auth-warning SMEMBERS geodineum:config_schema:_index 2>/dev/null || echo "")
    fi

    echo ""
    echo -e "  ${BOLD}Cog-load status (extension discovery):${NC}"
    echo -e "    ${DIM}┌─────────────┬──────────┬──────────────────────────────────┐${NC}"
    echo -e "    ${DIM}│${NC} ${BOLD}Extension${NC}   ${DIM}│${NC} ${BOLD}Status${NC}   ${DIM}│${NC} ${BOLD}Notes${NC}                            ${DIM}│${NC}"
    echo -e "    ${DIM}├─────────────┼──────────┼──────────────────────────────────┤${NC}"

    if echo "$schemas" | grep -q '^gnode-cms$\|^cms$'; then
        printf "    ${DIM}│${NC} %-11s ${DIM}│${NC} ${GREEN}%-8s${NC} ${DIM}│${NC} %-32s ${DIM}│${NC}\n" "gNode-CMS" "LOADED" "via daemon config_schema discovery"
    elif [[ -d "$cms_path" ]]; then
        printf "    ${DIM}│${NC} %-11s ${DIM}│${NC} ${YELLOW}%-8s${NC} ${DIM}│${NC} %-32s ${DIM}│${NC}\n" "gNode-CMS" "pending" "on disk; daemon not yet started"
    else
        printf "    ${DIM}│${NC} %-11s ${DIM}│${NC} ${DIM}%-8s${NC} ${DIM}│${NC} %-32s ${DIM}│${NC}\n" "gNode-CMS" "skipped" "GNODE_EXT_CMS_PATH not set"
    fi

    echo -e "    ${DIM}└─────────────┴──────────┴──────────────────────────────────┘${NC}"

    if [[ -z "$schemas" ]]; then
        echo -e "    ${DIM}(daemon not yet running — start with: sudo systemctl start gnode-daemon,${NC}"
        echo -e "    ${DIM} then re-query via: valkey-cli SMEMBERS geodineum:config_schema:_index)${NC}"
    fi
}

print_summary() {
    local resolved=($@)

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}          ${BOLD}Installation Complete${NC}                      ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "  ${BOLD}Installed components:${NC}"
    for comp in "${resolved[@]}"; do
        local dir
        dir=$(get_install_dir "$comp")
        if [[ -d "${INSTALL_ROOT}/${dir}" ]]; then
            echo -e "    ${GREEN}●${NC} ${comp} → ${INSTALL_ROOT}/${dir}"
        else
            echo -e "    ${YELLOW}○${NC} ${comp} (pending)"
        fi
    done

    echo ""
    echo "  ${BOLD}Next steps:${NC}"

    if needs_daemon "${resolved[@]}"; then
        if systemctl is-active --quiet gnode-daemon 2>/dev/null; then
            echo "    - Daemon is running. Check: sudo systemctl status gnode-daemon"
        else
            echo "    - Start daemon: sudo systemctl start gnode-daemon"
        fi
        echo "    - Bring a service on: sudo geodineum register   (a new one, or an existing codebase)"
    else
        echo "    - Upgrade to standard for real-time: sudo ./install.sh --profile standard"
    fi

    if [[ -n "$SITE_DOMAIN" ]]; then
        local site_id
        site_id=$(echo "$SITE_DOMAIN" | sed 's/[.-]/_/g')
        echo ""
        echo "  ${BOLD}Site deployment:${NC}"
        echo -e "    ${GREEN}●${NC} https://${SITE_DOMAIN}"
        echo "    Site ID:     ${site_id}"
        echo "    Environment: ${SITE_ENV:-testing}"

        local config_file="/var/www/${SITE_DOMAIN}/wp-config-geodineum.yaml"
        if [[ -r "$config_file" ]] && command -v grep &>/dev/null; then
            local viewkey
            viewkey=$(grep -oP 'viewkey:\s*["\x27]?\K[^"\x27\s]+' "$config_file" 2>/dev/null || echo "")
            if [[ -n "$viewkey" ]]; then
                echo "    Viewkey:     ${viewkey}"
                echo "    Gate URL:    https://${SITE_DOMAIN}/?viewkey=${viewkey}"
            fi
        fi

        local wp_root="/var/www/${SITE_DOMAIN}"
        if [[ -r "${wp_root}/wp-config.php" ]] && command -v wp &>/dev/null; then
            local admin_user
            admin_user=$(sudo -u www-data wp user list --role=administrator --field=user_login --path="$wp_root" 2>/dev/null | head -1)
            if [[ -n "$admin_user" ]]; then
                echo "    WP Admin:    ${admin_user}"
                echo "    WP Login:    https://${SITE_DOMAIN}/wp-admin/"
            fi
        fi

        local pw_file="/etc/geodineum/credentials/valkey_client_${site_id}.password"
        if [[ -r "$pw_file" ]]; then
            echo "    ValKey user:  gnode_client_${site_id}"
            echo "    ValKey port:  ${VALKEY_PORT:-47445}"
        fi

        echo ""
        echo "  ${BOLD}Quick commands:${NC}"
        echo "    geodineum status ${site_id}            # Full site details"
        echo "    geodineum env viewkey ${site_id}     # Show/generate viewkey"
        echo "    geodineum env show ${site_id}        # Environment + gate status"
    fi

    echo ""
    echo "    - Health check: geodineum status --config --verbose"
    if [[ -x /usr/local/bin/geodineum ]]; then
        echo "    - CLI ready: geodineum --help (or: gcli --help)"
    else
        echo "    - CLI install: sudo ln -sf ${INSTALL_ROOT}/Geodineum/geodineum /usr/local/bin/geodineum"
    fi
    echo "    - Documentation: https://github.com/geodineum"

    if [[ ${#PHASE_RESULTS[@]} -gt 0 ]]; then
        echo ""
        echo "  ${BOLD}Phase results:${NC}"
        for phase in "Deploy User" "Detection" "Prerequisites" "ValKey Setup" \
                     "Component Fetch" "Build" "Configuration" "Services" \
                     "Lua Functions" "Verification"; do
            local result="${PHASE_RESULTS[$phase]:-SKIP}"
            case "$result" in
                OK)   echo -e "    ${GREEN}[OK]${NC}   ${phase}" ;;
                FAIL) echo -e "    ${RED}[FAIL]${NC} ${phase}" ;;
                *)    echo -e "    ${DIM}[SKIP]${NC} ${phase}" ;;
            esac
        done
    fi

    print_cog_load_status

    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE:-}" ]]; then
        echo ""
        echo -e "  ${DIM}Full log: ${LOG_FILE}${NC}"
    fi
    echo ""
}

# =============================================================================
# Site reconciliation (reinstall: register each existing site again)
# =============================================================================

reconcile_site_credentials() {
    local cred_dir="${CREDENTIALS_DIR:-/etc/geodineum/credentials}"
    local cli="${INSTALL_ROOT}/Geodineum/geodineum"
    local web_root="${WEB_ROOT:-/var/www}"

    [[ -x "$cli" ]] || cli="$(command -v geodineum 2>/dev/null || true)"
    [[ -n "$cli" ]] || return 0

    # A preserved credentials dir may be 0750, which blocks www-data from its site credentials.
    [[ -d "$cred_dir" ]] && chmod 0751 "$cred_dir" 2>/dev/null || true

    local reconciled=0
    for wp_config in "${web_root}"/*/wp-config.php; do
        [[ -f "$wp_config" ]] || continue

        local site_dir domain site_id
        site_dir="$(dirname "$wp_config")"
        domain="$(basename "$site_dir")"
        site_id="$(echo "$domain" | sed 's/\./_/g')"

        # Skip WordPress installs Geodineum does not manage.
        if [[ ! -f "${site_dir}/wp-config-geodineum.yaml" ]] \
           && [[ ! -d "${site_dir}/.geodineum" ]] \
           && [[ ! -f "${cred_dir}/valkey_client_${site_id}.password" ]]; then
            continue
        fi

        # Registering again keeps the credential and recomposes the grants from the manifest.
        local env=""
        [[ -f "${site_dir}/.geodineum/gnode_services.yaml" ]] && env="$(yq eval '.environment // ""' "${site_dir}/.geodineum/gnode_services.yaml" 2>/dev/null)"
        if [[ -z "$env" || "$env" == null ]]; then
            log_warning "  ${site_id}: no environment in its manifest — re-register by hand: sudo geodineum register ${site_dir} --env <tier>"
            continue
        fi
        log_info "Reconciling site registration: ${site_id}"
        if "$cli" register "$site_dir" --env "$env" --yes >/dev/null 2>&1; then
            reconciled=$((reconciled + 1))
        else
            log_warning "  ${site_id} did not re-register — retry: sudo geodineum register ${site_dir} --env ${env}"
        fi
    done

    if [[ $reconciled -gt 0 ]]; then
        log_success "Reconciled credentials for ${reconciled} existing site(s)"
    fi
    return 0
}

# =============================================================================
# Site deployment for --site
# =============================================================================

# A site keeps its recorded environment; a new one starts gated in testing. A contradicting --env stops the run.
_resolve_site_env() {
    local site_id recorded="" f pw="${CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey.password"
    site_id=$(echo "$SITE_DOMAIN" | sed 's/[.-]/_/g')
    if [[ -r "$pw" ]] && command -v valkey-cli >/dev/null 2>&1; then
        recorded=$(REDISCLI_AUTH="$(<"$pw")" valkey-cli --no-auth-warning --raw -p "${VALKEY_PORT:-47445}" \
            HGET "{${GNODE_TOPOLOGY_NAMESPACE:-geodineum}}:gnode:constellation:env" "$site_id" 2>/dev/null) || recorded=""
    fi
    if [[ -z "$recorded" ]]; then
        for f in "/var/www/${SITE_DOMAIN}/.geodineum/config.yaml" "/var/www/${SITE_DOMAIN}/wp-config-geodineum.yaml"; do
            [[ -r "$f" ]] || continue
            recorded=$(grep -E '^[[:space:]]+active:' "$f" | head -1 | sed -E 's/.*active:[[:space:]]*//; s/["'\'']//g') || recorded=""
            [[ -n "$recorded" ]] && break
        done
    fi
    if [[ -n "$SITE_ENV" && -n "$recorded" && "$SITE_ENV" != "$recorded" ]]; then
        log_error "${SITE_DOMAIN} is registered as ${recorded}; --env ${SITE_ENV} would re-register it. Change it with: sudo geodineum env set ${site_id} ${SITE_ENV}"
        return 1
    fi
    if [[ -z "$SITE_ENV" && -n "$recorded" ]]; then
        SITE_ENV="$recorded"
        log_info "${SITE_DOMAIN}: keeping its recorded environment (${SITE_ENV})"
    elif [[ -z "$SITE_ENV" ]]; then
        SITE_ENV="testing"
        log_info "${SITE_DOMAIN}: new site, environment testing (gated); pass --env to choose another"
    fi
}

deploy_site_if_requested() {
    [[ -n "$SITE_DOMAIN" ]] || return 0
    [[ "$DRY_RUN" != "true" ]] || return 0

    log_step "Site Deployment"
    _resolve_site_env || return 1
    local cli="${INSTALL_ROOT}/Geodineum/geodineum"
    [[ -x "$cli" ]] || cli="$(command -v geodineum 2>/dev/null || true)"
    local -a args=("$SITE_DOMAIN" --new website-wp --env "$SITE_ENV" --yes --no-mail)
    [[ -n "$SITE_THEME" ]] && args+=(--theme "$SITE_THEME")
    if [[ -z "$cli" ]]; then
        log_warning "geodineum CLI not found — deploy later: sudo geodineum register ${args[*]}"
        return 1
    fi
    if "$cli" register "${args[@]}"; then
        log_success "Site deployed and registered: ${SITE_DOMAIN}"
    else
        local rc=$?
        log_error "Site deployment failed for ${SITE_DOMAIN} (exit ${rc}) — re-run: sudo geodineum register ${args[*]}"
        return $rc
    fi
}

# =============================================================================
# Post-install: hand over to `geodineum register`
# =============================================================================

# Sets _CLI to the geodineum CLI path, empty if not found.
_resolve_cli() {
    _CLI="${INSTALL_ROOT}/Geodineum/geodineum"
    [[ -x "$_CLI" ]] || _CLI="$(command -v geodineum 2>/dev/null || true)"
}

# One question; `geodineum register` asks the rest (NEW or INTEGRATE, then the type).
prompt_setup_service() {
    _resolve_cli
    echo ""
    echo -e "  ${BOLD}Register a service on Geodineum now?${NC} ${DIM}(later: sudo geodineum register)${NC}"
    local go; read -p "  [y/N]: " -n 1 go; echo ""
    [[ "$go" =~ ^[Yy]$ ]] || return 0
    if [[ -z "$_CLI" ]]; then
        log_warning "geodineum CLI not found — run later: sudo geodineum register"
        return 0
    fi
    "$_CLI" register || log_warning "Registration did not finish — re-run: sudo geodineum register"
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    banner

    if ! validate_install_root "$INSTALL_ROOT"; then
        log_error "Invalid install root: ${INSTALL_ROOT}"
        exit 1
    fi

    # ── Installation logging ──────────────────────────────────
    # Everything on stdout lands in the log, so phases never print secrets.
    local LOG_DIR="/var/log/geodineum"
    local LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    if [[ "$DRY_RUN" != "true" ]] && [[ -d "$LOG_DIR" ]]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
        log_info "Logging to: ${LOG_FILE}"
    fi

    declare -A PHASE_RESULTS=()

    run_phase() {
        local phase_name="$1"; shift
        local phase_func="$1"; shift
        local fatal="${1:-true}"; shift || true

        if "$phase_func" "$@"; then
            PHASE_RESULTS["$phase_name"]="OK"
        else
            PHASE_RESULTS["$phase_name"]="FAIL"
            if [[ "$fatal" == "true" ]]; then
                log_error "Phase failed (fatal): ${phase_name}"
                return 1
            else
                log_warning "Phase had issues (non-fatal): ${phase_name}"
            fi
        fi
    }

    run_phase "Deploy User" phase_deploy_user true
    run_phase "Detection" phase_detection true

    # The bundle from `geodineum node add` carries tunnel, credentials, constellations, node id and master.
    if [[ -n "$JOIN_BUNDLE" ]]; then
        [[ -r "$JOIN_BUNDLE" ]] || { log_error "--join: cannot read ${JOIN_BUNDLE}"; exit 1; }
        wizard_apply_constellation_bundle "$JOIN_BUNDLE" || { log_error "--join: could not apply ${JOIN_BUNDLE} (see above)"; exit 1; }
        if [[ -z "$DEPLOY_TIER" ]]; then
            [[ "$YES_MODE" == "true" ]] && { log_error "--join --yes needs a tier: pass --deploy-tier, or --tier to 'geodineum node add'"; exit 1; }
            read -r -p "  Tier for this node [web/full/compute/replica, default: compute]: " DEPLOY_TIER
            DEPLOY_TIER="${DEPLOY_TIER:-compute}"
        fi
        shred -u "$JOIN_BUNDLE" 2>/dev/null || rm -f "$JOIN_BUNDLE"
        log_info "Bundle applied and removed from this node"
    fi

    # Sets PROFILE from --deploy-tier, which skips the selection wizard.
    apply_deploy_tier

    if [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]] && [[ -z "$SITE_DOMAIN" ]]; then
        phase_selection
    fi

    if [[ -n "$SITE_DOMAIN" ]] && [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]]; then
        PROFILE="standard"
        log_info "Site deployment requested — using standard profile"
    fi

    local component_list=()
    if [[ -n "$PROFILE" ]]; then
        component_list=($(get_profile_components "$PROFILE"))
    fi
    if [[ -n "$COMPONENTS" ]]; then
        IFS=',' read -ra extra <<< "$COMPONENTS"
        component_list+=("${extra[@]}")
    fi
    if [[ -n "$SITE_THEME" ]]; then
        component_list+=("$SITE_THEME")
    fi

    if [[ "$WITH_COMMS" != "true" ]]; then
        local _filtered=()
        for _c in "${component_list[@]}"; do
            [[ "$_c" == "geodineum-comms" ]] && continue
            _filtered+=("$_c")
        done
        component_list=("${_filtered[@]}")
        log_info "Geodineum-COMMS excluded (--no-comms / wizard opt-out)"
    fi

    local resolved
    resolved=($(resolve_dependencies "${component_list[@]}"))

    if [[ ${#resolved[@]} -eq 0 ]]; then
        log_error "No components to install"
        exit 1
    fi

    log_step "Installation Plan"
    echo ""
    printf "  ${BOLD}%-22s %-32s %s${NC}\n" "COMPONENT" "REPOSITORY" "STATUS"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${NC}"
    for comp in "${resolved[@]}"; do
        local repo
        repo=$(get_repo "$comp")
        local dir
        dir=$(get_install_dir "$comp")
        local status="clone"
        [[ -d "${INSTALL_ROOT}/${dir}/.git" ]] && status="update"
        printf "  %-22s %-32s %s\n" "$comp" "$repo" "[${status}]"
    done
    echo ""

    local valkey_note=""
    for comp in "${resolved[@]}"; do
        case "$comp" in
            gnode-daemon|gnode-client)
                if [[ "$VALKEY_RUNNING" == "true" ]]; then
                    valkey_note="ValKey: running"
                elif [[ "$HAS_VALKEY" == "true" ]]; then
                    valkey_note="ValKey: installed (will configure)"
                else
                    valkey_note="ValKey: will install"
                fi
                break
                ;;
        esac
    done
    [[ -n "$valkey_note" ]] && echo -e "  ${DIM}${valkey_note}${NC}" && echo ""

    if [[ -n "$SITE_DOMAIN" ]]; then
        echo -e "  ${BOLD}Site deployment:${NC} ${SITE_DOMAIN} (theme: ${SITE_THEME:-gtemplate-wp}, env: ${SITE_ENV:-as recorded, or testing if new})"
        echo ""
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run mode — showing what would happen"
        echo ""
    elif ! confirm "Proceed with installation?"; then
        log_info "Cancelled"
        exit 0
    fi

    # ── Rollback on fatal failure ────────────────────────────
    # Removes only what this run created; prerequisites (apt, Rust, PHP) stay for the retry.
    INSTALLED_REPOS=()
    INSTALLED_SERVICES=()
    INSTALLED_PATHS=()

    # Call before creating the path: it is tracked only if it does not exist yet.
    track_path_if_new() {
        local p="$1"
        [[ -z "$p" ]] && return 0
        [[ "${DRY_RUN:-false}" == "true" ]] && return 0
        [[ -e "$p" ]] || INSTALLED_PATHS+=("$p")
    }

    rollback() {
        echo ""
        log_error "Installation failed — rolling back geodineum components"
        log_info "Prerequisites (apt, Rust, PHP) are preserved for retry"
        echo ""

        # Services first, so they release the paths removed below.
        for svc in "${INSTALLED_SERVICES[@]}"; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                log_info "Disabling: ${svc}"
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
            fi
            rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}.timer" 2>/dev/null
        done
        [[ ${#INSTALLED_SERVICES[@]} -gt 0 ]] && systemctl daemon-reload 2>/dev/null || true

        if crontab -l 2>/dev/null | grep -q "auto-deploy.sh"; then
            log_info "Removing auto-deploy cron entry"
            crontab -l 2>/dev/null | grep -v "auto-deploy.sh" | crontab - 2>/dev/null || true
        fi

        for repo_dir in "${INSTALLED_REPOS[@]}"; do
            if [[ -d "$repo_dir" ]]; then
                log_info "Removing: ${repo_dir}"
                rm -rf "$repo_dir"
            fi
        done

        # Reverse order: children before their parents.
        local _idx _p
        for (( _idx=${#INSTALLED_PATHS[@]}-1 ; _idx>=0 ; _idx-- )); do
            _p="${INSTALLED_PATHS[$_idx]}"
            if [[ -e "$_p" ]]; then
                log_info "Removing: ${_p}"
                rm -rf "$_p"
            fi
        done

        rm -f /usr/local/bin/geodineum /usr/local/bin/gcli 2>/dev/null

        echo ""
        log_info "Rollback complete. Re-run: sudo ./install.sh"
        if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE:-}" ]]; then
            log_info "Log: ${LOG_FILE}"
        fi
    }

    rollback_on_interrupt() {
        echo ""
        log_error "Installation interrupted (signal received) — rolling back"
        rollback
        exit 130
    }
    trap rollback_on_interrupt INT TERM

    # Track component fetches for rollback
    eval "_fetch_component_orig() $(declare -f fetch_component | tail -n +2)"
    fetch_component() {
        local name="$1"
        local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"
        local was_new=false
        [[ ! -d "$install_dir" ]] && was_new=true

        local result=0
        _fetch_component_orig "$@" 2>/dev/null || result=$?

        if [[ "$was_new" == "true" ]] && [[ -d "$install_dir" ]]; then
            INSTALLED_REPOS+=("$install_dir")
        fi
        return $result
    }

    if ! run_phase "Prerequisites" phase_prerequisites true "${resolved[@]}"; then
        rollback; exit 1
    fi
    if ! run_phase "ValKey Setup" phase_valkey true "${resolved[@]}"; then
        rollback; exit 1
    fi
    if ! run_phase "Component Fetch" phase_fetch true "${resolved[@]}"; then
        rollback; exit 1
    fi
    run_phase "Build" phase_build false "${resolved[@]}"
    if ! run_phase "Configuration" phase_config true "${resolved[@]}"; then
        rollback; exit 1
    fi
    run_phase "Services" phase_services false "${resolved[@]}"
    run_phase "Lua Functions" phase_functions false "${resolved[@]}"

    if printf '%s\n' "${resolved[@]}" | grep -q 'gcore'; then
        if [[ "$DRY_RUN" != "true" ]]; then
            local seed_script="${INSTALL_ROOT}/gCore/scripts/seed-manager-defaults.sh"
            if [[ -x "$seed_script" ]]; then
                log_step "gCore Config Seed"
                local admin_pw_file="${CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey_admin.password"
                [[ -r "$admin_pw_file" ]] || admin_pw_file="${CREDENTIALS_DIR:-/etc/geodineum/credentials}/valkey.password"
                if [[ -r "$admin_pw_file" ]]; then
                    VALKEY_PORT="${VALKEY_PORT:-47445}" \
                        VALKEY_PASSWORD_FILE="$admin_pw_file" \
                        bash "$seed_script" 2>&1 | grep -E '✓|·|Done' | head -20
                    log_success "gCore manager defaults seeded"
                fi
            fi
        fi
    fi

    deploy_site_if_requested

    if [[ "$DRY_RUN" != "true" ]] && type geodeploy_harden_all_wp &>/dev/null; then
        log_info "Hardening WordPress site permissions..."
        # Best-effort: under `if`, set -e is off, so one odd site in /var/www cannot abort the install.
        if geodeploy_harden_all_wp "/var/www"; then
            log_success "WordPress sites hardened (source read-only, uploads PHP-blocked)"
        else
            log_warning "WordPress hardening had non-fatal issues — continuing"
        fi
    fi

    if [[ -f "${INSTALL_ROOT}/Geodineum/geodineum" ]] && [[ "$DRY_RUN" != "true" ]]; then
        ln -sf "${INSTALL_ROOT}/Geodineum/geodineum" /usr/local/bin/geodineum 2>/dev/null && \
            log_success "CLI installed: /usr/local/bin/geodineum"
        ln -sf "${INSTALL_ROOT}/Geodineum/geodineum" /usr/local/bin/gcli 2>/dev/null && \
            log_success "CLI alias: /usr/local/bin/gcli"
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ -f "${LIB_DIR}/common.sh" ]]; then
            source "${LIB_DIR}/common.sh" 2>/dev/null || true
            if type harden_ecosystem_dirs &>/dev/null; then
                log_info "Deploying web-deny rules..."
                harden_ecosystem_dirs >/dev/null 2>&1
                log_success "Web-deny rules deployed to all ecosystem directories"
            fi
        fi
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        local orchestrator="${INSTALL_ROOT}/Geodineum/scripts/geodeploy-orchestrator"
        if [[ -f "$orchestrator" ]]; then
            local cron_line="*/5 * * * * ${orchestrator}"
            if ! sudo -u "$DEPLOY_USER" crontab -l 2>/dev/null | grep -q "geodeploy-orchestrator"; then
                local existing
                existing=$(sudo -u "$DEPLOY_USER" crontab -l 2>/dev/null | grep -v "auto-deploy.sh" || true)
                echo -e "${existing}\n${cron_line}" | sudo -u "$DEPLOY_USER" crontab - 2>/dev/null && \
                    log_success "Geodeploy cron installed (every 5 min as ${DEPLOY_USER})" || \
                    log_warning "Could not install cron — add manually: ${cron_line}"
            else
                log_info "Geodeploy cron already installed"
            fi
        else
            log_warning "Geodeploy orchestrator not found at ${orchestrator}"
        fi

        local sudoers_tpl="${INSTALL_ROOT}/Geodineum/templates/sudoers-geodeploy.tpl"
        if [[ -f "$sudoers_tpl" ]]; then
            sed "s|{{DEPLOY_USER}}|${DEPLOY_USER}|g" "$sudoers_tpl" > /etc/sudoers.d/geodineum-deploy
            chmod 440 /etc/sudoers.d/geodineum-deploy
            if visudo -cf /etc/sudoers.d/geodineum-deploy &>/dev/null; then
                log_success "Scoped sudoers installed for ${DEPLOY_USER}"
            else
                log_error "Sudoers syntax check failed — removing"
                rm -f /etc/sudoers.d/geodineum-deploy
            fi
        fi
    fi

    # Not gated on CONFIG_EXISTS: a reinstall after --keep-data has no bootstrap.env yet still needs this.
    if [[ "$DRY_RUN" != "true" ]]; then
        reconcile_site_credentials
    fi

    run_phase "Verification" phase_verify false "${resolved[@]}"

    if [[ -z "$SITE_DOMAIN" ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$YES_MODE" != "true" ]]; then
        prompt_setup_service
    fi

    # A Ctrl-C from here on must not roll back a finished install.
    trap - INT TERM

    print_summary "${resolved[@]}"
}

main "$@"

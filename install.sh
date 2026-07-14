#!/bin/bash
#
# Geodineum Ecosystem Installer
# ==============================
# One-command installation for the entire Geodineum ecosystem.
#
# 10-phase installation:
#   1. System detection     — find what's already installed
#   2. Profile selection    — choose components (interactive or --profile)
#   3. Prerequisite check   — verify/install system requirements
#   4. ValKey setup         — detect, install, or configure ValKey
#   5. Component fetch      — git clone/pull in dependency order
#   6. Build               — cargo (Rust), composer (PHP)
#   7. Config              — /etc/geodineum/ centralized FHS layout
#   8. Services            — systemd units, permissions, gnode user
#   9. Functions           — load Lua libraries into ValKey
#  10. Verification        — test all connections, show health
#
# Usage:
#   sudo ./install.sh                              # Standard profile (default)
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
COMPONENTS_FILE="${SCRIPT_DIR}/components.yaml"
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
# Reusable component-installation helpers harvested from the
# valkey-specific recovery work. New components (gNode extensions, gCore
# pro managers, future daemons) wire through these instead of reinventing
# dpkg state recovery, system-user creation, etc.
#
# Sourced before any phase code so the valkey-specific wrappers below
# can delegate to the generic versions.
if [[ -r "${LIB_DIR}/component-primitives.sh" ]]; then
    # shellcheck source=lib/component-primitives.sh
    source "${LIB_DIR}/component-primitives.sh"
else
    log_error "Missing required library: ${LIB_DIR}/component-primitives.sh"
    log_info "This file ships with the installer; if you're running from a custom"
    log_info "checkout, ensure lib/component-primitives.sh is present."
    exit 1
fi

# Source common.sh early — validate_domain is called in main() before
# the late-stage source at the bottom of the file.
if [[ -r "${LIB_DIR}/common.sh" ]]; then
    source "${LIB_DIR}/common.sh"
fi

# =============================================================================
# Defaults
# =============================================================================

# Profile is empty by default so a plain `sudo ./install.sh` enters the
# interactive wizard. Repeat-install operators who want to skip the
# prompt pass `--profile standard` (or `--yes`, which implies standard).
# This previously hard-defaulted to "standard" — that suppressed the
# wizard for first-time users and made component selection invisible.
PROFILE=""
COMPONENTS=""
# Geodineum-COMMS (notification daemon) is OPTIONAL even in the standard
# profile: a node joining an existing constellation often has a dedicated
# SMTP node, or notifications are served from the constellation master.
# Default-on (the common solo/master case); --no-comms opts out
# non-interactively, and the standard wizard prompts.
WITH_COMMS=true
COMMS_EXPLICIT=false
SITE_DOMAIN=""
SITE_THEME=""
SITE_THEME_PATH=""
SITE_ENV="testing"
DRY_RUN=false
SKIP_BUILD=false
YES_MODE=false
# Wizard state
INTENT="deploy"           # always deploy in public installer
CONSTELLATION="new"       # new | private
DEPLOY_TIER=""            # headless | replica | full (when joining constellation)
MASTER_IP=""              # constellation master's VPN IP (non-interactive join)
VALKEY_REPLICA="false"    # true if this node runs a ValKey replica
SKIP_LOCAL_VALKEY="false" # true if using remote ValKey only (full / headless node)
CONSTELLATION_DAEMON_PW=""  # master's valkey_daemon.password, pasted during a join install
CONSTELLATION_REPLICA_PW="" # master's valkey_replica.password, pasted during a replica join
GNODE_NODE_ID=""            # this node's unique id / consumer name (default: hostname on a join, "master" otherwise)
# GitHub auth: SSH (deploy key) or HTTPS (PAT). All repos are currently
# private — see docs/GITHUB_AUTH.md for setup before running install.sh.
#
# Precedence:
#   GEODINEUM_GIT_PROTOCOL=ssh    → use git@github.com:owner/repo.git
#   GEODINEUM_GITHUB_TOKEN=<pat>  → use https://x-access-token:<pat>@github.com/...
#   neither                        → fall back to https://github.com/... (will FAIL on private repos)
GIT_PROTOCOL="${GEODINEUM_GIT_PROTOCOL:-}"
GITHUB_TOKEN="${GEODINEUM_GITHUB_TOKEN:-}"

# Branch / ref to check out for every component repo. Resolution order:
#   1. --branch <ref> on the command line
#   2. GEODINEUM_BRANCH env var
# 3. The branch this install.sh script itself is on (the "branch
#      coherence" — if the operator pulled a feature branch for the
#      installer, components clone the same branch). Detected via
#      `git -C $SCRIPT_DIR rev-parse --abbrev-ref HEAD`. Skipped if
#      we're not running from a git checkout (e.g. installed-to-disk
#      copy without a .git dir, or HEAD is detached).
#   4. Empty → origin's default branch (typically `main`).
#
# Applies uniformly across all components — every Geodineum repo follows
# the same branching cadence during pre-launch waves (currently
# a feature branch). Previously, the branch defaulted to `main` even
# when running install.sh from a feature branch, which silently cloned
# stale code (e.g. components predating the CMS-feature flip → cargo
# panic on first build) — operators saw [FAIL] Build with no obvious
# explanation since the install.sh THEY ran was up-to-date.
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
    # Default to HTTPS unauthenticated. Works for public repos only.
    # Private-repo installs will fail in Phase 5 with "Repository not found".
    # See docs/GITHUB_AUTH.md.
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
GNODE_RUNNING=false
CONFIG_EXISTS=false

# =============================================================================
# Banner + Usage
# =============================================================================

banner() {
    # Inner width: 56 cells (between │ markers). Each body row pads to 56
    # visible columns so the right border lines up with the top/bottom.
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
    echo "  --profile <name>        Install predefined set: minimal, standard"
    echo "  --components <list>     Comma-separated components to install"
    echo "  --no-comms              Exclude Geodineum-COMMS (use a dedicated SMTP"
    echo "                          node, or notifications from the constellation master)"
    echo "  --with-comms            Force-include Geodineum-COMMS (non-interactive)"
    echo "  --install-root <path>   Production install location (default: /opt/geodineum)"
    echo "  --constellation <type>  new or private"
    echo "  --deploy-tier <tier>    headless, full, or replica (join an existing constellation)"
    echo "  --master-ip <ip>        Constellation master's VPN IP (with --deploy-tier; e.g. 10.66.0.1)"
    echo "  --site <domain>         Deploy a WordPress site after install"
    echo "  --theme <name>          Child theme: gcube (default)"
    echo "  --env <environment>     DTAP: testing, staging, acceptance, production"
    echo "  --dry-run               Preview without making changes"
    echo "  --skip-build            Skip compilation (use existing binaries)"
    echo "  --branch <ref>          Git branch/tag to fetch for ALL component repos"
    echo "                          (default: each repo's main). Use this to test"
    echo "                          a pre-launch wave end-to-end:"
    echo "                            --branch my-feature-branch"
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
    echo ""
    echo "Examples:"
    echo "  sudo $0                                     # Interactive guided setup"
    echo "  sudo $0 --profile standard --yes            # Non-interactive standard"
    echo "  sudo $0 --install-root /srv/geodineum       # Custom install location"
    echo "  sudo $0 --constellation private --deploy-tier replica  # Join existing"
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
            --theme-path)   SITE_THEME_PATH="$2"; shift 2 ;;
            --env)          SITE_ENV="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --skip-build)   SKIP_BUILD=true; shift ;;
            --yes|-y)       YES_MODE=true; shift ;;
            --constellation) CONSTELLATION="$2"; shift 2 ;;
            --deploy-tier)  DEPLOY_TIER="$2"; shift 2 ;;
            --master-ip)    MASTER_IP="$2"; shift 2 ;;
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
# Validates: path is absolute, parent is writable (or path itself if existing),
# filesystem is not mounted noexec, and at least 2GB is available.
# Logs warnings (non-fatal) when checks are soft, errors (fatal) when blocking.

validate_install_root() {
    local path="$1"
    local required_mb="${2:-2048}"  # 2GB default minimum

    # Absolute path required
    if [[ "${path:0:1}" != "/" ]]; then
        log_error "Install root must be an absolute path: ${path}"
        return 1
    fi

    # Determine check target: existing path or its parent
    local check_target="$path"
    if [[ ! -d "$path" ]]; then
        check_target=$(dirname "$path")
        # Walk up until we find an existing directory
        while [[ ! -d "$check_target" && "$check_target" != "/" ]]; do
            check_target=$(dirname "$check_target")
        done
    fi

    # Writable check (non-dry-run only)
    if [[ "$DRY_RUN" != "true" ]] && [[ ! -w "$check_target" ]]; then
        log_error "Install root not writable: ${check_target}"
        log_info "Check permissions or run with sudo"
        return 1
    fi

    # noexec check — code in /opt must be executable
    local mount_opts
    mount_opts=$(findmnt -n -o OPTIONS --target "$check_target" 2>/dev/null || echo "")
    if [[ -n "$mount_opts" ]] && echo "$mount_opts" | grep -q "noexec"; then
        log_error "Filesystem mounted noexec at ${check_target} — gNode daemon cannot execute"
        log_info "Choose a different install root or remount without noexec"
        return 1
    fi

    # Disk space check (advisory warning, not fatal)
    local avail_mb
    avail_mb=$(df -Pm "$check_target" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$avail_mb" ]] && [[ "$avail_mb" -lt "$required_mb" ]]; then
        log_warning "Install root has only ${avail_mb}MB available (recommended: ${required_mb}MB+)"
        log_info "Install may fail during component fetch/build"
    fi

    return 0
}

# =============================================================================
# Component Resolution (same topology as before)
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
        *)          log_error "Unknown profile: $1 (available: minimal, standard)"; exit 1 ;;
    esac
}

# Map a non-interactive --deploy-tier into the profile + ValKey flags, so a
# constellation node can be provisioned by a script without the wizard.
# Mirrors the interactive wizard's tier cases — keep them in sync.
#   headless : minimal profile, no daemon, no local ValKey (connects to master)
#   full     : standard profile + daemon, no local ValKey (daemon talks to master)
#   replica  : standard profile + local ValKey replica (EXPERIMENTAL)
# Requires --master-ip (or VALKEY_HOST) so the node knows the master's VPN IP.
apply_deploy_tier() {
    [[ -z "$DEPLOY_TIER" ]] && return 0
    CONSTELLATION="private"
    case "$DEPLOY_TIER" in
        headless)
            [[ -z "$PROFILE" ]] && PROFILE="minimal"
            SKIP_LOCAL_VALKEY="true"
            ;;
        full)
            [[ -z "$PROFILE" ]] && PROFILE="standard"
            SKIP_LOCAL_VALKEY="true"
            ;;
        replica)
            [[ -z "$PROFILE" ]] && PROFILE="standard"
            VALKEY_REPLICA="true"
            log_warning "Replica tier is EXPERIMENTAL (no read/write split yet — writes must reach the master)."
            ;;
        *)
            log_error "Unknown --deploy-tier: ${DEPLOY_TIER} (expected: headless | full | replica)"
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

# Does the resolved list include gnode-daemon?
needs_daemon() {
    for comp in "$@"; do
        [[ "$comp" == "gnode-daemon" ]] && return 0
    done
    return 1
}

# Does the resolved list include anything requiring PHP?
needs_php() {
    for comp in "$@"; do
        case "$comp" in
            gcore|gtemplate-wp|gnode-client) return 0 ;;
        esac
    done
    return 1
}

# Does the resolved list include WordPress themes (needs Apache, MySQL, wp-cli)?
needs_wordpress() {
    for comp in "$@"; do
        case "$comp" in
            gtemplate-wp|gcube) return 0 ;;
        esac
    done
    # Also if --site was specified
    [[ -n "$SITE_DOMAIN" ]] && return 0
    return 1
}

# Does the resolved list include gCore (standalone app scaffolding available)?
has_gcore() {
    for comp in "$@"; do
        [[ "$comp" == "gcore" ]] && return 0
    done
    return 1
}

# =============================================================================
# PHASE 0: Deploy User Setup
# =============================================================================
# Establishes the deploy user identity before anything else runs.
# The deploy user:
#   - Owns all source code in /opt/geodineum/ (can git pull)
#   - Runs the geodeploy orchestrator via cron
#   - Is a member of groups: geodineum (ecosystem access) + gnode (daemon repo access)
#   - Has a read-only SSH deploy key for GitHub
#
# The installer runs as root (sudo), but all git/cargo operations run as
# the deploy user via su/sudo -u.

# load deploy key into ssh-agent so per-clone passphrase prompts
# don't fire 9× (7 components + self-clone + extensions). Idempotent:
# no-op when key has no passphrase or is already loaded.
#
# Sets SSH_AUTH_SOCK + SSH_AGENT_PID in install.sh's environment so
# subsequent sudo -u $DEPLOY_USER invocations can preserve-env them.
# The agent runs as the deploy user (socket owned by them) so deploy_user
# git operations connect cleanly.
#
# Returns 0 on success or no-op-skip; non-zero only on a hard failure
# the operator should know about. Per-clone passphrase prompts remain
# the fallback in that case.
ensure_ssh_agent_loaded() {
    local key="$1"
    local user="$2"

    # Key file must exist + be readable to test.
    if [[ ! -r "$key" ]]; then
        log_warning "Deploy key ${key} not readable — skipping ssh-agent setup"
        return 0
    fi

    # ssh-keygen -y -P "" extracts the public key with empty passphrase
    # candidate. Exits 0 if the key is passphrase-free, 1 if encrypted.
    # Run as the deploy user so file-permission checks (key 600 owned
    # by deploy_user) succeed.
    if sudo -u "$user" ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
        log_detail "Deploy key has no passphrase — ssh-agent not needed"
        return 0
    fi

    # Key is encrypted. Start an agent as the deploy user.
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    local agent_env="${user_home}/.ssh/.geodineum-agent.env"

    # Reuse an existing live agent if one is recorded.
    if [[ -r "$agent_env" ]]; then
        # shellcheck source=/dev/null
        source "$agent_env" 2>/dev/null
        if [[ -n "${SSH_AGENT_PID:-}" ]] && kill -0 "$SSH_AGENT_PID" 2>/dev/null \
           && [[ -S "${SSH_AUTH_SOCK:-}" ]]; then
            # Agent alive. Is the key already loaded? Compare key
            # fingerprint vs `ssh-add -l` output.
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
        # Stale agent.env — clean up.
        rm -f "$agent_env"
    fi

    log_info "Starting ssh-agent for ${user} (deploy key is passphrase-protected)..."

    # Start a fresh agent as the deploy user. Capture SSH_AUTH_SOCK +
    # SSH_AGENT_PID from its eval-style output.
    local agent_out
    agent_out=$(sudo -u "$user" ssh-agent -s 2>/dev/null) || {
        log_warning "Could not start ssh-agent for ${user} — per-clone passphrase prompts will fire"
        return 1
    }

    # Persist for future install runs + parse into current env.
    install -m 0600 -o "$user" -g "$user" /dev/null "$agent_env"
    printf '%s\n' "$agent_out" > "$agent_env"
    chown "${user}:${user}" "$agent_env"
    chmod 0600 "$agent_env"

    # shellcheck source=/dev/null
    source "$agent_env" 2>/dev/null

    log_info "Adding deploy key to agent — you'll be prompted for the passphrase ONCE."
    if ! sudo -u "$user" env SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add "$key" </dev/tty; then
        log_warning "ssh-add failed — per-clone passphrase prompts will fire"
        # Clean up so we don't leave a useless agent process running.
        kill "$SSH_AGENT_PID" 2>/dev/null || true
        rm -f "$agent_env"
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1
    fi

    log_success "Deploy key loaded in ssh-agent (pid ${SSH_AGENT_PID}); subsequent clones won't prompt"

    # Export so subsequent sudo -u $user invocations can preserve them
    # via --preserve-env=SSH_AUTH_SOCK,SSH_AGENT_PID or inline env.
    export SSH_AUTH_SOCK SSH_AGENT_PID

    # Tear down at install-end so we don't leak an agent process
    # indefinitely (the persisted agent.env will be picked up by a
    # subsequent install run and re-validated).
    trap 'sudo -u '"$user"' kill "$SSH_AGENT_PID" 2>/dev/null || true; rm -f "'"$agent_env"'" 2>/dev/null || true' EXIT
}

# Helper: run a command as another user, preserving SSH_AUTH_SOCK
# when an ssh-agent is loaded in our env. Plain `sudo -u <user>` strips
# the env; subsequent git operations would fall back to per-clone
# passphrase prompts. With this wrapper, all git invocations connect
# to the agent loaded in Phase 0.
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

            # Create user if doesn't exist
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

    # Narrow-group hardening: per-purpose credential
    # groups (least privilege). Each group grants access to ONE resource
    # class — never put high-risk accounts (www-data) into a broad group.
    #
    #   gnode               — daemon primary, gnode user ONLY (no operator-
    #                         account members; tightens blast radius if
    #                         www-data is RCE-compromised)
    #   geodineum-creds     — daemon + admin credential readers. Members:
    #                         gnode user, deploy_user. Used by
    #                         /etc/geodineum/credentials/.
    #   geodineum-dash      — dashboard credential readers. Members:
    #                         gnode user, www-data, deploy_user. Used by
    #                         /etc/geodineum/dashboard/.
    #   geodineum-bootstrap — bootstrap.env readers (2026-06-03 added; was
    #                         previously world-readable 0644 root:root —
    #                         operator security stance rejects world-read).
    #                         Members: gnode, www-data, deploy_user,
    #                         geodine. Used by /etc/geodineum/bootstrap.env
    #                         and PHP component env files. NOTHING ELSE
    #                         goes in this group — it grants exactly
    #                         bootstrap.env / php-env read, nothing more.
    #   geodineum           — RETIRED conceptually; kept as empty marker
    #                         for /opt/geodineum/ chown (decision R back-
    #                         compat). NO untrusted users (especially
    #                         not www-data) — broad group, would violate
    #                         least-privilege.
    getent group gnode               &>/dev/null || groupadd --system gnode
    getent group geodineum           &>/dev/null || groupadd --system geodineum
    getent group geodineum-creds     &>/dev/null || groupadd --system geodineum-creds
    getent group geodineum-dash      &>/dev/null || groupadd --system geodineum-dash
    getent group geodineum-bootstrap &>/dev/null || groupadd --system geodineum-bootstrap
    # Two single-purpose groups, deliberately NOT conflated:
    #   geodineum-web  — reads web-site CREDENTIALS only (root:geodineum-web
    #                    0640). Sole member www-data. A secret group; no
    #                    source is ever filed here.
    #   geodineum-code — reads deployed shared SOURCE only (gCore, gNode-Client,
    #                    GeoV, themes). Members www-data (web) + geodine (the
    #                    in-process library consumer) + future gCore consumers.
    #                    Non-secret source; adding a member leaks no credential.
    # Keeping source and creds in separate groups is what lets geodine read the
    # framework without ever gaining read on any site's credential.
    getent group geodineum-web       &>/dev/null || groupadd --system geodineum-web
    getent group geodineum-code      &>/dev/null || groupadd --system geodineum-code

    # Dedicated COMMS runtime identity. Previously the COMMS
    # daemon ran as gnode (deployment convenience — gnode already had
    # ValKey creds), which meant a compromised COMMS gateway = a
    # compromised gnode-daemon (far more privileged: writes streams
    # across every site). geodineum-comms owns exactly its own
    # credential (valkey_comms.password via group), its state dir
    # (/var/lib/geodineum-comms), and bootstrap.env read.
    getent group geodineum-comms     &>/dev/null || groupadd --system geodineum-comms
    if ! getent passwd geodineum-comms &>/dev/null; then
        useradd --system --gid geodineum-comms --no-create-home \
                --home-dir /opt/geodineum/Geodineum-COMMS \
                --shell /usr/sbin/nologin geodineum-comms 2>/dev/null || \
            log_warning "Could not create geodineum-comms user — COMMS will fall back to manual setup"
    fi

    # Deploy user joins operator-side groups. Used for operational reads
    # (e.g. `geodineum status` showing the dashboard credential location,
    # or manual `valkey-cli` ACL checks). Deploy user NOT in gnode group
    # — gnode group is daemon-only.
    usermod -aG geodineum           "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-creds     "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-dash      "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG geodineum-bootstrap "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG gnode               "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG systemd-journal     "$DEPLOY_USER" 2>/dev/null || true
    usermod -aG www-data            "$DEPLOY_USER" 2>/dev/null || true

    # Service users joining geodineum-bootstrap (narrow group — grants
    # bootstrap.env read only). www-data needs read for PHP gCore
    # bootstrap-loader. gnode needs read for the daemon's ecosystem_config
    # at startup. geodine needs read for ValKey-integration discovery.
    # NOTHING ELSE goes in this group — adding a user here MUST be
    # justified by a documented bootstrap.env read need.
    usermod -aG geodineum-bootstrap www-data 2>/dev/null || true
    usermod -aG geodineum-bootstrap gnode    2>/dev/null || true
    # COMMS daemon reads bootstrap.env for ecosystem_config at
    # startup (same justification as gnode).
    if id geodineum-comms >/dev/null 2>&1; then
        usermod -aG geodineum-bootstrap geodineum-comms 2>/dev/null || true
    fi
    if id geodine >/dev/null 2>&1; then
        usermod -aG geodineum-bootstrap geodine 2>/dev/null || true
    fi

    # www-data reads its web-site creds via geodineum-web and the deployed
    # shared source via geodineum-code. geodine (if already present) joins
    # geodineum-code too so the in-process gCore/gNode-Client library is
    # readable — but is NEVER added to www-data (it must not see web content)
    # nor geodineum-web (it must not see any site credential). Service onboard
    # (onboard-service.sh) adds later gCore-consuming services to geodineum-code.
    # Group changes don't apply to a running process — Apache/PHP-FPM MUST be
    # restarted; the next restart in this install flow picks them up.
    usermod -aG geodineum-web    www-data 2>/dev/null || true
    usermod -aG geodineum-code   www-data 2>/dev/null || true
    if id geodine >/dev/null 2>&1; then
        usermod -aG geodineum-code geodine 2>/dev/null || true
    fi
    log_success "${DEPLOY_USER} is in groups: geodineum, geodineum-creds, geodineum-dash, geodineum-bootstrap, gnode, systemd-journal, www-data"
    log_info "geodineum-bootstrap members: www-data, gnode, ${DEPLOY_USER}$(id geodineum-comms >/dev/null 2>&1 && echo ', geodineum-comms')$(id geodine >/dev/null 2>&1 && echo ', geodine')"
    log_info "geodineum-web members:       www-data (web-site creds only)"
    log_info "geodineum-code members:      www-data$(id geodine >/dev/null 2>&1 && echo ', geodine') (shared source only)"

    # Persist DEPLOY_USER + DEPLOY_HOME for geodeploy.sh + cron-driven
    # geodeploy-orchestrator. The cron context has minimal env (no
    # SUDO_USER, no $USER from the install session) — without this file
    # the auto-deploy library would have to guess. /etc/geodineum/deploy.env
    # makes the deploy identity self-describing on disk and lives
    # alongside bootstrap.env (same directory, but stricter perms — see
    # 2026-06-03 narrow-group hardening; bootstrap.env itself moves to
    # root:geodineum-bootstrap 0640, this deploy.env file is the same
    # pattern since it's a "name not a secret" but no excuse for world-read).
    # /etc/geodineum is root:geodineum 0751 — the o+x traverse bit is
    # REQUIRED: www-data (bootstrap.env via geodineum-bootstrap file
    # group), geodineum-comms (credentials/, components/), and geodine
    # all need to traverse to their own group-readable files without
    # broad group memberships. Same rationale as credentials/.
    # (A prior revision set root:gnode 0750, which contradicted
    # lib/geodeploy.sh's fix_config_perms and would have blocked
    # www-data's bootstrap reads on a fresh host until the first
    # orchestrator cycle flipped it back.)
    install -d -m 0751 -o root -g geodineum /etc/geodineum
    cat > /etc/geodineum/deploy.env <<EOF_DEPLOY_ENV
DEPLOY_USER=${DEPLOY_USER}
DEPLOY_HOME=${DEPLOY_HOME}
EOF_DEPLOY_ENV
    # 2026-06-03 strict-deny posture: root:geodineum-bootstrap 0640 — same
    # narrow-group pattern as bootstrap.env. deploy.env contains a name,
    # not a secret, but world-read still leaks deployment shape (who is
    # the operator user). geodeploy.sh and geodeploy-orchestrator read it
    # as deploy_user (member of geodineum-bootstrap).
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

    # load the deploy key into ssh-agent once so subsequent
    # `sudo -u $DEPLOY_USER git clone ...` calls don't prompt for the
    # passphrase per-repo (7 component clones + 1 self-clone + 1 ext
    # = 9 prompts on a fresh install without this). Idempotent —
    # if the key has no passphrase OR is already loaded, no-op.
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
    #
    # trust the configured deploy infrastructure. Pre-fix we ran a
    # `su - $DEPLOY_USER -c "ssh -T git@github-deploy"` test as the
    # primary auto-detect — but `su -c` strips the deploy user's
    # interactive env in ways that produce false-negatives even when the
    # SAME ssh command works fine when run directly by the deploy user
    # in their normal shell. That false-negative dropped the protocol
    # to HTTPS, which (since all geodineum/* repos are still private)
    # then prompted for github.com username + PAT and failed cleanly.
    #
    # The decision-X locked workaround was `GEODINEUM_GIT_PROTOCOL=ssh`.
    # That worked, but now plain `sudo ./install.sh` (no env var)
    # the documented common path — and the broken test surfaced.
    #
    # New logic: if the deploy key exists AND the github-deploy SSH
    # alias is configured, USE THEM. This block is only reached after
    # the alias-config block above has run, and that block GUARANTEES
    # the alias is present when the deploy key is. So in the common
    # path: deploy key present → SSH via github-deploy.
    #
    # Layered fallbacks remain for the edge cases:
    #   - Operator explicit `GEODINEUM_GIT_PROTOCOL=ssh`  → SSH
    #   - Operator explicit `GEODINEUM_GIT_PROTOCOL=https` + token → HTTPS+PAT
    #   - Deploy key present (auto-trust)                → SSH
    #   - Deploy user's own ~/.ssh works against github  → use that
    #   - Final fallback                                  → HTTPS (will
    #                                                       prompt + fail
    #                                                       on private repos)
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
        # Common path. The deploy key exists and the alias is configured
        # — this Phase 0 just set them up if they weren't already. No
        # need to test (the `su -c "ssh -T"` test gives false-negatives
        # under env-isolation; the actual `git clone` invocation in
        # Phase 5 uses the same alias and works fine).
        log_success "SSH via github-deploy (deploy key + alias present)"
        GITHUB_CLONE_PREFIX="git@github-deploy:"
        GITHUB_CLONE_SUFFIX=".git"
    elif su - "$DEPLOY_USER" -c "ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1" | grep -qi "successfully authenticated"; then
        # Edge case: no deploy key present, but the deploy user's own
        # personal SSH config (e.g. ~/.ssh/id_ed25519) authenticates
        # against github.com. Use it.
        log_success "Deploy user's own SSH key authenticates to github.com — using that"
        GITHUB_CLONE_PREFIX="git@github.com:"
        GITHUB_CLONE_SUFFIX=".git"
    else
        log_warning "No SSH path available — falling back to HTTPS"
        log_info "All geodineum/* repos are private; HTTPS will prompt for credentials."
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

    # git
    if command -v git &>/dev/null; then
        HAS_GIT=true
        log_success "git $(git --version 2>/dev/null | awk '{print $3}')"
    else
        log_warning "git not found"
    fi

    # PHP
    if command -v php &>/dev/null; then
        HAS_PHP=true
        local php_ver
        php_ver=$(timeout 5 php -v 2>/dev/null </dev/null | head -1 | awk '{print $2}')
        log_success "PHP ${php_ver:-unknown}"
        # Check key extensions (single php -m call, cached)
        local php_modules
        php_modules=$(timeout 5 php -m 2>/dev/null </dev/null || echo "")
        # yaml added to the required-extensions list. Without it
        # gTemplate fatals on every request (yaml_parse_file undefined).
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

    # Composer (redirect stdin to prevent "Do not run as root" interactive warning)
    if command -v composer &>/dev/null; then
        HAS_COMPOSER=true
        local comp_ver
        comp_ver=$(composer --version --no-interaction 2>/dev/null </dev/null | awk '{print $3}' || echo "unknown")
        log_success "Composer ${comp_ver}"
    else
        log_warning "Composer not found"
    fi

    # Rust / cargo — check calling user's home too (sudo doesn't inherit PATH)
    local cargo_bin=""
    if command -v cargo &>/dev/null; then
        cargo_bin="cargo"
    else
        # Under sudo, cargo is in the calling user's home, not root's
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

    # systemd
    if command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=true
        log_success "systemd available"
    else
        log_warning "systemd not found (services won't auto-start)"
    fi

    # Apache
    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet apache2 2>/dev/null; then
        HAS_APACHE=true
        log_success "Apache2 running"
    elif command -v apache2 &>/dev/null || command -v apachectl &>/dev/null; then
        HAS_APACHE=true
        log_success "Apache2 installed (not running)"
    else
        log_detail "Apache2 not installed"
    fi

    # MySQL/MariaDB
    if [[ "$HAS_SYSTEMD" == "true" ]] && (systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null); then
        HAS_MYSQL=true
        log_success "MySQL/MariaDB running"
    elif command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
        HAS_MYSQL=true
        log_success "MySQL/MariaDB installed (not running)"
    else
        log_detail "MySQL/MariaDB not installed"
    fi

    # wp-cli
    if command -v wp &>/dev/null; then
        log_success "WP-CLI found"
    else
        log_detail "WP-CLI not installed"
    fi

    # certbot
    if command -v certbot &>/dev/null; then
        log_success "certbot found"
    else
        log_detail "certbot not installed"
    fi

    # ValKey — multi-strategy detection
    detect_valkey

    # gNode
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
        GNODE_RUNNING=true
        log_success "gNode daemon running"
    fi

    # Centralized config
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

    # Install root
    if [[ -d "$INSTALL_ROOT" ]]; then
        local comp_count
        comp_count=$(find "$INSTALL_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        log_success "${INSTALL_ROOT}/ exists (${comp_count} components)"
    else
        log_detail "${INSTALL_ROOT}/ not yet created"
    fi
}

detect_valkey() {
    # 1. systemd service (preferred: valkey-gnode on port 47445)
    if [[ "$HAS_SYSTEMD" == "true" ]] && systemctl is-active --quiet valkey-gnode 2>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey running (valkey-gnode service, port 47445)"
        return
    fi

    # 2. Generic valkey-server process
    if pgrep -x valkey-server &>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey process detected (valkey-server)"
        return
    fi

    # 3. Docker container
    if command -v docker &>/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi valkey; then
            HAS_VALKEY=true
            VALKEY_RUNNING=true
            log_success "ValKey running (Docker container)"
            return
        fi
    fi

    # 4. valkey-server binary available but not running
    if command -v valkey-server &>/dev/null; then
        HAS_VALKEY=true
        log_success "valkey-server binary found (not running)"
        return
    fi

    # 5. Connection test (something might be on port 47445)
    if timeout 2 bash -c "echo PING | nc -q 1 127.0.0.1 47445 2>/dev/null" | grep -q PONG 2>/dev/null; then
        HAS_VALKEY=true
        VALKEY_RUNNING=true
        log_success "ValKey responding on port 47445"
        return
    fi

    log_warning "ValKey not detected"
}

# Worker-side WireGuard bootstrap for a join-constellation install.
# Installs wireguard-tools, generates this node's keypair, prints the public
# key + public IP + the exact add-peer command for the master, then (when
# interactive) brings the tunnel up and verifies the master is reachable.
# Every step is non-fatal — WireGuard can also be finished by hand after.
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
    echo -e "       sudo geodineum constellation add-peer ${peer_name} \"${my_pub}\" \"${my_ip}:51820\""
    echo -e "       sudo geodineum constellation show-config"
    echo ""

    if [[ "${YES_MODE:-false}" == "true" ]]; then
        log_info "Non-interactive: after the master add-peer, place the config at ${wg_conf}, then:"
        log_info "  sudo systemctl enable --now wg-quick@wg-geodineum"
        return 0
    fi

    # Read the worker config pasted directly into THIS install shell (the
    # operator is already here — no separate file-save step). cat reads the
    # paste until Ctrl-D; we save it, fill the private key, and bring it up.
    echo -e "  ${BOLD}Then paste that config below${NC} ${DIM}and press Ctrl-D on a blank line${NC}"
    echo -e "  ${DIM}(or just Ctrl-D to skip and finish WireGuard by hand later):${NC}"
    local pasted=""
    pasted="$(cat || true)"
    if [[ -z "${pasted//[[:space:]]/}" ]]; then
        log_info "No config pasted — finish WireGuard before the daemon starts:"
        log_info "  save the master's show-config to ${wg_conf}, then: systemctl enable --now wg-quick@wg-geodineum"
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

# Prompt for the master's ValKey credential(s) during a join install, so the
# operator never has to shell into another window to copy them. Values are
# captured here (hidden input) and written to /etc/geodineum/credentials/ in
# phase_config, once the gnode user + creds dir exist. Daemon-bearing tiers
# (full/replica) need the gnode_daemon password; replica also needs the
# replication password. Headless runs no daemon — its per-site client creds
# are minted at site-registration time on the master, so nothing to paste.
wizard_constellation_credentials() {
    case "$DEPLOY_TIER" in
        full|replica) ;;
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

# Apply a base64 expansion bundle from `geodineum constellation expand`:
# decode it, write the WireGuard config, and capture the ValKey credential(s)
# into CONSTELLATION_*_PW (written to disk in phase_config). Returns non-zero
# if the input isn't a valid bundle so the caller can fall back to manual.
wizard_apply_constellation_bundle() {
    local b64="$1"
    local decoded
    decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
    if ! printf '%s' "$decoded" | grep -q 'GEODINEUM-CONSTELLATION-BUNDLE'; then
        return 1
    fi
    local wg_conf="/etc/wireguard/wg-geodineum.conf"
    install -d -m 700 /etc/wireguard 2>/dev/null || true
    printf '%s\n' "$decoded" \
        | awk '/^---WIREGUARD---/{f=1;next} /^---VALKEY_DAEMON_PASSWORD---/{f=0} f' > "$wg_conf"
    chmod 600 "$wg_conf" 2>/dev/null || true
    CONSTELLATION_DAEMON_PW="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_DAEMON_PASSWORD---/{f=1;next} /^---VALKEY_REPLICA_PASSWORD---/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"
    CONSTELLATION_REPLICA_PW="$(printf '%s\n' "$decoded" \
        | awk '/^---VALKEY_REPLICA_PASSWORD---/{f=1;next} /^===END===/{f=0} f' | sed '/^[[:space:]]*$/d' | head -1)"

    log_success "Bundle applied — WireGuard config + credentials captured."
    systemctl enable --now wg-quick@wg-geodineum 2>/dev/null || true
    local master_ip="${VALKEY_HOST:-10.66.0.1}"
    if ping -c2 -W2 "$master_ip" >/dev/null 2>&1; then
        log_success "WireGuard tunnel up — master ${master_ip} reachable over the VPN"
    else
        log_warning "Tunnel configured but ${master_ip} not yet reachable — check the endpoint you gave to 'expand'."
    fi
    return 0
}

# Worker enrollment entry point: offer the one-paste `expand` bundle; if the
# operator skips it (or it's invalid), fall back to manual WireGuard +
# credential entry.
wizard_constellation_join() {
    local master_ip="${VALKEY_HOST:-10.66.0.1}"

    # Already enrolled? If the WireGuard interface exists and the master is
    # reachable over it (e.g. a reinstall — uninstall leaves /etc/wireguard
    # intact), skip the WireGuard setup entirely and just collect the
    # credential. Reaching 10.66.0.1 at all proves the tunnel is up.
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
    echo -e "       sudo geodineum constellation expand ${me_name} ${me_ip}:51820"
    echo -e "  ${DIM}then paste the single-line bundle it prints.${NC}"
    echo ""

    if [[ "${YES_MODE:-false}" != "true" ]]; then
        local bundle=""
        read -r -p "  Paste expansion bundle (or press Enter to set up manually): " bundle || true
        if [[ -n "$bundle" ]]; then
            if wizard_apply_constellation_bundle "$bundle"; then
                return 0
            fi
            log_warning "That wasn't a valid bundle — falling back to manual setup."
        fi
    fi

    # Manual fallback: generate key + paste WG config, then paste credential(s).
    wizard_constellation_wireguard_prep
    wizard_constellation_credentials
}

# =============================================================================
# PHASE 2: Profile Selection
# =============================================================================

phase_selection() {
    log_step "Phase 2/10: Setup Wizard"

    # --yes mode is non-interactive: default profile to standard if the
    # operator didn't pass --profile/--components explicitly.
    if [[ "$YES_MODE" == "true" ]] && [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]]; then
        PROFILE="standard"
        log_info "Profile: standard (--yes default)"
        return
    fi

    if [[ -n "$PROFILE" ]] || [[ -n "$COMPONENTS" ]]; then
        # Non-interactive: profile/components already set via CLI args
        [[ -n "$PROFILE" ]] && log_info "Profile: ${PROFILE}"
        [[ -n "$COMPONENTS" ]] && log_info "Components: ${COMPONENTS}"
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
            CONSTELLATION="private"
            echo ""
            echo -e "  ${BOLD}What role will this node serve?${NC}"
            echo ""
            echo -e "    ${BOLD}a) Headless${NC}       gCore + services only — no daemon, no local ValKey"
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

            local tier_choice
            read -p "  Select [a/b/c, default: c]: " -n 1 tier_choice
            echo ""

            case "${tier_choice:-c}" in
                a|A) DEPLOY_TIER="headless" ;;
                b|B) DEPLOY_TIER="replica" ;;
                *)   DEPLOY_TIER="full" ;;
            esac

            log_info "Deployment tier: ${DEPLOY_TIER}"

            # Connection details (via WireGuard VPN)
            echo ""
            echo -e "  ${BOLD}Constellation connection${NC}"
            echo -e "  ${DIM}The master runs 'geodineum constellation init' and provides${NC}"
            echo -e "  ${DIM}a WireGuard VPN IP. ValKey is only reachable via the VPN.${NC}"
            echo ""
            local master_vpn_ip
            read -p "  Master VPN IP [10.66.0.1]: " master_vpn_ip
            VALKEY_HOST="${master_vpn_ip:-10.66.0.1}"
            VALKEY_PORT="47445"
            echo ""
            log_info "Constellation: ${VALKEY_HOST}:${VALKEY_PORT} (via WireGuard VPN)"

            # Adjust profile + flags based on tier (mirror of apply_deploy_tier).
            case "$DEPLOY_TIER" in
                headless)
                    PROFILE="minimal"
                    SKIP_LOCAL_VALKEY="true"
                    log_info "Auto-selected minimal profile (headless: no daemon, no local ValKey — connects to master)"
                    ;;
                replica)
                    PROFILE="standard"
                    VALKEY_REPLICA="true"
                    log_warning "Replica tier is EXPERIMENTAL: read/write splitting is not yet"
                    log_warning "implemented, so a local replica cannot serve writes. Prefer"
                    log_warning "'headless' or 'full' for production until a future release."
                    ;;
                full)
                    PROFILE="standard"
                    SKIP_LOCAL_VALKEY="true"
                    log_info "Auto-selected standard profile (full node: daemon, no local ValKey)"
                    ;;
            esac

            # Node ID — must be UNIQUE per node: it's the daemon's consumer
            # name in the shared group, so a worker that reuses the master's
            # "master" id contends over the same stream entries instead of
            # load-balancing. Default to this host's name.
            local _def_node; _def_node="$(hostname -s 2>/dev/null || echo worker)"
            if [[ "$YES_MODE" == "true" ]]; then
                GNODE_NODE_ID="${GNODE_NODE_ID:-$_def_node}"
            else
                local _node_ans
                read -r -p "  Node ID for this node [${_def_node}]: " _node_ans
                GNODE_NODE_ID="${_node_ans:-$_def_node}"
            fi
            log_info "Node ID: ${GNODE_NODE_ID}"

            # Worker enrollment: paste the master's one-shot `expand` bundle
            # (WireGuard config + credentials in one step), or fall back to
            # manual WireGuard + credential entry. Everything stays in this
            # install shell — no second window.
            wizard_constellation_join
            ;;
        *)
            CONSTELLATION="new"
            log_info "Constellation: new (standalone deployment)"
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

    # Skip component selection if tier already chose a profile
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

    # Only ask if we're installing themes and no theme was specified via CLI
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
    # Skipped when the operator already chose explicitly via --no-comms /
    # --with-comms. Default keeps it (the solo/master case); declining
    # suits a node that uses a dedicated SMTP node or the master's COMMS.
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

# Interactive custom component selection
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

    # Package manager detection
    local HAS_APT=false
    if command -v apt-get &>/dev/null; then
        HAS_APT=true
    fi

    # Root check
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

    # Helper: install apt packages if apt is available
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

    # Track if we already ran apt-get update this session
    local APT_UPDATED=false
    apt_update() {
        if [[ "$APT_UPDATED" != "true" ]] && [[ "$HAS_APT" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
            log_info "Updating package lists..."
            apt-get update -qq
            APT_UPDATED=true
        fi
    }

    # ─── Core tools (always needed) ──────────────────────────

    # git
    if [[ "$HAS_GIT" != "true" ]]; then
        log_info "Installing git..."
        apt_update
        apt_install "git" git || exit 1
        log_success "git installed"
    fi

    # jq — needed for config seeding (manager-defaults.json parsing)
    if ! command -v jq &>/dev/null; then
        log_info "Installing jq..."
        apt_update
        apt_install "jq" jq || log_warning "jq install failed — config seeding will need manual jq install"
    fi

    # yq — needed for CLI manifest discovery (geodeploy.yaml cli: sections)
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

    # python3-jsonschema — needed for `geodineum validate` (manifest schema checks).
    # The canonical schema declares $schema=draft/2020-12 and uses $defs (added
    # in Draft 2019-09), which requires jsonschema >= 4.0. Ubuntu 22.04 LTS
    # ships python3-jsonschema 3.x via apt; if that's what we end up with we
    # upgrade to 4.x via pip (with --break-system-packages for PEP 668 hosts).
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
            # PEP 668 (Ubuntu 23.04+, Debian 12+) blocks system-wide pip
            # installs by default; --break-system-packages allows it. Older
            # systems silently ignore the flag.
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

    # curl — needed for Rust install, Composer, downloads
    if ! command -v curl &>/dev/null; then
        log_info "Installing curl..."
        apt_update
        apt_install "curl" curl || exit 1
        log_success "curl installed"
    fi

    # unzip — needed for Composer
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

    # system libs that Geodineum's Rust crates link against. Previously,
    # only the source-build-Valkey path installed pkg-config + build-
    # essential + libsystemd-dev (Phase 4); Geodineum-COMMS also needs
    # libssl-dev (`lettre` with feature `tokio1-native-tls` → openssl-sys).
    # gNode's daemon doesn't need libssl-dev (its redis client uses
    # tokio-comp only), which is why gNode built fine while COMMS
    # silently failed with "Could not find OpenSSL development headers".
    # Operator-facing symptom previously:
    #   [INFO] Building Geodineum-COMMS notification daemon...
    #   [WARN] COMMS build failed — notifications will not be available
    # (the actual cargo error was hidden by 2>/dev/null on the build line;
    # stderr is surfaced there as well.)
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
            # php-yaml is required by gTemplate's config loader
            # (yaml_parse_file in inc/registration.php:124). Without it,
            # every WordPress request fatals with "Call to undefined
            # function gTemplate\yaml_parse_file" and the site returns
            # a 500 before rendering anything.
            apt_install "PHP" php php-cli php-fpm php-redis php-mbstring php-xml \
                php-curl php-zip php-intl php-igbinary php-yaml php-apcu || exit 1
            # php-json is bundled in PHP 8.x on some distros
            apt_install "php-json" php-json 2>/dev/null || true
            HAS_PHP=true
            log_success "PHP installed with extensions"
        fi
    fi

    # php-mysql — needed for WordPress database access
    if needs_wordpress "${resolved[@]}" && [[ "$HAS_PHP" == "true" ]]; then
        if ! php -m 2>/dev/null | grep -qi "^mysqli$"; then
            log_info "Installing php-mysql for WordPress..."
            apt_update
            apt_install "php-mysql" php-mysql || log_warning "php-mysql install failed"
        fi
    fi

    # Composer
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

            # Enable required modules
            if [[ "$DRY_RUN" != "true" ]]; then
                a2enmod rewrite headers expires ssl proxy_fcgi setenvif http2 2>/dev/null || true
                # Bootstrap PHP handler: stock Debian FPM conf until
                # ensure_php_fpm swaps in the geodineum pool. mod_php is
                # never installed — it pins prefork and disables HTTP/2.
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
                # wp-cli must be world-executable. The site-installer
                # runs `sudo -u www-data wp ...` (see gTemplate/scripts/
                # install-geodineum.sh:396) so www-data needs exec on
                # /usr/local/bin/wp. WP-CLI ships no secrets — it's a
                # public phar — and standard distribution practice is
                # 0755 root:root. Previously, we chmod'd 750, which silently
                # denied www-data and broke `wp core download` with
                # "sudo: unable to execute /usr/local/bin/wp: Permission
                # denied".
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
            log_warning "wireguard-tools install failed — constellation init will install on demand"
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
    # Always normalize ownership + permissions on the install root so
    # Phase 5's `sudo -u ${DEPLOY_USER} git clone ...` can write into it.
    # Previously the `mkdir + chmod 750` left it root:root, which silently
    # broke clones (git's "Permission denied" reached stderr but was lost
    # in the tee pipeline, leaving operators with an opaque "Failed to
    # fetch <component>" with no underlying cause).
    if [[ "$DRY_RUN" != "true" ]] && [[ -d "$INSTALL_ROOT" ]]; then
        local _owner="${DEPLOY_USER:-${SUDO_USER:-root}}"
        local _group="geodineum"
        # Group must exist before chown can use it; if Phase 7 hasn't
        # created it yet we fall back to the deploy user's primary group.
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

# Stop + disable + remove any legacy ValKey systemd units so the canonical
# /etc/systemd/system/valkey-gnode.service is the only ValKey on the box.
# Targets:
#   /etc/systemd/system/valkey.service          — pre-rename Geodineum unit
#   /etc/systemd/system/valkey-server.service   — older Geodineum unit (or
#                                                 apt's own if it landed in
#                                                 /etc rather than /lib)
#   /lib/systemd/system/valkey-server.service   — apt-upstream unit (we
#                                                 leave the file alone but
#                                                 mask the unit so systemd
#                                                 won't start it; this lets
#                                                 a future apt removal of
#                                                 valkey-server clean up).
# Idempotent. Safe to call repeatedly. Pre-launch posture: no backward
# compatibility for old unit names — one canonical, hard-stop on drift.
purge_legacy_valkey_units() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "purge legacy valkey units (valkey.service, valkey-server.service)"
        return 0
    fi

    local _purged=0
    local _legacy
    for _legacy in valkey valkey-server; do
        # Skip if the unit doesn't exist on this host
        systemctl list-unit-files "${_legacy}.service" 2>/dev/null | grep -q "${_legacy}.service" || continue

        # Stop + disable. Both are idempotent; non-existent is fine.
        systemctl stop    "${_legacy}.service" 2>/dev/null || true
        systemctl disable "${_legacy}.service" 2>/dev/null || true

        # Remove the unit file if it lives in /etc/ (operator-managed). The
        # apt-managed copy in /lib/ stays in place; we mask it instead so
        # systemd refuses to start it but apt can still uninstall cleanly.
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

# Ensure /etc/systemd/system/valkey-gnode.service exists with the right
# ExecStart for the binary that's actually installed. Idempotent — if the
# unit already exists (typical: source build path wrote it via
# install_valkey_from_source), this returns success without touching it.
# Called by the apt install path so apt's upstream valkey-server.service
# doesn't become the de-facto running unit.
ensure_canonical_valkey_unit() {
    local unit_path="/etc/systemd/system/valkey-gnode.service"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "write ${unit_path} (canonical gNode-flavored ValKey unit)"
        return 0
    fi

    if [[ -f "$unit_path" ]] && grep -q "^ExecStart=" "$unit_path"; then
        return 0  # already canonical
    fi

    # Detect the binary path. Source build → /usr/local/bin; apt → /usr/bin.
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

# ValKey CLI without a local server. Join/full-node tiers use the master's
# ValKey over VPN, but bootstrap-loader.sh and onboarding still shell out to
# a local valkey-cli — the remote-skip path never installed one.
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

# Build Valkey from source. Used on Ubuntu 22.04 and older Debian where
# the `valkey-server` package isn't in apt yet. Pinned to a known-good
# release tag; can be overridden with GEODINEUM_VALKEY_VERSION.
#
# Sets up /usr/local/bin/{valkey-server,valkey-cli}, /etc/valkey/valkey.conf,
# /var/lib/valkey, /var/log/valkey, the `valkey` system user, and the
# canonical Geodineum systemd unit at /etc/systemd/system/valkey-gnode.service
# (project-distinguished name; avoids collision with apt's upstream
# valkey-server.service which is purged by purge_legacy_valkey_units()).
# Downstream phases use `systemctl ... valkey-gnode` like they would
# for the apt-installed package.
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
        # USE_SYSTEMD=yes lets the unit use Type=notify; BUILD_TLS=no
        # keeps the dep set lean (we don't terminate TLS at the daemon
        # for Geodineum's intra-host topology).
        if ! make USE_SYSTEMD=yes BUILD_TLS=no -j"$(nproc)" >/dev/null 2>&1; then
            return 1
        fi

        install -m 0755 src/valkey-server /usr/local/bin/valkey-server
        install -m 0755 src/valkey-cli    /usr/local/bin/valkey-cli
        # redis-cli compat shim — many ecosystem scripts + ops habits
        # type `redis-cli`; this lets them keep working post-source-build.
        ln -sf /usr/local/bin/valkey-cli /usr/local/bin/redis-cli

        # System user + group for the daemon (no shell, no home). The
        # uninstaller removes the user but leaves the group (per its
        # "preserved if it has members" gate); a subsequent install run
        # then hits `useradd: group valkey exists - if you want to add
        # this user to that group, use -g.` and fails to create the
        # user. Then `install -o valkey` fails with "invalid user
        # 'valkey'", /var/lib/valkey isn't created, and the daemon
        # can't start. Be explicit about the group binding.
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

# thin wrappers over the generic primitives in lib/component-primitives.sh.
# The valkey-specific recovery patterns (statoverride cleanup, system-user
# creation, half-configured-package recovery) generalize to any apt-installed
# system daemon; the generic versions can be re-used for future components
# (gNode extensions, gCore pro managers, etc.).
clear_orphaned_valkey_statoverrides() {
    clear_orphaned_statoverrides valkey redis
}

ensure_valkey_system_user() {
    ensure_system_user valkey /var/lib/valkey "Valkey Server"
}

# thin wrapper. Two-layer dpkg recovery (missing /etc/<pkg>/ dir,
# missing conffile) is generic — see ensure_package_configured in
# lib/component-primitives.sh.
ensure_valkey_package_configured() {
    ensure_package_configured valkey-server /etc/valkey /etc/valkey/valkey.conf
}

# thin wrapper. valkey.conf's `dir /var/lib/valkey` directive +
# the systemd unit's ReadWritePaths require these two dirs; an earlier
# `apt purge` cycle wipes them. /run/valkey is recreated each boot by
# RuntimeDirectory=valkey so we only touch the persistent paths.
ensure_valkey_data_dirs() {
    ensure_data_dirs valkey valkey 0750 /var/lib/valkey /var/log/valkey
}

# Generate (or recover) the ValKey admin password and ensure requirepass
# is set in /etc/valkey/valkey.conf.
#
# Idempotent (decision T): if /etc/geodineum/credentials/valkey.password
# exists with content, we re-use it (and align requirepass to it).
# Otherwise we generate fresh via `openssl rand -base64 32`.
#
# Must be called BEFORE the first `systemctl start valkey-server` so the
# server comes up authenticated. Phase 6's ensure_bootstrap_env_written
# normally creates the credentials/ dir; we create it here too because
# Phase 4 runs before Phase 6.
#
# Permissions: credentials dir 0750 root:geodineum, password file 0640
# ${DEPLOY_USER}:geodineum (per invariant F — file-path secrets only).
# configure aclfile in valkey.conf so ACL SETUSER + ACL SAVE actually
# persist across valkey restarts. Without this, the ACL users we provision
# (gnode_daemon, geodineum_dashboard, gnode_client_*) live in memory only.
# `ACL SAVE` silently no-ops (its error is swallowed by `|| true` in
# provision_daemon_acl), so any restart — boot, logrotate, manual — wipes
# the ACL and the next auth attempt fails with WRONGPASS.
#
# Must be called BEFORE the restart that picks up requirepass, so both
# the password and aclfile take effect together.
ensure_valkey_aclfile_configured() {
    local conf_file="/etc/valkey/valkey.conf"
    # aclfile lives under the valkey data dir, NOT /etc/valkey. The
    # systemd unit runs valkey-server with ProtectSystem=strict, which makes
    # /etc read-only TO THE DAEMON regardless of file ownership. With the
    # aclfile in /etc, every `ACL SAVE` failed with "Read-only file system",
    # so daemon/dashboard/per-site ACL users never persisted and the next
    # restart reloaded a default-only file → WRONGPASS for all of them +
    # a crashed daemon. /var/lib/valkey is in the unit's ReadWritePaths,
    # so the daemon can actually rewrite the aclfile there.
    local acl_file="/var/lib/valkey/users.acl"
    local admin_pwfile="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}/valkey.password"

    if [[ ! -f "$conf_file" ]]; then
        return 0
    fi

    # users.acl must define the default user with the admin
    # password BEFORE the restart that enables aclfile mode. Once aclfile
    # is set, default is governed by users.acl, not requirepass — an
    # empty file causes valkey to reset default to nopass.
    # Valkey 8.0.2 rejects comment lines too: every line must start with
    # the 'user' keyword.
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

ensure_valkey_admin_password_set() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local pwfile="${cred_dir}/valkey.password"
    local conf_file="/etc/valkey/valkey.conf"

    if [[ ! -f "$conf_file" ]]; then
        log_warning "No ${conf_file} — skipping admin password setup"
        return 0
    fi

    # Enforce dir perms on EVERY install, not just creation.
    # dir root:geodineum-creds 0751. o+x allows traversal so www-data
    # (which is NOT in geodineum-creds) can reach valkey_client_<site>.password
    # files (owned gnode:www-data). Listing is still group-only (no o+r),
    # and per-file modes still hide the admin/daemon passwords from www-data.
    # Previously,: 0750 blocked traversal entirely, making client ACL passwords
    # unreachable from PHP and breaking gCore's bootstrap-loader with "no
    # readable ValKey password under /etc/geodineum/credentials".
    # --keep-data preserves this dir across reinstall, so a stale 0750
    # would survive and silently force every site into free-tier. install -d
    # is idempotent — it re-applies mode+ownership to an existing dir — so
    # we run it unconditionally rather than only when the dir is absent.
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
        # admin password owned root:geodineum-creds. Root writes
        # initial value; geodineum-creds group readers (gnode daemon +
        # deploy_user) can read for ACL operations. www-data CANNOT
        # read (not in geodineum-creds group).
        chown "root:geodineum-creds" "$pwfile" 2>/dev/null || true
        log_success "Generated ValKey admin password at ${pwfile}"
    fi

    # Idempotent requirepass: replace if present, append if absent.
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

# Verify the admin password authenticates against running ValKey.
# Allows ~5s for valkey-server to bind/accept after restart. Soft-fail:
# returns non-zero on failure but does not exit (caller decides).
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

    # Only needed if profile includes daemon or client
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

    # When Phase 1 detected an already-running valkey-server, we still
    # need to enforce Geodineum's auth contract: requirepass set in the
    # conf, admin password file at /etc/geodineum/credentials/valkey.password,
    # and authenticated PING on the canonical port. Pre-fix this branch
    # short-circuited the entire phase — leaving downstream phases (7, 8,
    # 9, Verification) to fail when the existing valkey was running on
    # the default port or without auth.
    if [[ "$VALKEY_RUNNING" == "true" ]]; then
        log_info "ValKey already running — verifying Geodineum auth contract"
        ensure_valkey_data_dirs
        # admin_password_set MUST run before aclfile_configured so
        # the latter can read the password and seed users.acl's default
        # user before the restart enables aclfile mode.
        ensure_valkey_admin_password_set
        ensure_valkey_aclfile_configured

        # Apply requirepass — valkey-server only honors a new requirepass
        # after restart (or CONFIG SET REWRITE, but we don't have admin
        # auth yet for that). Restart is the simpler invariant.
        if [[ -f /etc/valkey/valkey.conf ]]; then
            systemctl restart valkey-gnode 2>/dev/null || true
        fi

        if verify_valkey_admin_auth; then
            log_success "ValKey running and authenticated"
            # the resume path above rewrote users.acl (default user only) and
            # restarted ValKey, which drops the runtime-provisioned SERVICE ACL users.
            # The fresh path re-provisions them at the end of this phase; on the resume
            # path we must do it here too, before the early return — otherwise any
            # reinstall/resume leaves gnode_daemon/COMMS/dashboard unable to auth
            # (WRONGPASS → daemon won't start, Lua load + onboarding fail). Idempotent:
            # each provision_*_acl recovers the existing password from its cred file.
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
        # Reset the flag so the path below treats this as an install case.
        VALKEY_RUNNING=false
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Detect or install ValKey"
        return
    fi

    # Delegate to gNode's smart setup script if available
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
        # Re-detect after setup
        detect_valkey
        return
    fi

    # Fallback: manual ValKey installation
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

    # validate input. Pre-fix the case statement silently fell
    # through on any non-1/2/3 keystroke (operator muscle-memory hitting
    # `y` after a sequence of yes/no prompts is a natural failure mode).
    # No installation occurred → Phase 7 failed (no admin password) →
    # Phase 8/9 cascaded → [FAIL] ValKey Setup at Phase 10. Validate up
    # front and snap to the documented default.
    if [[ ! "${valkey_choice:-1}" =~ ^[123]$ ]]; then
        log_warning "Invalid choice '${valkey_choice}' — defaulting to (1) native"
        valkey_choice="1"
    fi

    case "${valkey_choice:-1}" in
        1)
            log_info "Installing Valkey..."

            # Purge any legacy unit names BEFORE installing. Idempotent;
            # ensures the canonical valkey-gnode.service is the only ValKey
            # systemd unit. See purge_legacy_valkey_units() docstring for
            # the rename rationale.
            purge_legacy_valkey_units

            # ── dpkg pre-flight ────────────────────────────────────────────
            # Self-heal corruption a previously uninstall (or any broken
            # install cycle) could have left behind: orphaned statoverride
            # records pointing at a deleted 'valkey' user, missing system
            # user, missing /etc/valkey/ directory, missing conffile, or
            # half-configured valkey-server stuck in 'iF'. Without this,
            # `apt-get install valkey-server` fails at postinst and EVERY
            # subsequent apt op fails the same way (dpkg keeps re-
            # attempting the failed configure). Ordering matters:
            # statoverrides cleared first (so adduser doesn't conflict),
            # then user created, then ensure_valkey_package_configured
            # creates /etc/valkey/, runs `dpkg --configure -a`, and if the
            # conffile is still missing escalates to a --force-confmiss
            # reinstall.
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

            # Resolution path:
            #   1. Try `valkey-server` from native apt (Ubuntu 24.04+, Debian 13+).
            #   2. Try `valkey` (alias the PPA might use).
            #   3. Build Valkey from source — works on any Ubuntu/Debian.
            # If redis-server is already installed from a previous run,
            # stop + purge it first (operator-confirmed: actual Valkey, not
            # the redis-server fallback).
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

            # Recover from a half-purged install: when valkey-server has been
            # `apt purge`-d in the past, dpkg marks /etc/valkey/valkey.conf
            # as obsolete and skips re-extracting it on a plain reinstall —
            # leaving the package "installed" but conffile-less, while the
            # systemd unit hard-codes that exact path in ExecStart. Detect +
            # repair with --force-confmiss; otherwise valkey-server fails on
            # boot and ensure_valkey_admin_password_set silently bails.
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

            # Per-package config + service identity. Source build sets up
            # both /etc/valkey/valkey.conf and the systemd unit itself
            # already, so the apt-installed paths are the only ones we
            # rewrite here. The canonical systemd unit name is
            # `valkey-gnode.service` regardless of install path — the apt
            # path's upstream valkey-server.service is purged + replaced
            # by ensure_canonical_valkey_unit().
            local conf_file="/etc/valkey/valkey.conf"
            local svc_name="valkey-gnode"

            if [[ "$valkey_pkg" != "valkey-source" ]] && [[ -f "$conf_file" ]]; then
                sed -i "s/^port .*/port 47445/" "$conf_file"
                log_detail "Configured ${svc_name} port 47445 (in ${conf_file})"

                # Apt path: re-purge (apt re-installed valkey-server.service
                # behind our back) + write our canonical valkey-gnode.service
                # pointing at the apt-installed binary.
                purge_legacy_valkey_units
                ensure_canonical_valkey_unit
            fi

            # Ensure /var/lib/valkey + /var/log/valkey exist with valkey:valkey
            # ownership. An earlier `apt purge` cycle may have wiped them;
            # valkey.conf's `dir /var/lib/valkey` (line 507) would then make
            # the daemon exit 1 on startup with "No such file or directory".
            ensure_valkey_data_dirs

            # Generate the admin password + inject requirepass BEFORE the
            # first start so valkey-server comes up authenticated.
            # ensure_valkey_admin_password_set is idempotent.
            ensure_valkey_admin_password_set

            # Configure aclfile + seed users.acl with the
            # default user. MUST run after admin_password_set (needs the
            # password) and BEFORE the restart (so default user retains
            # password across the aclfile takeover).
            ensure_valkey_aclfile_configured

            systemctl enable "${svc_name}" 2>/dev/null || true
            systemctl restart "${svc_name}" 2>/dev/null || systemctl start "${svc_name}" 2>/dev/null || true

            # Validate that valkey-server is actually accepting auth on
            # the canonical port BEFORE claiming success. Pre-fix this
            # block unconditionally set VALKEY_RUNNING=true and
            # log_success'd "Valkey running" — even when the daemon
            # had failed to start (e.g. /var/lib/valkey wasn't created
            # because the valkey user creation failed; the daemon
            # exited on first AOF write). Phase 7 + Phase 9 then hit
            # "Connection refused" while the install summary reported
            # 10/10 OK. Decision T (phase tracker reflects ground
            # truth) applies here as much as to Build.
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
                # Don't exit — let downstream phases skip cleanly with
                # their existing VALKEY_RUNNING checks. The summary will
                # show [FAIL] ValKey Setup via the return-non-zero below.
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

    # Replica configuration: if user chose "replica" tier, set up replication
    # to the constellation master. Local ValKey acts as a read replica.
    if [[ "$VALKEY_REPLICA" == "true" ]]; then
        configure_valkey_replica
    fi

    # gnode-daemon ACL user — primary runtime auth for the daemon itself.
    # gNode/scripts/load-valkey-functions.sh (Phase 9) and gNode/scripts/
    # install-gnode-service.sh (Phase 8) both expect the daemon-tier
    # password at well-known paths; without this provisioning step they
    # fail with WRONGPASS / "ValKey password file not found" while Phase 4
    # itself reports OK. Master-only, same as
    # provision_dashboard_acl.
    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_daemon_acl
    fi

    # COMMS ACL user — previously the geodineum_comms ACL user
    # was hand-provisioned (Mar 2026) and fresh installs silently shipped
    # a COMMS daemon that could never authenticate. Master-only, same
    # rationale as provision_daemon_acl.
    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_comms_acl
    fi

    # gDash dashboard ACL user — read-only across all keys, narrow xadd to the
    # operator audit-log stream (planned write surface). Idempotent. Master-only:
    # replicas inherit the ACL via replication, and ACL SETUSER would fail
    # on a read-only replica (and would generate a divergent local password
    # file that doesn't match the master's). On replicas the operator
    # copies /etc/geodineum/dashboard/geodineum-dashboard.txt from the
    # master after `geodineum constellation join-replica` completes.
    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_dashboard_acl
    fi

    # Replication ACL user — lets constellation workers attach as read
    # replicas without exposing the admin password or weakening
    # gnode_daemon (which is -@dangerous and therefore cannot PSYNC).
    # Master-only; the worker copies valkey_replica.password and authes
    # as masteruser gnode_replica.
    if [[ "$VALKEY_RUNNING" == "true" ]] && [[ "$VALKEY_REPLICA" != "true" ]]; then
        provision_replica_acl
    fi
}

# Provision the gnode_daemon ACL user (closes Phase 8 + Phase 9 gap).
#
# The gnode-daemon binary, install-gnode-service.sh, and load-valkey-
# functions.sh all auth as the ACL user `gnode_daemon`. Previously, nothing
# created that user — Phase 8 service install aborted with "ValKey
# password file not found", Phase 9 Lua-load aborted with WRONGPASS.
# Phase 4 reported [OK] because the admin auth verify (provision_dashboard_acl
# uses admin) succeeded.
#
# ACL grants: full read/write across all keys (~*) since the daemon is
# the canonical writer for every Geodineum key shape; +function-load for
# Lua-library installation; -@dangerous to block flushall/shutdown/debug.
# Per ACL_MODEL invariant: the daemon has its own user, distinct from
# admin (admin only used by the installer + operator).
#
# Credential at /etc/geodineum/credentials/valkey_daemon.password (the
# canonical path load-valkey-functions.sh reads) AND symlinked at
# /opt/geodineum/gNode/.gnode/valkey_daemon.password (where install-
# gnode-service.sh looks). Mode 0640 ${DEPLOY_USER}:gnode.
#
# Idempotent: re-runs reuse existing password.
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

    # Generate or recover the daemon password.
    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        chmod 0640 "$cred_file" 2>/dev/null || true
        # daemon credential owned gnode:geodineum-creds. Daemon
        # (gnode user) owns and reads; deploy_user reads via group for
        # `geodineum` CLI operations. www-data CANNOT read.
        chown "gnode:geodineum-creds" "$cred_file" 2>/dev/null || true
        log_success "Generated gnode_daemon credential at ${cred_file}"
    fi

    # Apply the ACL — broad grants for the daemon itself, dangerous-band
    # disallowed (still leaves @all so KEYS is technically allowed but
    # the cluster-safety invariant requires SCAN — runtime-side
    # discipline; ACL is permissive at the daemon tier).
    if ! REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" \
        ACL SETUSER gnode_daemon \
        on \
        resetpass ">${password}" \
        resetkeys "~*" \
        resetchannels "&*" \
        +@all \
        -@dangerous \
        +function +xinfo \
        >/dev/null; then
        log_warning "ACL SETUSER gnode_daemon failed — see output above"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return 1
    fi

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    # Mirror the credential into gNode's expected lookup path.
    # install-gnode-service.sh reads $PROJECT_ROOT/.gnode/valkey_daemon.password;
    # the systemd unit's User=gnode reads from /etc/geodineum/credentials/
    # at runtime via bootstrap-loader. Two paths, same content — symlink
    # avoids drift. The .gnode/ dir itself needs to exist + be traversable
    # by the gnode runtime user.
    # Best-effort early symlink: when phase_valkey runs in Phase 4,
    # /opt/geodineum/gNode/ doesn't exist yet (cloned in Phase 5), so
    # this no-ops on first install. ensure_daemon_credential_symlink
    # is also called from phase_services right before
    # install-gnode-service.sh, where the gNode tree is guaranteed
    # to exist. Idempotent.
    ensure_daemon_credential_symlink

    log_success "ACL user gnode_daemon provisioned (full grants, @dangerous denied)"
}

# Provision the gnode_replica ACL user (constellation read-replica auth).
#
# Replication (PSYNC/REPLCONF/SYNC) lives in the @dangerous category, so the
# daemon user — granted -@dangerous — cannot drive it. Rather than hand the
# admin password to every worker, the master mints a minimal-privilege
# replication user: no keys, no channels, only the three replication-protocol
# commands. A worker copies valkey_replica.password and sets
# `masteruser gnode_replica` (setup-valkey-replica.sh does this).
#
# Idempotent: re-runs reuse the existing password. Credential at
# /etc/geodineum/credentials/valkey_replica.password (gnode:geodineum-creds
# 0640) — same shape as the daemon credential so the operator copies it the
# same way.
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

    # Minimal replication user: no key/channel access, only the
    # replication-protocol commands. +ping lets the replica health-check
    # the link; +psync/+replconf are the PSYNC handshake.
    if ! REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" \
        ACL SETUSER gnode_replica \
        on \
        resetpass ">${password}" \
        resetkeys \
        resetchannels \
        nocommands \
        +psync +replconf +ping \
        >/dev/null; then
        log_warning "ACL SETUSER gnode_replica failed — see output above"
        return 1
    fi

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true
    log_success "ACL user gnode_replica provisioned (replication-only; copy ${cred_file} to workers)"
}

# Provision the geodineum_comms ACL user.
#
# The COMMS binary defaults to ACL username `geodineum_comms`
# (Geodineum-COMMS/src/config.rs `redis_user` default; overridable via
# VALKEY_USER env) and the systemd unit feeds it the password from
# /etc/geodineum/credentials/valkey_comms.password. Previously NOTHING
# in the installer created either — the ACL user + credential were
# hand-provisioned on the original host, so a fresh install produced a
# COMMS daemon that could never authenticate.
#
# ACL grants: same tier shape as gnode_daemon (+@all -@dangerous).
# COMMS reads/acks the {site}:gnode:comms:{env} streams, writes
# inference-request streams, session hashes, and pubsub — key patterns
# span sites, so ~* is required. Tightening to per-category grants is a
# post-launch refinement; the isolation win is the dedicated
# Unix user + dedicated password, not command scoping.
#
# Credential: root:geodineum-comms 0640 — root owns (daemon cannot
# rewrite its own credential), geodineum-comms group reads. Idempotent:
# recovers an existing password rather than rotating it.
provision_comms_acl() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local cred_file="${cred_dir}/valkey_comms.password"
    local admin_pwfile="${cred_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER geodineum_comms with @all -@dangerous; write ${cred_file} (0640 root:geodineum-comms)"
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

    # Generate or recover the COMMS password.
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

    if ! REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" \
        ACL SETUSER geodineum_comms \
        on \
        resetpass ">${password}" \
        resetkeys "~*" \
        resetchannels "&*" \
        +@all \
        -@dangerous \
        +xinfo \
        >/dev/null; then
        log_warning "ACL SETUSER geodineum_comms failed — see output above"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return 1
    fi

    REDISCLI_AUTH="$(cat "$admin_pwfile")" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    log_success "ACL user geodineum_comms provisioned (daemon-tier grants, @dangerous denied)"
}

# ensure /opt/geodineum/gNode/.gnode IS a symlink to the
# centralized credential store /etc/geodineum/credentials/.
#
# Previously `.gnode/` was a directory containing one
# per-file symlink (valkey_daemon.password → centralized). New
# credentials (e.g. site-specific) would each need their own symlink.
#
# Now (validator-aligned): `.gnode` itself is a symlink to the
# centralized store. Any file under /etc/geodineum/credentials/
# becomes automatically accessible at /opt/geodineum/gNode/.gnode/<name>
# — no per-file work, scales for site credentials and future ACL users.
#
# install-gnode-service.sh's chmod/chown operations on .gnode/*.password
# follow the symlink and act on the centralized file, which is exactly
# what we want (the centralized file's mode/owner is the canonical
# truth; .gnode/ is just a view onto it).
#
# Idempotent:
#   - if .gnode is already the correct symlink → no-op
# - if .gnode is a directory (legacy state) → remove
#     it before symlinking (we re-create as symlink; existing per-file
#     symlinks inside are no longer needed since the parent is now the
#     symlink)
#   - if .gnode is a stale symlink to somewhere else → replace
#
# Called twice: once from provision_daemon_acl (Phase 4, best-effort
# early; no-ops on fresh install since gNode isn't cloned yet), once
# from phase_services (Phase 8, canonical site — gNode tree is
# guaranteed to exist).
ensure_daemon_credential_symlink() {
    local cred_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    local gnode_root="${INSTALL_ROOT:-/opt/geodineum}/gNode"
    local link_path="${gnode_root}/.gnode"

    [[ -d "$gnode_root" ]] || return 0
    [[ -d "$cred_dir" ]]   || return 0

    # Already the correct symlink → no-op
    if [[ -L "$link_path" ]] && [[ "$(readlink "$link_path")" == "$cred_dir" ]]; then
        return 0
    fi

    # Stale directory (legacy layout) or wrong symlink → remove cleanly
    if [[ -L "$link_path" ]]; then
        rm -f "$link_path"
    elif [[ -d "$link_path" ]]; then
        # The dir may contain per-file symlinks or local password
        # files (legacy dev installs). Remove only if it has no
        # non-symlink content beyond what install-gnode-service.sh
        # would have placed there.
        rm -rf "$link_path"
    fi

    ln -s "$cred_dir" "$link_path"
    # Symlink ownership matters for some installers' chown -R; set it
    # to gnode:gnode for consistency. chown -h doesn't follow symlinks
    # (changes the link itself, not the target).
    chown -h gnode:gnode "$link_path" 2>/dev/null || true
    log_detail "Daemon credential view: ${link_path} → ${cred_dir}"
}

# Provision the geodineum_dashboard ACL user.
#
# Creates a read-only ACL user used by the Geodineum Dashboard (gDash) to
# query ValKey from wp-admin. The user has:
#   - +@read across all keys (%R~*) — covers get/hgetall/scan/pfcount/xread etc.
#   - +xadd narrowed to geodineum:audit-log:operator-actions (%W, Ch.1.C audit log)
#   - @write/@admin/@dangerous explicitly disallowed (no xreadgroup — the
#     consumer live-tails via read-only XREAD, never consumer groups)
#
# Credential at /etc/geodineum/dashboard/geodineum-dashboard.txt
# (mode 0640, deploy_user:gnode) per invariant F (file-path secrets only).
#
# Idempotent: re-runs leave existing credentials/ACL alone unless the file is
# missing or empty, in which case a fresh password is generated and written.
provision_dashboard_acl() {
    local creds_dir="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    # dashboard credential lives in its own dir, NOT in
    # credentials/. This is the security boundary — /etc/geodineum/
    # dashboard/ is the ONLY credential location www-data can reach.
    local dash_dir="/etc/geodineum/dashboard"
    local cred_file="${dash_dir}/geodineum-dashboard.txt"
    local admin_pwfile="${creds_dir}/valkey.password"
    local valkey_port="${VALKEY_PORT:-47445}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "ACL SETUSER geodineum_dashboard with read-only + audit-log xadd; write ${cred_file} (0640 gnode:geodineum-dash)"
        return
    fi

    # Migrate legacy credential file locations if present.
    local legacy_cred_file="${creds_dir}/geodineum-dashboard.txt"
    if [[ -f "$legacy_cred_file" ]] && [[ ! -f "$cred_file" ]]; then
        if [[ -d "$dash_dir" ]]; then
            mv "$legacy_cred_file" "$cred_file"
            log_detail "Migrated dashboard credential: ${legacy_cred_file} → ${cred_file}"
        fi
    fi

    # ensure dashboard/ exists. Phase 4 runs before Phase 7's
    # canonical directory creation, so on first install this dir
    # wouldn't exist yet — provision skipped with a "re-run install.sh"
    # hint, leaving the dashboard credential ungenerated until a
    # second install pass. Idempotent helper-style: create if absent
    # with the canonical perms; Phase 7's later install -d on the same
    # path is a no-op.
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

    # Generate or recover the password.
    local password
    if [[ -s "$cred_file" ]]; then
        password="$(cat "$cred_file")"
    else
        password="$(openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-40)"
        umask 077
        printf '%s' "$password" > "$cred_file"
        chmod 0640 "$cred_file" 2>/dev/null || true
        # dashboard credential owned gnode:geodineum-dash 0640.
        # gnode user is the canonical writer (runtime rotation);
        # geodineum-dash group readers include www-data (gCore PHP),
        # gnode, and deploy_user. www-data reads via direct group
        # membership; can traverse /etc/geodineum/dashboard/ via the
        # same group on the parent dir.
        chown "gnode:geodineum-dash" "$cred_file" 2>/dev/null || true
        log_success "Generated geodineum_dashboard credential at ${cred_file}"
    fi

    # Apply the ACL. resetpass clears any previous password before assigning the
    # current one (idempotent).
    local admin_password
    admin_password="$(cat "$admin_pwfile")"

    # Read-only everywhere + append-only to the operator audit log, via
    # ValKey 7+/8 key selectors:
    #   %R~*                                    → read ANY key
    #   %W~geodineum:audit-log:operator-actions → write ONLY the audit log
    # The prior form (`~*` allkeys, then a scoped `~pattern`, then `-@write`
    # AFTER `+xadd`) errored on two counts — a pattern can't follow allkeys,
    # and -@write stripped the xadd right back off — so the SETUSER aborted
    # and the password was never set (every dashboard reader got WRONGPASS).
    # +xadd is re-granted LAST so it survives the -@write removal; the %W
    # selector is what actually confines writes to the single audit key.
    if ! REDISCLI_AUTH="$admin_password" valkey-cli -p "$valkey_port" \
        ACL SETUSER geodineum_dashboard \
        on \
        resetpass ">${password}" \
        resetkeys "%R~*" "%W~geodineum:audit-log:operator-actions" \
        resetchannels \
        +@read \
        -@write -@admin -@dangerous \
        -flushall -flushdb -shutdown -debug -config -script \
        +xadd \
        >/dev/null; then
        log_warning "ACL SETUSER geodineum_dashboard failed — see output above"
        log_info "Retry: sudo REDISCLI_AUTH=\"\$(cat ${admin_pwfile})\" valkey-cli -p ${valkey_port} ACL LIST"
        return
    fi

    # Persist the ACL so it survives ValKey restarts.
    REDISCLI_AUTH="$admin_password" valkey-cli -p "$valkey_port" ACL SAVE >/dev/null 2>&1 || true

    log_success "ACL user geodineum_dashboard provisioned (read-only + audit-log xadd)"
}

# Configure local ValKey as a replica of the constellation master.
# Prompts for master IP/credentials and writes the replica directives
# via setup-valkey-replica.sh.
configure_valkey_replica() {
    log_step "Phase 4b/10: ValKey Replica Configuration"

    local replica_script="${INSTALL_ROOT}/gNode/scripts/setup-valkey-replica.sh"
    if [[ ! -x "$replica_script" ]]; then
        log_warning "setup-valkey-replica.sh not found at $replica_script"
        log_info "Configure replication manually after install"
        return
    fi

    # Master IP defaults to constellation VPN gateway
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

# Verify GitHub auth works before any clone is attempted. Tests against
# geodineum/Geodineum (the installer repo itself, which we know exists).
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

    # Failed — give actionable error
    log_error "Cannot reach ${test_repo} via ${GITHUB_CLONE_PREFIX}"
    echo ""
    echo -e "  ${BOLD}All Geodineum repos are currently private.${NC} You need either:"
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

    # Preflight: confirm GitHub auth before attempting any clone.
    # All Geodineum repos are currently private — fail fast with a useful
    # message rather than 8 cryptic "Repository not found" errors.
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

    # Deploy the installer repo to /opt/geodineum/Geodineum so the
    # geodeploy infra (lib/geodeploy.sh, scripts/geodeploy-orchestrator,
    # geodineum CLI binary) is reachable at the canonical FHS-style
    # location. Operators run install.sh from a dev clone (e.g.
    # ~/gh/Geodineum); without this step, /opt/geodineum/Geodineum never
    # exists and Phase 8/9/post-install hooks all hit "not found"
    # warnings.
    install_self_to_opt

    # Clone gNode-CMS into /opt/geodineum/pro/gNode/ — the canonical
    # signed-extension location. CMS is the default-shipped extension;
    # additional extensions land alongside it under pro/gNode/. To skip
    # cloning CMS (lean gNode build without any extensions), set
    # GEODINEUM_SKIP_CMS=true.
    if [[ "${GEODINEUM_SKIP_CMS:-false}" != "true" ]]; then
        fetch_extension "gnode-cms" "geodineum/gNode-CMS" || {
            log_warning "Failed to clone gNode-CMS — daemon will build WITHOUT CMS handlers"
            log_info "Sites/services depending on CMS commands won't work until CMS is cloned + signed"
            log_info "Retry: GEODINEUM_SKIP_CMS=false ./install.sh"
        }
    else
        log_info "GEODINEUM_SKIP_CMS=true — skipping gNode-CMS clone (lean build)"
    fi

    # Update GNODE_SCRIPTS now that gNode may be fetched
    if [[ -d "${INSTALL_ROOT}/gNode/scripts" ]]; then
        GNODE_SCRIPTS="${INSTALL_ROOT}/gNode/scripts"
    fi
}

# Clone a signed extension into /opt/geodineum/pro/gNode/<name>/.
# Mirrors fetch_component but writes to the extension dir rather than
# the standard component dir. Idempotent (pull if .git exists).
fetch_extension() {
    local ext_name="$1"           # e.g. "gnode-cms"
    local ext_repo="$2"           # e.g. "geodineum/gNode-CMS"
    local ext_dir_name="${ext_repo##*/}"   # "gNode-CMS"
    local ext_parent="${INSTALL_ROOT}/pro/gNode"
    local ext_dir="${ext_parent}/${ext_dir_name}"
    local branch="${GEODINEUM_BRANCH:-}"
    local branch_label="${branch:-<default>}"

    # Ensure the parent extension dir exists. gnode user owns it
    # (group model: gnode is the extension steward).
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

# Mirror the installer repo (the one running this script) into
# ${INSTALL_ROOT}/Geodineum so that paths like
#   /opt/geodineum/Geodineum/lib/geodeploy.sh
#   /opt/geodineum/Geodineum/scripts/geodeploy-orchestrator
#   /opt/geodineum/Geodineum/geodineum  (CLI binary)
# resolve at runtime.
#
# Strategy:
#   * If the source is a git clone with origin set, do a fresh `git clone`
#     of origin into the canonical path (matches the other components'
#     deploy pattern; auto-deploy cron can pull updates).
#   * If the source is a tarball / non-git checkout, fall back to rsync.
#   * Idempotent: existing /opt/geodineum/Geodineum gets `git pull`'d
#     instead of re-cloned.
install_self_to_opt() {
    local target="${INSTALL_ROOT}/Geodineum"
    local source="${SCRIPT_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Mirror installer ${source} → ${target}"
        return 0
    fi

    # Source has a git origin → do a real clone (matches the other 7
    # components' deploy pattern).
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

    # No git origin → rsync the source tree.
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

    # Branch resolution: --branch / GEODINEUM_BRANCH overrides per-repo default.
    # Empty value falls back to remote HEAD (typically `main`).
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
        # Pull as calling user (SSH keys are theirs)
        local pull_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
        # Surface git's own error on failure. The old 2>/dev/null hid the
        # diagnostic entirely (a permission-broken .git printed only
        # "fetch failed", costing a debugging round-trip on the squad join).
        local git_err
        if [[ -n "$branch" ]]; then
            # Explicit branch — fetch + checkout + ff-only pull. Detached or
            # mismatched checkouts get aligned with origin/<branch>.
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
        # Clone as the deploy user (SSH deploy key lives in
        # ${DEPLOY_HOME}/.ssh/id_ed25519_geodeploy per phase_deploy_user).
        # Pre-fix: clone used $SUDO_USER, which on a fresh install where the
        # operator runs `sudo ./install.sh` from a different user account
        # than the chosen deploy user (e.g., personal admin user with sudo
        # invoking install for a deploy_user system account) would leave
        # all subsequent /opt/geodineum/<repo> trees owned by SUDO_USER
        # instead of DEPLOY_USER. Phase 8's geodeploy_fix_perms would later
        # try to chown to DEPLOY_USER, but `sudo -u SUDO_USER git pull`
        # update path used DEPLOY_USER fallback — divergent ownership
        # between clone-time and update-time created git "dubious
        # ownership" failures on subsequent runs. Now uniform on
        # DEPLOY_USER (matching the update path's pattern at line 2019).
        local clone_branch_arg=""
        [[ -n "$branch" ]] && clone_branch_arg="--branch ${branch}"
        local clone_cmd="git clone ${clone_branch_arg} ${GITHUB_CLONE_PREFIX}${repo}${GITHUB_CLONE_SUFFIX} ${install_dir}"
        # Let git write progress + errors to the terminal directly. No
        # capture, no /dev/null. The previous version's `$(cmd 2>&1 >/dev/null)`
        # construct interacted badly with `set -euo pipefail` — even when
        # git clone exited 0, the assignment-with-redirect-and-errexit chain
        # propagated a non-zero status to the function, making
        # log_success run AND the outer caller see "Failed to fetch".
        # Simpler is better here: if clone fails, git's own error message
        # is already printed to the terminal, no pattern-matching needed.
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

# Read cargo-style build output on stdin; render a progress bar to
# /dev/tty against TOTAL "Compiling X" lines; pass errors, warnings,
# Finished, and unrecognised lines through to stdout (which install.sh
# tees to the log file). Cargo chatter (Locking/Downloading/Downloaded/
# Fresh/Adding) is absorbed silently. The bar overwrites itself via \r,
# so the terminal stays clean.
#
# Caller is responsible for has-TTY gating; this function assumes
# /dev/tty is writable.
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

# Probe controlling TTY independent of stdout redirection. Returns 0
# if /dev/tty is usable (i.e. we can render a progress bar to it).
# install.sh redirects stdout to a tee at startup, so `[[ -t 1 ]]`
# always returns false inside the script — has to probe /dev/tty
# directly.
_has_controlling_tty() {
    [[ "${NO_BUILD_PROGRESS:-}" != "1" ]] && ( exec 3>/dev/tty ) 2>/dev/null
}

# Count crates that a `cargo build` would compile. Pre-build estimate
# used as the denominator for the progress bar. Cheap — cargo tree
# reads Cargo.lock without compiling.
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

# Run an arbitrary build command and render its output via the
# cargo-progress filter. The command must emit cargo-style "Compiling
# X" / "Finished" lines (anything that wraps `cargo build` qualifies —
# e.g. a project's own scripts/build.sh).
#
# CARGO_DIR is used for the pre-count via `cargo tree`; it must contain
# a Cargo.toml. BUILD_CMD is passed to `bash -c`, run via sudo as
# BUILD_USER, in the CARGO_DIR (override with `cd` in BUILD_CMD if
# needed).
#
# Usage:
#   build_cmd_with_progress LABEL CARGO_DIR BUILD_USER BUILD_CMD [ENV_KV ...]
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

# Backwards-compatible thin wrapper: run `cargo build --release` with
# the standard cargo-env-sourcing prelude.
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

    # gNode's scripts/build.sh expects /usr/local/lib/geodineum/bootstrap-loader.sh
    # (canonical FHS path) AND /etc/geodineum/bootstrap.env to exist. Both
    # are normally written by phase_config (Phase 7), but Phase 6 runs
    # first — so we lay them down here before any compile step. Both calls
    # are idempotent: phase_config's later writes are no-ops when files
    # already exist with the right content.
    ensure_bootstrap_loader_installed
    ensure_bootstrap_env_written

    # Aggregate per-component build failures. Without this, a cargo panic
    # in build_component would print [ERR] but phase_build would still
    # return 0 (for-loop's last exit), so PHASE_RESULTS["Build"] got
    # recorded as OK while the daemon binary was missing. Decision T:
    # ensure the phase tracker reflects ground truth.
    local rc=0
    for comp in "${resolved[@]}"; do
        build_component "$comp" || rc=$?
    done
    return $rc
}

# Install canonical helper libs to /usr/local/lib/geodineum/. Idempotent.
# Originally only deployed bootstrap-loader.sh ; now also deploys the
# manifest libs + cli-helpers so any consumer (handler scripts, register-site,
# orchestrator) can resolve them via the one canonical search path instead
# of relying on /opt/geodineum/Geodineum/lib being on disk.
ensure_bootstrap_loader_installed() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "install ${LIB_DIR}/{bootstrap-loader,common,cli-helpers,manifest-registry,manifest-policy,manifest-install}.sh → /usr/local/lib/geodineum/"
        return 0
    fi
    if [[ ! -f "${LIB_DIR}/bootstrap-loader.sh" ]]; then
        log_warning "bootstrap-loader.sh source not found at ${LIB_DIR}/bootstrap-loader.sh"
        return 1
    fi
    install -d -m 0755 -o root -g root /usr/local/lib/geodineum

    # Required core: bootstrap-loader
    install -m 0755 -o root -g root \
        "${LIB_DIR}/bootstrap-loader.sh" \
        /usr/local/lib/geodineum/bootstrap-loader.sh

    # Optional helpers — present in source for new installs, may be absent on
    # older source trees (we don't fatal). Each handler library is independent.
    local _helper
    for _helper in common.sh cli-helpers.sh manifest-registry.sh manifest-policy.sh manifest-install.sh; do
        if [[ -f "${LIB_DIR}/${_helper}" ]]; then
            install -m 0755 -o root -g root \
                "${LIB_DIR}/${_helper}" \
                "/usr/local/lib/geodineum/${_helper}"
        fi
    done

    log_success "Helper libs available at /usr/local/lib/geodineum/"
}

# Write /etc/geodineum/bootstrap.env with the minimal 3-key surface that
# bootstrap-loader.sh's load_bootstrap_disk_tier requires. Called from
# phase_build BEFORE any compile step because gNode's scripts/build.sh
# sources bootstrap-loader.sh + calls load_ecosystem_config + that
# requires bootstrap.env to exist. Phase 7's phase_config still writes
# the same file later (idempotent — same defaults, same path, same
# permissions). Fast path: if the file already exists, no-op.
ensure_bootstrap_env_written() {
    local env_file="/etc/geodineum/bootstrap.env"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "write ${env_file} (3 whitelisted keys: VALKEY_HOST/PORT/CREDS_PATH)"
        return 0
    fi
    if [[ -s "$env_file" ]]; then
        # 2026-06-03 content-drift self-heal: if existing file has any keys
        # outside the strict whitelist, treat it as drifted state from
        # pre-D.x architecture (the "shared paths/settings" dumping ground
        # design) and rewrite to the canonical 3-key shape. Back up the
        # drifted file for forensics. Daemon will FATAL on any non-whitelisted
        # key, so silently honoring drifted state breaks startup — exactly
        # the failure mode we hit on 2026-06-03 prod canary.
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
        log_warning "These keys belong in ValKey Tier 2 (or were dead post-D.x). The Rust"
        log_warning "bootstrap-loader strict-rejects anything outside {VALKEY_HOST,"
        log_warning "VALKEY_PORT, VALKEY_CREDS_PATH}, so the gnode-daemon would FATAL."
        log_warning "Backing up drifted file to ${env_file}.archived-$(date +%Y%m%d-%H%M%S)"
        cp "$env_file" "${env_file}.archived-$(date +%Y%m%d-%H%M%S)"
        # Preserve the VALKEY values from the drifted file rather than
        # use install-script defaults (operator may have customized).
        local _host _port _creds
        _host=$(grep -E '^VALKEY_HOST=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        _port=$(grep -E '^VALKEY_PORT=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        _creds=$(grep -E '^VALKEY_CREDS_PATH=' "$env_file" | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
        [[ -n "$_host" ]]  && VALKEY_HOST="$_host"
        [[ -n "$_port" ]]  && VALKEY_PORT="$_port"
        [[ -n "$_creds" ]] && VALKEY_CREDS_PATH="$_creds"
        # Fall through to the canonical 3-key write below.
    fi
    # root:geodineum 0751 — o+x traverse required by www-data /
    # geodineum-comms / geodine for their group-readable files; matches
    # lib/geodeploy.sh fix_config_perms (one authority, one mode).
    install -d -m 0751 -o root -g geodineum /etc/geodineum 2>/dev/null \
        || install -d -m 0751 /etc/geodineum
    local host="${VALKEY_HOST:-127.0.0.1}"
    local port="${VALKEY_PORT:-47445}"
    local creds="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"
    install -d -m 0750 -o root -g root "$creds" 2>/dev/null || true
    # Three whitelisted keys ONLY — the bootstrap-loader rejects anything
    # outside the {VALKEY_HOST, VALKEY_PORT, VALKEY_CREDS_PATH} set with
    # a "key not whitelisted" FATAL. Mirror exactly what
    # lib/bootstrap-loader.sh::write_disk_bootstrap produces.
    cat > "$env_file" << EOF_BOOTSTRAP_ENV
VALKEY_HOST=${host}
VALKEY_PORT=${port}
VALKEY_CREDS_PATH=${creds}
EOF_BOOTSTRAP_ENV
    # 2026-06-03 strict-deny posture: root:geodineum-bootstrap 0640 (was
    # root:root 0644 — world-readable, rejected by operator). geodineum-bootstrap
    # is a narrow group containing ONLY {www-data, gnode, deploy_user,
    # geodine} so PHP/daemon/operator reads work via group bit; nothing
    # else on the host can read. If this runs in a fresh-install phase
    # BEFORE phase_users_groups created the group, fall back to root:root
    # 0600 (strictly tighter; daemon's strict-deny check also accepts 0600).
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

            # Signed-extension discovery dir. If gNode-CMS (and
            # any future Pro extensions) was cloned in Phase 5, point
            # build.rs at it. With no GNODE_EXT_DIR, gNode builds lean
            # core (no extensions registered).
            local ext_dir="${INSTALL_ROOT}/pro/gNode"
            local ext_dir_arg=""
            if [[ -d "$ext_dir" ]] && [[ -n "$(ls -A "$ext_dir" 2>/dev/null)" ]]; then
                ext_dir_arg="GNODE_EXT_DIR=${ext_dir}"
                log_detail "Building with signed extensions from ${ext_dir}/"
            fi

            # Use gNode's own build script if available (handles optional extensions)
            # Build as calling user (cargo/rustup are in their home, not root's)
            local build_user="${DEPLOY_USER:-${SUDO_USER:-$(whoami)}}"
            local env_kv=()
            [[ -n "$ext_dir_arg" ]] && env_kv+=("$ext_dir_arg")

            if [[ -x "${install_dir}/scripts/build.sh" ]]; then
                # build.sh ultimately wraps `cargo build --release`, so
                # its stdout is the same shape as a direct cargo invocation
                # (a few extra "Building gNode daemon..." lines around the
                # cargo output, which pass through the filter unchanged).
                # Use cargo_dir = install_dir/daemon for the cargo-tree
                # pre-count; build_cmd cds into install_dir before invoking
                # the script.
                if ! build_cmd_with_progress "gNode daemon" \
                        "${install_dir}/daemon" "$build_user" \
                        "cd ${install_dir} && bash scripts/build.sh" \
                        "${env_kv[@]}"; then
                    log_error "Daemon build failed"
                    return 1
                fi
            else
                # Fallback when gNode/scripts/build.sh isn't present.
                # source $HOME/.cargo/env so cargo is on PATH under
                # `sudo -u`.
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
            # gNode-Client ships a composer.json (it's a PHP library
            # gCore depends on). Previously, the build phase skipped it
            # entirely, leaving no vendor/ directory — validate-geodineum-
            # config.sh flagged it as "gNode-Client: composer install
            # needed" in every install summary.
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

            # Create backup directories (gnode-owned — the backup service runs as gnode)
            track_path_if_new "${install_dir}/backups"
            track_path_if_new "${install_dir}/backups/valkey"
            track_path_if_new "${install_dir}/logs"
            mkdir -p "${install_dir}/backups/valkey" 2>/dev/null || true
            mkdir -p "${install_dir}/logs" 2>/dev/null || true
            chown -R gnode:gnode "${install_dir}/backups" "${install_dir}/logs" 2>/dev/null || true
            chmod 750 "${install_dir}/backups" "${install_dir}/backups/valkey" "${install_dir}/logs" 2>/dev/null || true

            # Install logrotate configs
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

            # Install ValKey backup timer + service
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
OnCalendar=*-*-* 02:00:00
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

            # Install the logrotate config. The old setup-log-rotation.sh was
            # retired in the BAK restructure; the canonical conf now ships in
            # the repo and is installed directly to /etc/logrotate.d/. (Without
            # this, log rotation was silently never configured and the success
            # line below was misleading.)
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

phase_config() {
    local resolved=($@)

    log_step "Phase 7/10: Centralized Configuration"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Install lib/bootstrap-loader.sh to /usr/local/lib/geodineum/"
        log_dry "Create /etc/geodineum/ directory structure"
        log_dry "Write /etc/geodineum/bootstrap.env (3 keys, root:geodineum-bootstrap 0640)"
        log_dry "Populate ValKey tier (geodineum:bootstrap:*) with operator config"
        log_dry "Generate gcore.env, create gnode/geodineum users+groups, set credentials perms"
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

    # ── 2. Source the loader (use just-installed prod copy) ──────────────
    # shellcheck source=/usr/local/lib/geodineum/bootstrap-loader.sh
    source /usr/local/lib/geodineum/bootstrap-loader.sh

    # ── 3. Create directory structure ──────────────────────────────────────
    # Each track_path_if_new is a NO-OP when the path already exists,
    # so on a multi-site host where /etc/geodineum already has
    # site_a/credentials from a prior install, a failing site_b install
    # rolls back without touching site_a's state (UX-S2.01).
    track_path_if_new /etc/geodineum
    track_path_if_new /etc/geodineum/components
    track_path_if_new /etc/geodineum/components/gnode-daemon
    track_path_if_new /etc/geodineum/components/gnode-daemon/nodes
    track_path_if_new /etc/geodineum/components/gCore
    track_path_if_new /etc/geodineum/sites

    # ── 3a. Create gnode user + geodineum group BEFORE any chown-using
    # install -d (phase-ordering fix). Previously the install -d
    #       commands below ran first and hit "install: invalid user 'gnode'"
    #       because the gnode system user didn't exist yet — Phase 7's
    #       creation block was AFTER the install -d batch. Directories
    #       failed to be created at all, and Phase 7 cascaded:
    #       /etc/geodineum/components/gCore/ was missing when the
    #       gcore.env write tried to land. Phase 10 validator then
    #       reported "Layer 1: STRUCTURE 0.50 DEGRADED" because the
    #       expected directory tree wasn't there.
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

    # ── 3b. Directory creation with proper ownership.
    # The gnode user now exists, so install -d -o gnode succeeds.
    install -d -m 0751 -o root  -g geodineum /etc/geodineum
    install -d -m 0755 -o gnode -g gnode    /etc/geodineum/components
    install -d -m 0755 -o gnode -g gnode    /etc/geodineum/components/gnode-daemon
    install -d -m 0755 -o gnode -g gnode    /etc/geodineum/components/gnode-daemon/nodes
    install -d -m 0755 -o gnode -g gnode    /etc/geodineum/components/gCore
    install -d -m 0750 -o gnode -g www-data /etc/geodineum/sites

    local deploy_user="${SUDO_USER:-$(whoami)}"

    # credential group memberships (replaces the broad-gnode
    # approach which let www-data into gnode group → catastrophic blast
    # radius on PHP/WP RCE). New scoped model:
    #
    #   gnode group         → gnode user ONLY (no operator accounts).
    #                         Tight: daemon-only privileged access to
    #                         /opt/geodineum/{gNode,COMMS,BAK} + daemon
    #                         credential.
    #   geodineum-creds     → gnode + deploy_user (read credentials/).
    #                         www-data NOT a member — RCE on PHP can't
    #                         read admin or daemon credentials.
    #   geodineum-dash      → gnode + www-data + deploy_user (read
    #                         dashboard/). www-data here is intentional
    #                         and surgical: ONLY the dashboard token,
    #                         which has +@read across ValKey.
    #   geodineum           → empty marker (kept for /opt/geodineum/
    #                         chown back-compat per decision R).
    id -u gnode    &>/dev/null && true   # gnode in gnode primary only
    id -u www-data &>/dev/null && usermod -aG geodineum-dash www-data 2>/dev/null || true
    id -u "$deploy_user" &>/dev/null && usermod -aG geodineum-creds "$deploy_user" 2>/dev/null || true
    id -u "$deploy_user" &>/dev/null && usermod -aG geodineum-dash  "$deploy_user" 2>/dev/null || true
    # gnode user reads its own daemon credential via gnode group
    # ownership; also needs to read admin credential for ACL ops, so
    # add to geodineum-creds. Add to geodineum-dash so the daemon can
    # rotate the dashboard token at runtime (gnode owns the file).
    id -u gnode &>/dev/null && usermod -aG geodineum-creds gnode 2>/dev/null || true
    id -u gnode &>/dev/null && usermod -aG geodineum-dash  gnode 2>/dev/null || true
    # gnode→geodineum-bootstrap: daemon reads bootstrap.env(0640)@start; here not Phase 0 (gnode user absent then → no-op)
    id -u gnode &>/dev/null && usermod -aG geodineum-bootstrap gnode 2>/dev/null || true
    log_success "Group memberships:"
    log_detail "  gnode:           gnode (daemon-only)"
    log_detail "  geodineum-creds: gnode, ${deploy_user} (daemon + admin creds)"
    log_detail "  geodineum-dash:  gnode, www-data, ${deploy_user} (dashboard token)"
    log_detail "  geodineum-bootstrap: gnode (reads bootstrap.env at daemon start)"

    track_path_if_new /etc/geodineum/credentials
    # credentials/ owner root:geodineum-creds 0750. Root writes
    # initial credentials at install time; geodineum-creds group reads.
    # www-data is NOT in geodineum-creds → cannot traverse this dir at
    # all. Daemon + admin credentials are unreadable from any PHP/
    # www-data attack surface.
    install -d -m 0750 -o root -g geodineum-creds /etc/geodineum/credentials

    # Write any master ValKey credentials pasted during a join install
    # (wizard_constellation_credentials). gnode:geodineum-creds 0640 — the
    # daemon (gnode) reads them; www-data cannot. On a worker nothing else
    # provisions these (the ACL users live on the master), so they persist.
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

    track_path_if_new /etc/geodineum/dashboard
    # dashboard/ owner root:geodineum-dash 0750. Dedicated dir
    # for credentials gCore PHP must read at runtime (just the dashboard
    # token currently; future: any www-data-readable ACL credentials).
    # Separating these from credentials/ means PHP RCE can read AT MOST
    # the dashboard ACL credentials, which are bounded to +@read.
    install -d -m 0750 -o root -g geodineum-dash /etc/geodineum/dashboard

    # ── 5. Resolve operator-supplied config values ────────────────────────
    local cfg_valkey_host="${VALKEY_HOST:-127.0.0.1}"
    local cfg_valkey_port="${VALKEY_PORT:-47445}"
    local cfg_valkey_creds_path="${VALKEY_CREDS_PATH:-/etc/geodineum/credentials}"

    # ── 6. Tier 1 — write disk-minimal bootstrap.env (3 keys, root:root 644) ─
    write_disk_bootstrap "$cfg_valkey_host" "$cfg_valkey_port" "$cfg_valkey_creds_path"
    log_success "Wrote /etc/geodineum/bootstrap.env (root:geodineum-bootstrap 0640, 3 strict keys)"

    # ── 7. Tier 2 — populate ValKey-resident config ────────────────────────
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
        # Worker node: the admin credential stays on the master by design,
        # and the master's install already populated the shared tier.
        log_info "Worker node (remote ValKey) — tier population already done on the master; skipping"
    else
        log_warning "Admin ValKey password not yet readable at ${cfg_valkey_creds_path}/valkey.password"
        log_warning "Skipping ValKey tier population — re-run install.sh after credentials are in place"
    fi

    # ── 8. Component-specific gcore.env ───────────────────────────────────
    if [[ ! -f /etc/geodineum/components/gCore/gcore.env ]]; then
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
# Apache hardening (called from phase_services when Apache is the SAPI host)
# =============================================================================

# enable mod_security2 + OWASP Core Rule Set, harden information-leak
# defaults, set sensible request limits. Idempotent.
#
# Why each piece:
#   - libapache2-mod-security2: WAF that blocks common attack patterns
#     (SQL injection, XSS, traversal, scanner signatures) at the Apache layer
#     BEFORE PHP sees the request. Acts on static + PHP paths uniformly,
#     unlike gCore's PHP-emitted security headers which only protect
#     dynamic responses.
#   - modsecurity-crs: OWASP Core Rule Set, the maintained default rule
#     pack. We enable it in DetectionOnly mode initially (logs but doesn't
#     block) so legit traffic isn't broken by overly-strict default rules.
#     Operator can flip to On after reviewing the audit log.
#   - ServerTokens Prod / ServerSignature Off / TraceEnable Off: kills the
#     "Server: Apache/2.4.52 (Ubuntu)" + module-version disclosure on
# every response/error page. Previously, we leaked OS + Apache version
#     in plain text headers (seen on the curl output earlier).
#   - LimitRequestBody / Timeout: caps to prevent slow-loris and very-large-
#     POST denial-of-service. WordPress media uploads still work (10 MB cap).
ensure_apache_hardened() {
    if ! /usr/bin/command -v apache2 >/dev/null 2>&1; then
        return 0  # No Apache, nothing to harden
    fi

    log_info "Hardening Apache (mod_security2 + information-leak defaults)"

    # 1. Install mod_security2 + OWASP CRS (apt; idempotent)
    if ! /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' libapache2-mod-security2 2>/dev/null | grep -q '^ii'; then
        log_detail "Installing libapache2-mod-security2 + modsecurity-crs"
        /usr/bin/apt-get install -y -qq libapache2-mod-security2 modsecurity-crs >/dev/null 2>&1 \
            || log_warning "mod_security2 apt install had issues — continuing without WAF"
    else
        log_detail "mod_security2 already installed"
    fi

    # 2. Activate mod_security2's recommended config (Ubuntu ships
    # modsecurity.conf-recommended; rename to modsecurity.conf if needed).
    if [[ -f /etc/modsecurity/modsecurity.conf-recommended ]] && [[ ! -f /etc/modsecurity/modsecurity.conf ]]; then
        /usr/bin/cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
        # Start in DetectionOnly so existing traffic isn't broken; operator
        # reviews /var/log/apache2/modsec_audit.log then flips to On.
        /usr/bin/sed -i 's|^SecRuleEngine DetectionOnly|SecRuleEngine DetectionOnly|;
                         s|^SecRuleEngine On|SecRuleEngine DetectionOnly|' \
                         /etc/modsecurity/modsecurity.conf
        log_detail "Initialized modsecurity.conf (SecRuleEngine DetectionOnly — review then flip to On)"
    fi

    # 3. Information-leak hardening — drop into conf-available so it's
    # easy to disable for debugging.
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

    # 3b. WordPress admin CRS exclusions. The OWASP CRS WordPress package
    # (REQUEST-903.9002, enabled via crs-setup) does NOT cover the protocol
    # false-positives that block the Classic-Editor save POST to
    # /wp-admin/post.php: 921110 (HTTP smuggling) and 932130 (shell expr) fire
    # on legitimate post-body content, pushing the inbound anomaly score past
    # the threshold so 949110 returns 403 (SQLI/XSS/RCE all score 0). Scope the
    # removals to the auth-gated /wp-admin/ path so blocking stays on elsewhere.
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

    # 3c. mod_evasive thresholds for the HTTP/2 era. One multiplexed h2
    # pageload fires dozens of same-second requests, so the package-era
    # defaults (5 same-page / 50 same-site per second, 600s block) read a
    # wp-admin visit as a DoS and lock the operator out for 10 minutes.
    # conf-enabled loads after mods-enabled, so these override the module's
    # own conf without touching the package conffile. Inert without the
    # module; flood protection stays real (60s rolling blocks past 30/300 rps).
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

    # 4. Reload Apache to pick up the new config. Use reload (not restart)
    # so existing connections aren't dropped.
    if /usr/sbin/apachectl configtest >/dev/null 2>&1; then
        /usr/bin/systemctl reload apache2 >/dev/null 2>&1
        log_success "Apache hardened (mod_security2 in DetectionOnly + info-leak suppression)"
    else
        log_warning "Apache config test failed — NOT reloading. Review:"
        /usr/sbin/apachectl configtest 2>&1 | sed 's/^/    /'
        log_info "Disable the hardening: sudo a2disconf geodineum-harden"
    fi
}

# PHP-FPM + mpm_event. mod_php pins Apache to prefork: one process per
# connection, so a single hung backend call holds a whole worker hostage
# and HTTP/2 is off entirely. FPM makes a hung request cost one pool slot
# with a hard kill at request_terminate_timeout, and the pool opcache/APCu
# become shared across workers instead of per-process.
# Idempotent. Rollback: a2dismod mpm_event && a2enmod mpm_prefork &&
# systemctl restart apache2 (FPM keeps serving PHP under prefork too).
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

    # Dedicated pool. The stock www pool is retired at the end of the flip;
    # dpkg keeps deleted conffiles deleted, so it stays gone across upgrades.
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

    # Route .php to the pool. ProxySet timeout must outlive
    # request_terminate_timeout so FPM's kill fires first.
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

    # Event sizing + HTTP/2. conf-enabled loads after mods-enabled, so this
    # overrides stock mpm_event.conf without touching the package conffile.
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
    # Stock Debian handler confs target the www pool and would win the
    # handler merge (conf-enabled is alphabetical) — disable every version.
    local stock_conf
    for stock_conf in /etc/apache2/conf-enabled/php*-fpm.conf; do
        [[ -e "$stock_conf" ]] || continue
        /usr/sbin/a2disconf "$(basename "$stock_conf" .conf)" >/dev/null 2>&1 || true
    done

    # Both pools stay up through the Apache flip (zero-downtime ordering).
    if ! "/usr/sbin/php-fpm${phpv}" -t >/dev/null 2>&1; then
        log_warning "php-fpm config test FAILED — removing geodineum pool, keeping stock handler"
        rm -f "/etc/php/${phpv}/fpm/pool.d/geodineum.conf"
        /usr/sbin/a2disconf geodineum-php-fpm >/dev/null 2>&1 || true
        /usr/sbin/a2enconf "php${phpv}-fpm" >/dev/null 2>&1 || true
        return 0
    fi
    systemctl enable "php${phpv}-fpm" >/dev/null 2>&1 || true
    systemctl restart "php${phpv}-fpm" >/dev/null 2>&1 || true

    # mod_php is what pins prefork; event needs it gone before the MPM swap.
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
        # Retire the stock www pool only after Apache stopped referencing it.
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

    # Source geodeploy library — single authority for all permissions
    local geodeploy_lib="${INSTALL_ROOT}/Geodineum/lib/geodeploy.sh"
    if [[ -f "$geodeploy_lib" ]]; then
        GEODEPLOY_DEPLOY_USER="${DEPLOY_USER}"
        source "$geodeploy_lib"
        log_success "Loaded geodeploy permission library"
    else
        log_warning "geodeploy.sh not found at ${geodeploy_lib} — using inline fallback"
    fi

    # Set ownership per the narrow-group model.
    #   gNode/BAK                  → deploy_user:gnode            (daemon-side)
    #   Geodineum-COMMS/           → deploy_user:geodineum-comms  (isolation)
    #   Geodineum/                 → deploy_user:geodineum        (operator + CLI access via group)
    #   web/theme components       → deploy_user:geodineum-code   (shared source; www-data + geodine read via group)
    #
    # Fallback (when geodeploy_fix_perms isn't loaded) MUST distinguish
    # executable files from regular files — otherwise the blanket
    # chmod 640 strips the execute bit on:
    #   - target/release/<binary>     (the Rust binaries — gnode-daemon,
    #                                   geodineum-comms, ...)
    #   - *.sh / *.bash / *.py        (shell + python scripts)
    # A blanket 640 leaves binaries unreadable to systemd's service-user
    # exec (status=126). Each fallback below applies 0640 to regular
    # files THEN 0750 to executables.
    log_info "Setting permissions per narrow-group model"

    # Helper: blanket chmod 0640 then promote executables to 0750.
    # Defined inline so the fallback works even when lib/geodeploy.sh
    # isn't sourced (very-fresh install with no deploy harness yet).
    __sb77_chmod_files() {
        local root="$1"
        # Regular files
        find "$root" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" \) -prune -o \
                     -type f -print0 2>/dev/null | xargs -0 chmod 0640 2>/dev/null
        # Shell + Python scripts → executable
        find "$root" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" \) \
                     -exec chmod 0750 {} \; 2>/dev/null
        # Rust binaries (target/release top level — not the deps/ subdir)
        if [[ -d "$root/daemon/target/release" ]]; then
            find "$root/daemon/target/release" -maxdepth 1 -type f -executable \
                 -exec chmod 0750 {} \; 2>/dev/null
        fi
        if [[ -d "$root/target/release" ]]; then
            find "$root/target/release" -maxdepth 1 -type f -executable \
                 -exec chmod 0750 {} \; 2>/dev/null
        fi
        # Shebang detection — anything with a #! and no extension still
        # needs +x (e.g. installer-generated wrappers).
        find "$root" -type f -not -name "*.sh" -not -name "*.bash" -not -name "*.py" \
             -not -path "*/.git/*" -not -path "*/target/*" \
             -exec sh -c 'head -c 2 "$1" 2>/dev/null | grep -q "^#!" && chmod 0750 "$1"' _ {} \; 2>/dev/null
    }

    # Infrastructure repos: deploy_user:gnode
    for repo_dir in gNode Geodineum-BAK; do
        if [[ -d "${INSTALL_ROOT}/${repo_dir}" ]]; then
            if type geodeploy_fix_perms &>/dev/null; then
                geodeploy_fix_perms "${INSTALL_ROOT}/${repo_dir}" "${DEPLOY_USER}" "gnode"
                geodeploy_fix_binaries "${INSTALL_ROOT}/${repo_dir}" "$repo_dir"
            else
                chown -R "${DEPLOY_USER}:gnode" "${INSTALL_ROOT}/${repo_dir}"
                find "${INSTALL_ROOT}/${repo_dir}" -type d -exec chmod 2750 {} \;
                __sb77_chmod_files "${INSTALL_ROOT}/${repo_dir}"
            fi
        fi
    done

    # Geodineum-COMMS gets its own narrow group so the COMMS
    # daemon (geodineum-comms user) reads its tree without gnode-group
    # membership. Runtime-writable subdirs (.gnode/, logs/ — the unit's
    # ReadWritePaths) are owned BY the runtime user; everything else is
    # deploy-owned, group-readable.
    if [[ -d "${INSTALL_ROOT}/Geodineum-COMMS" ]]; then
        if type geodeploy_fix_perms &>/dev/null; then
            geodeploy_fix_perms "${INSTALL_ROOT}/Geodineum-COMMS" "${DEPLOY_USER}" "geodineum-comms"
            geodeploy_fix_binaries "${INSTALL_ROOT}/Geodineum-COMMS" "Geodineum-COMMS"
        else
            chown -R "${DEPLOY_USER}:geodineum-comms" "${INSTALL_ROOT}/Geodineum-COMMS"
            find "${INSTALL_ROOT}/Geodineum-COMMS" -type d -exec chmod 2750 {} \;
            __sb77_chmod_files "${INSTALL_ROOT}/Geodineum-COMMS"
        fi
        for rw_dir in .gnode logs; do
            mkdir -p "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
            chown -R geodineum-comms:geodineum-comms "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
            chmod 2750 "${INSTALL_ROOT}/Geodineum-COMMS/${rw_dir}" 2>/dev/null || true
        done
    fi

    # Geodineum repo itself: deploy_user:geodineum (operator + CLI access via group)
    if [[ -d "${INSTALL_ROOT}/Geodineum" ]]; then
        if type geodeploy_fix_perms &>/dev/null; then
            geodeploy_fix_perms "${INSTALL_ROOT}/Geodineum" "${DEPLOY_USER}" "geodineum"
        else
            chown -R "${DEPLOY_USER}:geodineum" "${INSTALL_ROOT}/Geodineum"
            find "${INSTALL_ROOT}/Geodineum" -type d -exec chmod 2750 {} \;
            __sb77_chmod_files "${INSTALL_ROOT}/Geodineum"
        fi
    fi

    # Shared SOURCE (gCore framework + themes that WP `require_once`s). Group =
    # geodineum-code, the single source-read class. NOT www-data: filing the
    # framework under the web server's primary group would force geodine into
    # www-data to use the library — exposing the whole web tier to a service
    # compromise. geodineum-code is a SUPPLEMENTARY group for www-data, so a
    # php-fpm/apache worker forked before www-data joined it cannot read these
    # files until re-exec (the "(13)Permission denied: pcfg_openfile" 500s).
    # The mitigation is the MANDATORY apache2 + php-fpm restart after group
    # setup (group membership is added above; this install flow restarts both).
    # Matches the manifests (group: geodineum-code) + geodeploy.sh — one model.
    # The set is DISCOVERED from each component's manifest group rather than
    # hardcoded, so comprehensive installs cover their additional web/theme
    # components without this shared source having to enumerate them.
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
                __sb77_chmod_files "${INSTALL_ROOT}/${wp_dir}"
            fi
        fi
    done

    unset -f __sb77_chmod_files
    log_success "Component permissions set per narrow-group model"

    # Centralized log directory: /var/log/geodineum/
    log_info "Setting up centralized logs at /var/log/geodineum/..."
    track_path_if_new /var/log/geodineum
    # `deploy` holds the orchestrator's auto-deploy.log (was wrongly under
    # /opt/geodineum/logs); geodeploy_fix_log_perms owns it <deploy_user>:geodineum.
    for log_dir in gnode comms gcore gcore/sites apache wordpress themes valkey bak deploy; do
        track_path_if_new "/var/log/geodineum/${log_dir}"
        mkdir -p "/var/log/geodineum/${log_dir}"
    done
    if type geodeploy_fix_log_perms &>/dev/null; then
        geodeploy_fix_log_perms "/var/log/geodineum"
    fi
    log_success "Log directories created with correct ownership"

    # Fix credential ownership
    if type geodeploy_fix_all_credentials &>/dev/null; then
        geodeploy_fix_all_credentials "/etc/geodineum/credentials"
        log_success "Credential ownership set (<runtime_user>:<runtime_user> 600)"
    fi

    # Make sure the daemon credential symlink exists at the gNode-side
    # path BEFORE install-gnode-service.sh runs. provision_daemon_acl
    # called the same helper in Phase 4 best-effort, but at that point
    # /opt/geodineum/gNode/ doesn't exist yet (Phase 5 clones it). Now
    # the gNode tree is on disk; the symlink can be created.
    ensure_daemon_credential_symlink

    # Install systemd service via gNode's script. Track rc and
    # return it at end so run_phase records [FAIL] Services. Previously,
    # this set PHASE_RESULTS["Services"]="FAIL" mid-function but
    # run_phase overwrote it back to OK based on the function's
    # implicit return-0.
    local service_script="${GNODE_SCRIPTS}/install-gnode-service.sh"
    if [[ -x "$service_script" ]]; then
        log_info "Installing gNode systemd service..."
        # Pass the node id through so install-gnode-service.sh writes it into
        # daemon.env (the unit's --node-id reads GNODE_NODE_ID). Empty on a
        # master/standalone install → the unit defaults to "master".
        # A flag-driven join (--master-ip / VALKEY_HOST, wizard skipped) must
        # NOT fall through to "master": two daemons sharing that consumer name
        # contend over the same pending stream entries instead of load-balancing.
        if [[ -z "$GNODE_NODE_ID" ]]; then
            case "${VALKEY_HOST:-127.0.0.1}" in
                127.0.0.1|localhost|::1) : ;;
                *) GNODE_NODE_ID="$(hostname -s 2>/dev/null || echo worker)"
                   log_info "Node ID defaulted to ${GNODE_NODE_ID} (remote ValKey → constellation worker)" ;;
            esac
        fi
        export GNODE_NODE_ID
        if ! "$service_script"; then
            log_warning "Service installation had issues — see output above"
            rc=1
        fi
    else
        log_warning "install-gnode-service.sh not found — systemd service not installed"
        log_info "Start daemon manually: ${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon"
        rc=1
    fi

    # Install COMMS systemd service if COMMS was installed
    if [[ -x "${INSTALL_ROOT}/Geodineum-COMMS/target/release/geodineum-comms" ]]; then
        local comms_service="/etc/systemd/system/geodineum-comms.service"

        # Runtime state + per-component env dirs owned by the
        # dedicated COMMS user. /var/lib/geodineum-comms holds the
        # per-site SQLite persistence (unit ReadWritePaths); the
        # components dir holds operator-created secrets (env file read
        # at start via EnvironmentFile, never written by the daemon —
        # root-owned, group-read).
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

    # Apache hardening (mod_security2 + info-leak suppression).
    # Idempotent; safe to re-run. Only fires if Apache is installed.
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

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Load Lua functions into ValKey (22 base + 1 CMS library)"
        return
    fi

    if [[ "$SKIP_LOCAL_VALKEY" == "true" ]]; then
        # Constellation worker: the function libraries live in the MASTER's
        # ValKey (loaded there at its install; the daemon re-verifies at
        # startup). Nothing to load locally — this is the expected state,
        # not a failure.
        log_info "Remote ValKey (constellation worker) — function libraries are managed on the master"
        return
    fi

    if [[ "$VALKEY_RUNNING" != "true" ]]; then
        log_warning "ValKey not running — cannot load Lua functions now"
        log_info "Load later: ${GNODE_SCRIPTS}/load-valkey-functions.sh"
        # ValKey-not-running is itself a soft-fail at this point —
        # surface it via rc so the phase tracker reflects it.
        return 1
    fi

    # Track rc + return at end. Setting PHASE_RESULTS
    # mid-function gets overwritten by run_phase based on the implicit
    # return-0; only the function's actual exit status counts.
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

    # Register ecosystem tools in the tool topology (dependency pyramid).
    # Surface stderr AND get the flag
    # positions right.
    #
    # gnode-daemon's clap layout puts ValKey-connection flags
    # (--redis-user, --redis-port, --redis-auth-file, --redis-auth) on
    # the top-level Cli struct, NOT on the RegisterTools subcommand.
    # Top-level flags must precede the subcommand:
    #
    #   gnode-daemon --redis-user X --redis-auth-file Y register-tools --tier tool
    #
    # Previously, we passed them after `register-tools`, which clap
    # rejected with "Found argument '--redis-user' which wasn't expected,
    # or isn't valid in this context". The env-var equivalents
    # (GNODE_REDIS_AUTH_FILE, VALKEY_USER, VALKEY_PORT) are already
    # honoured by the same flags' clap declarations, so passing via
    # env keeps the call site cleaner and avoids any ordering
    # subtlety.
    local daemon_bin="${INSTALL_ROOT}/gNode/daemon/target/release/gnode-daemon"
    if [[ -x "$daemon_bin" ]]; then
        log_info "Registering ecosystem tools in tool topology..."
        local daemon_pass_file="/etc/geodineum/credentials/valkey_daemon.password"
        if [[ -f "$daemon_pass_file" ]]; then
            if GNODE_REDIS_AUTH_FILE="$daemon_pass_file" \
               VALKEY_USER="gnode_daemon" \
               VALKEY_PORT="${VALKEY_PORT:-47445}" \
               "$daemon_bin" register-tools --tier tool; then
                log_success "Ecosystem tool topology populated (dependency pyramid)"
            else
                log_warning "Tool registration had issues (see stderr above) — register later: VALKEY_USER=gnode_daemon GNODE_REDIS_AUTH_FILE=${daemon_pass_file} gnode-daemon register-tools --tier tool"
                # Non-fatal for Ch.1 launch — the daemon can
                # self-register on first start.
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

    # Check each installed component
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

    # Check daemon binary. If absent, also downgrade PHASE_RESULTS["Build"]
    # to FAIL so the post-install summary reflects ground truth: a
    # missing binary means the build phase did not produce a working
    # artefact, even if cargo's stderr got swallowed somewhere upstream.
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

    # Check config
    if [[ -f "/etc/geodineum/bootstrap.env" ]]; then
        log_success "/etc/geodineum/bootstrap.env exists"
        ((pass++))
    else
        log_warning "/etc/geodineum/bootstrap.env missing"
        ((fail++))
    fi

    # Check ValKey connection. Re-PING live rather than trusting the
    # cached VALKEY_RUNNING flag — Phase 4 sets the flag based on a
    # post-restart auth verify, but state can drift between phases
    # (e.g., daemon crashed mid-Phase-6 build, OOM killer, manual
    # systemctl stop). Phase 10's job is to assert the runtime
    # invariant, not echo back what we believed in Phase 4.
    if needs_daemon "${resolved[@]}"; then
        # Credential fallback: workers have no admin password by design —
        # verify with the daemon ACL credential instead. Also target
        # VALKEY_HOST (remote on workers), not the implicit localhost:
        # both gaps made this check a guaranteed false FAIL on every join.
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

    # Check daemon service
    if needs_daemon "${resolved[@]}" && [[ "$HAS_SYSTEMD" == "true" ]]; then
        if systemctl is-enabled --quiet gnode-daemon 2>/dev/null; then
            log_success "gnode-daemon service enabled"
            ((pass++))
        else
            log_warning "gnode-daemon service not enabled"
        fi
    fi

    # Run validation script if available. surface output (decision
    # W). Pre-fix the call was `--quiet 2>/dev/null` which gave the
    # operator a content-free `[WARN] Configuration validation found
    # issues` line with no path forward — same shape as the other phases.
    # Now run without --quiet so the validator prints its findings
    # inline; the trailing exit code still drives pass/fail.
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

# Tier-4 4.2: Cog-load status table. Best-effort query of ValKey for
# the per-extension config_schema entries the daemon publishes at
# startup (Tier-2 2.9 wired the daemon-side discovery). When ValKey
# isn't reachable yet (e.g. daemon not started, or running under a
# different ACL than the one the wizard can read), the table degrades
# gracefully: shows scanned filesystem state with status "pending".
print_cog_load_status() {
    local cms_path="${GNODE_EXT_CMS_PATH:-/opt/geodineum/pro/gNode/gNode-CMS}"
    local schemas=""

    # use valkey-cli (the canonical CLI for the source-build
    # ValKey we ship). redis-cli works because Phase 4 installs a
    # symlink at /usr/local/bin/redis-cli → valkey-cli for compat with
    # legacy scripts + muscle memory, but the canonical tool name is
    # valkey-cli — the install summary shouldn't reinforce the wrong
    # name. Prefer valkey-cli; fall back to redis-cli for hosts that
    # don't have the compat symlink yet.
    local _cli=""
    if command -v valkey-cli >/dev/null 2>&1; then
        _cli="valkey-cli"
    elif command -v redis-cli >/dev/null 2>&1; then
        _cli="redis-cli"
    fi
    if [[ -n "$_cli" ]]; then
        # No-auth-warning: best-effort read; if ACL rejects, fall back
        # to filesystem detection. SCAN-via-SMEMBERS preferred over
        # KEYS per Tier-2 2.2 invariant (COMMS_KEYS_FORBIDDEN).
        schemas=$("$_cli" --no-auth-warning SMEMBERS geodineum:config_schema:_index 2>/dev/null || echo "")
    fi

    echo ""
    echo -e "  ${BOLD}Cog-load status (extension discovery):${NC}"
    echo -e "    ${DIM}┌─────────────┬──────────┬──────────────────────────────────┐${NC}"
    echo -e "    ${DIM}│${NC} ${BOLD}Extension${NC}   ${DIM}│${NC} ${BOLD}Status${NC}   ${DIM}│${NC} ${BOLD}Notes${NC}                            ${DIM}│${NC}"
    echo -e "    ${DIM}├─────────────┼──────────┼──────────────────────────────────┤${NC}"

    # gNode-CMS — Ch.1 only ships this extension by default
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
        if [[ "$GNODE_RUNNING" == "true" ]] || systemctl is-active --quiet gnode-daemon 2>/dev/null; then
            echo "    - Daemon is running. Check: sudo systemctl status gnode-daemon"
        else
            echo "    - Start daemon: sudo systemctl start gnode-daemon"
        fi
        echo "    - Register a site: geodineum new site example.com --theme gcube"
        echo "    - Or scaffold a service: geodineum new service my_api (--gcore for full framework)"
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

        # Show viewkey if available
        local config_file="/var/www/${SITE_DOMAIN}/wp-config-geodineum.yaml"
        if [[ -r "$config_file" ]] && command -v grep &>/dev/null; then
            local viewkey
            viewkey=$(grep -oP 'viewkey:\s*["\x27]?\K[^"\x27\s]+' "$config_file" 2>/dev/null || echo "")
            if [[ -n "$viewkey" ]]; then
                echo "    Viewkey:     ${viewkey}"
                echo "    Gate URL:    https://${SITE_DOMAIN}/?viewkey=${viewkey}"
            fi
        fi

        # Show WP admin credentials if available
        local wp_root="/var/www/${SITE_DOMAIN}"
        if [[ -r "${wp_root}/wp-config.php" ]] && command -v wp &>/dev/null; then
            local admin_user
            admin_user=$(sudo -u www-data wp user list --role=administrator --field=user_login --path="$wp_root" 2>/dev/null | head -1)
            if [[ -n "$admin_user" ]]; then
                echo "    WP Admin:    ${admin_user}"
                echo "    WP Login:    https://${SITE_DOMAIN}/wp-admin/"
            fi
        fi

        # Show ValKey credentials
        local pw_file="/etc/geodineum/credentials/valkey_client_${site_id}.password"
        if [[ -r "$pw_file" ]]; then
            echo "    ValKey user:  gnode_client_${site_id}"
            echo "    ValKey port:  ${VALKEY_PORT:-47445}"
        fi

        echo ""
        echo "  ${BOLD}Quick commands:${NC}"
        echo "    geodineum info ${site_id}            # Full site details"
        echo "    geodineum env viewkey ${site_id}     # Show/generate viewkey"
        echo "    geodineum env show ${site_id}        # Environment + gate status"
    fi

    echo ""
    echo "    - Health check: geodineum status --verbose"
    if [[ -x /usr/local/bin/geodineum ]]; then
        echo "    - CLI ready: geodineum --help (or: gcli --help)"
    else
        echo "    - CLI install: sudo ln -sf ${INSTALL_ROOT}/Geodineum/geodineum /usr/local/bin/geodineum"
    fi
    echo "    - Documentation: https://github.com/geodineum"

    # Phase results
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

    # Tier-4 4.2: Cog-load status
    print_cog_load_status

    # Log file location
    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE:-}" ]]; then
        echo ""
        echo -e "  ${DIM}Full log: ${LOG_FILE}${NC}"
    fi
    echo ""
}

# =============================================================================
# Credential reconciliation (reinstall: re-provision missing per-site creds)
# =============================================================================

reconcile_site_credentials() {
    local cred_dir="${CREDENTIALS_DIR:-/etc/geodineum/credentials}"
    local register_script="${INSTALL_ROOT}/gNode/scripts/register-site.sh"
    local web_root="${WEB_ROOT:-/var/www}"

    [[ -x "$register_script" ]] || return 0

    # Enforce 0751 on the credentials dir. reconcile runs late,
    # so this is a belt-and-suspenders fix for a --keep-data-preserved dir that
    # predates the unconditional install -d — 0750 there blocks www-data
    # traversal and silently forces every site into free-tier.
    [[ -d "$cred_dir" ]] && chmod 0751 "$cred_dir" 2>/dev/null || true

    local reconciled=0
    for wp_config in "${web_root}"/*/wp-config.php; do
        [[ -f "$wp_config" ]] || continue

        local site_dir domain site_id
        site_dir="$(dirname "$wp_config")"
        domain="$(basename "$site_dir")"
        site_id="$(echo "$domain" | sed 's/\./_/g')"

        # Only touch Geodineum-managed sites — identified by the deployer's
        # site YAML, a .geodineum/ marker, or an existing per-site credential.
        # Skips unrelated WordPress installs that happen to live under /var/www.
        if [[ ! -f "${site_dir}/wp-config-geodineum.yaml" ]] \
           && [[ ! -d "${site_dir}/.geodineum" ]] \
           && [[ ! -f "${cred_dir}/valkey_client_${site_id}.password" ]]; then
            continue
        fi

        # register-site.sh is idempotent: it reuses an existing password file,
        # (re)provisions the ACL user with full keyspace/channel/command grants,
        # and recreates streams. This repairs BOTH missing credentials AND the
        # half-provisioned users (wrong password / no perms) a --keep-data
        # reinstall leaves behind — the actual root of post-reinstall free-tier.
        log_info "Reconciling site credentials: ${site_id}"
        if GNODE_PASSWORD_DIR="$cred_dir" "$register_script" "$site_id" >/dev/null 2>&1; then
            reconciled=$((reconciled + 1))
        else
            log_warning "  register-site.sh issues for ${site_id} — retry: sudo ${register_script} ${site_id}"
        fi
    done

    if [[ $reconciled -gt 0 ]]; then
        log_success "Reconciled credentials for ${reconciled} existing site(s)"
    fi
    return 0
}

# =============================================================================
# Site deployment (called from both --site CLI path and post-install prompt)
# =============================================================================

# extracted from main() body so the post-install "Deploy a WordPress
# site now?" prompt can also drive deployment. Previously the prompt set
# SITE_DOMAIN but never actually invoked the site installer — the user
# saw "Installation Complete" with "Site deployed: https://<domain>" in
# the next-steps summary, but no vhost, no DB, no /var/www/<domain>/, no
# certbot run had happened. Silent inaction with a success indication.
#
# Reads SITE_DOMAIN, SITE_THEME, SITE_ENV, INSTALL_ROOT, DRY_RUN from
# the outer scope. No-op if SITE_DOMAIN is empty or DRY_RUN is true.
deploy_site_if_requested() {
    [[ -n "$SITE_DOMAIN" ]] || return 0
    [[ "$DRY_RUN" != "true" ]] || return 0

    log_step "Site Deployment"
    local install_script="${INSTALL_ROOT}/gTemplate/scripts/install-geodineum.sh"
    if [[ ! -x "$install_script" ]]; then
        log_warning "Site installer not found at ${install_script} — deploy manually:"
        log_info "  geodineum new site ${SITE_DOMAIN} --theme ${SITE_THEME:-gtemplate-wp} --env ${SITE_ENV}"
        return 1
    fi

    local theme_args=()
    if [[ -n "$SITE_THEME" ]]; then
        local theme_path="${INSTALL_ROOT}/$(get_install_dir "$SITE_THEME")"
        theme_args=(--theme "$SITE_THEME" --theme-path "$theme_path")
    fi

    if "$install_script" "$SITE_DOMAIN" "${theme_args[@]}" "$SITE_ENV"; then
        log_success "Site deployed: ${SITE_DOMAIN}"
        return 0
    else
        local rc=$?
        log_error "Site deployment failed for ${SITE_DOMAIN} (exit ${rc})"
        log_info "Re-run manually: ${install_script} ${SITE_DOMAIN} ${theme_args[*]} ${SITE_ENV}"
        return $rc
    fi
}

# Post-install prompt handler: WordPress site (reads domain, drives the
# WP site installer via deploy_site_if_requested).
prompt_deploy_wordpress() {
    local new_domain
    read -p "  Domain name: " new_domain
    [[ -n "$new_domain" ]] || return 0
    SITE_DOMAIN="$new_domain"
    SITE_THEME="${SITE_THEME:-gcube}"
    deploy_site_if_requested || \
        log_warning "Post-install site deploy failed — see errors above"
}

# Post-install prompt handler: standalone gCore app (no WordPress) —
# scaffold via the geodineum CLI (app dir + gCore bootstrap + ValKey
# identity + gNode onboarding).
prompt_scaffold_gcore_app() {
    local app_id
    read -p "  App ID (lowercase, [a-z0-9_]): " app_id
    [[ -n "$app_id" ]] || return 0
    if [[ ! "$app_id" =~ ^[a-z][a-z0-9_]*$ ]]; then
        log_error "Invalid app ID '${app_id}' — must start with a lowercase letter, only [a-z0-9_]"
        return 1
    fi

    local cli="${INSTALL_ROOT}/Geodineum/geodineum"
    if [[ ! -x "$cli" ]]; then
        cli="$(command -v geodineum 2>/dev/null || true)"
    fi
    if [[ -z "$cli" ]]; then
        log_warning "geodineum CLI not found — scaffold manually:"
        log_info "  sudo geodineum new service ${app_id} --gcore --env ${SITE_ENV:-testing}"
        return 1
    fi

    if "$cli" new service "$app_id" --gcore --env "${SITE_ENV:-testing}"; then
        log_success "Standalone gCore app scaffolded: ${app_id}"
    else
        log_warning "App scaffold failed — retry: sudo geodineum new service ${app_id} --gcore --env ${SITE_ENV:-testing}"
        return 1
    fi
}

# =============================================================================
# Post-install service-setup decision tree (New/Existing-first).
# Geodineum is the ECOSYSTEM you onboard onto — web AND non-web; gNode is its
# per-node orchestrator. A "site" is just a service with a web profile.
# Unbuilt branches are shown greyed with "coming soon" rather than offered then
# failing. The resolved geodineum CLI carries each verb (new site|service|
# pipeline | register).
# =============================================================================

# Render a non-selectable, greyed "coming soon" menu line.
_soon() { echo -e "    ${DIM}${1}  — coming soon${NC}"; }

# Resolve the geodineum CLI path into _CLI (empty if not found).
_resolve_cli() {
    _CLI="${INSTALL_ROOT}/Geodineum/geodineum"
    [[ -x "$_CLI" ]] || _CLI="$(command -v geodineum 2>/dev/null || true)"
}

# Read + validate a lowercase service id into SVC_ID. Returns 1 if empty/invalid.
_read_service_id() {
    SVC_ID=""
    read -p "  Service id (lowercase, [a-z0-9_]): " SVC_ID
    [[ -n "$SVC_ID" ]] || return 1
    if [[ ! "$SVC_ID" =~ ^[a-z][a-z0-9_]*$ ]]; then
        log_error "Invalid id '${SVC_ID}' — start with a lowercase letter, only [a-z0-9_]"
        return 1
    fi
}

# Scaffold a NEW service via the CLI. $1 = extra flags (word-split intentionally).
_new_service() {
    local extra="$1" env="${SITE_ENV:-testing}"
    _read_service_id || { log_info "No id given — skipping"; return 0; }
    if [[ -z "$_CLI" ]]; then
        log_warning "geodineum CLI not found — run: sudo geodineum new service ${SVC_ID} ${extra} --env ${env}"
        return 0
    fi
    if "$_CLI" new service "$SVC_ID" $extra --env "$env"; then
        log_success "Service scaffolded: ${SVC_ID}"
    else
        log_warning "Scaffold failed — retry: sudo geodineum new service ${SVC_ID} ${extra} --env ${env}"
    fi
}

_new_pipeline() {
    _read_service_id || { log_info "No id given — skipping"; return 0; }
    local src; read -p "  Source URL (pipeline input): " src
    if [[ -z "$src" ]]; then
        log_info "Pipelines need a --source — run later: sudo geodineum new pipeline ${SVC_ID} --source <url>"
        return 0
    fi
    if [[ -z "$_CLI" ]]; then
        log_warning "geodineum CLI not found — run: sudo geodineum new pipeline ${SVC_ID} --source ${src}"
        return 0
    fi
    if "$_CLI" new pipeline "$SVC_ID" --source "$src"; then
        log_success "Pipeline scaffolded: ${SVC_ID}"
    else
        log_warning "Pipeline scaffold failed — retry: sudo geodineum new pipeline ${SVC_ID} --source ${src}"
    fi
}

# 1) Onboard an EXISTING project — register code you already have.
_setup_existing() {
    echo ""
    echo -e "  ${BOLD}Onboard an existing project${NC} — registers ACL + streams + .geodineum/."
    echo -e "  ${DIM}Web-endpoint attach for an existing non-WordPress project: coming soon.${NC}"
    echo ""
    _read_service_id || { log_info "No id given — skipping"; return 0; }
    if [[ -z "$_CLI" ]]; then
        log_warning "geodineum CLI not found — run: sudo geodineum register ${SVC_ID}"
        return 0
    fi
    if "$_CLI" register "$SVC_ID"; then
        log_success "Existing project onboarded: ${SVC_ID}"
    else
        log_warning "Onboard failed — retry: sudo geodineum register ${SVC_ID}"
    fi
}

# 2a) New WEB service.
_setup_new_web() {
    local can_wp="$1" can_app="$2"
    echo ""
    echo -e "  ${BOLD}New web service${NC}"
    if [[ "$can_wp" == "true" ]]; then
        echo -e "    ${BOLD}1) WordPress site${NC}                  theme + gCore mu-plugin + Apache vhost/SSL"
    else
        _soon "1) WordPress site                  (WordPress support not installed)"
    fi
    if [[ "$can_app" == "true" ]]; then
        echo -e "    ${BOLD}2) Web app (gCore framework)${NC}       PHP app + HTTP endpoint"
    else
        _soon "2) Web app (gCore framework)       (gCore not installed)"
    fi
    echo -e "    ${BOLD}3) Web API (bring-your-own server)${NC} register + you serve it (http-api profile)"
    echo ""
    local w; read -p "  Select [1-3, default: 3]: " -n 1 w; echo ""
    case "${w:-3}" in
        1) [[ "$can_wp" == "true" ]] && prompt_deploy_wordpress || log_info "WordPress not available — skipping" ;;
        2) [[ "$can_app" == "true" ]] && _new_service "--gcore --template http-api" || log_info "gCore not available — skipping" ;;
        *) _new_service "--template http-api" ;;
    esac
}

# 2b) New NON-WEB service.
_setup_new_nonweb() {
    echo ""
    echo -e "  ${BOLD}New non-web service${NC} ${DIM}(language: php — python / node / rust coming soon)${NC}"
    echo -e "    ${BOLD}1) Worker / background processor${NC}"
    echo -e "    ${BOLD}2) Inference / AI service${NC}"
    echo -e "    ${BOLD}3) Data pipeline${NC}                  (needs a source URL)"
    _soon "   Daemon / system service"
    echo ""
    local n; read -p "  Select [1-3, default: 1]: " -n 1 n; echo ""
    case "${n:-1}" in
        2) _new_service "--template inference" ;;
        3) _new_pipeline ;;
        *) _new_service "--template worker" ;;
    esac
}

# 2) Create a NEW service — web vs non-web.
_setup_new() {
    local can_wp="$1" can_app="$2"
    echo ""
    echo -e "  ${BOLD}New service — web-facing?${NC}"
    echo -e "    ${BOLD}1) Web${NC}        serves HTTP — sites, apps, APIs"
    echo -e "    ${BOLD}2) Non-web${NC}    headless — workers, daemons, pipelines, inference"
    echo ""
    local face; read -p "  Select [1-2, default: 1]: " -n 1 face; echo ""
    case "${face:-1}" in
        2) _setup_new_nonweb ;;
        *) _setup_new_web "$can_wp" "$can_app" ;;
    esac
}

# Top of the tree: New vs Existing vs Skip.
prompt_setup_service() {
    local can_wp="$1" can_app="$2"
    _resolve_cli
    echo ""
    echo -e "  ${BOLD}Set up a service on Geodineum?${NC}"
    echo -e "  ${DIM}Geodineum is the ecosystem you onboard onto — web or non-web. gNode is its per-node orchestrator.${NC}"
    echo ""
    echo -e "    ${BOLD}1) Onboard an existing project${NC}  register code you already have"
    echo -e "    ${BOLD}2) Create a new service${NC}         scaffold a fresh project on Geodineum"
    echo -e "    ${BOLD}3) Skip${NC}                         later:  geodineum new … | geodineum register …"
    echo ""
    local top; read -p "  Select [1-3, default: 3]: " -n 1 top; echo ""
    case "${top:-3}" in
        1) _setup_existing ;;
        2) _setup_new "$can_wp" "$can_app" ;;
        *) ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    banner

    # Validate install root (from --install-root flag or env — wizard validates its own input)
    if ! validate_install_root "$INSTALL_ROOT"; then
        log_error "Invalid install root: ${INSTALL_ROOT}"
        exit 1
    fi

    # ── Installation logging ──────────────────────────────────
    # All output tee'd to log file. No sensitive data (passwords, tokens)
    # reaches stdout — individual phases handle credential isolation.

    local LOG_DIR="/var/log/geodineum"
    local LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    if [[ "$DRY_RUN" != "true" ]] && [[ -d "$LOG_DIR" ]]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
        log_info "Logging to: ${LOG_FILE}"
    fi

    # Phase result tracking
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

    # Phase 0: Deploy user
    run_phase "Deploy User" phase_deploy_user true

    # Phase 1: Detection
    run_phase "Detection" phase_detection true

    # Non-interactive constellation join: --deploy-tier maps to profile + flags
    # (and sets PROFILE, so the interactive wizard below is skipped).
    apply_deploy_tier

    # Phase 2: Selection (interactive if no --profile/--components)
    if [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]] && [[ -z "$SITE_DOMAIN" ]]; then
        phase_selection
    fi

    # --site without --profile implies standard profile
    if [[ -n "$SITE_DOMAIN" ]] && [[ -z "$PROFILE" ]] && [[ -z "$COMPONENTS" ]]; then
        PROFILE="standard"
        log_info "Site deployment requested — using standard profile"
    fi

    # Resolve component list
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

    # COMMS opt-out (flag or wizard): strip it from the resolved set. The
    # COMMS service-install, ACL provisioning, and ownership passes are all
    # already guarded on the binary's presence, so absence is clean.
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

    # Show installation plan
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

    # ValKey needed?
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
        echo -e "  ${BOLD}Site deployment:${NC} ${SITE_DOMAIN} (theme: ${SITE_THEME:-gtemplate-wp}, env: ${SITE_ENV})"
        echo ""
    fi

    # Confirm
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run mode — showing what would happen"
        echo ""
    elif ! confirm "Proceed with installation?"; then
        log_info "Cancelled"
        exit 0
    fi

    # ── Rollback on fatal failure ────────────────────────────
    # Tracks what this install run created. On fatal error, removes
    # geodineum artifacts (repos, config, systemd) but keeps prereqs
    # (apt packages, Rust, PHP) so a retry starts clean.
    #
    # Rollback no longer `rm -rf`s
    # /etc/geodineum. Instead, every phase records paths it NEWLY creates
    # into INSTALLED_PATHS via track_path_if_new(); rollback reverse-
    # iterates the array and removes only those paths. Pre-existing
    # state on multi-site hosts (e.g., /etc/geodineum/credentials/
    # site_a_creds from a prior install) is preserved.
    INSTALLED_REPOS=()
    INSTALLED_SERVICES=()
    INSTALLED_PATHS=()

    # Record a path for rollback only if it did not exist before this
    # install created it. Callers invoke BEFORE their mkdir/install, so
    # the pre-existence check is accurate. Safe to call on DRY_RUN
    # (path-creation is skipped; tracking is a no-op side-effect).
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

        # 1. Stop + disable + remove tracked services first so they
        #    release any file handles on paths we're about to delete.
        for svc in "${INSTALLED_SERVICES[@]}"; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                log_info "Disabling: ${svc}"
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
            fi
            rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}.timer" 2>/dev/null
        done
        [[ ${#INSTALLED_SERVICES[@]} -gt 0 ]] && systemctl daemon-reload 2>/dev/null || true

        # 2. Unregister auto-deploy cron if we installed it. The cron
        #    line pattern is stable (auto-deploy.sh) — idempotent grep/
        #    filter preserves any pre-existing unrelated entries.
        if crontab -l 2>/dev/null | grep -q "auto-deploy.sh"; then
            log_info "Removing auto-deploy cron entry"
            crontab -l 2>/dev/null | grep -v "auto-deploy.sh" | crontab - 2>/dev/null || true
        fi

        # 3. Remove cloned repos (only the ones we cloned this run)
        for repo_dir in "${INSTALLED_REPOS[@]}"; do
            if [[ -d "$repo_dir" ]]; then
                log_info "Removing: ${repo_dir}"
                rm -rf "$repo_dir"
            fi
        done

        # 4. Remove tracked paths in REVERSE order so files / deeper
        #    dirs come before their parents. Paths created by a prior
        #    install (pre-existing when THIS install started) are not
        #    in the array and survive — preserving site_a_creds while
        #    rolling back a failed site_b install.
        local _idx _p
        for (( _idx=${#INSTALLED_PATHS[@]}-1 ; _idx>=0 ; _idx-- )); do
            _p="${INSTALLED_PATHS[$_idx]}"
            if [[ -e "$_p" ]]; then
                log_info "Removing: ${_p}"
                rm -rf "$_p"
            fi
        done

        # 5. CLI symlinks are ours to remove unconditionally.
        rm -f /usr/local/bin/geodineum /usr/local/bin/gcli 2>/dev/null

        echo ""
        log_info "Rollback complete. Re-run: sudo ./install.sh"
        if [[ -n "${LOG_FILE:-}" ]] && [[ -f "${LOG_FILE:-}" ]]; then
            log_info "Log: ${LOG_FILE}"
        fi
    }

    # INT/TERM trap: Ctrl-C or `systemctl stop install.sh`-
    # style interruption mid-install triggers the same scoped rollback
    # as a phase failure. Cleared at the end of a successful install.
    rollback_on_interrupt() {
        echo ""
        log_error "Installation interrupted (signal received) — rolling back"
        rollback
        exit 130
    }
    trap rollback_on_interrupt INT TERM

    # Track component fetches for rollback
    _original_fetch_component=$(declare -f fetch_component)
    fetch_component() {
        local name="$1"
        local install_dir="${INSTALL_ROOT}/$(get_install_dir "$name")"
        local was_new=false
        [[ ! -d "$install_dir" ]] && was_new=true

        # Call original function (defined above)
        eval "${_original_fetch_component#*\{}" 2>/dev/null
        local result=$?

        # Track new clones for rollback
        if [[ "$was_new" == "true" ]] && [[ -d "$install_dir" ]]; then
            INSTALLED_REPOS+=("$install_dir")
        fi
        return $result
    }

    # Phases 3-9 (rollback on fatal failure)
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

    # Seed gCore manager defaults into ValKey (idempotent NX mode).
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

    # Deploy site if requested (via --site CLI arg). Post-install prompt
    # path calls deploy_site_if_requested directly after setting SITE_DOMAIN.
    deploy_site_if_requested

    # Harden WordPress site permissions (defensive ownership model)
    if [[ "$DRY_RUN" != "true" ]] && type geodeploy_harden_all_wp &>/dev/null; then
        log_info "Hardening WordPress site permissions..."
        # Guarded: WP hardening is best-effort and must never abort the
        # install. The `|| log_warning` also disables `set -e` for the
        # whole harden subtree, so an interior chmod/find hiccup on a
        # foreign /var/www site can't take the installer down before
        # Phase 10 (the worker-host test failure mode).
        if geodeploy_harden_all_wp "/var/www"; then
            log_success "WordPress sites hardened (source read-only, uploads PHP-blocked)"
        else
            log_warning "WordPress hardening had non-fatal issues — continuing"
        fi
    fi

    # Install CLI symlinks
    if [[ -f "${INSTALL_ROOT}/Geodineum/geodineum" ]] && [[ "$DRY_RUN" != "true" ]]; then
        ln -sf "${INSTALL_ROOT}/Geodineum/geodineum" /usr/local/bin/geodineum 2>/dev/null && \
            log_success "CLI installed: /usr/local/bin/geodineum"
        ln -sf "${INSTALL_ROOT}/Geodineum/geodineum" /usr/local/bin/gcli 2>/dev/null && \
            log_success "CLI alias: /usr/local/bin/gcli"
    fi

    # Deploy web-deny hardening rules
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

    # Set up geodeploy orchestrator cron
    if [[ "$DRY_RUN" != "true" ]]; then
        local orchestrator="${INSTALL_ROOT}/Geodineum/scripts/geodeploy-orchestrator"
        if [[ -f "$orchestrator" ]]; then
            local cron_line="*/5 * * * * ${orchestrator}"
            if ! sudo -u "$DEPLOY_USER" crontab -l 2>/dev/null | grep -q "geodeploy-orchestrator"; then
                # Remove old auto-deploy.sh cron if present
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

        # Install scoped sudoers for deploy operations
        local sudoers_tpl="${INSTALL_ROOT}/Geodineum/templates/sudoers-geodeploy.tpl"
        if [[ -f "$sudoers_tpl" ]]; then
            # Render the sudoers template by substituting {{DEPLOY_USER}}
            # everywhere — both the leading rule-user position AND inside
            # `chown` argument lists like `{{DEPLOY_USER}}\:gnode`. The
            # pre-fix sed used `s/^august /${DEPLOY_USER} /g` which only
            # touched the leading user; chown arg-user references like
            # `chown -R august\:gnode` survived unchanged, leaving the
            # deploy user only able to sudo-chown things to literal
            # `august` (the upstream maintainer's account name) on every
            # downstream install. The new placeholder is unambiguous and
            # global-replaces correctly. (Aligned with Geodineum-pro's
            # convention.)
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

    # Credential reconciliation: re-provision per-site ACL users for any
    # existing Geodineum WordPress site. NOT gated on CONFIG_EXISTS — that's
    # false after a --keep-data uninstall (bootstrap.env deleted), which is
    # exactly the reinstall case that needs reconciliation. The function
    # self-guards (skips non-Geodineum sites; no-ops on fresh installs).
    if [[ "$DRY_RUN" != "true" ]]; then
        reconcile_site_credentials
    fi

    # Phase 10: Verify
    run_phase "Verification" phase_verify false "${resolved[@]}"

    # Post-install: offer a WordPress site or a standalone gCore app
    # (gCore is CMS-agnostic — WordPress is one deploy target, not the
    # only one). Skipped in --yes mode: non-interactive installs use
    # --site or the geodineum CLI afterwards.
    if [[ -z "$SITE_DOMAIN" ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$YES_MODE" != "true" ]]; then
        local can_wp=false can_app=false
        if needs_wordpress "${resolved[@]}"; then can_wp=true; fi
        if has_gcore "${resolved[@]}"; then can_app=true; fi

        # New/Existing-first decision tree. Even when neither WP nor gCore is
        # present, the node can still onboard an existing project or scaffold a
        # non-web service — so the tree always runs; unavailable web leaves grey out.
        prompt_setup_service "$can_wp" "$can_app"
    fi

    # Installation succeeded — clear the interrupt trap so a post-install
    # Ctrl-C (e.g., operator aborting the summary prompt) doesn't trigger
    # a spurious rollback of a healthy install.
    trap - INT TERM

    # Summary
    print_summary "${resolved[@]}"
}

main "$@"

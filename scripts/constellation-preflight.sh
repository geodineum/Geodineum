#!/bin/bash
# Read-only preflight for a machine that will host a NEW constellation (its own
# ValKey + gNode). Run it on that machine, as the user who will run install.sh,
# before installing anything. Every FAIL names its fix; nothing is changed.
#
#   scripts/constellation-preflight.sh --constellation mynet \
#       [--domain mynet.example.org] [--private-repo owner/repo]... \
#       [--port 3000]... [--data /path/to/file]... [--branch one-topology]
set -uo pipefail

CONSTELLATION="" DOMAIN="" BRANCH="" REPOS=() PORTS=() DATA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --constellation) CONSTELLATION="$2"; shift 2 ;;
        --domain)        DOMAIN="$2"; shift 2 ;;
        --branch)        BRANCH="$2"; shift 2 ;;
        --private-repo)  REPOS+=("$2"); shift 2 ;;
        --port)          PORTS+=("$2"); shift 2 ;;
        --data)          DATA+=("$2"); shift 2 ;;
        -h|--help)       sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[[ -n "$CONSTELLATION" ]] || { echo "--constellation <name> is required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[[ -n "$BRANCH" ]] || BRANCH="$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

PASS=0 WARN=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  \033[33mWARN\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        → %s\n' "$2"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        → %s\n' "$2"; }
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

NODE="$(hostname -s 2>/dev/null || echo unknown)"
echo "on $NODE: constellation preflight for '$CONSTELLATION' (installer branch $BRANCH, user $(id -un))"

say "1. Identity"
if [[ "$CONSTELLATION" =~ ^[a-z][a-z0-9_]{1,31}$ ]]; then ok "constellation name '$CONSTELLATION' is valid"
else bad "constellation name '$CONSTELLATION' is invalid" "lowercase letter first, then a-z 0-9 _ (2-32 chars)"; fi
if [[ "$NODE" =~ ^[a-z0-9][a-z0-9-]{0,62}$ && "$NODE" != localhost && "$NODE" != master ]]; then
    ok "node id will be '$NODE' (short hostname; permanent: heartbeat segment + consumer name)"
else
    bad "short hostname '$NODE' is not a usable node id" "sudo hostnamectl set-hostname <lowercase-name> before installing"
fi
[[ "$BRANCH" == main ]] && warn "installer is on main" "the one-topology code is on branch one-topology until it merges: git checkout one-topology"
if [[ -e /etc/geodineum/components/gnode-daemon/daemon.env ]]; then
    warn "a gNode is already installed here (daemon.env exists)" "a re-install keeps its constellation list; this is not a fresh machine"
else
    ok "no previous gNode install"
fi

say "2. Operating system and resources"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:24.04) ok "Ubuntu 24.04" ;;
        ubuntu:22.04) warn "Ubuntu 22.04" "works; ValKey is built from source (slower first install)" ;;
        debian:*)     warn "${PRETTY_NAME:-Debian}" "the installer is tested on Ubuntu" ;;
        *)            bad "${PRETTY_NAME:-unknown OS}" "install on Ubuntu 24.04" ;;
    esac
else bad "no /etc/os-release"; fi
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == aarch64 ]] && ok "architecture $(uname -m)" || bad "architecture $(uname -m) is unsupported"
have systemctl && [[ -d /run/systemd/system ]] && ok "systemd is PID 1" || bad "systemd is not running" "a container without systemd cannot host the services"
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
(( mem_gb >= 4 )) && ok "${mem_gb} GB RAM" || warn "${mem_gb} GB RAM" "cargo release builds want 4 GB+; add swap if lower"
for d in / /opt; do
    free_gb=$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc 0-9)
    [[ -z "$free_gb" ]] && continue
    (( free_gb >= 20 )) && ok "$free_gb GB free on $d" || bad "only $free_gb GB free on $d" "builds + target/ dirs need 20 GB+"
done
if have timedatectl && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then ok "clock is NTP-synchronised"
else warn "clock not confirmed NTP-synchronised" "heartbeats are judged stale after 75 s: sudo timedatectl set-ntp true"; fi

say "3. Privileges and tools"
[[ "$(id -u)" -eq 0 ]] && warn "running as root" "run as the deploy user; install.sh uses sudo itself and builds as that user"
if sudo -n true 2>/dev/null; then ok "sudo works without a prompt"
elif [[ " $(id -nG) " == *" sudo "* ]]; then ok "user is in the sudo group (install.sh will ask for the password)"
else bad "user '$(id -un)' cannot sudo" "usermod -aG sudo $(id -un), then log in again"; fi
for t in git curl ssh; do have "$t" && ok "$t present" || bad "$t missing" "sudo apt-get install -y $t"; done
if have cargo || [[ -x "$HOME/.cargo/bin/cargo" ]]; then ok "cargo present ($("${HOME}/.cargo/bin/cargo" --version 2>/dev/null || cargo --version))"
else warn "no rust toolchain for $(id -un)" "install.sh installs rustup for this user; or: curl https://sh.rustup.rs -sSf | sh -s -- -y"; fi
if timeout 8 curl -fsS -o /dev/null https://deb.debian.org 2>/dev/null || timeout 8 curl -fsS -o /dev/null http://archive.ubuntu.com 2>/dev/null; then ok "package mirrors reachable"
else bad "package mirrors unreachable" "check proxy / firewall for outbound http(s)"; fi

say "4. GitHub access (branch $BRANCH)"
if timeout 10 bash -c '</dev/tcp/github.com/22' 2>/dev/null; then ok "github.com:22 reachable"
else warn "github.com:22 blocked" "use HTTPS: GITHUB_TOKEN=<token> install.sh, or allow outbound 22"; fi
for r in geodineum/Geodineum geodineum/gNode geodineum/gNode-Client geodineum/gCore geodineum/Geodineum-COMMS geodineum/gNode-CMS; do
    if out="$(timeout 20 git ls-remote --heads "https://github.com/$r.git" "$BRANCH" 2>/dev/null)" && [[ -n "$out" ]]; then ok "$r has $BRANCH"
    else bad "$r: no branch $BRANCH (or unreachable)" "install with --components limited to repos that have it, or push the branch"; fi
done
for r in "${REPOS[@]}"; do
    if timeout 20 git ls-remote --exit-code "git@github.com:$r.git" HEAD >/dev/null 2>&1; then ok "private $r readable over ssh"
    elif [[ -n "${GITHUB_TOKEN:-}" ]] && timeout 20 git ls-remote --exit-code "https://x-access-token:${GITHUB_TOKEN}@github.com/$r.git" HEAD >/dev/null 2>&1; then ok "private $r readable with GITHUB_TOKEN"
    else bad "private $r not readable by $(id -un)" "add this machine's ssh key to an account with access (a deploy key covers ONE repo), or export GITHUB_TOKEN"; fi
done

say "5. Ports (must be free before install)"
for p in 47445 "${PORTS[@]}"; do
    if [[ -n "$(ss -Htln "sport = :$p" 2>/dev/null)" ]]; then bad "port $p is already listening" "see what holds it: sudo ss -tlnp 'sport = :$p'"
    else ok "port $p free"; fi
done
if [[ -n "$DOMAIN" ]]; then
    for p in 80 443; do [[ -n "$(ss -Htln "sport = :$p" 2>/dev/null)" ]] && warn "port $p in use" "fine if that is the web server you will use for $DOMAIN" || ok "port $p free"; done
fi

say "6. Domain"
if [[ -n "$DOMAIN" ]]; then
    dns="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
    pub="$(timeout 8 curl -fsS https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$dns" ]]; then bad "$DOMAIN does not resolve" "create the A record first; TLS (certbot) needs it"
    elif [[ -n "$pub" && "$dns" == "$pub" ]]; then ok "$DOMAIN → $dns (this machine)"
    else warn "$DOMAIN → $dns, this machine's public IP is ${pub:-unknown}" "fine behind a proxy/NAT you control; certbot HTTP-01 needs port 80 to reach here"; fi
else
    echo "  (no --domain given: skipped)"
fi

say "7. Data to bring"
if [[ ${#DATA[@]} -eq 0 ]]; then echo "  (no --data given: skipped)"; fi
for f in "${DATA[@]}"; do
    if [[ -r "$f" ]]; then
        ok "$f present ($(du -h "$f" 2>/dev/null | cut -f1))"
        [[ $(( $(stat -c %a "$f") % 10 )) -ne 0 ]] && warn "$f is world-readable" "chmod o-rwx '$f'"
    else bad "$f missing or unreadable" "copy it over before the session"; fi
done

say "Result on $NODE"
printf '  %d pass, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL == 0 )); then
    echo "  Ready. Install with:"
    echo "    sudo GEODINEUM_GIT_PROTOCOL=ssh ./install.sh --constellation-name $CONSTELLATION --components gnode-daemon --yes"
    echo "  (add ,geodineum-comms only once this machine has a way to send mail)"
fi
exit $(( FAIL > 0 ))

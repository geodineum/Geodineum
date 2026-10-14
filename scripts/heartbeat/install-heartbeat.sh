#!/bin/bash
# Install a probe-gated heartbeat for one component. Plan by default; --apply acts.
set -euo pipefail

usage() { echo "usage: $0 <component> --probe <unit:..|tcp:h:p|http:url|pid:file|cmd:/abs> [--constellation c] [--environment e] [--user u] [--password-file f] [--valkey-host h] [--valkey-port p] [--valkey-user u] [--apply]" >&2; exit 2; }

src="$(dirname "$(readlink -f "$0")")"
host="$(hostname -s)"
component="${1:-}"; [[ -n "$component" && "$component" != -* ]] || usage
shift
probe="" constellation=geodineum environment=production user=gnode-heartbeat
vhost=127.0.0.1 vport=47445 vuser="gnode_client_${component//-/_}" pwfile="" apply=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --probe) probe="${2:-}"; shift 2 ;;
        --constellation) constellation="${2:-}"; shift 2 ;;
        --environment) environment="${2:-}"; shift 2 ;;
        --user) user="${2:-}"; shift 2 ;;
        --password-file) pwfile="${2:-}"; shift 2 ;;
        --valkey-host) vhost="${2:-}"; shift 2 ;;
        --valkey-port) vport="${2:-}"; shift 2 ;;
        --valkey-user) vuser="${2:-}"; shift 2 ;;
        --apply) apply=1; shift ;;
        *) usage ;;
    esac
done
[[ -n "$probe" ]] || usage
[[ "$component" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "illegal component name" >&2; exit 2; }
[[ "$probe" =~ ^(unit|tcp|http|pid|cmd): ]] || { echo "unknown probe kind" >&2; exit 2; }
[[ -n "$pwfile" ]] || pwfile="/etc/geodineum/credentials/valkey_client_${component//-/_}.password"

lib=/usr/local/lib/geodineum/heartbeat
etc=/etc/geodineum/heartbeat
spec="$etc/$component.env"
group="$(stat -c %G "$pwfile" 2>/dev/null || echo "$user")"

step() { echo "on ${host}: $*"; }
run() { if (( apply )); then "$@"; fi; }

if (( apply )); then
    [[ $EUID -eq 0 ]] || { echo "on ${host}: --apply needs root" >&2; exit 1; }
else
    echo "on ${host}: plan only (add --apply to act)"
fi

step "install $src/geodineum-heartbeat.sh -> $lib/ (0750 root:$group)"
run install -d -m 0755 "$lib"
run install -m 0750 -o root -g "$group" "$src/geodineum-heartbeat.sh" "$lib/geodineum-heartbeat.sh"

step "write spec $spec (0640 root:$group, no secret inline)"
if (( apply )); then
    install -d -m 0755 "$etc"
    umask 0137
    cat > "$spec" <<SPEC
COMPONENT=$component
CONSTELLATION=$constellation
ENVIRONMENT=$environment
VALKEY_HOST=$vhost
VALKEY_PORT=$vport
VALKEY_USER=$vuser
VALKEY_PASSWORD_FILE=$pwfile
PROBE=$probe
SPEC
    chown root:"$group" "$spec"; chmod 0640 "$spec"
fi

step "install units geodineum-heartbeat@.service and .timer into /etc/systemd/system"
run install -m 0640 "$src/geodineum-heartbeat@.service" "$src/geodineum-heartbeat@.timer" /etc/systemd/system/

step "run as User=$user (drop-in geodineum-heartbeat@$component.service.d/user.conf; the user must read $pwfile via group $group)"
if (( apply )); then
    install -d -m 0750 "/etc/systemd/system/geodineum-heartbeat@$component.service.d"
    printf '[Service]\nUser=%s\nGroup=%s\n' "$user" "$group" > "/etc/systemd/system/geodineum-heartbeat@$component.service.d/user.conf"
    chmod 0640 "/etc/systemd/system/geodineum-heartbeat@$component.service.d/user.conf"
fi

step "systemctl daemon-reload; enable --now geodineum-heartbeat@$component.timer"
run systemctl daemon-reload
run systemctl enable --now "geodineum-heartbeat@$component.timer"

step "declare the node once (on the constellation master): geodineum topology register node $host --role observer --constellation $constellation"
step "verify: journalctl -u geodineum-heartbeat@$component.service -n 5"

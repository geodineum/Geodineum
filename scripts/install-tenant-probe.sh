#!/bin/bash
# on the master node, as root: install the nightly tenant probe (scripts/tenant-probe.sh) as a root-owned copy
# under /usr/local/lib/geodineum, with its timer (03:00 UTC). Re-run after changing the probe or lib/site-pool.sh.
#   sudo bash scripts/install-tenant-probe.sh --alert-site <site with COMMS recipients> [--run-now] [--apply]
set -euo pipefail
APPLY=0; NOW=0; ALERT_SITE=""
while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1; shift ;; --run-now) NOW=1; shift ;; --alert-site) ALERT_SITE="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "on $(hostname -s): needs root: sudo bash $0 $*" >&2; exit 1; }
[[ "$ALERT_SITE" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { echo "--alert-site <site_id> is required (the site whose COMMS recipients get the alert)" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB=/usr/local/lib/geodineum; ENVF=/etc/geodineum/tenant-probe.env
run() { if (( APPLY )); then "$@"; else echo "   WOULD: $*"; fi; }
echo "== on $(hostname -s): [tenant-probe] $( ((APPLY)) && echo APPLY || echo 'PLAN, add --apply')"
bash -n "$HERE/tenant-probe.sh"; bash -n "$HERE/../lib/site-pool.sh"
run install -d -m 0755 "$LIB"
run install -m 0750 -o root -g root "$HERE/tenant-probe.sh" "$LIB/tenant-probe.sh"
run install -m 0640 -o root -g root "$HERE/../lib/site-pool.sh" "$LIB/tenant-probe.lib.sh"
run install -d -m 0750 -o root -g root /var/lib/geodineum/tenant-probe
if (( APPLY )); then printf 'TENANT_PROBE_ALERT_SITE=%s\n' "$ALERT_SITE" > "$ENVF"; chmod 0640 "$ENVF"; else echo "   WOULD write $ENVF: TENANT_PROBE_ALERT_SITE=$ALERT_SITE"; fi
unit=$(cat <<UNIT
[Unit]
Description=Geodineum: every pair of sites refused on every layer (tenant probe)
After=network-online.target valkey.service apache2.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVF
Environment=TENANT_PROBE_LIB=$LIB/tenant-probe.lib.sh
ExecStart=$LIB/tenant-probe.sh
PrivateTmp=yes
Nice=10
TimeoutStartSec=30m
UNIT
)
timer=$(cat <<'TIMER'
[Unit]
Description=Geodineum: nightly tenant probe

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
TIMER
)
if (( APPLY )); then
    printf '%s\n' "$unit" > /etc/systemd/system/geodineum-tenant-probe.service
    printf '%s\n' "$timer" > /etc/systemd/system/geodineum-tenant-probe.timer
    chmod 0644 /etc/systemd/system/geodineum-tenant-probe.{service,timer}
    systemctl daemon-reload
    systemctl enable --now geodineum-tenant-probe.timer
    systemctl list-timers geodineum-tenant-probe.timer --no-pager | sed 's/^/   /'
    if (( NOW )); then
        echo "   running once now:"
        systemctl start geodineum-tenant-probe.service || true
        journalctl -u geodineum-tenant-probe.service -n 60 --no-pager -o cat | sed 's/^/   /'
    fi
else
    echo "   WOULD write /etc/systemd/system/geodineum-tenant-probe.service:"; printf '%s\n' "$unit" | sed 's/^/      | /'
    echo "   WOULD write /etc/systemd/system/geodineum-tenant-probe.timer (daily 04:10 UTC, up to 20 min later)"
    echo "   WOULD: systemctl enable --now geodineum-tenant-probe.timer"
fi
echo "   results: /var/lib/geodineum/tenant-probe/<date>.json; log: journalctl -u geodineum-tenant-probe"

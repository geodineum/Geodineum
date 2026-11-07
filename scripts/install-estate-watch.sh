#!/bin/bash
# on every node, as root: install the nightly estate watch (scripts/estate-watch.py) as a root-owned copy,
# with its timer (03:20 UTC). The first run records the baseline and reports what is already wrong.
#   sudo bash scripts/install-estate-watch.sh --alert-site <site with COMMS recipients> [--allow "<host> <host>"] [--apply]
set -euo pipefail
APPLY=0; ALERT_SITE=""; ALLOW=""
while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1; shift ;; --alert-site) ALERT_SITE="$2"; shift 2 ;; --allow) ALLOW="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "on $(hostname -s): needs root: sudo bash $0 $*" >&2; exit 1; }
[[ "$ALERT_SITE" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { echo "--alert-site <site_id> is required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB=/usr/local/lib/geodineum; ENVF=/etc/geodineum/estate-watch.env; ALLOWF=/etc/geodineum/estate-watch.allow
run() { if (( APPLY )); then "$@"; else echo "   WOULD: $*"; fi; }
echo "== on $(hostname -s): [estate-watch] $( ((APPLY)) && echo APPLY || echo 'PLAN, add --apply')"
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/estate-watch.py"
run install -d -m 0755 "$LIB"
run install -m 0750 -o root -g root "$HERE/estate-watch.py" "$LIB/estate-watch.py"
run install -d -m 0750 -o root -g root /var/lib/geodineum/estate-watch
(( APPLY )) || { echo "   WOULD write $ENVF, $ALLOWF, the unit and the timer"; exit 0; }
printf 'ESTATE_WATCH_ALERT_SITE=%s\n' "$ALERT_SITE" > "$ENVF"; chmod 0640 "$ENVF"
touch "$ALLOWF"; chmod 0640 "$ALLOWF"
for h in $ALLOW; do grep -qxF "$h" "$ALLOWF" || echo "$h" >> "$ALLOWF"; done
cat > /etc/systemd/system/geodineum-estate-watch.service <<UNIT
[Unit]
Description=Geodineum: what this node serves, against what it should serve
After=network-online.target apache2.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 -I $LIB/estate-watch.py
SuccessExitStatus=1
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/geodineum/estate-watch -/var/lib/geodineum-watch -/run/mysqld
Nice=10
TimeoutStartSec=30m
UNIT
cat > /etc/systemd/system/geodineum-estate-watch.timer <<'TIMER'
[Unit]
Description=Geodineum: nightly estate watch

[Timer]
OnCalendar=*-*-* 03:20:00 UTC
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
TIMER
chmod 0644 /etc/systemd/system/geodineum-estate-watch.{service,timer}
install -d -m 0750 -g adm /var/lib/geodineum-watch
systemctl daemon-reload
systemctl enable --now geodineum-estate-watch.timer >/dev/null
echo "   running once now (baseline):"
systemctl start geodineum-estate-watch.service || true
journalctl -u geodineum-estate-watch.service -n 40 --no-pager -o cat | sed 's/^/   /'

#!/bin/bash
# on aesir, as root: the check the portal's Status tab reads (scripts/site-status.py), a root-owned copy with a timer, every five minutes.
#   sudo bash scripts/install-site-status.sh --alert-site <site with COMMS recipients> [--apply]
set -euo pipefail
APPLY=0; ALERT_SITE=""
while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1; shift ;; --alert-site) ALERT_SITE="${2:-}"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "on $(hostname -s): needs root: sudo bash $0 $*" >&2; exit 1; }
[[ "$ALERT_SITE" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { echo "--alert-site <site_id> is required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB=/usr/local/lib/geodineum; ENVF=/etc/geodineum/site-status.env
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/site-status.py"
if (( ! APPLY )); then echo "== on $(hostname -s): would install $LIB/site-status.py, $ENVF, the unit and a five-minute timer. Add --apply."; exit 0; fi
install -d -m 0755 "$LIB"
install -m 0750 -o root -g root "$HERE/site-status.py" "$LIB/site-status.py"
printf 'SITE_STATUS_ALERT_SITE=%s\n' "$ALERT_SITE" > "$ENVF"; chmod 0640 "$ENVF"
cat > /etc/systemd/system/geodineum-site-status.service <<UNIT
[Unit]
Description=Geodineum: does each client site answer
After=network-online.target apache2.service

[Service]
Type=oneshot
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 -I $LIB/site-status.py
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=true
Nice=10
TimeoutStartSec=4m
UNIT
cat > /etc/systemd/system/geodineum-site-status.timer <<'TIMER'
[Unit]
Description=Geodineum: client sites, every five minutes

[Timer]
OnCalendar=*:0/5
Persistent=false

[Install]
WantedBy=timers.target
TIMER
chmod 0644 /etc/systemd/system/geodineum-site-status.{service,timer}
systemctl daemon-reload
systemctl enable --now geodineum-site-status.timer >/dev/null
systemctl start geodineum-site-status.service || true
journalctl -u geodineum-site-status.service -n 20 --no-pager -o cat | sed 's/^/   /'

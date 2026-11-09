#!/bin/bash
# on every node, as root: install the account watch (scripts/account-watch.py) as a root-owned copy, run daily at 07:40
# node time (after the 06:30 reboot and the morning updates). It reports through COMMS as site geodineum (the admin bot's chat).
# The first run records the baseline; after that every change to accounts, privileged groups, sudoers, ssh keys,
# crontabs, units, docker images and listeners is flagged, with a daily digest of logins and sudo use.
#   sudo bash scripts/install-account-watch.sh [--alert-site <site>] [--no-digest] [--apply]
set -euo pipefail
APPLY=0; ALERT_SITE=""; ARGS="--digest-always"
while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1; shift ;; --alert-site) ALERT_SITE="${2:-}"; shift 2 ;; --no-digest) ARGS=""; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "on $(hostname -s): needs root: sudo bash $0 $*" >&2; exit 1; }
# the operators' own site: COMMS sends its Telegram to the admin bot's chat, and a site's client mailboxes never see it
[[ -n "$ALERT_SITE" ]] || ALERT_SITE=geodineum
[[ "$ALERT_SITE" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { echo "--alert-site <site_id> is required (no estate watch to copy it from)" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB=/usr/local/lib/geodineum; ENVF=/etc/geodineum/account-watch.env
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/account-watch.py"
echo "== on $(hostname -s): [account-watch] alert site $ALERT_SITE, digest ${ARGS:+daily}${ARGS:-off}"
if (( ! APPLY )); then echo "   would install $LIB/account-watch.py, $ENVF, the unit and the 07:40 timer, then run it once (baseline). Add --apply."; exit 0; fi
install -d -m 0755 "$LIB"
install -m 0750 -o root -g root "$HERE/account-watch.py" "$LIB/account-watch.py"
install -d -m 0700 -o root -g root /var/lib/geodineum/account-watch
printf 'ACCOUNT_WATCH_ALERT_SITE=%s\nACCOUNT_WATCH_ARGS=%s\n' "$ALERT_SITE" "$ARGS" > "$ENVF"; chmod 0640 "$ENVF"
cat > /etc/systemd/system/geodineum-account-watch.service <<UNIT
[Unit]
Description=Geodineum: who can log in, who can become root, who did
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 -I $LIB/account-watch.py \$ACCOUNT_WATCH_ARGS
SuccessExitStatus=1
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/geodineum/account-watch -/var/lib/geodineum-watch
Nice=10
TimeoutStartSec=10m
UNIT
cat > /etc/systemd/system/geodineum-account-watch.timer <<'TIMER'
[Unit]
Description=Geodineum: daily account watch

[Timer]
OnCalendar=*-*-* 07:40:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER
chmod 0644 /etc/systemd/system/geodineum-account-watch.{service,timer}
systemctl daemon-reload
systemctl enable --now geodineum-account-watch.timer >/dev/null
systemctl start geodineum-account-watch.service || true
journalctl -u geodineum-account-watch.service -n 30 --no-pager -o cat | sed 's/^/   /'
echo "   when a flagged change was yours, accept it with"
echo "   sudo /usr/bin/python3 -I $LIB/account-watch.py --accept --no-alert"

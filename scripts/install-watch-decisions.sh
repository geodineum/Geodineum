#!/bin/bash
# on every node that runs the estate or account watch, as root: install the reader of the watches' buttons
# (scripts/watch-decisions.py) as a root-owned copy with its timer, every 2 minutes. Each node reads every press with
# its own consumer group and acts only on findings its own watches hold. The admin allowlist is COMMS_ADMIN_IDS from
# COMMS's env where COMMS runs; elsewhere give it with --admins. Without one it refuses. Install the watches first.
# Plan by default; --apply installs and runs it once (that run sends the findings open before this flow, once, with
# buttons); --remove takes it away (the watches keep their findings; --accept <id> and --reject <id> still work as root).
#   sudo bash scripts/install-watch-decisions.sh [--admins <id,id>] [--site geodineum] [--apply | --remove]
set -euo pipefail
APPLY=0; REMOVE=0; ADMINS=""; SITE=""
while [[ $# -gt 0 ]]; do case "$1" in
    --apply) APPLY=1; shift ;; --remove) REMOVE=1; shift ;; --admins) ADMINS="${2:-}"; shift 2 ;; --site) SITE="${2:-}"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "on $(hostname -s): needs root: sudo bash $0 $*" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB=/usr/local/lib/geodineum; ENVF=/etc/geodineum/watch-decisions.env
COMMS_ENV=/etc/geodineum/components/geodineum-comms/geodineum-comms.env; U=/etc/systemd/system/geodineum-watch-decisions
if (( REMOVE )); then
    systemctl disable --now geodineum-watch-decisions.timer 2>/dev/null || true
    rm -f "$U.service" "$U.timer" "$LIB/watch-decisions.py" "$ENVF" /var/lib/geodineum-watch/watch-decisions.status; systemctl daemon-reload
    echo "on $(hostname -s): watch decisions removed; the watches keep their findings"; exit 0
fi
[[ -n "$ADMINS" ]] || ADMINS="$(sed -n 's/^WATCH_DECISIONS_ADMINS=//p' "$ENVF" 2>/dev/null | head -1 || true)"
[[ -n "$SITE" ]] || SITE="$(sed -n 's/^WATCH_DECISIONS_SITE=//p' "$ENVF" 2>/dev/null | head -1 || true)"
SITE="${SITE:-geodineum}"
[[ "$SITE" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { echo "--site <site_id>" >&2; exit 2; }
COMMS_IDS="$(sed -n 's/^COMMS_ADMIN_IDS=//p' "$COMMS_ENV" 2>/dev/null | tail -1 | tr -d "\"' " || true)"
if [[ -n "$ADMINS" ]]; then
    [[ "$ADMINS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "--admins takes Telegram ids: 123,456" >&2; exit 2; }
    WHO="--admins ($(tr ',' '\n' <<<"$ADMINS" | wc -l) id(s))"
elif [[ "$COMMS_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    WHO="COMMS_ADMIN_IDS ($(tr ',' '\n' <<<"$COMMS_IDS" | wc -l) id(s))"
else
    echo "on $(hostname -s): no admin allowlist: no COMMS_ADMIN_IDS in $COMMS_ENV; give --admins <id,id>" >&2; exit 2
fi
for f in watch-decisions.py watch_findings.py; do python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/$f"; done
echo "== on $(hostname -s): [watch-decisions] allowlist from $WHO, replies as $SITE, every 2 minutes"
for w in estate account; do
    if [[ ! -f "$LIB/$w-watch.py" ]]; then echo "   $w watch: not installed here"
    elif grep -qF watch_findings "$LIB/$w-watch.py"; then echo "   $w watch: installed, decides once"
    else echo "   $w watch: installed, an older copy: run install-$w-watch.sh --apply first"; fi
done
if (( ! APPLY )); then
    echo "   would install $LIB/watch-decisions.py, $LIB/watch_findings.py, $ENVF, the unit and the 2-minute timer, then run it once. Add --apply."
    exit 0
fi
[[ -d "$LIB" ]] || install -d -m 0755 "$LIB"
install -m 0750 -o root -g root "$HERE/watch-decisions.py" "$LIB/watch-decisions.py"
install -m 0640 -o root -g root "$HERE/watch_findings.py" "$LIB/watch_findings.py"
[[ -d /var/lib/geodineum/watch-decisions ]] || install -d -m 0750 -o root -g root /var/lib/geodineum/watch-decisions
[[ -d /var/lib/geodineum-watch ]] || install -d -m 0750 -g adm /var/lib/geodineum-watch
{ printf 'WATCH_DECISIONS_SITE=%s\n' "$SITE"; [[ -z "$ADMINS" ]] || printf 'WATCH_DECISIONS_ADMINS=%s\n' "$ADMINS"; } > "$ENVF"; chmod 0640 "$ENVF"
cat > "$U.service" <<UNIT
[Unit]
Description=Geodineum: apply the answers to the watches' buttons
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/geodineum/estate-watch.env
EnvironmentFile=-/etc/geodineum/account-watch.env
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 -I $LIB/watch-decisions.py
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
NoNewPrivileges=yes
ReadWritePaths=/var/lib/geodineum/watch-decisions -/var/lib/geodineum/estate-watch -/var/lib/geodineum/account-watch -/var/lib/geodineum-watch
TimeoutStartSec=50m
UNIT
cat > "$U.timer" <<'TIMER'
[Unit]
Description=Geodineum: the watches' buttons, every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
TIMER
chmod 0644 "$U.service" "$U.timer"
systemctl daemon-reload
systemctl enable --now geodineum-watch-decisions.timer >/dev/null
systemctl start geodineum-watch-decisions.service || true
journalctl -u geodineum-watch-decisions.service -n 20 --no-pager -o cat | sed 's/^/   /'

#!/bin/bash
# Both nodes on Amsterdam time, the nightly reboot at 06:30 and what hangs off it after it. Plan by default.
#   on aesir:  sudo bash scripts/session-2026-11-08-reboot-window.sh --apply     clock, reboot 06:30, updates from 06:35
#   on squad:  sudo bash scripts/session-2026-11-08-reboot-window.sh --apply     what its clock change left behind
# What must not move stays on UTC by name: the backups (the changeover hour is 02:00-03:00) and the database (NOW()
# against the UTC dates PHP writes). Saved first; a second run changes nothing. Undo: see the last line it prints.
set -uo pipefail
APPLY=0; [[ "${1:-}" == --apply ]] && APPLY=1
[[ ${CRONTAB:-} != "" || $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
CT="${CRONTAB:-crontab}"; NODE="${REBOOT_NODE:-$(hostname -s)}"; R="${REBOOT_ROOT:-}"; BK="${REBOOT_BACKUP:-$R/root/crontabs-before-2026-11-08}"
SYSCTL="${REBOOT_SYSTEMCTL:-systemctl}"; TDC="${REBOOT_TIMEDATECTL:-timedatectl}"
ZONE=Europe/Amsterdam
case "$NODE" in
aesir*) JOBS=$'root|06:30|/usr/local/bin/reboot_system.sh\nhermes|06:30|/usr/local/bin/reboot_system.sh\nhermes|06:35|/usr/local/bin/update_upgrade.sh\nhermes|06:45|/usr/local/bin/git_update.sh\nollama|06:50|/home/ollama/scripts/update_ollama.sh\nhermes|07:00|/home/hermes/TOB/run_telegram_bot.sh'
        TIMERS=(sites-backup:02:40 valkey-backup:02:00); DBCONF="$R/etc/mysql/mysql.conf.d/zz-geodineum-utc.cnf" ;;
squad)  JOBS=$'ollamaz|06:30|sudo /sbin/shutdown -r now\nollamaz|06:45|/home/ollamaz/scripts/update_and_rename.sh\nollamaz|06:50|bash /home/ollamaz/aurelius-bench/validation/validation_dispatch.sh'
        TIMERS=(valkey-backup:02:00); DBCONF="$R/etc/mysql/mariadb.conf.d/99-geodineum-utc.cnf" ;;
*) echo "not aesir or squad: $NODE" >&2; exit 1 ;;
esac
step() { echo "== on $NODE: $*"; }
rc=0
(( APPLY )) && install -d -m 0700 "$BK"

step "crontabs: plain Amsterdam times"
for u in $(cut -d'|' -f1 <<<"$JOBS" | sort -u); do
    cur="$("$CT" -u "$u" -l 2>/dev/null)" || { echo "   $u: no crontab"; continue; }
    new="$(JOBS="$JOBS" WHO="$u" python3 -I -c '
import os, sys
lines = sys.stdin.read().split("\n")
jobs = [j.split("|", 2) for j in os.environ["JOBS"].split("\n") if j.startswith(os.environ["WHO"] + "|")]
for _, at, cmd in jobs:
    hh, mm = at.split(":")
    hits = [i for i, l in enumerate(lines) if cmd in l and not l.lstrip().startswith("#")]
    if len(hits) != 1:
        print("   NOT CHANGED, found %d lines for: %s" % (len(hits), cmd), file=sys.stderr)
        continue
    old = lines[hits[0]]
    start = old.index(cmd)
    # a command in a pipeline or after cd keeps what stands before it, past the five time fields or a guard
    head = old[:start].split(None, 5)
    lead = head[5] if len(head) > 5 and not head[5].startswith("[") else ""
    lines[hits[0]] = "%d %d * * * %s%s" % (int(mm), int(hh), lead, old[start:])
sys.stdout.write("\n".join(lines))' <<<"$cur")" || { rc=1; continue; }
    if [[ "$new" == "$cur" ]]; then echo "   $u: already right"; else
        diff <(printf '%s\n' "$cur") <(printf '%s\n' "$new") | grep -E '^[<>]' | cut -c1-140 | sed "s/^/   $u /"
    fi
    awk -v u="$u" '!/^[[:space:]]*#/ && NF>5 && $2 ~ /(^|,)2(,|$)/ {print "   NOTE " u ": in the changeover hour, skipped or doubled twice a year: " substr($0,1,90)}' <<<"$new"
    if (( APPLY )) && [[ "$new" != "$cur" ]]; then
        printf '%s\n' "$cur" > "$BK/$u.crontab"; chmod 0600 "$BK/$u.crontab"
        if printf '%s\n' "$new" | "$CT" -u "$u" -; then echo "   $u: installed, saved at $BK/$u.crontab"; else echo "   $u: FAILED, unchanged"; rc=1; fi
    fi
done

step "the daily, weekly and monthly system jobs: 06:25 would be cut by the reboot, they go to 07:25, 07:47, 07:52"
SC="$R/etc/crontab"
if grep -E '^(25|47|52) 6[[:space:]]' "$SC" >/dev/null; then
    if (( APPLY )); then cp -p "$SC" "$BK/etc-crontab"; sed -i -E 's/^(25|47|52) 6([[:space:]])/\1 7\2/' "$SC"; echo "   done, saved at $BK/etc-crontab"; else echo "   would change $SC"; fi
else echo "   already moved"; fi

step "backups stay at the same moment, named in UTC"
for t in "${TIMERS[@]}"; do
    name=${t%%:*}; at=${t#*:}; d="$R/etc/systemd/system/$name.timer.d"
    if (( APPLY )); then install -d -m 0755 "$d"; printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00 UTC\n' "$at" > "$d/utc.conf"; chmod 0644 "$d/utc.conf"; echo "   $name: $at UTC"; else echo "   $name would be pinned to $at UTC"; fi
done

step "the OS upgrade stays clear of the reboot: 07:15"
d="$R/etc/systemd/system/apt-daily-upgrade.timer.d"
if (( APPLY )); then install -d -m 0755 "$d"; printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 07:15\nRandomizedDelaySec=30m\n' > "$d/after-reboot.conf"; chmod 0644 "$d/after-reboot.conf"; echo "   done"; else echo "   would write $d/after-reboot.conf"; fi

if [[ "$NODE" == aesir* ]]; then
    step "tenant probe: 03:00 UTC, finished before the reboot in summer too"
    d="$R/etc/systemd/system/geodineum-tenant-probe.timer.d"
    if (( APPLY )); then install -d -m 0755 "$d"; printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 03:00:00 UTC\n' > "$d/before-reboot.conf"; chmod 0644 "$d/before-reboot.conf"; echo "   done"; else echo "   would write $d/before-reboot.conf"; fi
fi

step "the database keeps UTC; read at its next start, so the reboot, and until then nothing changes"
if (( APPLY )); then
    printf '[mysqld]\ndefault-time-zone = +00:00\n' > "$DBCONF"; chmod 0644 "$DBCONF"
    if [[ -z "$R" ]] && ! { mysqld --validate-config >/dev/null 2>&1 || mysqld --help --verbose >/dev/null 2>&1; }; then
        rm -f "$DBCONF"; echo "   FAILED: the database refuses this setting, removed; it will follow the system clock"; rc=1
    else echo "   $DBCONF"; fi
else echo "   would write $DBCONF"; fi

step "the clock"
now="$("$TDC" show -p Timezone --value 2>/dev/null)"
if [[ "$now" == "$ZONE" ]]; then echo "   already $ZONE"
elif (( APPLY )); then "$TDC" set-timezone "$ZONE" && echo "   $now -> $ZONE" || { echo "   FAILED"; rc=1; }
else echo "   would go from $now to $ZONE and restart cron"; fi
rm -f "$R/etc/profile.d/geodineum-amsterdam-time.sh" 2>/dev/null
if (( APPLY )); then
    "$SYSCTL" daemon-reload; "$SYSCTL" restart cron
    "$SYSCTL" list-timers valkey-backup.timer apt-daily-upgrade.timer --no-pager 2>/dev/null | sed -n '2,3p' | cut -c1-100 | sed 's/^/   next: /'
    date '+   it is now %H:%M %Z'
    echo "   Undo: sudo timedatectl set-timezone Etc/UTC; put back from $BK; remove the *.timer.d drop-ins and $DBCONF."
else echo "Plan only: add --apply."; fi
exit $rc

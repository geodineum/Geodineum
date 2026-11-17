#!/bin/bash
# The estate watch against a fake node: replays a site takeover step by step and checks that each
# step is flagged, and that a clean site stays quiet. Needs nothing but python3.
#   bash tests/estate-watch/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; W="$HERE/scripts/estate-watch.py"
D="$(mktemp -d)"; trap 'rm -rf "${D:?}"' EXIT
pass=0; fail=0
has()  { grep -F "$2" <<<"$3" >/dev/null && { pass=$((pass+1)); echo "  ok   $1"; } || { fail=$((fail+1)); echo "  FAIL $1 (no '$2')"; sed 's/^/       /' <<<"$3"; }; }
none() { grep -F "FLAG" <<<"$2" >/dev/null && { fail=$((fail+1)); echo "  FAIL $1"; sed 's/^/       /' <<<"$2"; } || { pass=$((pass+1)); echo "  ok   $1"; }; }
lacks() { grep -F -- "$2" <<<"$3" >/dev/null && { fail=$((fail+1)); echo "  FAIL $1 (found '$2')"; } || { pass=$((pass+1)); echo "  ok   $1"; }; }
eq()   { [[ "$2" == "$3" ]] && { pass=$((pass+1)); echo "  ok   $1"; } || { fail=$((fail+1)); echo "  FAIL $1 (want '$2', got '$3')"; }; }

mkdir -p "$D/vh" "$D/rec" "$D/www/site/wp-includes" "$D/www/site/wp-content/uploads" "$D/www/site/wp-admin" "$D/bin" "$D/db"
SITE="$D/www/site"
cat > "$D/vh/site.conf" <<E
<VirtualHost *:443>
  ServerName site.test
  DocumentRoot $SITE
</VirtualHost>
E
printf 'DOCROOTS="%s"\n' "$SITE" > "$D/rec/site.env"
touch "$D/acl"; chmod 0640 "$D/acl"
cat > "$SITE/wp-config.php" <<'E'
<?php define('DB_NAME','n'); define('DB_USER','u'); define('DB_PASSWORD','p'); define('DB_HOST','localhost'); $table_prefix='wp_';
E
echo "<?php \$wp_version = '9.9';" > "$SITE/wp-includes/version.php"
printf 'home\thttps://site.test\nsiteurl\thttps://site.test\nblogname\tA Site\n' > "$D/db/options"
echo owner > "$D/db/admins"; echo 3 > "$D/db/posts"; echo 'A Site' > "$D/db/title"
cat > "$D/bin/mysql" <<E
#!/bin/bash
case "\$*" in
  *option_name*) cat "$D/db/options" ;;
  *capabilities*) cat "$D/db/admins" ;;
  *post_status*) cat "$D/db/posts" ;;
esac
E
cat > "$D/bin/curl" <<E
#!/bin/bash
echo "<html><head><title>\$(cat "$D/db/title")</title></head><body>hello</body></html>"
E
chmod +x "$D/bin/mysql" "$D/bin/curl"
# wordpress.org, offline: a file:// URL for both answers
python3 -c "
import hashlib,json,sys,os
s='$SITE'
json.dump({'checksums':{'wp-includes/version.php':hashlib.md5(open(s+'/wp-includes/version.php','rb').read()).hexdigest()}},open('$D/sums.json','w'))
json.dump({'offers':[{'current':'9.9'}]},open('$D/ver.json','w'))"
go() { python3 -I "$W" --vhosts "$D/vh" --records "$D/rec" --allow "$D/allow" --state "$D/st" --status "$D/nodir/s" --mysql "$D/bin/mysql" --curl "$D/bin/curl" \
       --checksums-url "file://$D/sums.json" --version-url "file://$D/ver.json" --private "$D/acl" --no-alert "$@" 2>&1; }

o=$(go); none "first run on a clean site: baseline, no flags" "$o"; has "first run says it is the baseline" "baseline recorded" "$o"
o=$(go); none "second run on the same site: quiet" "$o"

echo 'wp2_a8cba6d178d2' >> "$D/db/admins"
o=$(go); has "07-21: a new administrator" "site.test: new administrator wp2_a8cba6d178d2" "$o"
o=$(go); has "stays flagged until accepted" "new administrator wp2_a8cba6d178d2" "$o"
o=$(go --accept); has "--accept records it" "accepted" "$o"
o=$(go); none "accepted: quiet" "$o"

echo '<?php // gShield honeypot' > "$SITE/wp-content/uploads/.security-trap.php"; o=$(go); none "gShield's own trap is excused" "$o"
echo '<?php eval($_POST[0]);' > "$SITE/wp-content/uploads/.security-trap.php"; o=$(go); has "a file merely named like the trap is not" "PHP under uploads" "$o"; rm -f "$SITE/wp-content/uploads/.security-trap.php"
mkdir -p "$SITE/wp-content/uploads/2026/07"; echo '<?php' > "$SITE/wp-content/uploads/2026/07/Bunk-up.php"
o=$(go); has "07-26: PHP under uploads" "PHP under uploads" "$o"
go --accept >/dev/null; rm -f "$SITE/wp-content/uploads/2026/07/Bunk-up.php"; go --accept >/dev/null

echo 500 > "$D/db/posts"; o=$(go); has "spam: published posts jump" "published posts jumped 3 -> 500" "$o"; go --accept >/dev/null

printf 'home\thttps://ads.example/x\nsiteurl\thttps://ads.example/x\nblogname\tA Site\n' > "$D/db/options"
o=$(go); has "home URL moved to an ad network" "home URL changed" "$o"; go --accept >/dev/null

printf 'home\thttps://ads.example/x\nsiteurl\thttps://ads.example/x\nblogname\tHACKED BY TEMPIX\n' > "$D/db/options"; echo 'HACKED BY TEMPIX' > "$D/db/title"
o=$(go); has "08-29: site name" "site name reads as a defacement" "$o"; has "08-29: the page itself" "the page reads as a defacement" "$o"; go --accept >/dev/null
o=$(go); has "a defacement cannot be accepted away" "site name reads as a defacement" "$o"

printf 'home\thttps://site.test\nsiteurl\thttps://site.test\nblogname\tA Site\n' > "$D/db/options"; echo 'A Site' > "$D/db/title"; go --accept >/dev/null
echo "<?php \$wp_version = '9.9'; eval(\$_POST['x']);" > "$SITE/wp-includes/version.php"
o=$(go); has "a changed core file" "core differs from wordpress.org" "$o"
python3 -c "import hashlib,json; json.dump({'checksums':{'wp-includes/version.php':hashlib.md5(open('$SITE/wp-includes/version.php','rb').read()).hexdigest()}},open('$D/st/checksums-9.9.json','w'))"
touch "$SITE/wp-includes/extra.php"; o=$(go); has "an extra file in a core folder" "wp-includes/extra.php" "$o"; rm -f "$SITE/wp-includes/extra.php"

mkdir -p "$D/www/forgotten/wp-includes"; cp "$SITE/wp-config.php" "$D/www/forgotten/"; cp "$SITE/wp-includes/version.php" "$D/www/forgotten/wp-includes/"
cat > "$D/vh/forgotten.conf" <<E
<VirtualHost *:443>
  ServerName forgotten.test
  DocumentRoot $D/www/forgotten
</VirtualHost>
E
o=$(go); has "a public site nothing maintains" "forgotten.test: public vhost" "$o"
echo 'forgotten.test' > "$D/allow"; o=$(go); r=$(grep -F 'public vhost' <<<"$o" || true); [[ -z "$r" ]] && { pass=$((pass+1)); echo "  ok   allowed by name: not an unregistered site"; } || { fail=$((fail+1)); echo "  FAIL allow list"; }
rm -f "$D/allow" "$D/vh/forgotten.conf"

mkdir -p "$D/www/under/public"
printf '<VirtualHost *:443>\n  ServerName under.test\n  DocumentRoot %s\n</VirtualHost>\n' "$D/www/under/public" > "$D/vh/under.conf"
printf 'DOCROOTS="%s"\n' "$D/www/under" > "$D/rec/under.env"; o=$(go); r=$(grep -F 'under.test: public vhost' <<<"$o" || true); [[ -z "$r" ]] && { pass=$((pass+1)); echo "  ok   a vhost serving public/ below its record's root is known"; } || { fail=$((fail+1)); echo "  FAIL subfolder docroot"; }
rm -f "$D/rec/under.env"; o=$(go); has "the same vhost with no record is flagged" "under.test: public vhost" "$o"; rm -f "$D/vh/under.conf"
chmod 0644 "$D/acl"; o=$(go); has "a world-readable ACL file" "is readable by every local user" "$o"; chmod 0640 "$D/acl"
echo "<?php \$wp_version = '9.8';" > "$SITE/wp-includes/version.php"; rm -f "$D/st/state.json"
o=$(go); has "old WordPress is flagged on the first run: a compromise cannot become the baseline" "WordPress 9.8, current 9.9" "$o"
secret=$(grep -c "'p'" <<<"$o" || true); [[ "$secret" == 0 ]] && { pass=$((pass+1)); echo "  ok   no database password in the output"; } || { fail=$((fail+1)); echo "  FAIL password printed"; }
has "the run's findings are kept for a daily report" "WordPress 9.8, current 9.9" "$(cat "$D/st/findings.json")"

echo "-- one finding at a time"
S2=(--state "$D/st2"); echo "<?php \$wp_version = '9.9';" > "$SITE/wp-includes/version.php"
rec() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); r=[dict(v,id=k) for k,v in s.get("findings",{}).items() if sys.argv[2] in v["text"]]; print(r[0].get(sys.argv[3]) if r else "none")' "$D/st2/state.json" "$1" "$2"; }
o=$(go "${S2[@]}"); none "a fresh baseline" "$o"
printf 'eve\nmallory\n' >> "$D/db/admins"; o=$(go "${S2[@]}")
has "two new administrators, two findings" "new administrator eve" "$o"; has "the second" "new administrator mallory" "$o"
IE=$(rec "administrator eve" id)
o=$(go "${S2[@]}" --accept "$IE"); has "--accept <id> takes one" "accepted $IE: administrator eve on site.test" "$o"
eq "and only that one" "accepted new" "$(rec "administrator eve" status) $(rec "administrator mallory" status)"
o=$(go "${S2[@]}"); lacks "the accepted administrator is quiet" "eve" "$o"; has "the other is still found" "new administrator mallory" "$o"
eq "the baseline holds the accepted one, not the waiting one" "['eve', 'owner', 'wp2_a8cba6d178d2']" "$(python3 -I -c 'import json,sys; print(sorted(list(json.load(open(sys.argv[1]))["wp"].values())[0]["admins"]))' "$D/st2/state.json")"
cp "$D/bin/mysql" "$D/mysql.ok"; printf '#!/bin/bash\nexit 1\n' > "$D/bin/mysql"
o=$(go "${S2[@]}"); has "a database that cannot be read is a finding" "WordPress not readable" "$o"
eq "the waiting administrator is not taken as gone" new "$(rec "administrator mallory" status)"
cp "$D/mysql.ok" "$D/bin/mysql"; o=$(go "${S2[@]}")
eq "readable again: the same finding, not a new one" 1 "$(grep -c 'new administrator mallory' <<<"$o")"
eq "and the failed read did not become the baseline" "['eve', 'owner', 'wp2_a8cba6d178d2']" "$(python3 -I -c 'import json,sys; print(sorted(list(json.load(open(sys.argv[1]))["wp"].values())[0]["admins"]))' "$D/st2/state.json")"
printf 'home\thttps://site.test\nsiteurl\thttps://site.test\nblogname\tHACKED BY X\n' > "$D/db/options"; o=$(go "${S2[@]}")
o=$(go "${S2[@]}" --accept "$(rec "reads as a defacement" id)"); rc=$?
eq "a defacement cannot be accepted by its id either" 3 "$rc"; has "and it says so" "cannot be accepted" "$o"
printf 'home\thttps://site.test\nsiteurl\thttps://site.test\nblogname\tA Site\n' > "$D/db/options"
printf '<VirtualHost *:443>\n  ServerName staging.site.test\n  DocumentRoot %s\n</VirtualHost>\n' "$SITE" > "$D/vh/staging.conf"
o=$(go "${S2[@]}"); has "a registered vhost that is new" "staging.site.test: a vhost that was not here last run" "$o"; go "${S2[@]}" --accept >/dev/null
echo 'Another Title' > "$D/db/title"; o=$(go "${S2[@]}")
has "a production page title change is a finding" "FLAG site.test: page title changed" "$o"
has "on a staging host it is information" "INFO staging.site.test: page title changed" "$o"
lacks "not a finding" "FLAG staging.site.test" "$o"
has "kept for the daily report's mail" "staging.site.test: page title changed" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["info"])' "$D/st2/findings.json")"
o=$(go "${S2[@]}"); lacks "and not again the next night" "staging.site.test" "$o"
lacks "the findings file carries no nonce" "nonce" "$(cat "$D/st2/findings.json")"
echo "== $pass ok, $fail failed"; exit $(( fail > 0 ))

#!/usr/bin/python3 -I
"""What a node serves, against what it should serve. Nightly as root on every node, from
geodineum-estate-watch.timer (install-estate-watch.sh). By hand: python3 -I estate-watch.py --no-alert

Flags a public vhost no site record owns, and for each WordPress: a new administrator, a changed home URL
or site name, a jump in published posts, PHP under uploads, core files that differ from wordpress.org, a
version left behind. Flags a served page whose title changed or reads as a defacement.

The first run on a node records what it finds and still reports anything wrong in itself (an unregistered
vhost, a modified core, an old version), so an existing compromise cannot become the baseline quietly.
Each finding is sent once, with two buttons (watch-decisions.py applies them): Expected moves that one fact into the
expected state (--accept <id>), Not mine sends one urgent alert with what to look at (--reject <id>). --accept alone
takes everything open. A page title change on a staging., dev. or preview. host is information only.
Reads only; writes its own state, the run's findings (findings.json, for a daily report), one status file and,
when something new is found, one alert."""
import argparse
import glob
import hashlib
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request

DEFACED = re.compile(r"hacked\s*by|pwned|defaced|jembot|owned\s*by", re.I)
VERSION_GRACE_DAYS = 3
POST_JUMP = 20
UA = "geodineum-estate-watch"
NON_PROD = re.compile(r"^(staging|dev|preview)\.")


def _lib():
    sys.dont_write_bytecode = True
    s = importlib.util.spec_from_file_location("watch_findings", os.path.join(os.path.dirname(os.path.realpath(__file__)), "watch_findings.py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = _lib()


def args_():
    a = argparse.ArgumentParser()
    a.add_argument("--vhosts", default="/etc/apache2/sites-enabled")
    a.add_argument("--records", default=os.environ.get("SITE_POOL_RECORDS", "/etc/geodineum/web"))
    a.add_argument("--allow", default="/etc/geodineum/estate-watch.allow")
    a.add_argument("--state", default="/var/lib/geodineum/estate-watch")
    a.add_argument("--status", default="/var/lib/geodineum-watch/estate-watch.status")
    a.add_argument("--mysql", default="mysql")
    a.add_argument("--curl", default="curl")
    a.add_argument("--checksums-url", default="https://api.wordpress.org/core/checksums/1.0/?version={v}&locale=en_US")
    a.add_argument("--version-url", default="https://api.wordpress.org/core/version-check/1.7/")
    a.add_argument("--no-net", action="store_true", help="no wordpress.org and no page requests")
    a.add_argument("--accept", nargs="?", const="all", metavar="ID", help="what is there now is expected: everything open, or one finding")
    a.add_argument("--reject", metavar="ID", help="a finding that is not ours: one urgent alert; it stays in the daily report until it is gone")
    a.add_argument("--nonce", help=argparse.SUPPRESS)
    a.add_argument("--by", default="")
    a.add_argument("--bootstrap", default="/etc/geodineum/bootstrap.env")
    a.add_argument("--valkey-cred", default="/etc/geodineum/credentials/valkey_daemon.password")
    a.add_argument("--alert-site", default=os.environ.get("ESTATE_WATCH_ALERT_SITE", ""))
    a.add_argument("--no-alert", action="store_true")
    a.add_argument("--private", nargs="*", default=["/etc/valkey/users.acl"], help="files that must never be world-readable")
    a.add_argument("--env", default="production")
    return a.parse_args()


def vhosts(root):
    """Every enabled vhost: names and docroot. A plain :80 redirect has no docroot and serves nothing."""
    out = []
    for path in sorted(glob.glob(os.path.join(root, "*"))):
        try:
            text = open(path, errors="replace").read()
        except OSError:
            continue
        for block in re.findall(r"<VirtualHost[^>]*>(.*?)</VirtualHost>", text, re.S | re.I):
            lines = [re.sub(r"\s+#.*$", "", l).strip() for l in block.splitlines() if not l.strip().startswith("#")]
            names, doc = [], ""
            for l in lines:
                p = l.split()
                if len(p) >= 2 and p[0].lower() == "servername":
                    names.append(p[1].lower())
                elif len(p) >= 2 and p[0].lower() == "serveralias":
                    names += [n.lower() for n in p[1:]]
                elif len(p) >= 2 and p[0].lower() == "documentroot":
                    doc = p[1].strip("\"'").rstrip("/")
            if names:
                out.append({"file": os.path.basename(path), "names": names, "docroot": doc})
    return out


def known_docroots(records):
    known = set()
    for f in glob.glob(os.path.join(records, "*.env")):
        try:
            for line in open(f, errors="replace"):
                m = re.match(r'^DOCROOTS="([^"]*)"$', line.strip())
                if m:
                    known.update(d.rstrip("/") for d in m.group(1).split())
        except OSError:
            pass
    return known


def allow_list(path):
    try:
        return {l.split("#")[0].strip().lower() for l in open(path) if l.split("#")[0].strip()}
    except OSError:
        return set()


def is_trap(path):
    """gShield's own honeypot lives under uploads by design. The name and marker are not enough: a file
    that can run anything an attacker sends is not the trap."""
    if os.path.basename(path) != ".security-trap.php":
        return False
    try:
        text = open(path, errors="replace").read(8192)
    except OSError:
        return False
    if "HONEYPOT TRAP" not in text and "gShield" not in text:
        return False
    return not re.search(r"\b(eval|assert|system|exec|shell_exec|passthru|popen|proc_open|move_uploaded_file|base64_decode|include|require)\b", text)


def wp_root(doc):
    for d in (doc, os.path.dirname(doc)):
        if d and os.path.isfile(os.path.join(d, "wp-config.php")) and os.path.isdir(os.path.join(doc, "wp-includes")):
            return d
    return None


def wp_read(root, doc, mysql):
    """Reads the site's own database with the site's own login. Refuses to guess: an error is a finding."""
    c = open(os.path.join(root, "wp-config.php"), errors="replace").read()
    g = lambda k: (re.search(r"define\(\s*['\"]%s['\"]\s*,\s*['\"]([^'\"]*)" % k, c) or [None, None])[1]
    m = re.search(r"\$table_prefix\s*=\s*['\"]([A-Za-z0-9_]+)", c)
    t = m.group(1) if m else "wp_"
    host = (g("DB_HOST") or "localhost").split(":")[0]
    env = dict(os.environ, MYSQL_PWD=g("DB_PASSWORD") or "")

    def q(sql):
        r = subprocess.run([mysql, "-h", host, "-u", g("DB_USER") or "", "-N", "-B", g("DB_NAME") or "", "-e", sql],
                           env=env, capture_output=True, text=True, timeout=60)
        if r.returncode:
            raise RuntimeError(f"database not readable: {r.stderr.strip()[:120]}")
        return r.stdout.strip()

    opts = dict(l.split("\t", 1) for l in q(f"select option_name,option_value from {t}options where option_name in ('home','siteurl','blogname')").splitlines() if "\t" in l)
    admins = sorted(q(f"select u.user_login from {t}users u join {t}usermeta m on m.user_id=u.ID where m.meta_key='{t}capabilities' and m.meta_value like '%administrator%'").splitlines())
    posts = int(q(f"select count(*) from {t}posts where post_type='post' and post_status='publish'") or 0)
    vm = re.search(r"\$wp_version\s*=\s*'([^']+)'", open(os.path.join(doc, "wp-includes/version.php"), errors="replace").read())
    uploads = os.path.join(doc, "wp-content/uploads")
    php = []
    for d, _, fs in os.walk(uploads):
        php += [os.path.join(d, f) for f in fs if f.lower().endswith((".php", ".phtml", ".phar")) and not is_trap(os.path.join(d, f))]
    return {"home": opts.get("home", ""), "siteurl": opts.get("siteurl", ""), "blogname": opts.get("blogname", ""),
            "admins": admins, "posts": posts, "version": vm.group(1) if vm else "", "uploads_php": sorted(php)[:20]}


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def core_diff(doc, version, url, cache):
    """Core files against wordpress.org's checksums for this version: changed, and extra in core folders."""
    f = os.path.join(cache, f"checksums-{re.sub('[^0-9.]', '', version)}.json")
    try:
        sums = json.load(open(f))
    except (OSError, ValueError):
        sums = fetch_json(url.format(v=version)).get("checksums") or {}
        if sums:
            with open(f, "w") as o:
                json.dump(sums, o)
    if not sums:
        return None
    changed = []
    for rel, h in sums.items():
        if rel.startswith("wp-content/"):
            continue
        p = os.path.join(doc, rel)
        try:
            if hashlib.md5(open(p, "rb").read()).hexdigest() != h:
                changed.append(rel)
        except OSError:
            changed.append(rel + " (missing)")
    extra = []
    for top in ("wp-admin", "wp-includes"):
        for d, _, fs in os.walk(os.path.join(doc, top)):
            extra += [r for r in (os.path.relpath(os.path.join(d, x), doc) for x in fs if x != ".htaccess") if r not in sums]
    return {"changed": sorted(changed)[:20], "extra": sorted(extra)[:20]}


def page_title(name, curl):
    r = subprocess.run([curl, "-sk", "-L", "--max-redirs", "3", "-m", "20", "-A", UA, "--resolve", f"{name}:443:127.0.0.1",
                        "--resolve", f"{name}:80:127.0.0.1", f"https://{name}/"], capture_output=True, timeout=40)
    body = r.stdout.decode("utf-8", "replace")
    m = re.search(r"<title[^>]*>([^<]{0,200})", body, re.I)
    return (m.group(1).strip() if m else ""), bool(DEFACED.search(body[:20000]))


def run(a, state):
    found, unchecked, now = [], set(), int(time.time())
    first = not state
    seen = {"vhosts": {}, "wp": {}, "titles": {}, "behind_since": dict(state.get("behind_since", {}))}
    vs = vhosts(a.vhosts)
    known, allow = known_docroots(a.records), allow_list(a.allow)
    latest = None
    if not a.no_net:
        try:
            latest = fetch_json(a.version_url)["offers"][0]["current"]
        except Exception as e:  # the watch must not stop on wordpress.org
            print(f"  ..   latest WordPress version not available: {e}")
    if latest is None:
        unchecked.add("wp-behind")
    if a.no_net:
        unchecked.update(("wp-core", "title", "defaced-page"))
    for secret in a.private:
        try:
            if os.stat(secret).st_mode & 0o004:
                found.append(W.F("private-readable", secret, f"{secret} readable by every user", f"{secret} is readable by every local user",
                                 "a permission an installer or a hand edit loosened", look=[f"ls -l {secret}"], remove=[f"sudo chmod o-r {secret}"]))
        except OSError:
            pass
    done_wp, done_title, done_vh = set(), set(), set()
    for v in vs:
        doc, primary = v["docroot"], v["names"][0]
        for n in v["names"]:
            seen["vhosts"][n] = doc
        if not doc:
            continue
        conf = os.path.join(a.vhosts, v["file"])
        vlook = [f"sudo cat {conf}", f"sudo ls -la {doc}"]
        vrm = [f"sudo a2dissite {re.sub(r'[.]conf$', '', v['file'])} && sudo systemctl reload apache2"]
        # a record names the site root; the vhost often serves its public/ or public_html/ below that
        unknown = not any(doc == k or doc.startswith(k + "/") for k in known) and not (set(v["names"]) & allow)
        if unknown and primary not in done_vh:
            done_vh.add(primary)
            found.append(W.F("vhost-unregistered", f"{primary}|{doc}", f"{primary} vhost",
                             f"{primary}: public vhost ({v['file']}, {doc}) has no site record and is not allowed: nothing maintains it",
                             "a site set up by hand, outside the installer", look=vlook, remove=vrm))
        elif not unknown and primary not in (state.get("vhosts") or {}) and not first and primary not in allow and primary not in done_vh:
            done_vh.add(primary)
            found.append(W.F("vhost-new", f"{primary}|{doc}", f"{primary} vhost", f"{primary}: a vhost that was not here last run ({v['file']}, {doc})",
                             "a site the installer added", patch=[["set", ["vhosts", primary], doc]], undo=[["set", ["vhosts", primary], None]],
                             look=vlook, remove=vrm))
        root = wp_root(doc)
        if root and doc not in done_wp:
            done_wp.add(doc)
            wpc = f"sudo -u www-data wp --path={doc} --skip-plugins --skip-themes"
            try:
                w = wp_read(root, doc, a.mysql)
            except Exception as e:
                found.append(W.F("wp-unreadable", doc, f"WordPress of {primary}", f"{primary}: WordPress not readable: {e}",
                                 "a database login that changed, or a database that is down", scope=doc,
                                 look=[f"sudo grep -E 'DB_(NAME|USER|HOST)' {root}/wp-config.php"]))
                unchecked.add(doc)
                w = None
            if w:
                seen["wp"][doc] = w
                old = (state.get("wp") or {}).get(doc)
                if old:
                    for adm in sorted(set(w["admins"]) - set(old["admins"])):
                        found.append(W.F("wp-admin", f"{doc}|{adm}", f"administrator {adm} on {primary}", f"{primary}: new administrator {adm}",
                                         "an administrator someone added in wp-admin", scope=doc,
                                         patch=[["add", ["wp", doc, "admins"], adm]], undo=[["drop", ["wp", doc, "admins"], adm]],
                                         look=[f"{wpc} user get {adm}"], remove=[f"{wpc} user set-role {adm} subscriber"]))
                    for k, label, guess in (("home", "home URL", "a domain move"), ("siteurl", "site URL", "a domain move"),
                                            ("blogname", "site name", "the site name edited in WordPress")):
                        if w[k] != old[k]:
                            found.append(W.F("wp-option", f"{doc}|{k}|{w[k]}", f"{primary} {label}", f"{primary}: {label} changed: {old[k]!r} -> {w[k]!r}",
                                             guess, scope=doc, patch=[["set", ["wp", doc, k], w[k]]], undo=[["set", ["wp", doc, k], old[k]]],
                                             look=[f"{wpc} option get {k}"]))
                    if w["posts"] > old["posts"] + POST_JUMP:
                        found.append(W.F("wp-posts", doc, f"{primary} posts", f"{primary}: published posts jumped {old['posts']} -> {w['posts']}",
                                         "a bulk import, or spam posts", scope=doc,
                                         patch=[["set", ["wp", doc, "posts"], w["posts"]]], undo=[["set", ["wp", doc, "posts"], old["posts"]]],
                                         look=[f"{wpc} post list --post_status=publish --posts_per_page=20 --fields=ID,post_date,post_title"]))
                if DEFACED.search(w["blogname"]):
                    found.append(W.F("defaced-name", f"{doc}|{w['blogname']}", f"{primary} site name", f"{primary}: site name reads as a defacement: {w['blogname']!r}",
                                     "a takeover", acceptable=False, scope=doc, look=[f"{wpc} option get blogname", f"{wpc} user list --role=administrator"]))
                if len(w["admins"]) > 5:
                    found.append(W.F("wp-admins-many", f"{doc}|{len(w['admins'])}", f"{primary} administrators", f"{primary}: {len(w['admins'])} administrators",
                                     "accounts nobody removed", scope=doc, look=[f"{wpc} user list --role=administrator"]))
                for php in w["uploads_php"]:
                    found.append(W.F("wp-uploads-php", f"{doc}|{php}", f"PHP file under uploads on {primary}", f"{primary}: PHP under uploads: {php}",
                                     "a file that should not run there: a web shell is the usual case", scope=doc,
                                     look=[f"sudo ls -la {php}", f"sudo head -c 1500 {php}"],
                                     remove=[f"sudo install -d -m 0700 /root/quarantine && sudo mv {php} /root/quarantine/"]))
                if latest and w["version"] and w["version"] != latest:
                    since = seen["behind_since"].setdefault(doc, now)
                    days = (now - since) // 86400
                    if days >= VERSION_GRACE_DAYS or first:
                        found.append(W.F("wp-behind", f"{doc}|{w['version']}|{latest}", f"{primary} WordPress version",
                                         f"{primary}: WordPress {w['version']}, current {latest} (behind for {days} d here)",
                                         "updates held back on this site", scope="behind:" + doc, look=[f"{wpc} core check-update"]))
                else:
                    seen["behind_since"].pop(doc, None)
                if not a.no_net and w["version"]:
                    try:
                        d = core_diff(doc, w["version"], a.checksums_url, a.state)
                        if d is None:
                            unchecked.add("core:" + doc)
                        elif d["changed"] or d["extra"]:
                            h = hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()[:12]
                            found.append(W.F("wp-core", f"{doc}|{w['version']}|{h}", f"{primary} core files",
                                             f"{primary}: core differs from wordpress.org {w['version']}: changed {d['changed'][:5]}, extra {d['extra'][:5]}",
                                             "an update that did not finish, or a changed core file", scope="core:" + doc,
                                             look=[f"{wpc} core verify-checksums"],
                                             remove=[f"{wpc} core download --force --skip-content --version={w['version']}"]))
                    except Exception as e:
                        unchecked.add("core:" + doc)
                        print(f"  ..   {primary}: checksums not available: {e}")
        if not a.no_net and primary not in done_title:
            done_title.add(primary)
            try:
                title, bad = page_title(primary, a.curl)
            except Exception as e:
                unchecked.add("page:" + primary)
                print(f"  ..   {primary}: no page: {e}")
                continue
            seen["titles"][primary] = title
            plook = [f"curl -sk --resolve {primary}:443:127.0.0.1 https://{primary}/ | head -40"]
            if bad or DEFACED.search(title):
                found.append(W.F("defaced-page", f"{primary}|{title}", f"{primary} page", f"{primary}: the page reads as a defacement: title {title!r}",
                                 "a takeover", acceptable=False, scope="page:" + primary, look=plook))
            old_t = (state.get("titles") or {}).get(primary)
            if old_t is not None and title and title != old_t:
                found.append(W.F("title", f"{primary}|{title}", f"{primary} page title", f"{primary}: page title changed: {old_t!r} -> {title!r}",
                                 "the title edited in WordPress", info=bool(NON_PROD.match(primary)), scope="page:" + primary,
                                 patch=[["set", ["titles", primary], title]], undo=[["set", ["titles", primary], old_t]], look=plook))
    # what could not be read this run keeps what was known, so a failed read never becomes the new baseline
    for k in ("wp", "titles"):
        for key, val in (state.get(k) or {}).items():
            seen[k].setdefault(key, val)
    return found, unchecked, seen, first, len(vs), len(done_wp)


def publish(a, host, state, info):
    path = os.path.join(a.state, "findings.json")
    old = W.load(path)
    W.save(path, {"host": host, "at": old.get("at", int(time.time())) if info is None else int(time.time()),
                  "findings": [r["text"] for r in W.live(state)], "items": W.items(state),
                  "info": old.get("info", []) if info is None else info}, 0o640)


def status(a, error):
    if not os.path.isdir(os.path.dirname(a.status)):
        return
    ok_ms = int(time.time() * 1000)
    try:
        prev = dict(l.strip().split("=", 1) for l in open(a.status) if "=" in l)
    except OSError:
        prev = {}
    with open(a.status + ".tmp", "w") as o:
        o.write(f"what=estate watch\nmax_age_h=26\nok_ms={ok_ms if not error else prev.get('ok_ms', 0)}\nrun_ms={ok_ms}\nerror={error}\n")
    os.chmod(a.status + ".tmp", 0o640)
    try:
        import shutil
        shutil.chown(a.status + ".tmp", group="adm")
    except (OSError, LookupError):
        pass
    os.replace(a.status + ".tmp", a.status)


def main():
    a = args_()
    host = socket.gethostname().split(".")[0]
    script = os.path.realpath(__file__)
    os.makedirs(a.state, mode=0o750, exist_ok=True)
    sf = os.path.join(a.state, "state.json")
    with W.Locked(a.state):
        if a.reject or (a.accept and a.accept != "all"):
            return W.decide(a, host, "Estate watch", "estate-watch", script, sf, 0o640, lambda st: publish(a, host, st, None))
        state = W.load(sf)
        migrate = bool(state) and state.get("v") != 2
        error = ""
        try:
            found, unchecked, seen, first, nv, nw = run(a, state)
        except Exception as e:
            error = str(e)
            print(f"== on {host}: the watch itself failed: {e}")
            try:
                W.failure(a, "Estate watch", "estate-watch", host, f"the estate watch itself failed: {e}")
            except Exception as e2:
                print(f"  ..   alert not sent: {e2}")
            status(a, error)
            return 1
        now = int(time.time())
        info = W.settle(state, found, now, migrate, unchecked)
        if a.accept == "all":
            W.accept_all(state, now, a.by or "root")
        new = dict(seen, findings=state["findings"], v=2)
        W.apply(new, W.undo_ops(state, now))
        open_ = W.live(state)
        print(f"== on {host}: {nv} vhost block(s), {nw} WordPress, {len(open_)} finding(s)"
              f"{' (first run: baseline recorded)' if first else ''}{' (first run of decide-once: open findings count as sent)' if migrate else ''}")
        for r in open_:
            print(f"  FLAG {r['text']}" + ("" if r["status"] == "new" else f"  [{r['status']} {r['id']}]"))
        for t in info:
            print(f"  INFO {t}")
        if a.accept == "all":
            print(f"  ..   accepted every open finding that can be accepted")
        try:
            entry = W.announce(W.connect(a.bootstrap, a.valkey_cred), a, "Estate watch", "estate-watch", host, script, new, now) \
                if not a.no_alert and a.alert_site and any(r["status"] == "new" for r in open_) else None
            if entry:
                print(f"  ..   alert to {a.alert_site}: {entry}")
        except Exception as e:
            print(f"  ..   alert not sent: {e}")
            error = f"alert not sent: {e}"
        W.save(sf, new, 0o640)
        W.recovered(a.state)
        try:
            publish(a, host, new, info)
        except OSError as e:
            print(f"  ..   findings not kept: {e}")
    status(a, error)
    return 1 if W.live(new) else 0


if __name__ == "__main__":
    sys.exit(main())

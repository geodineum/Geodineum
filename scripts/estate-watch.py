#!/usr/bin/python3 -I
"""What a node serves, against what it should serve. Nightly as root on every node, from
geodineum-estate-watch.timer (install-estate-watch.sh). By hand: python3 -I estate-watch.py --no-alert

Flags a public vhost no site record owns, and for each WordPress: a new administrator, a changed home URL
or site name, a jump in published posts, PHP under uploads, core files that differ from wordpress.org, a
version left behind. Flags a served page whose title changed or reads as a defacement.

The first run on a node records what it finds and still reports anything wrong in itself (an unregistered
vhost, a modified core, an old version), so an existing compromise cannot become the baseline quietly.
A change stays flagged until --accept records it as the new state, naming what was accepted.
Reads only; writes its own state, one status file and, when something is wrong, one alert."""
import argparse
import glob
import hashlib
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
    a.add_argument("--accept", action="store_true", help="record what is there now as the expected state")
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


def run(a):
    findings, now = [], int(time.time())
    os.makedirs(a.state, mode=0o750, exist_ok=True)
    state_file = os.path.join(a.state, "state.json")
    try:
        state = json.load(open(state_file))
    except (OSError, ValueError):
        state = {}
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
    for secret in a.private:
        try:
            if os.stat(secret).st_mode & 0o004:
                findings.append(f"{secret} is readable by every local user")
        except OSError:
            pass
    done_wp, done_title, done_vh = set(), set(), set()
    for v in vs:
        doc, primary = v["docroot"], v["names"][0]
        for n in v["names"]:
            seen["vhosts"][n] = doc
        if not doc:
            continue
        # a record names the site root; the vhost often serves its public/ or public_html/ below that
        unknown = not any(doc == k or doc.startswith(k + "/") for k in known) and not (set(v["names"]) & allow)
        if unknown and primary not in done_vh:
            done_vh.add(primary)
            findings.append(f"{primary}: public vhost ({v['file']}, {doc}) has no site record and is not allowed: nothing maintains it")
        elif not unknown and primary not in (state.get("vhosts") or {}) and not first and primary not in allow and primary not in done_vh:
            done_vh.add(primary)
            findings.append(f"{primary}: a vhost that was not here last run ({v['file']}, {doc})")
        root = wp_root(doc)
        if root and doc not in done_wp:
            done_wp.add(doc)
            try:
                w = wp_read(root, doc, a.mysql)
            except Exception as e:
                findings.append(f"{primary}: WordPress not readable: {e}")
                w = None
            if w:
                seen["wp"][doc] = w
                old = (state.get("wp") or {}).get(doc)
                if old:
                    new_admins = sorted(set(w["admins"]) - set(old["admins"]))
                    if new_admins:
                        findings.append(f"{primary}: {len(new_admins)} new administrator(s): {', '.join(new_admins[:10])}")
                    for k, label in (("home", "home URL"), ("siteurl", "site URL"), ("blogname", "site name")):
                        if w[k] != old[k]:
                            findings.append(f"{primary}: {label} changed: {old[k]!r} -> {w[k]!r}")
                    if w["posts"] > old["posts"] + POST_JUMP:
                        findings.append(f"{primary}: published posts jumped {old['posts']} -> {w['posts']}")
                if DEFACED.search(w["blogname"]):
                    findings.append(f"{primary}: site name reads as a defacement: {w['blogname']!r}")
                if len(w["admins"]) > 5:
                    findings.append(f"{primary}: {len(w['admins'])} administrators")
                if w["uploads_php"]:
                    findings.append(f"{primary}: PHP under uploads: {', '.join(w['uploads_php'][:5])}")
                if latest and w["version"] and w["version"] != latest:
                    since = seen["behind_since"].setdefault(doc, now)
                    days = (now - since) // 86400
                    if days >= VERSION_GRACE_DAYS or first:
                        findings.append(f"{primary}: WordPress {w['version']}, current {latest} (behind for {days} d here)")
                else:
                    seen["behind_since"].pop(doc, None)
                if not a.no_net and w["version"]:
                    try:
                        d = core_diff(doc, w["version"], a.checksums_url, a.state)
                        if d and (d["changed"] or d["extra"]):
                            findings.append(f"{primary}: core differs from wordpress.org {w['version']}: changed {d['changed'][:5]}, extra {d['extra'][:5]}")
                    except Exception as e:
                        print(f"  ..   {primary}: checksums not available: {e}")
        if not a.no_net and primary not in done_title:
            done_title.add(primary)
            try:
                title, bad = page_title(primary, a.curl)
            except Exception as e:
                print(f"  ..   {primary}: no page: {e}")
                continue
            seen["titles"][primary] = title
            if bad or DEFACED.search(title):
                findings.append(f"{primary}: the page reads as a defacement: title {title!r}")
            old_t = (state.get("titles") or {}).get(primary)
            if old_t is not None and title and title != old_t:
                findings.append(f"{primary}: page title changed: {old_t!r} -> {title!r}")
    return findings, seen, first, state_file, len(vs), len(done_wp)


def alert(a, host, findings, state_dir):
    """One mail per distinct set of findings, again after six hours if it stands. Uses the daemon's own login."""
    fp = hashlib.sha256("\n".join(sorted(findings)).encode()).hexdigest()[:16] if findings else "clean"
    fpf, atf = os.path.join(state_dir, "alert.fp"), os.path.join(state_dir, "alert.at")
    prev = open(fpf).read().strip() if os.path.exists(fpf) else ""
    at = int(open(atf).read().strip() or 0) if os.path.exists(atf) else 0
    open(fpf, "w").write(fp)
    send = bool(findings) and (fp != prev or time.time() - at > 21600)
    recovered = not findings and prev not in ("", "clean")
    if a.no_alert or not a.alert_site or not (send or recovered):
        return
    env = {}
    try:
        env = dict(l.strip().split("=", 1) for l in open("/etc/geodineum/bootstrap.env") if "=" in l and not l.startswith("#"))
    except OSError:
        pass
    cred = "/etc/geodineum/credentials/valkey_daemon.password"
    subject = f"[estate watch] {len(findings)} finding(s) on {host}" if findings else f"[estate watch] clean again on {host}"
    body = "\n".join(findings) if findings else "Everything this node serves is back to what is expected."
    r = subprocess.run(["valkey-cli", "-e", "--no-auth-warning", "-h", env.get("VALKEY_HOST", "127.0.0.1"), "-p", env.get("VALKEY_PORT", "47445"),
                        "--user", "gnode_daemon", "XADD", f"{{{a.alert_site}}}:gnode:comms:{a.env}", "*",
                        "site_id", a.alert_site, "environment", a.env, "type", "alert", "priority", "2" if findings else "4",
                        "timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "sender", '{"name":"estate watch"}',
                        "subject", subject, "body", body, "metadata", '{"source":"estate-watch","form_type":"alert"}',
                        "dispatch", '{"channels":["email","telegram"]}'],
                       env=dict(os.environ, REDISCLI_AUTH=open(cred).read().strip()), capture_output=True, text=True, timeout=20)
    print(f"  ..   alert to {a.alert_site}: {r.stdout.strip() or r.stderr.strip()}")
    if send:
        open(atf, "w").write(str(int(time.time())))


def main():
    a = args_()
    host = socket.gethostname().split(".")[0]
    error = ""
    try:
        findings, seen, first, state_file, nv, nw = run(a)
    except Exception as e:
        findings, seen, first, state_file, nv, nw = [f"the watch itself failed: {e}"], None, False, None, 0, 0
        error = str(e)
    print(f"== on {host}: {nv} vhost block(s), {nw} WordPress, {len(findings)} finding(s){' (first run: baseline recorded)' if first else ''}")
    for f in findings:
        print(f"  FLAG {f}")
    if seen is not None and (first or a.accept or not findings):
        with open(state_file + ".tmp", "w") as o:
            json.dump(seen, o, indent=1, sort_keys=True)
        os.chmod(state_file + ".tmp", 0o640)
        os.replace(state_file + ".tmp", state_file)
        if a.accept and findings:
            print(f"  ..   accepted {len(findings)} finding(s) as the expected state")
    elif seen is not None:
        # the page titles and versions move on; only the watched facts stay until accepted
        print("  ..   state kept until --accept: what is flagged stays flagged")
    if a.accept:
        findings = []
    try:
        alert(a, host, findings, a.state)
    except Exception as e:
        print(f"  ..   alert not sent: {e}")
        error = error or f"alert not sent: {e}"
    if os.path.isdir(os.path.dirname(a.status)):
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
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

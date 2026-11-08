#!/usr/bin/env python3
"""Every five minutes: does each client site answer, how long does its certificate last, when was the last backup.
Written for its portal to read: {site}:site:status, and {site}:site:incidents for each outage. Two failed checks in a
row make an outage, and the operator hears when one starts and ends. A preview copy (.viewkey) is not a client's site.
Checked on this node, through its own Apache: it says whether the site works, not whether the internet can reach it."""
import argparse
import datetime
import glob
import json
import os
import socket
import ssl
import subprocess
import time


def args():
    a = argparse.ArgumentParser()
    a.add_argument("--www", default="/var/www")
    a.add_argument("--curl", default="curl")
    a.add_argument("--systemctl", default="systemctl")
    a.add_argument("--port", default=os.environ.get("VALKEY_PORT", "47445"))
    a.add_argument("--cred", default="/etc/geodineum/credentials/valkey.password")
    a.add_argument("--alert-site", default=os.environ.get("SITE_STATUS_ALERT_SITE", ""))
    a.add_argument("--env", default="production")
    a.add_argument("--no-tls", action="store_true")
    return a.parse_args()


def vk(a, *cmd):
    env = dict(os.environ)
    if a.cred and os.path.exists(a.cred):
        env["REDISCLI_AUTH"] = open(a.cred).read().strip()
    r = subprocess.run(["valkey-cli", "--no-auth-warning", "-e", "-p", str(a.port), *cmd], env=env, capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        raise RuntimeError(f"valkey: {cmd[0]}: {r.stdout.strip()[:80]} {r.stderr.strip()[:80]}")
    return r.stdout.strip()


def sites(a):
    for marker in sorted(glob.glob(os.path.join(a.www, "*", ".site"))):
        root = os.path.dirname(marker)
        if os.path.exists(os.path.join(root, ".viewkey")):
            continue
        domain = os.path.basename(root)
        yield domain, domain.replace(".", "_").replace("-", "_")


def answers(a, domain):
    r = subprocess.run([a.curl, "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "15", "--resolve", f"{domain}:443:127.0.0.1", f"https://{domain}/"],
                       capture_output=True, text=True, timeout=30)
    code = r.stdout.strip()
    return code.isdigit() and 200 <= int(code) < 400


def tls_days(domain):
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection(("127.0.0.1", 443), timeout=8) as s, ctx.wrap_socket(s, server_hostname=domain) as t:
            end = ssl.cert_time_to_seconds(t.getpeercert()["notAfter"])
        return max(0, int((end - time.time()) // 86400))
    except ssl.SSLCertVerificationError:
        return 0
    except (OSError, ssl.SSLError, KeyError, ValueError):
        return None


def last_backup_ms(a):
    r = subprocess.run([a.systemctl, "show", "--timestamp=unix", "-p", "Result", "-p", "ExecMainExitTimestamp", "sites-backup.service"], capture_output=True, text=True, timeout=10)
    f = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
    at = f.get("ExecMainExitTimestamp", "").lstrip("@")
    return int(at) * 1000 if f.get("Result") == "success" and at.isdigit() else 0


def alert(a, subject, body):
    if not a.alert_site:
        return
    vk(a, "XADD", f"{{{a.alert_site}}}:gnode:comms:{a.env}", "*", "site_id", a.alert_site, "environment", a.env, "type", "alert", "priority", "2",
       "timestamp", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "sender", '{"name":"site status"}',
       "content", json.dumps({"subject": subject, "body": body}), "dispatch", '{"channels":["telegram","email"]}')


def check(a, domain, site, backup_ms, now_ms):
    key = f"{{{site}}}:site:status"
    cur = vk(a, "HGET", key, "state")
    fails = int(vk(a, "HGET", key, "fails") or 0)
    since = int(vk(a, "HGET", key, "since_ms") or 0)
    ok = answers(a, domain)
    fails = 0 if ok else fails + 1
    state = cur or "up"
    if ok and state == "down":
        vk(a, "XADD", f"{{{site}}}:site:incidents", "MAXLEN", "~", "50", "*", "from_ms", str(since), "to_ms", str(now_ms))
        alert(a, f"[site status] {domain} answers again", f"{domain} did not answer for {max(1, (now_ms - since) // 60000)} minutes.")
        state, since = "up", now_ms
    elif not ok and state == "up" and fails >= 2:
        alert(a, f"[site status] {domain} does not answer", f"{domain} failed {fails} checks in a row on this node.")
        state, since = "down", now_ms
    elif not since:
        since = now_ms
    fields = ["state", state, "fails", str(fails), "since_ms", str(since), "checked_ms", str(now_ms)]
    if backup_ms:
        fields += ["backup_ms", str(backup_ms)]
    days = None if a.no_tls else tls_days(domain)
    if days is not None:
        fields += ["tls_days", str(days)]
    vk(a, "HSET", key, *fields)
    return ok


def main():
    a = args()
    now_ms = int(time.time() * 1000)
    backup = last_backup_ms(a)
    bad = 0
    for domain, site in sites(a):
        try:
            print(("ok  " if check(a, domain, site, backup, now_ms) else "FAIL"), domain)
        except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as e:
            bad += 1
            print("ERROR", domain, e)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())

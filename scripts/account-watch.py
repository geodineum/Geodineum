#!/usr/bin/env python3
"""Account watch: who can log in, who can become root, what runs as root, who did log in and use sudo.

Nightly as root. The first run records a baseline; afterwards a change is flagged until `--accept` records it.
Every run also writes a digest of the last day's logins and sudo use, sent with the findings (and on its own with
--digest-always). Findings and digest go through COMMS like the estate watch. Reads only; changes nothing it watches.
  python3 -I account-watch.py [--accept] [--no-alert] [--root /]   (--root and the --cmd-* options exist for the tests)
"""
import argparse, glob, hashlib, json, os, re, socket, subprocess, sys, time

PRIV_GROUPS = ["root", "sudo", "admin", "wheel", "docker", "lxd", "disk", "adm", "shadow", "aesir", "geodineum-creds"]
NOLOGIN = ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false", "/usr/bin/false", "")


def args_():
    a = argparse.ArgumentParser()
    a.add_argument("--root", default="/")
    a.add_argument("--state", default="/var/lib/geodineum/account-watch")
    a.add_argument("--status", default="/var/lib/geodineum-watch/account-watch.status")
    a.add_argument("--accept", action="store_true", help="record what is there now as the expected state")
    a.add_argument("--alert-site", default=os.environ.get("ACCOUNT_WATCH_ALERT_SITE", ""))
    a.add_argument("--env", default="production")
    a.add_argument("--no-alert", action="store_true")
    a.add_argument("--digest-always", action="store_true", help="send the digest even when nothing is flagged")
    a.add_argument("--hours", type=int, default=26, help="how far back the digest of logins and sudo looks")
    a.add_argument("--cmd-last", default="last -w -i --time-format iso")
    a.add_argument("--cmd-auth", default="journalctl -q --no-pager -o short-iso _COMM=sudo _COMM=sshd --since -{hours}h")
    a.add_argument("--cmd-docker", default="docker image ls --digests --format {{.Repository}}:{{.Tag}}@{{.Digest}}")
    a.add_argument("--cmd-ports", default="ss -H -ltnu")
    return a.parse_args()


def P(a, path):
    return os.path.join(a.root, path.lstrip("/"))


def sh(cmd, a):
    try:
        r = subprocess.run(cmd.replace("{hours}", str(a.hours)).split(), capture_output=True, text=True, timeout=60)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def read(path):
    try:
        return open(path, errors="replace").read()
    except OSError:
        return None


def lines_of(text):
    return sorted({l.strip() for l in (text or "").splitlines() if l.strip() and not l.lstrip().startswith("#")})


def mask(line):
    return re.sub(r"((?:TOKEN|PASS(?:WORD)?|SECRET|KEY|AUTH)[A-Z_]*=)[^ $(;\"']+", r"\1<masked>", line, flags=re.I)


def collect(a):
    s = {}
    users, homes = {}, {}
    for l in (read(P(a, "/etc/passwd")) or "").splitlines():
        p = l.split(":")
        if len(p) >= 7:
            homes[p[0]] = p[5]
            if p[6] not in NOLOGIN:
                users[p[0]] = f"uid {p[2]}, shell {p[6]}"
    s["login_accounts"] = users
    groups = {}
    for l in (read(P(a, "/etc/group")) or "").splitlines():
        p = l.split(":")
        if len(p) >= 4 and p[0] in PRIV_GROUPS:
            groups[p[0]] = sorted(m for m in p[3].split(",") if m)
    s["groups"] = groups
    sud = {}
    for f in [P(a, "/etc/sudoers")] + sorted(glob.glob(P(a, "/etc/sudoers.d/*"))):
        if os.path.isfile(f):
            sud[os.path.basename(f)] = [mask(l) for l in lines_of(read(f)) if not l.startswith("Defaults")]
    s["sudoers"] = sud
    keys = {}
    for u, h in homes.items():
        for f in (os.path.join(h, ".ssh/authorized_keys"), os.path.join(h, ".ssh/authorized_keys2")):
            t = read(P(a, f))
            if t is None:
                continue
            for l in lines_of(t):
                parts = l.split()
                blob = next((x for x in parts if len(x) > 60 and re.match(r"^[A-Za-z0-9+/=]+$", x)), l)
                keys.setdefault(u, []).append(hashlib.sha256(blob.encode()).hexdigest()[:16] + " " + (parts[-1] if len(parts) > 2 else ""))
    s["ssh_keys"] = {u: sorted(v) for u, v in keys.items()}
    cron = {}
    for f in [P(a, "/etc/crontab")] + sorted(glob.glob(P(a, "/etc/cron.d/*"))) + sorted(glob.glob(P(a, "/var/spool/cron/crontabs/*"))):
        if os.path.isfile(f):
            cron[f[len(a.root.rstrip("/")):] if a.root != "/" else f] = [mask(l) for l in lines_of(read(f)) if not re.match(r"^[A-Z_]+=", l)]
    s["crontabs"] = cron
    units = sorted(os.path.basename(f) for f in glob.glob(P(a, "/etc/systemd/system/*.service")) + glob.glob(P(a, "/etc/systemd/system/*.timer")))
    s["units"] = units
    d = sh(a.cmd_docker, a)
    s["docker_images"] = lines_of(d) if d is not None else None
    ports = sh(a.cmd_ports, a)
    if ports is not None:
        s["ports"] = sorted({f"{p[0]} {p[4]}" for p in (l.split() for l in ports.splitlines()) if len(p) >= 5})
    return s


def diff(old, new, label):
    out = []
    if isinstance(new, dict):
        for k in sorted(set(old or {}) | set(new)):
            o, n = (old or {}).get(k), new.get(k)
            if o == n:
                continue
            if o is None:
                out.append(f"{label}: new {k}" + (f": {n}" if isinstance(n, str) else f" ({len(n)} entr{'y' if len(n) == 1 else 'ies'})" if isinstance(n, list) else ""))
                if isinstance(n, list):
                    out += [f"    + {x}" for x in n[:12]]
            elif n is None:
                out.append(f"{label}: {k} is gone")
            elif isinstance(n, list):
                add, gone = sorted(set(n) - set(o)), sorted(set(o) - set(n))
                out.append(f"{label} {k}: " + ", ".join(x for x in [f"{len(add)} added" if add else "", f"{len(gone)} removed" if gone else ""] if x))
                out += [f"    + {x}" for x in add[:12]] + [f"    - {x}" for x in gone[:12]]
            else:
                out.append(f"{label} {k}: {o} -> {n}")
    elif isinstance(new, list):
        add, gone = sorted(set(new) - set(old or [])), sorted(set(old or []) - set(new))
        if add or gone:
            out.append(f"{label}: " + ", ".join(x for x in [f"{len(add)} added" if add else "", f"{len(gone)} removed" if gone else ""] if x))
            out += [f"    + {x}" for x in add[:12]] + [f"    - {x}" for x in gone[:12]]
    return out


def digest(a, known_ips):
    """Logins and sudo in the last --hours: who, from where, how often; a source address not seen before is flagged."""
    flags, logins, sudo = [], {}, {}
    since = time.time() - a.hours * 3600
    for l in (sh(a.cmd_last, a) or "").splitlines():
        p = l.split()
        if len(p) < 4 or p[0] in ("reboot", "wtmp", "shutdown") or not re.match(r"^\d{4}-\d\d-\d\dT", p[3]):
            continue
        try:
            t = time.mktime(time.strptime(p[3][:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            continue
        if t < since:
            continue
        user, ip = p[0], p[2]
        logins.setdefault(user, {}).setdefault(ip, 0)
        logins[user][ip] += 1
        if ip not in known_ips.get(user, []):
            flags.append(f"login: {user} from {ip}, an address this account never used before ({p[3][:16]})")
    for l in (sh(a.cmd_auth, a) or "").splitlines():
        m = re.search(r"sudo\[?\d*\]?:\s+(\S+) : .*?COMMAND=(.*)$", l)
        if m:
            sudo.setdefault(m.group(1), []).append(m.group(2))
            continue
        m = re.search(r"sshd\[\d+\]: Accepted (\S+) for (\S+) from (\S+)", l)
        if m and m.group(2) not in logins:
            logins.setdefault(m.group(2), {}).setdefault(m.group(3), 0)
    lines = []
    for u, ips in sorted(logins.items()):
        lines.append(f"logins {u}: " + ", ".join(f"{ip} x{n}" if n else ip for ip, n in sorted(ips.items())))
    for u, cmds in sorted(sudo.items()):
        if u == "root":
            lines.append(f"sudo root (the sweep and timers): {len(cmds)}")
            continue
        top = {}
        for c in cmds:
            k = " ".join(c.split()[:2])
            top[k] = top.get(k, 0) + 1
        lines.append(f"sudo {u}: {len(cmds)}: " + ", ".join(f"{k} x{n}" for k, n in sorted(top.items(), key=lambda x: -x[1])[:6]))
    return flags, lines, logins


def alert(a, host, findings, lines, state_dir):
    fp = hashlib.sha256("\n".join(sorted(findings)).encode()).hexdigest()[:16] if findings else "clean"
    fpf, atf = os.path.join(state_dir, "alert.fp"), os.path.join(state_dir, "alert.at")
    prev = (read(fpf) or "").strip()
    at = int((read(atf) or "0").strip() or 0)
    open(fpf, "w").write(fp)
    send = bool(findings) and (fp != prev or time.time() - at > 21600)
    if a.no_alert or not a.alert_site or not (send or a.digest_always):
        return
    env = {}
    try:
        env = dict(l.strip().split("=", 1) for l in open("/etc/geodineum/bootstrap.env") if "=" in l and not l.startswith("#"))
    except OSError:
        pass
    subject = f"[account watch] {len([f for f in findings if not f.startswith('    ')])} finding(s) on {host}" if findings else f"[account watch] {host}: nothing new"
    body = "\n".join(findings + ([""] if findings else []) + ["Last day:"] + (lines or ["no logins, no sudo"]))
    r = subprocess.run(["valkey-cli", "-e", "--no-auth-warning", "-h", env.get("VALKEY_HOST", "127.0.0.1"), "-p", env.get("VALKEY_PORT", "47445"),
                        "--user", "gnode_daemon", "XADD", f"{{{a.alert_site}}}:gnode:comms:{a.env}", "*",
                        "site_id", a.alert_site, "environment", a.env, "type", "alert", "priority", "2" if findings else "4",
                        "timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "sender", '{"name":"account watch"}',
                        "subject", subject, "body", body[:3500], "metadata", '{"source":"account-watch","form_type":"alert"}',
                        "dispatch", '{"channels":["email","telegram"]}'],
                       env=dict(os.environ, REDISCLI_AUTH=open("/etc/geodineum/credentials/valkey_daemon.password").read().strip()),
                       capture_output=True, text=True, timeout=20)
    print(f"  ..   alert to {a.alert_site}: {r.stdout.strip() or r.stderr.strip()}")
    if send:
        open(atf, "w").write(str(int(time.time())))


def main():
    a = args_()
    host = socket.gethostname().split(".")[0]
    os.makedirs(a.state, mode=0o750, exist_ok=True)
    sf = os.path.join(a.state, "state.json")
    try:
        state = json.load(open(sf))
    except (OSError, ValueError):
        state = {}
    first = not state
    error = ""
    try:
        now = collect(a)
        findings = []
        if not first:
            for k, label in (("login_accounts", "account that can log in"), ("groups", "group"), ("sudoers", "sudoers"),
                             ("ssh_keys", "ssh key"), ("crontabs", "crontab"), ("units", "systemd unit"),
                             ("docker_images", "docker image"), ("ports", "listening port")):
                if now.get(k) is not None:
                    findings += diff(state.get(k), now[k], label)
        known = state.get("login_ips", {})
        lflags, lines, logins = digest(a, known)
        if not first:
            findings += lflags
        for u, ips in logins.items():
            known.setdefault(u, [])
            known[u] = sorted(set(known[u]) | set(ips))
        now["login_ips"] = known
    except Exception as e:
        findings, lines, now, error = [f"the watch itself failed: {e}"], [], None, str(e)
    print(f"== on {host}: {len([f for f in findings if not f.startswith('    ')])} finding(s){' (first run: baseline recorded)' if first else ''}")
    for f in findings:
        print(f"  FLAG {f}" if not f.startswith("    ") else f"       {f.strip()}")
    for l in lines:
        print(f"  ..   {l}")
    if now is not None and (first or a.accept or not findings):
        with open(sf + ".tmp", "w") as o:
            json.dump(now, o, indent=1, sort_keys=True)
        os.chmod(sf + ".tmp", 0o600)
        os.replace(sf + ".tmp", sf)
        if a.accept and findings:
            print(f"  ..   accepted as the expected state")
    elif now is not None:
        # new login addresses are remembered even while other findings wait for --accept
        st = dict(state, login_ips=now["login_ips"])
        with open(sf + ".tmp", "w") as o:
            json.dump(st, o, indent=1, sort_keys=True)
        os.chmod(sf + ".tmp", 0o600)
        os.replace(sf + ".tmp", sf)
        print("  ..   kept until --accept: what is flagged stays flagged")
    if a.accept:
        findings = []
    try:
        alert(a, host, findings, lines, a.state)
    except Exception as e:
        print(f"  ..   alert not sent: {e}")
        error = error or f"alert not sent: {e}"
    if os.path.isdir(os.path.dirname(a.status)):
        ms = int(time.time() * 1000)
        prev = dict(l.strip().split("=", 1) for l in (read(a.status) or "").splitlines() if "=" in l)
        with open(a.status + ".tmp", "w") as o:
            o.write(f"what=account watch\nmax_age_h=26\nok_ms={ms if not error else prev.get('ok_ms', 0)}\nrun_ms={ms}\nerror={error}\n")
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

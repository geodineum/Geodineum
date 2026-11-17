#!/usr/bin/env python3
"""Account watch: who can log in, who can become root, what runs as root, who did log in and use sudo.

Nightly as root. The first run records a baseline. Each change after that is sent once, with two buttons
(watch-decisions.py applies them): Expected moves that one fact into the baseline (--accept <id>), Not mine sends one
urgent alert with what to look at (--reject <id>); --accept alone takes everything open. Something that went away
(an account, a listener, a unit) is information only.
Every run also writes a digest of the last day's logins and sudo use to <state>/digest.json. With --daily send the
digest goes with the findings (and on its own with --digest-always); with --daily report a daily report reads it and
the alerts carry the findings alone. auto: report once daily-report.status is in the status directory.
Findings go through COMMS like the estate watch. Reads only.
  python3 -I account-watch.py [--accept [<id>] | --reject <id>] [--no-alert] [--root /]   (--root and the --cmd-* options exist for the tests)
"""
import argparse, glob, hashlib, importlib.util, json, os, re, socket, subprocess, sys, time

PRIV_GROUPS = ["root", "sudo", "admin", "wheel", "docker", "lxd", "disk", "adm", "shadow", "geodineum-creds"]
NOLOGIN = ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false", "/usr/bin/false", "")
WATCHED = (("login_accounts", "account that can log in"), ("groups", "group"), ("sudoers", "sudoers"), ("ssh_keys", "ssh key"),
           ("crontabs", "crontab"), ("units", "systemd unit"), ("docker_images", "docker image"), ("ports", "listening port"))


def _lib():
    sys.dont_write_bytecode = True
    s = importlib.util.spec_from_file_location("watch_findings", os.path.join(os.path.dirname(os.path.realpath(__file__)), "watch_findings.py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = _lib()


def args_():
    a = argparse.ArgumentParser()
    a.add_argument("--root", default="/")
    a.add_argument("--state", default="/var/lib/geodineum/account-watch")
    a.add_argument("--status", default="/var/lib/geodineum-watch/account-watch.status")
    a.add_argument("--accept", nargs="?", const="all", metavar="ID", help="what is there now is expected: everything open, or one finding")
    a.add_argument("--reject", metavar="ID", help="a finding that is not ours: one urgent alert; it stays in the daily report until it is gone")
    a.add_argument("--nonce", help=argparse.SUPPRESS)
    a.add_argument("--by", default="")
    a.add_argument("--bootstrap", default="/etc/geodineum/bootstrap.env")
    a.add_argument("--valkey-cred", default="/etc/geodineum/credentials/valkey_daemon.password")
    a.add_argument("--alert-site", default=os.environ.get("ACCOUNT_WATCH_ALERT_SITE", ""))
    a.add_argument("--env", default="production")
    a.add_argument("--no-alert", action="store_true")
    a.add_argument("--digest-always", action="store_true", help="send the digest even when nothing is flagged (--daily send)")
    a.add_argument("--daily", choices=["auto", "report", "send"], default=os.environ.get("ACCOUNT_WATCH_DAILY") or "auto")
    a.add_argument("--hours", type=int, default=26, help="how far back the digest of logins and sudo looks")
    a.add_argument("--cmd-last", default="last -w -i --time-format iso")
    a.add_argument("--cmd-auth", default="journalctl -q --no-pager -o short-iso _COMM=sudo _COMM=sshd --since -{hours}h")
    a.add_argument("--cmd-docker", default="docker image ls --digests --format {{.Repository}}:{{.Tag}}@{{.Digest}}")
    a.add_argument("--cmd-ports", default="ss -H -ltnup")
    a.add_argument("--cmd-wg", default="wg show all listen-port")
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
        # WireGuard without a ListenPort takes a new random UDP port at every boot: its own ports are not listeners to watch
        wg = {l.split()[-1] for l in lines_of(sh(a.cmd_wg, a) or "") if l.split()[-1].isdigit()}
        s["ports"] = sorted({f"{p[0]} {p[4]}" for p in (l.split() for l in ports.splitlines())
                             if len(p) >= 5 and not (p[0] == "udp" and p[4].rsplit(":", 1)[-1] in wg) and not user_loopback(a, p)})
    return s


def user_loopback(a, p):
    """A port only this node reaches, opened by a person's own program (an editor, a Claude session): a new one each run."""
    if not (p[4].startswith("127.") or p[4].startswith("[::1]:")):
        return False
    m = re.search(r"pid=(\d+)", " ".join(p[5:]))
    try:
        uid = next(int(l.split()[1]) for l in open(P(a, f"/proc/{m.group(1)}/status")) if l.startswith("Uid:")) if m else -1
    except (OSError, StopIteration, ValueError):
        return False
    return uid >= 1000 and uid != 65534


def what(k, key, item):
    """Name, most likely cause, and the root commands to look at it and to remove it."""
    if k == "login_accounts":
        return (f"account {key}", "an account a package or a person created", [f"getent passwd {key}", f"sudo last -w {key} | head"],
                [f"sudo usermod -L -s /usr/sbin/nologin {key}"])
    if k == "groups":
        return (f"{item} in group {key}", "someone given more rights", [f"getent group {key}"], [f"sudo gpasswd -d {item} {key}"] if item else [])
    if k == "sudoers":
        f = "/etc/sudoers" if key == "sudoers" else f"/etc/sudoers.d/{key}"
        return (f"sudoers file {key}", "a rule an installer or a person added", [f"sudo cat {f}"],
                [f"sudo rm {f}"] if key != "sudoers" and not item else [f"sudo visudo -f {f}"])
    if k == "ssh_keys":
        return (f"ssh key of {key}", "a key someone added to log in with", [f"sudo cat ~{key}/.ssh/authorized_keys"], [])
    if k == "crontabs":
        spool = key.startswith("/var/spool/cron/crontabs/")
        u = os.path.basename(key)
        return (f"crontab {key}", "a scheduled job a package or a person added", [f"sudo crontab -u {u} -l" if spool else f"sudo cat {key}"],
                ([f"sudo crontab -u {u} -r"] if spool else [f"sudo rm {key}"]) if not item else [])
    if k == "units":
        ours = key.startswith("geodineum-") or key.startswith("gnode")
        return (f"unit {key}", "one of our installers" if ours else "a package's service, or one made by hand",
                [f"systemctl cat {key}", f"systemctl status {key} --no-pager"], [f"sudo systemctl disable --now {key}"])
    if k == "docker_images":
        return (f"docker image {key.split('@')[0]}", "an image pulled for a container", [f"sudo docker ps -a --filter ancestor={key.split('@')[0]}"],
                [f"sudo docker image rm {key.split('@')[0]}"])
    if k == "ports":
        addr = key.split()[-1]
        local = addr.startswith(("127.", "[::1]", "::1"))
        return (f"listener {key}", "a local service (only this node reaches it)" if local else "a service open to the network",
                [f"sudo ss -ltnup | grep -F ':{addr.rsplit(':', 1)[-1]} '"], [])
    return (f"{k} {key}", "a change on this node", [], [])


def changes(old_state, now):
    """One finding per fact that appeared or changed; what went away is information only."""
    out = []
    for k, label in WATCHED:
        new = now.get(k)
        if new is None:
            continue
        old = old_state.get(k)

        def add(key, item, text, patch, undo):
            name, guess, look, remove = what(k, key, item)
            out.append(W.F(k, f"{key}|{item}", name, text, guess, patch=patch, undo=undo, look=look, remove=remove))

        if isinstance(new, dict):
            for key in sorted(set(old or {}) | set(new)):
                o, n = (old or {}).get(key), new.get(key)
                if o == n:
                    continue
                if o is None:
                    shown = f": {n}" if isinstance(n, str) else (": " + " | ".join(n[:6]) if n else "")
                    add(key, json.dumps(n, sort_keys=True), f"{label}: new {key}{shown}", [["set", [k, key], n]], [["set", [k, key], None]])
                elif n is None:
                    out.append(W.F(k, f"{key}|gone", "", f"{label}: {key} is gone", "", info=True))
                elif isinstance(n, list):
                    for x in sorted(set(n) - set(o)):
                        add(key, x, f"{label} {key}: added {x}", [["add", [k, key], x]], [["drop", [k, key], x]])
                    for x in sorted(set(o) - set(n)):
                        out.append(W.F(k, f"{key}|{x}|gone", "", f"{label} {key}: removed {x}", "", info=True))
                else:
                    add(key, n, f"{label} {key}: {o} -> {n}", [["set", [k, key], n]], [["set", [k, key], o]])
        else:
            for x in sorted(set(new) - set(old or [])):
                add(x, "", f"{label}: added {x}", [["add", [k], x]], [["drop", [k], x]])
            for x in sorted(set(old or []) - set(new)):
                out.append(W.F(k, f"{x}|gone", "", f"{label}: removed {x}", "", info=True))
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
            flags.append(W.F("login", f"{user}|{ip}", f"login of {user} from {ip}", f"login: {user} from {ip}, an address this account never used before ({p[3][:16]})",
                             "you, from a network not seen before (a phone, travel, a new provider)", event=True,
                             look=[f"sudo last -w -i | grep -F {ip}", f"sudo journalctl -q _COMM=sshd --since -3d | grep -F {ip}"]))
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
    return flags, lines, logins, {u: len(c) for u, c in sudo.items()}


def daily_mode(a):
    if a.daily != "auto":
        return a.daily
    return "report" if os.path.exists(os.path.join(os.path.dirname(a.status), "daily-report.status")) else "send"


def publish(a, host, state, info, extra=None):
    """The digest file the daily report reads: the day's logins and sudo (from a run), the open findings (always)."""
    path = os.path.join(a.state, "digest.json")
    d = W.load(path) if extra is None else dict(extra, host=host, at=int(time.time()), hours=a.hours)
    d.update(findings=[r["text"] for r in W.live(state)], items=W.items(state))
    if info is not None:
        d["info"] = info
    W.save(path, d, 0o600)


def status(a, error):
    if not os.path.isdir(os.path.dirname(a.status)):
        return
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


def main():
    a = args_()
    host = socket.gethostname().split(".")[0]
    script = os.path.realpath(__file__)
    os.makedirs(a.state, mode=0o750, exist_ok=True)
    sf = os.path.join(a.state, "state.json")
    with W.Locked(a.state):
        if a.reject or (a.accept and a.accept != "all"):
            return W.decide(a, host, "Account watch", "account-watch", script, sf, 0o600, lambda st: publish(a, host, st, None))
        state = W.load(sf)
        first = not state
        migrate = not first and state.get("v") != 2
        try:
            now = collect(a)
            unchecked = set()
            for k in ("docker_images", "ports"):
                if now.get(k) is None:
                    unchecked.add(k)
                    if state.get(k) is not None:
                        now[k] = state[k]
            if not first and not state.get("wg_excluded") and "ports" not in unchecked:
                # a baseline from before WireGuard's own ports were left out still lists them: its UDP ports that are gone now
                # are dropped once, so the change of rule is not reported as listeners removed
                state["ports"] = [p for p in (state.get("ports") or []) if not p.startswith("udp ") or p in now["ports"]]
            now["wg_excluded"] = True
            found = [] if first else changes(state, now)
            known = state.get("login_ips", {})
            lflags, lines, logins, sudo = digest(a, known)
            if not first:
                found += lflags
            for u, ips in logins.items():
                known.setdefault(u, [])
                known[u] = sorted(set(known[u]) | set(ips))
            now["login_ips"] = known
        except Exception as e:
            print(f"== on {host}: the watch itself failed: {e}")
            try:
                W.failure(a, "Account watch", "account-watch", host, f"the account watch itself failed: {e}")
            except Exception as e2:
                print(f"  ..   alert not sent: {e2}")
            status(a, str(e))
            return 1
        ts = int(time.time())
        info = W.settle(state, found, ts, migrate, unchecked)
        if a.accept == "all":
            W.accept_all(state, ts, a.by or "root")
        new = dict(now, findings=state["findings"], v=2)
        W.apply(new, W.undo_ops(state, ts))
        open_ = W.live(state)
        print(f"== on {host}: {len(open_)} finding(s){' (first run: baseline recorded)' if first else ''}"
              f"{' (first run of decide-once: open findings count as sent)' if migrate else ''}")
        for r in open_:
            print(f"  FLAG {r['text']}" + ("" if r["status"] == "new" else f"  [{r['status']} {r['id']}]"))
        for t in info:
            print(f"  INFO {t}")
        for l in lines:
            print(f"  ..   {l}")
        if a.accept == "all":
            print("  ..   accepted every open finding as the expected state")
        error = ""
        report = daily_mode(a) == "report"
        try:
            if not a.no_alert and a.alert_site:
                tail = [] if report else ["", "Last day:"] + (lines or ["no logins, no sudo"])
                vk = None
                if any(r["status"] == "new" for r in open_):
                    vk = W.connect(a.bootstrap, a.valkey_cred)
                    print(f"  ..   alert to {a.alert_site}: {W.announce(vk, a, 'Account watch', 'account-watch', host, script, new, ts, tail)}")
                elif a.digest_always and not report:
                    vk = W.connect(a.bootstrap, a.valkey_cred)
                    e = W.send(vk, a.alert_site, a.env, "account watch", "account-watch", f"Account watch on {host}: nothing new", "\n".join(tail[1:]), 4)
                    print(f"  ..   digest to {a.alert_site}: {e}")
        except Exception as e:
            print(f"  ..   alert not sent: {e}")
            error = f"alert not sent: {e}"
        W.save(sf, new, 0o600)
        W.recovered(a.state)
        try:
            # the digest stays on the node, sent or not
            publish(a, host, new, info, {"lines": lines, "logins": logins, "sudo": sudo})
        except OSError as e:
            print(f"  ..   digest not kept: {e}")
    status(a, error)
    return 1 if W.live(new) else 0


if __name__ == "__main__":
    sys.exit(main())

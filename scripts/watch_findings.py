"""What the estate and account watches share: a finding is decided once.

A finding has a stable id (a hash of its kind and subject, not of its wording) and a record in the watch's root-owned
state: new, alerted (sent once, with two buttons), accepted, rejected, or gone (no longer on the node). An accepted fact
moves into the baseline (its patch); while it waits, each run keeps it out of the baseline (its undo), so it is still
found and never sent again. A button carries only the record's random nonce, single-use, never the id.
"""
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import time

LIVE = ("new", "alerted", "rejected")
NONCE = re.compile(r"^[0-9a-f]{32}$")
CALLBACK = re.compile(r"^wd:([ar]):([0-9a-f]{32})$")


def fid(kind, subject):
    return hashlib.sha256(f"{kind}\n{subject}".encode()).hexdigest()[:10]


def F(kind, subject, name, text, guess, patch=(), undo=(), info=False, acceptable=True, event=False, scope="", look=(), remove=()):
    return {"id": fid(kind, subject), "kind": kind, "name": name, "text": text, "guess": guess, "info": info,
            "patch": [list(p) for p in patch], "undo": [list(u) for u in undo], "acceptable": acceptable, "event": event,
            "scope": scope, "look": list(look), "remove": list(remove)}


def apply(state, ops):
    """Ops on the state's JSON: ["set", path, value] (None deletes), ["add" | "drop", path, item] on a sorted list."""
    for op, path, val in ops:
        d = state
        for k in path[:-1]:
            if not isinstance(d.get(k), dict):
                d[k] = {}
            d = d[k]
        k = path[-1]
        if op == "set":
            if val is None:
                d.pop(k, None)
            else:
                d[k] = val
        else:
            items = d.get(k) if isinstance(d.get(k), list) else []
            d[k] = sorted(set(items) | {val}) if op == "add" else [x for x in items if x != val]
    return state


class Locked:
    def __init__(self, state_dir):
        self.path = os.path.join(state_dir, ".lock")

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o640)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


def save(path, data, mode):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as o:
        json.dump(data, o, indent=1, sort_keys=True)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def settle(state, found, now, migrate=False, unchecked=()):
    """Records this run's findings. Info goes nowhere but the run's list. A finding seen before keeps its record and
    is not sent again; a record not found this run is gone, unless its kind or scope could not be checked."""
    recs = state.setdefault("findings", {})
    info, here = [], set()
    for f in found:
        if f["info"]:
            info.append(f["text"])
            continue
        if f["id"] in here:
            continue
        here.add(f["id"])
        r = recs.get(f["id"])
        if r and r["status"] == "accepted" and f["acceptable"]:
            continue
        keep = {k: v for k, v in f.items() if k not in ("id", "info")}
        if r and r["status"] in LIVE:
            r.update(keep, seen=now)
        else:
            r = recs[f["id"]] = dict(keep, status="new", first=now, seen=now, nonce=secrets.token_hex(16))
            if migrate:
                r.update(status="alerted", alerted=now, batch="bridge")
    for i, r in recs.items():
        if r["status"] in LIVE and i not in here and not r.get("event") and r.get("kind") not in unchecked and r.get("scope") not in unchecked:
            r.update(status="gone", gone=now, nonce=None)
    for i in [i for i, r in recs.items() if r["status"] == "gone" and now - r.get("gone", now) > 30 * 86400]:
        del recs[i]
    if migrate:
        for n, r in enumerate(sorted((r for r in recs.values() if r.get("batch") == "bridge"), key=lambda r: r["text"]), 1):
            r["n"] = n
    state["v"] = 2
    return info


def accept_all(state, now, by):
    for r in state.get("findings", {}).values():
        if r["status"] in LIVE and r.get("acceptable", True):
            r.update(status="accepted", decided=now, by=by, nonce=None)


def undo_ops(state, now):
    return [op for r in state.get("findings", {}).values() if r["status"] in LIVE and r.get("seen") == now for op in r.get("undo", [])]


def live(state):
    return sorted((dict(r, id=i) for i, r in state.get("findings", {}).items() if r["status"] in LIVE), key=lambda r: (r.get("first", 0), r["text"]))


def items(state):
    """What a daily report may read: no nonce, no patch."""
    return [{k: r.get(k) for k in ("id", "name", "text", "guess", "status", "first", "alerted", "decided")} for r in live(state)]


def env_file(path):
    try:
        return dict(l.strip().split("=", 1) for l in open(path) if "=" in l and not l.lstrip().startswith("#"))
    except OSError:
        return {}


class VKError(Exception):
    pass


class VK:
    """RESP2 over one socket: the password goes in AUTH, never on a command line or into an environment."""

    def __init__(self, host, port, user, password):
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        self.f = self.sock.makefile("rb")
        if password:
            try:
                self.call("AUTH", user, password)
            except VKError as e:
                raise VKError(f"login as {user} refused ({str(e).split()[0]})") from None

    def call(self, *args):
        out = [b"*%d\r\n" % len(args)]
        for x in args:
            b = x if isinstance(x, bytes) else str(x).encode()
            out.append(b"$%d\r\n%s\r\n" % (len(b), b))
        self.sock.sendall(b"".join(out))
        return self._read()

    def _read(self):
        line = self.f.readline()
        if not line:
            raise VKError("ValKey closed the connection")
        t, rest = line[:1], line[1:-2]
        if t == b"+":
            return rest.decode()
        if t == b"-":
            raise VKError(rest.decode(errors="replace"))
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            return None if n < 0 else self.f.read(n + 2)[:-2].decode("utf-8", "replace")
        if t == b"*":
            n = int(rest)
            return None if n < 0 else [self._read() for _ in range(n)]
        raise VKError(f"unexpected reply {line[:20]!r}")


def connect(bootstrap, cred):
    env = env_file(bootstrap)
    password = open(cred).read().strip()
    return VK(env.get("VALKEY_HOST", "127.0.0.1"), env.get("VALKEY_PORT", "47445"), "gnode_daemon", password)


def send(vk, site, env, sender, source, subject, body, priority, channels=("email", "telegram"), markup=None):
    dispatch = {"channels": list(channels)}
    if markup:
        dispatch["reply_markup"] = markup
    return vk.call("XADD", f"{{{site}}}:gnode:comms:{env}", "*", "site_id", site, "environment", env, "type", "alert",
                   "priority", str(priority), "timestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "sender", json.dumps({"name": sender}), "subject", subject, "body", body[:3500],
                   "metadata", json.dumps({"source": source, "form_type": "alert", "compact": True}),
                   "dispatch", json.dumps(dispatch))


def numbered(batch_recs):
    """A message's findings in the order they were sent: (number, record), the number as printed in the message."""
    return list(enumerate(sorted(batch_recs, key=lambda r: (r.get("order", 0), r.get("n", 0))), 1))


def keyboard(rows):
    many = len(rows) > 1
    kb = []
    for n, r in rows:
        if r["status"] not in ("new", "alerted") or not r.get("nonce"):
            continue
        tag = f" ({n})" if many else ""
        row = [{"text": "✓ Expected" + tag, "callback_data": f"wd:a:{r['nonce']}"}] if r.get("acceptable", True) else []
        kb.append(row + [{"text": "✗ Not mine" + tag, "callback_data": f"wd:r:{r['nonce']}"}])
    return {"inline_keyboard": kb}


def lines(rows, where=lambda r: ""):
    return "\n".join(f"{n}. {where(r)}{r['text']}\n   Most likely: {r['guess']}. [{r['id']}]" for n, r in rows)


def announce(vk, a, label, source, host, script, state, now, tail=()):
    """One message for this run's new findings, each with its two buttons. Marks them alerted once COMMS has it."""
    new = sorted((dict(r, id=i) for i, r in state.get("findings", {}).items() if r["status"] == "new"), key=lambda r: r["text"])
    if not new:
        return None
    for n, r in enumerate(new, 1):
        r["n"] = n
    rows = numbered(new)
    subject = f"{label} on {host}: {len(new)} new finding{'s' if len(new) != 1 else ''}"
    body = (lines(rows) + f"\n\nAnswer with the buttons. As root instead: sudo python3 -I {script} --accept <id> (or --reject <id>)"
            + "".join(f"\n{t}" for t in tail))
    entry = send(vk, a.alert_site, a.env, label.lower(), source, subject, body, 2, markup=keyboard(rows))
    batch = f"{source}-{now}-{secrets.token_hex(4)}"
    for r in new:
        state["findings"][r["id"]].update(status="alerted", alerted=now, batch=batch, n=r["n"])
    return entry


def decide(a, host, label, source, script, sf, mode, publish):
    """--accept <id> or --reject <id>, under the watch's lock. With --nonce (the decision reader) the nonce must match."""
    state = load(sf)
    i = a.reject or a.accept
    r = state.get("findings", {}).get(i)
    if not r or r["status"] not in LIVE:
        print(f"  ..   {i}: no open finding with this id")
        return 3
    if a.nonce is not None and not (r.get("nonce") and hmac.compare_digest(r["nonce"], a.nonce)):
        print(f"  ..   {i}: the button is not this finding's, or was used already")
        return 3
    now = int(time.time())
    if a.accept:
        if not r.get("acceptable", True):
            print(f"  ..   {i}: {r['name']} cannot be accepted; it goes when it is gone from {host}")
            return 3
        apply(state, r.get("patch", []))
        r.update(status="accepted", decided=now, by=a.by or "root", nonce=None)
        save(sf, state, mode)
        publish(state)
        print(f"  ..   accepted {i}: {r['name']}")
        return 0
    if r["status"] == "rejected":
        print(f"  ..   {i}: {r['name']} is already marked not ours")
        return 0
    r.update(status="rejected", decided=now, by=a.by or "root", nonce=None)
    save(sf, state, mode)
    publish(state)
    print(f"  ..   rejected {i}: {r['name']}")
    if a.no_alert or not a.alert_site:
        return 0
    look = "".join(f"\non {host}: {c}" for c in r.get("look", []))
    rm = "".join(f"\non {host}: {c}" for c in r.get("remove", []))
    body = (f"{r['text']}.\n\nLook at it:{look or ' (nothing to run; read the line above)'}"
            + (f"\n\nRemove it, once you are sure:{rm}" if rm else "")
            + f"\n\nIt stays at the top of every daily report until it is gone from {host} or accepted:"
            + f"\non {host}: sudo python3 -I {script} --accept {i}")
    try:
        entry = send(connect(a.bootstrap, a.valkey_cred), a.alert_site, a.env, label.lower(), source,
                     f"Not yours: {r['name']} on {host}", body, 1)
        print(f"  ..   urgent alert to {a.alert_site}: {entry}")
    except (OSError, VKError) as e:
        print(f"  ..   urgent alert not sent: {e}")
        return 2
    return 0


def failure(a, label, source, host, error):
    """The watch itself failed: one alert per distinct error, not one per run."""
    fpf = os.path.join(a.state, "failed.fp")
    fp = hashlib.sha256(error.encode()).hexdigest()[:16]
    try:
        prev = open(fpf).read().strip()
    except OSError:
        prev = ""
    if prev == fp or a.no_alert or not a.alert_site:
        return
    send(connect(a.bootstrap, a.valkey_cred), a.alert_site, a.env, label.lower(), source, f"{label} on {host} failed", error, 2,
         channels=("email", "telegram"))
    fd = os.open(fpf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w") as o:
        o.write(fp)


def recovered(state_dir):
    try:
        os.remove(os.path.join(state_dir, "failed.fp"))
    except OSError:
        pass

#!/usr/bin/python3 -I
"""The answers to the watches' buttons. Every 2 minutes as root, from geodineum-watch-decisions.timer
(install-watch-decisions.sh). By hand: python3 -I watch-decisions.py

Reads button presses from the bot's inbound stream with this node's own consumer group, so every node sees every
press and only the node whose watch holds the nonce acts. A press counts only from an id in the admin allowlist
(refuses to run without one) and only with a nonce a watch holds for an open finding; the watch checks it again under
its lock and clears it, so a nonce works once. Expected: the watch's --accept <id>, a one-line reply, that finding's
buttons removed. Not mine: the watch's --reject <id>, which sends the urgent alert itself.
Once, after both watches have taken the findings that were open before, sends them as one message with buttons.
"""
import argparse
import hmac
import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

COMMS_ENV = "/etc/geodineum/components/geodineum-comms/geodineum-comms.env"
LIB = "/usr/local/lib/geodineum"


def _lib():
    sys.dont_write_bytecode = True
    s = importlib.util.spec_from_file_location("watch_findings", os.path.join(os.path.dirname(os.path.realpath(__file__)), "watch_findings.py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


W = _lib()


def args_():
    a = argparse.ArgumentParser()
    a.add_argument("--watch", action="append", metavar="NAME=SCRIPT:STATE_DIR",
                   help=f"default: estate={LIB}/estate-watch.py:/var/lib/geodineum/estate-watch and the same for account")
    a.add_argument("--admins", default=os.environ.get("WATCH_DECISIONS_ADMINS", ""), help="Telegram ids, comma-separated (default: COMMS_ADMIN_IDS)")
    a.add_argument("--comms-env", default=COMMS_ENV)
    a.add_argument("--site", default=os.environ.get("WATCH_DECISIONS_SITE") or "geodineum", help="the operators' site: replies and the one-time message")
    a.add_argument("--env", default="production")
    a.add_argument("--group", default="")
    a.add_argument("--state", default="/var/lib/geodineum/watch-decisions")
    a.add_argument("--status", default="/var/lib/geodineum-watch/watch-decisions.status")
    a.add_argument("--bootstrap", default="/etc/geodineum/bootstrap.env")
    a.add_argument("--valkey-cred", default="/etc/geodineum/credentials/valkey_daemon.password")
    a.add_argument("--telegram-api", default="https://api.telegram.org")
    a.add_argument("--no-bridge", action="store_true")
    return a.parse_args()


def watches(a):
    out = []
    for spec in a.watch or [f"estate={LIB}/estate-watch.py:/var/lib/geodineum/estate-watch",
                            f"account={LIB}/account-watch.py:/var/lib/geodineum/account-watch"]:
        name, _, rest = spec.partition("=")
        script, _, state = rest.rpartition(":")
        out.append({"name": name, "label": f"{name} watch", "script": script, "state": state})
    return out


def states(ws):
    return [(i, w, W.load(os.path.join(w["state"], "state.json"))) for i, w in enumerate(ws)]


def find(ws, nonce):
    for i, w, st in states(ws):
        for fid, r in st.get("findings", {}).items():
            if r.get("nonce") and r["status"] == "alerted" and hmac.compare_digest(r["nonce"], nonce):
                return w, dict(r, id=fid)
    return None, None


def batch_rows(ws, batch):
    recs = []
    for i, w, st in states(ws):
        recs += [dict(r, id=fid, order=i, watch=w["label"]) for fid, r in st.get("findings", {}).items() if r.get("batch") == batch]
    return W.numbered(recs)


def telegram(a, token, method, payload):
    if not token:
        return False
    req = urllib.request.Request(f"{a.telegram_api}/bot{token}/{method}", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status == 200
    except Exception as e:  # buttons left in place are harmless: a used nonce changes nothing
        print(f"  ..   Telegram {method} failed: {type(e).__name__}")
        return False


def bridge(a, vk, ws, host):
    """The findings that were open before this flow: one message, once, after every watch here has taken them."""
    sf = os.path.join(a.state, "state.json")
    st = W.load(sf)
    if st.get("bridge"):
        return
    present = [(i, w, s) for i, w, s in states(ws) if s]
    if any(s.get("v") != 2 for _, _, s in present):
        return
    rows = batch_rows(ws, "bridge")
    open_ = [(n, r) for n, r in rows if r["status"] == "alerted" and r.get("nonce")]
    if open_:
        n = len(open_)
        body = (W.lines(open_, lambda r: f"[{r['watch']}] ")
                + "\n\nThey were found before the buttons existed and will not be sent again. Expected moves one into what is "
                  "expected; Not mine sends what to look at.")
        entry = W.send(vk, a.site, a.env, "watch decisions", "watch-decisions", f"These {n} are waiting for your answer ({host})", body, 2,
                       markup=W.keyboard(rows))
        print(f"  ..   the {n} open findings sent once with buttons: {entry}")
    W.save(sf, dict(st, bridge=int(time.time())), 0o640)


def handle(a, vk, ws, admins, token, f):
    if f.get("is_callback") != "true":
        return
    m = W.CALLBACK.match(f.get("text", ""))
    if not m:
        return
    action, nonce = m.groups()
    op = f.get("operator_id", "")
    if op not in admins:
        print(f"  REFUSED a press from {op or 'no id'}: not in the admin allowlist")
        return
    w, r = find(ws, nonce)
    if not r:
        print("  ..   a press with a nonce no open finding here holds (used, or another node's)")
        return
    flag = "--accept" if action == "a" else "--reject"
    p = subprocess.run([sys.executable, "-I", w["script"], "--state", w["state"], flag, r["id"], "--nonce", nonce, "--by", f"telegram:{op}",
                        "--bootstrap", a.bootstrap, "--valkey-cred", a.valkey_cred], capture_output=True, text=True, timeout=3600)
    print(f"  {'ACCEPTED' if action == 'a' else 'REJECTED'} {w['label']} {r['id']} ({r['name']}) by {op}: rc {p.returncode}")
    for l in (p.stdout + p.stderr).strip().splitlines()[-3:]:
        print(f"       {l}")
    if p.returncode:
        return
    if action == "a":
        W.send(vk, a.site, a.env, "watch decisions", "watch-decisions", f"Accepted: {r['name']}. It will not be mentioned again.", "", 4,
               channels=("telegram",))
    chat, mid = f.get("chat_id", ""), f.get("callback_message_id", "")
    if chat and mid.isdigit():
        telegram(a, token, "editMessageReplyMarkup", {"chat_id": chat, "message_id": int(mid),
                                                      "reply_markup": W.keyboard(batch_rows(ws, r.get("batch")))})


def status(a, error):
    if not os.path.isdir(os.path.dirname(a.status)):
        return
    ms = int(time.time() * 1000)
    try:
        prev = dict(l.strip().split("=", 1) for l in open(a.status) if "=" in l)
    except OSError:
        prev = {}
    with open(a.status + ".tmp", "w") as o:
        o.write(f"what=watch decisions\nmax_age_h=1\nok_ms={ms if not error else prev.get('ok_ms', 0)}\nrun_ms={ms}\nerror={error}\n")
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
    ce = W.env_file(a.comms_env)
    admins = {x.strip() for x in (a.admins or ce.get("COMMS_ADMIN_IDS", "").strip("'\"")).split(",") if x.strip().isdigit()}
    if not admins:
        print(f"== on {host}: no admin allowlist (--admins, WATCH_DECISIONS_ADMINS, or COMMS_ADMIN_IDS in {a.comms_env}): refusing to apply any press")
        status(a, "no admin allowlist")
        return 2
    token = ce.get("TELEGRAM_BOT_TOKEN", "").strip("'\"")
    inbound = ce.get("COMMS_INBOUND_SITE", "").strip("'\"") or "geodineum"
    stream, group = f"{{{inbound}}}:gnode:comms:inbound:{a.env}", a.group or f"watch-decisions-{host}"
    os.makedirs(a.state, mode=0o750, exist_ok=True)
    ws = watches(a)
    error = ""
    try:
        vk = W.connect(a.bootstrap, a.valkey_cred)
        try:
            vk.call("XGROUP", "CREATE", stream, group, "0", "MKSTREAM")
        except W.VKError as e:
            if "BUSYGROUP" not in str(e):
                raise
        if not a.no_bridge:
            bridge(a, vk, ws, host)
        while True:
            r = vk.call("XREADGROUP", "GROUP", group, host, "COUNT", 100, "STREAMS", stream, ">")
            entries = r[0][1] if r else []
            for eid, flat in entries:
                try:
                    handle(a, vk, ws, admins, token, dict(zip(flat[0::2], flat[1::2])))
                except (OSError, subprocess.SubprocessError, W.VKError) as e:
                    print(f"  ..   press {eid} not applied: {e}")
                    error = error or f"press not applied: {e}"
                vk.call("XACK", stream, group, eid)
            if len(entries) < 100:
                break
    except (OSError, W.VKError) as e:
        print(f"== on {host}: watch decisions not read: {e}")
        error = str(e)
    status(a, error)
    return 1 if error else 0


if __name__ == "__main__":
    sys.exit(main())

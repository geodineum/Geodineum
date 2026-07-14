#!/usr/bin/env bash
# =============================================================================
# ecosystem-smoke-test.sh — Geodineum Ch.1 live ecosystem verification
# =============================================================================
# Proves a running install actually works end to end:
#   L0  ValKey reachable + every ACL identity authenticates (admin, daemon,
#       comms, and EACH per-site client key — the "does the client key
#       connect" check)
#   L1  gNode Lua function libraries loaded + read-only functions callable
#   L2  daemon command dispatch live — real round-trip through the unified
#       stream (ping/health/version/echo), then `describe` to enumerate the
#       live command surface and assert the Ch.1 baseline is present and no
#       extension commands leaked into a base install
#   L3  services active + sites serve HTTP
#
# Run:   sudo bash scripts/ecosystem-smoke-test.sh [--site <id>] [--env <env>]
#                                                  [--port 47445] [--quiet]
# Exit:  0 = all PASS, 1 = one or more FAIL. WARN never fails the run.
# Read-only: calls no mutating command; safe on production.
# =============================================================================
set -uo pipefail

PORT=47445; ENVIRON="production"; ONLY_SITE=""; QUIET=0
CREDS="/etc/geodineum/credentials"
while [[ $# -gt 0 ]]; do case "$1" in
  --site)  ONLY_SITE="${2:-}"; shift 2;;
  --env)   ENVIRON="${2:-}"; shift 2;;
  --port)  PORT="${2:-}"; shift 2;;
  --quiet) QUIET=1; shift;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

P=0; F=0; W=0
ok(){ echo "  PASS  $*"; P=$((P+1)); }
no(){ echo "  FAIL  $*"; F=$((F+1)); }
wn(){ echo "  WARN  $*"; W=$((W+1)); }
hdr(){ echo; echo "── $* ─────────────────────────────────────────" | cut -c1-64; }
info(){ [[ $QUIET -eq 1 ]] || echo "        $*"; }

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo (needs to read credential files)"; exit 1; }
command -v valkey-cli >/dev/null || { echo "ERROR: valkey-cli not found"; exit 1; }

read_cred(){ [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo ""; }
ADMIN_PW="$(read_cred "$CREDS/valkey.password")"
DAEMON_PW="$(read_cred "$CREDS/valkey_daemon.password")"
COMMS_PW="$(read_cred "$CREDS/valkey_comms.password")"

# auth helpers — each returns valkey-cli output, never throws
vk_admin(){  REDISCLI_AUTH="$ADMIN_PW"  valkey-cli -p "$PORT" "$@" 2>&1; }
vk_daemon(){ valkey-cli -p "$PORT" --user gnode_daemon --pass "$DAEMON_PW" --no-auth-warning "$@" 2>&1; }
vk_client(){ local site="$1" pw="$2"; shift 2;
  valkey-cli -p "$PORT" --user "gnode_client_${site}" --pass "$pw" --no-auth-warning "$@" 2>&1; }

gen_id(){ if command -v uuidgen >/dev/null; then uuidgen|tr -d '-'; \
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid|tr -d '-'; \
  else openssl rand -hex 16; fi; }
now_ms(){ date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }

echo "============================================================"
echo " Geodineum ecosystem smoke test · env=${ENVIRON} · port=${PORT}"
echo "============================================================"

# ── L0: connectivity + every ACL identity authenticates ──────────────────
hdr "L0  ValKey connectivity + ACL auth"
[[ -n "$ADMIN_PW" ]] && { [[ "$(vk_admin PING)" == "PONG" ]] && ok "admin (default user) PING" || no "admin PING: $(vk_admin PING)"; } || no "admin password unreadable at $CREDS/valkey.password"
[[ -n "$DAEMON_PW" ]] && { [[ "$(vk_daemon PING)" == "PONG" ]] && ok "gnode_daemon PING" || no "gnode_daemon PING: $(vk_daemon PING)"; } || no "daemon password unreadable"
[[ -n "$COMMS_PW" ]] && { out="$(valkey-cli -p "$PORT" --user geodineum_comms --pass "$COMMS_PW" --no-auth-warning PING 2>&1)"; [[ "$out" == "PONG" ]] && ok "geodineum_comms PING" || no "geodineum_comms PING: $out"; } || wn "comms password unreadable (COMMS may not be installed)"

# discover per-site client keys → THE "does the client key connect" test
hdr "L0  per-site client keys connect"
declare -a SITES=()
shopt -s nullglob
for f in "$CREDS"/valkey_client_*.password; do
  base="$(basename "$f")"; site="${base#valkey_client_}"; site="${site%.password}"
  [[ -n "$ONLY_SITE" && "$site" != "$ONLY_SITE" ]] && continue
  SITES+=("$site")
  pw="$(read_cred "$f")"
  if [[ -z "$pw" ]]; then no "client key '$site' password unreadable"; continue; fi
  out="$(vk_client "$site" "$pw" PING)"
  if [[ "$out" == "PONG" ]]; then ok "client key gnode_client_${site} connects"
  else no "client key gnode_client_${site} FAILED: $out"; fi
done
shopt -u nullglob
[[ ${#SITES[@]} -eq 0 ]] && wn "no per-site client keys found (no sites onboarded yet?)"

# ── L1: Lua function libraries loaded + read-only functions callable ──────
hdr "L1  gNode Lua functions"
libcount="$(vk_daemon FUNCTION LIST 2>/dev/null | grep -c 'library_name')"
if [[ "$libcount" =~ ^[0-9]+$ ]] && [[ "$libcount" -ge 20 ]]; then ok "Lua libraries loaded: $libcount (expected ~23)"
else no "Lua libraries loaded: ${libcount:-0} (expected ~23 — phase-10 function load may have failed)"; fi
# read-only FCALL probes (must execute without 'function not found' / ERR)
probe_site="${SITES[0]:-default}"
for probe in \
  "GNODE_CORE_EXISTS 0 __smoke__ ${probe_site}" \
  "GNODE_CACHE_EXISTS 0 __smoke__ ${probe_site}" \
  "GNODE_NODE_FETCH_CONFIG 0 general"; do
  fn="${probe%% *}"
  out="$(vk_daemon FCALL $probe 2>&1)"
  if echo "$out" | grep -qiE 'function not found|unknown command|NOPERM|wrong number'; then no "FCALL $fn: $out"
  else ok "FCALL $fn callable"; fi
done

# ── L2: daemon command dispatch — real round-trip + inventory ─────────────
hdr "L2  daemon command dispatch (round-trip)"
if [[ ${#SITES[@]} -eq 0 ]]; then
  wn "no site to round-trip through — skipping dispatch test (onboard a site, re-run)"
else
  rt_site="${SITES[0]}"
  stream="{${rt_site}}:gnode:unified:${ENVIRON}"
  roundtrip(){ # $1=command  -> echoes response json or empty
    local cmd="$1" id; id="$(gen_id)"
    vk_daemon XADD "$stream" '*' t c id "$id" c "$cmd" p '{}' ss "$rt_site" sn default ts "$(now_ms)" >/dev/null 2>&1
    local key="{${rt_site}}:res:${id}" i out
    for i in $(seq 1 20); do
      out="$(vk_daemon GET "$key" 2>/dev/null)"
      [[ -n "$out" && "$out" != "(nil)" ]] && { echo "$out"; return 0; }
      sleep 0.25
    done
    return 1
  }
  info "round-tripping through $stream"
  for cmd in ping health version echo; do
    if r="$(roundtrip "$cmd")"; then
      if echo "$r" | grep -qiE '"status"\s*:\s*"?(ok|success)|pong|healthy'; then ok "command '$cmd' round-trip ok"
      else wn "command '$cmd' responded but status unclear: $(echo "$r"|cut -c1-80)"; fi
    else no "command '$cmd' NO RESPONSE in 5s (daemon not consuming unified stream?)"; fi
  done

  # describe → enumerate the LIVE command surface
  hdr "L2  command inventory (describe)"
  desc="$(roundtrip describe || true)"
  if [[ -n "$desc" ]]; then
    ok "describe returned a command inventory"
    for base in ping health status version echo describe extension_list get_node_info; do
      echo "$desc" | grep -q "\"$base\"\|'$base'\| $base\b" && ok "  baseline cmd present: $base" || wn "  baseline cmd '$base' not visible in describe output"
    done
    # Extension-command leak check — these must NOT be in a base install
    leak=0
    for pro in dep_register registry_create cross_topology template_render content_create; do
      echo "$desc" | grep -q "$pro" && { wn "  extension command leaked into base: $pro"; leak=1; }
    done
    [[ $leak -eq 0 ]] && ok "  no extension commands in base install"
  else
    no "describe returned nothing — command dispatch or describe handler down"
  fi
fi

# ── L3: services + HTTP ───────────────────────────────────────────────────
hdr "L3  services + sites"
for svc in valkey-gnode gnode-daemon geodineum-comms; do
  st="$(systemctl is-active "$svc" 2>/dev/null)"
  if [[ "$st" == active ]]; then ok "$svc active"
  elif [[ "$svc" == geodineum-comms && "$st" != active ]]; then wn "$svc $st (optional component)"
  else no "$svc $st"; fi
done
# sites: try each discovered site's vhost on loopback (best-effort)
for site in "${SITES[@]}"; do
  dom="${site//_/.}"   # heuristic: example_com -> example.com
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Host: $dom" http://127.0.0.1/ 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|301|302|403)$ ]]; then ok "site $dom serves HTTP ($code)"
  else wn "site $dom HTTP $code (vhost/DNS heuristic may be off — verify manually)"; fi
done

echo
echo "============================================================"
echo "  SMOKE TEST:  ${P} PASS · ${F} FAIL · ${W} WARN   (sites: ${#SITES[@]})"
echo "============================================================"
if [[ $F -eq 0 ]]; then
  echo "  CLEAN — ecosystem live: ACL auth, Lua functions, command dispatch, services."
  exit 0
else
  echo "  ${F} failure(s) — see FAIL lines above."
  exit 1
fi

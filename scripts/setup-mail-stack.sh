#!/usr/bin/env bash
# Mail-stack provisioning: postfix relay + per-domain DKIM signing, with the
# DNS records printed at the end. Grew out of doing this by hand for
# palaciodeobras.com; a site that can queue COMMS mail deserves a sender
# domain that authenticates.
#
#   sudo setup-mail-stack.sh <domain> [--selector geo]
#
# Idempotent: safe to run per domain; re-running an existing domain reprints
# its records. Companion CLI verb: `geodineum mail records <domain>`.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "This needs root: sudo $0 $*" >&2; exit 1; }
DOMAIN="${1:-}"; shift || true
[[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || { echo "usage: sudo $0 <domain> [--selector geo]" >&2; exit 1; }
SELECTOR=geo
while [[ $# -gt 0 ]]; do case "$1" in
    --selector) SELECTOR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
esac; done

KEYDIR=/etc/opendkim/keys/$DOMAIN

echo "== packages =="
for p in postfix opendkim opendkim-tools; do
    dpkg -s "$p" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y "$p"
done

echo "== opendkim base config =="
# Socket + trust anchors once; refile tables so per-domain lines append.
touch /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts
grep -q '^127.0.0.1$' /etc/opendkim/TrustedHosts || printf '127.0.0.1\nlocalhost\n' >> /etc/opendkim/TrustedHosts
ensure_conf() { # key value — idempotent opendkim.conf line
    if grep -qE "^$1\b" /etc/opendkim.conf; then
        sed -i -E "s|^$1\b.*|$1\t$2|" /etc/opendkim.conf
    else
        printf '%s\t%s\n' "$1" "$2" >> /etc/opendkim.conf
    fi
}
ensure_conf KeyTable        refile:/etc/opendkim/KeyTable
ensure_conf SigningTable    refile:/etc/opendkim/SigningTable
ensure_conf InternalHosts   refile:/etc/opendkim/TrustedHosts
ensure_conf Socket          inet:8891@localhost
ensure_conf Mode            sv
ensure_conf Canonicalization relaxed/simple

echo "== DKIM key for $DOMAIN (selector: $SELECTOR) =="
if [[ ! -f $KEYDIR/$SELECTOR.private ]]; then
    install -d -m 0750 -o opendkim -g opendkim "$KEYDIR"
    opendkim-genkey -b 2048 -d "$DOMAIN" -s "$SELECTOR" -D "$KEYDIR"
    chown opendkim:opendkim "$KEYDIR/$SELECTOR".{private,txt}
    chmod 0600 "$KEYDIR/$SELECTOR.private"
    chmod 0640 "$KEYDIR/$SELECTOR.txt"
else
    echo "key exists, keeping it (records reprinted below)"
fi
grep -q "^$SELECTOR._domainkey.$DOMAIN" /etc/opendkim/KeyTable \
    || echo "$SELECTOR._domainkey.$DOMAIN $DOMAIN:$SELECTOR:$KEYDIR/$SELECTOR.private" >> /etc/opendkim/KeyTable
grep -q "^\*@$DOMAIN" /etc/opendkim/SigningTable \
    || echo "*@$DOMAIN $SELECTOR._domainkey.$DOMAIN" >> /etc/opendkim/SigningTable

echo "== postfix milter wiring =="
postconf -e 'milter_default_action = accept'
postconf -e 'milter_protocol = 6'
cur_s=$(postconf -h smtpd_milters 2>/dev/null || true)
cur_n=$(postconf -h non_smtpd_milters 2>/dev/null || true)
[[ "$cur_s" == *8891* ]] || postconf -e "smtpd_milters = ${cur_s:+$cur_s, }inet:localhost:8891"
[[ "$cur_n" == *8891* ]] || postconf -e "non_smtpd_milters = ${cur_n:+$cur_n, }inet:localhost:8891"

systemctl enable --now opendkim >/dev/null
systemctl restart opendkim
systemctl reload postfix

echo "== verify =="
systemctl is-active opendkim postfix
opendkim-testkey -d "$DOMAIN" -s "$SELECTOR" -k "$KEYDIR/$SELECTOR.private" 2>&1 | head -2 || true

IP4=$(curl -4 -s --max-time 6 https://ifconfig.me || true)
IP6=$(curl -6 -s --max-time 6 https://ifconfig.me || true)
echo
echo "──────────────── DNS records for $DOMAIN ────────────────"
echo "· DKIM (TXT, host: $SELECTOR._domainkey):"
sed 's/^/    /' "$KEYDIR/$SELECTOR.txt"
echo "· SPF (TXT, host @) — merge into any existing v=spf1 record:"
echo "    v=spf1${IP4:+ ip4:$IP4}${IP6:+ ip6:$IP6} ~all"
echo "· DMARC (TXT, host _dmarc) — if none exists yet:"
echo "    v=DMARC1; p=quarantine; rua=mailto:postmaster@$DOMAIN"
echo "──────────────────────────────────────────────────────────"
echo "opendkim-testkey will FAIL until the DKIM TXT is published; re-check with:"
echo "  opendkim-testkey -vvv -d $DOMAIN -s $SELECTOR"

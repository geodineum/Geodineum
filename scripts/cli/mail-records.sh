#!/usr/bin/env bash
# `geodineum mail records <domain>` — reprint the DNS records for a domain
# provisioned by setup-mail-stack.sh, and show live-DNS reality beside them.
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
    echo "usage: geodineum mail records <domain>"
    echo "provisioned domains:"
    ls /etc/opendkim/keys/ 2>/dev/null || echo "  (none — run scripts/setup-mail-stack.sh first)"
    exit 1
fi

shopt -s nullglob
txts=(/etc/opendkim/keys/"$DOMAIN"/*.txt)
if [[ ${#txts[@]} -eq 0 ]]; then
    echo "no DKIM key material for $DOMAIN (need sudo to read, or domain not provisioned)"
    exit 1
fi
for f in "${txts[@]}"; do
    sel=$(basename "$f" .txt)
    echo "· DKIM TXT (host: ${sel}._domainkey):"
    sed 's/^/    /' "$f"
    echo "  live DNS: $(dig +short "${sel}._domainkey.$DOMAIN" TXT | head -1)"
    echo "  key test: $(opendkim-testkey -d "$DOMAIN" -s "$sel" 2>&1 | tail -1 || true)"
done
echo "· SPF live: $(dig +short "$DOMAIN" TXT | grep spf1 || echo '(none)')"
echo "· DMARC live: $(dig +short "_dmarc.$DOMAIN" TXT | head -1)"
echo "· MX live: $(dig +short "$DOMAIN" MX | tr '\n' ' ')"

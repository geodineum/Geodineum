#!/bin/bash
# geodineum site user <site_id> | --root <docroot> — the Unix user a site's PHP runs as: its pool
# user, else www-data. Scripts that run a site's PHP or WP-CLI: sudo -u "$(geodineum site user <id>)"
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../../lib/site-pool.sh
source "$HERE/../../lib/site-pool.sh"
if [[ "${1:-}" == --root ]]; then
    [[ -n "${2:-}" ]] || { echo "usage: sudo geodineum site user <site_id> | --root <docroot>" >&2; exit 2; }
    site_pool_owner_for "$2" || echo www-data
    exit 0
fi
ID="${1:-}"
[[ "$ID" =~ ^[a-z0-9_]+$ ]] || { echo "usage: sudo geodineum site user <site_id> | --root <docroot>" >&2; exit 2; }
if site_pool_read "$SITE_POOL_RECORDS/$ID.env" 2>/dev/null; then printf '%s\n' "$SP_SITE_USER"; else echo www-data; fi

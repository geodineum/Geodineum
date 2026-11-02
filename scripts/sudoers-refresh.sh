#!/usr/bin/env bash
# Re-render /etc/sudoers.d/geodineum-deploy from templates/sudoers-geodeploy.tpl:
#   sudo bash scripts/sudoers-refresh.sh [deploy user]            shows the diff
#   sudo bash scripts/sudoers-refresh.sh [deploy user] --apply    installs it (visudo-checked)
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
TPL="$HERE/templates/sudoers-geodeploy.tpl"
DEST=/etc/sudoers.d/geodineum-deploy
HOST=$(hostname -s)
APPLY=0; USER_ARG=""
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        *) USER_ARG="$a" ;;
    esac
done
DEPLOY_USER=${USER_ARG:-${SUDO_USER:-}}
say() { echo "on $HOST: [sudoers] $*"; }

(( EUID == 0 )) || { say "run with sudo"; exit 1; }
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && id "$DEPLOY_USER" >/dev/null 2>&1 \
    || { say "deploy user '${DEPLOY_USER}' unknown"; exit 1; }
[[ -f "$TPL" ]] || { say "no template $TPL"; exit 1; }

tmp=$(mktemp /etc/sudoers.d/.geodineum-deploy.XXXXXX)
trap 'rm -f "$tmp"' EXIT
sed "s|{{DEPLOY_USER}}|${DEPLOY_USER}|g" "$TPL" > "$tmp"
chmod 0440 "$tmp"
visudo -cf "$tmp" >/dev/null || { say "STOP: the rendered template fails visudo; $DEST unchanged"; exit 1; }

if [[ -f "$DEST" ]] && cmp -s "$tmp" "$DEST"; then
    say "$DEST already matches the template"
    exit 0
fi
say "changes for $DEST (deploy user $DEPLOY_USER):"
diff -u "$DEST" "$tmp" | tail -n +3 || true
if (( ! APPLY )); then
    say "dry run; add --apply to install"
    exit 0
fi
mv -f "$tmp" "$DEST"
trap - EXIT
chown root:root "$DEST"
say "installed $DEST"

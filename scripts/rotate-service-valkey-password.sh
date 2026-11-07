#!/bin/bash
# Replace a service's ValKey password with no downtime: both passwords work until the service has moved.
# Never prints a password; the new one reaches ValKey only as its SHA-256.
#   on the master:      sudo bash rotate-service-valkey-password.sh --begin  <service> [--copy-to <ssh host>]
#   on the service's node (if it is another node):
#                       sudo bash rotate-service-valkey-password.sh --switch <service>
#   on the master:      sudo bash rotate-service-valkey-password.sh --finish <service>
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
MODE="${1:-}"; SVC="${2:-}"; COPY=""
[[ "${3:-}" == --copy-to ]] && COPY="${4:-}"
[[ "$MODE" =~ ^--(begin|switch|finish)$ && "$SVC" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || { sed -n 3,7p "$0"; exit 2; }
CREDS="${GEODINEUM_CREDENTIALS_DIR:-/etc/geodineum/credentials}"; PORT="${VALKEY_PORT:-47445}"
USER_="gnode_client_$SVC"; CRED="$CREDS/valkey_client_$SVC.password"; STATE=/root/.rotate-valkey; UNIT="${ROTATE_UNIT:-$SVC}"
SUDO_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"; INBOX="$SUDO_HOME/.rotate-$SVC.new"
NEW="$STATE/$SVC.new"; OLD="$STATE/$SVC.old"
umask 077; mkdir -p "$STATE"
A() { REDISCLI_AUTH="$(<"$CREDS/valkey.password")" valkey-cli -e --raw --no-auth-warning -p "$PORT" "$@"; }
hash_of() { printf '%s' "$(<"$1")" | sha256sum | cut -d' ' -f1; }
wipe() { shred -u "${1:?}" 2>/dev/null || rm -f -- "${1:?}"; }
install_cred() { # keeps the owner, group and mode the file had
    local u g m; read -r u g m < <(stat -c '%U %G %a' "$CRED")
    install -o "$u" -g "$g" -m "$m" "$1" "$CRED.new"; mv -f "$CRED.new" "$CRED"
}
save() { [[ -n "$(A CONFIG GET aclfile | sed -n 2p)" ]] && A ACL SAVE >/dev/null; chmod 0640 /etc/valkey/users.acl 2>/dev/null || true; }
case "$MODE" in
--begin)
    [[ -r "$CREDS/valkey.password" ]] || { echo "not the master: no admin credential" >&2; exit 1; }
    A ACL GETUSER "$USER_" >/dev/null
    [[ -f "$NEW" ]] && { echo "a rotation of $SVC is already begun; run --finish first" >&2; exit 1; }
    openssl rand -hex 32 | tr -d '\n' > "$NEW"
    A ACL SETUSER "$USER_" "#$(hash_of "$NEW")" >/dev/null
    save
    if [[ -f "$CRED" ]]; then install_cred "$NEW"; echo "  this node's copy of $(basename "$CRED") updated"; fi
    if [[ -n "$COPY" ]]; then
        sudo -u "${SUDO_USER:?run through sudo}" ssh -o BatchMode=yes "$COPY" 'umask 077; cat > ~/.rotate-'"$SVC"'.new' < "$NEW"
        echo "  new password copied to $COPY (0600); both passwords work until --finish"
    fi ;;
--switch)
    [[ -f "$INBOX" ]] || { echo "no $INBOX: run --begin on the master first" >&2; exit 1; }
    host="$(sed -n 's/^VALKEY_HOST=//p' /etc/geodineum/bootstrap.env 2>/dev/null | head -1)"
    r=$(REDISCLI_AUTH="$(<"$INBOX")" valkey-cli -e --no-auth-warning -h "${host:-127.0.0.1}" -p "$PORT" --user "$USER_" PING 2>&1 || true)
    [[ "$r" == PONG ]] || { echo "the new password does not authenticate: $r; nothing changed" >&2; exit 1; }
    cp -p "$CRED" "$OLD"
    install_cred "$INBOX"; wipe "$INBOX"
    if systemctl is-enabled "$UNIT" >/dev/null 2>&1; then systemctl restart "$UNIT"; sleep 3; echo "  $UNIT: $(systemctl is-active "$UNIT")"; fi
    r=$(REDISCLI_AUTH="$(<"$CRED")" valkey-cli -e --no-auth-warning -h "${host:-127.0.0.1}" -p "$PORT" --user "$USER_" PING 2>&1 || true)
    [[ "$r" == PONG ]] || { echo "after the switch the file does not authenticate: $r" >&2; exit 1; }
    wipe "$OLD"
    echo "  switched; now --finish on the master" ;;
--finish)
    [[ -f "$NEW" ]] || { echo "no rotation of $SVC is begun" >&2; exit 1; }
    new=$(hash_of "$NEW"); n=0
    for old in $(A ACL GETUSER "$USER_" | grep -E '^[0-9a-f]{64}$' || true); do
        [[ "$old" == "$new" ]] && continue
        A ACL SETUSER "$USER_" "!$old" >/dev/null; n=$((n+1))
    done
    save; wipe "$NEW"
    echo "  $n old password(s) of $USER_ removed" ;;
esac

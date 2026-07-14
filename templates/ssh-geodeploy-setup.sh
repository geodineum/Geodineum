#!/bin/bash
# =============================================================================
# Generate a read-only deploy key for geodeploy auto-pull
# =============================================================================
# Creates a separate SSH key used ONLY by the geodeploy orchestrator.
# This key gets read-only access on GitHub — it can pull but never push.
#
# Two approaches:
#
# A) Per-org machine user (recommended for orgs with many repos):
#    1. Create a GitHub account (e.g., geodeploy-bot)
#    2. Add it as read-only collaborator to the geodineum org
#    3. Upload the public key to that account's SSH keys
#    4. One key covers all repos
#
# B) Per-repo deploy keys (simpler, no extra GitHub account):
#    1. Upload the public key as a deploy key to EACH repo
#    2. GitHub requires unique keys per repo, so use the host-alias trick:
#       each repo gets its own Host entry pointing to the same key
#    3. More setup but no extra GitHub account needed
#
# This script sets up the SSH key and config for either approach.
# =============================================================================

set -euo pipefail

KEY_PATH="${HOME}/.ssh/id_ed25519_geodeploy"
SSH_CONFIG="${HOME}/.ssh/config"

echo "=== Geodeploy SSH Key Setup ==="
echo ""

# --- Step 1: Generate key ---
if [[ -f "$KEY_PATH" ]]; then
    echo "Key already exists: ${KEY_PATH}"
    echo "Public key:"
    cat "${KEY_PATH}.pub"
else
    echo "Generating ed25519 deploy key..."
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "geodeploy@$(hostname) read-only"
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
    echo ""
    echo "Public key (upload this to GitHub):"
    cat "${KEY_PATH}.pub"
fi

echo ""

# --- Step 2: Add SSH config entry ---
if grep -q "Host github-deploy" "$SSH_CONFIG" 2>/dev/null; then
    echo "SSH config entry 'github-deploy' already exists"
else
    echo "Adding SSH config entry..."
    cat >> "$SSH_CONFIG" << 'EOF'

# Geodeploy: read-only pull access for auto-deploy
Host github-deploy
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_geodeploy
  IdentitiesOnly yes
EOF
    echo "Added 'github-deploy' host alias to ${SSH_CONFIG}"
fi

echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Upload the public key to GitHub:"
echo "   - Machine user: Settings → SSH Keys → paste key"
echo "   - Deploy keys:  Each repo → Settings → Deploy Keys → paste key (read-only)"
echo ""
echo "2. Update git remotes in /opt/geodineum/ to use the deploy host alias:"
echo "   cd /opt/geodineum/gNode && git remote set-url origin git@github-deploy:geodineum/gNode.git"
echo "   (repeat for each repo)"
echo ""
echo "3. Or run this to update all at once:"
echo '   for repo in /opt/geodineum/*/; do'
echo '     cd "$repo" && url=$(git remote get-url origin 2>/dev/null) && [ -n "$url" ] && \'
echo '     git remote set-url origin "${url/github.com/github-deploy}" 2>/dev/null && \'
echo '     echo "  $(basename $repo): updated" || true'
echo '   done'
echo ""
echo "4. Test: ssh -T git@github-deploy"
echo "   Should say: Hi <user>! You'\''ve successfully authenticated..."

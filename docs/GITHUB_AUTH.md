# GitHub Auth Setup — REQUIRED Before You Run install.sh

> **All Geodineum repos are currently private.** You MUST set up GitHub
> authentication on every server before running `install.sh` — otherwise
> all `git clone` operations fail. This will change when we publicly launch;
> until then, treat this guide as a hard prerequisite, not optional reading.

The installer fetches 8+ component repositories
(`geodineum/gNode`, `geodineum/gCore`, `geodineum/gTemplate`, `geodineum/gCube`,
`geodineum/Geodineum-COMMS`, `geodineum/Geodineum-BAK`, `geodineum/gNode-Client`,
plus the parent `geodineum/Geodineum`). Without auth, every clone returns
`Repository not found` and the install aborts in Phase 5.

You have two options. **Method 1 (SSH deploy key) is recommended for production
servers.** Method 2 (Personal Access Token) is acceptable for one-off / dev
machines.

---

## Method 1: SSH Deploy Key (Recommended)

A GitHub deploy key is a per-repository SSH key with **read-only access**.
It's the right primitive for unattended deploy servers — narrower scope than
a personal SSH key, no password expiry, and revokable per-server.

### Step 1 — generate a key on the deploy server

Run as the user who will execute `sudo ./install.sh` (typically your sudoer
account, NOT root — install.sh clones via `sudo -u "$SUDO_USER"`):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/geodineum_deploy -N "" -C "geodineum-deploy@$(hostname)"
cat ~/.ssh/geodineum_deploy.pub
```

Copy the printed public key (starts with `ssh-ed25519`).

### Step 2 — add as a deploy key on EACH repo

GitHub deploy keys are per-repository, so you must add the key to every
repo the installer fetches. For each repo below:

1. Go to `https://github.com/<owner>/<repo>/settings/keys`
2. Click **Add deploy key**
3. Title: `geodineum-deploy@<your-hostname>`
4. Paste the public key from Step 1
5. **Leave "Allow write access" UNCHECKED** — read-only is sufficient for clone/pull
6. Click **Add key**

Repos to add the key to (Chapter 1 set):

```
geodineum/Geodineum
geodineum/Geodineum-COMMS
geodineum/Geodineum-BAK
geodineum/gNode
geodineum/gNode-Client
geodineum/gCore
geodineum/gTemplate
geodineum/gCube
```

> **Tip:** If you're managing many servers, generate one key per server
> (don't reuse). Deploy keys are uniquely tied to a single repo + key pair —
> you can't reuse the same public key across multiple repos under the same
> account. (You can, however, reuse it across orgs since GitHub scopes deploy
> keys per-repo.)

### Step 3 — configure SSH to use the key for github.com

Add to `~/.ssh/config` (create if missing):

```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/geodineum_deploy
    IdentitiesOnly yes
```

Set permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/geodineum_deploy
chmod 644 ~/.ssh/geodineum_deploy.pub
```

### Step 4 — switch the installer to SSH

The installer defaults to HTTPS clone URLs which will fail for private repos.
Tell it to use SSH instead:

```bash
sudo GEODINEUM_GIT_PROTOCOL=ssh ./install.sh
```

Or persist this in `/etc/geodineum/bootstrap.env` so all future runs use SSH:

```bash
sudo tee -a /etc/geodineum/bootstrap.env > /dev/null <<'EOF'

# Use SSH for git clone (required while repos are private)
GEODINEUM_GIT_PROTOCOL="ssh"
EOF
```

### Step 5 — verify before running install.sh

```bash
ssh -T git@github.com
# Expected: "Hi <repo>! You've successfully authenticated, but GitHub does
#           not provide shell access."
```

Test a clone (don't actually clone — just verify auth):

```bash
git ls-remote git@github.com:geodineum/gNode.git HEAD
git ls-remote git@github.com:geodineum/gCore.git HEAD
# Each should print a SHA, not an error.
```

If both work, `install.sh` will succeed in Phase 5 (component fetch).

---

## Method 2: Personal Access Token (PAT) over HTTPS

Simpler if you don't want to manage SSH keys, but the token is broader-scoped
than a deploy key (it's tied to your user account, has access to whatever you
give it).

### Step 1 — create a fine-grained PAT

1. Go to `https://github.com/settings/tokens?type=beta`
2. Click **Generate new token**
3. **Repository access**: choose **Only select repositories** and pick all 8+
   repos listed above (don't grant access to "All repositories" — principle of
   least privilege)
4. **Permissions** → **Repository permissions** → **Contents: Read-only**
5. Set expiration (90 days recommended; renew before it expires — set a
   calendar reminder)
6. Click **Generate token** and copy it (you won't see it again)

### Step 2 — pass to install.sh

```bash
sudo GEODINEUM_GITHUB_TOKEN="github_pat_xxxxxxxxxxxx" ./install.sh
```

The installer rewrites clone URLs to embed the token:
`https://x-access-token:<token>@github.com/<owner>/<repo>.git`

### Step 3 — persist the token (recommended)

So `geodineum update`, future installs, and re-runs use the same token:

```bash
sudo tee -a /etc/geodineum/bootstrap.env > /dev/null <<EOF

# GitHub PAT for private repo access (required until public launch)
GEODINEUM_GITHUB_TOKEN="github_pat_xxxxxxxxxxxx"
EOF
sudo chmod 600 /etc/geodineum/bootstrap.env  # token is a secret
sudo chown root:root /etc/geodineum/bootstrap.env
```

> **Security:** A token-bearing bootstrap.env must be 600 root:root, NOT 644
> (the default for the secret-free template). Tighten the permissions yourself
> if you persist a token here. The token grants read access to all 8+ repos.

---

## Troubleshooting

### `Repository not found` during install
Most common error when auth is missing. The repo IS there, but GitHub returns
404 to unauthenticated requests against private repos to avoid leaking the
existence of private repositories.

- Method 1: deploy key not added to that specific repo (deploy keys are per-repo)
- Method 2: PAT doesn't have access to that repo selected
- Verify with `git ls-remote git@github.com:<owner>/<repo>.git HEAD` (SSH) or
  `git ls-remote https://x-access-token:<token>@github.com/<owner>/<repo>.git HEAD` (HTTPS)

### `Permission denied (publickey)` on `git clone`
- SSH key not added to GitHub for that repo, OR
- `~/.ssh/config` not pointing at the right key, OR
- File permissions wrong (`chmod 600 ~/.ssh/<key>`)
- Test verbosely: `ssh -vT git@github.com` (output shows which key was tried)

### `Could not resolve host: github.com`
- DNS or firewall issue. Some corporate firewalls block outbound TCP 22 (SSH).
  Use Method 2 (PAT over HTTPS port 443) if 22 is blocked.

### Install proceeds but `geodineum update` later fails
- Token / SSH protocol wasn't persisted to `bootstrap.env`. Add it (see Step 3
  of either method).

### Wrong user runs install.sh
- `install.sh` clones as `$SUDO_USER`, not root. The deploy key / SSH config
  must exist in the SUDO_USER's home, not `/root/.ssh/`. Verify by running
  `sudo -u $SUDO_USER ssh -T git@github.com` before kicking off install.

---

## After install.sh completes

The remote URLs are baked into each repo's `.git/config`. To switch a
component from HTTPS to SSH (or vice versa) post-install:

```bash
cd /opt/geodineum/<component>
git remote set-url origin git@github.com:<owner>/<repo>.git   # → SSH
# or
git remote set-url origin https://github.com/<owner>/<repo>.git   # → HTTPS
```

---

## Public Launch — Removing This Step

When Chapter 1 publicly launches and repos are flipped public, this guide
becomes optional (HTTPS unauthenticated clones will work for public repos,
subject to GitHub's 60-req/hr unauthenticated rate limit). At that point
the README will note auth as optional rather than required. Until then —
this guide is a hard prerequisite.

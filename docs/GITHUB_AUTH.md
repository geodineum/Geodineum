# GitHub access for install.sh

The installer clones its component repositories from GitHub
(`geodineum/Geodineum`, `gNode`, `gNode-Client`, `gCore`, `gTemplate`, `gCube`,
`Geodineum-COMMS`, `Geodineum-BAK`). They are public, so the default needs no
setup: clones use `https://github.com/<owner>/<repo>.git`.

Set one of these only when you install from private forks or mirrors:

| Variable | Clone URL | Use |
|---|---|---|
| `GEODINEUM_GIT_PROTOCOL=ssh` | `git@github.com:<owner>/<repo>.git` | an SSH key of the user running `sudo ./install.sh` (clones run as `$SUDO_USER`, not root) |
| `GEODINEUM_GITHUB_TOKEN=<token>` | `https://x-access-token:<token>@github.com/<owner>/<repo>.git` | a fine-grained token with read-only Contents access to those repositories |

```bash
sudo GEODINEUM_GIT_PROTOCOL=ssh ./install.sh
```

With SSH, check access first: `sudo -u "$SUDO_USER" git ls-remote git@github.com:geodineum/gNode.git HEAD`
prints a SHA.

Each clone keeps its URL in `.git/config`; change it later with
`git -C /opt/geodineum/<component> remote set-url origin <url>`.

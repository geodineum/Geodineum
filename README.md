<p align="center">
  <a href="https://geodineum.com">
    <img src=".github/geodineum-logo.png" alt="Geodineum" width="128">
  </a>
</p>

# Geodineum

The installer and orchestrator for a ValKey-backed multi-service ecosystem: a
Linux host runs one or more services, and each service declares its own wiring
(install, config, logging, CLI, backup, and data routing) in a single manifest.

Built by **Niels Erik Toren** · shell installer + `geodineum` CLI + manifest contract

---

## What it is

Geodineum installs and wires an ecosystem of services around a shared ValKey
backend. A service author writes their binary and one `geodeploy.yaml`; the
orchestrator reads the manifest and handles everything else: deploy, ValKey ACL
grants, systemd, logging, CLI dispatch, and backup hints. Complexity is opt-in: a
manifest that omits a section gets the convention default.

This repository is the canonical installer, the `geodineum` operator CLI, and the
manifest contract. The components that plug into it (`gNode`, `gNode-Client`,
`gCore`, `gTemplate`, `gCube`, `Geodineum-COMMS`, `Geodineum-BAK`) each live in
their own repository and ship their own manifest.

## Public build surface

What you build against is the **`geodeploy.yaml` manifest**: one file declaring a
service's identity, deploy, install/uninstall, logging, config, data
(streams/keys/channels, composed into ValKey ACL grants), backup, and CLI verbs.
Its schema is the source of truth:
**`schemas/geodeploy-manifest.schema.yaml`** (JSON Schema), and
`geodineum validate` checks any manifest against it. The reference service that
exercises every section is **`services/hello-world/`**.

The other surface is the **`geodineum` CLI**: install/uninstall, per-service
lifecycle, site and config management, schema validation, and constellation
membership. Each installed component contributes its own manifest-declared verbs,
discovered automatically. Adding one is a `cli:` entry plus a handler script, no
recompile. Run `geodineum --help` for the resolved command set.

**Internal**: `install.sh`, `uninstall.sh`, and the shared helper libraries under
`lib/` are implementation and may change.

## Capabilities

- **Idempotent phased install**: a single `install.sh` runs the ecosystem
  install end to end; re-running converges rather than duplicating.
- **Manifest-driven deploy**: pulls each component, applies trigger actions
  (chmod, opcache-clear, build, restart), and tracks the checked-out branch.
- **Composed ValKey ACLs**: a service's declared `data.consumes` / `data.produces`
  become least-privilege ACL grants; inter-service traffic is routed by gNode, so
  a service needs no ACL on another's keyspace.
- **Per-service lifecycle**: install / uninstall / health with per-service
  locking, `on_failure` semantics, sudo gating, and an audit trail to ValKey.
- **Auto-discovered CLI**: component verbs are dispatched straight from their
  manifests; no central registration.
- **Multi-node constellations**: several nodes share one ValKey brain over a
  private WireGuard VPN, ValKey never touching the public internet. Every node
  gets a unique node id: the wizard prompts for one on a constellation join, and
  flag-driven joins default it to the host's name, so a worker never collides
  with the master's identity.
- **Signed extensions, your choice**: official gNode extensions are signed with
  the project's private Ed25519 author key and verified against the public key
  embedded in the daemon. Operators decide the policy with one variable:
  `GNODE_SIGNED_EXT_ONLY=1` loads only officially-signed extensions (the
  production default); leave it off to run your own unsigned extensions during
  development or self-hosting.

## Contract

The manifest contract is **`schemas/geodeploy-manifest.schema.yaml`**.
Cross-component contracts, the permission model, and this ecosystem's README
standard live in **[`CONTRACTS/`](CONTRACTS/)**; each component repository ships
its own `CONTRACT.md`. Multi-node deployment is walked through in
**[`docs/MULTI_NODE_DEPLOYMENT.md`](docs/MULTI_NODE_DEPLOYMENT.md)**.

## Quick start

Clone to `/opt/geodineum/Geodineum/` and run the installer:

```sh
sudo ./install.sh
```

Then exercise the manifest-driven surface: install the bundled reference service,
call a component verb, and inspect the registry:

```sh
sudo geodineum service install services/hello-world/geodeploy.yaml
geodineum gmath multiply 6 7     # → 42.0000000000000000000  (real g_math via a manifest cli verb)
geodineum service list
geodineum validate --all         # every geodeploy.yaml checked against the schema
```

Authoring your own service is one `geodeploy.yaml` plus a few idempotent shell
steps. Copy `services/hello-world/` and validate it with `geodineum validate`.

## Limits worth knowing

- **Multi-node replica tier is experimental**: headless and full nodes ship
  today; a local read/write-split ValKey replica does not. And yes, we are
  already working on it.
- **Topology tier is implicit**: services register on the 30-D service tier;
  choosing a tier per manifest is not yet a manifest field.
- **`config.defaults` seeding is deferred**: the orchestrator does not yet
  NX-seed a manifest's config defaults at install time.
- **Backup is wholesale, not per-service**: the RDB snapshot covers everything;
  per-service `backup.*` entries are introspective hints, not selective backups.
- **Validated on a fresh Ubuntu 22.04 host**: the full install → uninstall →
  reinstall cycle is exercised there; other distributions are untested.

## Collaborate

Contributions are welcome. Check **[`ROADMAP.md`](ROADMAP.md)** to see what is
already on our plate and pick up work from there. We do not curate
`good-first-issue` labels in the age of AI: read the roadmap, pick something
real, and build it.

- Fork, branch, and open a pull request against `main`; we review every PR.
- Changes to a wire contract can be proposed, but expect intense scrutiny. Any
  accepted change must update **both** `CONTRACT.md` and `CONTRACT.scn.md` in
  the same commit.
- A change to a signed extension must be re-signed in the same commit; only
  maintainers hold the author key, so extension PRs land unsigned and are
  signed on merge.

## Author & support

Built by **Niels Erik Toren**.

If you want to support the work:

| Currency | Address |
|---|---|
| Bitcoin (BTC) | `bc1qwf78fjgapt2gcts4mwf3gnfkclvqgtlg4gpu4d` |
| Ethereum (ETH) | `0xf38b517Dd2005d93E0BDc1e9807665074c5eC731` / `nierto.eth` |
| Monero (XMR) | `8BPaSoq1pEJH4LgbGNQ92kFJA3oi2frE4igHvdP9Lz2giwhFo2VnNvGT8XABYasjtoVY2Qb3LVHv6CP3qwcJ8UnyRtjWRZ5` |

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. Use of this software is entirely at your own risk. In no event shall the
author or contributors be held liable for any damages arising from the use or
inability to use this software.

## License

Licensed under either of

* [Apache License, Version 2.0](LICENSE-APACHE)
* [MIT License](LICENSE-MIT)

at your option.

# Geodineum CLI Reference

**Version 1.0.0** | Single ecosystem manager for service registration, configuration, and topology.

```
geodineum <command> [subcommand] [options]
```

Invocable as `geodineum` or `gcli` (symlink).

---

## Installation

```bash
# Symlink to PATH (already done by install.sh)
sudo ln -sf /opt/geodineum/Geodineum/geodineum /usr/local/bin/geodineum
sudo ln -sf /opt/geodineum/Geodineum/geodineum /usr/local/bin/gcli
```

---

## Commands

### `register` — Register an existing service

The **single registration authority** for the entire ecosystem. Creates the `.geodineum/` directory in the service root, provisions ACL credentials and streams, and writes the `gnode:` declaration its topology entity is registered from ([CONTRACTS/REGISTRATION.md](CONTRACTS/REGISTRATION.md)).

```bash
sudo geodineum register <site_id> [options]
```

**Capability sources** (pick one):

| Flag | Description |
|------|-------------|
| `--express` | Auto-detect capabilities by scanning the service root (language, framework, protocol, scope) |
| `--yaml <path>` | Read from YAML file. Auto-detects flat (`wp-config-geodineum.yaml`) or daemon (`gnode_services.yaml`) format |
| `--template <preset>` | Use a capability preset: `wordpress`, `http-api`, `worker`, `inference` |

**Options:**

| Flag | Description |
|------|-------------|
| `--path <dir>` | Service root directory. Auto-detected for WordPress sites (`/var/www/{domain}`) |
| `--env <environment>` | DTAP environment: `testing` (default), `staging`, `acceptance`, `production` |
| `--owner <tenant_id>` | Tenant/owner for cross-site discovery |
| `--force` | Regenerate ACL password and overwrite existing config |
| `--dry-run` | Preview without making changes |

**What it creates:**

```
<service_root>/.geodineum/
  ├── .htaccess              Deny from all (web access protection)
  ├── credentials/
  │   └── valkey_client_{site_id}.password  → /etc/geodineum/credentials/...
  ├── config.yaml            Unified config (identity, environment, ValKey, capabilities)
  ├── gnode_services.yaml    manifest; its `gnode:` block is the topology declaration
  ├── config-schema.yaml     Config option schema (generated on import)
  └── .registered            Timestamp + hash marker
```

**Express mode** scans the service root and infers:
- Language (PHP, Python, Node, Rust, Go, Ruby, Java)
- Framework (WordPress, Laravel, Django, FastAPI, Express, Axum, etc.)
- Protocol (REST, GraphQL, gRPC, gNode stream)
- Scope (client-facing, daemon, worker)
- Log and documentation locations

Shows detected values for interactive confirmation before proceeding.

**Examples:**

```bash
# Express mode — scan and infer capabilities
sudo geodineum register your_site --express --env production

# From existing YAML config
sudo geodineum register your_site --yaml /var/www/your-site/wp-config-geodineum.yaml --env production

# With capability preset and tenant grouping
sudo geodineum register client_app --template http-api --path /opt/apps/client --owner acme --env production

# Preview only
geodineum register new_service --template worker --path /opt/svc --dry-run
```

---

### `new site` — Deploy a WordPress site

Full WordPress deployment with gNode integration, theme activation, and security hardening in one command.

```bash
sudo geodineum new site <domain> [options]
```

| Flag | Description |
|------|-------------|
| `--theme <name>` | Child theme: `gcube` |
| `--theme-path <path>` | Custom theme source path (auto-detected if omitted) |
| `--env <environment>` | DTAP environment (default: `testing`) |
| `--owner <tenant_id>` | Tenant/owner for cross-site discovery |
| `--no-ssl` | Skip SSL certificate setup |
| `--dry-run` | Preview without making changes |

**Steps performed:**
1. WordPress deployment via gTemplate installer
2. `.geodineum/` creation + gNode onboarding (ACL, streams, capabilities)
3. Web hardening (.htaccess deny rules on infrastructure directories)

```bash
sudo geodineum new site example.com --theme gcube --env production
sudo geodineum new site test.example.com --theme gcube --env testing --no-ssl
```

---

### `new service` — Scaffold a standalone service

Creates a service directory with bootstrap code, capability config, and full gNode onboarding.

```bash
sudo geodineum new service <name> [options]
```

| Flag | Description |
|------|-------------|
| `--lang <language>` | Bootstrap language: `php`, `python`, `node` (default: `php`) |
| `--template <preset>` | Capability preset: `http-api` (default), `worker`, `inference` |
| `--path <dir>` | Install path (default: `/opt/geodineum/services/<name>`) |
| `--env <environment>` | DTAP environment (default: `testing`) |
| `--owner <tenant_id>` | Tenant/owner for cross-site discovery |
| `--dry-run` | Preview without making changes |

**Creates:**
- `src/bootstrap.{php,py,js}` — ready-to-run service code with ValKey connection
- `.geodineum/` — config, credentials, capability registration
- `.env` — service environment variables

```bash
sudo geodineum new service my_api --lang php --template http-api
sudo geodineum new service ml_worker --lang python --template inference --owner acme
```

---

### `new pipeline` — Create a data pipeline

Service variant with a cron schedule and ingest bootstrap code.

```bash
sudo geodineum new pipeline <name> --source <url> [options]
```

| Flag | Description |
|------|-------------|
| `--source <url>` | Data source URL (required) |
| `--schedule <cron>` | Cron schedule (default: `*/5 * * * *`) |
| `--lang <language>` | Bootstrap language: `php`, `python` (default: `python`) |
| `--env <environment>` | DTAP environment (default: `testing`) |

```bash
sudo geodineum new pipeline stock_feed --source https://api.example.com/feed --lang python
sudo geodineum new pipeline log_ingest --source https://logs.internal/stream --schedule "*/15 * * * *"
```

---

### `config` — Manage service configuration

Read, write, and import configuration via ValKey. Changes propagate to running services via `PUBLISH` notifications (gCore ConfigWatcher).

Two config namespaces per service:
- **`capabilities`** — the service's declared axes (its identity in the topology space)
- **`app`** — application config imported from service files

#### `config set`

```bash
geodineum config set <site_id> <key> <value> [options]
```

Auto-detects namespace: known topology axes go to `capabilities`, everything else to `app`.

| Flag | Description |
|------|-------------|
| `--namespace <ns>` | Force namespace: `capabilities`, `app`, or custom |
| `--sync-yaml` | Also update `.geodineum/gnode_services.yaml` (capabilities only) |

Validates against `config-schema.yaml` when available (warns on type mismatches, invalid enum values).

```bash
geodineum config set example_site throughput_tier enterprise
geodineum config set my_api database.pool_size 20
geodineum config set ml_service domain_primary ml_inference --sync-yaml
```

#### `config get`

```bash
geodineum config get <site_id> [key] [--namespace app|capabilities]
```

Without a key, shows all config from both namespaces. With `--namespace`, restricts to one.

```bash
geodineum config get example_site                       # All config
geodineum config get example_site throughput_tier        # Single value
geodineum config get my_api --namespace app             # App config only
```

#### `config list`

```bash
geodineum config list <site_id> [--json] [--schema]
```

Full config overview from ValKey + `.geodineum/` status. Shows schema descriptions when `config-schema.yaml` exists.

| Flag | Description |
|------|-------------|
| `--json` | Machine-readable JSON output |
| `--schema` | Show all topology axes and valid values |

```bash
geodineum config list example_site
geodineum config list --schema            # Axis reference
```

#### `config import`

Scan a service root for config files and import them into ValKey. Generates a `config-schema.yaml` for developer refinement.

```bash
sudo geodineum config import <site_id> [options]
```

| Flag | Description |
|------|-------------|
| `--path <dir>` | Service root to scan (auto-detected if omitted) |
| `--depth <N>` | Directory scan depth (default: `3`) |
| `--include <globs>` | Additional file patterns, comma-separated (e.g. `*.json,*.properties`) |
| `--exclude <globs>` | Skip file patterns, comma-separated (e.g. `test-*.yaml`) |
| `--include-env` | Also scan `.env` files (off by default) |
| `--dry-run` | Preview what would be imported |
| `--force` | Skip confirmation + regenerate schema |

**Supported file formats:**

| Format | Extensions | Parser |
|--------|------------|--------|
| YAML | `.yaml`, `.yml` | Section + key/value extraction |
| INI | `.ini`, `.conf` | `[section]` + key=value |
| TOML | `.toml` | `[section]` + key = value |
| PHP defines | `wp-config.php`, `config.php` | `define('KEY', 'value')` |
| PHP arrays | `config/*.php` | `'key' => 'value'` |
| dotenv | `.env` | `KEY=value` (opt-in only) |

Sensitive keys (containing `password`, `secret`, `token`, etc.) are automatically skipped.

```bash
sudo geodineum config import example_site                           # Auto-detect path
sudo geodineum config import my_api --path /opt/my-api --depth 5   # Deeper scan
sudo geodineum config import app --include "*.json" --dry-run      # Preview with JSON files
```

---

### `env` — Environment management

Control DTAP environments and ViewKey gating.

#### `env set`

```bash
sudo geodineum env set <site_id> <environment>
```

Changes the active DTAP environment. Non-production environments are gated behind a ViewKey (auto-generated). Invalidates ValKey config cache and clears PHP OPcache.

```bash
sudo geodineum env set your_site production
sudo geodineum env set your_staging_site staging
```

#### `env show`

```bash
geodineum env show <site_id>
```

Displays current environment, ViewKey, and gate status.

#### `env viewkey`

```bash
geodineum env viewkey <site_id> [--generate]
```

Show or generate the ViewKey for non-production sites.

---

### `info` — Ecosystem and site information

```bash
geodineum info [<site_id>]
```

Without a site_id, shows ecosystem overview: ValKey status, credentials, services, components.

With a site_id, shows:
- Credentials and ACL user
- ValKey connection test
- Stream status (per-environment message counts)
- `.geodineum/` directory status (config, credentials symlink, registration marker)
- File paths (site config, web root, service directory)
- COMMS notification config

---

### `list` — List registered services

```bash
geodineum list [--json]
```

Queries the ValKey site registry. Shows site ID, active environment, and status.

---

### `update-service` — Update an existing registration

Re-detects or re-applies capabilities, regenerates `.geodineum/` config files, and pushes changes to ValKey. The service must already be registered.

```bash
sudo geodineum update-service <site_id> [options]
```

**Capability sources** (pick one):

| Flag | Description |
|------|-------------|
| `--express` | Re-scan service root and infer capabilities |
| `--yaml <path>` | Re-read capabilities from YAML file |
| `--template <preset>` | Re-apply capability preset |

**Options:**

| Flag | Description |
|------|-------------|
| `--reimport` | Also re-import app config from service files |
| `--dry-run` | Preview without making changes |

**What gets updated:**
- `.geodineum/config.yaml` — unified config with new capabilities
- `.geodineum/gnode_services.yaml` — daemon capability config
- ValKey `{site_id}:config:capabilities` hash
- `PUBLISH` notification for running services
- Daemon re-discovers within 120s (mtime-based detection)

```bash
sudo geodineum update-service your_site --express
sudo geodineum update-service my_api --template inference
sudo geodineum update-service my_app --yaml /opt/app/config.yaml --reimport
geodineum update-service my_api --express --dry-run
```

---

### `deregister` — remove a service

The one route that removes a service: the inverse of registering it.

```bash
sudo geodineum deregister <id> [options]
```

| Flag | Description |
|------|-------------|
| `--purge-data` | Also remove the data registration created (docroot, service dir, COMMS history) |
| `--keep-acl` | Keep the ValKey identity (ACL user + credential file) |
| `--keep-cache` | Keep cache/rate-limit keys |
| `--dry-run` | Show the plan only |
| `--force` | Skip confirmation prompt |

**In order:**
1. Stop its heartbeat and the units registration created
2. ValKey (`gNode/scripts/deregister-service.sh`): the registration intent, the topology entity and its placements in the constellation that holds it, its keys, its identity
3. Undo what registration created on this host, newest first, from its ledger (`/etc/geodineum/registrations/<id>.tsv`): vhost, certificate, units, env file, system user and group, manifest, discovery entry
4. Remove the registration marker
5. Check that nothing is left, and name what was kept

Nothing registration did not create is removed. A node leaves with `geodineum node remove`.

```bash
sudo geodineum deregister my_old_service --dry-run
sudo geodineum deregister test_app --purge-data --force
```

---

### `harden` — Deploy web-deny rules to all ecosystem directories

Defense-in-depth for the `www-data`-in-`geodineum`-group problem. A compromised PHP process can read any `geodineum`-group file. This command deploys Apache `.htaccess` and nginx deny rules to every ecosystem directory so those files can never be served via HTTP, even if a vhost misconfiguration, symlink, or path traversal exposes them.

```bash
sudo geodineum harden
```

**Protected directories:**
- `/opt/geodineum/` — ecosystem root (catch-all)
- `/opt/geodineum/gNode/` — daemon source + binary
- `/opt/geodineum/Geodineum/` — CLI + installer
- `/opt/geodineum/Geodineum-COMMS/` — notification daemon
- `/opt/geodineum/Geodineum-BAK/` — backup daemon
- `/opt/geodineum/gNode-Client/` — PHP client library
- `/opt/geodineum/services/*/` — standalone services
- `/opt/geodineum/gCore/scripts/`, `gTemplate/scripts/`, etc. — sensitive subdirs
- `/etc/geodineum/` — config + credentials

Runs automatically after `geodineum update`. Safe to re-run (idempotent).

---

### `status` — The constellation at a glance

```bash
sudo geodineum status [--json]
```

Nodes (heartbeat age, load, memory), what runs where, services (shape, health, placements), components. Reads only ValKey.

---

### `topology` — Inspect, register and deregister topology entities

```bash
sudo geodineum topology [list|all|show <id>|stats|sites|load [id]|verify]
sudo geodineum topology register components
sudo geodineum topology register service <site> [profile] [--env <dtap>]
sudo geodineum topology register node <id> [--role <word>] [--specialization <word>] [--constellation <c>]
sudo geodineum topology deregister <id>
sudo geodineum topology deregister --shape <site|app|daemon|component|node> --confirm
```

One recipe per entity type, with checks and refusals: [CONTRACTS/REGISTRATION.md](CONTRACTS/REGISTRATION.md).

---

### `check` — Ecosystem config health check

```bash
geodineum check [options]
```

| Flag | Description |
|------|-------------|
| `--site <id>` | Check specific site only |
| `--verbose` | Show all checks (not just failures) |
| `--json` | Machine-readable JSON output |
| `--fix` | Attempt to fix issues (requires root) |

Wraps `validate-geodineum-config.sh` (7-layer config health check).

---

### `update` — Pull and rebuild components

```bash
sudo geodineum update [options]
```

| Flag | Description |
|------|-------------|
| `--component <name>` | Update only a specific component |
| `--skip-build` | Skip recompilation after update |

Pulls latest from GitHub for all installed components. Rebuilds the daemon binary, runs `composer install`, and reloads Lua functions.

---

### `logs` — Tail ecosystem logs

```bash
geodineum logs [options]
```

| Flag | Description |
|------|-------------|
| `--service <name>` | Service: `daemon` (default), `comms`, `valkey`, `gcore`, `apache` |
| `-n <lines>` | Number of lines (default: `50`) |
| `-f` | Follow (live tail) |

```bash
geodineum logs -f                    # Follow daemon logs
geodineum logs --service comms -f    # Follow COMMS logs
geodineum logs --service gcore -n 100
```

---

### `install` — Install ecosystem components

```bash
sudo geodineum install [--profile minimal|standard]
```

Delegates to `install.sh` (10-phase installer). Profiles:
- **minimal** — gNode-Client, gCore, gTemplate
- **standard** — minimal + gNode daemon, gCube, Geodineum-COMMS, Geodineum-BAK

---

## The `.geodineum/` Directory

Every registered service gets a `.geodineum/` directory in its root. This is the service-local footprint of the Geodineum ecosystem.

```
<service_root>/.geodineum/
  ├── .htaccess                          Apache: Deny from all
  ├── nginx-deny.conf                    nginx: location block snippet
  ├── credentials/
  │   └── valkey_client_{site_id}.password   Symlink → /etc/geodineum/credentials/
  ├── config.yaml                        Unified service config (identity, env, ValKey, capabilities)
  ├── gnode_services.yaml                manifest; its `gnode:` block is the topology declaration (CONTRACTS/REGISTRATION.md)
  ├── config-schema.yaml                 Config option schema (developer-editable, generated on import)
  └── .registered                        Registration marker (timestamp + config hash)
```

**Ownership:** `{service_owner}:geodineum 750`

The `geodineum` group includes `gnode`, `www-data`, and deploy users. This allows:
- The daemon (`gnode`) to read `gnode_services.yaml` for discovery
- PHP (`www-data`) to read `config.yaml` for bootstrap
- The service owner to read/write all files

**Web server protection** (defense-in-depth when `.geodineum/` sits inside a web root):

- **Apache:** `.htaccess` with `Require all denied` is created automatically
- **nginx:** `nginx-deny.conf` snippet is generated. Include it in your server block:
  ```nginx
  # In your site's server block
  include /var/www/mysite.com/.geodineum/nginx-deny.conf;
  ```
  Or add the rule directly to your nginx config:
  ```nginx
  location ~ /\.geodineum { deny all; return 404; }
  ```

---

## Config Schema for Developers

Services can declare their configurable options in `.geodineum/config-schema.yaml`. The CLI uses this for validation, descriptions, and presentation.

Auto-generate a draft from existing config files:
```bash
sudo geodineum config import my_service
# Generates .geodineum/config-schema.yaml with inferred types
```

Then edit to add descriptions and refine types:

```yaml
schema_version: "1.0.0"
site_id: "my_service"

options:
  config.cache.ttl:
    type: integer
    default: 3600
    min: 0
    description: "Cache lifetime in seconds (0 = no expiry)"
    section: cache

  config.cache.driver:
    type: enum
    values: [valkey, redis, memcached, file]
    default: "valkey"
    description: "Cache backend driver"
    section: cache
    restart: true

  config.logging.level:
    type: enum
    values: [debug, info, warning, error, critical]
    default: "info"
    description: "Minimum log level"
    section: logging
```

**Supported types:** `string`, `integer`, `float`, `boolean`, `enum`, `url`, `path`, `email`, `duration`, `bytes`

**Option fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `type` | yes | Value type (see above) |
| `default` | no | Default value |
| `description` | no | Shown in `config list` |
| `section` | no | Grouping for display |
| `values` | for enum | List of valid values |
| `min` / `max` | no | Bounds for integer/float |
| `sensitive` | no | Mask value in output |
| `restart` | no | Warn that restart is needed after change |
| `readonly` | no | Refuse changes via CLI |
| `deprecated` | no | Warn with replacement key |

See `templates/config-schema.yaml.tpl` for the full reference with examples.

---

## Topology Axes

The words a site, app or daemon declares by name in the `axes:` map of its manifest's `gnode:` block ([CONTRACTS/REGISTRATION.md](CONTRACTS/REGISTRATION.md)). The daemon encodes them and refuses a word it does not know. The authority is the published vocabulary, `gNode/daemon/config/topology_schema.yaml`; this table is a reader's copy.

| Axis | Valid Values |
|------|-------------|
| `protocol` (list) | http_rest, graphql, grpc, websocket, gnode_stream, resp3_direct, amqp, kafka, custom_tcp, undefined |
| `auth_method` | none, api_key, bearer_token, session_cookie, mtls, hardware_token |
| `service_scope` | infrastructure, daemon, worker, cron_scheduled, internal_api, bff, client_facing, edge |
| `domain` (list) | platform, identity, configuration, storage, cache, compute, transform, messaging, workflow, template, content, gateway, integration, analytics, logging, ml_inference, search, notification, presentation, undefined |
| `contract_stability` | experimental, alpha, beta, stable, frozen |
| `contract_version` | v1 ... v5, undefined |
| `throughput_tier` | minimal, standard, professional, enterprise, hyperscale |
| `latency_class` | realtime, interactive, responsive, patient, batch |
| `reliability_tier` | best_effort, standard, high, critical, ultra |
| `execution_priority` | background, low, normal, high, critical |
| `implementation_language` | rust, php, lua, python, go, javascript, bash, undefined |
| `native_format` | plaintext, json, xml, yaml, msgpack, protobuf, cbor, resp3, custom_binary, undefined |
| `fundamentality` | foundation, daemon, app, site, endpoint, or a fraction 0 to 1 |

The environment (`testing`, `staging`, `acceptance`, `production`) is the manifest's `environment:` key, not an axis. Load, health and lifecycle are measured by the daemon and are never declared.

---

## Quick Start

```bash
# 1. Install the ecosystem
sudo geodineum install --profile standard

# 2. Deploy a WordPress site
sudo geodineum new site myapp.com --theme gcube --env testing

# 3. Register an existing service
sudo geodineum register my_api --express --path /opt/my-api --env production

# 4. Import and manage config
sudo geodineum config import my_api
geodineum config set my_api throughput_tier enterprise --sync-yaml
geodineum config list my_api

# 5. Promote to production
sudo geodineum env set myapp_com production

# 6. Monitor
geodineum status --verbose
geodineum info my_api
geodineum logs -f
```

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

The **single registration authority** for the entire ecosystem. Creates the `.geodineum/` directory in the service root, provisions ACL credentials and streams, and generates capability configuration for 30D topology discovery.

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
  ├── gnode_services.yaml    30D capability config (daemon discovers this)
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
- **`capabilities`** — 25 discovery dimensions (service identity in the 30D space)
- **`app`** — application config imported from service files

#### `config set`

```bash
geodineum config set <site_id> <key> <value> [options]
```

Auto-detects namespace: known topology dimensions go to `capabilities`, everything else to `app`.

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
| `--schema` | Show all available topology dimensions and valid values |

```bash
geodineum config list example_site
geodineum config list --schema            # Dimension reference
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

### `deregister` — Complete service removal

Removes a service entirely from the ecosystem. Alias: `remove`.

```bash
sudo geodineum deregister <site_id> [options]
```

| Flag | Description |
|------|-------------|
| `--remove-acl` | Also remove the ValKey ACL user and credential file |
| `--keep-cache` | Keep cache/rate-limit keys |
| `--force` | Skip confirmation prompt |
| `--dry-run` | Preview without making changes |

**Steps performed:**
1. Remove ValKey config hashes (`{site_id}:config:capabilities`, `{site_id}:config:app`)
2. Remove entry from `discovery-paths.conf`
3. Remove `.geodineum/` directory
4. Deregister streams, registry, metadata (via `deregister-service.sh`)
5. Optionally remove ACL user and credential file

```bash
geodineum deregister my_old_service --dry-run
sudo geodineum deregister test_app --remove-acl --force
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

### `status` — Ecosystem health check

```bash
geodineum status [options]
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
  ├── gnode_services.yaml                30D capability config (daemon discovers via discovery-paths.conf)
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

## Topology Capability Dimensions

The 25 discovery dimensions that define a service's identity in the 30D topology space (25 discovery + 5 storage). Set via `register --express`, `--template`, or `config set`.

| Dimension | Valid Values |
|-----------|-------------|
| `protocol` | http_rest, graphql, grpc, gnode_stream, websocket, mqtt |
| `native_format` | json, xml, protobuf, msgpack, html, binary |
| `api_version` | v1, v2, v3, beta, alpha, latest |
| `contract_stability` | stable, beta, alpha, experimental, deprecated |
| `clearance_required` | public, authenticated, elevated, admin, system |
| `auth_method` | none, session_cookie, bearer_token, api_key, mtls, oauth2 |
| `data_sensitivity` | public, internal, confidential, restricted, secret |
| `service_scope` | client_facing, daemon, worker, internal, partner |
| `domain_primary` | content, compute, ml_inference, integration, storage, auth, payment, communication |
| `domain_secondary` | template, platform, data, cache, search, messaging, monitoring |
| `specialization` | generalist, focused, specialist |
| `throughput_tier` | minimal, standard, professional, enterprise, unlimited |
| `latency_class` | interactive, responsive, patient, batch, async |
| `reliability_tier` | minimal, standard, high, critical |
| `pipeline_stage` | ingest, transform, process, deliver, archive |
| `execution_priority` | background, low, normal, high, critical |
| `service_tier` | TOOL, SERVICE, PIPELINE, INFRASTRUCTURE, ORCHESTRATOR |
| `environment` | testing, staging, acceptance, production |

View this table anytime: `geodineum config list --schema`

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

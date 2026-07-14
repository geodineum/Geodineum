# =============================================================================
# Geodineum Config Schema — Developer Reference
# =============================================================================
#
# Place this file at: <service_root>/.geodineum/config-schema.yaml
#
# The Geodineum CLI uses this schema to:
#   - Validate values on `geodineum config set`
#   - Show descriptions on `geodineum config list`
#   - Present options during `geodineum register --express`
#   - Enable future LLM auto-management of service configuration
#
# Auto-generation:
#   `geodineum config import <site_id>` generates a draft schema from
#   existing config files. Edit the generated file to add descriptions,
#   refine types, and set constraints.
#
# Schema version: 1.0.0
# =============================================================================

schema_version: "1.0.0"
site_id: "{{SITE_ID}}"

# =============================================================================
# Option Definition Reference
# =============================================================================
#
# Each option key uses dot-notation matching how it appears in ValKey:
#   source_filename.section.key
#
# Fields per option:
#
#   type: (required)
#     string    — free-form text
#     integer   — whole number
#     float     — decimal number
#     boolean   — true/false, yes/no, on/off, 1/0
#     enum      — one of a fixed set of values
#     url       — URL (http/https)
#     path      — filesystem path
#     email     — email address
#     duration  — time duration (e.g., "30s", "5m", "1h")
#     bytes     — size (e.g., "128M", "1G")
#
#   default: (recommended)
#     The value used when none is explicitly set.
#
#   description: (recommended)
#     Human-readable explanation shown in `geodineum config list`.
#     Keep it short — one line, max ~80 chars.
#
#   section: (optional)
#     Logical grouping for display. Options with the same section
#     are shown together in `geodineum config list`.
#
#   values: (required for enum)
#     List of valid values: [val1, val2, val3]
#
#   min: / max: (optional, integer/float only)
#     Numeric bounds. The CLI warns if a value is outside bounds.
#
#   sensitive: (optional, default: false)
#     If true, the value is masked in output (shown as ****).
#     Used for keys that aren't secrets per se but are private.
#
#   restart: (optional, default: false)
#     If true, changing this value requires a service restart.
#     The CLI shows a warning after `config set`.
#
#   readonly: (optional, default: false)
#     If true, the CLI refuses to change this value.
#     Used for computed or infrastructure values.
#
#   deprecated: (optional)
#     If set, the CLI warns when this option is used.
#     Value is the replacement key: "Use new_key instead"
#
# =============================================================================

options:

  # --- Example: Database Config ---

  # config.database.host:
  #   type: string
  #   default: "127.0.0.1"
  #   description: "Database server hostname"
  #   section: database
  #   restart: true

  # config.database.port:
  #   type: integer
  #   default: 3306
  #   min: 1
  #   max: 65535
  #   description: "Database server port"
  #   section: database
  #   restart: true

  # config.database.pool_size:
  #   type: integer
  #   default: 5
  #   min: 1
  #   max: 100
  #   description: "Connection pool size"
  #   section: database

  # --- Example: Cache Config ---

  # config.cache.driver:
  #   type: enum
  #   values: [valkey, redis, memcached, file, array]
  #   default: "valkey"
  #   description: "Cache backend driver"
  #   section: cache
  #   restart: true

  # config.cache.ttl:
  #   type: integer
  #   default: 3600
  #   min: 0
  #   description: "Default cache TTL in seconds (0 = no expiry)"
  #   section: cache

  # --- Example: Logging ---

  # config.logging.level:
  #   type: enum
  #   values: [debug, info, warning, error, critical]
  #   default: "info"
  #   description: "Minimum log level"
  #   section: logging

  # config.logging.path:
  #   type: path
  #   default: "/var/log/{{SITE_ID}}/app.log"
  #   description: "Log file path"
  #   section: logging

  # --- Example: Performance ---

  # config.performance.workers:
  #   type: integer
  #   default: 4
  #   min: 1
  #   max: 32
  #   description: "Number of worker processes"
  #   section: performance
  #   restart: true

  # config.performance.max_memory:
  #   type: bytes
  #   default: "256M"
  #   description: "Maximum memory per worker"
  #   section: performance
  #   restart: true

  # --- Example: Feature Flags ---

  # config.features.dark_mode:
  #   type: boolean
  #   default: false
  #   description: "Enable dark mode UI"
  #   section: features

  # config.features.beta_api:
  #   type: boolean
  #   default: false
  #   description: "Enable beta API endpoints"
  #   section: features

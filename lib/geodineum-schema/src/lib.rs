//! geodineum-schema — Convention-over-configuration schema publisher
//!
//! Every Geodineum component drops YAML contract files in `config/schemas/`.
//! This crate provides a single function to publish them to ValKey for
//! runtime discovery by other services.
//!
//! # Usage
//!
//! ```rust,ignore
//! // In your daemon startup:
//! geodineum_schema::publish(
//!     "config/schemas/",
//!     &mut valkey_conn,
//!     "your_site",
//!     "production",
//! ).await;
//! ```
//!
//! # ValKey keys
//!
//! - `{site_id}:gnode:schema:{component}:{contract_name}` — full contract JSON
//! - `{site_id}:gnode:schema:_index` — JSON array of all registered schema keys

use redis::aio::MultiplexedConnection;
use serde::{Deserialize, Serialize};
use std::path::Path;
use tracing::{info, warn};

/// A field in a stream contract.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaField {
    pub name: String,
    #[serde(rename = "type")]
    pub field_type: String,
    pub required: bool,
    pub description: String,
    pub example: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub values: Option<String>,
}

/// A complete stream contract definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamContract {
    pub name: String,
    pub component: String,
    pub version: String,
    pub stability: String,
    pub stream: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub consumer_group: Option<String>,
    pub purpose: String,
    pub fields: Vec<SchemaField>,
    pub xadd_example: String,
}

/// YAML file wrapper — contract nested under `contract:` key.
#[derive(Debug, Deserialize)]
struct ContractFile {
    contract: StreamContract,
}

/// Load all contract YAML files from a directory.
/// Skips files starting with `_` (meta-files like `_contract_spec.yaml`).
pub fn load_contracts(schemas_dir: &Path) -> Vec<StreamContract> {
    let mut contracts = Vec::new();

    let entries = match std::fs::read_dir(schemas_dir) {
        Ok(e) => e,
        Err(e) => {
            warn!(dir = %schemas_dir.display(), error = %e, "Cannot read schemas directory");
            return contracts;
        }
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let fname = path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        if !fname.ends_with(".yaml") && !fname.ends_with(".yml") {
            continue;
        }
        if fname.starts_with('_') {
            continue;
        }

        match std::fs::read_to_string(&path) {
            Ok(contents) => match serde_yaml::from_str::<ContractFile>(&contents) {
                Ok(cf) => {
                    info!(file = %fname, contract = %cf.contract.name, "Loaded schema from YAML");
                    contracts.push(cf.contract);
                }
                Err(e) => warn!(file = %fname, error = %e, "Failed to parse schema YAML"),
            },
            Err(e) => warn!(file = %path.display(), error = %e, "Failed to read schema file"),
        }
    }

    contracts
}

/// Publish all YAML contracts from a directory to ValKey.
///
/// Resolves `{site_id}` and `{env}` placeholders in stream patterns and
/// xadd_example fields. Merges into the `{site_id}:gnode:schema:_index`
/// discovery index (idempotent — safe to call on every startup).
///
/// Returns the number of contracts successfully published.
///
/// `#[must_use]` so callers can't silently
/// drop the published-count return value.
#[must_use = "publish returns the number of contracts written; check it"]
pub async fn publish(
    schemas_dir: &str,
    conn: &mut MultiplexedConnection,
    site_id: &str,
    environment: &str,
) -> usize {
    let dir = resolve_schemas_dir(schemas_dir);
    let dir = match dir {
        Some(d) => d,
        None => {
            warn!(path = %schemas_dir, "config/schemas/ directory not found");
            return 0;
        }
    };

    let contracts = load_contracts(&dir);
    if contracts.is_empty() {
        info!(dir = %dir.display(), "No schema contracts found");
        return 0;
    }

    // Resolve placeholders
    let contracts: Vec<StreamContract> = contracts
        .into_iter()
        .map(|mut c| {
            c.stream = c.stream.replace("{site_id}", site_id).replace("{env}", environment);
            c.xadd_example = c.xadd_example.replace("{site_id}", site_id).replace("{env}", environment);
            c
        })
        .collect();

    let mut published = 0;

    for contract in &contracts {
        let key = format!(
            "{}:gnode:schema:{}:{}",
            site_id, contract.component, contract.name
        );

        let json = match serde_json::to_string(contract) {
            Ok(j) => j,
            Err(e) => {
                warn!(contract = %contract.name, error = %e, "Failed to serialize schema");
                continue;
            }
        };

        let result: redis::RedisResult<()> = redis::cmd("SET")
            .arg(&key)
            .arg(&json)
            .query_async(conn)
            .await;

        match result {
            Ok(()) => {
                info!(key = %key, "Published schema contract");
                published += 1;
            }
            Err(e) => warn!(key = %key, error = %e, "Failed to publish schema"),
        }
    }

    // Merge into discovery index
    let index_key = format!("{}:gnode:schema:_index", site_id);
    let contract_keys: Vec<String> = contracts
        .iter()
        .map(|c| format!("{}:{}", c.component, c.name))
        .collect();

    // A bare `.unwrap_or_default()` on the
    // GET masked every transient Redis error during the index merge,
    // silently resetting the discovery index to empty. Post-fix:
    // distinguish "key absent" (treat as empty list — that's the seed
    // case) from "Redis errored" (warn + bail without overwriting the
    // index, so a transient failure doesn't truncate published
    // schemas).
    let existing: Option<String> = match redis::cmd("GET")
        .arg(&index_key)
        .query_async::<Option<String>>(conn)
        .await
    {
        Ok(v) => v,
        Err(e) => {
            warn!(
                key = %index_key,
                error = %e,
                "GET on schema index failed; skipping merge to avoid clobbering existing index"
            );
            info!(count = published, "Schema contracts published to ValKey (index merge skipped)");
            return published;
        }
    };

    let mut all_schemas: Vec<String> = match existing {
        None => vec![],
        Some(s) if s.is_empty() => vec![],
        Some(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            warn!(error = %e, "schema index JSON malformed; resetting to empty");
            vec![]
        }),
    };

    for name in &contract_keys {
        if !all_schemas.contains(name) {
            all_schemas.push(name.clone());
        }
    }

    // Explicit error handling on the index
    // SET. Pre-fix `let _: RedisResult = …` discarded any error
    // entirely; post-fix logs on Err so failed index writes are
    // visible in observability.
    let index_payload = match serde_json::to_string(&all_schemas) {
        Ok(s) => s,
        Err(e) => {
            warn!(error = %e, "Failed to serialize schema index — index unchanged");
            info!(count = published, "Schema contracts published to ValKey (index write skipped)");
            return published;
        }
    };
    if let Err(e) = redis::cmd("SET")
        .arg(&index_key)
        .arg(&index_payload)
        .query_async::<()>(conn)
        .await
    {
        warn!(key = %index_key, error = %e, "Schema index SET failed");
    }

    info!(count = published, "Schema contracts published to ValKey");
    published
}

/// Synchronous version of `publish` for callers that use `redis::Connection`
/// (e.g., gNode daemon, which is not async at startup).
///
/// Same semantics as `publish()`: idempotent, resolves placeholders,
/// merges into the `_index` discovery key.
// #[must_use] mirroring publish() above.
#[must_use = "publish_sync returns the number of contracts written; check it"]
pub fn publish_sync(
    schemas_dir: &str,
    conn: &mut redis::Connection,
    site_id: &str,
    environment: &str,
) -> usize {
    let dir = match resolve_schemas_dir(schemas_dir) {
        Some(d) => d,
        None => {
            warn!(path = %schemas_dir, "config/schemas/ directory not found");
            return 0;
        }
    };

    let contracts = load_contracts(&dir);
    if contracts.is_empty() {
        info!(dir = %dir.display(), "No schema contracts found");
        return 0;
    }

    let contracts: Vec<StreamContract> = contracts
        .into_iter()
        .map(|mut c| {
            c.stream = c.stream.replace("{site_id}", site_id).replace("{env}", environment);
            c.xadd_example = c.xadd_example.replace("{site_id}", site_id).replace("{env}", environment);
            c
        })
        .collect();

    let mut published = 0;

    for contract in &contracts {
        let key = format!(
            "{}:gnode:schema:{}:{}",
            site_id, contract.component, contract.name
        );

        let json = match serde_json::to_string(contract) {
            Ok(j) => j,
            Err(e) => {
                warn!(contract = %contract.name, error = %e, "Failed to serialize schema");
                continue;
            }
        };

        let result: redis::RedisResult<()> = redis::cmd("SET").arg(&key).arg(&json).query(conn);

        match result {
            Ok(()) => {
                info!(key = %key, "Published schema contract");
                published += 1;
            }
            Err(e) => warn!(key = %key, error = %e, "Failed to publish schema"),
        }
    }

    let index_key = format!("{}:gnode:schema:_index", site_id);
    let contract_keys: Vec<String> = contracts
        .iter()
        .map(|c| format!("{}:{}", c.component, c.name))
        .collect();

    // Same shape as the async path above —
    // distinguish "key absent" from "Redis errored", explicit log on
    // failure, no silent swallowing.
    let existing: Option<String> = match redis::cmd("GET")
        .arg(&index_key)
        .query::<Option<String>>(conn)
    {
        Ok(v) => v,
        Err(e) => {
            warn!(key = %index_key, error = %e, "GET on schema index failed (sync); skipping merge");
            info!(count = published, "Schema contracts published to ValKey (sync, index merge skipped)");
            return published;
        }
    };

    let mut all_schemas: Vec<String> = match existing {
        None => vec![],
        Some(s) if s.is_empty() => vec![],
        Some(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            warn!(error = %e, "schema index JSON malformed (sync); resetting to empty");
            vec![]
        }),
    };

    for name in &contract_keys {
        if !all_schemas.contains(name) {
            all_schemas.push(name.clone());
        }
    }

    let index_payload = match serde_json::to_string(&all_schemas) {
        Ok(s) => s,
        Err(e) => {
            warn!(error = %e, "Failed to serialize schema index (sync) — index unchanged");
            info!(count = published, "Schema contracts published to ValKey (sync, index write skipped)");
            return published;
        }
    };
    if let Err(e) = redis::cmd("SET")
        .arg(&index_key)
        .arg(&index_payload)
        .query::<()>(conn)
    {
        warn!(key = %index_key, error = %e, "Schema index SET failed (sync)");
    }

    info!(count = published, "Schema contracts published to ValKey (sync)");
    published
}

/// Validation error for a stream message against a contract.
#[derive(Debug)]
pub struct ValidationError {
    pub field: String,
    pub reason: String,
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.field, self.reason)
    }
}

/// Validate a set of stream entry fields against a contract.
///
/// Checks that all required fields are present and that field values match
/// expected types. Returns a list of validation errors (empty = valid).
///
/// # Example
///
/// ```rust,ignore
/// let contract = geodineum_schema::load_contracts(Path::new("config/schemas/"))
///     .into_iter()
///     .find(|c| c.name == "outbound_alert")
///     .unwrap();
///
/// let mut fields = std::collections::HashMap::new();
/// fields.insert("id".to_string(), "msg-001".to_string());
/// fields.insert("type".to_string(), "alert".to_string());
/// fields.insert("content".to_string(), r#"{"subject":"test"}"#.to_string());
///
/// let errors = geodineum_schema::validate(&contract, &fields);
/// assert!(errors.is_empty());
/// ```
// #[must_use] so a caller checking schema
// validity can't silently drop the returned errors list.
#[must_use = "validate returns the error list; check it"]
pub fn validate(
    contract: &StreamContract,
    fields: &std::collections::HashMap<String, String>,
) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    for schema_field in &contract.fields {
        let value = fields.get(&schema_field.name);

        // Check required fields
        if schema_field.required && value.is_none() {
            errors.push(ValidationError {
                field: schema_field.name.clone(),
                reason: "required field missing".to_string(),
            });
            continue;
        }

        let value = match value {
            Some(v) => v,
            None => continue, // Optional and absent — fine
        };

        // Type validation
        match schema_field.field_type.as_str() {
            "integer" => {
                if value.parse::<i64>().is_err() {
                    errors.push(ValidationError {
                        field: schema_field.name.clone(),
                        reason: format!("expected integer, got: {}", value),
                    });
                }
            }
            "float" => {
                if value.parse::<f64>().is_err() {
                    errors.push(ValidationError {
                        field: schema_field.name.clone(),
                        reason: format!("expected float, got: {}", value),
                    });
                }
            }
            "boolean" => {
                if !matches!(value.as_str(), "true" | "false" | "0" | "1") {
                    errors.push(ValidationError {
                        field: schema_field.name.clone(),
                        reason: format!("expected boolean, got: {}", value),
                    });
                }
            }
            "json" => {
                if serde_json::from_str::<serde_json::Value>(value).is_err() {
                    errors.push(ValidationError {
                        field: schema_field.name.clone(),
                        reason: "expected valid JSON".to_string(),
                    });
                }
            }
            _ => {} // string, iso8601 — any string is valid
        }

        // Enum validation (pipe-delimited values)
        if let Some(ref allowed) = schema_field.values {
            let valid_values: Vec<&str> = allowed.split('|').collect();
            if !valid_values.contains(&value.as_str()) {
                errors.push(ValidationError {
                    field: schema_field.name.clone(),
                    reason: format!("value '{}' not in allowed set: {}", value, allowed),
                });
            }
        }
    }

    errors
}

/// Try to find the schemas directory, checking multiple paths.
fn resolve_schemas_dir(schemas_dir: &str) -> Option<std::path::PathBuf> {
    let path = Path::new(schemas_dir);
    if path.is_dir() {
        return Some(path.to_path_buf());
    }

    // Try relative to current exe
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidates = [
                parent.join(schemas_dir),
                parent.join("../../").join(schemas_dir),
            ];
            for c in &candidates {
                if c.is_dir() {
                    return Some(c.canonicalize().unwrap_or_else(|_| c.clone()));
                }
            }
        }
    }

    None
}

// ============================================================================
// config_schema surface — Commit 0.5
// ============================================================================
//
// Every Geodineum component + extension ships a single `config_schema.yaml`
// that enumerates the config keys it reads. Keys carry type/default/mutable/
// description/(optional capability) so an operator-facing consumer (e.g., the
// gCore wp-admin panel) can render the whole ecosystem's tunable surface from
// ValKey without ssh-grep.
//
// ValKey keyspace (ecosystem-wide, NOT per-site — config_schema is an
// invariant, not per-site state):
//   HSET geodineum:config_schema:<component> <KEY> <JSON ConfigSchemaEntry>
//   SADD geodineum:config_schema:_index <component>
//
// Shape matches the primer's `CONFIG_SCHEMA_SHAPE` invariant.

/// A single config-key entry within a component's config_schema.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigSchemaEntry {
    pub key: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub default: serde_yaml::Value,
    pub mutable: bool,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capability: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<String>>,
}

/// Top-level shape of a config_schema.yaml file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigSchemaFile {
    pub component: String,
    pub entries: Vec<ConfigSchemaEntry>,
}

/// Load a single config_schema.yaml file from disk.
///
/// Returns Err on I/O failure or parse failure — this is a bootstrap-time
/// read; silent-accept is not appropriate.
pub fn load_config_schema(path: &Path) -> anyhow::Result<ConfigSchemaFile> {
    let contents = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("failed to read {}: {}", path.display(), e))?;
    let parsed: ConfigSchemaFile = serde_yaml::from_str(&contents)
        .map_err(|e| anyhow::anyhow!("failed to parse {} as ConfigSchemaFile: {}", path.display(), e))?;
    if parsed.component.is_empty() {
        anyhow::bail!("config_schema at {} has empty `component` field", path.display());
    }
    Ok(parsed)
}

fn config_schema_key(component: &str) -> String {
    format!("geodineum:config_schema:{}", component)
}

const CONFIG_SCHEMA_INDEX: &str = "geodineum:config_schema:_index";

/// Publish a single component's config_schema to ValKey (async).
///
/// Writes one HSET field per entry into `geodineum:config_schema:<component>`
/// and SADDs the component name into `geodineum:config_schema:_index`.
/// Idempotent — safe to call on every startup.
pub async fn publish_config_schema(
    schema_file: &Path,
    conn: &mut MultiplexedConnection,
) -> anyhow::Result<usize> {
    let file = load_config_schema(schema_file)?;
    let hash_key = config_schema_key(&file.component);

    let mut published = 0;
    for entry in &file.entries {
        let json = serde_json::to_string(entry)
            .map_err(|e| anyhow::anyhow!("serialize entry {}: {}", entry.key, e))?;
        let _: () = redis::cmd("HSET")
            .arg(&hash_key)
            .arg(&entry.key)
            .arg(&json)
            .query_async(conn)
            .await
            .map_err(|e| anyhow::anyhow!("HSET {} {}: {}", hash_key, entry.key, e))?;
        published += 1;
    }

    let _: () = redis::cmd("SADD")
        .arg(CONFIG_SCHEMA_INDEX)
        .arg(&file.component)
        .query_async(conn)
        .await
        .map_err(|e| anyhow::anyhow!("SADD config_schema index: {}", e))?;

    info!(
        component = %file.component,
        count = published,
        "config_schema published to ValKey"
    );
    Ok(published)
}

/// Synchronous variant of `publish_config_schema` for non-async callers
/// (e.g., gNode daemon startup).
pub fn publish_config_schema_sync(
    schema_file: &Path,
    conn: &mut redis::Connection,
) -> anyhow::Result<usize> {
    let file = load_config_schema(schema_file)?;
    let hash_key = config_schema_key(&file.component);

    let mut published = 0;
    for entry in &file.entries {
        let json = serde_json::to_string(entry)
            .map_err(|e| anyhow::anyhow!("serialize entry {}: {}", entry.key, e))?;
        let _: () = redis::cmd("HSET")
            .arg(&hash_key)
            .arg(&entry.key)
            .arg(&json)
            .query(conn)
            .map_err(|e| anyhow::anyhow!("HSET {} {}: {}", hash_key, entry.key, e))?;
        published += 1;
    }

    let _: () = redis::cmd("SADD")
        .arg(CONFIG_SCHEMA_INDEX)
        .arg(&file.component)
        .query(conn)
        .map_err(|e| anyhow::anyhow!("SADD config_schema index: {}", e))?;

    info!(
        component = %file.component,
        count = published,
        "config_schema published to ValKey (sync)"
    );
    Ok(published)
}

/// Fetch a component's config_schema from ValKey (sync).
/// Returns an empty Vec if the component is not in the index.
pub fn fetch_config_schema_sync(
    component: &str,
    conn: &mut redis::Connection,
) -> anyhow::Result<Vec<ConfigSchemaEntry>> {
    let hash_key = config_schema_key(component);
    let raw: std::collections::HashMap<String, String> = redis::cmd("HGETALL")
        .arg(&hash_key)
        .query(conn)
        .map_err(|e| anyhow::anyhow!("HGETALL {}: {}", hash_key, e))?;

    let mut entries = Vec::with_capacity(raw.len());
    for (k, v) in raw {
        match serde_json::from_str::<ConfigSchemaEntry>(&v) {
            Ok(e) => entries.push(e),
            Err(e) => warn!(key = %k, error = %e, "failed to deserialize config_schema entry"),
        }
    }
    Ok(entries)
}

/// Validate a raw string value against a config_schema entry's type/values.
///
/// Intended for consumer-side use (e.g., wp-admin write-back and
/// gNode-Client pre-FCALL). Mirrors the enum/type discipline used by the
/// stream-contract `validate` function but applies to a single key rather
/// than a whole message.
pub fn validate_value_against_schema(
    entry: &ConfigSchemaEntry,
    value: &str,
) -> Result<(), ValidationError> {
    match entry.ty.as_str() {
        "int" | "integer" => {
            if value.parse::<i64>().is_err() {
                return Err(ValidationError {
                    field: entry.key.clone(),
                    reason: format!("expected int, got: {}", value),
                });
            }
        }
        "bool" | "boolean" => {
            if !matches!(value, "true" | "false" | "0" | "1") {
                return Err(ValidationError {
                    field: entry.key.clone(),
                    reason: format!("expected bool, got: {}", value),
                });
            }
        }
        "enum" => {
            let allowed = entry.values.as_ref().ok_or_else(|| ValidationError {
                field: entry.key.clone(),
                reason: "enum type declared without `values` list".to_string(),
            })?;
            if !allowed.iter().any(|a| a == value) {
                return Err(ValidationError {
                    field: entry.key.clone(),
                    reason: format!("value '{}' not in allowed set: {:?}", value, allowed),
                });
            }
        }
        "path" => {
            if value.is_empty() {
                return Err(ValidationError {
                    field: entry.key.clone(),
                    reason: "path type must not be empty".to_string(),
                });
            }
            // We deliberately do NOT check fs-existence here: schemas describe
            // intent at publish-time and are validated against operator-
            // supplied strings at write-back-time; the path may not yet exist.
        }
        // "string" and anything unrecognized: accept any non-empty string.
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::path::Path;

    #[test]
    fn load_comms_contracts() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);

        assert_eq!(contracts.len(), 3, "Expected 3 COMMS contracts");

        let names: Vec<&str> = contracts.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"outbound_alert"));
        assert!(names.contains(&"inbound_command"));
        assert!(names.contains(&"workflow_dispatch"));

        // Check outbound_alert structure
        let alert = contracts.iter().find(|c| c.name == "outbound_alert").unwrap();
        assert_eq!(alert.component, "geodineum_comms");
        assert_eq!(alert.version, "1.0.0");
        assert_eq!(alert.stability, "stable");
        assert!(alert.consumer_group.is_some());
        assert!(alert.fields.len() >= 5);

        // Check field types parsed correctly
        let id_field = alert.fields.iter().find(|f| f.name == "id").unwrap();
        assert_eq!(id_field.field_type, "string");
        assert!(id_field.required);
    }

    #[test]
    fn load_gnode_contracts() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../gNode/config/schemas");
        let contracts = load_contracts(&dir);

        assert_eq!(contracts.len(), 3, "Expected 3 gNode contracts");

        let names: Vec<&str> = contracts.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"unified_command"));
        assert!(names.contains(&"health_metrics"));
        assert!(names.contains(&"broadcast_event"));
    }

    #[test]
    fn load_gcore_contracts() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../gCore/config/schemas/contracts");
        let contracts = load_contracts(&dir);

        assert_eq!(contracts.len(), 2, "Expected 2 gCore contracts");
    }

    #[test]
    fn load_bak_contracts() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-BAK/config/schemas");
        let contracts = load_contracts(&dir);

        assert_eq!(contracts.len(), 1, "Expected 1 BAK contract");
        assert_eq!(contracts[0].name, "backup_event");
    }

    #[test]
    fn validate_valid_message() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);
        let alert = contracts.iter().find(|c| c.name == "outbound_alert").unwrap();

        let mut fields = HashMap::new();
        fields.insert("id".to_string(), "test-001".to_string());
        fields.insert("type".to_string(), "alert".to_string());
        fields.insert("content".to_string(), r#"{"subject":"test","body":"hi"}"#.to_string());

        let errors = validate(alert, &fields);
        assert!(errors.is_empty(), "Valid message should have no errors: {:?}",
            errors.iter().map(|e| format!("{}", e)).collect::<Vec<_>>());
    }

    #[test]
    fn validate_missing_required() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);
        let alert = contracts.iter().find(|c| c.name == "outbound_alert").unwrap();

        let fields = HashMap::new(); // empty — missing id, type, content
        let errors = validate(alert, &fields);

        let missing: Vec<&str> = errors.iter().map(|e| e.field.as_str()).collect();
        assert!(missing.contains(&"id"), "Should flag missing 'id'");
        assert!(missing.contains(&"type"), "Should flag missing 'type'");
        assert!(missing.contains(&"content"), "Should flag missing 'content'");
    }

    #[test]
    fn validate_bad_type() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);
        let alert = contracts.iter().find(|c| c.name == "outbound_alert").unwrap();

        let mut fields = HashMap::new();
        fields.insert("id".to_string(), "test".to_string());
        fields.insert("type".to_string(), "alert".to_string());
        fields.insert("content".to_string(), "not json".to_string()); // bad JSON
        fields.insert("priority".to_string(), "abc".to_string()); // bad integer

        let errors = validate(alert, &fields);
        let error_fields: Vec<&str> = errors.iter().map(|e| e.field.as_str()).collect();
        assert!(error_fields.contains(&"content"), "Should flag bad JSON");
        assert!(error_fields.contains(&"priority"), "Should flag bad integer");
    }

    #[test]
    fn validate_bad_enum() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);
        let alert = contracts.iter().find(|c| c.name == "outbound_alert").unwrap();

        let mut fields = HashMap::new();
        fields.insert("id".to_string(), "test".to_string());
        fields.insert("type".to_string(), "INVALID_TYPE".to_string()); // bad enum
        fields.insert("content".to_string(), r#"{"s":"x"}"#.to_string());

        let errors = validate(alert, &fields);
        let error_fields: Vec<&str> = errors.iter().map(|e| e.field.as_str()).collect();
        assert!(error_fields.contains(&"type"), "Should flag bad enum value");
    }

    #[test]
    fn contracts_serialize_to_json() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Geodineum-COMMS/config/schemas");
        let contracts = load_contracts(&dir);

        for contract in &contracts {
            let json = serde_json::to_string(contract).expect("Should serialize to JSON");
            assert!(json.contains(&contract.name));
            assert!(json.contains(&contract.component));

            // Round-trip: deserialize back
            let rt: StreamContract = serde_json::from_str(&json).expect("Should round-trip");
            assert_eq!(rt.name, contract.name);
            assert_eq!(rt.fields.len(), contract.fields.len());
        }
    }

    // ----- config_schema surface (Commit 0.5) -----

    fn mk_entry(key: &str, ty: &str, mutable: bool, values: Option<Vec<&str>>) -> ConfigSchemaEntry {
        ConfigSchemaEntry {
            key: key.to_string(),
            ty: ty.to_string(),
            default: serde_yaml::Value::Null,
            mutable,
            description: String::new(),
            capability: None,
            values: values.map(|v| v.into_iter().map(|s| s.to_string()).collect()),
        }
    }

    #[test]
    fn config_schema_validate_int() {
        let e = mk_entry("GNODE_THREADS", "int", false, None);
        assert!(validate_value_against_schema(&e, "4").is_ok());
        assert!(validate_value_against_schema(&e, "-1").is_ok());
        assert!(validate_value_against_schema(&e, "not-an-int").is_err());
    }

    #[test]
    fn config_schema_validate_bool() {
        let e = mk_entry("GCORE_DEBUG", "bool", true, None);
        for v in ["true", "false", "0", "1"] {
            assert!(validate_value_against_schema(&e, v).is_ok(), "bool '{}' should be ok", v);
        }
        assert!(validate_value_against_schema(&e, "yes").is_err());
    }

    #[test]
    fn config_schema_validate_enum() {
        let e = mk_entry("GNODE_LOG_LEVEL", "enum", true, Some(vec!["trace", "debug", "info", "warn", "error"]));
        assert!(validate_value_against_schema(&e, "info").is_ok());
        assert!(validate_value_against_schema(&e, "NONE").is_err());

        let bad = mk_entry("X", "enum", true, None);
        assert!(validate_value_against_schema(&bad, "anything").is_err(),
            "enum without values list should be rejected");
    }

    #[test]
    fn config_schema_validate_path() {
        let e = mk_entry("INSTALL_ROOT", "path", false, None);
        assert!(validate_value_against_schema(&e, "/opt/geodineum").is_ok());
        assert!(validate_value_against_schema(&e, "/does/not/exist/yet").is_ok(),
            "path validation does NOT check fs existence");
        assert!(validate_value_against_schema(&e, "").is_err());
    }

    #[test]
    fn config_schema_entry_serde_roundtrip() {
        let e = mk_entry(
            "GNODE_LOG_LEVEL",
            "enum",
            true,
            Some(vec!["trace", "debug", "info", "warn", "error"]),
        );
        let json = serde_json::to_string(&e).unwrap();
        let back: ConfigSchemaEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back.key, "GNODE_LOG_LEVEL");
        assert_eq!(back.ty, "enum");
        assert!(back.mutable);
        assert_eq!(back.values.unwrap().len(), 5);
    }

    #[test]
    fn config_schema_file_parses_yaml() {
        let yaml = r#"
component: gNode
entries:
  - key: GNODE_LOG_LEVEL
    type: enum
    default: info
    mutable: true
    description: "Daemon log verbosity"
    values: [trace, debug, info, warn, error]
  - key: GNODE_PROCESSOR_THREADS
    type: int
    default: 4
    mutable: false
    description: "Worker thread count"
"#;
        let parsed: ConfigSchemaFile = serde_yaml::from_str(yaml).expect("parse");
        assert_eq!(parsed.component, "gNode");
        assert_eq!(parsed.entries.len(), 2);
        assert_eq!(parsed.entries[0].key, "GNODE_LOG_LEVEL");
        assert_eq!(parsed.entries[0].ty, "enum");
        assert!(parsed.entries[0].mutable);
        assert!(parsed.entries[0].values.is_some());
        assert_eq!(parsed.entries[1].ty, "int");
        assert!(!parsed.entries[1].mutable);
    }
}

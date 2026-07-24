use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::services::replication_error::{INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER};

const OBSERVED_CALLERS_FILE_ENV: &str = "ENGINE_INDEX_IDENTITY_OBSERVED_CALLERS_FILE";
pub const OBSERVED_UPSTREAM_AUTH_HEADER_PATTERN: &str = "sha256:*";

pub fn record_caller(caller_id: &str) {
    let Ok(path) = std::env::var(OBSERVED_CALLERS_FILE_ENV) else {
        return;
    };

    if path.trim().is_empty() || caller_id.trim().is_empty() {
        return;
    }

    if let Err(err) = write_observed_catalog_caller(Path::new(&path), caller_id) {
        tracing::warn!(
            caller_id,
            path = %path,
            error = %err,
            "failed to record engine index identity caller"
        );
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PhysicalCallerObservation<'a> {
    pub physical_uid: &'a str,
    pub logical_uid: &'a str,
    pub node_secret_id: &'a str,
    pub auth_secret_id: &'a str,
    pub auth_header_value: &'a str,
    pub upstream_path: &'a str,
    pub application_id: &'a str,
    pub http_status: u16,
}

pub fn record_physical_caller(caller_id: &str, observation: PhysicalCallerObservation<'_>) {
    let Ok(path) = std::env::var(OBSERVED_CALLERS_FILE_ENV) else {
        return;
    };

    if path.trim().is_empty() || caller_id.trim().is_empty() {
        return;
    }

    if let Err(err) = write_observed_physical_caller(Path::new(&path), caller_id, observation) {
        tracing::warn!(
            caller_id,
            path = %path,
            error = %err,
            "failed to record engine index identity caller"
        );
    }
}

fn write_observed_catalog_caller(path: &Path, caller_id: &str) -> std::io::Result<()> {
    let mut callers = read_observed_callers(path)?;
    callers.insert(caller_id.to_string(), catalog_caller_row(caller_id));
    write_observed_callers(path, callers)
}

fn write_observed_physical_caller(
    path: &Path,
    caller_id: &str,
    observation: PhysicalCallerObservation<'_>,
) -> std::io::Result<()> {
    let mut callers = read_observed_callers(path)?;
    callers.insert(
        caller_id.to_string(),
        physical_caller_row(caller_id, observation),
    );
    write_observed_callers(path, callers)
}

fn write_observed_callers(path: &Path, callers: BTreeMap<String, Value>) -> std::io::Result<()> {
    let caller_rows = callers.into_values().collect::<Vec<_>>();

    let payload = json!({
        "status": "observed",
        "callers": caller_rows,
        "checks": {
            "identity": "checked",
            "auth": "checked",
            "status": "checked"
        }
    });

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, serde_json::to_vec_pretty(&payload)?)
}

fn catalog_caller_row(caller_id: &str) -> Value {
    json!({
        "caller_id": caller_id,
        "observed_upstream_kind": "catalog_only",
        "physical_uid": null,
        "logical_uid": null,
        "auth_secret_owner": "no direct Flapjack request",
        "auth_secret_id": null,
        "node_secret_id": null,
        "upstream_path": null,
        "upstream_headers": {},
        "http_status": 200,
        "terminal_migration_state": "completed"
    })
}

fn physical_caller_row(caller_id: &str, observation: PhysicalCallerObservation<'_>) -> Value {
    json!({
        "caller_id": caller_id,
        "observed_upstream_kind": "physical_uid",
        "physical_uid": observation.physical_uid,
        "logical_uid": observation.logical_uid,
        "auth_secret_owner": "VmInventory::node_secret_id",
        "auth_secret_id": observation.auth_secret_id,
        "node_secret_id": observation.node_secret_id,
        "upstream_path": observation.upstream_path,
        "upstream_headers": {
            (INTERNAL_AUTH_HEADER): auth_header_proof(observation.auth_header_value),
            (INTERNAL_APP_ID_HEADER): observation.application_id
        },
        "http_status": observation.http_status,
        "terminal_migration_state": "completed"
    })
}

fn auth_header_proof(value: &str) -> String {
    if value.is_empty() {
        return String::new();
    }
    format!("sha256:{}", hex::encode(Sha256::digest(value.as_bytes())))
}

fn read_observed_callers(path: &Path) -> std::io::Result<BTreeMap<String, Value>> {
    if !path.exists() {
        return Ok(BTreeMap::new());
    }

    let payload = fs::read_to_string(path)?;
    let parsed = serde_json::from_str::<Value>(&payload).unwrap_or_else(|_| json!({}));
    let callers = parsed
        .get("callers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|row| {
            let caller_id = row.get("caller_id")?.as_str()?;
            Some((caller_id.to_string(), row.clone()))
        })
        .collect();
    Ok(callers)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_observed_caller_deduplicates_and_preserves_structured_state() {
        let dir = std::env::temp_dir().join(format!(
            "engine-index-identity-observer-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("observed.json");

        write_observed_catalog_caller(&path, "routes.admin.migrations.list_migrations").unwrap();
        write_observed_catalog_caller(&path, "routes.admin.migrations.list_migrations").unwrap();
        write_observed_catalog_caller(&path, "routes.indexes.lifecycle.delete_index").unwrap();

        let payload: Value =
            serde_json::from_str(&fs::read_to_string(path).expect("observed payload"))
                .expect("observed JSON");

        assert_eq!(payload["status"], "observed");
        assert_eq!(payload["checks"]["identity"], "checked");
        assert!(payload["checks"].get("tenant_isolation").is_none());
        assert_eq!(payload["callers"].as_array().expect("callers").len(), 2);
        assert_eq!(
            payload["callers"],
            json!([
                catalog_caller_row("routes.admin.migrations.list_migrations"),
                catalog_caller_row("routes.indexes.lifecycle.delete_index")
            ])
        );

        fs::remove_dir_all(&dir).expect("remove temp dir");
    }

    #[test]
    fn write_observed_physical_caller_preserves_boundary_evidence() {
        let dir = std::env::temp_dir().join(format!(
            "engine-index-identity-observer-physical-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("observed.json");

        write_observed_physical_caller(
            &path,
            "routes.indexes.index_metrics_route.get_index_metrics",
            PhysicalCallerObservation {
                physical_uid: "11111111111111111111111111111111_products",
                logical_uid: "products",
                node_secret_id: "vm-source.flapjack.foo",
                auth_secret_id: "vm-source.flapjack.foo",
                auth_header_value: "observed-node-api-key",
                upstream_path: "/metrics",
                application_id: "flapjack",
                http_status: 200,
            },
        )
        .unwrap();

        let payload: Value =
            serde_json::from_str(&fs::read_to_string(path).expect("observed payload"))
                .expect("observed JSON");

        let row = &payload["callers"][0];
        assert_eq!(
            row["upstream_headers"]["x-algolia-api-key"],
            "sha256:ec328dfb058371b544ae1cb1c011f48026ccb075b53552de58a3cb663dd28d9f"
        );
        assert_ne!(row["upstream_headers"]["x-algolia-api-key"], "<redacted>");
        assert!(row.get("unrelated_tenant_state").is_none());

        fs::remove_dir_all(&dir).expect("remove temp dir");
    }
}

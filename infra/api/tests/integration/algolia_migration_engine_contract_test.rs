use api::services::algolia_import::{
    AsyncMigrationDisposition, AsyncMigrationPhase, AsyncMigrationStatusResponse,
};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use uuid::Uuid;

const CONTRACT_JSON: &str = include_str!("../fixtures/algolia_migration_engine_contract.json");

fn contract() -> Value {
    serde_json::from_str(CONTRACT_JSON)
        .expect("Algolia migration engine contract fixture is valid JSON")
}

fn strings_at<'a>(value: &'a Value, path: &[&str]) -> Vec<&'a str> {
    value
        .pointer(&format!("/{}", path.join("/")))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("fixture path /{} must be an array", path.join("/")))
        .iter()
        .map(|item| {
            item.as_str().unwrap_or_else(|| {
                panic!("fixture path /{} must contain only strings", path.join("/"))
            })
        })
        .collect()
}

fn valid_status_json() -> Value {
    serde_json::json!({
        "jobId": "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
        "phase": "exporting",
        "disposition": "running",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "exportProgress": {"completed": 1, "total": 2}
    })
}

#[test]
fn algolia_migration_engine_contract_fixture_pins_engine_and_artifacts() {
    let contract = contract();

    assert_eq!(
        contract["pinned_engine_sha"],
        "a025a5eb43025b0680cfc78e5e07ec6c052695a4"
    );

    let artifacts = contract["openapi_artifacts"]
        .as_array()
        .expect("openapi_artifacts must be an array");
    assert_eq!(artifacts.len(), 2);
    assert_eq!(artifacts[0]["path"], "engine/docs2/openapi.json");
    assert_eq!(
        artifacts[1]["path"],
        "engine/demo-dualclient/public/openapi.json"
    );
    for artifact in artifacts {
        assert_eq!(
            artifact["sha256"],
            "a17c29c127813a4ad8e8c7a80667eb44edff63a7f05feb700bd077b88833d637"
        );
    }
}

#[test]
fn algolia_migration_engine_contract_fixture_closes_routes_and_wire_sets() {
    let contract = contract();

    assert_eq!(contract["routes"]["submit"]["method"], "POST");
    assert_eq!(
        contract["routes"]["submit"]["path"],
        "/1/migrations/algolia"
    );
    assert_eq!(contract["routes"]["status"]["method"], "GET");
    assert_eq!(
        contract["routes"]["status"]["path"],
        "/1/migrations/algolia/{job_id}"
    );
    assert_eq!(contract["routes"]["cancel"]["method"], "POST");
    assert_eq!(
        contract["routes"]["cancel"]["path"],
        "/1/migrations/algolia/{job_id}/cancel"
    );
    assert_eq!(
        strings_at(&contract, &["request", "required_fields"]),
        ["apiKey", "appId", "sourceIndex"]
    );
    assert_eq!(
        strings_at(&contract, &["request", "optional_fields"]),
        ["overwrite", "targetIndex"]
    );
    assert_eq!(
        strings_at(&contract, &["status", "required_fields"]),
        ["createdAt", "disposition", "jobId", "phase", "updatedAt"]
    );
    assert_eq!(
        strings_at(&contract, &["status", "optional_fields"]),
        ["exportProgress", "terminalAt"]
    );
    assert_eq!(
        strings_at(&contract, &["progress", "required_fields"]),
        ["completed", "total"]
    );
    assert_eq!(
        strings_at(&contract, &["progress", "optional_fields"]),
        Vec::<&str>::new()
    );
}

#[test]
fn algolia_migration_engine_contract_fixture_has_no_privacy_scrub_transport() {
    let contract = contract();
    let expected_routes = json!({
        "submit": {
            "method": "POST",
            "path": "/1/migrations/algolia"
        },
        "status": {
            "method": "GET",
            "path": "/1/migrations/algolia/{job_id}"
        },
        "cancel": {
            "method": "POST",
            "path": "/1/migrations/algolia/{job_id}/cancel"
        }
    });

    assert_eq!(
        contract["routes"], expected_routes,
        "the pinned migration-family route set must remain submit, status, and cancel only"
    );

    let normalized_routes = contract["routes"].to_string().to_ascii_lowercase();
    for forbidden in ["scrub", "tombstone", "erase", "delete"] {
        assert!(
            !normalized_routes.contains(forbidden),
            "the pinned migration-family route set must not claim a {forbidden} transport"
        );
    }
}

#[test]
fn algolia_migration_engine_contract_fixture_closes_enums_and_errors() {
    let contract = contract();

    assert_eq!(
        strings_at(&contract, &["enums", "phase"]),
        [
            "submitted",
            "exporting",
            "preparing",
            "staging",
            "activating"
        ]
    );
    assert_eq!(
        strings_at(&contract, &["enums", "disposition"]),
        ["running", "succeeded", "failed", "cancelled"]
    );

    let errors = contract["errors"]
        .as_object()
        .expect("errors must be an object");
    assert_eq!(errors.len(), 4);
    assert_eq!(errors["migration_ha_unsupported"]["http_status"], 503);
    assert_eq!(errors["migration_capacity_exhausted"]["http_status"], 503);
    assert_eq!(errors["migration_job_not_found"]["http_status"], 404);
    assert_eq!(errors["cancel_too_late"]["http_status"], 409);
}

#[test]
fn algolia_migration_engine_contract_fixture_decodes_only_its_closed_status_schema() {
    let contract = contract();
    let phases = AsyncMigrationPhase::ALL.map(|phase| {
        serde_json::to_value(phase)
            .expect("serialize phase")
            .as_str()
            .expect("phase wire value")
            .to_string()
    });
    let dispositions = AsyncMigrationDisposition::ALL.map(|disposition| {
        serde_json::to_value(disposition)
            .expect("serialize disposition")
            .as_str()
            .expect("disposition wire value")
            .to_string()
    });
    assert_eq!(
        phases.as_slice(),
        strings_at(&contract, &["enums", "phase"])
    );
    assert_eq!(
        dispositions.as_slice(),
        strings_at(&contract, &["enums", "disposition"])
    );

    let mut response = valid_status_json();
    assert!(serde_json::from_value::<AsyncMigrationStatusResponse>(response.clone()).is_ok());
    response["fixtureGrowthMustFail"] = serde_json::json!(true);
    assert!(serde_json::from_value::<AsyncMigrationStatusResponse>(response).is_err());
}

#[test]
fn algolia_migration_engine_contract_fixture_covers_all_typed_status_arms() {
    for phase in strings_at(&contract(), &["enums", "phase"]) {
        let mut response = valid_status_json();
        response["phase"] = serde_json::json!(phase);
        let decoded: AsyncMigrationStatusResponse =
            serde_json::from_value(response).expect("fixture phase must decode");
        let _: Uuid = decoded.job_id;
        let _: DateTime<Utc> = decoded.created_at;
        let _: DateTime<Utc> = decoded.updated_at;
    }

    for disposition in strings_at(&contract(), &["enums", "disposition"]) {
        let mut response = valid_status_json();
        response["disposition"] = serde_json::json!(disposition);
        if disposition != "running" {
            response["terminalAt"] = serde_json::json!("2026-07-22T00:00:02Z");
        }
        if disposition == "succeeded" {
            response["phase"] = serde_json::json!("activating");
        }
        let decoded: AsyncMigrationStatusResponse =
            serde_json::from_value(response).expect("fixture disposition must decode");
        assert_eq!(decoded.terminal_at.is_some(), disposition != "running");
    }

    let mut without_progress = valid_status_json();
    without_progress
        .as_object_mut()
        .expect("status object")
        .remove("exportProgress");
    let decoded: AsyncMigrationStatusResponse =
        serde_json::from_value(without_progress).expect("optional progress may be absent");
    assert_eq!(decoded.export_progress, None);
}

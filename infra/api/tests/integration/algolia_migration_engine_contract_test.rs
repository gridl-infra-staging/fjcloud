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

#[test]
fn route_credential_canaries_never_enter_engine_contract_fixture() {
    for canary in [
        "secret-api-key-canary-success",
        "temporary-secret-key-that-must-not-leak",
        "source-name-canary-that-must-not-enter-logs",
        "cancel-customer-credential-canary",
        "fresh-refused-key",
    ] {
        assert!(
            !CONTRACT_JSON.contains(canary),
            "route credential canary must not enter the engine fixture: {canary}"
        );
    }
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

fn successful_terminal_status_with_outcome() -> Value {
    serde_json::json!({
        "jobId": "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
        "phase": "activating",
        "disposition": "succeeded",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "terminalAt": "2026-07-22T00:00:02Z",
        "settingsApplied": true,
        "synonymsImported": {"imported": 3},
        "rulesImported": {"imported": 6},
        "warnings": [{
            "code": "unsupported_synonym_type",
            "message": "Skipped one synonym",
            "resource": "synonyms",
            "pageIndex": 2,
            "itemIndex": 5,
            "jsonPath": "$.synonyms[5]"
        }]
    })
}

#[test]
fn algolia_migration_engine_contract_fixture_pins_engine_and_artifacts() {
    let contract = contract();
    let pinned_engine_sha = contract["pinned_engine_sha"]
        .as_str()
        .expect("pinned_engine_sha must be a string");

    assert_eq!(
        pinned_engine_sha.len(),
        40,
        "the fixture must carry one 40-character pinned engine SHA"
    );
    assert!(
        pinned_engine_sha
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()),
        "the pinned engine SHA must be lowercase hex"
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
    let first_sha256 = artifacts[0]["sha256"]
        .as_str()
        .expect("first OpenAPI artifact sha256 must be a string");
    let second_sha256 = artifacts[1]["sha256"]
        .as_str()
        .expect("second OpenAPI artifact sha256 must be a string");
    for checksum in [first_sha256, second_sha256] {
        assert_eq!(
            checksum.len(),
            64,
            "each OpenAPI artifact checksum must be a 64-character sha256"
        );
        assert!(
            checksum
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()),
            "artifact checksum must be lowercase hex"
        );
    }
    assert_eq!(
        first_sha256, second_sha256,
        "the duplicated OpenAPI artifacts must stay byte-identical"
    );
}

#[test]
fn algolia_migration_engine_contract_fixture_closes_routes_and_wire_sets() {
    let contract = contract();

    assert_eq!(
        contract["required_runtime_routes"]["acknowledge"]["method"],
        "POST"
    );
    assert_eq!(
        contract["required_runtime_routes"]["acknowledge"]["path"],
        "/1/migrations/algolia/{job_id}/acknowledge"
    );
    assert_eq!(
        contract["acknowledgement_contract"],
        json!({
            "operation_id": "acknowledge_algolia_migration",
            "authentication": {
                "required": true,
                "security_scheme": "api_key"
            },
            "request": {
                "path_parameters": ["job_id"],
                "body": "none"
            },
            "engine_behavior": "idempotent_no_op_terminal_receipt",
            "responses": {
                "success": {
                    "http_status": 204,
                    "description": "Terminal migration acknowledged"
                },
                "invalid_uuid": {
                    "http_status": 400,
                    "description": "Invalid migration job UUID"
                },
                "missing_job": {
                    "http_status": 404,
                    "description": "No durable migration phase record is currently retained for the UUID"
                },
                "too_early": {
                    "http_status": 409,
                    "description": "migration_ack_too_early"
                },
                "read_failure": {
                    "http_status": 500,
                    "description": "Migration status record could not be read"
                }
            },
        }),
        "ACK route presence is not enough; the fixture must pin the authenticated no-op receipt semantics that the merged engine publishes"
    );
    assert_eq!(
        contract["privacy_scrub_known_answer"],
        json!({
            "command": [
                "bash",
                "scripts/update_algolia_migration_engine_contract.sh",
                "--check"
            ],
            "working_directory": ".",
            "success_marker":
                "privacy-scrub transport receipt: PASS"
        }),
        "the dependency gate must execute the engine-owned privacy-scrub proof without pinning the unrelated whole-suite count"
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
        [
            "exportProgress",
            "rulesImported",
            "settingsApplied",
            "synonymsImported",
            "terminalAt",
            "warnings"
        ]
    );
    assert_eq!(
        contract["status_outcome"],
        json!({
            "fields": [
                "rulesImported",
                "settingsApplied",
                "synonymsImported",
                "warnings"
            ],
            "settingsApplied": {
                "type": ["boolean", "null"]
            },
            "synonymsImported": {
                "ref": "#/components/schemas/MigrateCount",
                "nullable": true
            },
            "rulesImported": {
                "ref": "#/components/schemas/MigrateCount",
                "nullable": true
            },
            "warnings": {
                "type": "array",
                "items_ref": "#/components/schemas/MigrateWarning"
            }
        }),
        "fixture must preserve current-main terminal-only outcome fields"
    );
    assert_eq!(
        contract["count"],
        json!({
            "required_fields": ["imported"],
            "optional_fields": [],
            "field_types": {
                "imported": ["integer"]
            }
        })
    );
    assert_eq!(
        contract["warning"],
        json!({
            "required_fields": ["code", "jsonPath", "message", "resource"],
            "optional_fields": ["itemIndex", "pageIndex"],
            "field_types": {
                "code": ["string"],
                "itemIndex": ["integer", "null"],
                "jsonPath": ["string"],
                "message": ["string"],
                "pageIndex": ["integer", "null"],
                "resource": ["string"]
            }
        })
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
fn algolia_migration_engine_contract_fixture_closes_provider_discriminator_and_shared_lifecycle() {
    let contract = contract();
    let transport_owner = include_str!("../../src/services/flapjack_proxy/migration.rs");

    assert_eq!(
        contract["provider_discriminator"],
        json!({
            "field": "source_provider",
            "values": ["algolia"]
        }),
        "the source-provider discriminator must remain a closed set"
    );
    assert_eq!(
        contract["routes"],
        json!({
            "submit": {
                "method": "POST",
                "path": "/1/migrations/{source_provider}"
            },
            "status": {
                "method": "GET",
                "path": "/1/migrations/{source_provider}/{job_id}"
            },
            "cancel": {
                "method": "POST",
                "path": "/1/migrations/{source_provider}/{job_id}/cancel"
            },
            "acknowledge": {
                "method": "POST",
                "path": "/1/migrations/{source_provider}/{job_id}/acknowledge"
            }
        }),
        "all providers must share one lifecycle route-role map"
    );
    assert_eq!(
        contract["provider_aliases"],
        json!({
            "algolia": {
                "submit": "/1/migrations/algolia",
                "status": "/1/migrations/algolia/{job_id}",
                "cancel": "/1/migrations/algolia/{job_id}/cancel",
                "acknowledge": "/1/migrations/algolia/{job_id}/acknowledge"
            }
        }),
        "the existing Algolia wire must remain an explicit compatibility alias"
    );
    assert!(
        transport_owner.contains("fn migration_url(")
            && transport_owner.contains("async fn submit_migration(")
            && transport_owner.contains("async fn migration_status(")
            && transport_owner.contains("async fn cancel_migration(")
            && transport_owner.contains("async fn acknowledge_migration("),
        "the fixture's shared lifecycle map must have one provider-neutral transport owner"
    );
    assert!(
        !transport_owner.contains("/1/migrations/algolia"),
        "legacy Algolia transport aliases must pass the provider discriminator into the shared URL builder"
    );
    for preserved_key in [
        "request",
        "status",
        "status_outcome",
        "errors",
        "privacy_scrub_contract",
        "privacy_scrub_known_answer",
    ] {
        assert!(
            contract[preserved_key].is_object(),
            "{preserved_key} must remain in the provider-discriminated fixture"
        );
    }
}

#[test]
fn algolia_migration_engine_contract_fixture_pins_authenticated_privacy_scrub_transport() {
    let contract = contract();

    assert_eq!(
        contract["privacy_scrub_contract"]["route"],
        json!({
            "method": "POST",
            "path": "/1/migrations/privacy-scrub",
            "operation_id": "submit_privacy_scrub",
            "security_scheme": "private_migration"
        }),
        "fixture must pin the authenticated private scrub transport route"
    );
    assert_eq!(
        strings_at(
            &contract,
            &["privacy_scrub_contract", "request", "required_fields"]
        ),
        ["expectedGeneration", "scrubId", "tenant"]
    );
    assert_eq!(
        strings_at(
            &contract,
            &["privacy_scrub_contract", "request", "optional_fields"]
        ),
        ["objectIDs", "ruleIDs", "synonymIDs"]
    );
    assert_eq!(
        contract["privacy_scrub_contract"]["request"]["property_types"],
        json!({
            "expectedGeneration": { "type": "string" },
            "objectIDs": { "type": "array", "items": "string" },
            "ruleIDs": { "type": "array", "items": "string" },
            "scrubId": { "type": "string" },
            "synonymIDs": { "type": "array", "items": "string" },
            "tenant": { "type": "string" }
        }),
        "scrub request must pin each field's wire type, including array item types"
    );
    assert_eq!(
        contract["privacy_scrub_contract"]["ack"],
        json!({
            "http_status": 202,
            "schema": "PrivacyScrubAck",
            "required_fields": ["disposition", "scrubId"],
            "optional_fields": [],
            "property_types": {
                "disposition": { "type": "string" },
                "scrubId": { "type": "string" }
            }
        }),
        "scrub delivery must close over the engine ACK response shape and wire types"
    );
    assert_eq!(
        contract["privacy_scrub_contract"]["receipt"],
        json!({
            "path": "engine/docs2/4_EVIDENCE/privacy_scrub_transport_receipt.json",
            "validated_head_sha": "c14fd322842c42cf2527616a69f708257194a9ef",
            "scrub_implementation_sha": "674f243579e2f31ce15a00c8f79d8a98842c7659",
            "boundary_variants": [
                "PreIntent",
                "PostIntent",
                "EngineCommit",
                "PreAck",
                "ResponseLoss",
                "Restart",
                "AckReplay"
            ],
            "auth_negative_cases": [
                "missing credentials",
                "wrong credentials",
                "incomplete app material",
                "ordinary admin credentials"
            ],
            "exact_absence_resource_classes": [
                "objectIDs",
                "synonymIDs",
                "ruleIDs"
            ]
        }),
        "fixture must carry the F10E receipt denominator that cloud replay tests consume"
    );
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

    let decoded: AsyncMigrationStatusResponse =
        serde_json::from_value(successful_terminal_status_with_outcome())
            .expect("successful terminal outcome should decode");
    assert_eq!(decoded.settings_applied, Some(true));
    assert_eq!(decoded.synonyms_imported.unwrap().imported, 3);
    assert_eq!(decoded.rules_imported.unwrap().imported, 6);
    assert_eq!(decoded.warnings.unwrap().len(), 1);
}

#[test]
fn algolia_migration_engine_contract_fixture_enforces_terminal_outcome_legality() {
    let contract = contract();
    let phases = strings_at(&contract, &["enums", "phase"]);
    let dispositions = strings_at(&contract, &["enums", "disposition"]);

    for phase in &phases {
        for disposition in &dispositions {
            let is_terminal = *disposition != "running";
            let mut response = valid_status_json();
            response["phase"] = serde_json::json!(phase);
            response["disposition"] = serde_json::json!(disposition);
            if is_terminal {
                response["terminalAt"] = serde_json::json!("2026-07-22T00:00:02Z");
            }
            let result = serde_json::from_value::<AsyncMigrationStatusResponse>(response);
            if *disposition == "succeeded" && *phase != "activating" {
                assert!(
                    result.is_err(),
                    "succeeded must require activating phase, got {phase}"
                );
            } else if *disposition == "running" {
                assert!(
                    result.is_ok(),
                    "running+{phase} must decode (resume=false: non-terminal is valid in-flight)"
                );
                assert_eq!(result.unwrap().terminal_at, None);
            } else {
                assert!(
                    result.is_ok(),
                    "terminal disposition {disposition}+{phase} must decode"
                );
                assert!(
                    result.unwrap().terminal_at.is_some(),
                    "terminal disposition must carry terminalAt"
                );
            }
        }
    }

    let mut running_with_terminal = valid_status_json();
    running_with_terminal["terminalAt"] = serde_json::json!("2026-07-22T00:00:02Z");
    assert!(
        serde_json::from_value::<AsyncMigrationStatusResponse>(running_with_terminal).is_err(),
        "running disposition must reject terminalAt (resume=false: terminal is final)"
    );
}

#[test]
fn algolia_migration_engine_contract_fixture_closes_top_level_schema() {
    let contract = contract();
    let keys: Vec<&str> = contract
        .as_object()
        .expect("fixture must be an object")
        .keys()
        .map(String::as_str)
        .collect();

    let expected_keys = [
        "acknowledgement_contract",
        "count",
        "enums",
        "errors",
        "openapi_artifacts",
        "pinned_engine_sha",
        "privacy_scrub_contract",
        "privacy_scrub_known_answer",
        "progress",
        "provider_aliases",
        "provider_discriminator",
        "request",
        "required_runtime_routes",
        "routes",
        "status",
        "status_outcome",
        "warning",
    ];
    let mut sorted_keys = keys.clone();
    sorted_keys.sort_unstable();
    assert_eq!(
        sorted_keys, expected_keys,
        "fixture top-level keys must be exactly the closed set; unknown growth is rejected"
    );
}

#[test]
fn algolia_migration_engine_contract_privacy_scrub_rejects_wrong_auth_scheme() {
    let contract = contract();
    assert_eq!(
        contract["privacy_scrub_contract"]["route"]["security_scheme"], "private_migration",
        "privacy scrub must use private_migration, not api_key or public"
    );
    assert_ne!(
        contract["privacy_scrub_contract"]["route"]["security_scheme"],
        contract["acknowledgement_contract"]["authentication"]["security_scheme"],
        "privacy scrub auth must differ from the public terminal ACK auth scheme"
    );
}

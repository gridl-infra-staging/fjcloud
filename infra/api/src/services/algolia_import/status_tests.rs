use serde_json::json;

use super::AsyncMigrationStatusResponse;
use crate::models::algolia_import_job::{
    MAX_ALGOLIA_IMPORT_WARNINGS, MAX_ALGOLIA_IMPORT_WARNING_CODE_BYTES,
    MAX_ALGOLIA_IMPORT_WARNING_JSON_PATH_BYTES, MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES,
    MAX_ALGOLIA_IMPORT_WARNING_RESOURCE_BYTES,
};

fn valid_status_response() -> serde_json::Value {
    json!({
        "jobId": "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
        "phase": "exporting",
        "disposition": "running",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z",
        "exportProgress": {"completed": 10, "total": 25}
    })
}

fn successful_terminal_status_with_outcome() -> serde_json::Value {
    json!({
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

fn assert_status_rejected(
    mut response: serde_json::Value,
    mutate: impl FnOnce(&mut serde_json::Value),
    context: &str,
) {
    mutate(&mut response);
    assert!(
        serde_json::from_value::<AsyncMigrationStatusResponse>(response).is_err(),
        "{context} must be rejected"
    );
}

#[test]
fn successful_terminal_status_accepts_complete_outcome() {
    let decoded: AsyncMigrationStatusResponse =
        serde_json::from_value(successful_terminal_status_with_outcome())
            .expect("successful terminal outcome should decode");

    assert_eq!(decoded.settings_applied, Some(true));
    assert_eq!(decoded.synonyms_imported.unwrap().imported, 3);
    assert_eq!(decoded.rules_imported.unwrap().imported, 6);
    let warnings = decoded
        .warnings
        .expect("warning vector should be preserved");
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].code, "unsupported_synonym_type");
    assert_eq!(warnings[0].message, "Skipped one synonym");
    assert_eq!(warnings[0].resource, "synonyms");
    assert_eq!(warnings[0].page_index, Some(2));
    assert_eq!(warnings[0].item_index, Some(5));
    assert_eq!(warnings[0].json_path, "$.synonyms[5]");
}

#[test]
fn legacy_success_without_outcome_remains_accepted_without_synthesis() {
    let mut response = successful_terminal_status_with_outcome();
    for field in [
        "settingsApplied",
        "synonymsImported",
        "rulesImported",
        "warnings",
    ] {
        response.as_object_mut().unwrap().remove(field);
    }

    let decoded: AsyncMigrationStatusResponse =
        serde_json::from_value(response).expect("legacy success should decode");
    assert_eq!(decoded.settings_applied, None);
    assert_eq!(decoded.synonyms_imported, None);
    assert_eq!(decoded.rules_imported, None);
    assert_eq!(decoded.warnings, None);
}

#[test]
fn outcome_fields_are_rejected_before_successful_terminal_publication() {
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| {
            value["phase"] = json!("activating");
            value["disposition"] = json!("running");
            value.as_object_mut().unwrap().remove("terminalAt");
        },
        "running status with outcome fields",
    );
    for disposition in ["failed", "cancelled"] {
        assert_status_rejected(
            successful_terminal_status_with_outcome(),
            |value| value["disposition"] = json!(disposition),
            "non-success terminal status with outcome fields",
        );
    }
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| {
            value.as_object_mut().unwrap().remove("settingsApplied");
            value.as_object_mut().unwrap().remove("synonymsImported");
            value.as_object_mut().unwrap().remove("rulesImported");
        },
        "warning-only outcome field",
    );
}

#[test]
fn successful_outcome_requires_terminal_at() {
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| {
            value.as_object_mut().unwrap().remove("terminalAt");
        },
        "successful outcome without terminalAt",
    );
}

#[test]
fn partial_settings_synonym_rule_bundles_are_rejected() {
    for field in ["settingsApplied", "synonymsImported", "rulesImported"] {
        assert_status_rejected(
            successful_terminal_status_with_outcome(),
            |value| {
                value.as_object_mut().unwrap().remove(field);
            },
            "partial terminal outcome bundle",
        );
    }
}

#[test]
fn nested_outcome_shapes_are_closed() {
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| value["synonymsImported"]["imported"] = json!("3"),
        "malformed count",
    );
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| value["settingsApplied"] = serde_json::Value::Null,
        "null settings field",
    );
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| value["warnings"] = serde_json::Value::Null,
        "null warning field",
    );
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| value["rulesImported"]["rejected"] = json!(1),
        "unknown count field",
    );
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| value["warnings"][0]["unknownField"] = json!(true),
        "unknown warning field",
    );
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| {
            value["warnings"][0]
                .as_object_mut()
                .unwrap()
                .remove("jsonPath");
        },
        "missing required warning jsonPath",
    );
}

#[test]
fn terminal_outcome_warning_bounds_fail_closed() {
    assert_status_rejected(
        successful_terminal_status_with_outcome(),
        |value| {
            let warning = value["warnings"][0].clone();
            value["warnings"] = json!(vec![warning; MAX_ALGOLIA_IMPORT_WARNINGS + 1]);
        },
        "warning array above the item limit",
    );

    for (field, limit) in [
        ("code", MAX_ALGOLIA_IMPORT_WARNING_CODE_BYTES),
        ("message", MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES),
        ("resource", MAX_ALGOLIA_IMPORT_WARNING_RESOURCE_BYTES),
        ("jsonPath", MAX_ALGOLIA_IMPORT_WARNING_JSON_PATH_BYTES),
    ] {
        assert_status_rejected(
            successful_terminal_status_with_outcome(),
            |value| value["warnings"][0][field] = json!("x".repeat(limit + 1)),
            "warning string above its byte limit",
        );
    }

    let mut boundary = successful_terminal_status_with_outcome();
    boundary["warnings"][0]["code"] = json!("x".repeat(MAX_ALGOLIA_IMPORT_WARNING_CODE_BYTES));
    boundary["warnings"][0]["message"] =
        json!("x".repeat(MAX_ALGOLIA_IMPORT_WARNING_MESSAGE_BYTES));
    boundary["warnings"][0]["resource"] =
        json!("x".repeat(MAX_ALGOLIA_IMPORT_WARNING_RESOURCE_BYTES));
    boundary["warnings"][0]["jsonPath"] =
        json!("x".repeat(MAX_ALGOLIA_IMPORT_WARNING_JSON_PATH_BYTES));
    serde_json::from_value::<AsyncMigrationStatusResponse>(boundary)
        .expect("warnings exactly at each bound must remain accepted");
}

#[test]
fn status_response_rejects_every_unpinned_or_contradictory_shape() {
    assert_status_rejected(
        valid_status_response(),
        |value| value["unpublishedField"] = json!(true),
        "unknown response field",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["exportProgress"]["unpublishedField"] = json!(true),
        "unknown progress field",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["jobId"] = json!("not-a-uuid"),
        "invalid job UUID",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["createdAt"] = json!("not-a-timestamp"),
        "invalid timestamp",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["updatedAt"] = json!("2026-07-21T23:59:59Z"),
        "updated time before created time",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["exportProgress"] = json!({"completed": 26, "total": 25}),
        "completed progress above total",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["terminalAt"] = json!("2026-07-22T00:00:02Z"),
        "running response with terminal time",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| {
            value["disposition"] = json!("failed");
            value["terminalAt"] = json!("2026-07-22T00:00:00Z");
        },
        "terminal time before updated time",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["disposition"] = json!("failed"),
        "terminal disposition without terminal time",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| {
            value["disposition"] = json!("succeeded");
            value["terminalAt"] = json!("2026-07-22T00:00:02Z");
        },
        "success before activation",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["phase"] = json!("unpublished_phase"),
        "unknown phase",
    );
    assert_status_rejected(
        valid_status_response(),
        |value| value["disposition"] = json!("unpublished_disposition"),
        "unknown disposition",
    );
}

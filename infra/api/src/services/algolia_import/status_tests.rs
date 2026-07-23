use serde_json::json;

use super::AsyncMigrationStatusResponse;

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

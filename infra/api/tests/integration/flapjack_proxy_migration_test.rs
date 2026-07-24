use crate::common::flapjack_proxy_test_support::setup;
use api::services::algolia_import::{
    AlgoliaImportService, AlgoliaImportSubmitRequest, AsyncMigrationDisposition,
    AsyncMigrationPhase, AsyncMigrationStatusResponse, EngineTarget,
};
use serde_json::json;
use std::sync::Arc;

#[tokio::test]
async fn async_algolia_migration_methods_use_authenticated_admin_transport() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    let service = AlgoliaImportService::new(Arc::new(proxy));
    let upstream = json!({
        "jobId": "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
        "phase": "submitted",
        "disposition": "running",
        "createdAt": "2026-07-22T00:00:00Z",
        "updatedAt": "2026-07-22T00:00:01Z"
    });
    http.push_json_response(202, upstream.clone());
    http.expect_sensitive_json_body(
        r#"{"appId":"app","apiKey":"key","sourceIndex":"products","overwrite":false}"#,
    );

    let submit = service
        .submit(
            EngineTarget::new("https://vm-a1.flapjack.foo", "node-1", "us-east-1"),
            AlgoliaImportSubmitRequest::new(
                "app".to_string(),
                zeroize::Zeroizing::new("key".to_string()),
                "products".to_string(),
                None,
                false,
            ),
        )
        .await
        .expect("submit should decode");
    assert_eq!(submit.phase, AsyncMigrationPhase::Submitted);
    assert_eq!(submit.disposition, AsyncMigrationDisposition::Running);

    let requests = http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/migrations/algolia"
    );
    assert_eq!(requests[0].api_key, api_key);

    http.push_json_response(200, upstream.clone());
    let _: AsyncMigrationStatusResponse = service
        .status(
            EngineTarget::new("https://vm-a1.flapjack.foo/", "node-1", "us-east-1"),
            "engine job/1",
        )
        .await
        .expect("status should decode");
    let requests = http.take_requests();
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/migrations/algolia/engine%20job%2F1"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);

    http.push_json_response(200, upstream);
    let _: AsyncMigrationStatusResponse = service
        .cancel(
            EngineTarget::new("https://vm-a1.flapjack.foo", "node-1", "us-east-1"),
            "engine-job-1",
        )
        .await
        .expect("cancel should decode");
    let requests = http.take_requests();
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(
        requests[1].url,
        "https://vm-a1.flapjack.foo/1/migrations/algolia/engine-job-1/cancel"
    );
    assert_eq!(requests[1].api_key, api_key);
    assert_eq!(requests[1].json_body, None);

    http.push_text_response(204, "");
    service
        .acknowledge(
            EngineTarget::new("https://vm-a1.flapjack.foo", "node-1", "us-east-1"),
            "engine-job-1",
        )
        .await
        .expect("acknowledge should accept a successful empty response");
    let requests = http.take_requests();
    assert_eq!(requests[2].method, reqwest::Method::POST);
    assert_eq!(
        requests[2].url,
        "https://vm-a1.flapjack.foo/1/migrations/algolia/engine-job-1/acknowledge"
    );
    assert_eq!(requests[2].api_key, api_key);
    assert_eq!(requests[2].json_body, None);
}

#[tokio::test]
async fn async_algolia_migration_acknowledge_rejects_non_success_status() {
    let (http, _, proxy) = setup().await;
    let service = AlgoliaImportService::new(Arc::new(proxy));
    http.push_json_response(409, json!({"code": "ack_conflict"}));

    let error = service
        .acknowledge(
            EngineTarget::new("https://vm-a1.flapjack.foo", "node-1", "us-east-1"),
            "engine-job-1",
        )
        .await
        .expect_err("acknowledge must reject non-2xx responses");

    assert!(format!("{error}").contains("HTTP 409"));
}

use crate::common::flapjack_proxy_test_support::setup;
use api::models::SourceImportProvider;
use api::services::algolia_import::{
    AlgoliaImportService, AlgoliaImportSubmitRequest, AsyncMigrationDisposition,
    AsyncMigrationPhase, AsyncMigrationStatusResponse, EngineTarget,
};
use api::services::flapjack_proxy::{ProxyError, SourceIndexDiscoveryRequest};
use serde_json::json;
use std::sync::Arc;

async fn assert_hosted_discovery_proxy_request(
    provider: SourceImportProvider,
    expected_url: &str,
    offset: Option<u64>,
    limit: Option<u64>,
    body: serde_json::Value,
) {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    let engine_response = json!({
        "indexes": [{
            "name": format!("{}_products", provider.as_str()),
            "documentCount": 42
        }],
        "offset": offset,
        "limit": limit,
        "total": 19
    });
    let body_text = body.to_string();
    http.expect_sensitive_json_body(&body_text);
    http.push_sensitive_json_response(200, engine_response.clone());

    let response = proxy
        .list_source_indexes(
            "https://vm-a1.flapjack.foo/",
            "node-1",
            "us-east-1",
            SourceIndexDiscoveryRequest::new(provider, offset, limit, &body_text),
        )
        .await
        .expect("source discovery should preserve neutral engine JSON");

    assert_eq!(response, engine_response);
    let requests = http.take_sensitive_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, expected_url);
    assert_eq!(requests[0].api_key, api_key);
}

#[tokio::test]
async fn hosted_discovery_proxy_sends_exact_provider_urls_with_pagination() {
    assert_hosted_discovery_proxy_request(
        SourceImportProvider::Meilisearch,
        "https://vm-a1.flapjack.foo/1/migrations/meilisearch/list-indexes?offset=7&limit=2",
        Some(7),
        Some(2),
        json!({
            "endpoint": "https://meili.example",
            "apiKey": "meili-source-key"
        }),
    )
    .await;

    assert_hosted_discovery_proxy_request(
        SourceImportProvider::Typesense,
        "https://vm-a1.flapjack.foo/1/migrations/typesense/list-indexes?offset=7&limit=2",
        Some(7),
        Some(2),
        json!({
            "node": "https://typesense.example",
            "apiKey": "typesense-source-key"
        }),
    )
    .await;
}

#[tokio::test]
async fn hosted_discovery_proxy_omits_empty_pagination_query() {
    assert_hosted_discovery_proxy_request(
        SourceImportProvider::Meilisearch,
        "https://vm-a1.flapjack.foo/1/migrations/meilisearch/list-indexes",
        None,
        None,
        json!({
            "endpoint": "https://meili.example",
            "apiKey": "meili-source-key"
        }),
    )
    .await;

    assert_hosted_discovery_proxy_request(
        SourceImportProvider::Typesense,
        "https://vm-a1.flapjack.foo/1/migrations/typesense/list-indexes",
        None,
        None,
        json!({
            "node": "https://typesense.example",
            "apiKey": "typesense-source-key"
        }),
    )
    .await;
}

#[tokio::test]
async fn hosted_discovery_proxy_preserves_pagination_above_u32_max() {
    // Stage 1 publishes non-negative int64 pagination and the producer accepts
    // u64; a value above u32::MAX must render exactly, not truncate or reject.
    let above_u32_offset = u64::from(u32::MAX) + 1; // 4294967296
    let above_u32_limit = u64::from(u32::MAX) + 5; // 4294967300
    assert_hosted_discovery_proxy_request(
        SourceImportProvider::Meilisearch,
        "https://vm-a1.flapjack.foo/1/migrations/meilisearch/list-indexes?offset=4294967296&limit=4294967300",
        Some(above_u32_offset),
        Some(above_u32_limit),
        json!({
            "endpoint": "https://meili.example",
            "apiKey": "meili-source-key"
        }),
    )
    .await;
}

#[tokio::test]
async fn hosted_discovery_proxy_maps_engine_errors_to_flapjack_error() {
    let (http, _, proxy) = setup().await;
    let body = json!({
        "endpoint": "https://meili.example",
        "apiKey": "meili-source-key"
    });
    let body_text = body.to_string();
    http.expect_sensitive_json_body(&body_text);
    http.push_sensitive_json_response(503, json!({"code": "source_unavailable"}));

    let error = proxy
        .list_source_indexes(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            SourceIndexDiscoveryRequest::new(
                SourceImportProvider::Meilisearch,
                Some(7),
                Some(2),
                &body_text,
            ),
        )
        .await
        .expect_err("non-200 discovery response must stay an engine error");

    assert!(matches!(
        error,
        ProxyError::FlapjackError {
            status: 503,
            ref message
        } if message == "{\"code\":\"source_unavailable\"}"
    ));
}

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
            "9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb",
        )
        .await
        .expect("cancel should decode");
    let requests = http.take_requests();
    assert_eq!(requests[1].method, reqwest::Method::POST);
    assert_eq!(
        requests[1].url,
        "https://vm-a1.flapjack.foo/1/migrations/algolia/9f11d0a0-4443-44d4-b6c6-1ed71dbeb0fb/cancel"
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

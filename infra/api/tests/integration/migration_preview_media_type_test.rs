use std::sync::Arc;

use api::models::vm_inventory::NewVmInventory;
use api::models::AlgoliaImportErrorCode;
use api::repos::VmInventoryRepo;
use api::router::build_router;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

use crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use crate::common::{create_test_jwt, mock_repo, mock_vm_inventory_repo, TestStateBuilder};

fn preview_request() -> Value {
    json!({
        "appId": "PREVIEWAPP123",
        "apiKey": "temporary-preview-key",
        "sourceIndex": "products"
    })
}

fn preview_response() -> Value {
    json!({
        "sourceCounts": {
            "indexes": 2,
            "records": 42
        },
        "report": {
            "summary": {
                "totalEntries": 1,
                "hardRejections": 0,
                "warnings": 1,
                "scopeGaps": 0
            },
            "entries": [{
                "severity": "Warning",
                "code": "UnsupportedSourceField",
                "resource": "Settings",
                "jsonPath": "$.settings.attributesForFaceting[0]",
                "pageIndex": null,
                "itemIndex": 0
            }],
            "reportDigest": "sha256:preview-report"
        }
    })
}

async fn setup_preview_app() -> (axum::Router, String, Arc<MockFlapjackHttpClient>) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-preview.flapjack.test".to_string(),
            flapjack_url: "https://vm-preview.flapjack.test".to_string(),
            capacity: json!({ "disk_bytes": 10_000_000_000_i64 }),
        })
        .await
        .expect("seed active preview VM");
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key(vm.node_secret_id(), &vm.region)
        .await
        .expect("seed preview VM node secret");
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        flapjack_http.clone(),
        node_secret_manager,
    ));
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_flapjack_proxy(flapjack_proxy)
        .with_algolia_migration_enabled(true)
        .build();

    (
        build_router(state),
        create_test_jwt(customer.id),
        flapjack_http,
    )
}

async fn response_json(response: axum::response::Response) -> (StatusCode, Value) {
    let status = response.status();
    let body = response
        .into_body()
        .collect()
        .await
        .expect("collect response body")
        .to_bytes();
    let value = serde_json::from_slice(&body).unwrap_or_else(|error| {
        panic!(
            "response body must be JSON: {error}: {}",
            String::from_utf8_lossy(&body)
        )
    });
    (status, value)
}

async fn post_preview(
    app: axum::Router,
    jwt: &str,
    content_type: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(http::Method::POST)
        .uri("/migration/algolia/preview")
        .header("authorization", format!("Bearer {jwt}"));
    if let Some(content_type) = content_type {
        request = request.header("content-type", content_type);
    }
    let response = app
        .oneshot(
            request
                .body(Body::from(body.to_string()))
                .expect("build preview request"),
        )
        .await
        .expect("preview response");
    response_json(response).await
}

#[tokio::test]
async fn preview_rejects_text_plain_before_proxying_to_engine() {
    let (app, jwt, flapjack_http) = setup_preview_app().await;

    let (status, body) = post_preview(app, &jwt, Some("text/plain"), preview_request()).await;

    assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(
        body,
        json!({
            "error": "content_type_must_be_application_json",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

#[tokio::test]
async fn preview_rejects_missing_content_type_before_proxying_to_engine() {
    let (app, jwt, flapjack_http) = setup_preview_app().await;

    let (status, body) = post_preview(app, &jwt, None, preview_request()).await;

    assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(
        body,
        json!({
            "error": "content_type_must_be_application_json",
            "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
        })
    );
    assert_eq!(flapjack_http.request_count(), 0);
    assert!(flapjack_http.take_sensitive_requests().is_empty());
}

#[tokio::test]
async fn preview_accepts_json_with_charset_and_preserves_engine_report() {
    let (app, jwt, flapjack_http) = setup_preview_app().await;
    let request_body = preview_request();
    let expected_response = preview_response();
    flapjack_http.expect_sensitive_json_body(&request_body.to_string());
    flapjack_http.push_sensitive_json_response(200, expected_response);

    let (status, body) = post_preview(
        app,
        &jwt,
        Some("application/json; charset=utf-8"),
        request_body,
    )
    .await;

    assert_eq!(status, StatusCode::OK, "preview body: {body}");
    assert_eq!(body["sourceCounts"]["indexes"], 2);
    assert_eq!(body["report"]["summary"]["totalEntries"], 1);
}

#[tokio::test]
async fn preview_accepts_well_formed_application_json_and_preserves_source_counts() {
    let (app, jwt, flapjack_http) = setup_preview_app().await;
    let request_body = preview_request();
    let expected_response = preview_response();
    flapjack_http.expect_sensitive_json_body(&request_body.to_string());
    flapjack_http.push_sensitive_json_response(200, expected_response);

    let (status, body) = post_preview(app, &jwt, Some("application/json"), request_body).await;

    assert_eq!(status, StatusCode::OK, "preview body: {body}");
    assert_eq!(body["sourceCounts"]["records"], 42);
    assert_eq!(
        body["report"]["entries"][0]["code"],
        "UnsupportedSourceField"
    );
}

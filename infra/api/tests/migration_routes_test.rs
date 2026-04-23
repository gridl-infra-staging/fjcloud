mod common;

use std::sync::Arc;

use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::flapjack_proxy_test_support::{setup, MockFlapjackHttpClient};
use common::indexes_route_test_support::response_json;
use common::{create_test_jwt, mock_deployment_repo, mock_repo, TestStateBuilder};
use serde_json::json;
use tower::ServiceExt;

use api::router::build_router;
use api::secrets::NodeSecretManager;

/// Build an app with a customer who has a provisioned deployment with a flapjack_url.
/// Reuses flapjack_proxy_test_support::setup() for proxy components.
async fn setup_with_eligible_deployment() -> (axum::Router, String, Arc<MockFlapjackHttpClient>) {
    let (http_client, _ssm, proxy) = setup().await;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    // setup() creates a key for "node-1" / "us-east-1", so use that node_id
    deployment_repo.seed_provisioned(
        customer.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-m1.flapjack.foo"),
    );

    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_flapjack_proxy(Arc::new(proxy))
            .build(),
    );

    (app, jwt, http_client)
}

// ---------------------------------------------------------------------------
// Auth required
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_requires_auth() {
    let (app, _jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("content-type", "application/json")
                .body(Body::from(json!({"appId": "X", "apiKey": "Y"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// POST /migration/algolia/list-indexes — validation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_rejects_non_object_json() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from("[1, 2, 3]"))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("JSON object"), "got: {err}");
}

#[tokio::test]
async fn algolia_list_indexes_rejects_missing_app_id() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"apiKey": "secret"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("appId"), "got: {err}");
}

#[tokio::test]
async fn algolia_list_indexes_rejects_non_string_app_id() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"appId": 123, "apiKey": "secret"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("appId"), "got: {err}");
}

#[tokio::test]
async fn algolia_list_indexes_rejects_missing_api_key() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"appId": "X"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("apiKey"), "got: {err}");
}

#[tokio::test]
async fn algolia_list_indexes_rejects_non_string_api_key() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"appId": "X", "apiKey": true}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("apiKey"), "got: {err}");
}

// ---------------------------------------------------------------------------
// POST /migration/algolia/migrate — validation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_migrate_rejects_non_object_json() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from("[1, 2, 3]"))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("JSON object"), "got: {err}");
}

#[tokio::test]
async fn algolia_migrate_rejects_missing_app_id() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"apiKey": "secret", "sourceIndex": "products"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("appId"), "got: {err}");
}

#[tokio::test]
async fn algolia_migrate_rejects_missing_source_index() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"appId": "X", "apiKey": "secret"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("sourceIndex"), "got: {err}");
}

#[tokio::test]
async fn algolia_migrate_rejects_non_string_source_index() {
    let (app, jwt, _http_client) = setup_with_eligible_deployment().await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({"appId": "X", "apiKey": "secret", "sourceIndex": 42}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("sourceIndex"), "got: {err}");
}

// ---------------------------------------------------------------------------
// 503 when no eligible deployment
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_returns_503_when_no_deployment() {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let customer = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let jwt = create_test_jwt(customer.id);

    // No deployments seeded — customer has no eligible deployment
    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .build(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"appId": "X", "apiKey": "Y"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.contains("deployment"), "got: {err}");
}

// ---------------------------------------------------------------------------
// Deployment fallback: skips newer deployment without flapjack_url
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_skips_deployment_without_flapjack_url() {
    let (http_client, ssm, proxy) = setup().await;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();

    let customer = customer_repo.seed_verified_free_customer("Carol", "carol@example.com");
    let jwt = create_test_jwt(customer.id);

    // setup() already created key for "node-1"; add one for the eligible deployment
    ssm.create_node_api_key("node-old", "us-east-1")
        .await
        .unwrap();

    // Seed the eligible deployment (older, has flapjack_url)
    deployment_repo.seed_provisioned(
        customer.id,
        "node-old",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-old.flapjack.foo"),
    );

    // Seed a newer deployment WITHOUT flapjack_url (should be skipped)
    deployment_repo.seed_provisioned(
        customer.id,
        "node-new",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
        None,
    );

    let upstream = json!({"items": []});
    http_client.push_json_response(200, upstream.clone());

    let app = build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_deployment_repo(deployment_repo)
            .with_flapjack_proxy(Arc::new(proxy))
            .build(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({"appId": "X", "apiKey": "Y"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);

    // Verify the request went to the old (eligible) deployment
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert!(
        requests[0].url.contains("vm-old.flapjack.foo"),
        "should use eligible deployment, got: {}",
        requests[0].url
    );
}

// ---------------------------------------------------------------------------
// Success paths
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_success() {
    let (app, jwt, http_client) = setup_with_eligible_deployment().await;

    let upstream = json!({
        "items": [{"name": "products", "entries": 100}]
    });
    http_client.push_json_response(200, upstream.clone());

    let body = json!({"appId": "APP123", "apiKey": "algolia-key"});

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/list-indexes")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, resp_body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(resp_body, upstream);

    // Verify the body was forwarded to the proxy
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].json_body, Some(body));
}

#[tokio::test]
async fn algolia_migrate_success() {
    let (app, jwt, http_client) = setup_with_eligible_deployment().await;

    let upstream = json!({"taskID": 42, "status": "started"});
    http_client.push_json_response(200, upstream.clone());

    let body = json!({
        "appId": "APP123",
        "apiKey": "algolia-key",
        "sourceIndex": "products"
    });

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/migration/algolia/migrate")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, resp_body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(resp_body, upstream);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].json_body, Some(body));
}

mod common;

use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::indexes_route_test_support::{response_json, setup_ready_index};
use serde_json::json;
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// GET /indexes/:name/security/sources — list
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_security_sources_returns_upstream_json() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    let upstream = json!({
        "sources": [
            {"source": "192.168.1.0/24", "description": "Office"}
        ]
    });
    http_client.push_json_response(200, upstream.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/security/sources")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);
}

// ---------------------------------------------------------------------------
// POST /indexes/:name/security/sources — append
// ---------------------------------------------------------------------------

#[tokio::test]
async fn append_security_source_success() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    let upstream = json!({"createdAt": "2026-03-19T00:00:00Z"});
    http_client.push_json_response(200, upstream.clone());

    let source_body = json!({"source": "10.0.0.0/8", "description": "Internal"});

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/security/sources")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(source_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].json_body, Some(source_body));
}

#[tokio::test]
async fn append_security_source_rejects_non_object_json() {
    let (app, jwt, _http_client, _customer_id) = setup_ready_index("products").await;

    // Send a JSON array instead of an object
    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/security/sources")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from("[\"192.168.1.0/24\"]"))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body.get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("")
            .contains("JSON object"),
        "error message should mention JSON object, got: {body}"
    );
}

// ---------------------------------------------------------------------------
// DELETE /indexes/:name/security/sources/:source — delete
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_security_source_success() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    let upstream = json!({"deletedAt": "2026-03-19T00:00:00Z"});
    http_client.push_json_response(200, upstream.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/security/sources/10.0.0.1")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);
}

#[tokio::test]
async fn delete_security_source_percent_encodes_cidr_source_for_upstream() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    let upstream = json!({"deletedAt": "2026-03-19T00:00:00Z"});
    http_client.push_json_response(200, upstream.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/security/sources/192.168.1.0%2F24")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, upstream);

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/security/sources/192.168.1.0%2F24"
    );
}

// ---------------------------------------------------------------------------
// Unknown index → 404
// ---------------------------------------------------------------------------

#[tokio::test]
async fn security_sources_returns_404_for_unknown_index() {
    let (app, jwt, _http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/nonexistent/security/sources")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

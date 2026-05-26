mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{create_test_jwt, mock_api_key_repo, mock_repo, MockApiKeyRepo, MockCustomerRepo};
use http_body_util::BodyExt;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use api::repos::api_key_repo::ApiKeyRepo;
use api::router::build_router;
use api::state::AppState;

fn test_state_with_api_keys(
    customer_repo: Arc<MockCustomerRepo>,
    api_key_repo: Arc<MockApiKeyRepo>,
) -> AppState {
    let mut state = common::test_state_with_repo(customer_repo);
    state.api_key_repo = api_key_repo;
    state
}

async fn body_json(body: Body) -> serde_json::Value {
    let bytes = body.collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn create_returns_key_only_once() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let api_key_repo = mock_api_key_repo();
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "Production Key",
                "scopes": ["indexes:read", "indexes:write"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["name"], "Production Key");
    let key_str = json["key"].as_str().unwrap();
    assert!(key_str.starts_with("fjc_live_"));
    assert_eq!(key_str.len(), 41); // fjc_live_ (9) + 32 hex chars
    let issued_prefix = &key_str[..16];
    let key_prefix = json["key_prefix"].as_str().unwrap();
    assert_eq!(key_prefix.len(), 16);
    assert!(key_prefix.starts_with("fjc_live_"));
    assert_eq!(key_prefix, issued_prefix);
    assert!(json["id"].is_string());
    assert_eq!(
        json["scopes"],
        serde_json::json!(["indexes:read", "indexes:write"])
    );

    // Listing does NOT return the full key
    let customer_id = customer.id;
    let keys = api_key_repo.list_by_customer(customer_id).await.unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].key_prefix, issued_prefix);
    // key_hash is present but serialization skips it
    let serialized = serde_json::to_value(&keys[0]).unwrap();
    assert!(serialized.get("key_hash").is_none()); // #[serde(skip_serializing)]
}

#[tokio::test]
async fn create_and_list_round_trip_managed_key_parity_fields() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Parity User", "parity@example.com");
    let api_key_repo = mock_api_key_repo();
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let expires_at = "2030-01-02T03:04:05Z";
    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "Managed Search Key",
                "description": "Managed key for storefront search",
                "indexes": ["products", "catalog"],
                "restrict_sources": ["10.0.0.0/8", "192.168.1.0/24"],
                "expires_at": expires_at,
                "max_hits_per_query": 120,
                "max_queries_per_ip_per_hour": 5000,
                "scopes": ["indexes:read", "indexes:write"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let create_resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(create_resp.status(), StatusCode::CREATED);
    let created_json = body_json(create_resp.into_body()).await;
    assert_eq!(
        created_json["description"],
        serde_json::json!("Managed key for storefront search")
    );
    assert_eq!(
        created_json["indexes"],
        serde_json::json!(["products", "catalog"])
    );
    assert_eq!(
        created_json["restrict_sources"],
        serde_json::json!(["10.0.0.0/8", "192.168.1.0/24"])
    );
    assert_eq!(created_json["expires_at"], serde_json::json!(expires_at));
    assert_eq!(created_json["max_hits_per_query"], serde_json::json!(120));
    assert_eq!(
        created_json["max_queries_per_ip_per_hour"],
        serde_json::json!(5000)
    );

    let stored = api_key_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(stored.len(), 1);
    assert_eq!(
        stored[0].description.as_deref(),
        Some("Managed key for storefront search")
    );
    assert_eq!(stored[0].indexes, vec!["products", "catalog"]);
    assert_eq!(
        stored[0].restrict_sources,
        vec!["10.0.0.0/8", "192.168.1.0/24"]
    );
    assert_eq!(
        stored[0].expires_at,
        Some(
            chrono::DateTime::parse_from_rfc3339(expires_at)
                .unwrap()
                .with_timezone(&chrono::Utc),
        )
    );
    assert_eq!(stored[0].max_hits_per_query, Some(120));
    assert_eq!(stored[0].max_queries_per_ip_per_hour, Some(5000));

    let list_req = Request::builder()
        .method("GET")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let list_resp = app.oneshot(list_req).await.unwrap();
    assert_eq!(list_resp.status(), StatusCode::OK);
    let list_json = body_json(list_resp.into_body()).await;
    let keys = list_json.as_array().unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(
        keys[0]["description"],
        serde_json::json!("Managed key for storefront search")
    );
    assert_eq!(
        keys[0]["indexes"],
        serde_json::json!(["products", "catalog"])
    );
    assert_eq!(
        keys[0]["restrict_sources"],
        serde_json::json!(["10.0.0.0/8", "192.168.1.0/24"])
    );
    assert_eq!(keys[0]["expires_at"], serde_json::json!(expires_at));
    assert_eq!(keys[0]["max_hits_per_query"], serde_json::json!(120));
    assert_eq!(
        keys[0]["max_queries_per_ip_per_hour"],
        serde_json::json!(5000)
    );
}

#[tokio::test]
async fn create_rejects_non_positive_managed_key_limits() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Limits User", "limits@example.com");
    let api_key_repo = mock_api_key_repo();
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "Managed Search Key",
                "scopes": ["indexes:read"],
                "max_hits_per_query": 0,
                "max_queries_per_ip_per_hour": -5
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp.into_body()).await;
    assert_eq!(json["error"], serde_json::json!("max_hits_per_query must be at least 1"));
    let stored = api_key_repo.list_by_customer(customer.id).await.unwrap();
    assert!(stored.is_empty());
}

#[tokio::test]
async fn list_returns_keys_without_secrets() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let api_key_repo = mock_api_key_repo();
    api_key_repo.seed(
        customer.id,
        "Key 1",
        "hash1",
        "fj_live_",
        vec!["read".into()],
    );
    api_key_repo.seed(
        customer.id,
        "Key 2",
        "hash2",
        "fj_live_",
        vec!["write".into()],
    );
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(customer_repo, api_key_repo));

    let req = Request::builder()
        .method("GET")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp.into_body()).await;
    let keys = json.as_array().unwrap();
    assert_eq!(keys.len(), 2);

    // No key or key_hash in list response
    for key in keys {
        assert!(key.get("key").is_none());
        assert!(key.get("key_hash").is_none());
    }
}

#[tokio::test]
async fn delete_revokes_key() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let api_key_repo = mock_api_key_repo();
    let key = api_key_repo.seed(
        customer.id,
        "Key 1",
        "hash1",
        "fj_live_",
        vec!["read".into()],
    );
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/api-keys/{}", key.id))
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Key is now revoked
    let found = api_key_repo.find_by_id(key.id).await.unwrap().unwrap();
    assert!(found.revoked_at.is_some());
}

#[tokio::test]
async fn delete_other_customers_key_returns_404() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("User A", "a@example.com");
    let customer_b = customer_repo.seed("User B", "b@example.com");
    let api_key_repo = mock_api_key_repo();
    let key_b = api_key_repo.seed(
        customer_b.id,
        "B's Key",
        "hash1",
        "fj_live_",
        vec!["read".into()],
    );
    let token_a = create_test_jwt(customer_a.id);

    let app = build_router(test_state_with_api_keys(customer_repo, api_key_repo));

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/api-keys/{}", key_b.id))
        .header("authorization", format!("Bearer {token_a}"))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn unauthorized_without_auth() {
    let app = build_router(common::test_state());

    for (method, uri) in [("GET", "/api-keys"), ("POST", "/api-keys")] {
        let req = Request::builder()
            .method(method)
            .uri(uri)
            .header("content-type", "application/json")
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/api-keys/{}", Uuid::new_v4()))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn scopes_stored_correctly() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let api_key_repo = mock_api_key_repo();
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "Admin Key",
                "scopes": ["indexes:read", "indexes:write", "keys:manage"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp.into_body()).await;
    assert_eq!(
        json["scopes"],
        serde_json::json!(["indexes:read", "indexes:write", "keys:manage"])
    );

    // Also verify in storage
    let keys = api_key_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(
        keys[0].scopes,
        vec!["indexes:read", "indexes:write", "keys:manage"]
    );
}

#[tokio::test]
async fn create_issues_fjc_live_prefix() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Test User", "test@example.com");
    let api_key_repo = mock_api_key_repo();
    let token = create_test_jwt(customer.id);

    let app = build_router(test_state_with_api_keys(
        customer_repo,
        api_key_repo.clone(),
    ));

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "Flapjack Cloud Key",
                "scopes": ["search"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp.into_body()).await;
    let key = json["key"].as_str().unwrap();
    assert!(
        key.starts_with("fjc_live_"),
        "new keys must use fjc_live_ prefix, got: {key}"
    );
    assert_eq!(key.len(), 41); // fjc_live_ (9) + 32 hex chars

    let prefix = json["key_prefix"].as_str().unwrap();
    assert_eq!(prefix.len(), 16);
    assert!(prefix.starts_with("fjc_live_"));
    assert_eq!(prefix, &key[..16]);

    let keys = api_key_repo.list_by_customer(customer.id).await.unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].key_prefix.len(), 16);
    assert!(keys[0].key_prefix.starts_with("fjc_live_"));
    assert_eq!(keys[0].key_prefix, &key[..16]);
}

/// API key names exceeding 128 chars should be rejected.
#[tokio::test]
async fn create_rejects_name_exceeding_max_length() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed("User", "user@example.com");
    let token = create_test_jwt(customer.id);
    let api_key_repo = mock_api_key_repo();
    let state = test_state_with_api_keys(customer_repo, api_key_repo);
    let app = build_router(state);
    let long_name = "a".repeat(129);

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": long_name,
                "scopes": ["search"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// API key names must not be empty.
#[tokio::test]
async fn create_rejects_empty_name() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed("User", "user@example.com");
    let token = create_test_jwt(customer.id);
    let api_key_repo = mock_api_key_repo();
    let state = test_state_with_api_keys(customer_repo, api_key_repo);
    let app = build_router(state);

    let req = Request::builder()
        .method("POST")
        .uri("/api-keys")
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_string(&serde_json::json!({
                "name": "",
                "scopes": ["search"]
            }))
            .unwrap(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

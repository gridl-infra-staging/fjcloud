//! Cross-tenant isolation tests for index route families not yet covered by
//! `indexes_test.rs`. Each case proves that a foreign tenant (Bob) gets `404`
//! and zero flapjack proxy requests when accessing an index owned by Alice.
//!
//! Covered here: settings, search, dictionaries, suggestions,
//! personalization, recommendations, chat.
//! Already covered in `indexes_test.rs`: rules, synonyms, analytics,
//! experiments, debug, documents.

mod common;

use std::sync::Arc;

use api::repos::tenant_repo::TenantRepo;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

use common::{
    create_test_jwt, flapjack_proxy_test_support::MockFlapjackHttpClient, mock_deployment_repo,
    mock_repo, mock_tenant_repo, mock_vm_inventory_repo, test_app_with_indexes_and_vm_inventory,
};

// ---------------------------------------------------------------------------
// Shared harness: Alice-owned ready index + Bob JWT + router
// ---------------------------------------------------------------------------

struct CrossTenantHarness {
    app: axum::Router,
    bob_jwt: String,
    http_client: Arc<MockFlapjackHttpClient>,
}

/// Seed Alice's ready index and return Bob's JWT + the router.
/// Every test reuses this single setup to avoid fixture duplication.
async fn setup_cross_tenant() -> CrossTenantHarness {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
    let _alice_jwt = create_test_jwt(alice.id);
    let bob_jwt = create_test_jwt(bob.id);

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        alice.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-test.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(alice.id, "alice-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(alice.id, "alice-index", vm.id)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));
    let app = test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo,
    );

    CrossTenantHarness {
        app,
        bob_jwt,
        http_client,
    }
}

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

impl CrossTenantHarness {
    /// Assert Bob gets 404 and no proxy requests for the given method/URI/body.
    /// Optional headers let callers mirror route-specific fixtures without
    /// per-route request setup branches.
    async fn assert_foreign_tenant_blocked(
        &self,
        method: http::Method,
        uri: &str,
        body: Option<Value>,
        extra_headers: &[(&str, &str)],
    ) {
        let mut builder = Request::builder()
            .method(method.clone())
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.bob_jwt));

        for (header_name, header_value) in extra_headers {
            builder = builder.header(*header_name, *header_value);
        }

        let req_body = match body {
            Some(ref json_val) => {
                builder = builder.header("content-type", "application/json");
                Body::from(json_val.to_string())
            }
            None => Body::empty(),
        };

        let resp = self
            .app
            .clone()
            .oneshot(builder.body(req_body).unwrap())
            .await
            .unwrap();

        let (status, resp_body) = response_json(resp).await;
        let label = format!("{method} {uri}");
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{label}: expected 404, got {status}"
        );
        assert!(
            resp_body["error"]
                .as_str()
                .unwrap_or_default()
                .contains("not found"),
            "{label}: error body should contain 'not found', got: {resp_body}"
        );
        assert_eq!(
            self.http_client.take_requests().len(),
            0,
            "{label}: no proxy requests should be made for foreign tenant"
        );
    }
}

// ===========================================================================
// Classic route-family tests: settings, search, dictionaries, suggestions
// ===========================================================================

// ---- Settings ----

#[tokio::test]
async fn classic_settings_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/settings",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_settings_put_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::PUT,
        "/indexes/alice-index/settings",
        Some(json!({
            "searchableAttributes": ["title"],
            "filterableAttributes": ["category"]
        })),
        &[],
    )
    .await;
}

// ---- Search ----

#[tokio::test]
async fn classic_search_post_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::POST,
        "/indexes/alice-index/search",
        Some(json!({"query": "laptop", "page": 0, "hitsPerPage": 10})),
        &[],
    )
    .await;
}

// ---- Dictionaries ----

#[tokio::test]
async fn classic_dictionaries_languages_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/dictionaries/languages",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_dictionaries_search_post_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::POST,
        "/indexes/alice-index/dictionaries/stopwords/search",
        Some(json!({"query": "", "language": "en"})),
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_dictionaries_batch_post_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::POST,
        "/indexes/alice-index/dictionaries/stopwords/batch",
        Some(json!({
            "clearExistingDictionaryEntries": false,
            "requests": [{"action": "addEntry", "body": {"objectID": "s1", "language": "en", "word": "the"}}]
        })),
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_dictionaries_settings_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/dictionaries/settings",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_dictionaries_settings_put_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::PUT,
        "/indexes/alice-index/dictionaries/settings",
        Some(json!({"disableStandardEntries": true, "customNormalization": false})),
        &[],
    )
    .await;
}

// ---- Suggestions ----

#[tokio::test]
async fn classic_suggestions_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/suggestions",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_suggestions_put_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::PUT,
        "/indexes/alice-index/suggestions",
        Some(json!({
            "sourceIndices": [{"indexName": "alice-index", "minHits": 5, "minLetters": 4}],
            "languages": ["en"],
            "exclude": [],
            "allowSpecialCharacters": false,
            "enablePersonalization": false
        })),
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_suggestions_delete_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::DELETE,
        "/indexes/alice-index/suggestions",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn classic_suggestions_status_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/suggestions/status",
        None,
        &[],
    )
    .await;
}

// ===========================================================================
// AI route-family tests: personalization, recommendations, chat
// ===========================================================================

// ---- Personalization: strategy ----

#[tokio::test]
async fn ai_personalization_strategy_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/personalization/strategy",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn ai_personalization_strategy_put_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::PUT,
        "/indexes/alice-index/personalization/strategy",
        Some(json!({
            "eventsScoring": [{"eventName": "Product viewed", "eventType": "view", "score": 50}],
            "facetsScoring": [{"facetName": "category", "score": 80}],
            "personalizationImpact": 75
        })),
        &[],
    )
    .await;
}

#[tokio::test]
async fn ai_personalization_strategy_delete_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::DELETE,
        "/indexes/alice-index/personalization/strategy",
        None,
        &[],
    )
    .await;
}

// ---- Personalization: profiles ----

#[tokio::test]
async fn ai_personalization_profile_get_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::GET,
        "/indexes/alice-index/personalization/profiles/user-token-1",
        None,
        &[],
    )
    .await;
}

#[tokio::test]
async fn ai_personalization_profile_delete_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::DELETE,
        "/indexes/alice-index/personalization/profiles/user-token-1",
        None,
        &[],
    )
    .await;
}

// ---- Recommendations ----

#[tokio::test]
async fn ai_recommendations_post_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::POST,
        "/indexes/alice-index/recommendations",
        Some(json!({
            "requests": [{"indexName": "alice-index", "objectID": "sku-1", "maxRecommendations": 3}]
        })),
        &[],
    )
    .await;
}

// ---- Chat ----

#[tokio::test]
async fn ai_chat_post_blocked_for_foreign_tenant() {
    let h = setup_cross_tenant().await;
    h.assert_foreign_tenant_blocked(
        http::Method::POST,
        "/indexes/alice-index/chat",
        Some(json!({"query": "hello"})),
        &[("accept", "application/json")],
    )
    .await;
}

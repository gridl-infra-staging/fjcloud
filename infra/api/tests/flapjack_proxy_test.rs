#[path = "common/mod.rs"]
mod common;

use std::sync::Arc;
use std::time::Duration;

use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::access_tracker::AccessTracker;
use api::services::flapjack_proxy::{FlapjackProxy, ProxyError};
use common::flapjack_proxy_test_support::{setup, MockFlapjackHttpClient};
use serde_json::json;
use uuid::Uuid;

#[tokio::test]
async fn create_index_sends_correct_request() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    http.push_json_response(200, json!({"uid": "my-index"}));

    let flapjack_url = "https://vm-a1.flapjack.foo";
    let result = proxy
        .create_index(flapjack_url, "node-1", "us-east-1", "my-index")
        .await;

    assert!(result.is_ok(), "create_index should succeed: {result:?}");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, format!("{flapjack_url}/1/indexes"));
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(json!({"uid": "my-index"})));
}

#[tokio::test]
async fn delete_index_sends_correct_request() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    http.push_text_response(200, "");

    let flapjack_url = "https://vm-a1.flapjack.foo";
    let result = proxy
        .delete_index(flapjack_url, "node-1", "us-east-1", "my-index")
        .await;

    assert!(result.is_ok(), "delete_index should succeed: {result:?}");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!("{flapjack_url}/1/indexes/my-index")
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn list_indexes_parses_response() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(
        200,
        json!({
            "items": [
                {
                    "name": "products",
                    "entries": 1500,
                    "dataSize": 204800,
                    "fileSize": 512000,
                    "createdAt": "2026-02-01T00:00:00Z",
                    "updatedAt": "2026-02-20T12:00:00Z"
                },
                {
                    "name": "users",
                    "entries": 300,
                    "dataSize": 51200,
                    "fileSize": 102400,
                    "createdAt": "2026-02-10T00:00:00Z",
                    "updatedAt": "2026-02-20T12:00:00Z"
                }
            ],
            "nbPages": 1
        }),
    );

    let indexes = proxy
        .list_indexes("https://vm-a1.flapjack.foo", "node-1", "us-east-1")
        .await
        .expect("list_indexes should succeed");

    assert_eq!(indexes.len(), 2);
    assert_eq!(indexes[0].name, "products");
    assert_eq!(indexes[0].entries, 1500);
    assert_eq!(indexes[0].data_size, 204800);
    assert_eq!(indexes[0].file_size, 512000);
    assert_eq!(indexes[1].name, "users");
    assert_eq!(indexes[1].entries, 300);
}

#[tokio::test]
async fn test_search_forwards_query_and_returns_results() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(
        200,
        json!({
            "hits": [
                {"objectID": "1", "name": "Widget"},
                {"objectID": "2", "name": "Gadget"}
            ],
            "nbHits": 2,
            "processingTimeMs": 3
        }),
    );

    let result = proxy
        .test_search(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            json!({"query": "widget"}),
        )
        .await
        .expect("test_search should succeed");

    assert_eq!(result["nbHits"], 2);
    assert_eq!(result["hits"].as_array().unwrap().len(), 2);
    assert_eq!(result["processingTimeMs"], 3);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/query"
    );
    assert_eq!(requests[0].json_body, Some(json!({"query": "widget"})));
}

#[tokio::test]
async fn cache_hit_avoids_ssm_read() {
    let (http, ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"uid": "idx1"}));
    http.push_json_response(200, json!({"uid": "idx2"}));

    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await
        .unwrap();

    assert_eq!(ssm.get_read_count(), 1, "first call should read from SSM");

    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx2")
        .await
        .unwrap();

    assert_eq!(
        ssm.get_read_count(),
        1,
        "second call should use cached key, not read SSM again"
    );
    assert_eq!(http.request_count(), 2);
}

#[tokio::test]
async fn cache_miss_reads_from_ssm() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    http.push_json_response(200, json!({"items": [], "nbPages": 0}));

    let indexes = proxy
        .list_indexes("https://vm-a1.flapjack.foo", "node-1", "us-east-1")
        .await
        .expect("should succeed after reading key from SSM");

    assert!(indexes.is_empty());

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].api_key, api_key);
}

#[tokio::test]
async fn flapjack_error_propagates_status() {
    let (http, _ssm, proxy) = setup().await;

    http.push_text_response(409, "index already exists");

    let result = proxy
        .create_index(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "existing-index",
        )
        .await;

    match result {
        Err(ProxyError::FlapjackError { status, message }) => {
            assert_eq!(status, 409);
            assert_eq!(message, "index already exists");
        }
        other => panic!("expected FlapjackError, got: {other:?}"),
    }
}

#[tokio::test]
async fn unreachable_vm_returns_proxy_error_unreachable() {
    let (http, _ssm, proxy) = setup().await;
    http.push_error(ProxyError::Unreachable("connect failed".to_string()));

    let result = proxy
        .create_index(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "my-index",
        )
        .await;

    match result {
        Err(ProxyError::Unreachable(msg)) => {
            assert!(msg.contains("connect failed"));
        }
        other => panic!("expected Unreachable, got: {other:?}"),
    }
}

#[tokio::test]
async fn get_index_stats_finds_single_index() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(
        200,
        json!({
            "items": [
                {
                    "name": "products",
                    "entries": 1500,
                    "dataSize": 204800,
                    "fileSize": 512000,
                    "createdAt": "2026-02-01T00:00:00Z",
                    "updatedAt": "2026-02-20T12:00:00Z"
                },
                {
                    "name": "users",
                    "entries": 300,
                    "dataSize": 51200,
                    "fileSize": 102400,
                    "createdAt": "2026-02-10T00:00:00Z",
                    "updatedAt": "2026-02-20T12:00:00Z"
                }
            ],
            "nbPages": 1
        }),
    );

    let stats = proxy
        .get_index_stats("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "users")
        .await
        .expect("get_index_stats should find 'users'");

    assert_eq!(stats.name, "users");
    assert_eq!(stats.entries, 300);
    assert_eq!(stats.data_size, 51200);
}

#[tokio::test]
async fn get_index_stats_returns_not_found_for_missing() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"items": [], "nbPages": 0}));

    let result = proxy
        .get_index_stats(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "no-such-index",
        )
        .await;

    match result {
        Err(ProxyError::FlapjackError { status, .. }) => {
            assert_eq!(status, 404);
        }
        other => panic!("expected FlapjackError 404, got: {other:?}"),
    }
}

#[tokio::test]
async fn get_index_settings_returns_settings() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(
        200,
        json!({
            "searchableAttributes": ["title", "description"],
            "faceting": {"maxValuesPerFacet": 100},
            "ranking": ["typo", "words", "proximity"]
        }),
    );

    let settings = proxy
        .get_index_settings(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
        )
        .await
        .expect("get_index_settings should succeed");

    assert_eq!(settings["searchableAttributes"][0], "title");
    assert_eq!(settings["ranking"][0], "typo");
}

#[tokio::test]
async fn create_search_key_sends_correct_request() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    http.push_json_response(
        200,
        json!({
            "key": "fj_search_abc123",
            "createdAt": "2026-02-21T00:00:00Z"
        }),
    );

    let result = proxy
        .create_search_key(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            &["products"],
            &["search", "browse"],
            "read-only key",
        )
        .await
        .expect("create_search_key should succeed");

    assert_eq!(result.key, "fj_search_abc123");
    assert_eq!(result.created_at, "2026-02-21T00:00:00Z");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-a1.flapjack.foo/1/keys");
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(
        requests[0].json_body,
        Some(json!({
            "acl": ["search", "browse"],
            "indexes": ["products"],
            "description": "read-only key"
        }))
    );
}

#[tokio::test]
async fn secret_error_propagates_when_key_not_found() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());
    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm);

    let result = proxy
        .create_index(
            "https://vm-a1.flapjack.foo",
            "node-missing",
            "us-east-1",
            "my-index",
        )
        .await;

    match result {
        Err(ProxyError::SecretError(msg)) => {
            assert!(
                msg.contains("node-missing"),
                "error should mention the missing node ID, got: {msg}"
            );
        }
        other => panic!("expected SecretError, got: {other:?}"),
    }

    assert_eq!(
        http.request_count(),
        0,
        "request must not be sent without key"
    );
}

#[tokio::test]
async fn timeout_error_propagates_through_proxy() {
    let (http, _ssm, proxy) = setup().await;

    http.push_error(ProxyError::Timeout);

    let result = proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await;

    assert!(
        matches!(result, Err(ProxyError::Timeout)),
        "expected ProxyError::Timeout, got: {result:?}"
    );
}

// ─── Cache TTL expiry ────────────────────────────────────────────────

#[tokio::test]
async fn cache_ttl_expiry_triggers_fresh_ssm_fetch() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());

    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    // Use a very short TTL so the cache expires between calls.
    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm.clone())
        .with_cache_ttl(Duration::from_millis(1));

    // First call — cache miss, reads from SSM.
    http.push_json_response(200, json!({"uid": "idx1"}));
    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await
        .unwrap();
    assert_eq!(ssm.get_read_count(), 1);

    // Sleep just long enough for the 1ms TTL to expire.
    tokio::time::sleep(Duration::from_millis(5)).await;

    // Second call — cache expired, must re-fetch from SSM.
    http.push_json_response(200, json!({"uid": "idx2"}));
    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx2")
        .await
        .unwrap();
    assert_eq!(
        ssm.get_read_count(),
        2,
        "after TTL expiry, SSM should be called again"
    );
}

// ─── Stale-on-error resilience ───────────────────────────────────────

#[tokio::test]
async fn stale_cache_used_when_ssm_fails_after_expiry() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());

    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm.clone())
        .with_cache_ttl(Duration::from_millis(1));

    // First call — populates the cache with a valid key.
    http.push_json_response(200, json!({"uid": "idx1"}));
    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await
        .unwrap();

    // Let TTL expire, then break SSM.
    tokio::time::sleep(Duration::from_millis(5)).await;
    ssm.set_should_fail(true);

    // Second call — SSM is down, but stale cached key should still work.
    http.push_json_response(200, json!({"uid": "idx2"}));
    let result = proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx2")
        .await;

    assert!(
        result.is_ok(),
        "proxy should use stale cached key when SSM fails, got: {result:?}"
    );
}

#[tokio::test]
async fn cold_cache_returns_error_when_ssm_fails() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());

    // Do NOT create a key — SSM will fail on first fetch.
    ssm.set_should_fail(true);

    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm.clone());

    let result = proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await;

    assert!(
        matches!(result, Err(ProxyError::SecretError(_))),
        "with empty cache and SSM down, should return SecretError, got: {result:?}"
    );
}

#[tokio::test]
async fn pruning_preserves_entries_within_4x_ttl_for_stale_fallback() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());

    // Create keys for two nodes.
    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();
    ssm.create_node_api_key("node-2", "us-east-1")
        .await
        .unwrap();

    // TTL = 10ms, so prune threshold = 40ms.
    let proxy = FlapjackProxy::with_http_client(http.clone(), ssm.clone())
        .with_cache_ttl(Duration::from_millis(10));

    // Populate cache for node-1.
    http.push_json_response(200, json!({"uid": "idx1"}));
    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx1")
        .await
        .unwrap();

    // Wait for node-1's entry to expire past TTL (10ms) but stay within 4×TTL (40ms).
    tokio::time::sleep(Duration::from_millis(15)).await;

    // Populate cache for node-2 — this triggers pruning. Node-1's entry is 15ms old
    // (past TTL=10ms but within prune_threshold=40ms), so it should SURVIVE pruning.
    http.push_json_response(200, json!({"uid": "idx2"}));
    proxy
        .create_index("https://vm-a1.flapjack.foo", "node-2", "us-east-1", "idx2")
        .await
        .unwrap();

    // Now break SSM and verify node-1's stale entry is still available for fallback.
    ssm.set_should_fail(true);

    http.push_json_response(200, json!({"uid": "idx3"}));
    let result = proxy
        .create_index("https://vm-a1.flapjack.foo", "node-1", "us-east-1", "idx3")
        .await;

    assert!(
        result.is_ok(),
        "node-1's stale entry within 4×TTL should survive pruning for fallback, got: {result:?}"
    );
}

// ─── Access tracker integration ──────────────────────────────────────

#[tokio::test]
async fn test_search_for_tenant_records_access() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let access_tracker = Arc::new(AccessTracker::new(tenant_repo));

    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    let proxy = FlapjackProxy::with_http_client_and_access_tracker(
        http.clone(),
        ssm.clone(),
        Some(access_tracker.clone()),
    );

    let customer_id = Uuid::new_v4();

    http.push_json_response(200, json!({"hits": [], "nbHits": 0}));
    proxy.record_access(customer_id, "products");
    proxy
        .test_search(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            json!({"query": "widget"}),
        )
        .await
        .unwrap();

    assert!(
        access_tracker.has_pending(customer_id, "products"),
        "record_access should track access for cold-tier tracking"
    );
}

#[tokio::test]
async fn test_search_does_not_record_access() {
    let http = Arc::new(MockFlapjackHttpClient::default());
    let ssm = Arc::new(MockNodeSecretManager::new());
    let tenant_repo = Arc::new(common::MockTenantRepo::new());
    let access_tracker = Arc::new(AccessTracker::new(tenant_repo));

    ssm.create_node_api_key("node-1", "us-east-1")
        .await
        .unwrap();

    let proxy = FlapjackProxy::with_http_client_and_access_tracker(
        http.clone(),
        ssm.clone(),
        Some(access_tracker.clone()),
    );

    http.push_json_response(200, json!({"hits": [], "nbHits": 0}));
    proxy
        .test_search(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            json!({"query": "widget"}),
        )
        .await
        .unwrap();

    assert_eq!(
        access_tracker.pending_count(),
        0,
        "test_search (without tenant) should NOT record access"
    );
}

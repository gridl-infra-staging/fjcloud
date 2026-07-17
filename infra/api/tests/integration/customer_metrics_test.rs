//! Customer metrics endpoint contract — RED tests.
//!
//! These tests pin the public contract of `GET /indexes/{name}/metrics` BEFORE
//! the route, cache, and `FlapjackProxy::fetch_metrics_text` exist (Stages 2-3).
//! That means this file is INTENDED to fail compilation until the seams below
//! are wired up. The compilation failure IS the red-phase evidence.
//!
//! Seams referenced (not yet present at HEAD):
//!   - `api::state::MetricsCache` with `expire_for_test(customer_id, index_name)`
//!   - `crate::common::flapjack_proxy_test_support::setup_ready_index_with_metrics_cache`
//!     (cache-aware variant of `setup_ready_index` returning the `MetricsCache`
//!     handle alongside router/jwt/http/customer_id).
//!
//! Do not "fix" the compile errors by stubbing out the missing references —
//! Stage 2 and Stage 3 own those owners.

use std::sync::Arc;

use crate::common::flapjack_proxy_test_support::{
    setup_ready_index, setup_ready_index_with_metrics_cache, test_flapjack_uid,
    MockFlapjackHttpClient,
};
use crate::common::indexes_route_test_support::response_json;
use crate::common::{
    create_test_jwt, mock_deployment_repo, mock_repo, mock_tenant_repo, mock_vm_inventory_repo,
    test_app_with_indexes_and_vm_inventory,
};

use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::{FlapjackProxy, ProxyError};
use api::state::MetricsCache;

use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use chrono::DateTime;
use tower::ServiceExt;

/// Builds a Prometheus exposition body that mixes (a) the in-scope tenant's
/// flapjack UID across multiple label-sets — to prove tier-aware summing —
/// with (b) a foreign UID — to prove the implementation filters by
/// `index=<flapjack_uid>` substring and does NOT leak other tenants' counters.
///
/// Hand-calculated sums for the in-scope UID:
///   documents_count        = 8000 (shard 1) + 4345 (shard 0) = 12345
///   storage_bytes          = 1_000_000_000 + 73_741_824      = 1_073_741_824
///   search_requests_total  = 8423
///   write_operations_total = 412                         (flapjack_documents_indexed_total)
fn metrics_fixture(in_scope_uid: &str) -> String {
    format!(
        "# HELP flapjack_documents_count Document count per index\n\
         # TYPE flapjack_documents_count gauge\n\
         flapjack_documents_count{{index=\"{uid}\",shard=\"1\"}} 8000\n\
         flapjack_documents_count{{index=\"{uid}\",shard=\"0\"}} 4345\n\
         flapjack_documents_count{{index=\"other-tenant-uid\"}} 99999\n\
         # HELP flapjack_storage_bytes Storage bytes per index per tier\n\
         # TYPE flapjack_storage_bytes gauge\n\
         flapjack_storage_bytes{{index=\"{uid}\",tier=\"hot\"}} 1000000000\n\
         flapjack_storage_bytes{{index=\"{uid}\",tier=\"warm\"}} 73741824\n\
         flapjack_storage_bytes{{index=\"other-tenant-uid\",tier=\"hot\"}} 999999999\n\
         # HELP flapjack_search_requests_total Search requests\n\
         # TYPE flapjack_search_requests_total counter\n\
         flapjack_search_requests_total{{index=\"{uid}\"}} 8423\n\
         flapjack_search_requests_total{{index=\"other-tenant-uid\"}} 77777\n\
         # HELP flapjack_documents_indexed_total Documents indexed\n\
         # TYPE flapjack_documents_indexed_total counter\n\
         flapjack_documents_indexed_total{{index=\"{uid}\"}} 412\n\
         flapjack_documents_indexed_total{{index=\"other-tenant-uid\"}} 55555\n",
        uid = in_scope_uid,
    )
}

fn metrics_request(jwt: &str, index_name: &str) -> Request<Body> {
    Request::builder()
        .method(http::Method::GET)
        .uri(format!("/indexes/{index_name}/metrics"))
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::empty())
        .unwrap()
}

// ---------------------------------------------------------------------------
// (a) Authenticated 200 returns the canonical six-field payload with
//     hand-calculated tier sums and RFC3339 UTC `fetched_at`.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn authenticated_200_returns_canonical_six_field_payload() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;
    let uid = test_flapjack_uid(customer_id, "products");

    http_client.push_text_response(200, &metrics_fixture(&uid));

    let resp = app
        .clone()
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    // Exact six-field contract — no more, no less.
    let obj = body.as_object().expect("response is a JSON object");
    let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
    keys.sort();
    assert_eq!(
        keys,
        vec![
            "documents_count",
            "fetched_at",
            "index",
            "search_requests_total",
            "storage_bytes",
            "write_operations_total",
        ],
        "response must expose exactly the six contract fields"
    );

    // Hand-calculated aggregate values.
    assert_eq!(body["index"], "products");
    assert_eq!(body["documents_count"], 12345);
    assert_eq!(body["storage_bytes"], 1_073_741_824u64);
    assert_eq!(body["search_requests_total"], 8423);
    assert_eq!(body["write_operations_total"], 412);

    // fetched_at must parse as RFC3339 and be UTC.
    let fetched_at = body["fetched_at"].as_str().expect("fetched_at is a string");
    let parsed = DateTime::parse_from_rfc3339(fetched_at).expect("fetched_at parses as RFC3339");
    assert_eq!(
        parsed.offset().local_minus_utc(),
        0,
        "fetched_at must be UTC (offset 0)"
    );

    // The upstream scrape hit `{flapjack_url}/metrics` exactly once with GET.
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1, "exactly one upstream scrape");
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/metrics");
    assert!(
        requests[0].json_body.is_none(),
        "scrape is a GET with no body"
    );
}

// ---------------------------------------------------------------------------
// (b) Cross-tenant request returns 404 with zero upstream requests.
//     Mirrors `documents_cross_tenant_isolation` (indexes_test.rs:7587).
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cross_tenant_returns_404_without_upstream_call() {
    // Inline the full setup so Alice AND Bob live in the SAME customer_repo
    // bound to the app. This mirrors the canonical cross-tenant pattern in
    // indexes_test.rs::documents_cross_tenant_isolation — Bob's JWT resolves
    // through the auth layer (no 401), but resolve_ready_index_target rejects
    // with 404 because the index belongs to Alice, not Bob.
    use api::repos::tenant_repo::TenantRepo;

    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let alice = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let bob = customer_repo.seed_verified_free_customer("Bob", "bob@example.com");
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

    let http_client = Arc::new(MockFlapjackHttpClient::default());
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

    let resp = app
        .oneshot(metrics_request(&bob_jwt, "alice-index"))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        body["error"]
            .as_str()
            .map(|s| s.contains("not found"))
            .unwrap_or(false),
        "body should carry a 'not found' error message, got: {body}"
    );

    // Auth/tenant rejection must happen BEFORE any upstream scrape.
    assert_eq!(http_client.take_requests().len(), 0);
}

// ---------------------------------------------------------------------------
// (c) Two calls within the cache window: identical `fetched_at` AND
//     `request_count() == 1`.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cache_hit_returns_stable_fetched_at_with_one_upstream_call() {
    let (app, jwt, http_client, customer_id, _metrics_cache) =
        setup_ready_index_with_metrics_cache("products").await;
    let uid = test_flapjack_uid(customer_id, "products");

    // Only ONE upstream response is enqueued — a real cache miss on the
    // second call would either pop an empty queue (default 200 `{}` body
    // which the parser would treat as empty) or attempt to hit a real VM.
    // The contract is that the second call MUST be served from cache.
    http_client.push_text_response(200, &metrics_fixture(&uid));

    let resp1 = app
        .clone()
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status1, body1) = response_json(resp1).await;
    assert_eq!(status1, StatusCode::OK);

    let resp2 = app
        .clone()
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status2, body2) = response_json(resp2).await;
    assert_eq!(status2, StatusCode::OK);

    // Cached payload — `fetched_at` is fixed at cache-insert time and
    // returned unchanged on hit.
    assert_eq!(
        body1["fetched_at"], body2["fetched_at"],
        "cached responses must share fetched_at"
    );
    // Payload bodies must be identical on cache hit.
    assert_eq!(body1, body2);

    // Exactly one upstream scrape across both requests.
    assert_eq!(
        http_client.request_count(),
        1,
        "second call within cache window must NOT hit upstream"
    );
}

// ---------------------------------------------------------------------------
// (d) Cache expiry: after `MetricsCache::expire_for_test(...)`, the next
//     call re-scrapes and returns a fresh `fetched_at`.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cache_expiry_re_scrapes_and_advances_fetched_at() {
    let (app, jwt, http_client, customer_id, metrics_cache) =
        setup_ready_index_with_metrics_cache("products").await;
    let uid = test_flapjack_uid(customer_id, "products");

    // Two upstream responses — one for the initial miss, one for the
    // post-expiry re-scrape. We enqueue them up-front; the mock pops in
    // FIFO order.
    http_client.push_text_response(200, &metrics_fixture(&uid));
    http_client.push_text_response(200, &metrics_fixture(&uid));

    let resp1 = app
        .clone()
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (_, body1) = response_json(resp1).await;
    let fetched_at_first = body1["fetched_at"].as_str().unwrap().to_string();

    // Narrow test-only seam: drop the entry for (customer_id, "products")
    // so the next call must re-scrape upstream.
    metrics_cache.expire_for_test(customer_id, "products");

    // Sleep a tick so even if `fetched_at` is computed at second-granularity
    // wall-clock, the new entry's timestamp is distinguishable from the
    // first one.
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;

    let resp2 = app
        .clone()
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status2, body2) = response_json(resp2).await;
    assert_eq!(status2, StatusCode::OK);
    let fetched_at_second = body2["fetched_at"].as_str().unwrap().to_string();

    assert_ne!(
        fetched_at_first, fetched_at_second,
        "post-expiry call must produce a fresh fetched_at"
    );
    // Two upstream scrapes total — initial miss + post-expiry re-scrape.
    assert_eq!(http_client.request_count(), 2);
}

// ---------------------------------------------------------------------------
// (e) 503 surface is narrow: ProxyError::Unreachable + Timeout map to 503,
//     ProxyError::FlapjackError { status: 500, .. } does NOT.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn proxy_unreachable_maps_to_503() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    http_client.push_error(ProxyError::Unreachable(
        "connect timed out to 10.0.0.99:7700".into(),
    ));

    let resp = app
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    // The error message must NOT leak the underlying VM IP/host (the
    // `From<ProxyError> for ApiError` contract hides those).
    let err_msg = body["error"].as_str().unwrap_or_default();
    assert!(
        !err_msg.contains("10.0.0.99"),
        "503 body must not leak VM addresses, got: {err_msg}"
    );

    // The upstream client was called — the 503 came from the transport
    // error, not pre-emption.
    assert_eq!(http_client.request_count(), 1);
}

#[tokio::test]
async fn proxy_timeout_maps_to_503() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    http_client.push_error(ProxyError::Timeout);

    let resp = app
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(http_client.request_count(), 1);
}

#[tokio::test]
async fn proxy_flapjack_error_does_not_map_to_503() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    // A raw non-2xx response from flapjack manifests as `FlapjackError`,
    // and `From<ProxyError> for ApiError` maps that by upstream status —
    // NOT to 503. This test locks the narrow 503 surface so that future
    // refactors don't accidentally widen it.
    http_client.push_error(ProxyError::FlapjackError {
        status: 500,
        message: "synthetic upstream 500".into(),
    });

    let resp = app
        .oneshot(metrics_request(&jwt, "products"))
        .await
        .unwrap();
    let (status, _body) = response_json(resp).await;
    assert_ne!(
        status,
        StatusCode::SERVICE_UNAVAILABLE,
        "FlapjackError must NOT widen the 503 surface"
    );
    assert_eq!(http_client.request_count(), 1);
}

// ---------------------------------------------------------------------------
// Type-level pin: keep the cache-handle reference live so the compile error
// for the missing `MetricsCache` seam shows up here too if every test above
// is somehow trimmed down. This is a belt-and-suspenders guard against the
// "stage 1 file compiles but doesn't actually pin the contract" failure
// mode flagged in the planning doc.
// ---------------------------------------------------------------------------

#[allow(dead_code)]
fn _metrics_cache_seam_pin(cache: Arc<MetricsCache>, customer_id: uuid::Uuid) {
    cache.expire_for_test(customer_id, "products");
}

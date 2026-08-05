//! Route tests for the read-only cutover-verification endpoint
//! `POST /migration/{source_provider}/verify`.
//!
//! These reuse the shared `FakeAlgoliaSourceLister` (source side) and the
//! canonical ready-index mock-repo seeding (destination side) so the route is
//! exercised end to end without a second fake source-service stack.
use super::*;

use crate::common::{
    mock_deployment_repo, mock_tenant_repo, mock_vm_inventory_repo, MockCustomerRepo,
    MockDeploymentRepo, MockTenantRepo, MockVmInventoryRepo,
};
use api::repos::tenant_repo::TenantRepo;
use api::services::access_tracker::AccessTracker;
use api::services::algolia_source::AlgoliaSourceLister;
use api::services::tenant_quota::FreeTierLimits;

mod verify_support;
use verify_support::*;

const SOURCE_INDEX: &str = "legacy_products";
const DESTINATION_INDEX: &str = "products";
const FLAPJACK_URL: &str = "https://vm-test.flapjack.foo";
const NODE_ID: &str = "node-a1";
const REGION: &str = "us-east-1";
type VerifyApp = (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    Arc<AccessTracker>,
    Uuid,
);
type VerifyUsageApp = (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    Arc<AccessTracker>,
    Uuid,
    Arc<crate::common::MockUsageRepo>,
);

struct VerifyAppSetup<'a> {
    destination_index: &'a str,
    tier: &'a str,
    algolia_migration_enabled: bool,
    source: Arc<dyn AlgoliaSourceLister>,
    destination_quota: Option<serde_json::Value>,
    foreign_destination_index: Option<&'a str>,
}

struct DestinationFixtureRepos {
    customers: Arc<MockCustomerRepo>,
    deployments: Arc<MockDeploymentRepo>,
    tenants: Arc<MockTenantRepo>,
    vm_inventory: Arc<MockVmInventoryRepo>,
}

fn source_response(object_ids: &[&str]) -> AlgoliaSourceSearchResponse {
    AlgoliaSourceSearchResponse {
        hits: object_ids
            .iter()
            .map(|id| AlgoliaSourceSearchHit {
                object_id: (*id).to_string(),
            })
            .collect(),
    }
}

fn destination_search_body(object_ids: &[&str]) -> serde_json::Value {
    json!({
        "hits": object_ids
            .iter()
            .map(|id| json!({ "objectID": id }))
            .collect::<Vec<_>>()
    })
}

fn verify_request(
    source_index: &str,
    destination_index: &str,
    queries: &[&str],
    result_limit: u32,
) -> serde_json::Value {
    json!({
        "appId": "APPID123",
        "apiKey": "search-only-key",
        "sourceIndex": source_index,
        "destinationIndex": destination_index,
        "queries": queries,
        "resultLimit": result_limit,
    })
}

fn verify_request_with_api_key(mut request: serde_json::Value, api_key: &str) -> serde_json::Value {
    request["apiKey"] = json!(api_key);
    request
}

/// Seed a verified free customer with a ready destination index at `tier`,
/// wired to a hermetic flapjack transport and the supplied fake source
/// service. Returns the route harness and access-tracking state needed for
/// destination assertions.
async fn setup_verify_app(
    destination_index: &str,
    tier: &str,
    algolia_migration_enabled: bool,
    source: Arc<dyn AlgoliaSourceLister>,
) -> VerifyApp {
    setup_verify_app_with_destination_quota(
        destination_index,
        tier,
        algolia_migration_enabled,
        source,
        None,
    )
    .await
}

async fn setup_verify_app_with_destination_quota(
    destination_index: &str,
    tier: &str,
    algolia_migration_enabled: bool,
    source: Arc<dyn AlgoliaSourceLister>,
    destination_quota: Option<serde_json::Value>,
) -> VerifyApp {
    setup_verify_app_with_options(VerifyAppSetup {
        destination_index,
        tier,
        algolia_migration_enabled,
        source,
        destination_quota,
        foreign_destination_index: None,
    })
    .await
}

async fn setup_verify_app_with_foreign_destination(
    destination_index: &str,
    foreign_destination_index: &str,
    source: Arc<dyn AlgoliaSourceLister>,
) -> VerifyApp {
    setup_verify_app_with_options(VerifyAppSetup {
        destination_index,
        tier: "active",
        algolia_migration_enabled: true,
        source,
        destination_quota: None,
        foreign_destination_index: Some(foreign_destination_index),
    })
    .await
}

async fn setup_verify_app_with_options(options: VerifyAppSetup<'_>) -> VerifyApp {
    let repos = DestinationFixtureRepos {
        customers: mock_repo(),
        deployments: mock_deployment_repo(),
        tenants: mock_tenant_repo(),
        vm_inventory: mock_vm_inventory_repo(),
    };
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = repos
        .customers
        .seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);

    node_secret_manager
        .create_node_api_key(NODE_ID, REGION)
        .await
        .expect("seed node admin key");

    let deployment = repos.deployments.seed_provisioned(
        customer.id,
        NODE_ID,
        REGION,
        "t4g.small",
        "aws",
        "running",
        Some(FLAPJACK_URL),
    );
    repos.tenants.seed_deployment(
        deployment.id,
        REGION,
        Some(FLAPJACK_URL),
        "healthy",
        "running",
    );
    repos
        .tenants
        .create(customer.id, options.destination_index, deployment.id)
        .await
        .expect("seed destination tenant");
    let vm = repos.vm_inventory.seed(REGION, FLAPJACK_URL);
    repos
        .tenants
        .set_vm_id(customer.id, options.destination_index, vm.id)
        .await
        .expect("place destination on shared VM");
    if let Some(quota) = options.destination_quota {
        repos
            .tenants
            .set_resource_quota(customer.id, options.destination_index, quota)
            .await
            .expect("seed destination quota");
    }
    if options.tier != "active" {
        repos
            .tenants
            .set_tier(customer.id, options.destination_index, options.tier)
            .await
            .expect("override destination tier");
    }
    if let Some(foreign_destination_index) = options.foreign_destination_index {
        seed_foreign_destination(&repos, vm.id, foreign_destination_index).await;
    }

    let access_tracker = Arc::new(AccessTracker::new(repos.tenants.clone()));
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client_and_access_tracker(
        flapjack_http.clone(),
        node_secret_manager,
        Some(access_tracker.clone()),
    ));

    let state = TestStateBuilder::new()
        .with_customer_repo(repos.customers)
        .with_deployment_repo(repos.deployments)
        .with_tenant_repo(repos.tenants)
        .with_vm_inventory_repo(repos.vm_inventory)
        .with_flapjack_proxy(flapjack_proxy)
        .with_algolia_source_service(options.source)
        .with_algolia_migration_enabled(options.algolia_migration_enabled)
        .build();

    (
        build_router(state),
        jwt,
        flapjack_http,
        access_tracker,
        customer.id,
    )
}

#[tokio::test]
async fn verify_reports_hand_calculated_parity_and_preserves_query_order() {
    // Source (ranked): running shoes -> [s1, s2, s3]; boots -> [b1, b2]
    // Destination (ranked): running shoes -> [s2, s3, z9]; boots -> [b1]
    let source = FakeAlgoliaSourceLister::with_search([
        Ok(source_response(&["s1", "s2", "s3"])),
        Ok(source_response(&["b1", "b2"])),
    ]);
    let (app, jwt, flapjack_http, access_tracker, customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;
    flapjack_http.push_json_response(200, destination_search_body(&["s2", "s3", "z9"]));
    flapjack_http.push_json_response(200, destination_search_body(&["b1"]));

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(
            SOURCE_INDEX,
            DESTINATION_INDEX,
            &["running shoes", "boots"],
            3,
        ),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "verify body: {body}");
    assert_eq!(body, expected_parity_report());

    // Source seam received both queries in customer-supplied order with the
    // per-query limit and source index name forwarded verbatim.
    let source_requests = source.search_requests();
    assert_eq!(source_requests.len(), 2);
    assert_eq!(source_requests[0].query, "running shoes");
    assert_eq!(source_requests[1].query, "boots");
    for request in &source_requests {
        assert_eq!(request.source_name, SOURCE_INDEX);
        assert_eq!(request.hits_per_page, 3);
        assert_eq!(request.app_id, "APPID123");
        assert_eq!(request.api_key.as_str(), "search-only-key");
    }
    // Destination search hit flapjack exactly once per query.
    assert_eq!(flapjack_http.request_count(), 2);
    assert!(
        access_tracker.has_pending(customer_id, DESTINATION_INDEX),
        "verify must record destination access for cold-tier inactivity tracking"
    );
}

#[tokio::test]
async fn verify_seeded_local_source_red_proof() {
    let source_base_url = seeded_source_url();
    seed_local_source(&source_base_url).await;
    let source_api_key = seeded_source_api_key();

    let source = real_algolia_source(source_base_url);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source).await;
    flapjack_http.push_json_response(200, destination_search_body(&["s2", "s3", "z9"]));
    flapjack_http.push_json_response(200, destination_search_body(&["b1"]));

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request_with_api_key(
            verify_request(
                SOURCE_INDEX,
                DESTINATION_INDEX,
                &["running shoes", "boots"],
                3,
            ),
            &source_api_key,
        ),
    )
    .await;

    assert_eq!(body, expected_parity_report(), "verify status: {status}");
    assert_eq!(status, StatusCode::OK, "verify body: {body}");
}

#[tokio::test]
async fn verify_compares_only_the_requested_top_n_when_backends_over_return() {
    let source = FakeAlgoliaSourceLister::with_search([Ok(source_response(&[
        "s1",
        "s2",
        "source-past-limit",
    ]))]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source).await;
    flapjack_http.push_json_response(
        200,
        destination_search_body(&["s2", "s1", "destination-past-limit"]),
    );

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoes"], 2),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "verify body: {body}");
    assert_eq!(
        body["queries"][0],
        json!({
            "query": "shoes",
            "overlapCount": 2,
            "sourceOnly": [],
            "destinationOnly": [],
            "hits": [
                {"objectID": "s1", "sourceRank": 1, "destinationRank": 2, "rankDelta": 1},
                {"objectID": "s2", "sourceRank": 2, "destinationRank": 1, "rankDelta": -1},
            ]
        })
    );
}

#[tokio::test]
async fn verify_applies_destination_query_rate_limit_to_each_query() {
    let source = FakeAlgoliaSourceLister::with_search([
        Ok(source_response(&["s1"])),
        Ok(source_response(&["s2"])),
    ]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app_with_destination_quota(
            DESTINATION_INDEX,
            "active",
            true,
            source.clone(),
            Some(json!({ "max_query_rps": 1 })),
        )
        .await;
    flapjack_http.push_json_response(200, destination_search_body(&["s1"]));
    flapjack_http.push_json_response(200, destination_search_body(&["s2"]));

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["first", "second"], 1),
    )
    .await;

    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "verify body: {body}");
    assert_eq!(
        headers
            .get(http::header::RETRY_AFTER)
            .expect("rate-limited verify must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "1"
    );
    assert_eq!(
        body,
        json!({ "error": format!("query rate limit exceeded for index '{DESTINATION_INDEX}'") })
    );
    assert_eq!(
        source.search_requests().len(),
        1,
        "second source query must not run after destination admission fails"
    );
    assert_eq!(
        flapjack_http.request_count(),
        1,
        "second destination search must not bypass rate admission"
    );
}

#[tokio::test]
async fn verify_refuses_batch_that_exceeds_remaining_monthly_search_allowance() {
    let source = FakeAlgoliaSourceLister::with_search([
        Ok(source_response(&["s1"])),
        Ok(source_response(&["s2"])),
    ]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id, _usage_repo) =
        setup_verify_app_with_monthly_search_usage(DESTINATION_INDEX, source.clone(), 4, 5).await;
    flapjack_http.push_json_response(200, destination_search_body(&["s1"]));
    flapjack_http.push_json_response(200, destination_search_body(&["s2"]));

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["first", "second"], 1),
    )
    .await;

    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "verify body: {body}");
    assert_eq!(
        body,
        json!({
            "error": "quota_exceeded",
            "limit": "monthly_searches",
            "upgrade_url": "/billing/upgrade",
        })
    );
    assert!(
        source.search_requests().is_empty(),
        "batch-level monthly quota refusal must happen before source queries"
    );
    assert_eq!(
        flapjack_http.request_count(),
        0,
        "batch-level monthly quota refusal must not execute destination searches"
    );
}

#[tokio::test]
async fn verify_checks_monthly_allowance_once_for_an_allowed_batch() {
    let source = FakeAlgoliaSourceLister::with_search([
        Ok(source_response(&["s1"])),
        Ok(source_response(&["s2"])),
    ]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id, usage_repo) =
        setup_verify_app_with_monthly_search_usage(DESTINATION_INDEX, source, 80, 100).await;
    flapjack_http.push_json_response(200, destination_search_body(&["s1"]));
    flapjack_http.push_json_response(200, destination_search_body(&["s2"]));

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["first", "second"], 1),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "verify body: {body}");
    assert_eq!(
        usage_repo.monthly_search_count_call_count(),
        1,
        "one batch must have one monthly allowance decision"
    );
}

#[tokio::test]
async fn verify_rejects_meilisearch_provider_before_any_source_call() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "meilisearch",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::SourceProviderUnsupported.as_str(),
            "code": AlgoliaImportErrorCode::SourceProviderUnsupported.as_str(),
        })
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_typesense_provider_before_any_source_call() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "typesense",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::SourceProviderUnsupported.as_str(),
            "code": AlgoliaImportErrorCode::SourceProviderUnsupported.as_str(),
        })
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_is_gated_closed_when_migration_unavailable() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", false, source.clone()).await;

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        headers
            .get("retry-after")
            .expect("disabled verify must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "30"
    );
    assert_eq!(
        body,
        json!({
            "error": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
            "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
        })
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_out_of_range_query_counts_before_any_backend_call() {
    for queries in [Vec::new(), vec!["shoe"; 21]] {
        let source = FakeAlgoliaSourceLister::with_search([]);
        let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
            setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;

        let (status, _headers, body) = post_verify(
            app,
            &jwt,
            "algolia",
            verify_request(SOURCE_INDEX, DESTINATION_INDEX, &queries, 5),
        )
        .await;

        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(
            body,
            json!({
                "error": "verify_queries_out_of_range",
                "code": AlgoliaImportErrorCode::IncompatibleData.as_str(),
            })
        );
        assert!(source.search_requests().is_empty());
        assert_eq!(flapjack_http.request_count(), 0);
    }
}

#[tokio::test]
async fn verify_rejects_over_limit_result_limit_before_any_backend_call() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 101),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({
            "error": "verify_result_limit_out_of_range",
            "code": AlgoliaImportErrorCode::SourceCatalogTooLarge.as_str(),
        })
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_over_limit_query_with_shared_error_response() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source.clone()).await;

    let long_query = "q".repeat(api::validation::MAX_SEARCH_QUERY_LEN + 1);
    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &[&long_query], 5),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body,
        json!({ "error": format!("query must be at most {} characters", api::validation::MAX_SEARCH_QUERY_LEN) })
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_maps_unreachable_source_to_labelled_backend_error() {
    let dead_uri = transport_closing_loopback_source_uri().await;
    let source = real_algolia_source(reqwest::Url::parse(&dead_uri).unwrap());
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, source).await;

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        headers
            .get("retry-after")
            .expect("unreachable source must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "30"
    );
    assert_eq!(body, expected_backend_unavailable_body());
    // The real source transport failed before destination search could run.
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_unowned_destination_index_as_not_found() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app_with_foreign_destination(
            DESTINATION_INDEX,
            "foreign_products",
            source.clone(),
        )
        .await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, "foreign_products", &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"], json!("index 'foreign_products' not found"));
    // Destination ownership fails before any source or destination search.
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_cold_destination_matching_search_route_contract() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "cold", true, source.clone()).await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    // Verify reuses the shared search-admission cold-tier contract verbatim.
    assert_eq!(status, StatusCode::GONE);
    assert_eq!(body["error"], json!("index_cold"));
    assert_eq!(
        body["restore_url"],
        json!(format!("/indexes/{DESTINATION_INDEX}/restore"))
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_restoring_destination_matching_search_route_contract() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "restoring", true, source.clone()).await;

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        headers
            .get("retry-after")
            .expect("restoring destination must include Retry-After")
            .to_str()
            .expect("Retry-After must be valid header text"),
        "30"
    );
    assert_eq!(body["error"], json!("index_restoring"));
    assert_eq!(
        body["poll_url"],
        json!(format!("/indexes/{DESTINATION_INDEX}/restore-status"))
    );
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

#[tokio::test]
async fn verify_rejects_destination_without_ready_endpoint_with_shared_error_response() {
    let source = FakeAlgoliaSourceLister::with_search([]);
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app_without_ready_destination_target(DESTINATION_INDEX, source.clone()).await;

    let (status, _headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body, json!({ "error": "endpoint not ready yet" }));
    assert!(source.search_requests().is_empty());
    assert_eq!(flapjack_http.request_count(), 0);
}

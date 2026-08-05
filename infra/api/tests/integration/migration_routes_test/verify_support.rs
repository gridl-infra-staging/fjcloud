use super::*;

pub(super) async fn seed_foreign_destination(
    repos: &DestinationFixtureRepos,
    vm_id: Uuid,
    destination_index: &str,
) {
    let customer = repos
        .customers
        .seed_verified_free_customer("Mallory", "mallory@example.com");
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
        .create(customer.id, destination_index, deployment.id)
        .await
        .expect("seed foreign destination tenant");
    repos
        .tenants
        .set_vm_id(customer.id, destination_index, vm_id)
        .await
        .expect("place foreign destination on shared VM");
}

pub(super) async fn setup_verify_app_with_monthly_search_usage(
    destination_index: &str,
    source: Arc<dyn AlgoliaSourceLister>,
    monthly_search_count: i64,
    monthly_search_limit: u64,
) -> VerifyUsageApp {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let usage_repo = crate::common::mock_usage_repo();
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    usage_repo.seed(
        customer.id,
        Utc::now().date_naive(),
        REGION,
        monthly_search_count,
        0,
        0,
        0,
    );

    node_secret_manager
        .create_node_api_key(NODE_ID, REGION)
        .await
        .expect("seed node admin key");
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        NODE_ID,
        REGION,
        "t4g.small",
        "aws",
        "running",
        Some(FLAPJACK_URL),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        REGION,
        Some(FLAPJACK_URL),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, destination_index, deployment.id)
        .await
        .expect("seed destination tenant");
    let vm = vm_inventory_repo.seed(REGION, FLAPJACK_URL);
    tenant_repo
        .set_vm_id(customer.id, destination_index, vm.id)
        .await
        .expect("place destination on shared VM");

    let access_tracker = Arc::new(AccessTracker::new(tenant_repo.clone()));
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client_and_access_tracker(
        flapjack_http.clone(),
        node_secret_manager,
        Some(access_tracker.clone()),
    ));
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_usage_repo(usage_repo.clone())
        .with_flapjack_proxy(flapjack_proxy)
        .with_algolia_source_service(source)
        .with_algolia_migration_enabled(true)
        .with_free_tier_limits(FreeTierLimits {
            max_indexes: 3,
            max_searches_per_month: monthly_search_limit,
            max_records: 100_000,
            max_storage_mb: 1024,
        })
        .build();

    (
        build_router(state),
        jwt,
        flapjack_http,
        access_tracker,
        customer.id,
        usage_repo,
    )
}

pub(super) async fn setup_verify_app_without_ready_destination_target(
    destination_index: &str,
    source: Arc<dyn AlgoliaSourceLister>,
) -> VerifyApp {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let flapjack_http = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = customer_repo.seed_verified_free_customer("Alice", "alice@example.com");
    let jwt = create_test_jwt(customer.id);
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        NODE_ID,
        REGION,
        "t4g.small",
        "aws",
        "running",
        Some(FLAPJACK_URL),
    );
    tenant_repo.seed_deployment(deployment.id, REGION, None, "healthy", "running");
    tenant_repo
        .create(customer.id, destination_index, deployment.id)
        .await
        .expect("seed destination tenant");

    let access_tracker = Arc::new(AccessTracker::new(tenant_repo.clone()));
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client_and_access_tracker(
        flapjack_http.clone(),
        node_secret_manager,
        Some(access_tracker.clone()),
    ));
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_flapjack_proxy(flapjack_proxy)
        .with_algolia_source_service(source)
        .with_algolia_migration_enabled(true)
        .build();

    (
        build_router(state),
        jwt,
        flapjack_http,
        access_tracker,
        customer.id,
    )
}

/// Build the concrete `AlgoliaSourceService` over a real `reqwest` transport
/// pointed at `source_base_url` (a loopback wiremock `MockServer`). This is the
/// production source stack — request construction, HTTP transport, URL
/// derivation, response parsing, status/error mapping — with only the vendor
/// endpoint stubbed. `TEST_JWT_SECRET` is exactly `MIN_CURSOR_KEY_BYTES` (32).
pub(super) fn real_algolia_source(source_base_url: reqwest::Url) -> Arc<dyn AlgoliaSourceLister> {
    Arc::new(
        AlgoliaSourceService::new_with_source_base_url(
            Arc::new(ReqwestAlgoliaSourceClient::new().expect("build reqwest source client")),
            crate::common::TEST_JWT_SECRET.as_bytes(),
            Some(source_base_url),
        )
        .expect("build real algolia source service"),
    )
}

/// Corpus owned by the seeded-source proof.
///
/// Every title separates on a ranking criterion that is decided *before* any
/// score-based tiebreak, so the ranked order below is derivable by reading the
/// titles rather than by knowing Flapjack's BM25 weights:
///
/// - `running shoes` is a two-term query, so the deciding criterion is
///   proximity: the token distance from `running` to `shoes` inside the title.
///   s1 = 1 (adjacent), s2 = 2 (one word between), s3 = 3 (two words between).
///   Strictly increasing distance => `running shoes -> [s1, s2, s3]`.
/// - `boots` is a single-term query, so proximity is 0 for every hit and the
///   deciding criterion is exact-on-single-word-query in its default
///   `attribute` mode: a hit is exact only when the whole attribute equals the
///   query. b1's title is exactly `boots`; b2's is not. => `boots -> [b1, b2]`.
///
/// Every earlier criterion (typo, words, filters, attribute) ties across these
/// documents: all query terms match verbatim and `title` is the only searchable
/// attribute. Titles must keep their distinct distances — an earlier revision
/// used `budget running trail shoes` for s3, which ties s2 on proximity and let
/// the BM25 tiebreak decide, and live Flapjack 1.0.10 then returned
/// `[s1, s3, s2]` against this oracle's claimed `[s1, s2, s3]`.
fn seeded_source_batch() -> serde_json::Value {
    json!({
        "requests": [
            {"action": "addObject", "body": {"objectID": "s1", "title": "running shoes"}},
            {"action": "addObject", "body": {"objectID": "s2", "title": "running trail shoes"}},
            {"action": "addObject", "body": {"objectID": "s3", "title": "running trail waterproof shoes"}},
            {"action": "addObject", "body": {"objectID": "b1", "title": "boots"}},
            {"action": "addObject", "body": {"objectID": "b2", "title": "winter boots"}},
        ]
    })
}

/// Resolve the loopback base URL of the lane-local Flapjack through the same
/// `FJCLOUD_ALGOLIA_SOURCE_BASE_URL` config seam used at application startup.
/// This keeps the seeded proof local and makes changing the override change the
/// source the proof contacts.
///
/// The gate exports the value before starting the test process. This function
/// only reads it; mutating the process environment here would race the other
/// tests in the shared platform binary.
pub(super) fn seeded_source_url() -> reqwest::Url {
    let source_base_url = std::env::var("FJCLOUD_ALGOLIA_SOURCE_BASE_URL")
        .expect("FJCLOUD_ALGOLIA_SOURCE_BASE_URL must point at lane-local Flapjack");
    api::config::Config::from_reader(|key| {
        match key {
            "DATABASE_URL" => Some("postgres://localhost/fjcloud"),
            "JWT_SECRET" => Some(crate::common::TEST_JWT_SECRET),
            "ADMIN_KEY" => Some("admin-bootstrap-key-for-testing"),
            "FJCLOUD_ALGOLIA_SOURCE_BASE_URL" => Some(source_base_url.as_str()),
            _ => None,
        }
        .map(str::to_string)
    })
    .expect("seeded source override must pass application config validation")
    .algolia_source_base_url
    .expect("seeded source override must be configured")
}

pub(super) fn seeded_source_api_key() -> String {
    std::env::var("FLAPJACK_ADMIN_KEY")
        .expect("FLAPJACK_ADMIN_KEY must match the lane-local Flapjack process")
}

pub(super) async fn seed_local_source(source_base_url: &reqwest::Url) {
    let admin_key = seeded_source_api_key();
    seed_local_source_with_deadline(
        source_base_url,
        &admin_key,
        std::time::Duration::from_secs(5),
    )
    .await
    .expect("lane-local Flapjack source must seed and publish within five seconds");
}

async fn seed_local_source_with_deadline(
    source_base_url: &reqwest::Url,
    admin_key: &str,
    deadline: std::time::Duration,
) -> Result<(), tokio::time::error::Elapsed> {
    tokio::time::timeout(
        deadline,
        seed_local_source_and_wait(source_base_url, admin_key),
    )
    .await
}

async fn successful_json_response(response: reqwest::Response, action: &str) -> serde_json::Value {
    let status = response.status();
    let body = response
        .text()
        .await
        .unwrap_or_else(|error| panic!("{action} response body failed: {error}"));
    assert!(status.is_success(), "{action} failed: {status} {body}");
    serde_json::from_str(&body)
        .unwrap_or_else(|error| panic!("{action} returned invalid JSON: {error}; body: {body}"))
}

async fn seed_local_source_and_wait(source_base_url: &reqwest::Url, admin_key: &str) {
    let client = reqwest::Client::new();
    let batch_url = source_base_url
        .join(&format!("/1/indexes/{SOURCE_INDEX}/batch"))
        .expect("build seeded-source batch URL");
    let response = client
        .post(batch_url)
        .header("X-Algolia-Application-Id", "flapjack")
        .header("X-Algolia-API-Key", admin_key)
        .json(&seeded_source_batch())
        .send()
        .await
        .expect("seed lane-local Flapjack source");
    let body = successful_json_response(response, "seed source").await;

    let task_id = body["taskID"]
        .as_i64()
        .expect("seed response must include numeric taskID");
    let task_url = source_base_url
        .join(&format!("/1/indexes/{SOURCE_INDEX}/task/{task_id}"))
        .expect("build seeded-source task URL");
    for _ in 0..100 {
        let task = client
            .get(task_url.clone())
            .header("X-Algolia-Application-Id", "flapjack")
            .header("X-Algolia-API-Key", admin_key)
            .send()
            .await
            .expect("read seeded-source task");
        let task = successful_json_response(task, "read seeded-source task").await;
        if task["status"] == json!("published") && task["pendingTask"] == json!(false) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("seeded-source task {task_id} did not publish within one second");
}

#[tokio::test]
async fn seeded_source_deadline_bounds_a_stalled_http_response() {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .expect("bind stalled seeded-source endpoint");
    let source_base_url = reqwest::Url::parse(&format!(
        "http://{}",
        listener
            .local_addr()
            .expect("read stalled endpoint address")
    ))
    .expect("parse stalled endpoint URL");
    let stalled_endpoint = tokio::spawn(async move {
        let (_socket, _peer) = listener.accept().await.expect("accept seed request");
        std::future::pending::<()>().await;
    });

    let result = seed_local_source_with_deadline(
        &source_base_url,
        "test-admin-key",
        std::time::Duration::from_millis(50),
    )
    .await;
    stalled_endpoint.abort();

    assert!(result.is_err(), "stalled source must hit the seed deadline");
}

/// Single owner for the hand-calculated verify parity oracle.
///
/// Source (ranked): running shoes -> [s1, s2, s3]; boots -> [b1, b2]
/// Destination (ranked): running shoes -> [s2, s3, z9]; boots -> [b1]
/// limit 3.
///
/// The fake-source and wiremock proofs stub that source order; the seeded-source
/// proof makes a real engine produce it from `seeded_source_batch`, whose doc
/// comment derives it from the titles. Change one and the other must follow.
///
/// All three proofs assert full-body equality against this value, so the
/// arithmetic lives in exactly one place.
pub(super) fn expected_parity_report() -> serde_json::Value {
    json!({
        "sourceIndex": SOURCE_INDEX,
        "destinationIndex": DESTINATION_INDEX,
        "resultLimit": 3,
        "queries": [
            {
                // s1 source-only; s2 rank 2->1 delta -1; s3 rank 3->2 delta -1; z9 dest-only.
                "query": "running shoes",
                "overlapCount": 2,
                "sourceOnly": ["s1"],
                "destinationOnly": ["z9"],
                "hits": [
                    {"objectID": "s2", "sourceRank": 2, "destinationRank": 1, "rankDelta": -1},
                    {"objectID": "s3", "sourceRank": 3, "destinationRank": 2, "rankDelta": -1},
                ]
            },
            {
                // b1 rank 1->1 delta 0; b2 source-only; no dest-only.
                "query": "boots",
                "overlapCount": 1,
                "sourceOnly": ["b2"],
                "destinationOnly": [],
                "hits": [
                    {"objectID": "b1", "sourceRank": 1, "destinationRank": 1, "rankDelta": 0},
                ]
            }
        ]
    })
}

/// Single owner for the labelled backend-unavailable verify contract body.
///
/// Every failure arm that maps to `migration_backend_unavailable` asserts
/// full-body equality against this value (paired with status 503 and
/// `retry-after: 30`), so the wire contract lives in exactly one place.
pub(super) fn expected_backend_unavailable_body() -> serde_json::Value {
    json!({
        "error": "algolia_discovery_unavailable",
        "code": AlgoliaImportErrorCode::BackendUnavailable.as_str(),
    })
}

pub(super) async fn post_verify(
    app: axum::Router,
    jwt: &str,
    provider: &str,
    body: serde_json::Value,
) -> (StatusCode, http::HeaderMap, serde_json::Value) {
    let response = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri(format!("/migration/{provider}/verify"))
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .expect("build verify request"),
        )
        .await
        .expect("verify response");
    let status = response.status();
    let headers = response.headers().clone();
    let (_, body) = response_json(response).await;
    (status, headers, body)
}

/// Mount a body-discriminated `POST /1/indexes/legacy_products/query` stub on
/// `server` that returns `object_ids` as Algolia search hits for the request
/// whose JSON body contains `{"query": query}`.
async fn mount_source_query_stub(server: &wiremock::MockServer, query: &str, object_ids: &[&str]) {
    use wiremock::matchers::{body_partial_json, method, path};
    use wiremock::{Mock, ResponseTemplate};

    Mock::given(method("POST"))
        .and(path("/1/indexes/legacy_products/query"))
        .and(body_partial_json(json!({ "query": query })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "hits": object_ids
                .iter()
                .map(|id| json!({ "objectID": id }))
                .collect::<Vec<_>>()
        })))
        .mount(server)
        .await;
}

/// Drive verify over a real axum router + real `reqwest` client + real HTTP,
/// with only the Algolia vendor endpoint stubbed on wiremock. Asserts the same
/// parity oracle as the in-process test, then asserts what only the wire can
/// prove: request order, path, header *values*, and that `resultLimit` reaches
/// the vendor as `hitsPerPage`.
#[tokio::test]
async fn verify_matches_the_parity_oracle_over_real_http_against_a_stubbed_source() {
    let server = wiremock::MockServer::start().await;
    mount_source_query_stub(&server, "running shoes", &["s1", "s2", "s3"]).await;
    mount_source_query_stub(&server, "boots", &["b1", "b2"]).await;

    let real_source = real_algolia_source(reqwest::Url::parse(&server.uri()).unwrap());
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, real_source).await;
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

    // Only the wire can prove these: the handler loops queries sequentially,
    // source before destination, so the server sees exactly the two source
    // queries in customer-supplied order.
    let received = server
        .received_requests()
        .await
        .expect("wiremock records received requests");
    assert_eq!(received.len(), 2, "one source query per requested query");
    for request in &received {
        assert_eq!(request.url.path(), "/1/indexes/legacy_products/query");
        assert_eq!(
            request
                .headers
                .get("X-Algolia-Application-Id")
                .expect("app id header present")
                .to_str()
                .unwrap(),
            "APPID123"
        );
        assert_eq!(
            request
                .headers
                .get("X-Algolia-API-Key")
                .expect("api key header present")
                .to_str()
                .unwrap(),
            "search-only-key"
        );
    }
    let body0: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();
    let body1: serde_json::Value = serde_json::from_slice(&received[1].body).unwrap();
    // Exact bodies: `resultLimit` (3) reaches the vendor as `hitsPerPage`.
    assert_eq!(body0, json!({ "query": "running shoes", "hitsPerPage": 3 }));
    assert_eq!(body1, json!({ "query": "boots", "hitsPerPage": 3 }));
    assert_eq!(flapjack_http.request_count(), 2);
}

pub(super) async fn transport_closing_loopback_source_uri() -> String {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .expect("bind loopback source transport closer");
    let addr = listener
        .local_addr()
        .expect("read loopback source transport closer address");
    tokio::spawn(async move {
        if let Ok((socket, _peer)) = listener.accept().await {
            drop(socket);
        }
    });
    format!("http://{addr}")
}

/// A retryable upstream status (503) must be reissued up to MAX_RETRY_ATTEMPTS
/// (3) over real HTTP, then map to the labelled backend-unavailable contract.
#[tokio::test]
async fn verify_retries_upstream_5xx_then_maps_to_backend_unavailable_over_http() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, ResponseTemplate};

    let server = wiremock::MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/indexes/legacy_products/query"))
        .respond_with(ResponseTemplate::new(503))
        .mount(&server)
        .await;

    let real_source = real_algolia_source(reqwest::Url::parse(&server.uri()).unwrap());
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, real_source).await;

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "body: {body}");
    assert_eq!(headers.get("retry-after").unwrap().to_str().unwrap(), "30");
    assert_eq!(body, expected_backend_unavailable_body());
    // The retry policy fired over real HTTP: the 5xx source response was
    // reissued (>1 request reached the server), in contrast with the terminal
    // arms — malformed 200 (exactly 1) and refused connection (0). We assert
    // ">1" rather than the exact fjcloud attempt count (MAX_RETRY_ATTEMPTS=3)
    // because reqwest 0.12/hyper reconnect-retries each POST when wiremock
    // closes the per-response connection, so the wire observes ~2x the fjcloud
    // attempts. The exact 3-attempt fjcloud policy is owned deterministically
    // at the client seam by
    // `services::algolia_source::tests::bounded_read_tests::algolia_source_search_retries_only_bounded_retryable_statuses`.
    let retried = server
        .received_requests()
        .await
        .expect("wiremock records received requests");
    assert!(
        retried.len() > 1,
        "retryable 5xx must be reissued over the wire, saw {} request(s)",
        retried.len()
    );
    for request in &retried {
        assert_eq!(request.url.path(), "/1/indexes/legacy_products/query");
        let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body, json!({ "query": "shoe", "hitsPerPage": 5 }));
    }
    assert_eq!(flapjack_http.request_count(), 0);
}

/// A 200 with an unparseable body maps to `InvalidUpstreamResponse` -> the same
/// labelled backend-unavailable contract, and is never retried (a 200 is
/// terminal): exactly one upstream request.
#[tokio::test]
async fn verify_maps_malformed_source_body_to_backend_unavailable_over_http() {
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, ResponseTemplate};

    let server = wiremock::MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/1/indexes/legacy_products/query"))
        .respond_with(ResponseTemplate::new(200).set_body_string("not-json"))
        .mount(&server)
        .await;

    let real_source = real_algolia_source(reqwest::Url::parse(&server.uri()).unwrap());
    let (app, jwt, flapjack_http, _access_tracker, _customer_id) =
        setup_verify_app(DESTINATION_INDEX, "active", true, real_source).await;

    let (status, headers, body) = post_verify(
        app,
        &jwt,
        "algolia",
        verify_request(SOURCE_INDEX, DESTINATION_INDEX, &["shoe"], 5),
    )
    .await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "body: {body}");
    assert_eq!(headers.get("retry-after").unwrap().to_str().unwrap(), "30");
    assert_eq!(body, expected_backend_unavailable_body());
    // A 200 is terminal: parsed once, never retried.
    assert_eq!(
        server
            .received_requests()
            .await
            .expect("wiremock records received requests")
            .len(),
        1
    );
    assert_eq!(flapjack_http.request_count(), 0);
}

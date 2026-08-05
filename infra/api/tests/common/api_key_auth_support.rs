use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{header, Request, StatusCode};
use axum::routing::get;
use axum::Router;
use chrono::{DateTime, Utc};
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use tower::ServiceExt;

use api::auth::api_key::{ApiKeyAuth, Stage1ApiKeyCompatDecision};
use api::errors::ApiError;
use api::models::api_key::ApiKeyRow;
use api::repos::api_key_repo::{ApiKeyManagedKeyParams, ApiKeyRepo};
use api::router::RateLimiter;
use api::state::AppState;

pub const TEST_KEY: &str = "fjc_live_0123456789abcdef0123456789abcdef";
pub const TEST_KEY_PREFIX: &str = "fjc_live_0123456";
pub const LEGACY_FJ_LIVE_KEY: &str = "fj_live_0123456789abcdef0123456789abcdef";
pub const LEGACY_FJ_LIVE_KEY_PREFIX: &str = "fj_live_01234567";
pub const GRIDL_KEY: &str = "gridl_live_0123456789abcdef0123456789abcdef";
pub const GRIDL_KEY_PREFIX: &str = "gridl_live_01234";
pub const SECOND_TEST_KEY: &str = "fjc_live_abcdef0123456789abcdef0123456789";

pub fn hash_key(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

#[derive(Clone, Default)]
pub struct ManagedTestKeyOptions {
    pub expires_at: Option<DateTime<Utc>>,
    pub restrict_sources: Vec<String>,
    pub max_queries_per_ip_per_hour: Option<i32>,
}

pub async fn create_managed_test_key(
    api_key_repo: &super::MockApiKeyRepo,
    customer_id: uuid::Uuid,
    plaintext_key: &str,
    expires_at: Option<DateTime<Utc>>,
) -> ApiKeyRow {
    create_managed_test_key_with_sources(
        api_key_repo,
        customer_id,
        plaintext_key,
        expires_at,
        Vec::new(),
    )
    .await
}

pub async fn create_managed_test_key_with_sources(
    api_key_repo: &super::MockApiKeyRepo,
    customer_id: uuid::Uuid,
    plaintext_key: &str,
    expires_at: Option<DateTime<Utc>>,
    restrict_sources: Vec<String>,
) -> ApiKeyRow {
    create_managed_test_key_with_options(
        api_key_repo,
        customer_id,
        plaintext_key,
        ManagedTestKeyOptions {
            expires_at,
            restrict_sources,
            max_queries_per_ip_per_hour: None,
        },
    )
    .await
}

pub async fn create_managed_test_key_with_options(
    api_key_repo: &super::MockApiKeyRepo,
    customer_id: uuid::Uuid,
    plaintext_key: &str,
    options: ManagedTestKeyOptions,
) -> ApiKeyRow {
    api_key_repo
        .create(
            customer_id,
            "managed-test-key",
            &hash_key(plaintext_key),
            &plaintext_key[..16],
            &["read".into(), "write".into()],
            ApiKeyManagedKeyParams {
                description: None,
                expires_at: options.expires_at,
                indexes: Vec::new(),
                restrict_sources: options.restrict_sources,
                max_hits_per_query: None,
                max_queries_per_ip_per_hour: options.max_queries_per_ip_per_hour,
            },
        )
        .await
        .unwrap()
}

async fn test_handler(auth: ApiKeyAuth) -> String {
    serde_json::json!({
        "customer_id": auth.customer_id,
        "key_id": auth.key_id,
        "scopes": auth.scopes,
    })
    .to_string()
}

async fn scoped_handler(auth: ApiKeyAuth) -> Result<String, ApiError> {
    auth.require_scope("read")?;
    Ok(format!("ok: {}", auth.customer_id))
}

pub fn build_test_app(
    customer_repo: Arc<super::MockCustomerRepo>,
    api_key_repo: Arc<super::MockApiKeyRepo>,
) -> Router {
    let state = super::test_state_with_api_key_repo(customer_repo, api_key_repo);
    build_test_app_with_state(state)
}

pub fn build_test_app_with_rate_limiter(
    customer_repo: Arc<super::MockCustomerRepo>,
    api_key_repo: Arc<super::MockApiKeyRepo>,
    api_key_rate_limiter: RateLimiter,
) -> Router {
    let state = super::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_api_key_repo(api_key_repo)
        .with_api_key_rate_limiter(api_key_rate_limiter)
        .build();
    build_test_app_with_state(state)
}

fn build_test_app_with_state(state: AppState) -> Router {
    Router::new()
        .route("/test", get(test_handler))
        .route("/scoped", get(scoped_handler))
        .with_state(state)
}

pub async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

pub async fn response_json_and_retry_after(
    resp: axum::response::Response,
) -> (StatusCode, serde_json::Value, Option<String>) {
    let status = resp.status();
    let retry_after = resp
        .headers()
        .get(header::RETRY_AFTER)
        .map(|value| value.to_str().unwrap().to_string());
    let body = body_json(resp).await;
    (status, body, retry_after)
}

pub async fn assert_socket_auth_success(
    app: &Router,
    key: &str,
    socket_addr: &str,
    customer_id: uuid::Uuid,
    key_id: uuid::Uuid,
) {
    let resp = authenticate_from_socket(app.clone(), key, socket_addr).await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_successful_auth_body(body_json(resp).await, customer_id, key_id);
}

pub async fn assert_socket_auth_status(
    app: &Router,
    key: &str,
    socket_addr: &str,
    expected: StatusCode,
) {
    let resp = authenticate_from_socket(app.clone(), key, socket_addr).await;
    assert_eq!(resp.status(), expected);
}

pub async fn assert_socket_rate_limited(app: &Router, key: &str, socket_addr: &str, retry: &str) {
    let resp = authenticate_from_socket(app.clone(), key, socket_addr).await;
    let (status, body, retry_after) = response_json_and_retry_after(resp).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(body, serde_json::json!({"error": "too many requests"}));
    assert_eq!(retry_after.as_deref(), Some(retry));
}

pub async fn assert_socket_invalid_token(app: &Router, key: &str, socket_addr: &str) {
    let resp = authenticate_from_socket(app.clone(), key, socket_addr).await;
    let (status, body, retry_after) = response_json_and_retry_after(resp).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        body,
        serde_json::json!({"error": "invalid or expired token"})
    );
    assert_eq!(retry_after, None);
}

pub async fn authenticate(app: Router, key: &str) -> axum::response::Response {
    app.oneshot(
        Request::get("/test")
            .header("authorization", format!("Bearer {key}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await
    .unwrap()
}

/// Authenticate with the same transport-verified peer extension axum attaches
/// through `into_make_service_with_connect_info` at runtime.
pub async fn authenticate_from_socket(
    app: Router,
    key: &str,
    socket_addr: &str,
) -> axum::response::Response {
    let mut request = Request::get("/test")
        .header("authorization", format!("Bearer {key}"))
        .body(Body::empty())
        .unwrap();
    request.extensions_mut().insert(ConnectInfo(
        socket_addr
            .parse::<SocketAddr>()
            .expect("socket addr parses"),
    ));
    app.oneshot(request).await.unwrap()
}

pub async fn authenticate_over_bound_api_server(
    app: Router,
    key: &str,
) -> (reqwest::StatusCode, serde_json::Value) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind API test listener");
    let url = format!(
        "http://{}/test",
        listener.local_addr().expect("listener address")
    );
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server_task = tokio::spawn(async move {
        api::startup::serve_api_router(listener, app, async {
            let _ = shutdown_rx.await;
        })
        .await
    });

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .expect("build bounded reqwest client");
    let response = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        client
            .get(url)
            .header("authorization", format!("Bearer {key}"))
            .send(),
    )
    .await
    .expect("live API request must not hang")
    .expect("live API request must complete");
    let status = response.status();
    let body = response
        .json::<serde_json::Value>()
        .await
        .expect("API response body must be JSON");

    let _ = shutdown_tx.send(());
    tokio::time::timeout(std::time::Duration::from_secs(3), server_task)
        .await
        .expect("API server shutdown must not hang")
        .expect("API server task must join")
        .expect("API server must shut down cleanly");

    (status, body)
}

pub fn assert_successful_auth_body(
    body: serde_json::Value,
    customer_id: uuid::Uuid,
    key_id: uuid::Uuid,
) {
    assert_eq!(body["customer_id"], customer_id.to_string());
    assert_eq!(body["key_id"], key_id.to_string());
    assert_eq!(body["scopes"], serde_json::json!(["read", "write"]));
}

pub async fn seed_restricted_key(
    restrict_sources: Vec<String>,
) -> (Arc<super::MockCustomerRepo>, Arc<super::MockApiKeyRepo>) {
    let customer_repo = super::mock_repo();
    let api_key_repo = super::mock_api_key_repo();
    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    create_managed_test_key_with_sources(
        &api_key_repo,
        customer.id,
        TEST_KEY,
        None,
        restrict_sources,
    )
    .await;
    (customer_repo, api_key_repo)
}

#[derive(Clone)]
pub struct TestApiKeyRateLimitClock {
    now: Arc<Mutex<Instant>>,
}

impl TestApiKeyRateLimitClock {
    pub fn new() -> Self {
        Self {
            now: Arc::new(Mutex::new(Instant::now())),
        }
    }

    pub fn advance(&self, duration: Duration) {
        *self.now.lock().unwrap() += duration;
    }

    fn limiter(&self) -> RateLimiter {
        let now = self.now.clone();
        RateLimiter::new_dynamic_with_clock(Duration::from_secs(3600), move || *now.lock().unwrap())
    }
}

pub struct ApiKeyRateLimitSetup {
    pub customer_id: uuid::Uuid,
    pub primary_key: ApiKeyRow,
    pub secondary_key: ApiKeyRow,
    pub clock: TestApiKeyRateLimitClock,
    customer_repo: Arc<super::MockCustomerRepo>,
    api_key_repo: Arc<super::MockApiKeyRepo>,
}

impl ApiKeyRateLimitSetup {
    pub fn build_app(&self) -> Router {
        build_test_app_with_rate_limiter(
            self.customer_repo.clone(),
            self.api_key_repo.clone(),
            self.clock.limiter(),
        )
    }
}

pub async fn seed_rate_limit_setup(
    primary_limit: Option<i32>,
    secondary_limit: Option<i32>,
) -> ApiKeyRateLimitSetup {
    let customer_repo = super::mock_repo();
    let api_key_repo = super::mock_api_key_repo();
    let customer = customer_repo.seed("Acme Corp", "acme@example.com");
    let primary_key = create_managed_test_key_with_options(
        &api_key_repo,
        customer.id,
        TEST_KEY,
        ManagedTestKeyOptions {
            max_queries_per_ip_per_hour: primary_limit,
            ..Default::default()
        },
    )
    .await;
    let secondary_key = create_managed_test_key_with_options(
        &api_key_repo,
        customer.id,
        SECOND_TEST_KEY,
        ManagedTestKeyOptions {
            max_queries_per_ip_per_hour: secondary_limit,
            ..Default::default()
        },
    )
    .await;

    ApiKeyRateLimitSetup {
        customer_id: customer.id,
        primary_key,
        secondary_key,
        clock: TestApiKeyRateLimitClock::new(),
        customer_repo,
        api_key_repo,
    }
}

pub async fn assert_none_limit_remains_unlimited() {
    let setup = seed_rate_limit_setup(None, None).await;
    let app = setup.build_app();

    for _ in 0..3 {
        assert_socket_auth_success(
            &app,
            TEST_KEY,
            "203.0.113.20:44321",
            setup.customer_id,
            setup.primary_key.id,
        )
        .await;
    }
}

pub async fn assert_hourly_limit_retry_after_and_bucket_isolation() {
    let setup = seed_rate_limit_setup(Some(2), Some(1)).await;
    let app = setup.build_app();

    assert_socket_auth_status(&app, TEST_KEY, "203.0.113.20:44321", StatusCode::OK).await;
    assert_socket_auth_status(&app, TEST_KEY, "203.0.113.20:44321", StatusCode::OK).await;
    assert_socket_rate_limited(&app, TEST_KEY, "203.0.113.20:44321", "3600").await;
    assert_socket_auth_status(&app, TEST_KEY, "203.0.113.21:44321", StatusCode::OK).await;
    assert_socket_auth_success(
        &app,
        SECOND_TEST_KEY,
        "203.0.113.20:44321",
        setup.customer_id,
        setup.secondary_key.id,
    )
    .await;
}

pub async fn assert_hourly_limit_reopens_at_boundary() {
    let setup = seed_rate_limit_setup(Some(1), None).await;
    let app = setup.build_app();

    assert_socket_auth_status(&app, TEST_KEY, "203.0.113.20:44321", StatusCode::OK).await;
    assert_socket_auth_status(
        &app,
        TEST_KEY,
        "203.0.113.20:44321",
        StatusCode::TOO_MANY_REQUESTS,
    )
    .await;
    setup.clock.advance(Duration::from_secs(3600));
    assert_socket_auth_success(
        &app,
        TEST_KEY,
        "203.0.113.20:44321",
        setup.customer_id,
        setup.primary_key.id,
    )
    .await;
}

pub async fn assert_non_positive_limit_fails_closed() {
    let setup = seed_rate_limit_setup(Some(0), None).await;
    let app = setup.build_app();

    assert_socket_invalid_token(&app, TEST_KEY, "203.0.113.20:44321").await;
}

pub async fn send_gridl_test_request(app: Router) -> axum::response::Response {
    let request = Request::get("/test")
        .header("authorization", format!("Bearer {GRIDL_KEY}"))
        .body(Body::empty())
        .unwrap();

    app.oneshot(request).await.unwrap()
}

pub async fn extract_gridl_auth_with_decision(
    decision: Stage1ApiKeyCompatDecision,
    key: &str,
    key_prefix: &str,
) -> Result<ApiKeyAuth, api::auth::error::AuthError> {
    let customer_repo = super::mock_repo();
    let api_key_repo = super::mock_api_key_repo();

    let customer = customer_repo.seed("Flapjack Cloud Corp", "customer@example.com");
    api_key_repo.seed(
        customer.id,
        "gridl-key",
        &hash_key(key),
        key_prefix,
        vec!["read".into(), "search".into()],
    );

    let state = super::test_state_with_api_key_repo(customer_repo, api_key_repo);
    let request = Request::get("/test")
        .header("authorization", format!("Bearer {key}"))
        .body(Body::empty())
        .unwrap();
    let (mut parts, _) = request.into_parts();

    ApiKeyAuth::from_request_parts_with_stage1_decision(&mut parts, &state, decision).await
}

//! S3 integration tests — full router stack with auth middleware, rate limiting,
//! route wiring, and end-to-end request lifecycle.
//!
//! Tests use `build_s3_router` with properly signed SigV4 requests, wiremock for
//! Garage, and `tower::ServiceExt::oneshot` for request dispatch.

mod common;
mod storage_s3_auth_support;
#[allow(dead_code)]
#[path = "common/storage_s3_signed_router_harness.rs"]
mod storage_s3_signed_router_harness;

use api::models::storage::{NewStorageBucket, PreparedStorageAccessKey};
use api::repos::in_memory_storage_key_repo::InMemoryStorageKeyRepo;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::CustomerRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::router::build_s3_router;
use api::services::storage::encryption::encrypt_secret;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::mocks::MockCustomerRepo;
use common::storage_metering_test_support::{wait_for_bucket_egress, wait_for_bucket_totals};
use common::TestStateBuilder;
use http_body_util::BodyExt;
use std::sync::Arc;
use storage_s3_signed_router_harness::{
    s3_test_config, setup_signed_s3_router, setup_signed_s3_router_with_rps, signed_s3_request,
    SignedS3RouterHarness, TEST_MASTER_KEY,
};
use tower::ServiceExt;
use uuid::Uuid;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

type IntegrationSetup = SignedS3RouterHarness;

async fn setup() -> IntegrationSetup {
    setup_signed_s3_router().await
}

async fn setup_with_rps(rps: u32) -> IntegrationSetup {
    setup_signed_s3_router_with_rps(rps).await
}

fn signed_req(
    method_val: &str,
    uri: &str,
    access_key: &str,
    secret_key: &str,
    body: Vec<u8>,
) -> Request<Body> {
    signed_s3_request(method_val, uri, access_key, secret_key, body)
}

async fn body_string(body: Body) -> String {
    let bytes = body.collect().await.expect("body collect").to_bytes();
    String::from_utf8(bytes.to_vec()).expect("body should be utf8")
}

#[tokio::test]
async fn shared_signed_router_harness_smoke_lists_seeded_bucket() {
    let s = setup_signed_s3_router().await;
    let req = signed_s3_request("GET", "/", &s.access_key, &s.secret_key, vec![]);
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

// ---------------------------------------------------------------------------
// Lifecycle: PutObject → GetObject → DeleteObject with metering
// ---------------------------------------------------------------------------

#[tokio::test]
async fn lifecycle_put_get_delete_with_metering() {
    let s = setup().await;
    let upload_body = b"hello-world-content".to_vec();

    // 1. PutObject
    Mock::given(method("PUT"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(200).insert_header("etag", "\"abc123\""))
        .expect(1)
        .mount(&s.mock)
        .await;

    let req = signed_req(
        "PUT",
        "/my-bucket/my-key.txt",
        &s.access_key,
        &s.secret_key,
        upload_body.clone(),
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_bucket_totals(
        s.bucket_repo.as_ref(),
        s.bucket.id,
        upload_body.len() as i64,
        1,
    )
    .await;
    let updated = s.bucket_repo.get(s.bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, upload_body.len() as i64);
    assert_eq!(updated.object_count, 1);

    // 2. GetObject
    Mock::given(method("GET"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(upload_body.clone())
                .insert_header("content-length", upload_body.len().to_string()),
        )
        .expect(1)
        .mount(&s.mock)
        .await;

    let req = signed_req(
        "GET",
        "/my-bucket/my-key.txt",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_bucket_egress(
        s.bucket_repo.as_ref(),
        s.bucket.id,
        upload_body.len() as i64,
    )
    .await;
    let updated = s.bucket_repo.get(s.bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.egress_bytes, upload_body.len() as i64);

    // 3. DeleteObject (HEAD for size, then DELETE)
    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-length", upload_body.len().to_string()),
        )
        .expect(1)
        .mount(&s.mock)
        .await;

    Mock::given(method("DELETE"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&s.mock)
        .await;

    let req = signed_req(
        "DELETE",
        "/my-bucket/my-key.txt",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    wait_for_bucket_totals(s.bucket_repo.as_ref(), s.bucket.id, 0, 0).await;
    let updated = s.bucket_repo.get(s.bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, 0);
    assert_eq!(updated.object_count, 0);
}

// ---------------------------------------------------------------------------
// Auth middleware rejects unauthenticated requests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn unauthenticated_request_returns_s3_xml_error() {
    let s = setup().await;

    let req = Request::builder()
        .method("GET")
        .uri("/")
        .body(Body::empty())
        .unwrap();

    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<Code>AuthorizationHeaderMalformed</Code>"));
}

// ---------------------------------------------------------------------------
// Rate limiting returns SlowDown XML
// ---------------------------------------------------------------------------

#[tokio::test]
async fn rate_limit_burst_returns_slowdown_xml() {
    let s = setup_with_rps(2).await;

    // Send 3 requests — first 2 pass, 3rd is rate limited
    for i in 0..3 {
        let req = signed_req("GET", "/", &s.access_key, &s.secret_key, vec![]);
        let resp = s.router.clone().oneshot(req).await.unwrap();

        if i < 2 {
            assert_eq!(resp.status(), StatusCode::OK, "request {i} should pass");
        } else {
            assert_eq!(
                resp.status(),
                StatusCode::SERVICE_UNAVAILABLE,
                "request {i} should be rate limited"
            );
            let body = body_string(resp.into_body()).await;
            assert!(body.contains("<Code>SlowDown</Code>"));
            assert!(body.contains("reduce your request rate"));
        }
    }
}

// ---------------------------------------------------------------------------
// Tenant isolation: wrong bucket key returns AccessDenied
// ---------------------------------------------------------------------------

#[tokio::test]
async fn wrong_bucket_key_returns_access_denied() {
    let s = setup().await;

    // Create a second bucket — key is scoped to the first bucket
    s.bucket_repo
        .create(
            NewStorageBucket {
                customer_id: s.customer_id,
                name: "other-bucket".to_string(),
            },
            "gridl-internal-other",
        )
        .await
        .expect("seed second bucket");

    // HEAD other-bucket with key scoped to my-bucket → AccessDenied
    let req = signed_req(
        "HEAD",
        "/other-bucket",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    // HEAD errors have no body, just status
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ---------------------------------------------------------------------------
// Garage error propagation
// ---------------------------------------------------------------------------

#[tokio::test]
async fn garage_404_propagated_to_client() {
    let s = setup().await;

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123/nonexistent.txt"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_string(
                    "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>",
                )
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&s.mock)
        .await;

    let req = signed_req(
        "GET",
        "/my-bucket/nonexistent.txt",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("NoSuchKey"));
}

// ---------------------------------------------------------------------------
// Security headers present on S3 responses
// ---------------------------------------------------------------------------

#[tokio::test]
async fn security_headers_present_on_s3_response() {
    let s = setup().await;

    let req = signed_req("GET", "/", &s.access_key, &s.secret_key, vec![]);
    let resp = s.router.clone().oneshot(req).await.unwrap();

    assert!(resp.headers().get("strict-transport-security").is_some());
    assert!(resp.headers().get("x-content-type-options").is_some());
    assert!(resp.headers().get("x-frame-options").is_some());
}

// ---------------------------------------------------------------------------
// Suspended customer is rejected on S3 auth path
// ---------------------------------------------------------------------------

#[tokio::test]
async fn suspended_customer_returns_access_denied() {
    let mock = MockServer::start().await;
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());

    let customer = customer_repo.seed("Acme", "acme@example.com");

    let garage_proxy = Arc::new(GarageProxy::new(
        reqwest::Client::new(),
        GarageProxyConfig {
            endpoint: mock.uri(),
            access_key: "garage-admin-key".to_string(),
            secret_key: "garage-admin-secret".to_string(),
            region: "garage".to_string(),
        },
    ));

    let bucket = bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "test-bucket".to_string(),
            },
            "gridl-internal-susp",
        )
        .await
        .expect("seed bucket");

    let access_key = "gridl_s3_suspendedtest01abc".to_string();
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY02".to_string();
    let (enc, nonce) = encrypt_secret(&secret_key, &TEST_MASTER_KEY).expect("encrypt");
    key_repo
        .create(PreparedStorageAccessKey {
            customer_id: customer.id,
            bucket_id: bucket.id,
            access_key: access_key.clone(),
            garage_access_key_id: format!("garage-{}", Uuid::new_v4()),
            secret_key_enc: enc,
            secret_key_nonce: nonce,
            label: "test".to_string(),
        })
        .await
        .expect("seed key");

    // Suspend the customer
    customer_repo
        .suspend(customer.id)
        .await
        .expect("suspend should succeed");

    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_storage_bucket_repo(bucket_repo)
        .with_storage_key_repo(key_repo)
        .with_garage_proxy(garage_proxy)
        .with_storage_master_key(TEST_MASTER_KEY)
        .build();

    let cfg = s3_test_config(100);
    let router = build_s3_router(state, &cfg);

    // Valid SigV4 request from suspended customer must return 403
    let req = signed_req(
        "GET",
        "/test-bucket/file.txt",
        &access_key,
        &secret_key,
        vec![],
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<Code>AccessDenied</Code>"),
        "suspended customer should get AccessDenied, got: {body}"
    );

    // Verify no request reached Garage
    assert_eq!(mock.received_requests().await.unwrap().len(), 0);
}

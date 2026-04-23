//! S3 bucket route handler tests.
//!
//! Tests bucket CRUD operations against the route handlers using
//! `tower::ServiceExt::oneshot`. S3AuthContext is injected via request
//! extensions (simulating the auth middleware path).

mod common;

use api::models::storage::NewStorageBucket;
use api::repos::InMemoryStorageBucketRepo;
use api::routes::storage::buckets;
use api::services::storage::s3_auth::S3AuthContext;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use axum::routing::{get, put};
use axum::Router;
use common::TestStateBuilder;
use http_body_util::BodyExt;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn setup() -> (
    MockServer,
    Arc<InMemoryStorageBucketRepo>,
    Router,
    Uuid,
    Uuid,
) {
    let mock = MockServer::start().await;
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let customer_id = Uuid::new_v4();
    let bucket_id = Uuid::new_v4();
    let garage_proxy = Arc::new(GarageProxy::new(
        reqwest::Client::new(),
        GarageProxyConfig {
            endpoint: mock.uri(),
            access_key: "test-access-key".to_string(),
            secret_key: "test-secret-key".to_string(),
            region: "garage".to_string(),
        },
    ));
    let state = TestStateBuilder::new()
        .with_storage_bucket_repo(bucket_repo.clone())
        .with_garage_proxy(garage_proxy)
        .build();

    let router = Router::new()
        .route("/", get(buckets::list_buckets))
        .route(
            "/:bucket",
            put(buckets::create_bucket)
                .head(buckets::head_bucket)
                .delete(buckets::delete_bucket)
                .get(buckets::list_objects_v2),
        )
        .with_state(state);

    (mock, bucket_repo, router, customer_id, bucket_id)
}

fn s3_request(method_val: Method, uri: &str, customer_id: Uuid, bucket_id: Uuid) -> Request<Body> {
    let mut req = Request::builder()
        .method(method_val)
        .uri(uri)
        .body(Body::empty())
        .expect("request should build");
    req.extensions_mut().insert(S3AuthContext {
        access_key: "test-access-key".to_string(),
        customer_id,
        bucket_id,
    });
    req
}

async fn seed_bucket(
    repo: &InMemoryStorageBucketRepo,
    customer_id: Uuid,
    name: &str,
    garage_bucket: &str,
) -> api::models::storage::StorageBucket {
    use api::repos::storage_bucket_repo::StorageBucketRepo;
    repo.create(
        NewStorageBucket {
            customer_id,
            name: name.to_string(),
        },
        garage_bucket,
    )
    .await
    .expect("seed bucket should succeed")
}

async fn body_string(body: Body) -> String {
    let bytes = body.collect().await.expect("body collect").to_bytes();
    String::from_utf8(bytes.to_vec()).expect("body should be utf8")
}

// ---------------------------------------------------------------------------
// ListBuckets tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_buckets_empty_returns_xml() {
    let (_mock, _repo, router, customer_id, bucket_id) = setup().await;
    let req = s3_request(Method::GET, "/", customer_id, bucket_id);
    let resp = router.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let content_type = resp
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(content_type.contains("application/xml"));
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<ListAllMyBucketsResult"));
    assert!(body.contains("<Buckets/>"));
}

#[tokio::test]
async fn list_buckets_only_returns_authenticated_bucket() {
    let (_mock, repo, router, customer_id, _bucket_id) = setup().await;
    let authorized_bucket =
        seed_bucket(&repo, customer_id, "my-bucket", "gridl-internal-123").await;
    seed_bucket(&repo, customer_id, "other-bucket", "gridl-internal-456").await;

    let req = s3_request(Method::GET, "/", customer_id, authorized_bucket.id);
    let resp = router.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<Name>my-bucket</Name>"));
    assert!(!body.contains("<Name>other-bucket</Name>"));
}

// ---------------------------------------------------------------------------
// HeadBucket tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn head_bucket_forwards_to_garage() {
    let (mock, repo, router, customer_id, _bucket_id) = setup().await;
    let bucket = seed_bucket(&repo, customer_id, "my-bucket", "gridl-internal-123").await;

    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123"))
        .and(header("x-amz-request-payer", "requester"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock)
        .await;

    let mut req = s3_request(Method::HEAD, "/my-bucket", customer_id, bucket.id);
    req.headers_mut().insert(
        "x-amz-request-payer",
        "requester".parse().expect("valid header"),
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn head_bucket_nonexistent_returns_not_found() {
    let (_mock, _repo, router, customer_id, bucket_id) = setup().await;

    let req = s3_request(Method::HEAD, "/nonexistent", customer_id, bucket_id);
    let resp = router.oneshot(req).await.unwrap();

    // HEAD responses have no body — only status code is verifiable.
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn head_bucket_wrong_bucket_id_returns_forbidden() {
    let (_mock, repo, router, customer_id, _bucket_id) = setup().await;
    let _bucket = seed_bucket(&repo, customer_id, "my-bucket", "gridl-internal-123").await;
    let wrong_bucket_id = Uuid::new_v4(); // Different from bucket.id

    let req = s3_request(Method::HEAD, "/my-bucket", customer_id, wrong_bucket_id);
    let resp = router.oneshot(req).await.unwrap();

    // HEAD responses have no body — only status code is verifiable.
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ---------------------------------------------------------------------------
// ListObjectsV2 tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_objects_v2_forwards_query_to_garage() {
    let (mock, repo, router, customer_id, _bucket_id) = setup().await;
    let bucket = seed_bucket(&repo, customer_id, "my-bucket", "gridl-internal-123").await;

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123"))
        .and(header("x-amz-request-payer", "requester"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string("<ListBucketResult/>")
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let mut req = s3_request(
        Method::GET,
        "/my-bucket?list-type=2&prefix=docs/",
        customer_id,
        bucket.id,
    );
    req.headers_mut().insert(
        "x-amz-request-payer",
        "requester".parse().expect("valid header"),
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

// ---------------------------------------------------------------------------
// CreateBucket tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_bucket_with_bucket_scoped_key_returns_access_denied() {
    let (_mock, _repo, router, customer_id, bucket_id) = setup().await;

    let req = s3_request(Method::PUT, "/new-bucket", customer_id, bucket_id);
    let resp = router.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<Code>AccessDenied</Code>"));
}

// ---------------------------------------------------------------------------
// DeleteBucket tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_bucket_nonexistent_returns_no_such_bucket() {
    let (_mock, _repo, router, customer_id, bucket_id) = setup().await;

    let req = s3_request(Method::DELETE, "/nonexistent", customer_id, bucket_id);
    let resp = router.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<Code>NoSuchBucket</Code>"));
}

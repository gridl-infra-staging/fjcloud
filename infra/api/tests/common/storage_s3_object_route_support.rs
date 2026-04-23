//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/storage_s3_object_route_support.rs.
use api::models::storage::{NewStorageBucket, StorageBucket};
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::routes::storage::objects;
use api::services::storage::s3_auth::S3AuthContext;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use axum::body::Body;
use axum::http::{Method, Request};
use axum::routing::put;
use axum::Router;
use http_body_util::BodyExt;
use std::sync::Arc;
use uuid::Uuid;
use wiremock::MockServer;

use super::TestStateBuilder;

/// Spins up a minimal object-route router for unit testing PUT/GET/DELETE/HEAD
/// object operations without going through the full SigV4 auth middleware.
///
/// Creates:
/// - A `wiremock` `MockServer` acting as the upstream Garage backend
/// - An `InMemoryStorageBucketRepo` pre-seeded with a `"my-bucket"` bucket
/// - A `GarageProxy` pointing at the mock server
/// - A bare axum [`Router`] with the four object handlers mounted at `/:bucket/*key`
///
/// Returns `(mock_server, bucket_repo, router, customer_id, bucket_id, bucket)`.
/// Tests inject auth context manually via `s3_request` / `s3_request_with_body`
/// rather than relying on the auth middleware, so this harness is suitable for
/// testing proxy forwarding and response mapping in isolation.
pub async fn setup_object_router() -> (
    MockServer,
    Arc<InMemoryStorageBucketRepo>,
    Router,
    Uuid,
    Uuid,
    StorageBucket,
) {
    let mock = MockServer::start().await;
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let customer_id = Uuid::new_v4();
    let garage_proxy = Arc::new(GarageProxy::new(
        reqwest::Client::new(),
        GarageProxyConfig {
            endpoint: mock.uri(),
            access_key: "test-access-key".to_string(),
            secret_key: "test-secret-key".to_string(),
            region: "garage".to_string(),
        },
    ));

    let bucket = bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: "my-bucket".to_string(),
            },
            "gridl-internal-123",
        )
        .await
        .expect("seed bucket");

    let state = TestStateBuilder::new()
        .with_storage_bucket_repo(bucket_repo.clone())
        .with_garage_proxy(garage_proxy)
        .build();

    let router = Router::new()
        .route(
            "/:bucket/*key",
            put(objects::put_object)
                .get(objects::get_object)
                .delete(objects::delete_object)
                .head(objects::head_object),
        )
        .with_state(state);

    (mock, bucket_repo, router, customer_id, bucket.id, bucket)
}

pub fn s3_request(method: Method, uri: &str, customer_id: Uuid, bucket_id: Uuid) -> Request<Body> {
    let mut req = Request::builder()
        .method(method)
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

/// Builds an axum [`Request`] with a non-empty body and a pre-injected
/// [`S3AuthContext`] extension, bypassing SigV4 signature verification.
///
/// Extends `s3_request` with a body payload so tests can drive PUT/POST
/// handlers that read the request body (e.g. object upload). The `S3AuthContext`
/// is populated with the fixed `"test-access-key"` and the caller-supplied
/// `customer_id` / `bucket_id`.
pub fn s3_request_with_body(
    method: Method,
    uri: &str,
    customer_id: Uuid,
    bucket_id: Uuid,
    body: Vec<u8>,
) -> Request<Body> {
    let mut req = Request::builder()
        .method(method)
        .uri(uri)
        .body(Body::from(body))
        .expect("request should build");
    req.extensions_mut().insert(S3AuthContext {
        access_key: "test-access-key".to_string(),
        customer_id,
        bucket_id,
    });
    req
}

pub async fn body_string(body: Body) -> String {
    let bytes = body.collect().await.expect("body collect").to_bytes();
    String::from_utf8(bytes.to_vec()).expect("body should be utf8")
}

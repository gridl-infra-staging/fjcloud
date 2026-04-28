//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/tests/common/storage_s3_signed_router_harness.rs.
use api::config::Config;
use api::models::storage::{NewStorageBucket, PreparedStorageAccessKey, StorageBucket};
use api::repos::in_memory_storage_key_repo::InMemoryStorageKeyRepo;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::router::build_s3_router;
use api::services::storage::encryption::encrypt_secret;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use axum::body::Body;
use axum::http::Request;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use uuid::Uuid;
use wiremock::MockServer;

use crate::common::mocks::{mock_garage_admin_client, MockCustomerRepo, MockGarageAdminClient};
use crate::common::TestStateBuilder;
use crate::storage_s3_auth_support::SigningRequest;

pub(crate) const TEST_MASTER_KEY: [u8; 32] = [0x42; 32];

pub(crate) struct SignedS3RouterHarness {
    pub mock: MockServer,
    pub bucket_repo: Arc<InMemoryStorageBucketRepo>,
    pub key_repo: Arc<InMemoryStorageKeyRepo>,
    pub garage_admin_client: Arc<MockGarageAdminClient>,
    pub router: axum::Router,
    pub customer_id: Uuid,
    pub bucket: StorageBucket,
    pub access_key: String,
    pub secret_key: String,
}

/// Builds a minimal [`Config`] for S3 router tests with a caller-supplied RPS limit.
///
/// Uses dummy values for everything except `s3_rate_limit_rps` and the auth
/// secrets (which match the constants in `TestStateBuilder`). This config is
/// passed to `build_s3_router` to apply rate-limiting middleware; tests that
/// exercise rate-limit enforcement pass a low `rps` value, while normal path
/// tests use a high value to avoid spurious 429 responses.
pub(crate) fn s3_test_config(rps: u32) -> Config {
    Config {
        database_url: "postgres://fake".to_string(),
        listen_addr: "0.0.0.0:3001".to_string(),
        s3_listen_addr: "0.0.0.0:3002".to_string(),
        s3_rate_limit_rps: rps,
        jwt_secret: "test-jwt-secret-min-32-chars-ok!".to_string(),
        admin_key: "test-admin-key-16".to_string(),
        stripe_secret_key: None,
        stripe_publishable_key: None,
        stripe_webhook_secret: None,
        stripe_success_url: "http://localhost".to_string(),
        stripe_cancel_url: "http://localhost".to_string(),
        internal_auth_token: None,
    }
}

pub(crate) async fn setup_signed_s3_router() -> SignedS3RouterHarness {
    setup_signed_s3_router_with_rps(100).await
}

/// Sets up a complete S3 signed-request test harness with a configurable rate limit.
///
/// Provisions:
/// - A `wiremock` `MockServer` acting as the upstream Garage backend
/// - In-memory bucket and key repos pre-seeded with a `"my-bucket"` bucket and
///   one AES-encrypted access key (`access_key` / `secret_key`)
/// - A `GarageProxy` pointed at the mock server so forwarded requests are
///   captured rather than sent to a real Garage instance
/// - An axum S3 router built via `build_s3_router` with the given `rps` limit
///
/// The returned [`SignedS3RouterHarness`] exposes the mock server, repos,
/// router, seeded credentials, and bucket so tests can enqueue wiremock
/// responses and drive requests through the full SigV4-auth + proxy pipeline.
pub(crate) async fn setup_signed_s3_router_with_rps(rps: u32) -> SignedS3RouterHarness {
    let mock = MockServer::start().await;
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
    let garage_admin_client = mock_garage_admin_client();
    let customer = customer_repo.seed("integration-test", "s3@test.com");
    let customer_id = customer.id;

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
                customer_id,
                name: "my-bucket".to_string(),
            },
            "gridl-internal-123",
        )
        .await
        .expect("seed bucket");

    let access_key = "gridl_s3_integrationtest1ab".to_string();
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01".to_string();
    let (enc, nonce) = encrypt_secret(&secret_key, &TEST_MASTER_KEY).expect("encrypt");
    key_repo
        .create(PreparedStorageAccessKey {
            customer_id,
            bucket_id: bucket.id,
            access_key: access_key.clone(),
            garage_access_key_id: format!("garage-{}", Uuid::new_v4()),
            secret_key_enc: enc,
            secret_key_nonce: nonce,
            label: "test".to_string(),
        })
        .await
        .expect("seed key");

    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_storage_bucket_repo(bucket_repo.clone())
        .with_storage_key_repo(key_repo.clone())
        .with_garage_admin_client(garage_admin_client.clone())
        .with_garage_proxy(garage_proxy)
        .with_storage_master_key(TEST_MASTER_KEY)
        .build();

    let cfg = s3_test_config(rps);
    let router = build_s3_router(state, &cfg);

    SignedS3RouterHarness {
        mock,
        bucket_repo,
        key_repo,
        garage_admin_client,
        router,
        customer_id,
        bucket,
        access_key,
        secret_key,
    }
}

/// Builds a fully SigV4-signed axum [`Request`] ready to send to the S3 router.
///
/// Computes the SHA-256 payload hash, constructs the `x-amz-date` timestamp,
/// and uses [`SigningRequest::sign`] to generate the `Authorization` header.
/// The `host` header is set to `"s3.flapjack.foo"` to match the expected virtual-
/// host value that the S3 auth middleware validates.
///
/// The resulting request includes all required headers (`host`, `x-amz-date`,
/// `x-amz-content-sha256`, `authorization`) so it will pass SigV4 verification
/// when the `access_key` / `secret_key` match a seeded key in the key repo.
pub(crate) fn signed_s3_request(
    method_val: &str,
    uri: &str,
    access_key: &str,
    secret_key: &str,
    body: Vec<u8>,
) -> Request<Body> {
    let now = chrono::Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let payload_hash = hex::encode(Sha256::digest(&body));

    let headers: Vec<(&str, &str)> = vec![
        ("host", "s3.flapjack.foo"),
        ("x-amz-date", &amz_date),
        ("x-amz-content-sha256", &payload_hash),
    ];

    let auth = SigningRequest {
        method: method_val,
        uri,
        headers: &headers,
        payload_hash: &payload_hash,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    Request::builder()
        .method(method_val)
        .uri(uri)
        .header("host", "s3.flapjack.foo")
        .header("x-amz-date", &amz_date)
        .header("x-amz-content-sha256", &payload_hash)
        .header("authorization", &auth)
        .body(Body::from(body))
        .expect("request should build")
}

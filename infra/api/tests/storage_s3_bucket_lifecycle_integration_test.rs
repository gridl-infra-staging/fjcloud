//! S3 bucket lifecycle integration tests split from storage_s3_integration_test
//! to keep test files below repo warning thresholds.

mod common;
mod storage_s3_auth_support;
#[allow(dead_code)]
#[path = "common/storage_s3_signed_router_harness.rs"]
mod storage_s3_signed_router_harness;

use api::models::storage::{NewStorageBucket, PreparedStorageAccessKey};
use api::repos::in_memory_storage_key_repo::InMemoryStorageKeyRepo;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::InMemoryStorageBucketRepo;
use api::router::build_s3_router;
use api::services::storage::encryption::encrypt_secret;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig};
use api::services::storage::{GarageAdminClient, GarageBucketInfo, GarageKeyInfo, StorageError};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::StatusCode;
use common::mocks::MockCustomerRepo;
use common::TestStateBuilder;
use http_body_util::BodyExt;
use std::sync::{Arc, Mutex};
use storage_s3_signed_router_harness::{
    s3_test_config, setup_signed_s3_router, signed_s3_request, SignedS3RouterHarness,
    TEST_MASTER_KEY,
};
use tower::ServiceExt;
use uuid::Uuid;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

type IntegrationSetup = SignedS3RouterHarness;

#[derive(Default)]
struct DeleteFailingGarageAdminClient {
    delete_bucket_calls: Mutex<Vec<String>>,
}

impl DeleteFailingGarageAdminClient {
    fn new() -> Self {
        Self::default()
    }

    fn delete_bucket_calls(&self) -> Vec<String> {
        self.delete_bucket_calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl GarageAdminClient for DeleteFailingGarageAdminClient {
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError> {
        Ok(GarageBucketInfo {
            id: format!("garage-bucket-{name}"),
        })
    }

    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError> {
        Ok(GarageBucketInfo {
            id: format!("garage-bucket-{global_alias}"),
        })
    }

    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError> {
        self.delete_bucket_calls
            .lock()
            .unwrap()
            .push(id.to_string());
        Err(StorageError::GarageAdmin(
            "forced delete failure for regression guard".to_string(),
        ))
    }

    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError> {
        Ok(GarageKeyInfo {
            id: format!("garage-key-{name}"),
            secret_key: "mock-garage-secret".to_string(),
        })
    }

    async fn delete_key(&self, _id: &str) -> Result<(), StorageError> {
        Ok(())
    }

    async fn allow_key(
        &self,
        _bucket_id: &str,
        _key_id: &str,
        _allow_read: bool,
        _allow_write: bool,
    ) -> Result<(), StorageError> {
        Ok(())
    }
}

#[derive(Default)]
struct MissingBucketGarageAdminClient {
    get_bucket_calls: Mutex<Vec<String>>,
    delete_bucket_calls: Mutex<Vec<String>>,
    delete_key_calls: Mutex<Vec<String>>,
}

impl MissingBucketGarageAdminClient {
    fn new() -> Self {
        Self::default()
    }

    fn get_bucket_calls(&self) -> Vec<String> {
        self.get_bucket_calls.lock().unwrap().clone()
    }

    fn delete_bucket_calls(&self) -> Vec<String> {
        self.delete_bucket_calls.lock().unwrap().clone()
    }

    fn delete_key_calls(&self) -> Vec<String> {
        self.delete_key_calls.lock().unwrap().clone()
    }
}

#[async_trait]
impl GarageAdminClient for MissingBucketGarageAdminClient {
    async fn create_bucket(&self, name: &str) -> Result<GarageBucketInfo, StorageError> {
        Ok(GarageBucketInfo {
            id: format!("garage-bucket-{name}"),
        })
    }

    async fn get_bucket_by_alias(
        &self,
        global_alias: &str,
    ) -> Result<GarageBucketInfo, StorageError> {
        self.get_bucket_calls
            .lock()
            .unwrap()
            .push(global_alias.to_string());
        Err(StorageError::GarageAdmin(
            "get bucket info returned HTTP 404: bucket already deleted".to_string(),
        ))
    }

    async fn delete_bucket(&self, id: &str) -> Result<(), StorageError> {
        self.delete_bucket_calls
            .lock()
            .unwrap()
            .push(id.to_string());
        Ok(())
    }

    async fn create_key(&self, name: &str) -> Result<GarageKeyInfo, StorageError> {
        Ok(GarageKeyInfo {
            id: format!("garage-key-{name}"),
            secret_key: "mock-garage-secret".to_string(),
        })
    }

    async fn delete_key(&self, id: &str) -> Result<(), StorageError> {
        self.delete_key_calls.lock().unwrap().push(id.to_string());
        Ok(())
    }

    async fn allow_key(
        &self,
        _bucket_id: &str,
        _key_id: &str,
        _allow_read: bool,
        _allow_write: bool,
    ) -> Result<(), StorageError> {
        Ok(())
    }
}

async fn setup() -> IntegrationSetup {
    setup_signed_s3_router().await
}

fn signed_req(
    method_val: &str,
    uri: &str,
    access_key: &str,
    secret_key: &str,
    body: Vec<u8>,
) -> axum::http::Request<Body> {
    signed_s3_request(method_val, uri, access_key, secret_key, body)
}

async fn body_string(body: Body) -> String {
    let bytes = body.collect().await.expect("body collect").to_bytes();
    String::from_utf8(bytes.to_vec()).expect("body should be utf8")
}

#[tokio::test]
async fn bucket_list_returns_seeded_bucket() {
    let s = setup().await;

    let req = signed_req("GET", "/", &s.access_key, &s.secret_key, vec![]);
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<Name>my-bucket</Name>"),
        "ListBuckets should include seeded bucket, got: {body}"
    );
}

#[tokio::test]
async fn list_objects_v2_proxied_to_garage() {
    let s = setup().await;

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123"))
        .and(query_param("list-type", "2"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string(
                    "<ListBucketResult><Name>gridl-internal-123</Name><KeyCount>0</KeyCount></ListBucketResult>",
                )
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&s.mock)
        .await;

    let req = signed_req(
        "GET",
        "/my-bucket?list-type=2",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<ListBucketResult"),
        "ListObjectsV2 should return proxied XML, got: {body}"
    );
}

#[tokio::test]
async fn delete_bucket_soft_deletes_bucket_and_revokes_key() {
    let s = setup().await;

    let req = signed_req("DELETE", "/my-bucket", &s.access_key, &s.secret_key, vec![]);
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let bucket = s
        .bucket_repo
        .get(s.bucket.id)
        .await
        .expect("bucket lookup should succeed")
        .expect("bucket should still exist as a soft-deleted row");
    assert_eq!(bucket.status, "deleted");

    let active_key = s
        .key_repo
        .get_by_access_key(&s.access_key)
        .await
        .expect("key lookup should succeed");
    assert!(
        active_key.is_none(),
        "DeleteBucket should revoke the bucket-scoped access key"
    );
    assert_eq!(
        s.garage_admin_client.deleted_bucket_ids(),
        vec!["garage-bucket-gridl-internal-123".to_string()],
        "DeleteBucket should invoke Garage admin deletion via StorageService"
    );
}

#[tokio::test]
async fn delete_bucket_returns_internal_error_when_garage_delete_fails() {
    let mock = MockServer::start().await;
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
    let failing_garage_admin = Arc::new(DeleteFailingGarageAdminClient::new());
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
    let access_key = "gridl_s3_deletefailure01".to_string();
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY03".to_string();
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
        .with_garage_admin_client(failing_garage_admin.clone())
        .with_garage_proxy(garage_proxy)
        .with_storage_master_key(TEST_MASTER_KEY)
        .build();
    let router = build_s3_router(state, &s3_test_config(100));
    let req = signed_req("DELETE", "/my-bucket", &access_key, &secret_key, vec![]);
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<Code>InternalError</Code>"),
        "DeleteBucket garage failure should return S3 InternalError, got: {body}"
    );
    let bucket_after = bucket_repo
        .get(bucket.id)
        .await
        .expect("bucket lookup should succeed")
        .expect("bucket row should still exist");
    assert_eq!(
        bucket_after.status, "active",
        "bucket should remain active when Garage delete fails"
    );
    let key_after = key_repo
        .get_by_access_key(&access_key)
        .await
        .expect("key lookup should succeed");
    assert!(
        key_after.is_some(),
        "access key should remain active when Garage delete fails"
    );
    assert_eq!(
        failing_garage_admin.delete_bucket_calls(),
        vec!["garage-bucket-gridl-internal-123".to_string()],
        "regression guard: route must attempt exactly one Garage admin delete call"
    );
}

#[tokio::test]
async fn delete_bucket_completes_local_cleanup_after_prior_garage_delete() {
    let mock = MockServer::start().await;
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let bucket_repo = Arc::new(InMemoryStorageBucketRepo::new());
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
    let garage_admin = Arc::new(MissingBucketGarageAdminClient::new());
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
    let access_key = "gridl_s3_retrydeletecleanup".to_string();
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY04".to_string();
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
        .with_garage_admin_client(garage_admin.clone())
        .with_garage_proxy(garage_proxy)
        .with_storage_master_key(TEST_MASTER_KEY)
        .build();
    let router = build_s3_router(state, &s3_test_config(100));

    let req = signed_req("DELETE", "/my-bucket", &access_key, &secret_key, vec![]);
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let bucket_after = bucket_repo
        .get(bucket.id)
        .await
        .expect("bucket lookup should succeed")
        .expect("bucket row should still exist");
    assert_eq!(
        bucket_after.status, "deleted",
        "delete retry should still soft-delete the local bucket row"
    );
    let key_after = key_repo
        .get_by_access_key(&access_key)
        .await
        .expect("key lookup should succeed");
    assert!(
        key_after.is_none(),
        "delete retry should still revoke the local access key"
    );
    assert_eq!(
        garage_admin.get_bucket_calls(),
        vec!["gridl-internal-123".to_string()],
        "delete retry should still probe the Garage alias once"
    );
    assert!(
        garage_admin.delete_bucket_calls().is_empty(),
        "delete retry should not call Garage delete again after a 404 lookup"
    );
    assert_eq!(
        garage_admin.delete_key_calls().len(),
        1,
        "delete retry should still revoke the Garage access key"
    );
}

#[tokio::test]
async fn wrong_secret_returns_signature_does_not_match() {
    let s = setup().await;

    let req = signed_req(
        "GET",
        "/my-bucket/file.txt",
        &s.access_key,
        "WRONG_SECRET_THAT_WONT_VALIDATE_1234",
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<Code>SignatureDoesNotMatch</Code>"),
        "wrong secret should get SignatureDoesNotMatch, got: {body}"
    );
}

#[tokio::test]
async fn revoked_key_returns_invalid_access_key_id() {
    let s = setup().await;

    let key_row = s
        .key_repo
        .get_by_access_key(&s.access_key)
        .await
        .expect("lookup should succeed")
        .expect("key should exist");
    s.key_repo
        .revoke(key_row.id)
        .await
        .expect("revoke should succeed");

    let req = signed_req(
        "GET",
        "/my-bucket/file.txt",
        &s.access_key,
        &s.secret_key,
        vec![],
    );
    let resp = s.router.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let body = body_string(resp.into_body()).await;
    assert!(
        body.contains("<Code>InvalidAccessKeyId</Code>"),
        "revoked key should get InvalidAccessKeyId, got: {body}"
    );
}

//! SigV4 request authentication tests for Flapjack Cloud storage.
//!
//! Uses in-memory key repo + AES-encrypted secrets to validate the full
//! authenticate() path: valid signature, invalid signature, unknown key,
//! revoked key, and clock-skew rejection.

mod common;
mod storage_s3_auth_support;

use api::models::storage::PreparedStorageAccessKey;
use api::repos::in_memory_storage_key_repo::InMemoryStorageKeyRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::repos::CustomerRepo;
use api::services::storage::encryption::encrypt_secret;
use api::services::storage::s3_auth::{S3AuthError, S3AuthService};
use chrono::Utc;
use common::mocks::MockCustomerRepo;
use std::sync::Arc;
use storage_s3_auth_support::{standard_headers, SigningRequest, EMPTY_SHA256};
use uuid::Uuid;

const TEST_MASTER_KEY: [u8; 32] = [0x42; 32];

struct TestHarness {
    auth_service: S3AuthService,
    key_repo: Arc<InMemoryStorageKeyRepo>,
    customer_repo: Arc<MockCustomerRepo>,
}

impl TestHarness {
    fn new() -> Self {
        let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
        let customer_repo = Arc::new(MockCustomerRepo::new());
        let auth_service = S3AuthService::new(
            key_repo.clone() as Arc<dyn StorageKeyRepo + Send + Sync>,
            customer_repo.clone(),
            TEST_MASTER_KEY,
        );
        Self {
            auth_service,
            key_repo,
            customer_repo,
        }
    }

    async fn insert_key_with_customer(&self, access_key: &str, secret_key: &str) -> (Uuid, Uuid) {
        let customer = self
            .customer_repo
            .seed("test", &format!("{access_key}@test.com"));
        let (enc, nonce) = encrypt_secret(secret_key, &TEST_MASTER_KEY).unwrap();
        let row = self
            .key_repo
            .create(PreparedStorageAccessKey {
                customer_id: customer.id,
                bucket_id: Uuid::new_v4(),
                access_key: access_key.to_string(),
                garage_access_key_id: format!("garage-{}", Uuid::new_v4()),
                secret_key_enc: enc,
                secret_key_nonce: nonce,
                label: "test".into(),
            })
            .await
            .unwrap();
        (row.id, customer.id)
    }

    async fn insert_key(&self, access_key: &str, secret_key: &str) -> Uuid {
        self.insert_key_with_customer(access_key, secret_key)
            .await
            .0
    }
}

#[tokio::test]
async fn valid_signed_request_authenticates() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_testkey12345678ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let req = SigningRequest {
        method: "GET",
        uri: "/my-bucket/my-key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    };
    let auth = req.sign();

    let mut all_headers: Vec<(&str, &str)> = headers.clone();
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", "/my-bucket/my-key", &all_headers)
        .await
        .expect("should authenticate");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn invalid_signature_is_rejected() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_invalidtest1234ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key: "WRONG_SECRET_KEY_THAT_WILL_NOT_MATCH_1234",
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/bucket/key", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::SignatureDoesNotMatch),
        "expected SignatureDoesNotMatch, got: {err:?}"
    );
}

#[tokio::test]
async fn unknown_access_key_is_rejected() {
    let h = TestHarness::new();

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key: "gridl_s3_nosuchthing1234ab",
        secret_key: "doesnt_matter_1234567890123456789012",
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::InvalidAccessKeyId),
        "expected InvalidAccessKeyId, got: {err:?}"
    );
}

#[tokio::test]
async fn revoked_key_is_rejected() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_revokedkey12345ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    let key_id = h.insert_key(access_key, secret_key).await;
    h.key_repo.revoke(key_id).await.unwrap();

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::InvalidAccessKeyId),
        "expected InvalidAccessKeyId, got: {err:?}"
    );
}

#[tokio::test]
async fn suspended_customer_is_rejected() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_suspended123456ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    let (_key_id, customer_id) = h.insert_key_with_customer(access_key, secret_key).await;
    h.customer_repo.suspend(customer_id).await.unwrap();

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::AccountDisabled),
        "expected AccountDisabled, got: {err:?}"
    );
}

#[tokio::test]
async fn clock_skew_beyond_15_minutes_is_rejected() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_clockskewtest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let skewed = Utc::now() - chrono::Duration::minutes(20);
    let amz_date = skewed.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &skewed,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::RequestTimeTooSkewed),
        "expected RequestTimeTooSkewed, got: {err:?}"
    );
}

#[tokio::test]
async fn canonical_query_params_sorted_correctly() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_querysorttest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let uri = "/my-bucket?z-param=last&a-param=first&m-param=middle";

    let auth = SigningRequest {
        method: "GET",
        uri,
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", uri, &all_headers)
        .await
        .expect("query param sorting should not break auth");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn authorization_header_without_spaces_after_commas_authenticates() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_commaparsetest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign()
    .replace(", ", ",");

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .expect("authorization parsing should accept optional whitespace after commas");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn repeated_headers_comma_joined_in_order() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_repeathdrtest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let mut headers = standard_headers(amz_date.as_str());
    headers.push(("x-amz-meta-tag", "alpha"));
    headers.push(("x-amz-meta-tag", "beta"));

    let auth = SigningRequest {
        method: "PUT",
        uri: "/my-bucket/obj",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("PUT", "/my-bucket/obj", &all_headers)
        .await
        .expect("repeated headers should be comma-joined and auth should pass");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn host_must_be_in_signed_headers() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_signedhosttest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign_with_signed_headers(&["x-amz-content-sha256", "x-amz-date"]);

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/bucket/key", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::MalformedAuth(_)),
        "expected malformed auth when host is omitted from SignedHeaders, got: {err:?}"
    );
}

#[tokio::test]
async fn credential_scope_must_match_request_date_and_s3_service() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_scopetest123456ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;
    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let previous_day = (now - chrono::Duration::days(1))
        .format("%Y%m%d")
        .to_string();

    let req = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    };

    let today = now.format("%Y%m%d").to_string();
    for auth in [
        req.sign_with_scope(&previous_day, "s3"),
        req.sign_with_scope(&today, "ec2"),
    ] {
        let mut all_headers: Vec<(&str, &str)> = headers.clone();
        all_headers.push(("authorization", auth.as_str()));
        let err = h
            .auth_service
            .authenticate("GET", "/", &all_headers)
            .await
            .unwrap_err();
        assert!(
            matches!(err, S3AuthError::MalformedAuth(_)),
            "expected malformed auth for invalid credential scope, got: {err:?}"
        );
    }
}

#[tokio::test]
async fn signed_headers_must_exist_in_request() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_missinghdrtest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign_with_signed_headers(&[
        "host",
        "x-amz-content-sha256",
        "x-amz-date",
        "x-amz-meta-missing",
    ]);

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/bucket/key", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::MalformedAuth(_)),
        "expected malformed auth when SignedHeaders references a missing header, got: {err:?}"
    );
}

#[tokio::test]
async fn header_whitespace_normalized() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_whitespacetest1ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = vec![
        ("host", "  s3.flapjack.foo  "),
        ("x-amz-date", amz_date.as_str()),
        ("x-amz-content-sha256", EMPTY_SHA256),
        ("x-amz-meta-desc", "  hello    world  "),
    ];

    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", "/bucket/key", &all_headers)
        .await
        .expect("whitespace normalization should not break auth");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn reserved_chars_in_path_and_query_are_uri_encoded() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_uriencodetest12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let uri = "/my-bucket/photos+raw/2026 03/image+1.jpg?prefix=summer+2026&marker=a+b";

    let auth = SigningRequest {
        method: "GET",
        uri,
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", uri, &all_headers)
        .await
        .expect("canonical URI and query encoding should match SigV4 rules");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn unsigned_payload_accepted() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_unsignedpayld12ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = vec![
        ("host", "s3.flapjack.foo"),
        ("x-amz-date", amz_date.as_str()),
        ("x-amz-content-sha256", "UNSIGNED-PAYLOAD"),
    ];

    let auth = SigningRequest {
        method: "PUT",
        uri: "/my-bucket/large-upload",
        headers: &headers,
        payload_hash: "UNSIGNED-PAYLOAD",
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("PUT", "/my-bucket/large-upload", &all_headers)
        .await
        .expect("UNSIGNED-PAYLOAD should be accepted");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn missing_content_sha256_header_is_rejected() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_nosha256test123ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = vec![
        ("host", "s3.flapjack.foo"),
        ("x-amz-date", amz_date.as_str()),
    ];

    let auth = SigningRequest {
        method: "PUT",
        uri: "/my-bucket/no-sha256",
        headers: &headers,
        payload_hash: "UNSIGNED-PAYLOAD",
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("PUT", "/my-bucket/no-sha256", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::MalformedAuth(_)),
        "expected malformed auth when x-amz-content-sha256 is missing, got: {err:?}"
    );
}

#[tokio::test]
async fn date_header_without_x_amz_date_authenticates() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_datehdrtest1234ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let date_header = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = vec![
        ("host", "s3.flapjack.foo"),
        ("date", date_header.as_str()),
        ("x-amz-content-sha256", EMPTY_SHA256),
    ];

    let auth = SigningRequest {
        method: "GET",
        uri: "/my-bucket/date-header",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", "/my-bucket/date-header", &all_headers)
        .await
        .expect("Date header in SigV4 basic format should be accepted when x-amz-date is absent");

    assert_eq!(ctx.access_key, access_key);
}

#[tokio::test]
async fn deleted_customer_returns_invalid_access_key_id() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_deletedcust1234ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    let customer = h.customer_repo.seed_deleted("deleted-user", "del@test.com");
    let (enc, nonce) = encrypt_secret(secret_key, &TEST_MASTER_KEY).unwrap();
    h.key_repo
        .create(PreparedStorageAccessKey {
            customer_id: customer.id,
            bucket_id: Uuid::new_v4(),
            access_key: access_key.to_string(),
            garage_access_key_id: format!("garage-{}", Uuid::new_v4()),
            secret_key_enc: enc,
            secret_key_nonce: nonce,
            label: "test".into(),
        })
        .await
        .unwrap();

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());

    let auth = SigningRequest {
        method: "GET",
        uri: "/",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let err = h
        .auth_service
        .authenticate("GET", "/", &all_headers)
        .await
        .unwrap_err();

    assert!(
        matches!(err, S3AuthError::InvalidAccessKeyId),
        "deleted customer should map to InvalidAccessKeyId (not AccountDisabled), got: {err:?}"
    );
}

#[tokio::test]
async fn uri_path_not_normalized() {
    let h = TestHarness::new();
    let access_key = "gridl_s3_urinormtest1234ab";
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01";
    h.insert_key(access_key, secret_key).await;

    let now = Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let uri = "/my-bucket//my-object/../photo.jpg";

    let auth = SigningRequest {
        method: "GET",
        uri,
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key,
        secret_key,
        timestamp: &now,
    }
    .sign();

    let mut all_headers: Vec<(&str, &str)> = headers;
    all_headers.push(("authorization", auth.as_str()));

    let ctx = h
        .auth_service
        .authenticate("GET", uri, &all_headers)
        .await
        .expect("URI should NOT be path-normalized for S3");

    assert_eq!(ctx.access_key, access_key);
}

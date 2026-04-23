//! S3 auth extractor tests.
//!
//! Validates `FromRequestParts<AppState>` for `S3AuthContext` including
//! extension short-circuit and SigV4 fallback authentication.

mod common;
mod storage_s3_auth_support;

use api::auth::S3AuthContext;
use api::models::storage::PreparedStorageAccessKey;
use api::repos::in_memory_storage_key_repo::InMemoryStorageKeyRepo;
use api::repos::storage_key_repo::StorageKeyRepo;
use api::services::storage::encryption::encrypt_secret;
use api::state::AppState;
use axum::extract::FromRequestParts;
use axum::http::Request;
use common::mocks::MockCustomerRepo;
use common::TestStateBuilder;
use std::sync::Arc;
use storage_s3_auth_support::{standard_headers, SigningRequest, EMPTY_SHA256};
use uuid::Uuid;

const TEST_MASTER_KEY: [u8; 32] = [0x42; 32];

async fn seeded_state() -> (AppState, Uuid, Uuid, String, String) {
    let key_repo = Arc::new(InMemoryStorageKeyRepo::new());
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed("extractor-test", "ext@test.com");
    let bucket_id = Uuid::new_v4();
    let access_key = "gridl_s3_extractorkey1234ab".to_string();
    let secret_key = "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY01".to_string();
    let (secret_key_enc, secret_key_nonce) =
        encrypt_secret(&secret_key, &TEST_MASTER_KEY).expect("test encryption should succeed");

    key_repo
        .create(PreparedStorageAccessKey {
            customer_id: customer.id,
            bucket_id,
            access_key: access_key.clone(),
            garage_access_key_id: format!("garage-{}", Uuid::new_v4()),
            secret_key_enc,
            secret_key_nonce,
            label: "test".to_string(),
        })
        .await
        .expect("seed key should succeed");

    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_storage_key_repo(key_repo)
        .with_storage_master_key(TEST_MASTER_KEY)
        .build();

    (state, customer.id, bucket_id, access_key, secret_key)
}

fn request_parts(headers: &[(&str, &str)], uri: &str) -> axum::http::request::Parts {
    let mut builder = Request::builder().method("GET").uri(uri);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    builder
        .body(axum::body::Body::empty())
        .expect("request should build")
        .into_parts()
        .0
}

#[tokio::test]
async fn valid_sigv4_extracts_context() {
    let (state, customer_id, bucket_id, access_key, secret_key) = seeded_state().await;
    let now = chrono::Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key: &access_key,
        secret_key: &secret_key,
        timestamp: &now,
    }
    .sign();
    let mut all_headers = headers;
    all_headers.push(("authorization", auth.as_str()));

    let mut parts = request_parts(&all_headers, "/bucket/key");
    let ctx = S3AuthContext::from_request_parts(&mut parts, &state)
        .await
        .expect("extractor should authenticate");

    assert_eq!(ctx.access_key, access_key);
    assert_eq!(ctx.customer_id, customer_id);
    assert_eq!(ctx.bucket_id, bucket_id);
}

#[tokio::test]
async fn invalid_signature_returns_signature_does_not_match_xml() {
    let (state, _customer_id, _bucket_id, access_key, _secret_key) = seeded_state().await;
    let now = chrono::Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key: &access_key,
        secret_key: "WRONG_SECRET_THAT_WONT_VALIDATE_1234",
        timestamp: &now,
    }
    .sign();
    let mut all_headers = headers;
    all_headers.push(("authorization", auth.as_str()));

    let mut parts = request_parts(&all_headers, "/bucket/key");
    let err = S3AuthContext::from_request_parts(&mut parts, &state)
        .await
        .unwrap_err();

    assert_eq!(err.status, 403);
    assert!(err.body.contains("<Code>SignatureDoesNotMatch</Code>"));
}

#[tokio::test]
async fn missing_authorization_returns_header_malformed_xml() {
    let (state, _, _, _, _) = seeded_state().await;
    let now = chrono::Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let mut parts = request_parts(&headers, "/bucket/key");

    let err = S3AuthContext::from_request_parts(&mut parts, &state)
        .await
        .unwrap_err();

    assert_eq!(err.status, 400);
    assert!(err
        .body
        .contains("<Code>AuthorizationHeaderMalformed</Code>"));
}

#[tokio::test]
async fn unknown_access_key_returns_invalid_access_key_id_xml() {
    let (state, _customer_id, _bucket_id, _access_key, _secret_key) = seeded_state().await;
    let now = chrono::Utc::now();
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let headers = standard_headers(amz_date.as_str());
    let auth = SigningRequest {
        method: "GET",
        uri: "/bucket/key",
        headers: &headers,
        payload_hash: EMPTY_SHA256,
        access_key: "gridl_s3_unknownkey1234ab",
        secret_key: "irrelevant_secret_material_for_signing_12",
        timestamp: &now,
    }
    .sign();
    let mut all_headers = headers;
    all_headers.push(("authorization", auth.as_str()));
    let mut parts = request_parts(&all_headers, "/bucket/key");

    let err = S3AuthContext::from_request_parts(&mut parts, &state)
        .await
        .unwrap_err();

    assert_eq!(err.status, 403);
    assert!(err.body.contains("<Code>InvalidAccessKeyId</Code>"));
}

#[tokio::test]
async fn extension_context_short_circuits_authentication() {
    let (state, customer_id, bucket_id, access_key, _secret_key) = seeded_state().await;
    let mut parts = request_parts(&[], "/bucket/key");
    parts.extensions.insert(S3AuthContext {
        access_key: access_key.clone(),
        customer_id,
        bucket_id,
    });

    let ctx = S3AuthContext::from_request_parts(&mut parts, &state)
        .await
        .expect("extractor should use extensions without headers");

    assert_eq!(ctx.access_key, access_key);
    assert_eq!(ctx.customer_id, customer_id);
    assert_eq!(ctx.bucket_id, bucket_id);
}

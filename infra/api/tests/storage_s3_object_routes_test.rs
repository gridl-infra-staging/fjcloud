//! S3 object route handler tests.
//!
//! Tests object CRUD operations with inline metering against the route handlers
//! using `tower::ServiceExt::oneshot`. S3AuthContext is injected via request
//! extensions (simulating the auth middleware path). Wiremock simulates Garage.

mod common;

use api::repos::storage_bucket_repo::StorageBucketRepo;
use axum::http::{Method, StatusCode};
use common::storage_metering_test_support::{wait_for_bucket_egress, wait_for_bucket_totals};
use common::storage_s3_object_route_support::{
    body_string, s3_request, s3_request_with_body, setup_object_router,
};
use tower::ServiceExt;
use uuid::Uuid;
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, ResponseTemplate};

// ---------------------------------------------------------------------------
// PutObject tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn put_object_forwards_to_garage_and_meters() {
    let (mock, bucket_repo, router, customer_id, bucket_id, bucket) = setup_object_router().await;
    let upload_body = b"hello-world-content".to_vec();

    Mock::given(method("PUT"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .and(header("content-type", "application/octet-stream"))
        .respond_with(ResponseTemplate::new(200).insert_header("etag", "\"abc123\""))
        .expect(1)
        .mount(&mock)
        .await;

    let mut req = s3_request_with_body(
        Method::PUT,
        "/my-bucket/my-key.txt",
        customer_id,
        bucket_id,
        upload_body.clone(),
    );
    req.headers_mut().insert(
        "content-type",
        "application/octet-stream".parse().expect("valid header"),
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_bucket_totals(bucket_repo.as_ref(), bucket.id, upload_body.len() as i64, 1).await;
    let updated = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, upload_body.len() as i64);
    assert_eq!(updated.object_count, 1);
}

#[tokio::test]
async fn put_object_nonexistent_bucket_returns_no_such_bucket() {
    let (_mock, _repo, router, customer_id, _bucket_id, _bucket) = setup_object_router().await;
    let wrong_bucket_id = Uuid::new_v4();

    let req = s3_request_with_body(
        Method::PUT,
        "/nonexistent/key.txt",
        customer_id,
        wrong_bucket_id,
        b"data".to_vec(),
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let body = body_string(resp.into_body()).await;
    assert!(body.contains("<Code>NoSuchBucket</Code>"));
}

#[tokio::test]
async fn put_object_overwrite_updates_metering_by_delta_only() {
    let (mock, bucket_repo, router, customer_id, bucket_id, bucket) = setup_object_router().await;
    let replacement_body = b"replacement-body".to_vec();

    bucket_repo.increment_size(bucket.id, 5, 1).await.unwrap();

    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(200).insert_header("content-length", "5"))
        .expect(1)
        .mount(&mock)
        .await;

    Mock::given(method("PUT"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock)
        .await;

    let req = s3_request_with_body(
        Method::PUT,
        "/my-bucket/my-key.txt",
        customer_id,
        bucket_id,
        replacement_body.clone(),
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_bucket_totals(
        bucket_repo.as_ref(),
        bucket.id,
        replacement_body.len() as i64,
        1,
    )
    .await;
    let updated = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, replacement_body.len() as i64);
    assert_eq!(updated.object_count, 1);
}

// ---------------------------------------------------------------------------
// GetObject tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_object_forwards_and_meters_egress() {
    let (mock, bucket_repo, router, customer_id, bucket_id, bucket) = setup_object_router().await;
    let object_body = b"object-data-from-garage";

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .and(header("range", "bytes=0-7"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(object_body.to_vec())
                .insert_header("content-type", "application/octet-stream")
                .insert_header("content-length", object_body.len().to_string()),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let mut req = s3_request(Method::GET, "/my-bucket/my-key.txt", customer_id, bucket_id);
    req.headers_mut()
        .insert("range", "bytes=0-7".parse().expect("valid header"));
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_string(resp.into_body()).await;
    assert_eq!(body.as_bytes(), object_body);

    wait_for_bucket_egress(bucket_repo.as_ref(), bucket.id, object_body.len() as i64).await;
    let updated = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.egress_bytes, object_body.len() as i64);
}

#[tokio::test]
async fn get_object_multi_segment_key() {
    let (mock, _repo, router, customer_id, bucket_id, _bucket) = setup_object_router().await;

    Mock::given(method("GET"))
        .and(path("/gridl-internal-123/folder/subfolder/file.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(b"nested".to_vec())
                .insert_header("content-length", "6"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let req = s3_request(
        Method::GET,
        "/my-bucket/folder/subfolder/file.txt",
        customer_id,
        bucket_id,
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

// ---------------------------------------------------------------------------
// DeleteObject tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_object_heads_then_deletes_and_meters() {
    let (mock, bucket_repo, router, customer_id, bucket_id, bucket) = setup_object_router().await;

    // First seed some size for metering to decrement
    bucket_repo
        .increment_size(bucket.id, 1024, 1)
        .await
        .unwrap();

    // HEAD to get object size
    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(200).insert_header("content-length", "1024"))
        .expect(1)
        .mount(&mock)
        .await;

    // DELETE
    Mock::given(method("DELETE"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&mock)
        .await;

    let req = s3_request(
        Method::DELETE,
        "/my-bucket/my-key.txt",
        customer_id,
        bucket_id,
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    wait_for_bucket_totals(bucket_repo.as_ref(), bucket.id, 0, 0).await;
    let updated = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, 0);
    assert_eq!(updated.object_count, 0);
}

#[tokio::test]
async fn delete_object_zero_byte_still_decrements_object_count() {
    let (mock, bucket_repo, router, customer_id, bucket_id, bucket) = setup_object_router().await;

    bucket_repo.increment_size(bucket.id, 0, 1).await.unwrap();

    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123/empty.txt"))
        .respond_with(ResponseTemplate::new(200).insert_header("content-length", "0"))
        .expect(1)
        .mount(&mock)
        .await;

    Mock::given(method("DELETE"))
        .and(path("/gridl-internal-123/empty.txt"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&mock)
        .await;

    let req = s3_request(
        Method::DELETE,
        "/my-bucket/empty.txt",
        customer_id,
        bucket_id,
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    wait_for_bucket_totals(bucket_repo.as_ref(), bucket.id, 0, 0).await;
    let updated = bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(updated.size_bytes, 0);
    assert_eq!(updated.object_count, 0);
}

// ---------------------------------------------------------------------------
// HeadObject tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn head_object_forwards_to_garage() {
    let (mock, _repo, router, customer_id, bucket_id, _bucket) = setup_object_router().await;

    Mock::given(method("HEAD"))
        .and(path("/gridl-internal-123/my-key.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-length", "512")
                .insert_header("content-type", "text/plain"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let req = s3_request(
        Method::HEAD,
        "/my-bucket/my-key.txt",
        customer_id,
        bucket_id,
    );
    let resp = router.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn head_object_wrong_bucket_returns_forbidden() {
    let (_mock, _repo, router, customer_id, _bucket_id, _bucket) = setup_object_router().await;
    let wrong_bucket_id = Uuid::new_v4();

    let req = s3_request(
        Method::HEAD,
        "/my-bucket/my-key.txt",
        customer_id,
        wrong_bucket_id,
    );
    let resp = router.oneshot(req).await.unwrap();
    // HEAD errors have no body, just status
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

//! S3 XML response builder tests.
//!
//! Validates that `s3_xml` builders produce well-formed XML matching the
//! S3 response contracts for `<Error>`, `<ListAllMyBucketsResult>`, and
//! `<ListBucketResult>` (ListObjectsV2).

mod common;

use api::services::storage::s3_xml;

// ---------------------------------------------------------------------------
// <Error> response
// ---------------------------------------------------------------------------

#[test]
fn error_response_produces_valid_xml() {
    let xml = s3_xml::error_response(
        "NoSuchKey",
        "The specified key does not exist.",
        "/my-bucket/missing",
        "req-abc-123",
    );

    assert!(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    assert!(xml.contains("<Error>"));
    assert!(xml.contains("<Code>NoSuchKey</Code>"));
    assert!(xml.contains("<Message>The specified key does not exist.</Message>"));
    assert!(xml.contains("<Resource>/my-bucket/missing</Resource>"));
    assert!(xml.contains("<RequestId>req-abc-123</RequestId>"));
    assert!(xml.contains("</Error>"));
}

#[test]
fn error_response_escapes_special_characters() {
    let xml = s3_xml::error_response(
        "InvalidBucketName",
        "Bucket name <\"foo&bar\"> is invalid",
        "/foo&bar",
        "req-1",
    );

    // XML special chars must be escaped
    assert!(xml.contains("&lt;"));
    assert!(xml.contains("&amp;"));
    assert!(!xml.contains("<\"foo"));
}

// ---------------------------------------------------------------------------
// ListAllMyBucketsResult (ListBuckets)
// ---------------------------------------------------------------------------

#[test]
fn list_buckets_empty_produces_valid_xml() {
    let xml = s3_xml::list_buckets_result("owner-123", "griddle-user", &[]);

    assert!(xml.contains("<ListAllMyBucketsResult"));
    assert!(xml.contains("<Owner>"));
    assert!(xml.contains("<ID>owner-123</ID>"));
    assert!(xml.contains("<DisplayName>griddle-user</DisplayName>"));
    assert!(xml.contains("<Buckets/>") || xml.contains("<Buckets></Buckets>"));
    assert!(xml.contains("</ListAllMyBucketsResult>"));
}

#[test]
fn list_buckets_with_entries() {
    let buckets = vec![
        s3_xml::BucketEntry {
            name: "my-first-bucket".to_string(),
            creation_date: "2026-01-15T10:30:00.000Z".to_string(),
        },
        s3_xml::BucketEntry {
            name: "my-second-bucket".to_string(),
            creation_date: "2026-03-01T08:00:00.000Z".to_string(),
        },
    ];

    let xml = s3_xml::list_buckets_result("owner-456", "griddle-user", &buckets);

    assert!(xml.contains("<Bucket>"));
    assert!(xml.contains("<Name>my-first-bucket</Name>"));
    assert!(xml.contains("<CreationDate>2026-01-15T10:30:00.000Z</CreationDate>"));
    assert!(xml.contains("<Name>my-second-bucket</Name>"));
    assert!(xml.contains("</Buckets>"));
}

// ---------------------------------------------------------------------------
// ListBucketResult (ListObjectsV2)
// ---------------------------------------------------------------------------

#[test]
fn list_objects_v2_empty_produces_valid_xml() {
    let params = s3_xml::ListObjectsV2Params {
        bucket: "my-bucket".to_string(),
        prefix: "".to_string(),
        max_keys: 1000,
        key_count: 0,
        is_truncated: false,
        continuation_token: None,
        next_continuation_token: None,
    };

    let xml = s3_xml::list_objects_v2_result(&params, &[]);

    assert!(xml.contains("<ListBucketResult"));
    assert!(xml.contains("<Name>my-bucket</Name>"));
    assert!(xml.contains("<MaxKeys>1000</MaxKeys>"));
    assert!(xml.contains("<KeyCount>0</KeyCount>"));
    assert!(xml.contains("<IsTruncated>false</IsTruncated>"));
    assert!(xml.contains("</ListBucketResult>"));
}

#[test]
fn list_objects_v2_with_objects() {
    let params = s3_xml::ListObjectsV2Params {
        bucket: "photo-bucket".to_string(),
        prefix: "photos/".to_string(),
        max_keys: 100,
        key_count: 2,
        is_truncated: false,
        continuation_token: None,
        next_continuation_token: None,
    };

    let objects = vec![
        s3_xml::ObjectEntry {
            key: "photos/cat.jpg".to_string(),
            last_modified: "2026-03-15T12:00:00.000Z".to_string(),
            etag: "\"abc123\"".to_string(),
            size: 1048576,
            storage_class: "STANDARD".to_string(),
        },
        s3_xml::ObjectEntry {
            key: "photos/dog.png".to_string(),
            last_modified: "2026-03-15T13:00:00.000Z".to_string(),
            etag: "\"def456\"".to_string(),
            size: 2097152,
            storage_class: "STANDARD".to_string(),
        },
    ];

    let xml = s3_xml::list_objects_v2_result(&params, &objects);

    assert!(xml.contains("<Prefix>photos/</Prefix>"));
    assert!(xml.contains("<Contents>"));
    assert!(xml.contains("<Key>photos/cat.jpg</Key>"));
    assert!(xml.contains("<Size>1048576</Size>"));
    assert!(xml.contains("<Key>photos/dog.png</Key>"));
    assert!(xml.contains("<ETag>&quot;def456&quot;</ETag>"));
}

#[test]
fn list_objects_v2_truncated_includes_continuation_token() {
    let params = s3_xml::ListObjectsV2Params {
        bucket: "big-bucket".to_string(),
        prefix: "".to_string(),
        max_keys: 10,
        key_count: 10,
        is_truncated: true,
        continuation_token: Some("token-page-1".to_string()),
        next_continuation_token: Some("token-page-2".to_string()),
    };

    let xml = s3_xml::list_objects_v2_result(&params, &[]);

    assert!(xml.contains("<IsTruncated>true</IsTruncated>"));
    assert!(xml.contains("<ContinuationToken>token-page-1</ContinuationToken>"));
    assert!(xml.contains("<NextContinuationToken>token-page-2</NextContinuationToken>"));
}

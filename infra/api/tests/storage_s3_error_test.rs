//! S3 error mapper tests.
//!
//! Validates that the shared error mapper produces correct S3 XML/status
//! pairs for proxy errors, auth errors, and known S3 error codes.

mod common;

use api::services::storage::s3_auth::S3AuthError;
use api::services::storage::s3_error::{
    from_auth_error, from_garage_error_xml, from_proxy_error, s3_error_response, status_for_s3_code,
};
use api::services::storage::s3_proxy::ProxyError;
use axum::response::IntoResponse;

// ---------------------------------------------------------------------------
// S3 error code → HTTP status mapping
// ---------------------------------------------------------------------------

#[test]
fn known_s3_codes_map_to_correct_status() {
    assert_eq!(status_for_s3_code("NoSuchKey"), 404);
    assert_eq!(status_for_s3_code("NoSuchBucket"), 404);
    assert_eq!(status_for_s3_code("NoSuchUpload"), 404);
    assert_eq!(status_for_s3_code("AccessDenied"), 403);
    assert_eq!(status_for_s3_code("BucketAlreadyExists"), 409);
    assert_eq!(status_for_s3_code("BucketNotEmpty"), 409);
    assert_eq!(status_for_s3_code("InvalidRange"), 416);
    assert_eq!(status_for_s3_code("EntityTooSmall"), 400);
    assert_eq!(status_for_s3_code("MalformedXML"), 400);
    assert_eq!(status_for_s3_code("InvalidBucketName"), 400);
    assert_eq!(status_for_s3_code("NotImplemented"), 501);
    assert_eq!(status_for_s3_code("InternalError"), 500);
}

#[test]
fn unknown_code_falls_back_to_internal_error() {
    assert_eq!(status_for_s3_code("GarageSpecificThing"), 500);
    assert_eq!(status_for_s3_code(""), 500);

    let resp = s3_error_response(
        "GarageSpecificThing",
        "opaque upstream detail",
        "/bucket",
        "req-0",
    );
    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(!resp.body.contains("GarageSpecificThing"));
}

#[test]
fn garage_error_xml_is_parsed_into_s3_response() {
    let garage_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><Resource>/bucket/missing</Resource><RequestId>garage-req-1</RequestId></Error>"#;

    let resp = from_garage_error_xml(garage_xml, "/fallback", "fallback-req");

    assert_eq!(resp.status, 404);
    assert!(resp.body.contains("<Code>NoSuchKey</Code>"));
    assert!(resp
        .body
        .contains("<Message>The specified key does not exist.</Message>"));
    assert!(resp.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(resp.body.contains("<RequestId>garage-req-1</RequestId>"));
}

#[test]
fn malformed_garage_error_xml_falls_back_to_internal_error() {
    let resp = from_garage_error_xml("<Error><Code>NoSuchKey", "/bucket/missing", "fallback-req");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(resp.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(resp.body.contains("<RequestId>fallback-req</RequestId>"));
}

#[test]
fn garage_error_xml_missing_message_falls_back_to_internal_error() {
    let garage_xml = "<Error><Code>NoSuchKey</Code></Error>";

    let resp = from_garage_error_xml(garage_xml, "/bucket/missing", "fallback-req");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(resp.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(resp.body.contains("<RequestId>fallback-req</RequestId>"));
}

#[test]
fn non_error_xml_falls_back_to_internal_error() {
    let garage_xml = r#"
<ListBucketsResult>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
</ListBucketsResult>"#;

    let resp = from_garage_error_xml(garage_xml, "/bucket/missing", "fallback-req");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(resp.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(resp.body.contains("<RequestId>fallback-req</RequestId>"));
}

#[test]
fn garage_error_xml_with_non_whitespace_outside_root_falls_back_to_internal_error() {
    let garage_xml = concat!(
        "garbage-prefix",
        "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>",
        "garbage-suffix"
    );

    let resp = from_garage_error_xml(garage_xml, "/bucket/missing", "fallback-req");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(resp.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(resp.body.contains("<RequestId>fallback-req</RequestId>"));
}

// ---------------------------------------------------------------------------
// Composite S3 error response (status + XML body)
// ---------------------------------------------------------------------------

#[test]
fn s3_error_response_produces_status_and_xml() {
    let resp = s3_error_response("NoSuchKey", "Key not found", "/bucket/key", "req-1");

    assert_eq!(resp.status, 404);
    assert!(resp.body.contains("<Code>NoSuchKey</Code>"));
    assert!(resp.body.contains("<Message>Key not found</Message>"));
    assert!(resp.body.contains("<Resource>/bucket/key</Resource>"));
    assert!(resp.body.contains("<RequestId>req-1</RequestId>"));
}

// ---------------------------------------------------------------------------
// ProxyError → S3 error response
// ---------------------------------------------------------------------------

#[test]
fn proxy_connect_error_maps_to_internal_error() {
    let err = ProxyError::UpstreamConnect("connection refused".into());
    let resp = from_proxy_error(&err, "/bucket", "req-2");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(!resp.body.contains("connection refused"));
}

#[test]
fn proxy_internal_error_maps_to_internal_error() {
    let err = ProxyError::Internal("bad method".into());
    let resp = from_proxy_error(&err, "/bucket", "req-3");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(!resp.body.contains("bad method"));
}

// ---------------------------------------------------------------------------
// S3AuthError → S3 error response
// ---------------------------------------------------------------------------

#[test]
fn auth_signature_mismatch_maps_to_signature_does_not_match() {
    let err = S3AuthError::SignatureDoesNotMatch;
    let resp = from_auth_error(&err, "/bucket/obj", "req-4");

    assert_eq!(resp.status, 403);
    assert!(resp.body.contains("<Code>SignatureDoesNotMatch</Code>"));
}

#[test]
fn auth_invalid_key_maps_to_invalid_access_key() {
    let err = S3AuthError::InvalidAccessKeyId;
    let resp = from_auth_error(&err, "/bucket/obj", "req-5");

    assert_eq!(resp.status, 403);
    assert!(resp.body.contains("<Code>InvalidAccessKeyId</Code>"));
}

#[test]
fn auth_time_skew_maps_to_request_time_too_skewed() {
    let err = S3AuthError::RequestTimeTooSkewed;
    let resp = from_auth_error(&err, "/bucket/obj", "req-6");

    assert_eq!(resp.status, 403);
    assert!(resp.body.contains("<Code>RequestTimeTooSkewed</Code>"));
}

#[test]
fn auth_malformed_maps_to_authorization_header_malformed() {
    let err = S3AuthError::MalformedAuth("bad header".into());
    let resp = from_auth_error(&err, "/bucket/obj", "req-7");

    assert_eq!(resp.status, 400);
    assert!(resp
        .body
        .contains("<Code>AuthorizationHeaderMalformed</Code>"));
}

#[test]
fn auth_internal_maps_to_internal_error() {
    let err = S3AuthError::Internal("db error".into());
    let resp = from_auth_error(&err, "/bucket/obj", "req-8");

    assert_eq!(resp.status, 500);
    assert!(resp.body.contains("<Code>InternalError</Code>"));
    assert!(!resp.body.contains("db error"));
}

#[tokio::test]
async fn s3_error_response_into_response_sets_xml_content_type() {
    let response =
        s3_error_response("NoSuchKey", "Key not found", "/bucket/key", "req-9").into_response();

    assert_eq!(response.status(), 404);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|value| value.to_str().ok()),
        Some("application/xml")
    );
}

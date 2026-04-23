//! Garage S3 proxy forwarding tests.
//!
//! Uses `wiremock` to simulate Garage's S3 endpoint and verify:
//! - Inbound requests are re-signed with internal Garage credentials
//! - Method, path, query, and body are forwarded intact
//! - Response status and filtered headers are returned correctly
//! - Upstream error responses are preserved

mod common;

use api::services::storage::s3_error;
use api::services::storage::s3_proxy::{GarageProxy, GarageProxyConfig, ProxyError, ProxyRequest};
use http_body_util::BodyExt;
use wiremock::matchers::{body_bytes, header_exists, header_regex, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const GARAGE_ACCESS_KEY: &str = "GK_INTERNAL_TEST_KEY";
const GARAGE_SECRET_KEY: &str = "InternalGarageSecretForTestingPurposes1";
const GARAGE_REGION: &str = "garage";

async fn setup_proxy() -> (MockServer, GarageProxy) {
    let mock = MockServer::start().await;
    let config = GarageProxyConfig {
        endpoint: mock.uri(),
        access_key: GARAGE_ACCESS_KEY.to_string(),
        secret_key: GARAGE_SECRET_KEY.to_string(),
        region: GARAGE_REGION.to_string(),
    };
    let proxy = GarageProxy::new(reqwest::Client::new(), config);
    (mock, proxy)
}

// ---------------------------------------------------------------------------
// Happy-path forwarding
// ---------------------------------------------------------------------------

#[tokio::test]
async fn forward_get_passes_through_response_body() {
    let (mock, proxy) = setup_proxy().await;

    Mock::given(method("GET"))
        .and(path("/my-bucket/my-object"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes(b"object-data-here".to_vec())
                .insert_header("content-type", "application/octet-stream")
                .insert_header("etag", "\"abc123\""),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/my-bucket/my-object",
            headers: &[],
            body: &[],
        })
        .await
        .expect("forward should succeed");

    assert_eq!(resp.status, 200);
    let body = resp
        .body
        .collect()
        .await
        .expect("streamed proxy body should collect")
        .to_bytes();
    assert_eq!(body.as_ref(), b"object-data-here");
}

#[tokio::test]
async fn forward_put_sends_body_to_garage() {
    let (mock, proxy) = setup_proxy().await;
    let upload_body = b"upload-payload-bytes";

    Mock::given(method("PUT"))
        .and(path("/my-bucket/uploaded-object"))
        .and(body_bytes(upload_body.as_slice()))
        .respond_with(ResponseTemplate::new(200).insert_header("etag", "\"def456\""))
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "PUT",
            uri: "/my-bucket/uploaded-object",
            headers: &[("content-type", "application/octet-stream")],
            body: upload_body,
        })
        .await
        .expect("PUT forward should succeed");

    assert_eq!(resp.status, 200);
}

#[tokio::test]
async fn forward_preserves_query_string() {
    let (mock, proxy) = setup_proxy().await;

    Mock::given(method("GET"))
        .and(path("/my-bucket"))
        .and(query_param("list-type", "2"))
        .and(query_param("prefix", "photos/"))
        .respond_with(ResponseTemplate::new(200).set_body_string("<ListBucketResult/>"))
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/my-bucket?list-type=2&prefix=photos/",
            headers: &[],
            body: &[],
        })
        .await
        .expect("query string should be forwarded");

    assert_eq!(resp.status, 200);
}

// ---------------------------------------------------------------------------
// Re-signing verification
// ---------------------------------------------------------------------------

#[tokio::test]
async fn forward_signs_with_garage_credentials() {
    let (mock, proxy) = setup_proxy().await;

    Mock::given(method("GET"))
        .and(path("/signed-test"))
        .and(header_exists("authorization"))
        .and(header_regex(
            "authorization",
            r"Credential=GK_INTERNAL_TEST_KEY/\d{8}/garage/s3/aws4_request",
        ))
        .and(header_exists("x-amz-date"))
        .and(header_exists("x-amz-content-sha256"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/signed-test",
            headers: &[(
                "authorization",
                "AWS4-HMAC-SHA256 Credential=CLIENT_KEY/20260315/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=clientsig",
            )],
            body: &[],
        })
        .await
        .expect("signed request should succeed");

    assert_eq!(resp.status, 200);
}

// ---------------------------------------------------------------------------
// Response header filtering
// ---------------------------------------------------------------------------

#[tokio::test]
async fn response_headers_are_filtered() {
    let (mock, proxy) = setup_proxy().await;

    Mock::given(method("GET"))
        .and(path("/hdr-test"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/plain")
                .insert_header("etag", "\"tag1\"")
                .insert_header("x-amz-request-id", "req-123")
                .insert_header("server", "Garage/1.0")
                .insert_header("connection", "keep-alive")
                .insert_header("transfer-encoding", "chunked")
                .insert_header("last-modified", "Sun, 15 Mar 2026 00:00:00 GMT"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/hdr-test",
            headers: &[],
            body: &[],
        })
        .await
        .expect("header filtering should not fail");

    let header_names: Vec<&str> = resp.headers.iter().map(|(k, _)| k.as_str()).collect();

    // Allowed headers pass through
    assert!(
        header_names.contains(&"content-type"),
        "content-type should pass through"
    );
    assert!(header_names.contains(&"etag"), "etag should pass through");
    assert!(
        header_names.contains(&"x-amz-request-id"),
        "x-amz-request-id should pass through"
    );
    assert!(
        header_names.contains(&"last-modified"),
        "last-modified should pass through"
    );

    // Denied headers are stripped
    assert!(
        !header_names.contains(&"server"),
        "server should be stripped"
    );
    assert!(
        !header_names.contains(&"connection"),
        "connection should be stripped"
    );
    assert!(
        !header_names.contains(&"transfer-encoding"),
        "transfer-encoding should be stripped"
    );
}

// ---------------------------------------------------------------------------
// Upstream error passthrough
// ---------------------------------------------------------------------------

#[tokio::test]
async fn upstream_404_is_preserved() {
    let (mock, proxy) = setup_proxy().await;

    let error_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>"#;

    Mock::given(method("GET"))
        .and(path("/my-bucket/missing-key"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_string(error_xml)
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/my-bucket/missing-key",
            headers: &[],
            body: &[],
        })
        .await
        .expect("error responses should still be returned, not converted to ProxyError");

    assert_eq!(resp.status, 404);
    let body = resp
        .body
        .collect()
        .await
        .expect("streamed error body should collect")
        .to_bytes();
    assert!(
        String::from_utf8_lossy(body.as_ref()).contains("NoSuchKey"),
        "error XML should be preserved"
    );
}

#[tokio::test]
async fn upstream_403_is_preserved() {
    let (mock, proxy) = setup_proxy().await;

    Mock::given(method("PUT"))
        .and(path("/forbidden-bucket/obj"))
        .respond_with(
            ResponseTemplate::new(403)
                .set_body_string("<Error><Code>AccessDenied</Code></Error>")
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "PUT",
            uri: "/forbidden-bucket/obj",
            headers: &[],
            body: &[],
        })
        .await
        .expect("403 should be forwarded not errored");

    assert_eq!(resp.status, 403);
}

#[tokio::test]
async fn upstream_409_is_preserved() {
    let (mock, proxy) = setup_proxy().await;

    let error_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>BucketAlreadyExists</Code><Message>The requested bucket name is not available.</Message></Error>"#;

    Mock::given(method("PUT"))
        .and(path("/conflict-bucket"))
        .respond_with(
            ResponseTemplate::new(409)
                .set_body_string(error_xml)
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "PUT",
            uri: "/conflict-bucket",
            headers: &[],
            body: &[],
        })
        .await
        .expect("409 should be forwarded not errored");

    assert_eq!(resp.status, 409);
    let body = resp
        .body
        .collect()
        .await
        .expect("streamed error body should collect")
        .to_bytes();
    assert!(
        String::from_utf8_lossy(body.as_ref()).contains("BucketAlreadyExists"),
        "409 error XML should be preserved"
    );
}

#[tokio::test]
async fn upstream_connection_failure_returns_error() {
    // Connect to a port that nothing is listening on
    let config = GarageProxyConfig {
        endpoint: "http://127.0.0.1:1".to_string(),
        access_key: GARAGE_ACCESS_KEY.to_string(),
        secret_key: GARAGE_SECRET_KEY.to_string(),
        region: GARAGE_REGION.to_string(),
    };
    let proxy = GarageProxy::new(reqwest::Client::new(), config);

    let result = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/unreachable",
            headers: &[],
            body: &[],
        })
        .await;

    match result {
        Err(ProxyError::UpstreamConnect(_)) => {}
        Err(err) => panic!("connection failure should return UpstreamConnect, got: {err:?}"),
        Ok(_) => panic!("connection failure should return UpstreamConnect"),
    }
}

// ---------------------------------------------------------------------------
// Integration: proxy error status → s3_error mapper → correct XML/status
// ---------------------------------------------------------------------------

#[tokio::test]
async fn garage_404_translates_to_s3_nosuchkey_via_error_mapper() {
    let (mock, proxy) = setup_proxy().await;

    let garage_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><Resource>/bucket/missing</Resource><RequestId>garage-req-1</RequestId></Error>"#;

    Mock::given(method("GET"))
        .and(path("/bucket/missing"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_string(garage_xml)
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/bucket/missing",
            headers: &[],
            body: &[],
        })
        .await
        .expect("should forward Garage 404");

    assert_eq!(resp.status, 404);

    let body = resp
        .body
        .collect()
        .await
        .expect("proxy error body should collect")
        .to_bytes();
    let body_str = String::from_utf8_lossy(body.as_ref());
    let mapped = s3_error::from_garage_error_xml(&body_str, "/fallback", "fallback-req");

    assert_eq!(mapped.status, 404);
    assert!(mapped.body.contains("<Code>NoSuchKey</Code>"));
    assert!(mapped
        .body
        .contains("<Message>The specified key does not exist.</Message>"));
    assert!(mapped.body.contains("<Resource>/bucket/missing</Resource>"));
    assert!(mapped.body.contains("<RequestId>garage-req-1</RequestId>"));
}

#[tokio::test]
async fn garage_409_translates_to_s3_bucket_conflict_via_error_mapper() {
    let (mock, proxy) = setup_proxy().await;

    let garage_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>BucketNotEmpty</Code><Message>The bucket you tried to delete is not empty.</Message></Error>"#;

    Mock::given(method("DELETE"))
        .and(path("/non-empty-bucket"))
        .respond_with(
            ResponseTemplate::new(409)
                .set_body_string(garage_xml)
                .insert_header("content-type", "application/xml"),
        )
        .expect(1)
        .mount(&mock)
        .await;

    let resp = proxy
        .forward(&ProxyRequest {
            method: "DELETE",
            uri: "/non-empty-bucket",
            headers: &[],
            body: &[],
        })
        .await
        .expect("should forward Garage 409");

    assert_eq!(resp.status, 409);

    let body = resp
        .body
        .collect()
        .await
        .expect("proxy error body should collect")
        .to_bytes();
    let body_str = String::from_utf8_lossy(body.as_ref());
    let mapped = s3_error::from_garage_error_xml(&body_str, "/non-empty-bucket", "fallback-req");

    assert_eq!(mapped.status, 409);
    assert!(mapped.body.contains("<Code>BucketNotEmpty</Code>"));
    assert!(mapped
        .body
        .contains("<Message>The bucket you tried to delete is not empty.</Message>"));
    assert!(mapped
        .body
        .contains("<Resource>/non-empty-bucket</Resource>"));
    assert!(mapped.body.contains("<RequestId>fallback-req</RequestId>"));
}

#[tokio::test]
async fn proxy_connection_failure_maps_to_s3_internal_error_xml() {
    let config = GarageProxyConfig {
        endpoint: "http://127.0.0.1:1".to_string(),
        access_key: GARAGE_ACCESS_KEY.to_string(),
        secret_key: GARAGE_SECRET_KEY.to_string(),
        region: GARAGE_REGION.to_string(),
    };
    let proxy = GarageProxy::new(reqwest::Client::new(), config);

    let result = proxy
        .forward(&ProxyRequest {
            method: "GET",
            uri: "/bucket/obj",
            headers: &[],
            body: &[],
        })
        .await;

    let err = match result {
        Err(e) => e,
        Ok(_) => panic!("expected proxy error for unreachable endpoint"),
    };
    let s3_resp = s3_error::from_proxy_error(&err, "/bucket/obj", "test-req-id");

    assert_eq!(s3_resp.status, 500);
    assert!(s3_resp.body.contains("<Code>InternalError</Code>"));
    assert!(s3_resp.body.contains("<Resource>/bucket/obj</Resource>"));
    assert!(!s3_resp.body.contains("127.0.0.1:1"));
}

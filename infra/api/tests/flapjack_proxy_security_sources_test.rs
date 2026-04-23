#[path = "common/mod.rs"]
mod common;

use common::flapjack_proxy_test_support::setup;
use serde_json::json;

// ---------------------------------------------------------------------------
// get_security_sources
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_security_sources_returns_upstream_response() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream = json!({
        "sources": [
            {"source": "192.168.1.0/24", "description": "Office network"},
            {"source": "10.0.0.1", "description": "VPN gateway"}
        ]
    });
    http.push_json_response(200, upstream.clone());

    let result = proxy
        .get_security_sources("https://vm-a1.flapjack.foo", "node-1", "us-east-1")
        .await
        .expect("get_security_sources should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/security/sources"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// append_security_source
// ---------------------------------------------------------------------------

#[tokio::test]
async fn append_security_source_sends_post_with_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream = json!({"createdAt": "2026-03-19T00:00:00Z"});
    http.push_json_response(200, upstream.clone());

    let source_body = json!({
        "source": "10.0.0.0/8",
        "description": "Internal network"
    });

    let result = proxy
        .append_security_source(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            source_body.clone(),
        )
        .await
        .expect("append_security_source should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/security/sources/append"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(source_body));
}

// ---------------------------------------------------------------------------
// delete_security_source
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_security_source_sends_delete_to_encoded_path() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream = json!({"deletedAt": "2026-03-19T00:00:00Z"});
    http.push_json_response(200, upstream.clone());

    let result = proxy
        .delete_security_source(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "10.0.0.1",
        )
        .await
        .expect("delete_security_source should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/security/sources/10.0.0.1"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn delete_security_source_percent_encodes_cidr_slash() {
    let (http, _ssm, proxy) = setup().await;

    let upstream = json!({"deletedAt": "2026-03-19T00:00:00Z"});
    http.push_json_response(200, upstream.clone());

    let result = proxy
        .delete_security_source(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "192.168.1.0/24",
        )
        .await
        .expect("delete with CIDR should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    // The slash in 192.168.1.0/24 must be percent-encoded as %2F
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/security/sources/192.168.1.0%2F24"
    );
}

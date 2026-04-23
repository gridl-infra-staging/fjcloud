#[path = "common/mod.rs"]
mod common;

use common::flapjack_proxy_test_support::setup;
use serde_json::json;

// ---------------------------------------------------------------------------
// algolia_list_indexes
// ---------------------------------------------------------------------------

#[tokio::test]
async fn algolia_list_indexes_posts_body_and_returns_upstream_response() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream = json!({
        "items": [
            {"name": "products", "entries": 1234},
            {"name": "users", "entries": 56}
        ]
    });
    http.push_json_response(200, upstream.clone());

    let body = json!({
        "appId": "ALGOLIA_APP_ID",
        "apiKey": "algolia-admin-key"
    });

    let result = proxy
        .algolia_list_indexes(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            body.clone(),
        )
        .await
        .expect("algolia_list_indexes should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/algolia-list-indexes"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(body));
}

// ---------------------------------------------------------------------------
// migrate_from_algolia
// ---------------------------------------------------------------------------

#[tokio::test]
async fn migrate_from_algolia_posts_body_and_returns_upstream_response() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream = json!({
        "taskID": 42,
        "status": "started"
    });
    http.push_json_response(200, upstream.clone());

    let body = json!({
        "appId": "ALGOLIA_APP_ID",
        "apiKey": "algolia-admin-key",
        "sourceIndex": "products"
    });

    let result = proxy
        .migrate_from_algolia(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            body.clone(),
        )
        .await
        .expect("migrate_from_algolia should succeed");

    assert_eq!(result, upstream);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/migrate-from-algolia"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(body));
}

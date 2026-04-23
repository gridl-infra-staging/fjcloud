#[path = "common/mod.rs"]
mod common;

use api::services::flapjack_proxy::ProxyError;
use common::flapjack_proxy_test_support::setup;
use serde_json::json;

#[tokio::test]
async fn analytics_trims_mixed_leading_query_delimiters() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"searches": []}));

    proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches",
            "products",
            "&?limit=5",
        )
        .await
        .expect("get_analytics should trim mixed leading query delimiters");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches?index=products&limit=5"
    );
}

#[tokio::test]
async fn experiment_query_params_trim_mixed_leading_delimiters() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"abtests": []}));

    proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "GET",
            "",
            None,
            "&?indexPrefix=products",
        )
        .await
        .expect("proxy_experiment should trim mixed leading query delimiters");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests?indexPrefix=products"
    );
}

#[tokio::test]
async fn experiment_unsupported_method_returns_400_with_uppercased_method() {
    let (_http, _ssm, proxy) = setup().await;

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "patch",
            "",
            None,
            "",
        )
        .await;

    match result {
        Err(ProxyError::FlapjackError { status, message }) => {
            assert_eq!(status, 400);
            assert_eq!(message, "unsupported experiments method: PATCH");
        }
        other => panic!("expected FlapjackError 400, got: {other:?}"),
    }
}

#[tokio::test]
async fn event_debug_trims_mixed_leading_query_delimiters() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"events": [], "count": 0}));

    proxy
        .get_debug_events(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "&?limit=25",
        )
        .await
        .expect("get_debug_events should trim mixed leading query delimiters");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/events/debug?index=products&limit=25"
    );
}

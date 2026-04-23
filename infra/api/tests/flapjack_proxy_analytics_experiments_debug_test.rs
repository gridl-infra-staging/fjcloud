#[path = "common/mod.rs"]
mod common;

use common::flapjack_proxy_test_support::setup;
use serde_json::json;

#[tokio::test]
async fn analytics_top_searches_proxies_get_to_flapjack() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "searches": [
            {"search": "laptop", "count": 42, "nbHits": 15}
        ]
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches",
            "products",
            "startDate=2026-02-18&endDate=2026-02-25&limit=10",
        )
        .await
        .expect("get_analytics searches should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches?index=products&startDate=2026-02-18&endDate=2026-02-25&limit=10"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn analytics_search_count_proxies_get_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "count": 1234,
        "dates": [
            {"date": "2026-02-24", "count": 180}
        ]
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches/count",
            "products",
            "startDate=2026-02-18&endDate=2026-02-25",
        )
        .await
        .expect("get_analytics searches/count should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches/count?index=products&startDate=2026-02-18&endDate=2026-02-25"
    );
}

#[tokio::test]
async fn analytics_no_results_proxies_get_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "searches": [
            {"search": "lapptop", "count": 8, "nbHits": 0}
        ]
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches/noResults",
            "products",
            "startDate=2026-02-18&endDate=2026-02-25&limit=10",
        )
        .await
        .expect("get_analytics noResults should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches/noResults?index=products&startDate=2026-02-18&endDate=2026-02-25&limit=10"
    );
}

#[tokio::test]
async fn analytics_no_result_rate_proxies_get_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "rate": 0.12,
        "count": 1234,
        "noResults": 148,
        "dates": [
            {"date": "2026-02-24", "rate": 0.1, "count": 180, "noResults": 18}
        ]
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches/noResultRate",
            "products",
            "startDate=2026-02-18&endDate=2026-02-25",
        )
        .await
        .expect("get_analytics noResultRate should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches/noResultRate?index=products&startDate=2026-02-18&endDate=2026-02-25"
    );
}

#[tokio::test]
async fn analytics_status_proxies_get_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "indexName": "products",
        "enabled": true
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "status",
            "products",
            "",
        )
        .await
        .expect("get_analytics status should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/status?index=products"
    );
}

#[tokio::test]
async fn analytics_forwards_optional_query_params() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"searches": []}));

    proxy
        .get_analytics(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "searches",
            "products",
            "startDate=2026-02-18&endDate=2026-02-25&limit=100&tags=beta&country=US",
        )
        .await
        .expect("get_analytics should forward optional params");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/searches?index=products&startDate=2026-02-18&endDate=2026-02-25&limit=100&tags=beta&country=US"
    );
}

// ---------------------------------------------------------------------------
// Stage 7: experiments
// ---------------------------------------------------------------------------

#[tokio::test]
async fn experiment_list_proxies_get_to_flapjack() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "abtests": [
            {"abTestID": 1, "name": "Ranking test", "status": "created"}
        ],
        "count": 1,
        "total": 1
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "GET",
            "",
            None,
            "indexPrefix=products",
        )
        .await
        .expect("proxy_experiment list should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests?indexPrefix=products"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn experiment_create_proxies_post_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let body = json!({
        "name": "Ranking test",
        "variants": [
            {"index": "products", "trafficPercentage": 50},
            {"index": "products", "trafficPercentage": 50, "customSearchParameters": {"enableRules": false}}
        ]
    });
    let upstream_response = json!({"abTestID": 7, "index": "products", "taskID": 99});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "POST",
            "",
            Some(body.clone()),
            "",
        )
        .await
        .expect("proxy_experiment create should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, "https://vm-a1.flapjack.foo/2/abtests");
    assert_eq!(requests[0].json_body, Some(body));
}

#[tokio::test]
async fn experiment_get_proxies_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "abTestID": 7,
        "name": "Ranking test",
        "status": "running",
        "variants": [{"index": "products", "trafficPercentage": 50}]
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "GET",
            "7",
            None,
            "",
        )
        .await
        .expect("proxy_experiment get should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-a1.flapjack.foo/2/abtests/7");
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn experiment_delete_proxies_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({"abTestID": 7, "index": "products", "taskID": 101});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "DELETE",
            "7",
            None,
            "",
        )
        .await
        .expect("proxy_experiment delete should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(requests[0].url, "https://vm-a1.flapjack.foo/2/abtests/7");
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn experiment_start_proxies_post_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({"abTestID": 7, "index": "products", "taskID": 102});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "POST",
            "7/start",
            None,
            "",
        )
        .await
        .expect("proxy_experiment start should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests/7/start"
    );
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn experiment_stop_proxies_post_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({"abTestID": 7, "index": "products", "taskID": 103});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "POST",
            "7/stop",
            None,
            "",
        )
        .await
        .expect("proxy_experiment stop should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests/7/stop"
    );
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn experiment_conclude_proxies_post_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let body = json!({
        "winner": "variant",
        "reason": "variant has better ctr",
        "controlMetric": 0.05,
        "variantMetric": 0.08,
        "confidence": 0.97,
        "significant": true,
        "promoted": false
    });
    let upstream_response = json!({"abTestID": 7, "index": "products", "taskID": 104});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "POST",
            "7/conclude",
            Some(body.clone()),
            "",
        )
        .await
        .expect("proxy_experiment conclude should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests/7/conclude"
    );
    assert_eq!(requests[0].json_body, Some(body));
}

#[tokio::test]
async fn experiment_results_proxies_get_to_flapjack() {
    let (http, _ssm, proxy) = setup().await;

    let upstream_response = json!({
        "experimentID": "7",
        "name": "Ranking test",
        "status": "running",
        "indexName": "products",
        "primaryMetric": "ctr"
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .proxy_experiment(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "GET",
            "7/results",
            None,
            "",
        )
        .await
        .expect("proxy_experiment results should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/2/abtests/7/results"
    );
    assert_eq!(requests[0].json_body, None);
}

// ---------------------------------------------------------------------------
// Stage 8: event debugger
// ---------------------------------------------------------------------------

#[tokio::test]
async fn event_debug_proxies_get_to_flapjack() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "events": [
            {
                "timestampMs": 1709251200000_i64,
                "index": "products",
                "eventType": "view",
                "eventSubtype": null,
                "eventName": "Viewed Product",
                "userToken": "user_abc",
                "objectIds": ["obj1", "obj2"],
                "httpCode": 200,
                "validationErrors": []
            }
        ],
        "count": 1
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_debug_events(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "",
        )
        .await
        .expect("get_debug_events should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/events/debug?index=products"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn event_debug_forwards_optional_query_params() {
    let (http, _ssm, proxy) = setup().await;

    http.push_json_response(200, json!({"events": [], "count": 0}));

    proxy
        .get_debug_events(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            "eventType=click&status=error&limit=50&from=1709251200000&until=1709337600000",
        )
        .await
        .expect("get_debug_events should forward optional params");

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/events/debug?index=products&eventType=click&status=error&limit=50&from=1709251200000&until=1709337600000"
    );
}

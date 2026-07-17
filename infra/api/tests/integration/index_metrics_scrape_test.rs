use crate::common::flapjack_proxy_test_support::setup;

#[tokio::test]
async fn fetch_metrics_text_sends_get_with_admin_key_and_returns_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let prom_body = "# HELP flapjack_documents_count\nflapjack_documents_count{index=\"x\"} 42\n";
    http.push_text_response(200, prom_body);

    let result = proxy
        .fetch_metrics_text("https://vm-test.flapjack.foo", "node-1", "us-east-1")
        .await
        .unwrap();

    assert_eq!(result, prom_body);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(requests[0].url, "https://vm-test.flapjack.foo/metrics");
    assert!(requests[0].json_body.is_none());
    assert_eq!(requests[0].api_key, api_key);
}

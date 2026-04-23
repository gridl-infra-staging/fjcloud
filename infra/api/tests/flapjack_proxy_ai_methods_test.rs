#[path = "common/mod.rs"]
mod common;

use common::flapjack_proxy_test_support::setup;
use serde_json::json;

#[tokio::test]
async fn get_personalization_strategy_sends_get_to_strategies_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({
        "eventsScoring": [
            {"eventName": "Product viewed", "eventType": "view", "score": 10}
        ],
        "facetsScoring": [
            {"facetName": "brand", "score": 70}
        ],
        "personalizationImpact": 75
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_personalization_strategy("https://vm-a1.flapjack.foo", "node-1", "us-east-1")
        .await
        .expect("get_personalization_strategy should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/strategies/personalization"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn save_personalization_strategy_sends_post_with_body() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let strategy = json!({
        "eventsScoring": [
            {"eventName": "Product viewed", "eventType": "view", "score": 10},
            {"eventName": "Product purchased", "eventType": "conversion", "score": 50}
        ],
        "facetsScoring": [
            {"facetName": "brand", "score": 70},
            {"facetName": "category", "score": 30}
        ],
        "personalizationImpact": 75
    });
    let upstream_response = json!({"updatedAt": "2026-03-17T00:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .save_personalization_strategy(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            strategy.clone(),
        )
        .await
        .expect("save_personalization_strategy should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/strategies/personalization"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(strategy));
}

#[tokio::test]
async fn delete_personalization_strategy_sends_delete_to_strategies_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let upstream_response = json!({"deletedAt": "2026-03-17T00:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_personalization_strategy("https://vm-a1.flapjack.foo", "node-1", "us-east-1")
        .await
        .expect("delete_personalization_strategy should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/strategies/personalization"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn get_personalization_profile_percent_encodes_user_token_path_segment() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    let user_token = "user token/1";

    let upstream_response = json!({
        "userToken": "user-123",
        "lastEventAt": "2026-02-25T00:00:00Z",
        "scores": {"brand": {"acme": 20}, "category": {"shoes": 12}}
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .get_personalization_profile(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            user_token,
        )
        .await
        .expect("get_personalization_profile should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/profiles/personalization/user%20token%2F1"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn delete_personalization_profile_percent_encodes_user_token_path_segment() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();
    let user_token = "user token/1";

    let upstream_response =
        json!({"userToken": "user-123", "deletedUntil": "2026-03-17T00:00:00Z"});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .delete_personalization_profile(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            user_token,
        )
        .await
        .expect("delete_personalization_profile should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/profiles/user%20token%2F1"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, None);
}

#[tokio::test]
async fn recommend_sends_post_to_literal_indexes_star_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let request_body = json!({
        "requests": [
            {
                "indexName": "products",
                "model": "trending-items",
                "threshold": 0
            }
        ]
    });
    let upstream_response = json!({"results": [{"hits": [], "processingTimeMS": 1}]});
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .recommend(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            request_body.clone(),
        )
        .await
        .expect("recommend should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/*/recommendations"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(request_body));
}

#[tokio::test]
async fn chat_sends_post_to_index_chat_endpoint() {
    let (http, ssm, proxy) = setup().await;
    let api_key = ssm.get_secret("node-1").unwrap();

    let request_body = json!({
        "query": "What are the most popular products?",
        "conversationHistory": [],
        "stream": false
    });
    let upstream_response = json!({
        "answer": "Top products are A and B.",
        "sources": [],
        "conversationId": "conv-123",
        "queryID": "qid-123"
    });
    http.push_json_response(200, upstream_response.clone());

    let result = proxy
        .chat(
            "https://vm-a1.flapjack.foo",
            "node-1",
            "us-east-1",
            "products",
            request_body.clone(),
        )
        .await
        .expect("chat should succeed");

    assert_eq!(result, upstream_response);

    let requests = http.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-a1.flapjack.foo/1/indexes/products/chat"
    );
    assert_eq!(requests[0].api_key, api_key);
    assert_eq!(requests[0].json_body, Some(request_body));
}

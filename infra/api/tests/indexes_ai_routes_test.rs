mod common;

use api::services::flapjack_proxy::ProxyError;
use axum::body::Body;
use axum::http::{self, Request, StatusCode};
use common::flapjack_proxy_test_support::{setup_ready_index, test_flapjack_uid};
use common::indexes_route_test_support::response_json;
use serde_json::json;
use tower::ServiceExt;

async fn assert_chat_proxy_error(
    proxy_error: ProxyError,
    expected_status: StatusCode,
    expected_error: &str,
    forbidden_error_fragment: Option<&str>,
) {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;
    let request_body = json!({"query": "hello", "stream": false});
    http_client.push_error(proxy_error);

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/chat")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(request_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, expected_status);
    assert_eq!(body["error"], expected_error);
    if let Some(forbidden) = forbidden_error_fragment {
        assert!(
            !body["error"]
                .as_str()
                .unwrap_or_default()
                .contains(forbidden),
            "chat error leaked upstream message: {}",
            body["error"]
        );
    }

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/chat",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(request_body));
}

#[tokio::test]
async fn get_personalization_strategy_proxies_to_flapjack() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    http_client.push_json_response(
        200,
        json!({
            "eventsScoring": [
                {"eventName": "Product viewed", "eventType": "view", "score": 10}
            ],
            "facetsScoring": [
                {"facetName": "brand", "score": 70}
            ],
            "personalizationImpact": 75
        }),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/personalization/strategy")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["personalizationImpact"], 75);
    assert_eq!(body["eventsScoring"][0]["eventName"], "Product viewed");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/strategies/personalization"
    );
}

#[tokio::test]
async fn save_personalization_strategy_rejects_non_object_body() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/personalization/strategy")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!(["invalid"]).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("personalization strategy must be a JSON object"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn save_personalization_strategy_proxies_object_body() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
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
    http_client.push_json_response(200, json!({"updatedAt": "2026-03-17T00:00:00Z"}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::PUT)
                .uri("/indexes/products/personalization/strategy")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(strategy.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["updatedAt"].is_string());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/strategies/personalization"
    );
    assert_eq!(requests[0].json_body, Some(strategy));
}

#[tokio::test]
async fn delete_personalization_strategy_proxies_delete() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    http_client.push_json_response(200, json!({"deletedAt": "2026-03-17T00:00:00Z"}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/personalization/strategy")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["deletedAt"].is_string());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/strategies/personalization"
    );
}

#[tokio::test]
async fn personalization_profile_routes_use_expected_flapjack_paths() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    http_client.push_json_response(200, json!({"userToken": "user token/1"}));
    http_client.push_json_response(200, json!({"deletedAt": "2026-03-17T00:00:00Z"}));

    let get_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/products/personalization/profiles/user%20token%2F1")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (get_status, get_body) = response_json(get_resp).await;
    assert_eq!(get_status, StatusCode::OK);
    assert_eq!(get_body["userToken"], "user token/1");

    let delete_resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::DELETE)
                .uri("/indexes/products/personalization/profiles/user%20token%2F1")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (delete_status, delete_body) = response_json(delete_resp).await;
    assert_eq!(delete_status, StatusCode::OK);
    assert!(delete_body["deletedAt"].is_string());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/profiles/personalization/user%20token%2F1"
    );
    assert_eq!(requests[1].method, reqwest::Method::DELETE);
    assert_eq!(
        requests[1].url,
        "https://vm-test.flapjack.foo/1/profiles/user%20token%2F1"
    );
}

#[tokio::test]
async fn recommend_rejects_non_object_body() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/recommendations")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!(["invalid"]).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("recommendations request must be a JSON object"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn recommend_proxies_to_wildcard_recommendations_endpoint() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;
    let request_body = json!({
        "requests": [{"indexName": "products", "objectID": "sku-1", "maxRecommendations": 3}]
    });
    http_client.push_json_response(200, json!({"results": [{"hits": []}]}));

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/recommendations")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(request_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["results"].is_array());

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        "https://vm-test.flapjack.foo/1/indexes/*/recommendations"
    );
    assert_eq!(requests[0].json_body, Some(request_body));
}

#[tokio::test]
async fn chat_rejects_stream_true_without_proxying() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/chat")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(
                    json!({"query": "hello", "stream": true}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("streaming chat is not supported in fjcloud"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn chat_rejects_non_object_body_without_proxying() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/chat")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!(["invalid"]).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("chat request must be a JSON object"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn chat_rejects_event_stream_accept_header_without_proxying() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/chat")
                .header("content-type", "application/json")
                .header("accept", "application/json, text/event-stream")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("streaming chat is not supported in fjcloud"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn chat_proxies_json_request_to_chat_endpoint() {
    let (app, jwt, http_client, customer_id) = setup_ready_index("products").await;
    let request_body = json!({
        "query": "suggest alternatives",
        "stream": false,
        "conversationHistory": [{"role": "user", "content": "hello"}]
    });
    http_client.push_json_response(
        200,
        json!({
            "answer": "Try related products",
            "sources": [{"objectID": "shoe-2"}],
            "conversationId": "conv-1",
            "queryID": "q-1"
        }),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/products/chat")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(request_body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["answer"], "Try related products");
    assert_eq!(body["conversationId"], "conv-1");
    assert_eq!(body["queryID"], "q-1");
    assert_eq!(body["sources"][0]["objectID"], "shoe-2");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(
        requests[0].url,
        format!(
            "https://vm-test.flapjack.foo/1/indexes/{}/chat",
            test_flapjack_uid(customer_id, "products")
        )
    );
    assert_eq!(requests[0].json_body, Some(request_body));
}

#[tokio::test]
async fn chat_returns_503_when_flapjack_unreachable() {
    assert_chat_proxy_error(
        ProxyError::Unreachable("connection refused".into()),
        StatusCode::SERVICE_UNAVAILABLE,
        "backend temporarily unavailable",
        None,
    )
    .await;
}

#[tokio::test]
async fn chat_returns_503_when_flapjack_times_out() {
    assert_chat_proxy_error(
        ProxyError::Timeout,
        StatusCode::SERVICE_UNAVAILABLE,
        "request timed out",
        None,
    )
    .await;
}

#[tokio::test]
async fn chat_returns_500_when_flapjack_returns_502() {
    assert_chat_proxy_error(
        ProxyError::FlapjackError {
            status: 502,
            message: "chat bad gateway from upstream engine".into(),
        },
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal server error",
        Some("chat bad gateway from upstream engine"),
    )
    .await;
}

#[tokio::test]
async fn chat_returns_not_found_for_missing_index_without_proxying() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/no-such-index/chat")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"query": "hello"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("not found"));
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn personalization_strategy_returns_not_found_for_missing_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::GET)
                .uri("/indexes/no-such-index/personalization/strategy")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(http_client.take_requests().len(), 0);
}

#[tokio::test]
async fn recommend_returns_not_found_for_missing_index() {
    let (app, jwt, http_client, _customer_id) = setup_ready_index("products").await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(http::Method::POST)
                .uri("/indexes/no-such-index/recommendations")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::from(json!({"requests": []}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(http_client.take_requests().len(), 0);
}

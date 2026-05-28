use std::sync::Arc;
use std::time::Duration;

use api::repos::webhook_event_repo::WebhookEventRow;
use api::repos::WebhookEventRepo;
use api::services::webhook_lag::WebhookLagPublisher;
use chrono::{Duration as ChronoDuration, Utc};
use serde_cbor::Value as CborValue;
use tokio::sync::watch;
use wiremock::MockServer;

async fn cloudwatch_client_for_mock_server(server: &MockServer) -> aws_sdk_cloudwatch::Client {
    let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_sdk_cloudwatch::config::Region::new("us-east-1"))
        .load()
        .await;
    let credentials = aws_sdk_cloudwatch::config::Credentials::new(
        "test-access-key",
        "test-secret-key",
        None,
        None,
        "webhook-lag-test",
    );
    let cloudwatch_config = aws_sdk_cloudwatch::config::Builder::from(&aws_config)
        .endpoint_url(server.uri())
        .credentials_provider(credentials)
        .build();
    aws_sdk_cloudwatch::Client::from_conf(cloudwatch_config)
}

fn assert_json_metric_payload(body: &serde_json::Value, expected_env: &str, expected_value: f64) {
    assert_eq!(body["Namespace"].as_str(), Some("fjcloud/api"));
    let metric_datum = body["MetricData"]
        .as_array()
        .and_then(|metric_data| metric_data.first())
        .expect("MetricData must include one datum");
    assert_eq!(metric_datum["MetricName"].as_str(), Some("WebhookBacklog"));
    assert_eq!(metric_datum["Unit"].as_str(), Some("Count"));
    assert_eq!(metric_datum["Value"].as_f64(), Some(expected_value));

    let env_dimension_value = metric_datum["Dimensions"]
        .as_array()
        .expect("dimensions must be an array")
        .iter()
        .find_map(|dimension| {
            (dimension["Name"].as_str() == Some("Env"))
                .then(|| dimension["Value"].as_str())
                .flatten()
        });
    assert_eq!(env_dimension_value, Some(expected_env));
}

fn as_cbor_map(value: &CborValue) -> &std::collections::BTreeMap<CborValue, CborValue> {
    match value {
        CborValue::Map(map) => map,
        other => panic!("expected CBOR map, got {other:?}"),
    }
}

fn as_cbor_array(value: &CborValue) -> &Vec<CborValue> {
    match value {
        CborValue::Array(array) => array,
        other => panic!("expected CBOR array, got {other:?}"),
    }
}

fn cbor_text(value: &CborValue) -> &str {
    match value {
        CborValue::Text(text) => text,
        other => panic!("expected CBOR text, got {other:?}"),
    }
}

fn cbor_f64(value: &CborValue) -> f64 {
    match value {
        CborValue::Float(float_value) => *float_value,
        CborValue::Integer(integer_value) => *integer_value as f64,
        other => panic!("expected CBOR numeric value, got {other:?}"),
    }
}

fn cbor_get<'a>(
    map: &'a std::collections::BTreeMap<CborValue, CborValue>,
    key: &str,
) -> &'a CborValue {
    map.get(&CborValue::Text(key.to_string()))
        .unwrap_or_else(|| panic!("missing CBOR key '{key}'"))
}

fn assert_cbor_metric_payload(raw_body: &[u8], expected_env: &str, expected_value: f64) {
    let root_value: CborValue = serde_cbor::from_slice(raw_body).unwrap_or_else(|error| {
        panic!(
            "failed to parse CloudWatch request as CBOR after JSON parse miss: {error}; body={}",
            String::from_utf8_lossy(raw_body)
        )
    });
    let root = as_cbor_map(&root_value);
    assert_eq!(cbor_text(cbor_get(root, "Namespace")), "fjcloud/api");

    let metric_data = as_cbor_array(cbor_get(root, "MetricData"));
    let metric_datum = as_cbor_map(
        metric_data
            .first()
            .expect("MetricData must include one CBOR metric datum"),
    );
    assert_eq!(
        cbor_text(cbor_get(metric_datum, "MetricName")),
        "WebhookBacklog"
    );
    assert_eq!(cbor_text(cbor_get(metric_datum, "Unit")), "Count");
    assert_eq!(cbor_f64(cbor_get(metric_datum, "Value")), expected_value);

    let dimensions = as_cbor_array(cbor_get(metric_datum, "Dimensions"));
    let env_dimension_value = dimensions.iter().map(as_cbor_map).find_map(|dimension| {
        (cbor_text(cbor_get(dimension, "Name")) == "Env")
            .then(|| cbor_text(cbor_get(dimension, "Value")))
    });
    assert_eq!(env_dimension_value, Some(expected_env));
}

fn assert_put_metric_payload(raw_body: &[u8], expected_env: &str, expected_value: f64) {
    if let Ok(json_body) = serde_json::from_slice::<serde_json::Value>(raw_body) {
        assert_json_metric_payload(&json_body, expected_env, expected_value);
    } else {
        assert_cbor_metric_payload(raw_body, expected_env, expected_value);
    }
}

#[tokio::test]
async fn webhook_lag_publisher_sends_webhook_backlog_metric() {
    let server = MockServer::start().await;
    let cloudwatch = cloudwatch_client_for_mock_server(&server).await;
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let now = Utc::now();

    for offset in [620_i64, 700, 900] {
        webhook_event_repo.seed_row(WebhookEventRow {
            stripe_event_id: format!("evt_stale_{offset}"),
            event_type: "charge.dispute.created".to_string(),
            payload: serde_json::json!({}),
            processed_at: None,
            created_at: now - ChronoDuration::seconds(offset),
        });
    }
    webhook_event_repo.seed_row(WebhookEventRow {
        stripe_event_id: "evt_recent".to_string(),
        event_type: "charge.dispute.created".to_string(),
        payload: serde_json::json!({}),
        processed_at: None,
        created_at: now - ChronoDuration::seconds(30),
    });
    webhook_event_repo.seed_row(WebhookEventRow {
        stripe_event_id: "evt_processed_old".to_string(),
        event_type: "charge.dispute.created".to_string(),
        payload: serde_json::json!({}),
        processed_at: Some(now),
        created_at: now - ChronoDuration::seconds(700),
    });

    let repo_trait_object: Arc<dyn WebhookEventRepo + Send + Sync> = webhook_event_repo;
    let publisher = WebhookLagPublisher::new(
        cloudwatch,
        repo_trait_object,
        "stage4-env-sentinel".to_string(),
        Duration::from_millis(5),
        Duration::from_secs(300),
    );
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let handle = tokio::spawn(async move {
        publisher.run(shutdown_rx).await;
    });

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    let raw_body = loop {
        let requests = server
            .received_requests()
            .await
            .expect("wiremock should capture CloudWatch requests");
        if let Some(request) = requests.first() {
            break request.body.clone();
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "webhook lag publisher did not emit any CloudWatch request before timeout"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    };

    shutdown_tx
        .send(true)
        .expect("shutdown signal should be delivered");
    handle
        .await
        .expect("webhook lag publisher task should join cleanly");

    assert_put_metric_payload(&raw_body, "stage4-env-sentinel", 3.0);
}

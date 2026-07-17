use std::sync::Arc;
use std::time::Duration;

use api::services::metrics::MetricsCollector;
use api::services::panics::PanicsPublisher;
use serde_cbor::Value as CborValue;
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, ResponseTemplate};

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
        "panics-test",
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
    assert_eq!(metric_datum["MetricName"].as_str(), Some("PanicsPerPeriod"));
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
        "PanicsPerPeriod"
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
async fn panics_publisher_sends_per_period_panic_deltas() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
        .mount(&server)
        .await;
    let cloudwatch = cloudwatch_client_for_mock_server(&server).await;
    let metrics = Arc::new(MetricsCollector::new());
    let env = "panic-env-sentinel";

    for _ in 0..5 {
        metrics.record_panic();
    }

    let mut publisher = PanicsPublisher::new(
        cloudwatch,
        env.to_string(),
        Duration::from_millis(50),
        Arc::clone(&metrics),
    );

    publisher
        .publish_once()
        .await
        .expect("first panic metric publish should succeed");
    for _ in 0..3 {
        metrics.record_panic();
    }
    publisher
        .publish_once()
        .await
        .expect("second panic metric publish should succeed");

    let bodies = server
        .received_requests()
        .await
        .expect("wiremock should capture CloudWatch requests")
        .into_iter()
        .map(|request| request.body)
        .collect::<Vec<_>>();
    assert_eq!(bodies.len(), 2);
    assert_put_metric_payload(&bodies[0], env, 5.0);
    assert_put_metric_payload(&bodies[1], env, 3.0);
}

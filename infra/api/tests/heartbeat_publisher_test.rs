use std::time::Duration;

use api::services::heartbeat::HeartbeatPublisher;
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
        "heartbeat-test",
    );
    let cloudwatch_config = aws_sdk_cloudwatch::config::Builder::from(&aws_config)
        .endpoint_url(server.uri())
        .credentials_provider(credentials)
        .build();
    aws_sdk_cloudwatch::Client::from_conf(cloudwatch_config)
}

#[tokio::test]
async fn heartbeat_publisher_sends_expected_metric_payload() {
    let server = MockServer::start().await;
    let cloudwatch = cloudwatch_client_for_mock_server(&server).await;
    // Use a distinctive sentinel as the env value so a substring assertion
    // on the wire body can prove the publisher actually emitted the
    // Env dimension *value* (not just the dimension name "Env").
    let env_value = "stage3-env-sentinel";
    let publisher =
        HeartbeatPublisher::new(cloudwatch, env_value.to_string(), Duration::from_millis(5));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let handle = tokio::spawn(async move {
        publisher.run(shutdown_rx).await;
    });

    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    let (raw_body, body) = loop {
        let requests = server
            .received_requests()
            .await
            .expect("wiremock should capture CloudWatch requests");
        if let Some(request) = requests.first() {
            let raw = request.body.clone();
            let lossy = String::from_utf8_lossy(&raw).to_string();
            break (raw, lossy);
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "heartbeat publisher did not emit any CloudWatch request before timeout"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    };

    shutdown_tx
        .send(true)
        .expect("shutdown signal should be delivered");
    handle.await.expect("heartbeat task should join cleanly");

    // AWS SDK may use CBOR (binary) or query-string encoding depending on
    // version. Both embed the metric field values as literal UTF-8 substrings,
    // so byte-level substring checks work for either wire format.
    let body_bytes = &raw_body;
    assert!(
        body_bytes
            .windows(b"Heartbeat".len())
            .any(|w| w == b"Heartbeat"),
        "payload must include Heartbeat metric name; body={body}"
    );
    assert!(
        body_bytes
            .windows(b"fjcloud/api".len())
            .any(|w| w == b"fjcloud/api"),
        "payload must include fjcloud/api namespace; body={body}"
    );
    assert!(
        body_bytes.windows(b"Env".len()).any(|w| w == b"Env"),
        "payload must include Env dimension name; body={body}"
    );
    assert!(
        body_bytes
            .windows(env_value.len())
            .any(|w| w == env_value.as_bytes()),
        "payload must include Env dimension value '{env_value}'; body={body}"
    );
}

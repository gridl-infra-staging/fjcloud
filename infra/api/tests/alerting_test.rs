mod common;

use std::collections::HashMap;

use api::services::alerting::{
    Alert, AlertError, AlertService, AlertSeverity, LogAlertService, MockAlertService,
    WebhookAlertService,
};
use sqlx::postgres::PgPoolOptions;

// ---------------------------------------------------------------------------
// Test 1: mock records alerts
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mock_records_alerts() {
    let svc = MockAlertService::new();

    let alert = Alert {
        severity: AlertSeverity::Critical,
        title: "VM unhealthy".into(),
        message: "deployment xyz failed 3 health checks".into(),
        metadata: HashMap::from([
            ("deployment_id".into(), "abc-123".into()),
            ("region".into(), "us-east-1".into()),
        ]),
    };

    svc.send_alert(alert).await.unwrap();
    assert_eq!(svc.alert_count(), 1);

    let recorded = svc.recorded_alerts();
    assert_eq!(recorded[0].severity, AlertSeverity::Critical);
    assert_eq!(recorded[0].title, "VM unhealthy");
    assert_eq!(recorded[0].delivery_status, "mock");

    // Metadata should be persisted as JSON
    let meta = recorded[0].metadata.as_object().unwrap();
    assert_eq!(meta.get("deployment_id").unwrap(), "abc-123");
    assert_eq!(meta.get("region").unwrap(), "us-east-1");
}

// ---------------------------------------------------------------------------
// Test 2: slack formats message correctly
// ---------------------------------------------------------------------------

#[tokio::test]
async fn slack_formats_message_correctly() {
    // We don't need a real DB or HTTP — just test the formatting method.
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect_lazy("postgres://fake:fake@localhost/fake_db")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::new();

    let svc = WebhookAlertService::new(
        pool,
        http_client,
        Some("https://hooks.slack.com/test".into()),
        None,
        "staging".into(),
    );

    let alert = Alert {
        severity: AlertSeverity::Warning,
        title: "Payment failed".into(),
        message: "Invoice inv_123 failed for customer cust_456".into(),
        metadata: HashMap::from([("customer_id".into(), "cust_456".into())]),
    };

    let payload = svc.format_slack_payload(&alert);

    // Verify structure
    let attachments = payload["attachments"].as_array().unwrap();
    assert_eq!(attachments.len(), 1);

    let attachment = &attachments[0];
    assert_eq!(attachment["color"], "#daa038"); // Warning = yellow
    assert_eq!(attachment["title"], "Payment failed");
    assert_eq!(
        attachment["text"],
        "Invoice inv_123 failed for customer cust_456"
    );

    // Verify fields contain metadata + environment
    let fields = attachment["fields"].as_array().unwrap();
    let field_titles: Vec<&str> = fields
        .iter()
        .map(|f| f["title"].as_str().unwrap())
        .collect();
    assert!(field_titles.contains(&"customer_id"));
    assert!(field_titles.contains(&"Environment"));

    // Verify environment field value
    let env_field = fields.iter().find(|f| f["title"] == "Environment").unwrap();
    assert_eq!(env_field["value"], "staging");
}

// ---------------------------------------------------------------------------
// Test 3: severity color mapping
// ---------------------------------------------------------------------------

#[test]
fn severity_colors_are_correct() {
    assert_eq!(AlertSeverity::Info.slack_color(), "#36a64f"); // green
    assert_eq!(AlertSeverity::Warning.slack_color(), "#daa038"); // yellow
    assert_eq!(AlertSeverity::Critical.slack_color(), "#d00000"); // red
}

// ---------------------------------------------------------------------------
// Test 4: MockAlertService handles empty metadata without error
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mock_handles_empty_metadata() {
    let svc = MockAlertService::new();

    let alert = Alert {
        severity: AlertSeverity::Info,
        title: "Test".into(),
        message: "No metadata".into(),
        metadata: HashMap::new(),
    };

    let result = svc.send_alert(alert).await;
    assert!(result.is_ok());
    assert_eq!(svc.alert_count(), 1);
    let recorded = svc.recorded_alerts();
    assert_eq!(recorded[0].metadata, serde_json::json!({}));
}

// ---------------------------------------------------------------------------
// Test 5: LogAlertService attempts persist after logging (no panic)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn log_alert_service_logs_and_attempts_persist() {
    // LogAlertService should log at the correct tracing level for each severity,
    // then attempt DB persist. With a fake pool, we get DbError — proving the
    // logging code ran without panic and reached the persist step.
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(100))
        .connect_lazy("postgres://fake:fake@127.0.0.1:59999/fake_db")
        .expect("connect_lazy should never fail");

    let svc = LogAlertService::new(pool);

    for severity in [
        AlertSeverity::Info,
        AlertSeverity::Warning,
        AlertSeverity::Critical,
    ] {
        let alert = Alert {
            severity,
            title: format!("{severity} alert"),
            message: "Testing log level dispatch".into(),
            metadata: HashMap::from([("test_key".into(), "test_value".into())]),
        };

        let result = svc.send_alert(alert).await;
        assert!(
            matches!(result, Err(AlertError::DbError(_))),
            "expected DbError for {severity} severity, got: {result:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// Test 6: AlertSeverity parse / as_str round-trip and edge cases
// ---------------------------------------------------------------------------

#[test]
fn alert_severity_round_trip() {
    for severity in [
        AlertSeverity::Info,
        AlertSeverity::Warning,
        AlertSeverity::Critical,
    ] {
        let s = severity.as_str();
        let parsed = s.parse::<AlertSeverity>().ok();
        assert_eq!(parsed, Some(severity), "round-trip failed for {s}");
    }

    // Display trait should match as_str
    assert_eq!(format!("{}", AlertSeverity::Info), "info");
    assert_eq!(format!("{}", AlertSeverity::Warning), "warning");
    assert_eq!(format!("{}", AlertSeverity::Critical), "critical");

    // Invalid input returns None
    assert_eq!("invalid".parse::<AlertSeverity>().ok(), None);
    assert_eq!("INFO".parse::<AlertSeverity>().ok(), None); // case-sensitive
    assert_eq!("".parse::<AlertSeverity>().ok(), None);
}

// ---------------------------------------------------------------------------
// Test 7: get_recent_alerts returns persisted alerts in chronological order
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_recent_alerts_returns_in_reverse_chronological_order() {
    let svc = MockAlertService::new();

    // Send 3 alerts with small delays to ensure different timestamps
    for i in 0..3 {
        let alert = Alert {
            severity: AlertSeverity::Info,
            title: format!("Alert {i}"),
            message: format!("Message {i}"),
            metadata: HashMap::new(),
        };
        svc.send_alert(alert).await.unwrap();
        // Small delay to ensure timestamps differ
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    assert_eq!(svc.alert_count(), 3);

    // get_recent_alerts should return in DESC order (newest first)
    let recent = svc.get_recent_alerts(10).await.unwrap();
    assert_eq!(recent.len(), 3);
    assert_eq!(recent[0].title, "Alert 2"); // newest
    assert_eq!(recent[1].title, "Alert 1");
    assert_eq!(recent[2].title, "Alert 0"); // oldest

    // Verify timestamps are actually in descending order (not just titles)
    assert!(
        recent[0].created_at >= recent[1].created_at,
        "Alert 2 should have later timestamp than Alert 1"
    );
    assert!(
        recent[1].created_at >= recent[2].created_at,
        "Alert 1 should have later timestamp than Alert 0"
    );

    // Limit should work
    let limited = svc.get_recent_alerts(2).await.unwrap();
    assert_eq!(limited.len(), 2);
    assert_eq!(limited[0].title, "Alert 2");
    assert_eq!(limited[1].title, "Alert 1");
}

// ---------------------------------------------------------------------------
// Test 8: non-positive limits should return no alerts
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_recent_alerts_with_non_positive_limit_returns_empty() {
    let svc = MockAlertService::new();

    for i in 0..2 {
        svc.send_alert(Alert {
            severity: AlertSeverity::Info,
            title: format!("Alert {i}"),
            message: format!("Message {i}"),
            metadata: HashMap::new(),
        })
        .await
        .unwrap();
    }

    assert!(
        svc.get_recent_alerts(0).await.unwrap().is_empty(),
        "limit=0 should return empty list"
    );
    assert!(
        svc.get_recent_alerts(-5).await.unwrap().is_empty(),
        "negative limit should return empty list"
    );
}

// ---------------------------------------------------------------------------
// Test 9: discord formats message correctly (embed with integer color)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn discord_formats_message_correctly() {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect_lazy("postgres://fake:fake@localhost/fake_db")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::new();

    let svc = WebhookAlertService::new(
        pool,
        http_client,
        None, // no slack
        Some("https://discord.com/api/webhooks/test".into()),
        "production".into(),
    );

    let alert = Alert {
        severity: AlertSeverity::Critical,
        title: "VM unhealthy".into(),
        message: "deployment xyz failed 3 health checks".into(),
        metadata: HashMap::from([
            ("deployment_id".into(), "dep-789".into()),
            ("region".into(), "eu-west-1".into()),
        ]),
    };

    let payload = svc.format_discord_payload(&alert);

    // Discord uses "embeds" array
    let embeds = payload["embeds"].as_array().unwrap();
    assert_eq!(embeds.len(), 1);

    let embed = &embeds[0];
    // Critical = red = 0xd00000 = 13631488
    assert_eq!(embed["color"], 0xd00000_u32);
    assert_eq!(embed["title"], "VM unhealthy");
    assert_eq!(
        embed["description"],
        "deployment xyz failed 3 health checks"
    );

    // Fields should contain metadata + environment
    let fields = embed["fields"].as_array().unwrap();
    let field_names: Vec<&str> = fields.iter().map(|f| f["name"].as_str().unwrap()).collect();
    assert!(field_names.contains(&"deployment_id"));
    assert!(field_names.contains(&"region"));
    assert!(field_names.contains(&"Environment"));

    // Verify environment field value
    let env_field = fields.iter().find(|f| f["name"] == "Environment").unwrap();
    assert_eq!(env_field["value"], "production");

    // Discord embeds use ISO 8601 timestamp
    assert!(embed["timestamp"].as_str().is_some());
}

// ---------------------------------------------------------------------------
// Test 10: discord severity colors are correct (decimal integers)
// ---------------------------------------------------------------------------

#[test]
fn discord_severity_colors_are_correct() {
    assert_eq!(AlertSeverity::Info.discord_color(), 0x36a64f_u32); // green
    assert_eq!(AlertSeverity::Warning.discord_color(), 0xdaa038_u32); // yellow
    assert_eq!(AlertSeverity::Critical.discord_color(), 0xd00000_u32); // red
}

// ---------------------------------------------------------------------------
// Test 11: webhook service constructor accepts both slack and discord URLs
// ---------------------------------------------------------------------------

#[tokio::test]
async fn webhook_not_configured_skips_both_channels() {
    // WebhookAlertService with neither Slack nor Discord should skip both
    // and go straight to DB persist. With a fake pool, persist returns DbError.
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(100))
        .connect_lazy("postgres://fake:fake@127.0.0.1:59999/fake_db")
        .expect("connect_lazy should never fail");

    let http_client = reqwest::Client::new();
    let svc = WebhookAlertService::new(pool, http_client, None, None, "test".into());

    let alert = Alert {
        severity: AlertSeverity::Warning,
        title: "Test graceful degradation".into(),
        message: "Neither webhook configured".into(),
        metadata: HashMap::new(),
    };

    let result = svc.send_alert(alert).await;
    assert!(
        matches!(result, Err(AlertError::DbError(_))),
        "expected DbError when no webhooks configured, got: {result:?}"
    );
}

// ---------------------------------------------------------------------------
// Test 12: delivery status resolution is deterministic
// ---------------------------------------------------------------------------

#[test]
fn webhook_delivery_status_resolution_paths_are_correct() {
    assert_eq!(
        WebhookAlertService::resolve_delivery_status(true, true),
        "sent"
    );
    assert_eq!(
        WebhookAlertService::resolve_delivery_status(false, true),
        "failed"
    );
    assert_eq!(
        WebhookAlertService::resolve_delivery_status(false, false),
        "skipped"
    );
}

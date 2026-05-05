mod common;

use api::services::email::{EmailService, MockEmailService, SesConfig, SesEmailService};
use api::services::email_suppression::InMemoryEmailSuppressionStore;
use api::startup_env::{RawEnvFamilyState, SesStartupMode, StartupEnvSnapshot};
use std::sync::Arc;

#[tokio::test]
async fn mock_email_service_captures_verification_email() {
    let service = MockEmailService::new();

    service
        .send_verification_email("alice@example.com", "verify-token-123")
        .await
        .expect("verification email should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "alice@example.com");
    assert!(sent[0].subject.contains("Verify your email"));
    assert!(
        sent[0]
            .html_body
            .contains(r#"href="https://cloud.flapjack.foo/verify-email/verify-token-123""#),
        "verification email body should contain full URL, got: {}",
        sent[0].html_body
    );
    assert!(!sent[0].html_body.contains("verify-email?token="));
    assert!(
        sent[0].html_body.contains("Flapjack Cloud"),
        "verification email should include Flapjack Cloud branding, got: {}",
        sent[0].html_body
    );
    assert!(!sent[0].html_body.contains("app.griddle.io"));
    assert!(sent[0].text_body.contains("verify-email/verify-token-123"));
    assert!(!sent[0].text_body.contains("verify-email?token="));
}

#[tokio::test]
async fn mock_email_service_captures_password_reset_email() {
    let service = MockEmailService::new();

    service
        .send_password_reset_email("alice@example.com", "reset-token-456")
        .await
        .expect("password reset email should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "alice@example.com");
    assert!(sent[0].subject.contains("Reset your password"));
    assert!(
        sent[0]
            .html_body
            .contains(r#"href="https://cloud.flapjack.foo/reset-password/reset-token-456""#),
        "password reset email body should contain full URL, got: {}",
        sent[0].html_body
    );
    assert!(!sent[0].html_body.contains("reset-password?token="));
    assert!(
        sent[0].html_body.contains("Flapjack Cloud"),
        "password reset email should include Flapjack Cloud branding, got: {}",
        sent[0].html_body
    );
    assert!(!sent[0].html_body.contains("app.griddle.io"));
    assert!(sent[0].text_body.contains("reset-password/reset-token-456"));
    assert!(!sent[0].text_body.contains("reset-password?token="));
}

#[tokio::test]
async fn mock_email_service_captures_invoice_ready_email() {
    let service = MockEmailService::new();

    service
        .send_invoice_ready_email(
            "alice@example.com",
            "inv_123",
            "https://billing.example.com/invoices/inv_123",
            Some("https://billing.example.com/invoices/inv_123/pdf"),
        )
        .await
        .expect("invoice ready email should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "alice@example.com");
    assert!(sent[0].subject.contains("Your invoice is ready"));
    assert!(sent[0].html_body.contains("inv_123"));
    assert!(sent[0]
        .html_body
        .contains("https://billing.example.com/invoices/inv_123"));
    assert!(sent[0]
        .html_body
        .contains("https://billing.example.com/invoices/inv_123/pdf"));
    assert!(
        sent[0].html_body.contains("Download PDF"),
        "invoice ready email should include PDF download link text when pdf_url is present, got: {}",
        sent[0].html_body
    );
    assert!(
        sent[0].html_body.contains("Flapjack Cloud"),
        "invoice ready email should include Flapjack Cloud branding, got: {}",
        sent[0].html_body
    );
    assert!(sent[0].text_body.contains("inv_123"));
    assert!(sent[0]
        .text_body
        .contains("https://billing.example.com/invoices/inv_123"));
    assert!(sent[0]
        .text_body
        .contains("https://billing.example.com/invoices/inv_123/pdf"));
}

#[tokio::test]
async fn mock_email_service_omits_pdf_link_when_pdf_url_missing() {
    let service = MockEmailService::new();

    service
        .send_invoice_ready_email(
            "alice@example.com",
            "inv_456",
            "https://billing.example.com/invoices/inv_456",
            None,
        )
        .await
        .expect("invoice ready email should be captured without PDF URL");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert!(
        !sent[0].html_body.contains("Download PDF"),
        "invoice ready email should omit PDF link text when pdf_url is missing, got: {}",
        sent[0].html_body
    );
    assert!(!sent[0].text_body.contains("Download PDF"));
    assert!(!sent[0].text_body.contains("/pdf"));
}

#[tokio::test]
async fn mock_email_service_captures_quota_warning_email() {
    let service = MockEmailService::new();

    service
        .send_quota_warning_email("alice@example.com", "monthly_searches", 80.0, 800, 1000)
        .await
        .expect("quota warning email should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "alice@example.com");
    assert!(sent[0].subject.contains("Usage warning"));
    assert!(sent[0].html_body.contains("monthly_searches"));
    assert!(sent[0].html_body.contains("80.0%"));
    assert!(sent[0].html_body.contains("800"));
    assert!(sent[0].html_body.contains("1000"));
    assert!(
        sent[0].html_body.contains("Flapjack Cloud"),
        "quota warning email should include Flapjack Cloud branding, got: {}",
        sent[0].html_body
    );
    assert!(sent[0].text_body.contains("monthly_searches"));
    assert!(sent[0].text_body.contains("80.0%"));
    assert!(sent[0].text_body.contains("800"));
    assert!(sent[0].text_body.contains("1000"));
}

#[tokio::test]
async fn mock_email_rejects_empty_recipient() {
    let service = MockEmailService::new();
    let err = service
        .send_verification_email("", "tok")
        .await
        .expect_err("empty recipient should be rejected");
    assert!(err.to_string().contains("must not be empty"));
}

#[tokio::test]
async fn mock_email_rejects_whitespace_recipient() {
    let service = MockEmailService::new();
    let err = service
        .send_verification_email("  ", "tok")
        .await
        .expect_err("whitespace recipient should be rejected");
    assert!(err.to_string().contains("must not be empty"));
}

#[tokio::test]
async fn mock_email_service_records_broadcast_plain_text_as_pre_wrapped_html() {
    let service = MockEmailService::new();
    let recipient = "broadcast@test.com";
    let subject = "Planned maintenance";
    let text_body = "Maintenance <b>starts</b> & needs \"approval\"";

    service
        .send_broadcast_email(recipient, subject, Option::<&str>::None, Some(text_body))
        .await
        .expect("plain-text broadcast should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, recipient);
    assert_eq!(sent[0].subject, subject);
    assert_eq!(
        sent[0].html_body,
        "<pre>Maintenance &lt;b&gt;starts&lt;/b&gt; &amp; needs &quot;approval&quot;</pre>"
    );
    assert_eq!(sent[0].text_body, text_body);
}

#[tokio::test]
async fn mock_email_service_preserves_html_only_broadcast_as_html_only() {
    let service = MockEmailService::new();
    let recipient = "broadcast@test.com";
    let subject = "Release notice";
    let html_body = "<p>Release at 02:00 UTC</p>";

    service
        .send_broadcast_email(recipient, subject, Some(html_body), None)
        .await
        .expect("html-only broadcast should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, recipient);
    assert_eq!(sent[0].subject, subject);
    assert_eq!(sent[0].html_body, html_body);
    assert_eq!(sent[0].text_body, "");
}

#[tokio::test]
async fn mock_email_service_preserves_operator_whitespace_in_broadcast_bodies() {
    let service = MockEmailService::new();
    let recipient = "broadcast@test.com";
    let subject = "Whitespace-sensitive notice";
    let html_body = "  <p>Indented html block</p>\n";
    let text_body = " \nBroadcast line one\nBroadcast line two\n ";

    service
        .send_broadcast_email(recipient, subject, Some(html_body), Some(text_body))
        .await
        .expect("broadcast with non-empty html/text should be captured");

    let sent = service.sent_emails();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, recipient);
    assert_eq!(sent[0].subject, subject);
    assert_eq!(sent[0].html_body, html_body);
    assert_eq!(sent[0].text_body, text_body);
}

fn snapshot_with(values: &[(&str, &str)]) -> StartupEnvSnapshot {
    StartupEnvSnapshot::from_reader(|key| {
        values
            .iter()
            .find(|(candidate, _)| *candidate == key)
            .map(|(_, value)| value.to_string())
    })
}

fn ses_config_from_snapshot(snapshot: &StartupEnvSnapshot) -> Result<SesConfig, String> {
    SesConfig::from_reader(|key| snapshot.env_value(key).map(str::to_string))
}

#[test]
fn startup_env_snapshot_captures_ses_configuration_set_for_central_ses_parser() {
    let snapshot = snapshot_with(&[
        ("SES_FROM_ADDRESS", "system@flapjack.foo"),
        ("SES_REGION", "us-east-1"),
        ("SES_CONFIGURATION_SET", "stage2-feedback"),
    ]);

    assert_eq!(
        snapshot.env_value("SES_CONFIGURATION_SET"),
        Some("stage2-feedback"),
        "startup env snapshot should expose SES_CONFIGURATION_SET via env_value()"
    );

    let config = ses_config_from_snapshot(&snapshot)
        .expect("SesConfig::from_reader should read SES configuration from startup snapshot");
    assert_eq!(config.from_address, "system@flapjack.foo");
    assert_eq!(config.region, "us-east-1");
    assert_eq!(config.configuration_set, "stage2-feedback");
}

#[test]
fn ses_startup_mode_uses_noop_only_for_local_mode_with_absent_ses_env() {
    let memory_only = snapshot_with(&[("NODE_SECRET_BACKEND", "memory")]);
    assert_eq!(memory_only.ses_startup_mode(), SesStartupMode::Ses);
    assert!(
        ses_config_from_snapshot(&memory_only).is_err(),
        "memory backend alone must not enable the local noop-email fallback"
    );

    let local_absent =
        snapshot_with(&[("ENVIRONMENT", "local"), ("NODE_SECRET_BACKEND", "memory")]);
    assert_eq!(
        local_absent.ses_family_state(),
        RawEnvFamilyState::AllAbsent
    );
    assert_eq!(local_absent.ses_startup_mode(), SesStartupMode::Noop);

    let local_explicit = snapshot_with(&[
        ("ENVIRONMENT", "local"),
        ("NODE_SECRET_BACKEND", "memory"),
        ("SES_FROM_ADDRESS", "ops@example.com"),
        ("SES_REGION", "us-east-1"),
        ("SES_CONFIGURATION_SET", "ses-feedback"),
    ]);
    assert_eq!(
        local_explicit.ses_family_state(),
        RawEnvFamilyState::FullyExplicit
    );
    assert_eq!(local_explicit.ses_startup_mode(), SesStartupMode::Ses);
    assert!(
        ses_config_from_snapshot(&local_explicit).is_ok(),
        "fully explicit SES env should parse"
    );
}

#[test]
fn ses_startup_mode_routes_blank_and_partial_to_existing_parser_error_path() {
    let local_blank = snapshot_with(&[
        ("ENVIRONMENT", "local"),
        ("NODE_SECRET_BACKEND", "memory"),
        ("SES_FROM_ADDRESS", " "),
        ("SES_REGION", "us-east-1"),
    ]);
    assert_eq!(
        local_blank.ses_family_state(),
        RawEnvFamilyState::HasBlankValues
    );
    assert_eq!(local_blank.ses_startup_mode(), SesStartupMode::Ses);
    assert!(
        ses_config_from_snapshot(&local_blank).is_err(),
        "blank SES values must still fail via SesConfig::from_reader"
    );

    let local_partial = snapshot_with(&[
        ("ENVIRONMENT", "local"),
        ("NODE_SECRET_BACKEND", "memory"),
        ("SES_FROM_ADDRESS", "ops@example.com"),
    ]);
    assert_eq!(
        local_partial.ses_family_state(),
        RawEnvFamilyState::PartiallyExplicit
    );
    assert_eq!(local_partial.ses_startup_mode(), SesStartupMode::Ses);
    assert!(
        ses_config_from_snapshot(&local_partial).is_err(),
        "partial SES values must still fail via SesConfig::from_reader"
    );
}

#[test]
fn ses_startup_mode_keeps_non_local_absent_ses_on_fail_fast_path() {
    let non_local_absent = snapshot_with(&[("NODE_SECRET_BACKEND", "auto")]);
    assert_eq!(
        non_local_absent.ses_family_state(),
        RawEnvFamilyState::AllAbsent
    );
    assert_eq!(non_local_absent.ses_startup_mode(), SesStartupMode::Ses);
    assert!(
        ses_config_from_snapshot(&non_local_absent).is_err(),
        "non-local startup must not silently noop when SES vars are absent"
    );
}

// ---------------------------------------------------------------------------
// SesConfig validation tests (RED → GREEN)
// ---------------------------------------------------------------------------

#[test]
fn ses_config_requires_from_address() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    });
    assert!(
        result.is_err(),
        "should fail when SES_FROM_ADDRESS is missing"
    );
    let err = result.unwrap_err();
    assert!(
        err.contains("SES_FROM_ADDRESS"),
        "error should mention SES_FROM_ADDRESS: {err}"
    );
}

#[test]
fn ses_config_rejects_empty_from_address() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    });
    assert!(result.is_err(), "should reject empty SES_FROM_ADDRESS");
}

#[test]
fn ses_config_rejects_whitespace_from_address() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("   ".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    });
    assert!(
        result.is_err(),
        "should reject whitespace-only SES_FROM_ADDRESS"
    );
}

#[test]
fn ses_config_requires_region() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        _ => None,
    });
    assert!(result.is_err(), "should fail when SES_REGION is missing");
    let err = result.unwrap_err();
    assert!(
        err.contains("SES_REGION"),
        "error should mention SES_REGION: {err}"
    );
}

#[test]
fn ses_config_rejects_empty_region() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("".to_string()),
        _ => None,
    });
    assert!(result.is_err(), "should reject empty SES_REGION");
}

#[test]
fn ses_config_rejects_whitespace_region() {
    let result = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("   ".to_string()),
        _ => None,
    });
    assert!(result.is_err(), "should reject whitespace-only SES_REGION");
}

#[test]
fn ses_config_parses_valid_config() {
    let config = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    })
    .expect("should parse valid SES config");
    assert_eq!(config.from_address, "system@flapjack.foo");
    assert_eq!(config.region, "us-east-1");
    assert_eq!(config.configuration_set, "ses-feedback");
    assert_eq!(config.from_name, "Flapjack Cloud");
}

#[test]
fn ses_config_trims_whitespace() {
    let config = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("  system@flapjack.foo  ".to_string()),
        "SES_CONFIGURATION_SET" => Some("  ses-feedback  ".to_string()),
        "SES_REGION" => Some("  us-west-2  ".to_string()),
        "EMAIL_FROM_NAME" => Some("  Billing Team  ".to_string()),
        _ => None,
    })
    .expect("should parse and trim SES config");
    assert_eq!(config.from_address, "system@flapjack.foo");
    assert_eq!(config.region, "us-west-2");
    assert_eq!(config.configuration_set, "ses-feedback");
    assert_eq!(config.from_name, "Billing Team");
}

#[test]
fn ses_config_defaults_from_name_when_missing_or_blank() {
    let missing_name = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    })
    .expect("missing EMAIL_FROM_NAME should use default");
    assert_eq!(missing_name.from_name, "Flapjack Cloud");

    let blank_name = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_CONFIGURATION_SET" => Some("ses-feedback".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        "EMAIL_FROM_NAME" => Some("   ".to_string()),
        _ => None,
    })
    .expect("blank EMAIL_FROM_NAME should use default");
    assert_eq!(blank_name.from_name, "Flapjack Cloud");
}

// ---------------------------------------------------------------------------
// Live SES smoke tests (env-gated, #[ignore])
// ---------------------------------------------------------------------------

/// Sends a real verification email via SES. Only runs when `SES_LIVE_TEST=1`.
///
/// Run with:
/// ```
/// SES_LIVE_TEST=1 SES_FROM_ADDRESS=system@flapjack.foo SES_REGION=us-east-1 \
/// SES_CONFIGURATION_SET=stage2-feedback \
///   cargo test ses_live_smoke -- --ignored
/// ```
#[tokio::test]
#[ignore]
async fn ses_live_smoke_sends_verification_email() {
    if std::env::var("SES_LIVE_TEST").as_deref() != Ok("1") {
        eprintln!("SES_LIVE_TEST not set — skipping live SES smoke test");
        return;
    }

    let config = SesConfig::from_env().expect("SES config must be set for live smoke test");
    let test_recipient =
        std::env::var("SES_TEST_RECIPIENT").unwrap_or_else(|_| config.from_address.clone());

    let aws_config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let ses_sdk_config = aws_sdk_sesv2::config::Builder::from(&aws_config)
        .region(aws_sdk_sesv2::config::Region::new(config.region))
        .build();
    let ses_client = aws_sdk_sesv2::Client::from_conf(ses_sdk_config);
    let service = SesEmailService::new(
        ses_client,
        config.from_address,
        config.configuration_set,
        Arc::new(InMemoryEmailSuppressionStore::default()),
    );

    service
        .send_verification_email(&test_recipient, "smoke-test-verify-token")
        .await
        .expect("live SES verification email should send without error");
}

/// Sends a real password reset email via SES. Only runs when `SES_LIVE_TEST=1`.
#[tokio::test]
#[ignore]
async fn ses_live_smoke_sends_password_reset_email() {
    if std::env::var("SES_LIVE_TEST").as_deref() != Ok("1") {
        eprintln!("SES_LIVE_TEST not set — skipping live SES smoke test");
        return;
    }

    let config = SesConfig::from_env().expect("SES config must be set for live smoke test");
    let test_recipient =
        std::env::var("SES_TEST_RECIPIENT").unwrap_or_else(|_| config.from_address.clone());

    let aws_config = aws_config::load_defaults(aws_config::BehaviorVersion::latest()).await;
    let ses_sdk_config = aws_sdk_sesv2::config::Builder::from(&aws_config)
        .region(aws_sdk_sesv2::config::Region::new(config.region))
        .build();
    let ses_client = aws_sdk_sesv2::Client::from_conf(ses_sdk_config);
    let service = SesEmailService::new(
        ses_client,
        config.from_address,
        config.configuration_set,
        Arc::new(InMemoryEmailSuppressionStore::default()),
    );

    service
        .send_password_reset_email(&test_recipient, "smoke-test-reset-token")
        .await
        .expect("live SES password reset email should send without error");
}

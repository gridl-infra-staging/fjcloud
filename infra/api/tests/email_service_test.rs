//! Tests for email service implementations (MockEmailService, NoopEmailService,
//! MailpitEmailService, SesConfig). Extracted from services/email.rs to keep
//! that file under the 800-line hard limit.

use api::services::email::{
    invoice_ready_email_html, password_reset_email_html, password_reset_email_html_with_base_url,
    quota_warning_email_html, verification_email_html, verification_email_html_with_base_url,
    EmailService, MailpitEmailService, MockEmailService, NoopEmailService, SesConfig,
    INVOICE_READY_SUBJECT, PASSWORD_RESET_SUBJECT, QUOTA_WARNING_SUBJECT, VERIFICATION_SUBJECT,
};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ---------------------------------------------------------------------------
// Template HTML unit tests
// ---------------------------------------------------------------------------

#[test]
fn verification_email_contains_token_url() {
    let html = verification_email_html("abc123");
    assert!(html.contains(r#"href="https://cloud.flapjack.foo/verify-email/abc123""#));
    assert!(!html.contains("verify-email?token="));
    assert!(html.contains("Verify your Flapjack Cloud account"));
    assert!(!html.contains("app.griddle.io"));
    assert!(!html.contains("Griddle"));
}

#[test]
fn password_reset_email_contains_token_url() {
    let html = password_reset_email_html("reset-tok-42");
    assert!(html.contains(r#"href="https://cloud.flapjack.foo/reset-password/reset-tok-42""#));
    assert!(!html.contains("reset-password?token="));
    assert!(html.contains("Flapjack Cloud password reset"));
    assert!(!html.contains("app.griddle.io"));
    assert!(!html.contains("Griddle"));
}

#[test]
fn auth_email_links_use_explicit_application_base_url() {
    let verify_html = verification_email_html_with_base_url("https://preview.example.test", "v1");
    let reset_html = password_reset_email_html_with_base_url("https://preview.example.test/", "r1");

    assert!(verify_html.contains(r#"href="https://preview.example.test/verify-email/v1""#));
    assert!(reset_html.contains(r#"href="https://preview.example.test/reset-password/r1""#));
    assert!(!verify_html.contains("verify-email?token="));
    assert!(!reset_html.contains("reset-password?token="));
    assert!(!verify_html.contains("cloud.flapjack.foo"));
    assert!(!reset_html.contains("cloud.flapjack.foo"));
}

#[test]
fn invoice_email_with_pdf_url() {
    let html = invoice_ready_email_html(
        "INV-001",
        "https://stripe.com/inv",
        Some("https://s3.example.com/inv.pdf"),
    );
    assert!(html.contains("INV-001"));
    assert!(html.contains("https://stripe.com/inv"));
    assert!(html.contains("Download PDF"));
    assert!(html.contains("https://s3.example.com/inv.pdf"));
}

#[test]
fn invoice_email_without_pdf_url() {
    let html = invoice_ready_email_html("INV-002", "https://stripe.com/inv2", None);
    assert!(html.contains("INV-002"));
    assert!(!html.contains("Download PDF"));
}

#[test]
fn quota_warning_email_renders_all_fields() {
    let html = quota_warning_email_html("queries", 85.3, 8530, 10000);
    assert!(html.contains("queries"));
    assert!(html.contains("85.3%"));
    assert!(html.contains("8530"));
    assert!(html.contains("10000"));
}

// ---------------------------------------------------------------------------
// MockEmailService tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mock_email_service_captures_sent_emails() {
    let service = MockEmailService::new();
    service
        .send_verification_email("user@test.com", "tok1")
        .await
        .unwrap();
    let emails = service.sent_emails();
    assert_eq!(emails.len(), 1);
    assert_eq!(emails[0].to, "user@test.com");
    assert_eq!(emails[0].subject, "Verify your email");
}

#[tokio::test]
async fn mock_email_rejects_empty_recipient() {
    let service = MockEmailService::new();
    let err = service
        .send_verification_email("", "tok")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("must not be empty"));
}

#[tokio::test]
async fn mock_email_rejects_whitespace_recipient() {
    let service = MockEmailService::new();
    let err = service
        .send_verification_email("  ", "tok")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("must not be empty"));
}

#[tokio::test]
async fn mock_email_service_records_broadcast_plain_text_as_pre_wrapped_html() {
    let service = MockEmailService::new();
    let recipient = "broadcast@test.com";
    let subject = "Planned maintenance";
    let text_body = "Maintenance starts at 02:00 UTC";

    service
        .send_broadcast_email(recipient, subject, Option::<&str>::None, Some(text_body))
        .await
        .unwrap();

    let emails = service.sent_emails();
    assert_eq!(emails.len(), 1);
    assert_eq!(emails[0].to, recipient);
    assert_eq!(emails[0].subject, subject);
    assert_eq!(emails[0].body, format!("<pre>{text_body}</pre>"));
}

// ---------------------------------------------------------------------------
// NoopEmailService tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn noop_email_accepts_non_empty_recipient_for_all_methods() {
    let service = NoopEmailService;
    let recipient = "noop@test.com";

    service
        .send_verification_email(recipient, "verify-token")
        .await
        .expect("verification should be accepted");
    service
        .send_password_reset_email(recipient, "reset-token")
        .await
        .expect("password reset should be accepted");
    service
        .send_invoice_ready_email(
            recipient,
            "inv_123",
            "https://billing.example.com/invoices/inv_123",
            Some("https://billing.example.com/invoices/inv_123.pdf"),
        )
        .await
        .expect("invoice ready should be accepted");
    service
        .send_quota_warning_email(recipient, "requests", 90.0, 900, 1000)
        .await
        .expect("quota warning should be accepted");
    service
        .send_broadcast_email(
            recipient,
            "Maintenance notice",
            Some("<p>Planned maintenance at 02:00 UTC</p>"),
            None,
        )
        .await
        .expect("broadcast should be accepted");
}

#[tokio::test]
async fn noop_email_rejects_blank_or_whitespace_recipient_with_record_validation_error() {
    let service = NoopEmailService;

    for recipient in ["", "   "] {
        let verification_err = service
            .send_verification_email(recipient, "verify-token")
            .await
            .expect_err("blank/whitespace recipients must fail");
        assert_eq!(
            verification_err.to_string(),
            "invalid email request: recipient email must not be empty"
        );

        let reset_err = service
            .send_password_reset_email(recipient, "reset-token")
            .await
            .expect_err("blank/whitespace recipients must fail");
        assert_eq!(
            reset_err.to_string(),
            "invalid email request: recipient email must not be empty"
        );

        let invoice_err = service
            .send_invoice_ready_email(recipient, "inv_123", "https://billing.example.com", None)
            .await
            .expect_err("blank/whitespace recipients must fail");
        assert_eq!(
            invoice_err.to_string(),
            "invalid email request: recipient email must not be empty"
        );

        let quota_err = service
            .send_quota_warning_email(recipient, "requests", 90.0, 900, 1000)
            .await
            .expect_err("blank/whitespace recipients must fail");
        assert_eq!(
            quota_err.to_string(),
            "invalid email request: recipient email must not be empty"
        );

        let broadcast_err = service
            .send_broadcast_email(
                recipient,
                "Maintenance notice",
                Some("<p>Planned maintenance at 02:00 UTC</p>"),
                None,
            )
            .await
            .expect_err("blank/whitespace recipients must fail");
        assert_eq!(
            broadcast_err.to_string(),
            "invalid email request: recipient email must not be empty"
        );
    }
}

// ---------------------------------------------------------------------------
// SesConfig tests
// ---------------------------------------------------------------------------

#[test]
fn ses_config_from_reader_valid() {
    let config = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("system@flapjack.foo".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    })
    .unwrap();
    assert_eq!(config.from_address, "system@flapjack.foo");
    assert_eq!(config.region, "us-east-1");
}

#[test]
fn ses_config_from_reader_missing_from() {
    let err = SesConfig::from_reader(|k| match k {
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    })
    .unwrap_err();
    assert!(err.contains("SES_FROM_ADDRESS"));
}

#[test]
fn ses_config_from_reader_missing_region() {
    let err = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("a@b.com".to_string()),
        _ => None,
    })
    .unwrap_err();
    assert!(err.contains("SES_REGION"));
}

#[test]
fn ses_config_trims_whitespace() {
    let config = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("  a@b.com  ".to_string()),
        "SES_REGION" => Some("  eu-west-1  ".to_string()),
        _ => None,
    })
    .unwrap();
    assert_eq!(config.from_address, "a@b.com");
    assert_eq!(config.region, "eu-west-1");
}

#[test]
fn ses_config_rejects_empty_after_trim() {
    let err = SesConfig::from_reader(|k| match k {
        "SES_FROM_ADDRESS" => Some("   ".to_string()),
        "SES_REGION" => Some("us-east-1".to_string()),
        _ => None,
    })
    .unwrap_err();
    assert!(err.contains("SES_FROM_ADDRESS"));
}

// ---------------------------------------------------------------------------
// MailpitEmailService tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn mailpit_email_service_rejects_empty_recipient() {
    let service = MailpitEmailService::new("http://localhost:99999", "noreply@test.com", "Test");
    let err = service
        .send_verification_email("", "token123")
        .await
        .unwrap_err();
    assert_eq!(
        err.to_string(),
        "invalid email request: recipient email must not be empty"
    );
}

#[tokio::test]
async fn mailpit_email_service_rejects_whitespace_recipient() {
    let service = MailpitEmailService::new("http://localhost:99999", "noreply@test.com", "Test");
    let err = service
        .send_verification_email("   ", "token123")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("must not be empty"));
}

#[tokio::test]
async fn mailpit_email_service_returns_delivery_failed_on_connection_error() {
    let service = MailpitEmailService::new(
        "http://localhost:99999",
        "noreply@test.com",
        "Flapjack Test",
    );
    let err = service
        .send_verification_email("user@example.com", "tok")
        .await
        .unwrap_err();
    assert!(
        err.to_string().contains("Mailpit request failed"),
        "expected connection error, got: {err}"
    );
}

// ---------------------------------------------------------------------------
// MailpitEmailService wiremock tests — payload, tags, URL, error handling
// ---------------------------------------------------------------------------

/// Helper: build a MailpitEmailService pointing at the given wiremock server.
fn mailpit_service(base_url: &str) -> MailpitEmailService {
    MailpitEmailService::new(base_url, "system@flapjack.foo", "Flapjack Cloud Dev")
}

/// Helper: extract the JSON body from the single request received by the mock.
async fn single_request_json(server: &MockServer) -> serde_json::Value {
    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1, "expected exactly 1 request to Mailpit");
    serde_json::from_slice(&requests[0].body).expect("request body should be valid JSON")
}

/// Shared assertions for every Mailpit email payload.
fn assert_common_payload(
    body: &serde_json::Value,
    expected_to: &str,
    expected_subject: &str,
    expected_tag: &str,
) {
    assert_eq!(body["From"]["Email"], "system@flapjack.foo");
    assert_eq!(body["From"]["Name"], "Flapjack Cloud Dev");
    assert_eq!(body["To"][0]["Email"], expected_to);
    assert!(body["To"].as_array().unwrap().len() == 1);
    assert_eq!(body["Subject"], expected_subject);
    assert_eq!(body["Tags"][0], expected_tag);
    assert!(body["Tags"].as_array().unwrap().len() == 1);
    assert!(body["HTML"].as_str().is_some_and(|s| !s.is_empty()));
}

async fn mount_mailpit_ok(server: &MockServer) {
    Mock::given(method("POST"))
        .and(path("/api/v1/send"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
        .mount(server)
        .await;
}

#[tokio::test]
async fn mailpit_verification_sends_correct_payload_and_tag() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_verification_email("alice@example.com", "tok-abc")
        .await
        .expect("should succeed");
    let body = single_request_json(&server).await;
    assert_common_payload(
        &body,
        "alice@example.com",
        VERIFICATION_SUBJECT,
        "verification",
    );
    let html = body["HTML"].as_str().unwrap();
    assert!(html.contains(r#"href="https://cloud.flapjack.foo/verify-email/tok-abc""#));
    assert!(!html.contains("verify-email?token="));
}

#[tokio::test]
async fn mailpit_password_reset_sends_correct_payload_and_tag() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_password_reset_email("bob@example.com", "rst-xyz")
        .await
        .expect("should succeed");
    let body = single_request_json(&server).await;
    assert_common_payload(
        &body,
        "bob@example.com",
        PASSWORD_RESET_SUBJECT,
        "password-reset",
    );
    let html = body["HTML"].as_str().unwrap();
    assert!(html.contains(r#"href="https://cloud.flapjack.foo/reset-password/rst-xyz""#));
    assert!(!html.contains("reset-password?token="));
}

#[tokio::test]
async fn mailpit_invoice_sends_correct_payload_and_tag_with_pdf() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_invoice_ready_email(
        "carol@example.com",
        "INV-42",
        "https://billing.example.com/inv/42",
        Some("https://cdn.example.com/inv-42.pdf"),
    )
    .await
    .expect("should succeed");
    let body = single_request_json(&server).await;
    assert_common_payload(&body, "carol@example.com", INVOICE_READY_SUBJECT, "invoice");
    let html = body["HTML"].as_str().unwrap();
    assert!(html.contains("INV-42"));
    assert!(html.contains("https://billing.example.com/inv/42"));
    assert!(html.contains("https://cdn.example.com/inv-42.pdf"));
    assert!(html.contains("Download PDF"));
}

#[tokio::test]
async fn mailpit_invoice_omits_pdf_link_when_none() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_invoice_ready_email(
        "dan@example.com",
        "INV-99",
        "https://b.example.com/99",
        None,
    )
    .await
    .expect("should succeed");
    let body = single_request_json(&server).await;
    assert_common_payload(&body, "dan@example.com", INVOICE_READY_SUBJECT, "invoice");
    let html = body["HTML"].as_str().unwrap();
    assert!(!html.contains("Download PDF"));
}

#[tokio::test]
async fn mailpit_quota_warning_sends_correct_payload_and_tag() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_quota_warning_email("eve@example.com", "searches", 92.5, 9250, 10000)
        .await
        .expect("should succeed");
    let body = single_request_json(&server).await;
    assert_common_payload(
        &body,
        "eve@example.com",
        QUOTA_WARNING_SUBJECT,
        "quota-warning",
    );
    let html = body["HTML"].as_str().unwrap();
    assert!(html.contains("searches"));
    assert!(html.contains("92.5%"));
    assert!(html.contains("9250"));
    assert!(html.contains("10000"));
}

#[tokio::test]
async fn mailpit_broadcast_sends_pre_wrapped_text_payload_and_tag() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    let subject = "Maintenance notice";
    let text_body = "Planned maintenance at 02:00 UTC";

    svc.send_broadcast_email("ops@example.com", subject, None, Some(text_body))
        .await
        .expect("should succeed");

    let body = single_request_json(&server).await;
    assert_common_payload(&body, "ops@example.com", subject, "broadcast");
    assert_eq!(body["HTML"], format!("<pre>{text_body}</pre>"));
}

#[tokio::test]
async fn mailpit_trims_trailing_slash_from_api_url() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let url_with_slash = format!("{}/", server.uri());
    let svc = mailpit_service(&url_with_slash);
    svc.send_verification_email("frank@example.com", "tok")
        .await
        .expect("trailing slash should not break the request");
    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1);
}

#[tokio::test]
async fn mailpit_returns_delivery_failed_on_500() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/api/v1/send"))
        .respond_with(ResponseTemplate::new(500).set_body_string("internal error"))
        .mount(&server)
        .await;
    let svc = mailpit_service(&server.uri());
    let err = svc
        .send_verification_email("user@example.com", "tok")
        .await
        .unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("500"),
        "should contain status code, got: {msg}"
    );
    assert!(
        msg.contains("internal error"),
        "should contain body, got: {msg}"
    );
}

#[tokio::test]
async fn mailpit_returns_delivery_failed_on_422() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/api/v1/send"))
        .respond_with(ResponseTemplate::new(422).set_body_string("unprocessable entity"))
        .mount(&server)
        .await;
    let svc = mailpit_service(&server.uri());
    let err = svc
        .send_password_reset_email("user@example.com", "tok")
        .await
        .unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("422"),
        "should contain status code, got: {msg}"
    );
}

#[tokio::test]
async fn mailpit_200_returns_ok() {
    let server = MockServer::start().await;
    mount_mailpit_ok(&server).await;
    let svc = mailpit_service(&server.uri());
    svc.send_verification_email("a@b.com", "t1")
        .await
        .expect("verification 200 -> Ok");
    svc.send_password_reset_email("a@b.com", "t2")
        .await
        .expect("password reset 200 -> Ok");
    svc.send_invoice_ready_email("a@b.com", "inv", "http://x", None)
        .await
        .expect("invoice 200 -> Ok");
    svc.send_quota_warning_email("a@b.com", "m", 50.0, 50, 100)
        .await
        .expect("quota warning 200 -> Ok");
}

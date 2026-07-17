use crate::services::email_suppression::EmailSuppressionStore;
use async_trait::async_trait;
use aws_sdk_sesv2::types::{Body, Content, Destination, EmailContent, Message, MessageTag};
use std::sync::{Arc, Mutex};

mod dunning;
mod mailpit;
mod render;
mod ses_config;
mod templates;

pub use dunning::{
    dunning_recovered_after_failure_email_html_with_base_url,
    dunning_recovered_after_failure_email_text_with_base_url,
    dunning_retries_exhausted_email_html_with_base_url,
    dunning_retries_exhausted_email_text_with_base_url,
    dunning_retry_scheduled_email_html_with_base_url,
    dunning_retry_scheduled_email_text_with_base_url, DUNNING_RECOVERED_AFTER_FAILURE_SUBJECT,
    DUNNING_RETRIES_EXHAUSTED_SUBJECT, DUNNING_RETRY_SCHEDULED_SUBJECT,
};
pub use mailpit::MailpitEmailService;
use render::{
    render_dunning_recovered_after_failure_email, render_dunning_retries_exhausted_email,
    render_dunning_retry_scheduled_email, render_invoice_ready_email, render_password_reset_email,
    render_quota_warning_email, render_verification_email, resolve_broadcast_render, RenderedEmail,
};
pub use ses_config::SesConfig;
pub use templates::*;

pub const DEFAULT_APP_BASE_URL: &str = "https://cloud.flapjack.foo";
pub const DEFAULT_EMAIL_FROM_NAME: &str = "Flapjack Cloud";

pub const VERIFICATION_SUBJECT: &str = "Verify your email";
const VERIFICATION_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>Verify your Flapjack Cloud account</h2>
    <p>Thanks for signing up for Flapjack Cloud. Confirm your email by clicking the link below.</p>
    <p><a href="{{VERIFY_URL}}">Verify email</a></p>
  </body>
</html>
"#;

pub const PASSWORD_RESET_SUBJECT: &str = "Reset your password";
const PASSWORD_RESET_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>Flapjack Cloud password reset</h2>
    <p>You can reset your Flapjack Cloud password by clicking the link below.</p>
    <p><a href="{{RESET_URL}}">Reset password</a></p>
  </body>
</html>
"#;

pub const INVOICE_READY_SUBJECT: &str = "Your invoice is ready";
const INVOICE_READY_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>Your Flapjack Cloud invoice is ready</h2>
    <p>Invoice <strong>{{INVOICE_ID}}</strong> for your Flapjack Cloud account is now available.</p>
    <p><a href="{{INVOICE_URL}}">View invoice</a></p>
    {{PDF_LINK}}
  </body>
</html>
"#;

pub const QUOTA_WARNING_SUBJECT: &str = "Usage warning";
const QUOTA_WARNING_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>Flapjack Cloud usage warning</h2>
    <p>Your {{METRIC}} usage on Flapjack Cloud is now at <strong>{{PERCENT}}%</strong>.</p>
    <p>Current: {{CURRENT}} / Limit: {{LIMIT}}</p>
  </body>
</html>
"#;

#[derive(Debug, thiserror::Error)]
pub enum EmailError {
    #[error("email delivery failed: {0}")]
    DeliveryFailed(String),

    #[error("invalid email request: {0}")]
    InvalidRequest(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SentEmail {
    pub to: String,
    pub subject: String,
    pub html_body: String,
    pub text_body: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BroadcastDeliveryStatus {
    Sent,
    Suppressed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DunningRetryScheduledEmailRequest<'a> {
    pub customer_id: &'a str,
    pub invoice_id: &'a str,
    pub hosted_invoice_url: Option<&'a str>,
    pub next_payment_attempt_unix_seconds: i64,
    pub attempt_count: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DunningRetriesExhaustedEmailRequest<'a> {
    pub customer_id: &'a str,
    pub invoice_id: &'a str,
    pub hosted_invoice_url: Option<&'a str>,
    pub attempt_count: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DunningRecoveredAfterFailureEmailRequest<'a> {
    pub customer_id: &'a str,
    pub invoice_id: &'a str,
    pub hosted_invoice_url: Option<&'a str>,
}

/// Async trait defining the email dispatch interface.
///
/// Provides typed methods for each transactional email (verification, password
/// reset, invoice ready, quota warning). Implementors include [`SesEmailService`]
/// for production (AWS SES) and [`NoopEmailService`] for local development and
/// testing.
#[async_trait]
pub trait EmailService: Send + Sync {
    async fn send_verification_email(&self, to: &str, verify_token: &str)
        -> Result<(), EmailError>;

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError>;

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        invoice_id: &str,
        invoice_url: &str,
        pdf_url: Option<&str>,
        dispatch_source: &str,
    ) -> Result<(), EmailError>;

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
    ) -> Result<(), EmailError>;

    async fn send_dunning_retry_scheduled_email(
        &self,
        to: &str,
        request: &DunningRetryScheduledEmailRequest<'_>,
    ) -> Result<(), EmailError>;

    async fn send_dunning_retries_exhausted_email(
        &self,
        to: &str,
        request: &DunningRetriesExhaustedEmailRequest<'_>,
    ) -> Result<(), EmailError>;

    async fn send_dunning_recovered_after_failure_email(
        &self,
        to: &str,
        request: &DunningRecoveredAfterFailureEmailRequest<'_>,
    ) -> Result<(), EmailError>;

    async fn send_broadcast_email(
        &self,
        to: &str,
        subject: &str,
        html_body: Option<&str>,
        text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError>;
}

fn validate_recipient_email(to: &str) -> Result<(), EmailError> {
    let trimmed = to.trim();
    if trimmed.is_empty() {
        return Err(EmailError::InvalidRequest(
            "recipient email must not be empty".to_string(),
        ));
    }
    if contains_header_injection_bytes(trimmed) {
        return Err(EmailError::InvalidRequest(
            "recipient email contains unsafe control characters".to_string(),
        ));
    }
    Ok(())
}

fn normalize_app_base_url(app_base_url: impl Into<String>) -> String {
    let normalized = app_base_url.into().trim().trim_end_matches('/').to_string();
    if normalized.is_empty() {
        return DEFAULT_APP_BASE_URL.to_string();
    }
    if is_safe_app_base_url(&normalized) {
        normalized
    } else {
        DEFAULT_APP_BASE_URL.to_string()
    }
}

fn normalize_from_name(from_name: impl Into<String>) -> String {
    let from_name = from_name.into().trim().to_string();
    if from_name.is_empty() {
        DEFAULT_EMAIL_FROM_NAME.to_string()
    } else {
        from_name
    }
}

fn contains_header_injection_bytes(value: &str) -> bool {
    value.chars().any(|ch| matches!(ch, '\r' | '\n' | '\0'))
}

fn url_host(url: &str) -> Option<&str> {
    let (_, remainder) = url.split_once("://")?;
    let authority = remainder.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit('@').next()?;
    if host_port.is_empty() {
        return None;
    }
    if host_port.starts_with('[') {
        let closing = host_port.find(']')?;
        return Some(&host_port[..=closing]);
    }
    Some(host_port.split(':').next().unwrap_or(host_port))
}

fn is_loopback_http_url(url: &str) -> bool {
    match url_host(url) {
        Some(host) => matches!(
            host.to_ascii_lowercase().as_str(),
            "localhost" | "127.0.0.1" | "[::1]" | "::1"
        ),
        None => false,
    }
}

fn is_safe_app_base_url(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    lower.starts_with("https://") || (lower.starts_with("http://") && is_loopback_http_url(url))
}

fn validate_sender_identity(from_name: &str, from_address: &str) -> Result<(), EmailError> {
    if contains_header_injection_bytes(from_name) || contains_header_injection_bytes(from_address) {
        return Err(EmailError::InvalidRequest(
            "sender identity contains unsafe control characters".to_string(),
        ));
    }
    if from_name.contains(['<', '>']) {
        return Err(EmailError::InvalidRequest(
            "sender display name must not contain angle brackets".to_string(),
        ));
    }
    if from_address.trim().is_empty()
        || from_address.contains(['<', '>'])
        || from_address.chars().any(|ch| ch.is_ascii_whitespace())
    {
        return Err(EmailError::InvalidRequest(
            "sender email address must be a bare email address".to_string(),
        ));
    }
    Ok(())
}

fn formatted_sender_identity(from_name: &str, from_address: &str) -> String {
    format!("{from_name} <{from_address}>")
}

pub struct MockEmailService {
    sent_emails: Arc<Mutex<Vec<SentEmail>>>,
    app_base_url: String,
}

impl MockEmailService {
    pub fn new() -> Self {
        Self::with_app_base_url(DEFAULT_APP_BASE_URL)
    }

    pub fn with_app_base_url(app_base_url: impl Into<String>) -> Self {
        Self {
            sent_emails: Arc::new(Mutex::new(Vec::new())),
            app_base_url: normalize_app_base_url(app_base_url),
        }
    }

    pub fn sent_emails(&self) -> Vec<SentEmail> {
        self.sent_emails.lock().unwrap().clone()
    }

    fn record(&self, to: &str, email: RenderedEmail) -> Result<(), EmailError> {
        validate_recipient_email(to)?;

        self.sent_emails.lock().unwrap().push(SentEmail {
            to: to.to_string(),
            subject: email.subject,
            html_body: email.html_body,
            text_body: email.text_body,
        });
        Ok(())
    }
}

impl Default for MockEmailService {
    fn default() -> Self {
        Self::new()
    }
}

pub struct NoopEmailService;

pub struct SesEmailService {
    client: aws_sdk_sesv2::Client,
    from_address: String,
    from_name: String,
    configuration_set_name: String,
    suppression_store: Arc<dyn EmailSuppressionStore>,
    app_base_url: String,
}

impl SesEmailService {
    pub fn new(
        client: aws_sdk_sesv2::Client,
        from_address: impl Into<String>,
        configuration_set_name: impl Into<String>,
        suppression_store: Arc<dyn EmailSuppressionStore>,
    ) -> Self {
        Self::with_app_base_url(
            client,
            from_address,
            DEFAULT_EMAIL_FROM_NAME,
            configuration_set_name,
            suppression_store,
            DEFAULT_APP_BASE_URL,
        )
    }

    pub fn with_app_base_url(
        client: aws_sdk_sesv2::Client,
        from_address: impl Into<String>,
        from_name: impl Into<String>,
        configuration_set_name: impl Into<String>,
        suppression_store: Arc<dyn EmailSuppressionStore>,
        app_base_url: impl Into<String>,
    ) -> Self {
        Self {
            client,
            from_address: from_address.into(),
            from_name: normalize_from_name(from_name),
            configuration_set_name: configuration_set_name.into(),
            suppression_store,
            app_base_url: normalize_app_base_url(app_base_url),
        }
    }

    /// Builds and sends a single HTML email via the AWS SES v2 API.
    ///
    /// Constructs a `SendEmailInput` with UTF-8 subject and HTML body, using
    /// the configured sender address. Validates that the recipient is non-empty
    /// before dispatching. Any `email_tags` provided are attached to the SES
    /// `EmailTags` array so downstream SES event-destination consumers (e.g. a
    /// SEND configuration-set destination shipping to CloudWatch/EventBridge)
    /// can correlate deliveries to the business identifiers they carry — most
    /// notably the fjcloud invoice ID for billing-email observability.
    async fn send_rendered_email(
        &self,
        to: &str,
        rendered_email: &RenderedEmail,
        email_tags: &[(&str, &str)],
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        validate_recipient_email(to)?;
        validate_sender_identity(&self.from_name, &self.from_address)?;

        if self
            .suppression_store
            .is_suppressed(to)
            .await
            .map_err(EmailError::DeliveryFailed)?
        {
            return Ok(BroadcastDeliveryStatus::Suppressed);
        }

        let subject_content = Content::builder()
            .data(&rendered_email.subject)
            .charset("UTF-8")
            .build()
            .map_err(|e| EmailError::InvalidRequest(format!("invalid email subject: {e}")))?;
        let html_body_content = Content::builder()
            .data(&rendered_email.html_body)
            .charset("UTF-8")
            .build()
            .map_err(|e| EmailError::InvalidRequest(format!("invalid email body: {e}")))?;
        let text_body_content = Content::builder()
            .data(&rendered_email.text_body)
            .charset("UTF-8")
            .build()
            .map_err(|e| EmailError::InvalidRequest(format!("invalid email body: {e}")))?;
        let body = Body::builder()
            .html(html_body_content)
            .text(text_body_content)
            .build();
        let message = Message::builder()
            .subject(subject_content)
            .body(body)
            .build();
        let destination = Destination::builder().to_addresses(to).build();
        let content = EmailContent::builder().simple(message).build();

        let mut request = self
            .client
            .send_email()
            .from_email_address(formatted_sender_identity(
                &self.from_name,
                &self.from_address,
            ))
            .configuration_set_name(&self.configuration_set_name)
            .destination(destination)
            .content(content);
        for (name, value) in email_tags {
            let tag = MessageTag::builder()
                .name(*name)
                .value(*value)
                .build()
                .map_err(|e| {
                    EmailError::InvalidRequest(format!("invalid SES message tag {name}: {e}"))
                })?;
            request = request.email_tags(tag);
        }
        request
            .send()
            .await
            .map_err(|e| EmailError::DeliveryFailed(e.to_string()))?;

        Ok(BroadcastDeliveryStatus::Sent)
    }
}

#[async_trait]
impl EmailService for MockEmailService {
    async fn send_verification_email(
        &self,
        to: &str,
        verify_token: &str,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_verification_email(&self.app_base_url, verify_token)?,
        )
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_password_reset_email(&self.app_base_url, reset_token)?,
        )
    }

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        invoice_id: &str,
        invoice_url: &str,
        pdf_url: Option<&str>,
        _dispatch_source: &str,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_invoice_ready_email(invoice_id, invoice_url, pdf_url)?,
        )
    }

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_quota_warning_email(metric, percent_used, current_usage, limit)?,
        )
    }

    async fn send_dunning_retry_scheduled_email(
        &self,
        to: &str,
        request: &DunningRetryScheduledEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_dunning_retry_scheduled_email(&self.app_base_url, request)?,
        )
    }

    async fn send_dunning_retries_exhausted_email(
        &self,
        to: &str,
        request: &DunningRetriesExhaustedEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_dunning_retries_exhausted_email(&self.app_base_url, request)?,
        )
    }

    async fn send_dunning_recovered_after_failure_email(
        &self,
        to: &str,
        request: &DunningRecoveredAfterFailureEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            render_dunning_recovered_after_failure_email(&self.app_base_url, request)?,
        )
    }

    async fn send_broadcast_email(
        &self,
        to: &str,
        subject: &str,
        html_body: Option<&str>,
        text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        self.record(to, resolve_broadcast_render(subject, html_body, text_body)?)?;
        Ok(BroadcastDeliveryStatus::Sent)
    }
}

#[async_trait]
impl EmailService for NoopEmailService {
    async fn send_verification_email(
        &self,
        to: &str,
        _verify_token: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        _reset_token: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        _invoice_id: &str,
        _invoice_url: &str,
        _pdf_url: Option<&str>,
        _dispatch_source: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_quota_warning_email(
        &self,
        to: &str,
        _metric: &str,
        _percent_used: f64,
        _current_usage: u64,
        _limit: u64,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_dunning_retry_scheduled_email(
        &self,
        to: &str,
        _request: &DunningRetryScheduledEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_dunning_retries_exhausted_email(
        &self,
        to: &str,
        _request: &DunningRetriesExhaustedEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_dunning_recovered_after_failure_email(
        &self,
        to: &str,
        _request: &DunningRecoveredAfterFailureEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)
    }

    async fn send_broadcast_email(
        &self,
        to: &str,
        subject: &str,
        html_body: Option<&str>,
        text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        validate_recipient_email(to)?;
        resolve_broadcast_render(subject, html_body, text_body)?;
        Ok(BroadcastDeliveryStatus::Sent)
    }
}

#[async_trait]
impl EmailService for SesEmailService {
    async fn send_verification_email(
        &self,
        to: &str,
        verify_token: &str,
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_verification_email(&self.app_base_url, verify_token)?,
            &[],
        )
        .await
        .map(|_| ())
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_password_reset_email(&self.app_base_url, reset_token)?,
            &[],
        )
        .await
        .map(|_| ())
    }

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        invoice_id: &str,
        invoice_url: &str,
        pdf_url: Option<&str>,
        dispatch_source: &str,
    ) -> Result<(), EmailError> {
        // Tagging with the fjcloud invoice_id lets a SES SEND event destination
        // (CloudWatch/EventBridge) correlate downstream delivery evidence back
        // to the invoice row we just finalized. Without this, the rehearsal's
        // invoice-email evidence gate has no queryable channel where the invoice
        // ID appears alongside the SES message_id.
        self.send_rendered_email(
            to,
            &render_invoice_ready_email(invoice_id, invoice_url, pdf_url)?,
            &[
                ("invoice_id", invoice_id),
                ("email_type", "invoice_ready"),
                ("dispatch_source", dispatch_source),
            ],
        )
        .await
        .map(|_| ())
    }

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_quota_warning_email(metric, percent_used, current_usage, limit)?,
            &[],
        )
        .await
        .map(|_| ())
    }

    async fn send_dunning_retry_scheduled_email(
        &self,
        to: &str,
        request: &DunningRetryScheduledEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_dunning_retry_scheduled_email(&self.app_base_url, request)?,
            &[
                ("invoice_id", request.invoice_id),
                ("email_type", "dunning_retry_scheduled"),
            ],
        )
        .await
        .map(|_| ())
    }

    async fn send_dunning_retries_exhausted_email(
        &self,
        to: &str,
        request: &DunningRetriesExhaustedEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_dunning_retries_exhausted_email(&self.app_base_url, request)?,
            &[
                ("invoice_id", request.invoice_id),
                ("email_type", "dunning_retries_exhausted"),
            ],
        )
        .await
        .map(|_| ())
    }

    async fn send_dunning_recovered_after_failure_email(
        &self,
        to: &str,
        request: &DunningRecoveredAfterFailureEmailRequest<'_>,
    ) -> Result<(), EmailError> {
        // See send_invoice_ready_email above: same rationale — attach the
        // fjcloud invoice_id so recovered-after-failure sends are observable in
        // a SES SEND event destination.
        self.send_rendered_email(
            to,
            &render_dunning_recovered_after_failure_email(&self.app_base_url, request)?,
            &[
                ("invoice_id", request.invoice_id),
                ("email_type", "dunning_recovered_after_failure"),
            ],
        )
        .await
        .map(|_| ())
    }

    async fn send_broadcast_email(
        &self,
        to: &str,
        subject: &str,
        html_body: Option<&str>,
        text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        let rendered = resolve_broadcast_render(subject, html_body, text_body)?;
        self.send_rendered_email(to, &rendered, &[]).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quota_warning_email_html_escapes_unknown_metric_label() {
        let html = quota_warning_email_html(r#"<img src=x onerror=alert(1)>"#, 88.0, 10, 20);

        assert!(html.contains("Your &lt;img src=x onerror=alert(1)&gt; usage"));
        assert!(!html.contains("<img src=x onerror=alert(1)>"));
    }

    #[test]
    fn normalize_app_base_url_rejects_non_loopback_http() {
        assert_eq!(
            normalize_app_base_url("http://example.com/reset"),
            DEFAULT_APP_BASE_URL
        );
        assert_eq!(
            normalize_app_base_url("http://localhost:4173"),
            "http://localhost:4173"
        );
    }

    #[test]
    fn sender_identity_and_recipient_reject_header_injection() {
        assert!(validate_sender_identity(
            "Flapjack\r\nBcc: victim@example.com",
            "noreply@example.com"
        )
        .is_err());
        assert!(validate_sender_identity(
            "Flapjack Cloud",
            "noreply@example.com\r\nCc: victim@example.com"
        )
        .is_err());
        assert!(
            validate_recipient_email("victim@example.com\r\nBcc: attacker@example.com").is_err()
        );
    }
}

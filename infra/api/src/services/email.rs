use crate::services::email_suppression::EmailSuppressionStore;
use async_trait::async_trait;
use aws_sdk_sesv2::types::{Body, Content, Destination, EmailContent, Message};
use std::sync::{Arc, Mutex};

mod mailpit;
mod render;
pub use mailpit::MailpitEmailService;
use render::{
    render_invoice_ready_email, render_password_reset_email, render_quota_warning_email,
    render_verification_email, resolve_broadcast_render, RenderedEmail,
};

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
    ) -> Result<(), EmailError>;

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
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
    if to.trim().is_empty() {
        return Err(EmailError::InvalidRequest(
            "recipient email must not be empty".to_string(),
        ));
    }
    Ok(())
}

fn normalize_app_base_url(app_base_url: impl Into<String>) -> String {
    app_base_url.into().trim_end_matches('/').to_string()
}

fn normalize_from_name(from_name: impl Into<String>) -> String {
    let from_name = from_name.into().trim().to_string();
    if from_name.is_empty() {
        DEFAULT_EMAIL_FROM_NAME.to_string()
    } else {
        from_name
    }
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
    /// before dispatching.
    async fn send_rendered_email(
        &self,
        to: &str,
        rendered_email: &RenderedEmail,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        validate_recipient_email(to)?;

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

        self.client
            .send_email()
            .from_email_address(formatted_sender_identity(
                &self.from_name,
                &self.from_address,
            ))
            .configuration_set_name(&self.configuration_set_name)
            .destination(destination)
            .content(content)
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
    ) -> Result<(), EmailError> {
        self.send_rendered_email(
            to,
            &render_invoice_ready_email(invoice_id, invoice_url, pdf_url)?,
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
        self.send_rendered_email(to, &rendered).await
    }
}

pub fn verification_email_html(verify_token: &str) -> String {
    verification_email_html_with_base_url(DEFAULT_APP_BASE_URL, verify_token)
}

pub fn verification_email_text(verify_token: &str) -> String {
    verification_email_text_with_base_url(DEFAULT_APP_BASE_URL, verify_token)
}

pub fn verification_email_html_with_base_url(app_base_url: &str, verify_token: &str) -> String {
    // The Svelte verification screen is `/verify-email/[token]`; keep email
    // links aligned with that route so customers do not land on a 404.
    let verify_url = format!(
        "{}/verify-email/{verify_token}",
        app_base_url.trim_end_matches('/')
    );
    VERIFICATION_TEMPLATE_HTML.replace("{{VERIFY_URL}}", &verify_url)
}

pub fn verification_email_text_with_base_url(app_base_url: &str, verify_token: &str) -> String {
    let verify_url = format!(
        "{}/verify-email/{verify_token}",
        app_base_url.trim_end_matches('/')
    );
    format!(
        "Verify your Flapjack Cloud account.\n\nThanks for signing up for Flapjack Cloud. Confirm your email:\n{verify_url}"
    )
}

pub fn password_reset_email_html(reset_token: &str) -> String {
    password_reset_email_html_with_base_url(DEFAULT_APP_BASE_URL, reset_token)
}

pub fn password_reset_email_text(reset_token: &str) -> String {
    password_reset_email_text_with_base_url(DEFAULT_APP_BASE_URL, reset_token)
}

pub fn password_reset_email_html_with_base_url(app_base_url: &str, reset_token: &str) -> String {
    // The Svelte reset screen is `/reset-password/[token]`; keep auth email
    // links using the same path contract the page server action reads.
    let reset_url = format!(
        "{}/reset-password/{reset_token}",
        app_base_url.trim_end_matches('/')
    );
    PASSWORD_RESET_TEMPLATE_HTML.replace("{{RESET_URL}}", &reset_url)
}

pub fn password_reset_email_text_with_base_url(app_base_url: &str, reset_token: &str) -> String {
    let reset_url = format!(
        "{}/reset-password/{reset_token}",
        app_base_url.trim_end_matches('/')
    );
    format!(
        "Flapjack Cloud password reset.\n\nYou can reset your Flapjack Cloud password here:\n{reset_url}"
    )
}

pub fn invoice_ready_email_html(
    invoice_id: &str,
    invoice_url: &str,
    pdf_url: Option<&str>,
) -> String {
    let pdf_link = match pdf_url {
        Some(url) => format!(r#"<p><a href="{url}">Download PDF</a></p>"#),
        None => String::new(),
    };
    INVOICE_READY_TEMPLATE_HTML
        .replace("{{INVOICE_ID}}", invoice_id)
        .replace("{{INVOICE_URL}}", invoice_url)
        .replace("{{PDF_LINK}}", &pdf_link)
}

pub fn invoice_ready_email_text(
    invoice_id: &str,
    invoice_url: &str,
    pdf_url: Option<&str>,
) -> String {
    let pdf_line = match pdf_url {
        Some(url) => format!("\nDownload PDF: {url}"),
        None => String::new(),
    };
    format!(
        "Your Flapjack Cloud invoice is ready.\n\nInvoice: {invoice_id}\nView invoice: {invoice_url}{pdf_line}"
    )
}

pub fn quota_warning_email_html(
    metric: &str,
    percent_used: f64,
    current_usage: u64,
    limit: u64,
) -> String {
    QUOTA_WARNING_TEMPLATE_HTML
        .replace("{{METRIC}}", metric)
        .replace("{{PERCENT}}", &format!("{percent_used:.1}"))
        .replace("{{CURRENT}}", &current_usage.to_string())
        .replace("{{LIMIT}}", &limit.to_string())
}

pub fn quota_warning_email_text(
    metric: &str,
    percent_used: f64,
    current_usage: u64,
    limit: u64,
) -> String {
    format!(
        "Flapjack Cloud usage warning.\n\nMetric: {metric}\nUsage: {percent_used:.1}%\nCurrent: {current_usage}\nLimit: {limit}"
    )
}

// ---------------------------------------------------------------------------
// SES configuration
// ---------------------------------------------------------------------------

/// Configuration required to wire `SesEmailService` in production.
/// Loaded from environment variables; startup fails fast if missing or invalid.
#[derive(Debug, Clone)]
pub struct SesConfig {
    pub from_address: String,
    pub from_name: String,
    pub region: String,
    pub configuration_set: String,
}

impl SesConfig {
    pub fn from_name_from_reader<F>(read: F) -> String
    where
        F: Fn(&str) -> Option<String>,
    {
        read("EMAIL_FROM_NAME")
            .map(normalize_from_name)
            .unwrap_or_else(|| DEFAULT_EMAIL_FROM_NAME.to_string())
    }

    pub fn from_name_from_env() -> String {
        Self::from_name_from_reader(|k| std::env::var(k).ok())
    }

    /// Testable constructor that reads values via a closure.
    pub fn from_reader<F>(read: F) -> Result<Self, String>
    where
        F: Fn(&str) -> Option<String>,
    {
        let from_address = read("SES_FROM_ADDRESS")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_FROM_ADDRESS is required but missing or empty")?;

        let from_name = Self::from_name_from_reader(&read);

        let region = read("SES_REGION")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_REGION is required but missing or empty")?;

        let configuration_set = read("SES_CONFIGURATION_SET")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_CONFIGURATION_SET is required but missing or empty")?;

        Ok(Self {
            from_address,
            from_name,
            region,
            configuration_set,
        })
    }

    /// Load from real environment variables.
    pub fn from_env() -> Result<Self, String> {
        Self::from_reader(|k| std::env::var(k).ok())
    }
}

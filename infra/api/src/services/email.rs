use async_trait::async_trait;
use aws_sdk_sesv2::types::{Body, Content, Destination, EmailContent, Message};
use std::sync::{Arc, Mutex};

pub const DEFAULT_APP_BASE_URL: &str = "https://cloud.flapjack.foo";

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
    pub body: String,
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

    fn record(&self, to: &str, subject: &str, body: String) -> Result<(), EmailError> {
        validate_recipient_email(to)?;

        self.sent_emails.lock().unwrap().push(SentEmail {
            to: to.to_string(),
            subject: subject.to_string(),
            body,
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
    app_base_url: String,
}

impl SesEmailService {
    pub fn new(client: aws_sdk_sesv2::Client, from_address: impl Into<String>) -> Self {
        Self::with_app_base_url(client, from_address, DEFAULT_APP_BASE_URL)
    }

    pub fn with_app_base_url(
        client: aws_sdk_sesv2::Client,
        from_address: impl Into<String>,
        app_base_url: impl Into<String>,
    ) -> Self {
        Self {
            client,
            from_address: from_address.into(),
            app_base_url: normalize_app_base_url(app_base_url),
        }
    }

    /// Builds and sends a single HTML email via the AWS SES v2 API.
    ///
    /// Constructs a `SendEmailInput` with UTF-8 subject and HTML body, using
    /// the configured sender address. Validates that the recipient is non-empty
    /// before dispatching.
    async fn send_html_email(
        &self,
        to: &str,
        subject: &str,
        html_body: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)?;

        let subject_content = Content::builder()
            .data(subject)
            .charset("UTF-8")
            .build()
            .map_err(|e| EmailError::InvalidRequest(format!("invalid email subject: {e}")))?;
        let body_content = Content::builder()
            .data(html_body)
            .charset("UTF-8")
            .build()
            .map_err(|e| EmailError::InvalidRequest(format!("invalid email body: {e}")))?;
        let body = Body::builder().html(body_content).build();
        let message = Message::builder()
            .subject(subject_content)
            .body(body)
            .build();
        let destination = Destination::builder().to_addresses(to).build();
        let content = EmailContent::builder().simple(message).build();

        self.client
            .send_email()
            .from_email_address(&self.from_address)
            .destination(destination)
            .content(content)
            .send()
            .await
            .map_err(|e| EmailError::DeliveryFailed(e.to_string()))?;

        Ok(())
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
            VERIFICATION_SUBJECT,
            verification_email_html_with_base_url(&self.app_base_url, verify_token),
        )
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError> {
        self.record(
            to,
            PASSWORD_RESET_SUBJECT,
            password_reset_email_html_with_base_url(&self.app_base_url, reset_token),
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
            INVOICE_READY_SUBJECT,
            invoice_ready_email_html(invoice_id, invoice_url, pdf_url),
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
            QUOTA_WARNING_SUBJECT,
            quota_warning_email_html(metric, percent_used, current_usage, limit),
        )
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
}

#[async_trait]
impl EmailService for SesEmailService {
    async fn send_verification_email(
        &self,
        to: &str,
        verify_token: &str,
    ) -> Result<(), EmailError> {
        self.send_html_email(
            to,
            VERIFICATION_SUBJECT,
            &verification_email_html_with_base_url(&self.app_base_url, verify_token),
        )
        .await
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError> {
        self.send_html_email(
            to,
            PASSWORD_RESET_SUBJECT,
            &password_reset_email_html_with_base_url(&self.app_base_url, reset_token),
        )
        .await
    }

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        invoice_id: &str,
        invoice_url: &str,
        pdf_url: Option<&str>,
    ) -> Result<(), EmailError> {
        self.send_html_email(
            to,
            INVOICE_READY_SUBJECT,
            &invoice_ready_email_html(invoice_id, invoice_url, pdf_url),
        )
        .await
    }

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
    ) -> Result<(), EmailError> {
        self.send_html_email(
            to,
            QUOTA_WARNING_SUBJECT,
            &quota_warning_email_html(metric, percent_used, current_usage, limit),
        )
        .await
    }
}

pub fn verification_email_html(verify_token: &str) -> String {
    verification_email_html_with_base_url(DEFAULT_APP_BASE_URL, verify_token)
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

pub fn password_reset_email_html(reset_token: &str) -> String {
    password_reset_email_html_with_base_url(DEFAULT_APP_BASE_URL, reset_token)
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

// ---------------------------------------------------------------------------
// MailpitEmailService — local dev email via Mailpit HTTP JSON API
// ---------------------------------------------------------------------------

/// Sends real emails to a local Mailpit instance via its HTTP JSON API
/// (`POST /api/v1/send`). Used in local dev when `MAILPIT_API_URL` is set.
/// Emails are caught by Mailpit and visible in its web UI at the configured
/// port (default 8025). No SMTP, no lettre — just reqwest POST with JSON.
/// Zero new dependencies (reqwest is already in workspace).
pub struct MailpitEmailService {
    /// Base URL of the Mailpit HTTP API (e.g., "http://localhost:8025").
    api_url: String,
    /// Sender email address (e.g., "system@flapjack.foo").
    from_email: String,
    /// Sender display name (e.g., "Flapjack Cloud Local Dev").
    from_name: String,
    /// Web console base URL used in auth email links.
    app_base_url: String,
    /// HTTP client for sending requests to Mailpit.
    client: reqwest::Client,
}

impl MailpitEmailService {
    pub fn new(
        api_url: impl Into<String>,
        from_email: impl Into<String>,
        from_name: impl Into<String>,
    ) -> Self {
        Self::with_app_base_url(api_url, from_email, from_name, DEFAULT_APP_BASE_URL)
    }

    pub fn with_app_base_url(
        api_url: impl Into<String>,
        from_email: impl Into<String>,
        from_name: impl Into<String>,
        app_base_url: impl Into<String>,
    ) -> Self {
        Self {
            api_url: api_url.into(),
            from_email: from_email.into(),
            from_name: from_name.into(),
            app_base_url: normalize_app_base_url(app_base_url),
            client: reqwest::Client::new(),
        }
    }

    /// Build the Mailpit JSON payload and POST it to /api/v1/send.
    /// The `tags` field lets you filter by email type in the Mailpit UI.
    async fn send_mailpit_email(
        &self,
        to: &str,
        subject: &str,
        html_body: &str,
        tag: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)?;

        // Mailpit POST /api/v1/send JSON format.
        // See: https://mailpit.axllent.com/docs/api-v1/view.html#post-/api/v1/send
        let payload = serde_json::json!({
            "From": { "Email": self.from_email, "Name": self.from_name },
            "To": [{ "Email": to }],
            "Subject": subject,
            "HTML": html_body,
            "Tags": [tag]
        });

        let url = format!("{}/api/v1/send", self.api_url.trim_end_matches('/'));
        let resp = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .json(&payload)
            .send()
            .await
            .map_err(|e| EmailError::DeliveryFailed(format!("Mailpit request failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(EmailError::DeliveryFailed(format!(
                "Mailpit returned HTTP {status}: {body}"
            )));
        }

        tracing::debug!(to, subject, tag, "Email sent via Mailpit");
        Ok(())
    }
}

#[async_trait]
impl EmailService for MailpitEmailService {
    async fn send_verification_email(
        &self,
        to: &str,
        verify_token: &str,
    ) -> Result<(), EmailError> {
        self.send_mailpit_email(
            to,
            VERIFICATION_SUBJECT,
            &verification_email_html_with_base_url(&self.app_base_url, verify_token),
            "verification",
        )
        .await
    }

    async fn send_password_reset_email(
        &self,
        to: &str,
        reset_token: &str,
    ) -> Result<(), EmailError> {
        self.send_mailpit_email(
            to,
            PASSWORD_RESET_SUBJECT,
            &password_reset_email_html_with_base_url(&self.app_base_url, reset_token),
            "password-reset",
        )
        .await
    }

    async fn send_invoice_ready_email(
        &self,
        to: &str,
        invoice_id: &str,
        invoice_url: &str,
        pdf_url: Option<&str>,
    ) -> Result<(), EmailError> {
        self.send_mailpit_email(
            to,
            INVOICE_READY_SUBJECT,
            &invoice_ready_email_html(invoice_id, invoice_url, pdf_url),
            "invoice",
        )
        .await
    }

    async fn send_quota_warning_email(
        &self,
        to: &str,
        metric: &str,
        percent_used: f64,
        current_usage: u64,
        limit: u64,
    ) -> Result<(), EmailError> {
        self.send_mailpit_email(
            to,
            QUOTA_WARNING_SUBJECT,
            &quota_warning_email_html(metric, percent_used, current_usage, limit),
            "quota-warning",
        )
        .await
    }
}

// Tests moved to infra/api/tests/email_service_test.rs to keep this file
// under the 800-line hard limit. Template helpers and subject constants are
// pub(crate) so external tests can verify rendered HTML.

// ---------------------------------------------------------------------------
// SES configuration
// ---------------------------------------------------------------------------

/// Configuration required to wire `SesEmailService` in production.
/// Loaded from environment variables; startup fails fast if missing or invalid.
#[derive(Debug, Clone)]
pub struct SesConfig {
    pub from_address: String,
    pub region: String,
}

impl SesConfig {
    /// Testable constructor that reads values via a closure.
    pub fn from_reader<F>(read: F) -> Result<Self, String>
    where
        F: Fn(&str) -> Option<String>,
    {
        let from_address = read("SES_FROM_ADDRESS")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_FROM_ADDRESS is required but missing or empty")?;

        let region = read("SES_REGION")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .ok_or("SES_REGION is required but missing or empty")?;

        Ok(Self {
            from_address,
            region,
        })
    }

    /// Load from real environment variables.
    pub fn from_env() -> Result<Self, String> {
        Self::from_reader(|k| std::env::var(k).ok())
    }
}

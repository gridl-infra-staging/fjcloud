use super::render::{
    render_invoice_ready_email, render_password_reset_email, render_quota_warning_email,
    render_verification_email, resolve_broadcast_render, RenderedEmail,
};
use super::{
    normalize_app_base_url, normalize_from_name, validate_recipient_email, BroadcastDeliveryStatus,
    EmailError, EmailService, DEFAULT_APP_BASE_URL,
};
use async_trait::async_trait;

/// Sends real emails to a local Mailpit instance via its HTTP JSON API
/// (`POST /api/v1/send`). Used in local dev when `MAILPIT_API_URL` is set.
/// Emails are caught by Mailpit and visible in its web UI at the configured
/// port (default 8025). No SMTP, no lettre - just reqwest POST with JSON.
pub struct MailpitEmailService {
    api_url: String,
    from_email: String,
    from_name: String,
    app_base_url: String,
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
            from_name: normalize_from_name(from_name),
            app_base_url: normalize_app_base_url(app_base_url),
            client: reqwest::Client::new(),
        }
    }

    async fn send_mailpit_email(
        &self,
        to: &str,
        rendered_email: &RenderedEmail,
        tag: &str,
    ) -> Result<(), EmailError> {
        validate_recipient_email(to)?;

        let payload = serde_json::json!({
            "From": { "Email": self.from_email, "Name": self.from_name },
            "To": [{ "Email": to }],
            "Subject": rendered_email.subject,
            "HTML": rendered_email.html_body,
            "Text": rendered_email.text_body,
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

        tracing::debug!(
            to,
            subject = rendered_email.subject,
            tag,
            "Email sent via Mailpit"
        );
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
            &render_verification_email(&self.app_base_url, verify_token)?,
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
            &render_password_reset_email(&self.app_base_url, reset_token)?,
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
            &render_invoice_ready_email(invoice_id, invoice_url, pdf_url)?,
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
            &render_quota_warning_email(metric, percent_used, current_usage, limit)?,
            "quota-warning",
        )
        .await
    }

    async fn send_broadcast_email(
        &self,
        to: &str,
        subject: &str,
        html_body: Option<&str>,
        text_body: Option<&str>,
    ) -> Result<BroadcastDeliveryStatus, EmailError> {
        let rendered = resolve_broadcast_render(subject, html_body, text_body)?;
        self.send_mailpit_email(to, &rendered, "broadcast").await?;
        Ok(BroadcastDeliveryStatus::Sent)
    }
}

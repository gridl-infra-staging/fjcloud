use super::{
    invoice_ready_email_html, invoice_ready_email_text, password_reset_email_html_with_base_url,
    password_reset_email_text_with_base_url, quota_warning_email_html, quota_warning_email_text,
    verification_email_html_with_base_url, verification_email_text_with_base_url, EmailError,
    INVOICE_READY_SUBJECT, PASSWORD_RESET_SUBJECT, QUOTA_WARNING_SUBJECT, VERIFICATION_SUBJECT,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RenderedEmail {
    pub(super) subject: String,
    pub(super) html_body: String,
    pub(super) text_body: String,
}

impl RenderedEmail {
    fn new(subject: &str, html_body: String, text_body: String) -> Self {
        Self {
            subject: subject.to_string(),
            html_body,
            text_body,
        }
    }
}

pub(super) fn resolve_broadcast_render(
    subject: &str,
    html_body: Option<&str>,
    text_body: Option<&str>,
) -> Result<RenderedEmail, EmailError> {
    match (html_body, text_body) {
        (Some(html), Some(text)) if !html.trim().is_empty() && !text.trim().is_empty() => Ok(
            RenderedEmail::new(subject, html.to_string(), text.to_string()),
        ),
        (Some(html), _) if !html.trim().is_empty() => {
            Ok(RenderedEmail::new(subject, html.to_string(), String::new()))
        }
        (_, Some(text)) if !text.trim().is_empty() => Ok(RenderedEmail::new(
            subject,
            format!("<pre>{}</pre>", escape_html_text(text)),
            text.to_string(),
        )),
        (None, None) => Err(EmailError::InvalidRequest(
            "broadcast email requires html_body or text_body".to_string(),
        )),
        _ => Err(EmailError::InvalidRequest(
            "broadcast email requires html_body or text_body".to_string(),
        )),
    }
}

fn escape_html_text(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

pub(super) fn render_verification_email(
    app_base_url: &str,
    verify_token: &str,
) -> Result<RenderedEmail, EmailError> {
    render_transactional_email(
        VERIFICATION_SUBJECT,
        "verification email",
        verification_email_html_with_base_url(app_base_url, verify_token),
        verification_email_text_with_base_url(app_base_url, verify_token),
    )
}

pub(super) fn render_password_reset_email(
    app_base_url: &str,
    reset_token: &str,
) -> Result<RenderedEmail, EmailError> {
    render_transactional_email(
        PASSWORD_RESET_SUBJECT,
        "password reset email",
        password_reset_email_html_with_base_url(app_base_url, reset_token),
        password_reset_email_text_with_base_url(app_base_url, reset_token),
    )
}

pub(super) fn render_invoice_ready_email(
    invoice_id: &str,
    invoice_url: &str,
    pdf_url: Option<&str>,
) -> Result<RenderedEmail, EmailError> {
    render_transactional_email(
        INVOICE_READY_SUBJECT,
        "invoice ready email",
        invoice_ready_email_html(invoice_id, invoice_url, pdf_url),
        invoice_ready_email_text(invoice_id, invoice_url, pdf_url),
    )
}

pub(super) fn render_quota_warning_email(
    metric: &str,
    percent_used: f64,
    current_usage: u64,
    limit: u64,
) -> Result<RenderedEmail, EmailError> {
    render_transactional_email(
        QUOTA_WARNING_SUBJECT,
        "quota warning email",
        quota_warning_email_html(metric, percent_used, current_usage, limit),
        quota_warning_email_text(metric, percent_used, current_usage, limit),
    )
}

fn render_transactional_email(
    subject: &str,
    label: &str,
    html_body: String,
    text_body: String,
) -> Result<RenderedEmail, EmailError> {
    Ok(RenderedEmail::new(
        subject,
        require_non_empty_html(label, html_body)?,
        require_non_empty_text(label, text_body)?,
    ))
}

fn require_non_empty_html(label: &str, html_body: String) -> Result<String, EmailError> {
    if html_body.trim().is_empty() {
        return Err(EmailError::InvalidRequest(format!(
            "{label} HTML body must not be empty"
        )));
    }
    Ok(html_body)
}

fn require_non_empty_text(label: &str, text_body: String) -> Result<String, EmailError> {
    if text_body.trim().is_empty() {
        return Err(EmailError::InvalidRequest(format!(
            "{label} text body must not be empty"
        )));
    }
    Ok(text_body)
}

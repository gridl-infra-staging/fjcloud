use super::{
    DunningRecoveredAfterFailureEmailRequest, DunningRetriesExhaustedEmailRequest,
    DunningRetryScheduledEmailRequest, EmailError,
};
use chrono::{TimeZone, Utc};

pub const DUNNING_RETRY_SCHEDULED_SUBJECT: &str = "Payment retry scheduled";
const DUNNING_RETRY_SCHEDULED_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>We couldn't process your payment</h2>
    <p>We'll automatically retry your payment on <strong>{{NEXT_PAYMENT_ATTEMPT}}</strong>.</p>
    <p>Retry status: {{ATTEMPT_COUNT}}</p>
    <p><a href="{{INVOICE_URL}}">Review and update your payment details</a></p>
  </body>
</html>
"#;

pub const DUNNING_RETRIES_EXHAUSTED_SUBJECT: &str = "Payment retries exhausted";
const DUNNING_RETRIES_EXHAUSTED_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>We still couldn't process your payment</h2>
    <p>No more automatic retries are scheduled.</p>
    <p>Retry status: {{ATTEMPT_COUNT}}</p>
    <p>Access status: your account may be temporarily limited until payment is received.</p>
    <p><a href="{{INVOICE_URL}}">Review and update your payment details</a></p>
  </body>
</html>
"#;

pub const DUNNING_RECOVERED_AFTER_FAILURE_SUBJECT: &str = "Payment recovered";
const DUNNING_RECOVERED_AFTER_FAILURE_TEMPLATE_HTML: &str = r#"
<html>
  <body>
    <h2>Your payment is now successful</h2>
    <p>Your account access remains active.</p>
    <p><a href="{{INVOICE_URL}}">View your invoice details</a></p>
  </body>
</html>
"#;

fn resolve_dunning_invoice_url(
    app_base_url: &str,
    invoice_id: &str,
    hosted_invoice_url: Option<&str>,
) -> String {
    hosted_invoice_url.map_or_else(
        || {
            format!(
                "{}/console/billing/invoices/{invoice_id}",
                app_base_url.trim_end_matches('/')
            )
        },
        str::to_string,
    )
}

fn format_unix_seconds_utc(unix_seconds: i64) -> Result<String, EmailError> {
    let timestamp = Utc.timestamp_opt(unix_seconds, 0).single().ok_or_else(|| {
        EmailError::InvalidRequest(format!(
            "invalid unix timestamp for dunning email: {unix_seconds}"
        ))
    })?;
    Ok(timestamp.format("%Y-%m-%d %H:%M:%S UTC").to_string())
}

fn format_dunning_attempt_count(attempt_count: Option<u32>) -> String {
    attempt_count
        .map(|attempt| format!("attempt {attempt}"))
        .unwrap_or_else(|| "attempt unknown".to_string())
}

pub fn dunning_retry_scheduled_email_html_with_base_url(
    app_base_url: &str,
    request: &DunningRetryScheduledEmailRequest<'_>,
) -> Result<String, EmailError> {
    let next_payment_attempt = format_unix_seconds_utc(request.next_payment_attempt_unix_seconds)?;
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    Ok(DUNNING_RETRY_SCHEDULED_TEMPLATE_HTML
        .replace("{{NEXT_PAYMENT_ATTEMPT}}", &next_payment_attempt)
        .replace(
            "{{ATTEMPT_COUNT}}",
            &format_dunning_attempt_count(request.attempt_count),
        )
        .replace("{{INVOICE_URL}}", &invoice_url))
}

pub fn dunning_retry_scheduled_email_text_with_base_url(
    app_base_url: &str,
    request: &DunningRetryScheduledEmailRequest<'_>,
) -> Result<String, EmailError> {
    let next_payment_attempt = format_unix_seconds_utc(request.next_payment_attempt_unix_seconds)?;
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    Ok(format!(
        "We couldn't process your payment.\n\nWe'll automatically retry your payment on {}.\nRetry status: {}\nReview and update your payment details: {}",
        next_payment_attempt,
        format_dunning_attempt_count(request.attempt_count),
        invoice_url,
    ))
}

pub fn dunning_retries_exhausted_email_html_with_base_url(
    app_base_url: &str,
    request: &DunningRetriesExhaustedEmailRequest<'_>,
) -> String {
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    DUNNING_RETRIES_EXHAUSTED_TEMPLATE_HTML
        .replace(
            "{{ATTEMPT_COUNT}}",
            &format_dunning_attempt_count(request.attempt_count),
        )
        .replace("{{INVOICE_URL}}", &invoice_url)
}

pub fn dunning_retries_exhausted_email_text_with_base_url(
    app_base_url: &str,
    request: &DunningRetriesExhaustedEmailRequest<'_>,
) -> String {
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    format!(
        "We still couldn't process your payment.\n\nNo more automatic retries are scheduled.\nRetry status: {}\nAccess status: your account may be temporarily limited until payment is received.\nReview and update your payment details: {}",
        format_dunning_attempt_count(request.attempt_count),
        invoice_url,
    )
}

pub fn dunning_recovered_after_failure_email_html_with_base_url(
    app_base_url: &str,
    request: &DunningRecoveredAfterFailureEmailRequest<'_>,
) -> String {
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    DUNNING_RECOVERED_AFTER_FAILURE_TEMPLATE_HTML.replace("{{INVOICE_URL}}", &invoice_url)
}

pub fn dunning_recovered_after_failure_email_text_with_base_url(
    app_base_url: &str,
    request: &DunningRecoveredAfterFailureEmailRequest<'_>,
) -> String {
    let invoice_url =
        resolve_dunning_invoice_url(app_base_url, request.invoice_id, request.hosted_invoice_url);
    format!(
        "Your payment is now successful.\n\nYour account access remains active.\nView your invoice details: {}",
        invoice_url,
    )
}

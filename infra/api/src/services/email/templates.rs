use super::{
    normalize_app_base_url, DEFAULT_APP_BASE_URL, INVOICE_READY_TEMPLATE_HTML,
    PASSWORD_RESET_TEMPLATE_HTML, QUOTA_WARNING_TEMPLATE_HTML, VERIFICATION_TEMPLATE_HTML,
};

pub(super) fn escape_html(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
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

pub(super) fn safe_email_href(url: &str) -> String {
    let trimmed = url.trim();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("https://") || lower.starts_with("http://") {
        escape_html(trimmed)
    } else {
        "#".to_string()
    }
}

pub fn verification_email_html(verify_token: &str) -> String {
    verification_email_html_with_base_url(DEFAULT_APP_BASE_URL, verify_token)
}

pub fn verification_email_text(verify_token: &str) -> String {
    verification_email_text_with_base_url(DEFAULT_APP_BASE_URL, verify_token)
}

pub fn verification_email_html_with_base_url(app_base_url: &str, verify_token: &str) -> String {
    let app_base_url = normalize_app_base_url(app_base_url);
    // The Svelte verification screen is `/verify-email/[token]`; keep email
    // links aligned with that route so customers do not land on a 404.
    let verify_url = format!("{}/verify-email/{verify_token}", app_base_url);
    VERIFICATION_TEMPLATE_HTML.replace("{{VERIFY_URL}}", &safe_email_href(&verify_url))
}

pub fn verification_email_text_with_base_url(app_base_url: &str, verify_token: &str) -> String {
    let app_base_url = normalize_app_base_url(app_base_url);
    let verify_url = format!("{}/verify-email/{verify_token}", app_base_url);
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
    let app_base_url = normalize_app_base_url(app_base_url);
    // The Svelte reset screen is `/reset-password/[token]`; keep auth email
    // links using the same path contract the page server action reads.
    let reset_url = format!("{}/reset-password/{reset_token}", app_base_url);
    PASSWORD_RESET_TEMPLATE_HTML.replace("{{RESET_URL}}", &safe_email_href(&reset_url))
}

pub fn password_reset_email_text_with_base_url(app_base_url: &str, reset_token: &str) -> String {
    let app_base_url = normalize_app_base_url(app_base_url);
    let reset_url = format!("{}/reset-password/{reset_token}", app_base_url);
    format!(
        "Flapjack Cloud password reset.\n\nYou can reset your Flapjack Cloud password here:\n{reset_url}"
    )
}

/// Render the invoice-ready notification HTML with escaped customer-facing
/// values; unsafe (non-http/https) URLs collapse to `#` rather than passing
/// through.
pub fn invoice_ready_email_html(
    invoice_id: &str,
    invoice_url: &str,
    pdf_url: Option<&str>,
) -> String {
    let pdf_link = match pdf_url {
        Some(url) => format!(
            r#"<p><a href="{}">Download PDF</a></p>"#,
            safe_email_href(url)
        ),
        None => String::new(),
    };
    INVOICE_READY_TEMPLATE_HTML
        .replace("{{INVOICE_ID}}", &escape_html(invoice_id))
        .replace("{{INVOICE_URL}}", &safe_email_href(invoice_url))
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
    let display = format_quota_warning_metric(metric, current_usage, limit);
    QUOTA_WARNING_TEMPLATE_HTML
        .replace("{{METRIC}}", &escape_html(&display.metric_label))
        .replace("{{PERCENT}}", &format!("{percent_used:.1}"))
        .replace("{{CURRENT}}", &escape_html(&display.current_value))
        .replace("{{LIMIT}}", &escape_html(&display.limit_value))
}

pub fn quota_warning_email_text(
    metric: &str,
    percent_used: f64,
    current_usage: u64,
    limit: u64,
) -> String {
    let display = format_quota_warning_metric(metric, current_usage, limit);
    format!(
        "Flapjack Cloud usage warning.\n\nMetric: {metric}\nUsage: {percent_used:.1}%\nCurrent: {current}\nLimit: {limit}",
        metric = display.metric_label,
        current = display.current_value,
        limit = display.limit_value,
    )
}

struct QuotaWarningMetricDisplay {
    metric_label: String,
    current_value: String,
    limit_value: String,
}

/// Map a raw quota metric key to its customer-facing label and formatted
/// current/limit values (storage renders as MiB; unknown keys pass through).
fn format_quota_warning_metric(
    metric: &str,
    current_usage: u64,
    limit: u64,
) -> QuotaWarningMetricDisplay {
    match metric {
        "monthly_searches" => QuotaWarningMetricDisplay {
            metric_label: "monthly searches".to_string(),
            current_value: current_usage.to_string(),
            limit_value: limit.to_string(),
        },
        "records" => QuotaWarningMetricDisplay {
            metric_label: "records".to_string(),
            current_value: current_usage.to_string(),
            limit_value: limit.to_string(),
        },
        "storage_mb" => QuotaWarningMetricDisplay {
            metric_label: "storage".to_string(),
            current_value: format_storage_mib(current_usage),
            limit_value: format_storage_mib(limit),
        },
        _ => QuotaWarningMetricDisplay {
            metric_label: metric.to_string(),
            current_value: current_usage.to_string(),
            limit_value: limit.to_string(),
        },
    }
}

fn format_storage_mib(value: u64) -> String {
    format!("{value} MiB")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verification_email_html_escapes_href_attribute() {
        let html = verification_email_html_with_base_url(
            "https://cloud.flapjack.foo",
            r#"abc"><script>alert(1)</script>"#,
        );

        assert!(html.contains(
            r#"href="https://cloud.flapjack.foo/verify-email/abc&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;""#
        ));
        assert!(!html.contains(r#"<script>alert(1)</script>"#));
    }

    #[test]
    fn invoice_ready_email_html_escapes_text_and_rejects_script_hrefs() {
        let html = invoice_ready_email_html(
            r#"in_1"><img src=x onerror=alert(1)>"#,
            r#"javascript:alert(1)"#,
            Some(r#"https://billing.stripe.com/invoice?x="><script>alert(2)</script>"#),
        );

        assert!(html
            .contains("Invoice <strong>in_1&quot;&gt;&lt;img src=x onerror=alert(1)&gt;</strong>"));
        assert!(html.contains(r##"<a href="#">View invoice</a>"##));
        assert!(html.contains(
            r#"<a href="https://billing.stripe.com/invoice?x=&quot;&gt;&lt;script&gt;alert(2)&lt;/script&gt;">Download PDF</a>"#
        ));
        assert!(!html.contains(r#"<script>alert(2)</script>"#));
        assert!(!html.contains("javascript:alert(1)"));
    }

    #[test]
    fn quota_warning_email_html_escapes_unknown_metric_label() {
        let html = quota_warning_email_html(r#"<img src=x onerror=alert(1)>"#, 88.0, 10, 20);

        assert!(html.contains("Your &lt;img src=x onerror=alert(1)&gt; usage"));
        assert!(!html.contains("<img src=x onerror=alert(1)>"));
    }

    #[test]
    fn password_reset_text_falls_back_to_https_default_for_unsafe_base_url() {
        let text = password_reset_email_text_with_base_url("http://example.com", "reset-token");

        assert!(text.contains("https://cloud.flapjack.foo/reset-password/reset-token"));
        assert!(!text.contains("http://example.com/reset-password/reset-token"));
    }
}

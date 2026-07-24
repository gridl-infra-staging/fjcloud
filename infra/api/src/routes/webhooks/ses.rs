use std::collections::HashMap;

use axum::http::StatusCode;
use base64::Engine as _;
use openssl::hash::MessageDigest;
use openssl::sign::Verifier;
use openssl::x509::X509;
use serde::Deserialize;

use crate::errors::ApiError;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::audit_log::{
    write_audit_log, ACTION_SES_COMPLAINT_SUPPRESSED, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
    ADMIN_SENTINEL_ACTOR_ID,
};
use crate::services::email_suppression::{
    normalize_recipient_email, EmailSuppressionStore, PgEmailSuppressionStore,
};
use crate::state::AppState;

const SNS_NOTIFICATION: &str = "Notification";
const SNS_SUBSCRIPTION_CONFIRMATION: &str = "SubscriptionConfirmation";
const SNS_UNSUBSCRIBE_CONFIRMATION: &str = "UnsubscribeConfirmation";
const SNS_SUPPRESSION_SOURCE: &str = "ses_sns_webhook";
const TRUSTED_SNS_ACCOUNT_ID: &str = "213880904778";
const TRUSTED_SES_FEEDBACK_TOPIC_PREFIX: &str = "fjcloud-ses-feedback-";

pub(super) async fn process_ses_sns_request(
    state: &AppState,
    body: &str,
) -> Result<StatusCode, ApiError> {
    let envelope = parse_sns_envelope(body)?;
    let sns_type = parse_sns_type(&envelope.sns_type)?;
    validate_sns_topic_arn(&envelope.topic_arn)?;
    validate_sns_url(&envelope.signing_cert_url, "SigningCertURL")?;
    if let Some(subscribe_url) = envelope.subscribe_url.as_deref() {
        validate_sns_url(subscribe_url, "SubscribeURL")?;
    }
    verify_sns_signature(state, &envelope, sns_type).await?;
    match sns_type {
        SnsType::SubscriptionConfirmation => confirm_subscription(state, &envelope).await?,
        SnsType::Notification => handle_ses_notification(state, &envelope).await?,
        SnsType::UnsubscribeConfirmation => {}
    }
    Ok(StatusCode::OK)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SnsType {
    Notification,
    SubscriptionConfirmation,
    UnsubscribeConfirmation,
}

#[derive(Debug, Deserialize)]
struct SnsEnvelope {
    #[serde(rename = "Type")]
    sns_type: String,
    #[serde(rename = "MessageId")]
    message_id: String,
    #[serde(rename = "TopicArn")]
    topic_arn: String,
    #[serde(rename = "Message")]
    message: String,
    #[serde(rename = "Timestamp")]
    timestamp: String,
    #[serde(rename = "SignatureVersion")]
    signature_version: String,
    #[serde(rename = "Signature")]
    signature: String,
    #[serde(rename = "SigningCertURL")]
    signing_cert_url: String,
    #[serde(rename = "Subject")]
    subject: Option<String>,
    #[serde(rename = "Token")]
    token: Option<String>,
    #[serde(rename = "SubscribeURL")]
    subscribe_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SesNotification {
    // AWS SESv2 config-set event destination publishes with `eventType`
    // (NOT `notificationType` — that's the older SES Email Receiving
    // format). Pinned by webhooks_ses_event_payload_tests.rs.
    #[serde(rename = "eventType")]
    notification_type: String,
    mail: SesMail,
    bounce: Option<SesBounce>,
    complaint: Option<SesComplaint>,
}

#[derive(Debug, Deserialize)]
struct SesMail {
    #[serde(rename = "messageId")]
    message_id: String,
}

#[derive(Debug, Deserialize)]
struct SesBounce {
    #[serde(rename = "bounceType")]
    bounce_type: String,
    #[serde(rename = "bounceSubType")]
    bounce_sub_type: String,
    #[serde(rename = "bouncedRecipients")]
    bounced_recipients: Vec<SesRecipient>,
}

#[derive(Debug, Deserialize)]
struct SesComplaint {
    #[serde(rename = "complainedRecipients")]
    complained_recipients: Vec<SesRecipient>,
}

#[derive(Debug, Deserialize)]
struct SesRecipient {
    #[serde(rename = "emailAddress")]
    email_address: String,
}

fn parse_sns_envelope(body: &str) -> Result<SnsEnvelope, ApiError> {
    let envelope: SnsEnvelope = serde_json::from_str(body)
        .map_err(|error| ApiError::BadRequest(format!("invalid SNS envelope JSON: {error}")))?;

    let required = [
        ("Type", envelope.sns_type.as_str()),
        ("MessageId", envelope.message_id.as_str()),
        ("TopicArn", envelope.topic_arn.as_str()),
        ("Message", envelope.message.as_str()),
        ("Timestamp", envelope.timestamp.as_str()),
        ("SignatureVersion", envelope.signature_version.as_str()),
        ("Signature", envelope.signature.as_str()),
        ("SigningCertURL", envelope.signing_cert_url.as_str()),
    ];
    for (field, value) in required {
        if value.trim().is_empty() {
            return Err(ApiError::BadRequest(format!(
                "missing required SNS field: {field}"
            )));
        }
    }

    Ok(envelope)
}

fn parse_sns_type(value: &str) -> Result<SnsType, ApiError> {
    match value {
        SNS_NOTIFICATION => Ok(SnsType::Notification),
        SNS_SUBSCRIPTION_CONFIRMATION => Ok(SnsType::SubscriptionConfirmation),
        SNS_UNSUBSCRIBE_CONFIRMATION => Ok(SnsType::UnsubscribeConfirmation),
        _ => Err(ApiError::BadRequest(format!(
            "unsupported SNS Type: {value}"
        ))),
    }
}

/// Reject cross-account or wrong-topic SNS envelopes before we trust their
/// signed payload. AWS signatures prove "an AWS SNS topic sent this", not "our
/// SES feedback topic sent this". Without an ARN allowlist, an attacker can
/// create their own SNS topic, trick us into auto-confirming it, then publish
/// signed Notification messages that suppress arbitrary recipients.
fn validate_sns_topic_arn(topic_arn: &str) -> Result<(), ApiError> {
    let segments: Vec<&str> = topic_arn.split(':').collect();
    if segments.len() != 6 {
        return Err(ApiError::BadRequest(format!(
            "TopicArn must use AWS ARN format: {topic_arn}"
        )));
    }
    if segments[0] != "arn" || segments[1] != "aws" || segments[2] != "sns" {
        return Err(ApiError::BadRequest(format!(
            "TopicArn must be an AWS SNS ARN: {topic_arn}"
        )));
    }
    if segments[3].is_empty() {
        return Err(ApiError::BadRequest("TopicArn region is empty".to_string()));
    }
    if segments[4] != TRUSTED_SNS_ACCOUNT_ID {
        return Err(ApiError::BadRequest(format!(
            "TopicArn account is not trusted: {}",
            segments[4]
        )));
    }
    if !segments[5].starts_with(TRUSTED_SES_FEEDBACK_TOPIC_PREFIX) {
        return Err(ApiError::BadRequest(format!(
            "TopicArn topic is not trusted: {}",
            segments[5]
        )));
    }
    Ok(())
}

fn validate_sns_url(url_value: &str, field_name: &str) -> Result<(), ApiError> {
    let parsed = reqwest::Url::parse(url_value).map_err(|error| {
        ApiError::BadRequest(format!("{field_name} is not a valid URL: {error}"))
    })?;
    if parsed.scheme() != "https" {
        return Err(ApiError::BadRequest(format!("{field_name} must use https")));
    }

    let Some(host) = parsed.host_str() else {
        return Err(ApiError::BadRequest(format!(
            "{field_name} must include a host"
        )));
    };

    if !is_trusted_sns_host(host) {
        return Err(ApiError::BadRequest(format!(
            "{field_name} host is not trusted: {host}"
        )));
    }

    Ok(())
}

fn is_trusted_sns_host(host: &str) -> bool {
    let Some(prefix) = host.strip_suffix(".amazonaws.com") else {
        return false;
    };
    prefix.starts_with("sns.") && prefix.len() > "sns.".len()
}

fn required_subscription_url(envelope: &SnsEnvelope) -> Result<&str, ApiError> {
    envelope
        .subscribe_url
        .as_deref()
        .filter(|url| !url.trim().is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing required SNS field: SubscribeURL".to_string()))
}

fn required_subscription_token(envelope: &SnsEnvelope) -> Result<&str, ApiError> {
    envelope
        .token
        .as_deref()
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing required SNS field: Token".to_string()))
}

async fn verify_sns_signature(
    state: &AppState,
    envelope: &SnsEnvelope,
    sns_type: SnsType,
) -> Result<(), ApiError> {
    let canonical = canonical_sns_string(envelope, sns_type)?;
    let digest = match envelope.signature_version.as_str() {
        "1" => MessageDigest::sha1(),
        "2" => MessageDigest::sha256(),
        _ => {
            return Err(ApiError::BadRequest(format!(
                "unsupported SNS SignatureVersion: {}",
                envelope.signature_version
            )))
        }
    };

    let signature_bytes = base64::engine::general_purpose::STANDARD
        .decode(envelope.signature.as_bytes())
        .map_err(|error| {
            ApiError::BadRequest(format!("invalid SNS signature encoding: {error}"))
        })?;

    let cert_pem = state
        .webhook_http_client
        .get_text(&envelope.signing_cert_url)
        .await
        .map_err(|error| ApiError::BadRequest(format!("failed to fetch signing cert: {error}")))?;
    let cert = X509::from_pem(cert_pem.as_bytes())
        .map_err(|error| ApiError::BadRequest(format!("invalid signing cert PEM: {error}")))?;
    let public_key = cert.public_key().map_err(|error| {
        ApiError::BadRequest(format!("invalid signing cert public key: {error}"))
    })?;
    let mut verifier = Verifier::new(digest, &public_key).map_err(|error| {
        ApiError::BadRequest(format!("failed to initialize signature verifier: {error}"))
    })?;
    verifier.update(canonical.as_bytes()).map_err(|error| {
        ApiError::BadRequest(format!("failed to feed signature payload: {error}"))
    })?;

    let is_valid = verifier.verify(&signature_bytes).map_err(|error| {
        ApiError::BadRequest(format!("failed to verify SNS signature: {error}"))
    })?;
    if !is_valid {
        return Err(ApiError::BadRequest("invalid SNS signature".to_string()));
    }

    Ok(())
}

/// Build the canonical signing string per the AWS SNS HTTP/HTTPS signature
/// spec, used as input to SHA1/SHA256 signature verification.
///
/// Format (load-bearing — must match AWS exactly, off-by-one-byte breaks
/// every real-world signature):
///   `<Key1>\n<Value1>\n<Key2>\n<Value2>\n...\n<KeyN>\n<ValueN>\n`
///
/// In particular, each key AND each value is followed by `\n`, including
/// the final value. A previous version of this function used `join("\n")`
/// which omitted the trailing `\n` on the last value; that produced a
/// canonical string one byte short of what AWS signed, so every real
/// SubscriptionConfirmation and Notification was rejected at signature
/// verification while unit tests still passed (because the unit-test
/// fixture mirrored the same off-by-one canonicalization). Symptom in
/// the wild: SNS subscriptions stuck in PendingConfirmation because our
/// handler returned 400 on AWS's redelivered confirmations.
///
/// Reference: https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
fn canonical_sns_string(envelope: &SnsEnvelope, sns_type: SnsType) -> Result<String, ApiError> {
    let mut fields: Vec<(&str, &str)> = Vec::new();
    fields.push(("Message", envelope.message.as_str()));
    fields.push(("MessageId", envelope.message_id.as_str()));

    match sns_type {
        SnsType::Notification => {
            if let Some(subject) = envelope.subject.as_deref() {
                if !subject.is_empty() {
                    fields.push(("Subject", subject));
                }
            }
            fields.push(("Timestamp", envelope.timestamp.as_str()));
        }
        SnsType::SubscriptionConfirmation | SnsType::UnsubscribeConfirmation => {
            fields.push(("SubscribeURL", required_subscription_url(envelope)?));
            fields.push(("Timestamp", envelope.timestamp.as_str()));
            fields.push(("Token", required_subscription_token(envelope)?));
        }
    }

    fields.push(("TopicArn", envelope.topic_arn.as_str()));
    fields.push(("Type", envelope.sns_type.as_str()));

    // Each (key, value) pair contributes `key\nvalue\n` — the trailing `\n`
    // on the last value is what AWS's signing process does, so omitting it
    // would produce a canonical string one byte short of AWS's input.
    let mut out = String::new();
    for (key, value) in &fields {
        out.push_str(key);
        out.push('\n');
        out.push_str(value);
        out.push('\n');
    }
    Ok(out)
}

async fn confirm_subscription(state: &AppState, envelope: &SnsEnvelope) -> Result<(), ApiError> {
    let subscribe_url = required_subscription_url(envelope)?;
    state
        .webhook_http_client
        .get_success(subscribe_url)
        .await
        .map_err(|error| ApiError::BadRequest(format!("subscription confirmation failed: {error}")))
}

async fn handle_ses_notification(state: &AppState, envelope: &SnsEnvelope) -> Result<(), ApiError> {
    let notification: SesNotification =
        serde_json::from_str(&envelope.message).map_err(|error| {
            ApiError::BadRequest(format!("invalid SES notification payload JSON: {error}"))
        })?;

    match notification.notification_type.as_str() {
        "Bounce" => handle_bounce_notification(state, envelope, &notification).await,
        "Complaint" => handle_complaint_notification(state, envelope, &notification).await,
        _ => Ok(()),
    }
}

async fn handle_bounce_notification(
    state: &AppState,
    envelope: &SnsEnvelope,
    notification: &SesNotification,
) -> Result<(), ApiError> {
    let Some(bounce) = notification.bounce.as_ref() else {
        return Err(ApiError::BadRequest(
            "SES bounce notification missing bounce payload".to_string(),
        ));
    };

    if bounce.bounce_type != "Permanent" {
        return Ok(());
    }

    let recipient = extract_recipient_from_bounce(bounce)?;
    let normalized_recipient = normalize_recipient_email(&recipient);
    if normalized_recipient.is_empty() {
        return Err(ApiError::BadRequest(
            "SES bounce recipient email is empty".to_string(),
        ));
    }

    let suppression_reason = format!(
        "bounce_{}_{}",
        bounce.bounce_type.to_ascii_lowercase(),
        bounce.bounce_sub_type.to_ascii_lowercase()
    );
    let suppression_store = PgEmailSuppressionStore::new(state.pool.clone());
    suppression_store
        .upsert_suppressed_recipient(
            &normalized_recipient,
            &suppression_reason,
            SNS_SUPPRESSION_SOURCE,
        )
        .await
        .map_err(ApiError::Internal)?;

    write_ses_suppression_audit(
        state,
        ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
        &normalized_recipient,
        serde_json::json!({
            "recipient_email": normalized_recipient,
            "sns_message_id": envelope.message_id,
            "sns_topic_arn": envelope.topic_arn,
            "ses_mail_message_id": notification.mail.message_id,
            "notification_type": notification.notification_type,
            "bounce_type": bounce.bounce_type,
            "bounce_sub_type": bounce.bounce_sub_type,
            "suppression_reason": suppression_reason,
        }),
    )
    .await;

    super::send_alert_best_effort(
        state,
        ses_suppression_alert(
            AlertSeverity::Warning,
            "SES permanent bounce suppressed recipient",
            &normalized_recipient,
            &notification.mail.message_id,
            &suppression_reason,
        ),
    )
    .await;

    Ok(())
}

async fn handle_complaint_notification(
    state: &AppState,
    envelope: &SnsEnvelope,
    notification: &SesNotification,
) -> Result<(), ApiError> {
    let Some(complaint) = notification.complaint.as_ref() else {
        return Err(ApiError::BadRequest(
            "SES complaint notification missing complaint payload".to_string(),
        ));
    };

    let recipient = extract_recipient_from_complaint(complaint)?;
    let normalized_recipient = normalize_recipient_email(&recipient);
    if normalized_recipient.is_empty() {
        return Err(ApiError::BadRequest(
            "SES complaint recipient email is empty".to_string(),
        ));
    }

    let suppression_store = PgEmailSuppressionStore::new(state.pool.clone());
    suppression_store
        .upsert_suppressed_recipient(&normalized_recipient, "complaint", SNS_SUPPRESSION_SOURCE)
        .await
        .map_err(ApiError::Internal)?;

    write_ses_suppression_audit(
        state,
        ACTION_SES_COMPLAINT_SUPPRESSED,
        &normalized_recipient,
        serde_json::json!({
            "recipient_email": normalized_recipient,
            "sns_message_id": envelope.message_id,
            "sns_topic_arn": envelope.topic_arn,
            "ses_mail_message_id": notification.mail.message_id,
            "notification_type": notification.notification_type,
            "suppression_reason": "complaint",
        }),
    )
    .await;

    super::send_alert_best_effort(
        state,
        ses_suppression_alert(
            AlertSeverity::Warning,
            "SES complaint suppressed recipient",
            &normalized_recipient,
            &notification.mail.message_id,
            "complaint",
        ),
    )
    .await;

    Ok(())
}

fn ses_suppression_alert(
    severity: AlertSeverity,
    title_prefix: &str,
    recipient_email: &str,
    ses_mail_message_id: &str,
    suppression_reason: &str,
) -> Alert {
    let mut metadata = HashMap::new();
    metadata.insert("recipient_email".to_string(), recipient_email.to_string());
    metadata.insert(
        "ses_mail_message_id".to_string(),
        ses_mail_message_id.to_string(),
    );
    metadata.insert(
        "suppression_reason".to_string(),
        suppression_reason.to_string(),
    );

    Alert {
        severity,
        title: format!("{title_prefix} {recipient_email}"),
        message: format!(
            "Recipient {recipient_email} was suppressed for {suppression_reason} (ses_mail_message_id={ses_mail_message_id})"
        ),
        metadata,
    }
}

fn extract_recipient_from_bounce(bounce: &SesBounce) -> Result<String, ApiError> {
    let Some(first) = bounce.bounced_recipients.first() else {
        return Err(ApiError::BadRequest(
            "SES bounce has no recipients".to_string(),
        ));
    };
    Ok(first.email_address.clone())
}

fn extract_recipient_from_complaint(complaint: &SesComplaint) -> Result<String, ApiError> {
    let Some(first) = complaint.complained_recipients.first() else {
        return Err(ApiError::BadRequest(
            "SES complaint has no recipients".to_string(),
        ));
    };
    Ok(first.email_address.clone())
}

async fn write_ses_suppression_audit(
    state: &AppState,
    action: &str,
    normalized_recipient: &str,
    metadata: serde_json::Value,
) {
    let target_tenant_id = match state
        .customer_repo
        .find_by_email(normalized_recipient)
        .await
    {
        Ok(customer) => customer.map(|row| row.id),
        Err(error) => {
            tracing::warn!(
                "failed to correlate SES suppression audit target for {}: {}",
                normalized_recipient,
                error
            );
            None
        }
    };

    if let Err(error) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
        action,
        target_tenant_id,
        metadata,
    )
    .await
    {
        tracing::error!("failed to write SES suppression audit row: {error}");
    }
}

// Regression tests pinning the AWS-SNS-spec canonical signing-string
// format byte-for-byte. Located in a sibling file so this module stays
// under the file-size guardrail; the `#[path]` form keeps the tests
// scoped INSIDE this `ses` module so `use super::*;` in the test
// file resolves the private `SnsType`, `SnsEnvelope`, and
// `canonical_sns_string` items it asserts against.
//
// Spec: https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
#[cfg(test)]
#[path = "webhooks_canonical_sns_string_tests.rs"]
mod canonical_sns_string_tests;

// Regression tests for the AWS SESv2 event-destination payload format.
// Sibling file for the same size-guardrail reason as the SNS tests above.
#[cfg(test)]
#[path = "webhooks_ses_event_payload_tests.rs"]
mod ses_event_payload_tests;

#[cfg(test)]
mod sns_topic_arn_tests {
    use super::*;

    #[test]
    fn accepts_trusted_ses_feedback_topic_arn() {
        let trusted = "arn:aws:sns:us-east-1:213880904778:fjcloud-ses-feedback-staging";
        assert!(validate_sns_topic_arn(trusted).is_ok());
    }

    #[test]
    fn rejects_untrusted_account_even_when_topic_name_matches() {
        let err = validate_sns_topic_arn(
            "arn:aws:sns:us-east-1:999999999999:fjcloud-ses-feedback-staging",
        )
        .unwrap_err();
        assert!(
            matches!(err, ApiError::BadRequest(ref message) if message.contains("TopicArn account is not trusted")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn rejects_non_feedback_topic_in_trusted_account() {
        let err =
            validate_sns_topic_arn("arn:aws:sns:us-east-1:213880904778:attacker-controlled-topic")
                .unwrap_err();
        assert!(
            matches!(err, ApiError::BadRequest(ref message) if message.contains("TopicArn topic is not trusted")),
            "unexpected error: {err:?}"
        );
    }
}

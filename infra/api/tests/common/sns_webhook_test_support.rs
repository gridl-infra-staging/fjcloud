// Shared SNS/SES webhook fixture. Two test roots drive the SES webhook
// (`platform` via ses_bounce_complaint_handler_test.rs, `auth_admin` via
// admin_webhook_events_test.rs), so the signing fixture lives here rather
// than being duplicated per root. Focused shard selections compile this
// module even when a shard calls none of it.
#![allow(dead_code)]

//! AWS-SNS signing fixture and SES notification payload builders.
//!
//! `canonical_sns_string` below is a deliberate independent reimplementation
//! of the production function in `infra/api/src/routes/webhooks/ses.rs`; it
//! pins the AWS signing-string spec from the test side so a production-side
//! regression cannot silently redefine "correct".

use std::sync::Arc;

use base64::Engine as _;
use chrono::Utc;
use openssl::hash::MessageDigest;
use openssl::pkey::PKey;
use openssl::rsa::Rsa;
use openssl::sign::Signer;
use openssl::x509::{X509NameBuilder, X509};
use uuid::Uuid;

pub const TRUSTED_SNS_HOST: &str = "sns.us-east-1.amazonaws.com";
pub const TRUSTED_SIGNING_CERT_URL: &str =
    "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem";
pub const TRUSTED_SUBSCRIBE_URL: &str = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=arn:aws:sns:us-east-1:213880904778:fjcloud-ses-feedback-staging&Token=token-123";

#[derive(Clone)]
pub struct SnsSigningFixture {
    cert_pem: String,
    private_key: PKey<openssl::pkey::Private>,
}

impl SnsSigningFixture {
    pub fn new() -> Self {
        let rsa = Rsa::generate(2048).expect("generate RSA key");
        let private_key = PKey::from_rsa(rsa).expect("convert private key");

        let mut name_builder = X509NameBuilder::new().expect("create x509 name builder");
        name_builder
            .append_entry_by_text("CN", TRUSTED_SNS_HOST)
            .expect("set common name");
        let name = name_builder.build();

        let mut builder = X509::builder().expect("create x509 cert builder");
        builder.set_version(2).expect("set cert version");
        builder.set_subject_name(&name).expect("set subject");
        builder.set_issuer_name(&name).expect("set issuer");
        builder
            .set_pubkey(&private_key)
            .expect("set public key on cert");
        let not_before = openssl::asn1::Asn1Time::days_from_now(0).expect("not_before");
        let not_after = openssl::asn1::Asn1Time::days_from_now(1).expect("not_after");
        builder
            .set_not_before(&not_before)
            .expect("apply not_before");
        builder.set_not_after(&not_after).expect("apply not_after");
        builder
            .sign(&private_key, MessageDigest::sha256())
            .expect("sign certificate");

        let cert = builder.build();
        let cert_pem = String::from_utf8(cert.to_pem().expect("serialize cert to pem"))
            .expect("cert pem is valid UTF-8");

        Self {
            cert_pem,
            private_key,
        }
    }
}

pub fn signed_sns_envelope(
    fixture: &SnsSigningFixture,
    sns_type: &str,
    message: &str,
    signature_version: &str,
    signing_cert_url: &str,
    subscribe_url: Option<&str>,
    tamper_signature: bool,
) -> serde_json::Value {
    let message_id = Uuid::new_v4().to_string();
    let timestamp = Utc::now().to_rfc3339();
    let topic_arn = "arn:aws:sns:us-east-1:213880904778:fjcloud-ses-feedback-staging";

    let mut envelope = serde_json::json!({
        "Type": sns_type,
        "MessageId": message_id,
        "TopicArn": topic_arn,
        "Timestamp": timestamp,
        "SignatureVersion": signature_version,
        "SigningCertURL": signing_cert_url,
        "Message": message,
    });

    if sns_type == "SubscriptionConfirmation" || sns_type == "UnsubscribeConfirmation" {
        envelope["Token"] = serde_json::Value::String("token-123".to_string());
        envelope["SubscribeURL"] =
            serde_json::Value::String(subscribe_url.unwrap_or(TRUSTED_SUBSCRIBE_URL).to_string());
    }

    let canonical = canonical_sns_string(&envelope).expect("build canonical string");
    let digest = match signature_version {
        "1" => MessageDigest::sha1(),
        "2" => MessageDigest::sha256(),
        _ => MessageDigest::sha256(),
    };
    let mut signer = Signer::new(digest, &fixture.private_key).expect("create signer");
    signer
        .update(canonical.as_bytes())
        .expect("feed canonical bytes");
    let mut signature = signer.sign_to_vec().expect("sign canonical data");
    if tamper_signature {
        signature.reverse();
    }
    envelope["Signature"] =
        serde_json::Value::String(base64::engine::general_purpose::STANDARD.encode(signature));

    envelope
}

pub fn canonical_sns_string(envelope: &serde_json::Value) -> Result<String, String> {
    let sns_type = envelope["Type"]
        .as_str()
        .ok_or_else(|| "Type missing".to_string())?;

    let mut fields: Vec<(&str, &str)> = Vec::new();
    fields.push((
        "Message",
        envelope["Message"]
            .as_str()
            .ok_or_else(|| "Message missing".to_string())?,
    ));
    fields.push((
        "MessageId",
        envelope["MessageId"]
            .as_str()
            .ok_or_else(|| "MessageId missing".to_string())?,
    ));

    if sns_type == "SubscriptionConfirmation" || sns_type == "UnsubscribeConfirmation" {
        fields.push((
            "SubscribeURL",
            envelope["SubscribeURL"]
                .as_str()
                .ok_or_else(|| "SubscribeURL missing".to_string())?,
        ));
        fields.push((
            "Timestamp",
            envelope["Timestamp"]
                .as_str()
                .ok_or_else(|| "Timestamp missing".to_string())?,
        ));
        fields.push((
            "Token",
            envelope["Token"]
                .as_str()
                .ok_or_else(|| "Token missing".to_string())?,
        ));
    } else if let Some(subject) = envelope["Subject"].as_str() {
        fields.push(("Subject", subject));
        fields.push((
            "Timestamp",
            envelope["Timestamp"]
                .as_str()
                .ok_or_else(|| "Timestamp missing".to_string())?,
        ));
    } else {
        fields.push((
            "Timestamp",
            envelope["Timestamp"]
                .as_str()
                .ok_or_else(|| "Timestamp missing".to_string())?,
        ));
    }
    fields.push((
        "TopicArn",
        envelope["TopicArn"]
            .as_str()
            .ok_or_else(|| "TopicArn missing".to_string())?,
    ));
    fields.push(("Type", sns_type));

    // Mirror production: each (key, value) contributes `key\nvalue\n`,
    // including the trailing `\n` on the final value, per the AWS SNS
    // signature spec. See production-side comment in
    // infra/api/src/routes/webhooks/ses.rs::canonical_sns_string for why the
    // earlier `join("\n")` form was a real-world bug despite passing this
    // round-trip unit test.
    let mut out = String::new();
    for (key, value) in &fields {
        out.push_str(key);
        out.push('\n');
        out.push_str(value);
        out.push('\n');
    }
    Ok(out)
}

pub fn ses_bounce_message(
    notification_type: &str,
    subtype: &str,
    recipient: &str,
    mail_message_id: &str,
) -> serde_json::Value {
    serde_json::json!({
        "eventType": notification_type,
        "mail": {
            "timestamp": Utc::now().to_rfc3339(),
            "source": "sender@example.com",
            "messageId": mail_message_id,
            "destination": [recipient],
        },
        "bounce": {
            "bounceType": "Permanent",
            "bounceSubType": subtype,
            "bouncedRecipients": [
                { "emailAddress": recipient }
            ]
        }
    })
}

pub fn ses_complaint_message(recipient: &str, mail_message_id: &str) -> serde_json::Value {
    serde_json::json!({
        "eventType": "Complaint",
        "mail": {
            "timestamp": Utc::now().to_rfc3339(),
            "source": "sender@example.com",
            "messageId": mail_message_id,
            "destination": [recipient],
        },
        "complaint": {
            "complainedRecipients": [
                { "emailAddress": recipient }
            ]
        }
    })
}

pub fn webhook_http_client_for_fixture(
    fixture: &SnsSigningFixture,
) -> Arc<super::MockWebhookHttpClient> {
    let webhook_http_client = super::mock_webhook_http_client();
    webhook_http_client.set_text_response(TRUSTED_SIGNING_CERT_URL, Ok(fixture.cert_pem.clone()));
    webhook_http_client.set_success_response(TRUSTED_SUBSCRIBE_URL, Ok(()));
    webhook_http_client
}

mod common;

use std::sync::Arc;

use api::services::audit_log::{
    ACTION_SES_COMPLAINT_SUPPRESSED, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use base64::Engine as _;
use chrono::Utc;
use http_body_util::BodyExt;
use openssl::hash::MessageDigest;
use openssl::pkey::PKey;
use openssl::rsa::Rsa;
use openssl::sign::Signer;
use openssl::x509::{X509NameBuilder, X509};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

const TRUSTED_SNS_HOST: &str = "sns.us-east-1.amazonaws.com";
const TRUSTED_SIGNING_CERT_URL: &str =
    "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-test.pem";
const TRUSTED_SUBSCRIBE_URL: &str = "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=arn:aws:sns:us-east-1:111111111111:ses-feedback&Token=token-123";

#[derive(Clone)]
struct SnsSigningFixture {
    cert_pem: String,
    private_key: PKey<openssl::pkey::Private>,
}

impl SnsSigningFixture {
    fn new() -> Self {
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

fn signed_sns_envelope(
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
    let topic_arn = "arn:aws:sns:us-east-1:111111111111:ses-feedback";

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

fn canonical_sns_string(envelope: &serde_json::Value) -> Result<String, String> {
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
    // infra/api/src/routes/webhooks.rs::canonical_sns_string for why the
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

fn ses_bounce_message(
    notification_type: &str,
    subtype: &str,
    recipient: &str,
    mail_message_id: &str,
) -> serde_json::Value {
    serde_json::json!({
        "notificationType": notification_type,
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

fn ses_complaint_message(recipient: &str, mail_message_id: &str) -> serde_json::Value {
    serde_json::json!({
        "notificationType": "Complaint",
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

fn build_app_with_pool(
    pool: PgPool,
    customer_repo: Arc<common::MockCustomerRepo>,
    webhook_http_client: Arc<common::MockWebhookHttpClient>,
) -> axum::Router {
    let mut state = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_webhook_http_client(webhook_http_client)
        .build();
    state.pool = pool;
    api::router::build_router(state)
}

fn webhook_http_client_for_fixture(
    fixture: &SnsSigningFixture,
) -> Arc<common::MockWebhookHttpClient> {
    let webhook_http_client = common::mock_webhook_http_client();
    webhook_http_client.set_text_response(TRUSTED_SIGNING_CERT_URL, Ok(fixture.cert_pem.clone()));
    webhook_http_client.set_success_response(TRUSTED_SUBSCRIBE_URL, Ok(()));
    webhook_http_client
}

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping SES SNS webhook integration tests");
        return None;
    };

    let pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");

    Some(pool)
}

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, serde_json::Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body =
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body)
}

async fn suppression_row_count(pool: &PgPool, recipient_email: &str) -> i64 {
    let normalized = recipient_email.trim().to_ascii_lowercase();
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM email_suppression WHERE recipient_email = $1",
    )
    .bind(normalized)
    .fetch_one(pool)
    .await
    .expect("count suppression rows")
}

async fn suppression_reason(pool: &PgPool, recipient_email: &str) -> Option<String> {
    let normalized = recipient_email.trim().to_ascii_lowercase();
    sqlx::query_scalar::<_, String>(
        "SELECT suppression_reason FROM email_suppression WHERE recipient_email = $1",
    )
    .bind(normalized)
    .fetch_optional(pool)
    .await
    .expect("read suppression reason")
}

async fn audit_row_count(pool: &PgPool, action: &str, target_tenant_id: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(action)
    .bind(target_tenant_id)
    .fetch_one(pool)
    .await
    .expect("count audit rows")
}

async fn cleanup_for_customer(pool: &PgPool, customer_id: Uuid, recipient_email: &str) {
    let normalized = recipient_email.trim().to_ascii_lowercase();
    let _ = sqlx::query("DELETE FROM audit_log WHERE target_tenant_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await;
    let _ = sqlx::query("DELETE FROM email_suppression WHERE recipient_email = $1")
        .bind(normalized)
        .execute(pool)
        .await;
}

#[tokio::test]
async fn ses_sns_route_exists_and_rejects_malformed_outer_envelope() {
    let app = common::TestStateBuilder::new().build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from("{"))
                .expect("build malformed request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn ses_sns_route_rejects_unsupported_sns_type() {
    let fixture = SnsSigningFixture::new();
    let message = serde_json::json!({ "notificationType": "Bounce" }).to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "CustomType",
        &message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        false,
    );

    let app = common::TestStateBuilder::new().build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn ses_sns_route_rejects_malformed_inner_ses_json() {
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        "{ this is not valid JSON",
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        false,
    );

    let app = common::TestStateBuilder::new()
        .with_webhook_http_client(webhook_http_client)
        .build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn ses_sns_route_rejects_untrusted_signing_cert_url_host() {
    let fixture = SnsSigningFixture::new();
    let message =
        ses_bounce_message("Bounce", "General", "host-test@example.com", "mail-host-1").to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        &message,
        "2",
        "https://evil.example.com/cert.pem",
        None,
        false,
    );

    let app = common::TestStateBuilder::new().build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn ses_sns_route_rejects_untrusted_subscribe_url_host() {
    let fixture = SnsSigningFixture::new();
    let message = "confirm this subscription";
    let payload = signed_sns_envelope(
        &fixture,
        "SubscriptionConfirmation",
        message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        Some("https://evil.example.com/confirm"),
        false,
    );

    let app = common::TestStateBuilder::new().build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn ses_sns_route_rejects_invalid_signature() {
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let message =
        ses_bounce_message("Bounce", "General", "sig-test@example.com", "mail-sig-1").to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        &message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        true,
    );

    let app = common::TestStateBuilder::new()
        .with_webhook_http_client(webhook_http_client)
        .build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn hard_bounce_suppresses_recipient_and_writes_correlated_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Hard Bounce", "hard-bounce@example.com");
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let app = build_app_with_pool(
        pool.clone(),
        Arc::clone(&customer_repo),
        webhook_http_client,
    );

    let message = ses_bounce_message(
        "Bounce",
        "General",
        "hard-bounce@example.com",
        "mail-hard-bounce-1",
    )
    .to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        &message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        false,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");
    let (status, _body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        suppression_row_count(&pool, "hard-bounce@example.com").await,
        1
    );
    assert_eq!(
        suppression_reason(&pool, "hard-bounce@example.com")
            .await
            .as_deref(),
        Some("bounce_permanent_general")
    );
    assert_eq!(
        audit_row_count(&pool, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED, customer.id).await,
        1
    );

    cleanup_for_customer(&pool, customer.id, "hard-bounce@example.com").await;
}

#[tokio::test]
async fn complaint_suppresses_recipient_and_writes_correlated_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Complaint", "complaint@example.com");
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let app = build_app_with_pool(
        pool.clone(),
        Arc::clone(&customer_repo),
        webhook_http_client,
    );

    let message = ses_complaint_message("complaint@example.com", "mail-complaint-1").to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        &message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        false,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");
    let (status, _body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        suppression_row_count(&pool, "complaint@example.com").await,
        1
    );
    assert_eq!(
        suppression_reason(&pool, "complaint@example.com")
            .await
            .as_deref(),
        Some("complaint")
    );
    assert_eq!(
        audit_row_count(&pool, ACTION_SES_COMPLAINT_SUPPRESSED, customer.id).await,
        1
    );

    cleanup_for_customer(&pool, customer.id, "complaint@example.com").await;
}

#[tokio::test]
async fn transient_bounce_event_is_ignored_without_suppression_or_audit() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Transient Bounce", "transient@example.com");
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let app = build_app_with_pool(
        pool.clone(),
        Arc::clone(&customer_repo),
        webhook_http_client,
    );

    let message = serde_json::json!({
        "notificationType": "Bounce",
        "mail": {
            "timestamp": Utc::now().to_rfc3339(),
            "source": "sender@example.com",
            "messageId": "mail-transient-1",
            "destination": ["transient@example.com"],
        },
        "bounce": {
            "bounceType": "Transient",
            "bounceSubType": "MailboxFull",
            "bouncedRecipients": [
                { "emailAddress": "transient@example.com" }
            ]
        }
    })
    .to_string();
    let payload = signed_sns_envelope(
        &fixture,
        "Notification",
        &message,
        "2",
        TRUSTED_SIGNING_CERT_URL,
        None,
        false,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");
    let (status, _body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        suppression_row_count(&pool, "transient@example.com").await,
        0
    );
    assert_eq!(
        audit_row_count(&pool, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED, customer.id).await,
        0
    );
    assert_eq!(
        audit_row_count(&pool, ACTION_SES_COMPLAINT_SUPPRESSED, customer.id).await,
        0
    );

    cleanup_for_customer(&pool, customer.id, "transient@example.com").await;
}

#[tokio::test]
async fn subscription_confirmation_confirms_verified_request() {
    let fixture = SnsSigningFixture::new();
    let webhook_http_client = webhook_http_client_for_fixture(&fixture);
    let payload = signed_sns_envelope(
        &fixture,
        "SubscriptionConfirmation",
        "confirm this subscription",
        "2",
        TRUSTED_SIGNING_CERT_URL,
        Some(TRUSTED_SUBSCRIBE_URL),
        false,
    );

    let app = common::TestStateBuilder::new()
        .with_webhook_http_client(Arc::clone(&webhook_http_client))
        .build_app();
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/webhooks/ses/sns")
                .header("content-type", "application/json")
                .body(Body::from(payload.to_string()))
                .expect("build request"),
        )
        .await
        .expect("send request");

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        webhook_http_client.success_calls(),
        vec![TRUSTED_SUBSCRIBE_URL]
    );
}

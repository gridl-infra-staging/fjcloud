use std::sync::Arc;

use api::repos::webhook_event_repo::WebhookEventRow;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::Utc;
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn app_with_webhook_repo(
    webhook_event_repo: Arc<crate::common::MockWebhookEventRepo>,
) -> axum::Router {
    crate::common::TestStateBuilder::new()
        .with_webhook_event_repo(webhook_event_repo)
        .build_app()
}

#[tokio::test]
async fn admin_webhook_events_requires_admin_auth() {
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_auth")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_webhook_events_returns_seeded_row() {
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let seeded_row = WebhookEventRow {
        stripe_event_id: "evt_test_lookup".to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "id": "evt_test_lookup",
            "object": "event",
            "data": { "object": { "id": "in_test_lookup" } }
        }),
        processed_at: Some(Utc::now()),
        created_at: Utc::now(),
    };
    webhook_event_repo.seed_row(seeded_row.clone());

    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_lookup")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json, serde_json::to_value(&seeded_row).unwrap());
}

#[tokio::test]
async fn admin_webhook_events_returns_404_for_unknown_event_id() {
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=evt_test_missing")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(
        json,
        serde_json::json!({ "error": "webhook event not found" })
    );
}

#[tokio::test]
async fn admin_webhook_events_returns_400_for_missing_or_blank_stripe_event_id() {
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let app = app_with_webhook_repo(webhook_event_repo);

    let missing_param_req = Request::builder()
        .uri("/admin/webhook-events")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let missing_param_resp = app.clone().oneshot(missing_param_req).await.unwrap();
    assert_eq!(missing_param_resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        body_json(missing_param_resp).await,
        serde_json::json!({ "error": "stripe_event_id query parameter is required" })
    );

    let blank_param_req = Request::builder()
        .uri("/admin/webhook-events?stripe_event_id=")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();
    let blank_param_resp = app.oneshot(blank_param_req).await.unwrap();
    assert_eq!(blank_param_resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        body_json(blank_param_resp).await,
        serde_json::json!({ "error": "stripe_event_id query parameter is required" })
    );
}

// ===========================================================================
// Stage 1 — webhook audit rows must carry a SYSTEM actor (RED until the
// operator-identity work lands).
//
// `routes/webhooks/ses.rs` and `routes/webhooks/stripe_disputes.rs` are
// machine-initiated by a third-party vendor callback: no human operator
// exists, so attributing them to an operator identity would be a lie in the
// audit trail. They must get a distinct, documented SYSTEM actor instead —
// and NOT the nil sentinel, because leaving two occupants behind means the
// "sentinel is gone" assertion can never pass.
//
// These rows can carry `target_tenant_id IS NULL` when the vendor payload
// cannot be correlated to a customer, so the helpers below fetch and clean up
// by ACTION rather than by target. They also run inside an isolated schema
// (`common/support/pg_schema_harness.rs`) so an action-scoped `SELECT` can
// assert an exact row count without seeing another test's rows.
// ===========================================================================

use api::repos::{CustomerRepo, InvoiceRepo};
use api::services::audit_log::{
    ACTION_SES_COMPLAINT_SUPPRESSED, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
    ACTION_STRIPE_DISPUTE_UPDATED,
};
use axum::http::Method;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::sns_webhook_test_support::{
    ses_bounce_message, ses_complaint_message, signed_sns_envelope,
    webhook_http_client_for_fixture, SnsSigningFixture, TRUSTED_SIGNING_CERT_URL,
};
use crate::common::stripe_webhook_test_support::{
    dispute_created_payload, dispute_funds_withdrawn_payload, seed_draft_invoice, webhook_request,
};
use crate::common::support::pg_schema_harness;

// Durable UUIDv5 identities derived from the canonical actor names
// `https://fjcloud.com/audit/system/{ses,stripe}` in the URL namespace.
// Production must store these exact values so audit queries remain stable
// across process restarts and each vendor has a distinct identity.
const SES_SYSTEM_ACTOR_ID: Uuid = Uuid::from_u128(0x8a0f2350_fc1d_5c32_8f1e_09d9dd362d4a);
const STRIPE_SYSTEM_ACTOR_ID: Uuid = Uuid::from_u128(0x2b9e4725_b5fe_5cd3_ba7a_537abb6d31e9);

/// `(actor_id, metadata)` for every audit row of one action. Action-scoped
/// because vendor rows may have a NULL `target_tenant_id`.
async fn audit_rows_for_action(pool: &PgPool, action: &str) -> Vec<(Uuid, serde_json::Value)> {
    sqlx::query_as::<_, (Uuid, serde_json::Value)>(
        "SELECT actor_id, metadata FROM audit_log WHERE action = $1 ORDER BY created_at ASC",
    )
    .bind(action)
    .fetch_all(pool)
    .await
    .expect("read audit rows by action")
}

/// Assert the vendor-actor contract on one row.
fn assert_system_actor_row(
    actor_id: Uuid,
    expected_actor_id: Uuid,
    metadata: &serde_json::Value,
    system: &str,
) {
    assert_eq!(
        actor_id, expected_actor_id,
        "a vendor-initiated {system} webhook row must carry its documented, durable system actor"
    );
    assert_eq!(
        metadata["actor_type"], "system",
        "the audit row must mark itself machine-initiated so a reader can tell it from an \
         operator action"
    );
    assert_eq!(
        metadata["system"], system,
        "the audit row must name which vendor callback produced it"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn ses_suppression_webhooks_write_a_stable_ses_system_actor() {
    assert_ne!(
        SES_SYSTEM_ACTOR_ID, STRIPE_SYSTEM_ACTOR_ID,
        "SES and Stripe must have distinct system identities"
    );

    let Some(db) = pg_schema_harness::connect_and_migrate("stage1_ses_system_actor").await else {
        return;
    };
    let pool = db.pool.clone();

    let customer_repo = crate::common::mock_repo();
    let bounce_recipient = "ses-system-bounce@example.com";
    let complaint_recipient = "ses-system-complaint@example.com";
    customer_repo.seed("SES Bounce", bounce_recipient);
    customer_repo.seed("SES Complaint", complaint_recipient);

    let fixture = SnsSigningFixture::new();
    let state = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_webhook_http_client(webhook_http_client_for_fixture(&fixture))
        .with_pool(pool.clone())
        .build();
    let app = api::router::build_router(state);

    let notifications = [
        ses_bounce_message("Bounce", "General", bounce_recipient, "mail-ses-system-1"),
        ses_complaint_message(complaint_recipient, "mail-ses-system-2"),
    ];
    for message in notifications {
        let payload = signed_sns_envelope(
            &fixture,
            "Notification",
            &message.to_string(),
            "2",
            TRUSTED_SIGNING_CERT_URL,
            None,
            false,
        );
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/webhooks/ses/sns")
                    .header("content-type", "application/json")
                    .body(Body::from(payload.to_string()))
                    .expect("build SES webhook request"),
            )
            .await
            .expect("send SES webhook request");
        assert_eq!(resp.status(), StatusCode::OK);
    }

    let bounce_rows = audit_rows_for_action(&pool, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED).await;
    assert_eq!(
        bounce_rows.len(),
        1,
        "one permanent bounce must write exactly one audit row"
    );
    assert_system_actor_row(
        bounce_rows[0].0,
        SES_SYSTEM_ACTOR_ID,
        &bounce_rows[0].1,
        "ses",
    );
    assert_eq!(
        bounce_rows[0].1["recipient_email"], bounce_recipient,
        "the existing SES metadata contract must survive the actor change"
    );

    let complaint_rows = audit_rows_for_action(&pool, ACTION_SES_COMPLAINT_SUPPRESSED).await;
    assert_eq!(
        complaint_rows.len(),
        1,
        "one complaint must write exactly one audit row"
    );
    assert_system_actor_row(
        complaint_rows[0].0,
        SES_SYSTEM_ACTOR_ID,
        &complaint_rows[0].1,
        "ses",
    );

    // Stability: the SES system actor is one fixed identity, not a fresh UUID
    // minted per call. A per-call `Uuid::new_v4()` would satisfy every
    // assertion above and still be useless for querying the audit trail.
    assert_eq!(
        bounce_rows[0].0, complaint_rows[0].0,
        "both SES actions must share one stable ses system actor id"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn stripe_dispute_webhooks_write_a_stable_stripe_system_actor() {
    let Some(db) = pg_schema_harness::connect_and_migrate("stage1_stripe_system_actor").await
    else {
        return;
    };
    let pool = db.pool.clone();

    let customer_repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();
    let webhook_event_repo = crate::common::mock_webhook_event_repo();
    let customer = customer_repo.seed("Dispute System Actor", "dispute-system-actor@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_dispute_system_actor")
        .await
        .expect("attach stripe customer id");
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_dispute_system_actor",
            "https://stripe.test/in_dispute_system_actor",
            None,
        )
        .await
        .expect("attach Stripe invoice id");
    webhook_event_repo.seed_row(WebhookEventRow {
        stripe_event_id: "evt_dispute_system_actor_invoice_paid".to_string(),
        event_type: "invoice.paid".to_string(),
        payload: serde_json::json!({
            "data": {
                "object": {
                    "id": "in_dispute_system_actor",
                    "payment_intent": "pi_dispute_system_actor"
                }
            }
        }),
        processed_at: Some(Utc::now()),
        created_at: Utc::now(),
    });

    let state = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_webhook_event_repo(webhook_event_repo)
        .with_pool(pool.clone())
        .build();
    let app = api::router::build_router(state);

    let payloads = [
        dispute_created_payload(
            "evt_dispute_system_actor_created",
            "dp_dispute_system_actor",
            "ch_dispute_system_actor",
            Some("pi_dispute_system_actor"),
            "cus_dispute_system_actor",
            5000,
        ),
        dispute_funds_withdrawn_payload(
            "evt_dispute_system_actor_withdrawn",
            "dp_dispute_system_actor",
            "ch_dispute_system_actor",
            Some("pi_dispute_system_actor"),
            "cus_dispute_system_actor",
            5000,
        ),
    ];
    for payload in &payloads {
        let resp = app
            .clone()
            .oneshot(webhook_request(payload))
            .await
            .expect("send stripe dispute webhook");
        assert_eq!(resp.status(), StatusCode::OK);
    }

    let rows = audit_rows_for_action(&pool, ACTION_STRIPE_DISPUTE_UPDATED).await;
    assert_eq!(
        rows.len(),
        2,
        "each dispute milestone must write exactly one audit row"
    );
    for (actor_id, metadata) in &rows {
        assert_system_actor_row(*actor_id, STRIPE_SYSTEM_ACTOR_ID, metadata, "stripe");
        assert_eq!(
            metadata["stripe_dispute_id"], "dp_dispute_system_actor",
            "the existing dispute metadata contract must survive the actor change"
        );
    }
    assert_eq!(
        rows[0].1["invoice_id"],
        serde_json::json!(invoice.id),
        "the dispute audit row must still correlate to the resolved invoice"
    );

    assert_eq!(
        rows[0].0, rows[1].0,
        "both dispute milestones must share one stable stripe system actor id"
    );
}

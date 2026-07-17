use api::repos::{DisputeRepo, DisputeUpsertInput, PgDisputeRepo};
use chrono::Utc;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::{self, DbHarness};

async fn connect_and_migrate() -> Option<DbHarness> {
    pg_schema_harness::connect_and_migrate("it_pg_dispute_repo").await
}

#[tokio::test]
async fn upsert_is_idempotent_by_stripe_dispute_id() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgDisputeRepo::new(pool.clone());

    let stripe_dispute_id = format!("dp_test_{}", Uuid::new_v4().simple());
    let input = DisputeUpsertInput {
        stripe_dispute_id: stripe_dispute_id.clone(),
        stripe_charge_id: format!("ch_test_{}", Uuid::new_v4().simple()),
        stripe_payment_intent_id: Some(format!("pi_test_{}", Uuid::new_v4().simple())),
        invoice_id: None,
        amount_cents: 4900,
        currency: "usd".to_string(),
        reason: Some("fraudulent".to_string()),
        status: "needs_response".to_string(),
        evidence_due_by: Some(Utc::now()),
        disputed_at: Some(Utc::now()),
        resolved_at: None,
    };

    let first = repo.upsert(&input).await.expect("first upsert");
    let second = repo.upsert(&input).await.expect("second upsert");

    assert_eq!(first.stripe_dispute_id, stripe_dispute_id);
    assert_eq!(second.stripe_dispute_id, stripe_dispute_id);

    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM disputes WHERE stripe_dispute_id = $1")
            .bind(&stripe_dispute_id)
            .fetch_one(&pool)
            .await
            .expect("count dispute rows");
    assert_eq!(count, 1, "duplicate upserts must not create duplicate rows");
}

#[tokio::test]
async fn upsert_updates_lifecycle_status_transition_fields() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let repo = PgDisputeRepo::new(db.pool.clone());

    let stripe_dispute_id = format!("dp_test_{}", Uuid::new_v4().simple());
    let mut input = DisputeUpsertInput {
        stripe_dispute_id: stripe_dispute_id.clone(),
        stripe_charge_id: format!("ch_test_{}", Uuid::new_v4().simple()),
        stripe_payment_intent_id: None,
        invoice_id: None,
        amount_cents: 700,
        currency: "usd".to_string(),
        reason: Some("product_not_received".to_string()),
        status: "needs_response".to_string(),
        evidence_due_by: None,
        disputed_at: Some(Utc::now()),
        resolved_at: None,
    };

    repo.upsert(&input).await.expect("initial upsert");

    input.status = "won".to_string();
    input.resolved_at = Some(Utc::now());

    let updated = repo.upsert(&input).await.expect("status transition upsert");

    assert_eq!(updated.status, "won");
    assert!(updated.resolved_at.is_some());
}

#[tokio::test]
async fn upsert_persists_nullable_invoice_id() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let repo = PgDisputeRepo::new(db.pool.clone());

    let stripe_dispute_id = format!("dp_test_{}", Uuid::new_v4().simple());
    let input = DisputeUpsertInput {
        stripe_dispute_id,
        stripe_charge_id: format!("ch_test_{}", Uuid::new_v4().simple()),
        stripe_payment_intent_id: Some(format!("pi_test_{}", Uuid::new_v4().simple())),
        invoice_id: None,
        amount_cents: 1200,
        currency: "usd".to_string(),
        reason: None,
        status: "warning_needs_response".to_string(),
        evidence_due_by: None,
        disputed_at: Some(Utc::now()),
        resolved_at: None,
    };

    let stored = repo
        .upsert(&input)
        .await
        .expect("upsert with null invoice_id");

    assert_eq!(stored.invoice_id, None);
}

#[tokio::test]
async fn upsert_with_null_invoice_id_preserves_existing_invoice_link() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgDisputeRepo::new(pool.clone());

    let customer_id = Uuid::new_v4();
    let invoice_id = Uuid::new_v4();
    sqlx::query("INSERT INTO customers (id, name, email) VALUES ($1, $2, $3)")
        .bind(customer_id)
        .bind(format!("Dispute Test {}", &customer_id.to_string()[..8]))
        .bind(format!(
            "dispute-{}@integration.test",
            &customer_id.to_string()[..8]
        ))
        .execute(&pool)
        .await
        .expect("insert customer for invoice FK");
    sqlx::query(
        "INSERT INTO invoices (id, customer_id, period_start, period_end, subtotal_cents, total_cents, status) \
         VALUES ($1, $2, DATE '2026-01-01', DATE '2026-01-31', 1000, 1000, 'finalized')",
    )
    .bind(invoice_id)
    .bind(customer_id)
    .execute(&pool)
    .await
    .expect("insert invoice for dispute link");

    let stripe_dispute_id = format!("dp_test_{}", Uuid::new_v4().simple());
    let mut input = DisputeUpsertInput {
        stripe_dispute_id: stripe_dispute_id.clone(),
        stripe_charge_id: format!("ch_test_{}", Uuid::new_v4().simple()),
        stripe_payment_intent_id: Some(format!("pi_test_{}", Uuid::new_v4().simple())),
        invoice_id: Some(invoice_id),
        amount_cents: 3400,
        currency: "usd".to_string(),
        reason: Some("fraudulent".to_string()),
        status: "needs_response".to_string(),
        evidence_due_by: Some(Utc::now()),
        disputed_at: Some(Utc::now()),
        resolved_at: None,
    };

    repo.upsert(&input)
        .await
        .expect("initial upsert with invoice");

    input.status = "won".to_string();
    input.invoice_id = None;
    input.resolved_at = Some(Utc::now());

    let updated = repo
        .upsert(&input)
        .await
        .expect("status transition upsert without invoice id");

    assert_eq!(updated.status, "won");
    assert_eq!(
        updated.invoice_id,
        Some(invoice_id),
        "NULL invoice_id input must not clear a previously resolved invoice link"
    );
}

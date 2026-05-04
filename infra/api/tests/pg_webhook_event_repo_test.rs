/// SQL integration tests for PgWebhookEventRepo.
///
/// Catches the production bug found 2026-05-03 by the Phase G live invoice
/// probe: `find_latest_invoice_id_by_payment_intent` previously used
/// `fetch_one` which errors with RowNotFound on zero rows, so a charge.refunded
/// webhook for a payment_intent we'd never processed returned 500 to Stripe.
/// The mock repo returned None correctly, so unit tests with mocks passed
/// through this path silently — only the live Postgres path surfaced the bug.
///
/// This test file exercises the real `PgWebhookEventRepo` against a Postgres
/// pool to lock in the contract: zero matching rows must return Ok(None), not
/// Err(RowNotFound).
///
/// ## Running
///
///   DATABASE_URL=postgres://user:pass@localhost/flapjack_test \
///     cargo test -p api --test pg_webhook_event_repo_test
///
/// If DATABASE_URL is not set, all tests are skipped.
use api::repos::{PgWebhookEventRepo, WebhookEventRepo};
use sqlx::PgPool;

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping PgWebhookEventRepo SQL tests");
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

#[tokio::test]
async fn find_latest_invoice_id_by_payment_intent_returns_none_when_no_rows() {
    // Regression: previously used fetch_one which errors with RowNotFound on
    // zero rows. Must return Ok(None) so the caller (charge.refunded handler)
    // can fall through to its next lookup strategy and ack the webhook.
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let repo = PgWebhookEventRepo::new(pool.clone());

    // Use a payment_intent id with a uuid suffix so it cannot collide with any
    // real test data — guarantees zero matching rows for the SQL filter.
    let pi_id = format!("pi_test_unknown_{}", uuid::Uuid::new_v4().simple());
    let result = repo.find_latest_invoice_id_by_payment_intent(&pi_id).await;
    assert!(
        result.is_ok(),
        "fetch_optional path must return Ok(None) on zero rows, not Err(RowNotFound). Got: {result:?}"
    );
    assert_eq!(
        result.unwrap(),
        None,
        "no matching webhook event seeded — must return None"
    );
}

#[tokio::test]
async fn find_latest_invoice_id_by_payment_intent_finds_seeded_row() {
    // Positive: seed an invoice.payment_succeeded event then look it up.
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let repo = PgWebhookEventRepo::new(pool.clone());

    let pi_id = format!("pi_test_seeded_{}", uuid::Uuid::new_v4().simple());
    let invoice_id = format!("in_test_seed_{}", uuid::Uuid::new_v4().simple());
    let event_id = format!("evt_test_{}", uuid::Uuid::new_v4().simple());
    // Build a payload with the precise JSONB shape the lookup query queries:
    // payload.data.object.id (= invoice id) and payload.data.object.payment_intent.
    let payload = serde_json::json!({
        "data": {
            "object": {
                "id": invoice_id,
                "payment_intent": pi_id,
            }
        }
    });

    repo.try_insert(&event_id, "invoice.payment_succeeded", &payload)
        .await
        .expect("seed insert");

    let result = repo
        .find_latest_invoice_id_by_payment_intent(&pi_id)
        .await
        .expect("lookup");
    assert_eq!(
        result,
        Some(invoice_id.clone()),
        "must find the seeded invoice id"
    );

    // Cleanup
    sqlx::query("DELETE FROM webhook_events WHERE stripe_event_id = $1")
        .bind(&event_id)
        .execute(&pool)
        .await
        .ok();
}

#[tokio::test]
async fn find_by_stripe_event_id_returns_none_when_no_rows() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let repo = PgWebhookEventRepo::new(pool);
    let missing_id = format!("evt_test_missing_{}", uuid::Uuid::new_v4().simple());

    let result = repo.find_by_stripe_event_id(&missing_id).await;
    assert!(
        result.is_ok(),
        "lookup on zero rows must return Ok(None), got: {result:?}"
    );
    assert_eq!(result.unwrap(), None);
}

#[tokio::test]
async fn find_by_stripe_event_id_returns_seeded_row_shape() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let repo = PgWebhookEventRepo::new(pool.clone());
    let event_id = format!("evt_test_lookup_{}", uuid::Uuid::new_v4().simple());
    let event_type = "invoice.payment_succeeded";
    let payload = serde_json::json!({
        "data": {
            "object": {
                "id": format!("in_test_{}", uuid::Uuid::new_v4().simple()),
                "payment_intent": format!("pi_test_{}", uuid::Uuid::new_v4().simple()),
            }
        }
    });

    repo.try_insert(&event_id, event_type, &payload)
        .await
        .expect("seed webhook row");
    repo.mark_processed(&event_id)
        .await
        .expect("mark webhook row processed");

    let row = repo
        .find_by_stripe_event_id(&event_id)
        .await
        .expect("lookup seeded webhook row")
        .expect("seeded row should exist");

    assert_eq!(row.stripe_event_id, event_id);
    assert_eq!(row.event_type, event_type);
    assert_eq!(row.payload, payload);
    assert!(
        row.processed_at.is_some(),
        "processed row must have processed_at timestamp"
    );

    sqlx::query("DELETE FROM webhook_events WHERE stripe_event_id = $1")
        .bind(&event_id)
        .execute(&pool)
        .await
        .ok();
}

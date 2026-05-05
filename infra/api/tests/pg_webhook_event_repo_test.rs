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

mod support;

use support::pg_schema_harness::{self, DbHarness};

async fn connect_and_migrate() -> Option<DbHarness> {
    pg_schema_harness::connect_and_migrate("it_pg_webhook_event_repo").await
}

#[tokio::test]
async fn find_latest_invoice_id_by_payment_intent_returns_none_when_no_rows() {
    // Regression: previously used fetch_one which errors with RowNotFound on
    // zero rows. Must return Ok(None) so the caller (charge.refunded handler)
    // can fall through to its next lookup strategy and ack the webhook.
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

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
async fn try_insert_same_event_id_has_single_winner_under_concurrency() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

    let repo = PgWebhookEventRepo::new(pool.clone());
    let event_id = format!("evt_test_dupe_{}", uuid::Uuid::new_v4().simple());
    let payload = serde_json::json!({
        "data": {
            "object": {
                "id": format!("in_test_dupe_{}", uuid::Uuid::new_v4().simple()),
            }
        }
    });

    let (first, second) = tokio::join!(
        repo.try_insert(&event_id, "invoice.payment_succeeded", &payload),
        repo.try_insert(&event_id, "invoice.payment_succeeded", &payload),
    );

    let first = first.expect("first insert attempt should not error");
    let second = second.expect("second insert attempt should not error");
    assert!(
        (first && !second) || (!first && second),
        "exactly one concurrent caller must win try_insert; got first={first}, second={second}"
    );

    let persisted_rows = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM webhook_events WHERE stripe_event_id = $1",
    )
    .bind(&event_id)
    .fetch_one(&pool)
    .await
    .expect("count persisted webhook rows");
    assert_eq!(
        persisted_rows, 1,
        "exactly one webhook_events row must exist for a stripe_event_id"
    );

    sqlx::query("DELETE FROM webhook_events WHERE stripe_event_id = $1")
        .bind(&event_id)
        .execute(&pool)
        .await
        .ok();
}

#[tokio::test]
async fn find_latest_invoice_id_by_payment_intent_finds_seeded_row() {
    // Positive: seed an invoice.payment_succeeded event then look it up.
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

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
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

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
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

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

/// SQL integration tests for PgCustomerRepo data contracts.
use api::models::IngestQuotaWarningMetric;
use api::repos::{CustomerRepo, PgCustomerRepo, ResendVerificationOutcome};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sqlx::PgPool;
use std::sync::Arc;
use uuid::Uuid;

use crate::common::support::pg_schema_harness;

async fn cleanup_customer(pool: &PgPool, email: &str) {
    sqlx::query("DELETE FROM customers WHERE email = $1")
        .bind(email)
        .execute(pool)
        .await
        .ok();
}

async fn cleanup_customer_graph(pool: &PgPool, customer_ids: &[Uuid]) {
    sqlx::query("DELETE FROM customer_tenants WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_deployments WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM subscriptions WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM invoices WHERE customer_id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customers WHERE id = ANY($1)")
        .bind(customer_ids.to_vec())
        .execute(pool)
        .await
        .ok();
}

/// Minimal row shape used to inspect retention metadata directly from SQL.
#[derive(sqlx::FromRow)]
struct CustomerDeletionMetadataRaw {
    #[allow(dead_code)]
    id: Uuid,
    updated_at: chrono::DateTime<chrono::Utc>,
    deleted_at: Option<chrono::DateTime<chrono::Utc>>,
}

/// Reads deletion metadata via a schema-tolerant projection so the test can
/// fail on missing behavior without requiring Stage 2 schema changes first.
async fn fetch_customer_deletion_metadata(pool: &PgPool, id: Uuid) -> CustomerDeletionMetadataRaw {
    sqlx::query_as(
        "SELECT \
            id, \
            updated_at, \
            (to_jsonb(customers)->>'deleted_at')::timestamptz AS deleted_at \
         FROM customers \
         WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("fetch customer deletion metadata")
}

async fn force_deleted_at_for_ids(
    pool: &PgPool,
    ids: &[Uuid],
    deleted_at: chrono::DateTime<chrono::Utc>,
) {
    sqlx::query("UPDATE customers SET deleted_at = $1, updated_at = $1 WHERE id = ANY($2)")
        .bind(deleted_at)
        .bind(ids.to_vec())
        .execute(pool)
        .await
        .expect("force deleted_at fixture timestamp for deterministic tie-break test");
}

async fn set_resend_verification_sent_at(
    pool: &PgPool,
    id: Uuid,
    resend_verification_sent_at: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar(
        "UPDATE customers \
         SET resend_verification_sent_at = $2, updated_at = NOW() \
         WHERE id = $1 \
         RETURNING resend_verification_sent_at",
    )
    .bind(id)
    .bind(resend_verification_sent_at)
    .fetch_one(pool)
    .await
    .expect("seed resend_verification_sent_at fixture timestamp")
}

async fn set_resend_password_reset_sent_at(
    pool: &PgPool,
    id: Uuid,
    resend_password_reset_sent_at: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar(
        "UPDATE customers \
         SET resend_password_reset_sent_at = $2, updated_at = NOW() \
         WHERE id = $1 \
         RETURNING resend_password_reset_sent_at",
    )
    .bind(id)
    .bind(resend_password_reset_sent_at)
    .fetch_one(pool)
    .await
    .expect("seed resend_password_reset_sent_at fixture timestamp")
}

#[tokio::test]
async fn subscription_cycle_anchor_round_trip_and_clear_with_none() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "anchor-roundtrip-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Anchor Roundtrip", &email)
        .await
        .expect("create customer");
    let first_anchor = chrono::Utc::now();

    let set_result = repo
        .set_subscription_cycle_anchor(customer.id, Some(first_anchor))
        .await
        .expect("set initial subscription anchor");
    assert!(
        set_result,
        "setting anchor should update active customer rows"
    );

    let after_set = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after anchor set")
        .expect("customer should exist after anchor set");
    assert_eq!(
        after_set.subscription_cycle_anchor_at,
        Some(first_anchor),
        "anchor setter must persist the exact timestamp"
    );

    let clear_result = repo
        .set_subscription_cycle_anchor(customer.id, None)
        .await
        .expect("clear subscription anchor");
    assert!(
        clear_result,
        "clearing anchor should update active customer rows"
    );

    let after_clear = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after anchor clear")
        .expect("customer should exist after anchor clear");
    assert_eq!(
        after_clear.subscription_cycle_anchor_at, None,
        "anchor setter must clear the persisted value when None is provided"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn try_upgrade_to_shared_atomic_allows_exactly_one_concurrent_winner() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "atomic-upgrade-race-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Atomic Upgrade Race", &email)
        .await
        .expect("create customer");
    let base_anchor = chrono::Utc::now();
    let mut join_handles = Vec::new();
    for offset_ms in 0_i64..8_i64 {
        let pooled_repo = PgCustomerRepo::new(pool.clone());
        let candidate_anchor = base_anchor + chrono::Duration::milliseconds(offset_ms);
        join_handles.push(tokio::spawn(async move {
            let won = pooled_repo
                .try_upgrade_to_shared_atomic(customer.id, candidate_anchor)
                .await
                .expect("attempt atomic free-to-shared upgrade");
            (candidate_anchor, won)
        }));
    }

    let mut winning_anchor: Option<chrono::DateTime<chrono::Utc>> = None;
    let mut winner_count = 0_usize;
    for handle in join_handles {
        let (candidate_anchor, won) = handle
            .await
            .expect("join concurrent atomic-upgrade attempt");
        if won {
            winner_count += 1;
            winning_anchor = Some(candidate_anchor);
        }
    }

    assert_eq!(
        winner_count, 1,
        "compare-and-set upgrade seam must allow exactly one winner under concurrency"
    );

    let upgraded_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find customer after concurrent upgrade race")
        .expect("customer should still exist after concurrent upgrade race");
    assert_eq!(
        upgraded_customer.billing_plan, "shared",
        "winning atomic update must persist shared plan"
    );
    assert_eq!(
        upgraded_customer.subscription_cycle_anchor_at, winning_anchor,
        "winning atomic update must persist the winner's anchor timestamp"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn try_upgrade_to_shared_atomic_returns_false_without_mutation_for_shared_or_deleted_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let already_shared_email = format!(
        "atomic-upgrade-shared-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let deleted_email = format!(
        "atomic-upgrade-deleted-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let already_shared = repo
        .create("Already Shared", &already_shared_email)
        .await
        .expect("create already-shared fixture");
    let deleted = repo
        .create("Deleted Fixture", &deleted_email)
        .await
        .expect("create deleted fixture");

    let preexisting_anchor = chrono::Utc::now() - chrono::Duration::hours(6);
    repo.set_billing_plan(already_shared.id, "shared")
        .await
        .expect("set already-shared plan fixture");
    repo.set_subscription_cycle_anchor(already_shared.id, Some(preexisting_anchor))
        .await
        .expect("seed already-shared anchor fixture");
    repo.soft_delete(deleted.id)
        .await
        .expect("soft-delete deleted fixture");

    let shared_attempt_anchor = chrono::Utc::now();
    let shared_attempt = repo
        .try_upgrade_to_shared_atomic(already_shared.id, shared_attempt_anchor)
        .await
        .expect("attempt atomic upgrade on already-shared row");
    assert!(
        !shared_attempt,
        "atomic upgrade should return false when row is already shared"
    );
    let already_shared_after = repo
        .find_by_id(already_shared.id)
        .await
        .expect("reload already-shared row")
        .expect("already-shared row should still exist");
    assert_eq!(
        already_shared_after.billing_plan, "shared",
        "failed upgrade attempt must not change already-shared billing plan"
    );
    assert_eq!(
        already_shared_after.subscription_cycle_anchor_at,
        Some(preexisting_anchor),
        "failed upgrade attempt must preserve existing anchor on already-shared row"
    );

    let deleted_attempt = repo
        .try_upgrade_to_shared_atomic(deleted.id, chrono::Utc::now())
        .await
        .expect("attempt atomic upgrade on deleted row");
    assert!(
        !deleted_attempt,
        "atomic upgrade should return false when row is soft-deleted"
    );
    let deleted_after = repo
        .find_by_id(deleted.id)
        .await
        .expect("reload deleted row")
        .expect("deleted row should still exist as retained row");
    assert_eq!(deleted_after.status, "deleted");
    assert_eq!(
        deleted_after.billing_plan, "free",
        "failed upgrade on deleted row must not mutate billing plan"
    );
    assert_eq!(
        deleted_after.subscription_cycle_anchor_at, None,
        "failed upgrade on deleted row must not set anchor"
    );

    cleanup_customer(&pool, &already_shared_email).await;
    cleanup_customer(&pool, &deleted_email).await;
}

#[tokio::test]
async fn claim_ingest_quota_warning_is_monthly_per_metric_and_atomic() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "quota-warning-claim-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Quota Warning Claim", &email)
        .await
        .expect("create customer");

    let first_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("first records warning claim");
    assert!(
        first_records_claim,
        "first claim for metric/month should succeed"
    );

    let duplicate_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("duplicate records warning claim");
    assert!(
        !duplicate_records_claim,
        "duplicate claim for same metric/month should fail atomically"
    );

    let storage_claim_same_month = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::StorageMb,
            2026,
            5,
        )
        .await
        .expect("storage warning claim in same month");
    assert!(
        storage_claim_same_month,
        "different metric in same month should claim independently"
    );

    let next_month_records_claim = repo
        .claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            6,
        )
        .await
        .expect("records warning claim in next month");
    assert!(
        next_month_records_claim,
        "same metric should claim again next month"
    );

    let sent_for_may_records = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("read records warning state for may");
    assert!(
        !sent_for_may_records,
        "recorded month should move forward after next-month claim"
    );

    let sent_for_june_records = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            6,
        )
        .await
        .expect("read records warning state for june");
    assert!(
        sent_for_june_records,
        "latest claimed month should be readable for matching metric"
    );

    let sent_for_may_storage = repo
        .ingest_quota_warning_sent_for_month(
            customer.id,
            IngestQuotaWarningMetric::StorageMb,
            2026,
            5,
        )
        .await
        .expect("read storage warning state for may");
    assert!(
        sent_for_may_storage,
        "storage warning state should remain independent from records state"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_ingest_quota_warning_reopens_same_month_claim() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "quota-warning-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Quota Warning Rollback", &email)
        .await
        .expect("create customer");

    assert!(
        repo.claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("initial claim"),
        "initial claim should reserve the records warning slot"
    );

    assert!(
        repo.rollback_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("rollback claim"),
        "rollback should clear the current month reservation"
    );

    assert!(
        !repo
            .ingest_quota_warning_sent_for_month(
                customer.id,
                IngestQuotaWarningMetric::Records,
                2026,
                5,
            )
            .await
            .expect("read rolled back month state"),
        "rolled back month should no longer appear claimed"
    );

    assert!(
        repo.claim_ingest_quota_warning_for_month(
            customer.id,
            IngestQuotaWarningMetric::Records,
            2026,
            5,
        )
        .await
        .expect("reclaim same month"),
        "same month should become claimable again after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn create_customer_has_zero_carryforward() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cf-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("CF Test", &email)
        .await
        .expect("create customer");
    assert_eq!(
        customer.object_storage_egress_carryforward_cents,
        Decimal::ZERO,
        "new customer carry-forward must default to zero"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn create_with_password_has_zero_carryforward() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfpw-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("CF PW Test", &email, "$argon2id$test_hash")
        .await
        .expect("create customer with password");
    assert_eq!(
        customer.object_storage_egress_carryforward_cents,
        Decimal::ZERO,
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn set_and_read_carryforward_round_trips() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfrt-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo.create("CF Round-Trip", &email).await.expect("create");

    // Set a sub-cent carry-forward value
    let ok = repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(0.3712))
        .await
        .expect("set carryforward");
    assert!(ok, "setter should return true for existing active customer");

    // Read it back via find_by_id
    let updated = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id")
        .expect("customer must exist");
    assert_eq!(
        updated.object_storage_egress_carryforward_cents,
        dec!(0.3712),
        "carry-forward must round-trip through Postgres"
    );

    // Also verify find_by_email sees the same value
    let by_email = repo
        .find_by_email(&email)
        .await
        .expect("find_by_email")
        .expect("customer must exist");
    assert_eq!(
        by_email.object_storage_egress_carryforward_cents,
        dec!(0.3712),
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn set_carryforward_on_deleted_customer_returns_false() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "cfdel-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo.create("CF Deleted", &email).await.expect("create");
    repo.soft_delete(customer.id).await.expect("soft_delete");

    let ok = repo
        .set_object_storage_egress_carryforward_cents(customer.id, dec!(1.5))
        .await
        .expect("set carryforward on deleted");
    assert!(!ok, "setter must return false for deleted customer");

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn resend_verification_cooldown_persists_across_repo_reload() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let first_repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-cooldown-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = first_repo
        .create("Resend Cooldown", &email)
        .await
        .expect("create customer");

    let first_outcome = first_repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "first-token",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("first resend token rotation");
    assert!(
        matches!(first_outcome, ResendVerificationOutcome::Allowed { .. }),
        "first resend should be allowed"
    );

    let customer_after_first_send = first_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after first resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_first_send.email_verify_token.as_deref(),
        Some("first-token"),
        "first resend should persist the token on the customer row"
    );
    assert!(
        customer_after_first_send
            .resend_verification_sent_at
            .is_some(),
        "first resend should stamp cooldown state on the customer row"
    );

    let reloaded_repo = PgCustomerRepo::new(pool.clone());
    let second_outcome = reloaded_repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "second-token",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("second resend token rotation");

    match second_outcome {
        ResendVerificationOutcome::CooldownActive {
            retry_after_seconds,
        } => {
            assert!(
                (1..=60).contains(&retry_after_seconds),
                "retry_after_seconds should stay within the 60-second cooldown window"
            );
        }
        unexpected => panic!(
            "immediate second resend after repo reload should be blocked by cooldown, got {unexpected:?}"
        ),
    }

    let customer_after_second_attempt = reloaded_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after blocked resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_second_attempt.email_verify_token.as_deref(),
        Some("first-token"),
        "blocked resend must not rotate the token again"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_resend_verification_restores_previous_token_and_cooldown_state() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create("Resend Rollback", &email)
        .await
        .expect("create customer");
    let previous_expiry = chrono::Utc::now() + chrono::Duration::hours(24);
    let historical_cooldown_timestamp = chrono::Utc::now()
        - chrono::Duration::seconds(api::repos::RESEND_VERIFICATION_COOLDOWN_SECONDS + 5);
    let previous_token = "last-deliverable-token";
    let reserved_token = "reserved-token";

    let seeded = repo
        .set_email_verify_token(customer.id, previous_token, previous_expiry)
        .await
        .expect("seed last deliverable token");
    assert!(seeded, "fixture seed should update an active customer");
    let seeded_cooldown_timestamp =
        set_resend_verification_sent_at(&pool, customer.id, historical_cooldown_timestamp).await;

    let reservation = match repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            reserved_token,
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("reserve resend token")
    {
        ResendVerificationOutcome::Allowed { reservation } => reservation,
        unexpected => panic!("first resend reservation should be allowed, got {unexpected:?}"),
    };
    assert_eq!(
        reservation.previous_resend_verification_sent_at,
        Some(seeded_cooldown_timestamp),
        "reservation should carry the prior non-NULL cooldown timestamp for rollback"
    );
    assert!(
        reservation.reserved_resend_verification_sent_at
            > reservation
                .previous_resend_verification_sent_at
                .unwrap_or(chrono::DateTime::<chrono::Utc>::MIN_UTC),
        "reservation should stamp a fresh resend cooldown timestamp"
    );

    let rolled_back = repo
        .rollback_resend_verification_token_rotation(customer.id, reserved_token, &reservation)
        .await
        .expect("rollback resend reservation");
    assert!(
        rolled_back,
        "rollback should restore prior values when reservation still matches"
    );

    let after_rollback = repo
        .find_by_id(customer.id)
        .await
        .expect("load customer after rollback")
        .expect("customer should exist");
    assert_eq!(
        after_rollback.email_verify_token.as_deref(),
        Some(previous_token),
        "rollback should restore the last deliverable token"
    );
    assert_eq!(
        after_rollback.email_verify_expires_at,
        Some(previous_expiry),
        "rollback should restore the prior token expiry"
    );
    assert_eq!(
        after_rollback.resend_verification_sent_at,
        reservation.previous_resend_verification_sent_at,
        "rollback should restore the previous cooldown timestamp"
    );

    let immediate_retry = repo
        .rotate_email_verification_token_with_resend_cooldown(
            customer.id,
            "retry-token-after-rollback",
            chrono::Utc::now() + chrono::Duration::hours(24),
        )
        .await
        .expect("retry resend after rollback");
    assert!(
        matches!(immediate_retry, ResendVerificationOutcome::Allowed { .. }),
        "customer should be able to retry immediately after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn resend_password_reset_cooldown_persists_across_repo_reload() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let first_repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-password-reset-cooldown-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = first_repo
        .create("Resend Password Reset Cooldown", &email)
        .await
        .expect("create customer");

    let first_outcome = first_repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "first-reset-token",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("first password reset resend token rotation");
    assert!(
        matches!(
            first_outcome,
            api::repos::ResendPasswordResetOutcome::Allowed { .. }
        ),
        "first reset resend should be allowed"
    );

    let customer_after_first_send = first_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after first reset resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_first_send.password_reset_token.as_deref(),
        Some("first-reset-token"),
        "first reset resend should persist the token on the customer row"
    );
    assert!(
        customer_after_first_send
            .resend_password_reset_sent_at
            .is_some(),
        "first reset resend should stamp cooldown state on the customer row"
    );

    let reloaded_repo = PgCustomerRepo::new(pool.clone());
    let second_outcome = reloaded_repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "second-reset-token",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("second password reset resend token rotation");

    match second_outcome {
        api::repos::ResendPasswordResetOutcome::CooldownActive {
            retry_after_seconds,
        } => {
            assert!(
                (1..=60).contains(&retry_after_seconds),
                "retry_after_seconds should stay within the 60-second cooldown window"
            );
        }
        unexpected => panic!(
            "immediate second reset resend after repo reload should be blocked by cooldown, got {unexpected:?}"
        ),
    }

    let customer_after_second_attempt = reloaded_repo
        .find_by_id(customer.id)
        .await
        .expect("reload customer after blocked reset resend")
        .expect("customer should exist");
    assert_eq!(
        customer_after_second_attempt
            .password_reset_token
            .as_deref(),
        Some("first-reset-token"),
        "blocked reset resend must not rotate the token again"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn rollback_password_reset_resend_restores_previous_token_and_cooldown_state() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "resend-password-reset-rollback-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Resend Reset Rollback", &email, "$argon2id$seed")
        .await
        .expect("create customer");
    let previous_expiry = chrono::Utc::now() + chrono::Duration::hours(1);
    let historical_cooldown_timestamp = chrono::Utc::now()
        - chrono::Duration::seconds(api::repos::RESEND_VERIFICATION_COOLDOWN_SECONDS + 5);
    let previous_token = "deliverable-reset-token";
    let reserved_token = "reserved-reset-token";

    let seeded = repo
        .set_password_reset_token(customer.id, previous_token, previous_expiry)
        .await
        .expect("seed last deliverable reset token");
    assert!(seeded, "fixture seed should update an active customer");
    let seeded_cooldown_timestamp =
        set_resend_password_reset_sent_at(&pool, customer.id, historical_cooldown_timestamp).await;

    let reservation = match repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            reserved_token,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("reserve password reset resend token")
    {
        api::repos::ResendPasswordResetOutcome::Allowed { reservation } => reservation,
        unexpected => {
            panic!("first password reset reservation should be allowed, got {unexpected:?}")
        }
    };
    assert_eq!(
        reservation.previous_password_reset_sent_at,
        Some(seeded_cooldown_timestamp),
        "reservation should carry the prior non-NULL password-reset cooldown timestamp for rollback"
    );
    assert!(
        reservation.reserved_password_reset_sent_at
            > reservation
                .previous_password_reset_sent_at
                .unwrap_or(chrono::DateTime::<chrono::Utc>::MIN_UTC),
        "reservation should stamp a fresh password-reset resend cooldown timestamp"
    );

    let rolled_back = repo
        .rollback_password_reset_token_rotation(customer.id, reserved_token, &reservation)
        .await
        .expect("rollback password reset resend reservation");
    assert!(
        rolled_back,
        "rollback should restore prior values when password-reset reservation still matches"
    );

    let after_rollback = repo
        .find_by_id(customer.id)
        .await
        .expect("load customer after rollback")
        .expect("customer should exist");
    assert_eq!(
        after_rollback.password_reset_token.as_deref(),
        Some(previous_token),
        "rollback should restore the last deliverable reset token"
    );
    assert_eq!(
        after_rollback.password_reset_expires_at,
        Some(previous_expiry),
        "rollback should restore the prior reset token expiry"
    );
    assert_eq!(
        after_rollback.resend_password_reset_sent_at, reservation.previous_password_reset_sent_at,
        "rollback should restore the previous password-reset cooldown timestamp"
    );

    let immediate_retry = repo
        .rotate_password_reset_token_with_resend_cooldown(
            customer.id,
            "retry-reset-token-after-rollback",
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("retry password reset resend after rollback");
    assert!(
        matches!(
            immediate_retry,
            api::repos::ResendPasswordResetOutcome::Allowed { .. }
        ),
        "customer should be able to retry password-reset resend immediately after rollback"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn soft_delete_retains_row_and_is_idempotent() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "soft-delete-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Soft Delete Test", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    let first_delete = repo
        .soft_delete(customer.id)
        .await
        .expect("first soft_delete");
    assert!(first_delete, "first soft_delete should return true");

    let first_delete_metadata = fetch_customer_deletion_metadata(&pool, customer.id).await;
    let first_deleted_at = first_delete_metadata
        .deleted_at
        .expect("first soft_delete should stamp deleted_at for retained-row metadata");
    assert_eq!(
        first_deleted_at, first_delete_metadata.updated_at,
        "first soft_delete should stamp deleted_at and updated_at together"
    );

    let retained_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after soft_delete")
        .expect("soft-deleted row should still be retained");
    assert_eq!(retained_customer.status, "deleted");
    assert_eq!(retained_customer.email, email);

    let second_delete = repo
        .soft_delete(customer.id)
        .await
        .expect("second soft_delete");
    assert!(
        !second_delete,
        "second soft_delete should return false for an already-deleted row"
    );

    let second_delete_metadata = fetch_customer_deletion_metadata(&pool, customer.id).await;
    assert_eq!(
        second_delete_metadata.deleted_at,
        Some(first_deleted_at),
        "second soft_delete must be idempotent and not re-stamp deleted_at"
    );
    assert_eq!(
        second_delete_metadata.updated_at, first_delete_metadata.updated_at,
        "second soft_delete must not change updated_at once the row is already deleted"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn deleted_customer_cutoff_selector_filters_and_orders_by_deleted_at_then_id() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_deleted_email = format!(
        "soft-delete-cutoff-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_deleted_email = format!(
        "soft-delete-cutoff-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let active_email = format!(
        "soft-delete-cutoff-active-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first_deleted = repo
        .create("Cutoff First", &first_deleted_email)
        .await
        .expect("create first deleted customer");
    let second_deleted = repo
        .create("Cutoff Second", &second_deleted_email)
        .await
        .expect("create second deleted customer");
    let active_customer = repo
        .create("Cutoff Active", &active_email)
        .await
        .expect("create active customer");

    repo.soft_delete(first_deleted.id)
        .await
        .expect("soft delete first customer");
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    repo.soft_delete(second_deleted.id)
        .await
        .expect("soft delete second customer");

    let first_deleted_at = fetch_customer_deletion_metadata(&pool, first_deleted.id)
        .await
        .deleted_at
        .expect("first deleted customer should have deleted_at stamped");
    let second_deleted_at = fetch_customer_deletion_metadata(&pool, second_deleted.id)
        .await
        .deleted_at
        .expect("second deleted customer should have deleted_at stamped");

    let at_first_cutoff = repo
        .list_deleted_before_cutoff(first_deleted_at)
        .await
        .expect("list deleted before first cutoff");
    assert_eq!(
        at_first_cutoff.len(),
        1,
        "cutoff selector should include only rows deleted on/before the cutoff"
    );
    assert_eq!(
        at_first_cutoff[0].id, first_deleted.id,
        "earliest deleted row should be selected first"
    );
    assert_eq!(
        at_first_cutoff[0].deleted_at,
        Some(first_deleted_at),
        "repo selector should project deleted_at on retained rows"
    );

    let at_second_cutoff = repo
        .list_deleted_before_cutoff(second_deleted_at)
        .await
        .expect("list deleted before second cutoff");
    assert_eq!(
        at_second_cutoff
            .iter()
            .map(|row| row.id)
            .collect::<Vec<_>>(),
        vec![first_deleted.id, second_deleted.id],
        "selector should deterministically order by deleted_at ASC, id ASC"
    );
    assert!(
        at_second_cutoff
            .iter()
            .all(|row| row.id != active_customer.id),
        "selector must never include active customers"
    );
    assert!(
        at_second_cutoff.iter().all(|row| row.deleted_at.is_some()),
        "selector should only include rows with deleted_at populated"
    );
    assert!(
        at_second_cutoff[0].deleted_at <= at_second_cutoff[1].deleted_at,
        "selector output must be monotonic by deleted_at"
    );

    cleanup_customer(&pool, &first_deleted_email).await;
    cleanup_customer(&pool, &second_deleted_email).await;
    cleanup_customer(&pool, &active_email).await;
}

#[tokio::test]
async fn deleted_customer_cutoff_selector_tie_breaks_equal_deleted_at_by_id() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_deleted_email = format!(
        "soft-delete-cutoff-tie-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_deleted_email = format!(
        "soft-delete-cutoff-tie-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first_deleted = repo
        .create("Cutoff Tie First", &first_deleted_email)
        .await
        .expect("create first deleted customer");
    let second_deleted = repo
        .create("Cutoff Tie Second", &second_deleted_email)
        .await
        .expect("create second deleted customer");

    repo.soft_delete(first_deleted.id)
        .await
        .expect("soft delete first customer");
    repo.soft_delete(second_deleted.id)
        .await
        .expect("soft delete second customer");

    let shared_deleted_at = chrono::Utc::now();
    force_deleted_at_for_ids(
        &pool,
        &[first_deleted.id, second_deleted.id],
        shared_deleted_at,
    )
    .await;

    let tied_rows = repo
        .list_deleted_before_cutoff(shared_deleted_at)
        .await
        .expect("list deleted rows at tie cutoff");
    let expected_ids = {
        let mut ids = vec![first_deleted.id, second_deleted.id];
        ids.sort();
        ids
    };
    assert_eq!(
        tied_rows.len(),
        2,
        "selector should return exactly the two seeded deleted rows for the tie case"
    );
    assert_eq!(
        tied_rows.iter().map(|row| row.id).collect::<Vec<_>>(),
        expected_ids,
        "when deleted_at timestamps are equal, selector must tie-break by id ASC"
    );
    let tied_deleted_ats: Vec<_> = tied_rows
        .iter()
        .map(|row| row.deleted_at.expect("deleted rows must carry deleted_at"))
        .collect();
    assert!(
        tied_deleted_ats[0] == tied_deleted_ats[1],
        "fixture override should create an equal deleted_at tie for all selected rows"
    );

    cleanup_customer(&pool, &first_deleted_email).await;
    cleanup_customer(&pool, &second_deleted_email).await;
}

#[tokio::test]
async fn list_aggregates_billing_health_inputs_without_duplicate_customer_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_email = format!(
        "list-health-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_email = format!(
        "list-health-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first = repo
        .create("List Health First", &first_email)
        .await
        .expect("create first customer");
    let second = repo
        .create("List Health Second", &second_email)
        .await
        .expect("create second customer");

    let first_deployment_id = Uuid::new_v4();
    let second_deployment_id = Uuid::new_v4();
    let first_short = &first.id.to_string()[..8];
    let second_short = &second.id.to_string()[..8];

    sqlx::query(
        "INSERT INTO customer_deployments (id, customer_id, node_id, region, vm_type, vm_provider) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(first_deployment_id)
    .bind(first.id)
    .bind(format!("node-list-health-{first_short}"))
    .bind("us-east-1")
    .bind("t4g.small")
    .bind("aws")
    .execute(&pool)
    .await
    .expect("insert first deployment");

    sqlx::query(
        "INSERT INTO customer_deployments (id, customer_id, node_id, region, vm_type, vm_provider) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(second_deployment_id)
    .bind(second.id)
    .bind(format!("node-list-health-{second_short}"))
    .bind("us-east-1")
    .bind("t4g.small")
    .bind("aws")
    .execute(&pool)
    .await
    .expect("insert second deployment");

    let older_access = chrono::Utc::now() - chrono::Duration::hours(4);
    let newest_access = chrono::Utc::now() - chrono::Duration::minutes(5);
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, last_accessed_at) \
         VALUES ($1, $2, $3, $4), ($5, $6, $7, $8), ($9, $10, $11, $12)",
    )
    .bind(first.id)
    .bind(format!("tenant-list-health-a-{first_short}"))
    .bind(first_deployment_id)
    .bind(older_access)
    .bind(first.id)
    .bind(format!("tenant-list-health-b-{first_short}"))
    .bind(first_deployment_id)
    .bind(newest_access)
    .bind(second.id)
    .bind(format!("tenant-list-health-a-{second_short}"))
    .bind(second_deployment_id)
    .bind(chrono::Utc::now() - chrono::Duration::minutes(30))
    .execute(&pool)
    .await
    .expect("insert tenant rows");

    sqlx::query(
        "INSERT INTO invoices (customer_id, period_start, period_end, subtotal_cents, total_cents, status) \
         VALUES \
            ($1, DATE '2026-01-01', DATE '2026-01-31', 100, 100, 'failed'), \
            ($2, DATE '2026-02-01', DATE '2026-02-28', 200, 200, 'failed'), \
            ($3, DATE '2026-03-01', DATE '2026-03-31', 300, 300, 'paid'), \
            ($4, DATE '2026-01-01', DATE '2026-01-31', 100, 100, 'paid')",
    )
    .bind(first.id)
    .bind(first.id)
    .bind(first.id)
    .bind(second.id)
    .execute(&pool)
    .await
    .expect("insert invoice rows");

    let list = repo.list().await.expect("list customers");
    let seeded_rows: Vec<_> = list
        .into_iter()
        .filter(|row| row.id == first.id || row.id == second.id)
        .collect();
    assert_eq!(
        seeded_rows.len(),
        2,
        "list must return exactly one row per customer even with multi-row joins"
    );

    let first_row = seeded_rows
        .iter()
        .find(|row| row.id == first.id)
        .expect("first seeded customer should be in list output");
    assert_eq!(
        first_row.last_accessed_at,
        Some(newest_access),
        "list should project MAX(customer_tenants.last_accessed_at) per customer"
    );
    assert_eq!(
        first_row.overdue_invoice_count, 2,
        "list should count only failed invoices for overdue tally"
    );

    let second_row = seeded_rows
        .iter()
        .find(|row| row.id == second.id)
        .expect("second seeded customer should be in list output");
    assert!(
        second_row.last_accessed_at.is_some(),
        "customer with one tenant should project that tenant's last_accessed_at"
    );
    assert_eq!(
        second_row.overdue_invoice_count, 0,
        "customer with no failed invoices should have overdue_invoice_count = 0"
    );

    cleanup_customer_graph(&pool, &[first.id, second.id]).await;
}

#[tokio::test]
async fn oauth_identity_lookup_returns_linked_customer() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "oauth-lookup-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_oauth_customer("OAuth Lookup", &email)
        .await
        .expect("create oauth customer");

    repo.link_oauth_identity(customer.id, "google", "google-user-lookup")
        .await
        .expect("link oauth identity");

    let found = repo
        .find_oauth_identity("google", "google-user-lookup")
        .await
        .expect("lookup oauth identity")
        .expect("linked identity should resolve to customer");
    assert_eq!(found.id, customer.id);

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

#[tokio::test]
async fn oauth_identity_link_enforces_provider_user_uniqueness() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let first_email = format!(
        "oauth-first-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let second_email = format!(
        "oauth-second-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let first = repo
        .create_oauth_customer("OAuth First", &first_email)
        .await
        .expect("create first oauth customer");
    let second = repo
        .create_oauth_customer("OAuth Second", &second_email)
        .await
        .expect("create second oauth customer");

    repo.link_oauth_identity(first.id, "github", "github-shared-user")
        .await
        .expect("link first oauth identity");

    let duplicate_link = repo
        .link_oauth_identity(second.id, "github", "github-shared-user")
        .await;
    assert!(
        matches!(duplicate_link, Err(api::repos::RepoError::Conflict(_))),
        "second link for the same provider/user tuple must fail with conflict"
    );

    cleanup_customer_graph(&pool, &[first.id, second.id]).await;
}

#[tokio::test]
async fn create_and_link_oauth_customer_flow_preserves_existing_identity_on_conflict() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let linked_email = format!(
        "oauth-linked-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let contender_email = format!(
        "oauth-contender-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let linked = repo
        .create_oauth_customer("OAuth Linked", &linked_email)
        .await
        .expect("create linked customer");
    repo.link_oauth_identity(linked.id, "google", "google-conflict-user")
        .await
        .expect("link canonical identity");

    let contender = repo
        .create_oauth_customer("OAuth Contender", &contender_email)
        .await
        .expect("create contender customer");

    let conflict = repo
        .link_oauth_identity(contender.id, "google", "google-conflict-user")
        .await;
    assert!(
        matches!(conflict, Err(api::repos::RepoError::Conflict(_))),
        "linking an already-linked provider identity must return conflict"
    );

    let owner = repo
        .find_oauth_identity("google", "google-conflict-user")
        .await
        .expect("lookup canonical owner")
        .expect("conflict tuple should remain linked");
    assert_eq!(owner.id, linked.id);

    cleanup_customer_graph(&pool, &[linked.id, contender.id]).await;
}

#[tokio::test]
async fn oauth_identity_link_rejects_deleted_customer_rows() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "oauth-deleted-link-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create_oauth_customer("OAuth Deleted", &email)
        .await
        .expect("create oauth customer");
    repo.soft_delete(customer.id)
        .await
        .expect("soft delete oauth customer");

    let result = repo
        .link_oauth_identity(customer.id, "google", "deleted-user-link")
        .await;
    assert!(
        matches!(result, Err(api::repos::RepoError::NotFound)),
        "deleted customers must not accept new oauth identity links"
    );

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

#[tokio::test]
async fn hard_delete_removes_customer_and_dependents_then_404s_on_repeat() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "hard-erase-test-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    // 1. Seed a customer with dependent rows across every table that
    //    has a non-cascading FK to customers(id), plus oauth_identities
    //    (which DOES cascade) so we can prove the cascade actually
    //    fires under hard_delete.
    let customer = repo
        .create_with_password("Hard Erase Test", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    // customer_deployments has a NOT NULL node_id (UNIQUE) and a CHECK on
    // vm_provider — schema reality from migrations/002_deployments.sql.
    let node_id = format!("node-{}", &Uuid::new_v4().to_string()[..8]);
    let deployment_id: Uuid = sqlx::query_scalar(
        "INSERT INTO customer_deployments \
            (customer_id, node_id, region, vm_type, vm_provider, status) \
         VALUES ($1, $2, 'us-east-1', 't4g.small', 'aws', 'provisioning') \
         RETURNING id",
    )
    .bind(customer.id)
    .bind(&node_id)
    .fetch_one(&pool)
    .await
    .expect("seed customer_deployments");

    // customer_tenants has a deployment_id FK to customer_deployments(id).
    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id) \
         VALUES ($1, $2, $3)",
    )
    .bind(customer.id)
    .bind(format!("tenant-{}", &Uuid::new_v4().to_string()[..6]))
    .bind(deployment_id)
    .execute(&pool)
    .await
    .expect("seed customer_tenants");

    sqlx::query(
        "INSERT INTO api_keys (customer_id, name, key_prefix, key_hash) \
         VALUES ($1, 'test-key', $2, 'hash_value')",
    )
    .bind(customer.id)
    .bind(format!("p_{}", &Uuid::new_v4().to_string()[..6]))
    .execute(&pool)
    .await
    .expect("seed api_keys");

    sqlx::query(
        "INSERT INTO invoices \
            (customer_id, period_start, period_end, subtotal_cents, \
             tax_cents, total_cents, status) \
         VALUES ($1, '2026-01-01'::DATE, '2026-01-31'::DATE, \
                 500, 0, 500, 'paid')",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed invoices");

    sqlx::query(
        "INSERT INTO oauth_identities \
            (customer_id, provider, provider_user_id) \
         VALUES ($1, 'github', $2)",
    )
    .bind(customer.id)
    .bind(format!("gh_{}", &Uuid::new_v4().to_string()[..8]))
    .execute(&pool)
    .await
    .expect("seed oauth_identities");

    // usage_records: idempotency_key UNIQUE, tenant_id/node_id/event_type
    // NOT NULL, event_type CHECKed against an enum-shaped set.
    sqlx::query(
        "INSERT INTO usage_records \
            (idempotency_key, customer_id, tenant_id, region, node_id, \
             event_type, value, recorded_at, flapjack_ts) \
         VALUES ($1, $2, $3, 'us-east-1', $4, \
                 'search_requests', 1, NOW(), NOW())",
    )
    .bind(format!("idem-{}", Uuid::new_v4()))
    .bind(customer.id)
    .bind(format!("tenant-{}", &Uuid::new_v4().to_string()[..6]))
    .bind(&node_id)
    .execute(&pool)
    .await
    .expect("seed usage_records");

    // usage_daily: PK is composite (customer_id, date, region).
    sqlx::query(
        "INSERT INTO usage_daily \
            (customer_id, date, region, search_requests) \
         VALUES ($1, '2026-01-01'::DATE, 'us-east-1', 1)",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed usage_daily");

    repo.soft_delete(customer.id)
        .await
        .expect("soft delete customer");

    // 2. Hard-erase. The repo seam must return true and leave NO
    //    dependents pointing at this customer.
    let first_erase = repo.hard_delete(customer.id).await.expect("hard_delete");
    assert!(first_erase, "first hard_delete should return true");

    let remaining_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after hard_delete");
    assert!(
        remaining_customer.is_none(),
        "customer row must be removed by hard_delete"
    );

    // Real DB row-count checks per dependent table; tightens the contract
    // so partial-delete regressions cannot pass.
    for table in [
        "customer_tenants",
        "customer_deployments",
        "api_keys",
        "invoices",
        "oauth_identities",
        "usage_records",
        "usage_daily",
    ] {
        let count: i64 = sqlx::query_scalar(&format!(
            "SELECT COUNT(*)::BIGINT FROM {table} WHERE customer_id = $1"
        ))
        .bind(customer.id)
        .fetch_one(&pool)
        .await
        .expect("count dependent rows");
        assert_eq!(
            count, 0,
            "table {table} still references erased customer {}",
            customer.id
        );
    }

    // 3. Repeat call must return false (already erased).
    let second_erase = repo
        .hard_delete(customer.id)
        .await
        .expect("second hard_delete");
    assert!(
        !second_erase,
        "second hard_delete must return false for an already-erased customer"
    );
}

#[tokio::test]
async fn hard_delete_rejects_customers_with_open_invoices() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_pg_customer_repo").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());
    let email = format!(
        "hard-erase-open-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );

    let customer = repo
        .create_with_password("Open Invoice", &email, "$argon2id$integration_hash")
        .await
        .expect("create customer");

    // Seed a finalized but unpaid invoice — explicitly NOT in the
    // {paid, refunded} set the seam treats as final.
    sqlx::query(
        "INSERT INTO invoices \
            (customer_id, period_start, period_end, subtotal_cents, \
             tax_cents, total_cents, status) \
         VALUES ($1, '2026-02-01'::DATE, '2026-02-28'::DATE, \
                 500, 0, 500, 'finalized')",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed open invoice");

    repo.soft_delete(customer.id).await.expect("soft delete");

    let err = repo
        .hard_delete(customer.id)
        .await
        .expect_err("hard_delete must refuse customers with open invoices");
    match err {
        api::repos::RepoError::Conflict(msg) => {
            assert!(
                msg.contains("open invoice"),
                "open-invoice conflict message must reference open invoices: {msg}"
            );
        }
        other => panic!("expected RepoError::Conflict, got {other:?}"),
    }

    // Customer + invoice rows must be untouched by the rejected call so
    // the admin can wind billing down and retry.
    let still_present = repo
        .find_by_id(customer.id)
        .await
        .expect("find_by_id after rejected hard_delete")
        .expect("rejected hard_delete must not remove the customer row");
    assert_eq!(still_present.status, "deleted");

    let invoice_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*)::BIGINT FROM invoices WHERE customer_id = $1")
            .bind(customer.id)
            .fetch_one(&pool)
            .await
            .expect("count invoices");
    assert_eq!(
        invoice_count, 1,
        "rejected hard_delete must not silently drop invoices"
    );

    cleanup_customer_graph(&pool, &[customer.id]).await;
}

// ─── Login lockout tests ─────────────────────────────────────────────────────

#[tokio::test]
async fn lockout_record_failed_login_increments_and_eventually_locks() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_basic").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let customer = repo
        .create_with_password("lockout-user", "lockout@test.dev", "$argon2id$hash")
        .await
        .expect("create test customer");

    // First 4 failures should not lock (threshold is 5)
    for i in 1..=4 {
        let result = repo
            .record_failed_login(customer.id)
            .await
            .expect("record_failed_login");
        assert_eq!(
            result, None,
            "attempt {i}: should not be locked before threshold"
        );
    }

    // 5th failure should trigger lockout
    let result = repo
        .record_failed_login(customer.id)
        .await
        .expect("record_failed_login at threshold");
    assert!(
        result.is_some(),
        "5th failure must trigger lockout — expected Some(seconds_remaining)"
    );
    let seconds = result.unwrap();
    assert!(
        seconds > 0 && seconds <= 1800,
        "lockout duration must be between 1 and 1800 seconds, got {seconds}"
    );

    // Verify lockout_remaining reports the same
    let remaining = repo
        .login_lockout_remaining(customer.id)
        .await
        .expect("login_lockout_remaining");
    assert!(
        remaining.is_some(),
        "lockout_remaining must report locked state"
    );

    cleanup_customer(&pool, "lockout@test.dev").await;
}

#[tokio::test]
async fn lockout_successful_login_resets_counters() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_reset").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let customer = repo
        .create_with_password("reset-user", "reset-lockout@test.dev", "$argon2id$hash")
        .await
        .expect("create test customer");

    // Accumulate some failures
    for _ in 0..3 {
        repo.record_failed_login(customer.id)
            .await
            .expect("record_failed_login");
    }

    // Successful login resets everything
    let reset = repo
        .record_successful_login(customer.id)
        .await
        .expect("record_successful_login");
    assert!(reset, "record_successful_login should return true");

    // Next failure should start from count 1 (no lock)
    let result = repo
        .record_failed_login(customer.id)
        .await
        .expect("record_failed_login after reset");
    assert_eq!(
        result, None,
        "after successful login, counter resets — first failure should not lock"
    );

    cleanup_customer(&pool, "reset-lockout@test.dev").await;
}

#[tokio::test]
async fn lockout_concurrent_failures_reach_exact_count() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("lockout_concurrent").await else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = Arc::new(PgCustomerRepo::new(pool.clone()));

    let customer = repo
        .create_with_password(
            "concurrent-user",
            "concurrent-lockout@test.dev",
            "$argon2id$hash",
        )
        .await
        .expect("create test customer");

    let mut set = tokio::task::JoinSet::new();
    for _ in 0..10 {
        let repo_clone = Arc::clone(&repo);
        let cid = customer.id;
        set.spawn(async move { repo_clone.record_failed_login(cid).await });
    }

    let mut results = Vec::new();
    while let Some(res) = set.join_next().await {
        results.push(res.expect("task join").expect("record_failed_login"));
    }

    // All 10 must have completed — verify the final count in DB
    let count: i32 = sqlx::query_scalar("SELECT failed_login_count FROM customers WHERE id = $1")
        .bind(customer.id)
        .fetch_one(&pool)
        .await
        .expect("query failed_login_count");

    assert_eq!(
        count, 10,
        "10 concurrent record_failed_login calls must result in count=10 (atomic increment)"
    );

    // At least some results should have reported lockout (threshold is 5)
    let locked_count = results.iter().filter(|r| r.is_some()).count();
    assert!(
        locked_count >= 6,
        "at least 6 of 10 concurrent calls should report locked (calls 5-10), got {locked_count}"
    );

    cleanup_customer(&pool, "concurrent-lockout@test.dev").await;
}

#[tokio::test]
async fn verify_email_succeeds_even_when_deferred_verify_lockout_columns_are_active() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("verify_lockout_deferred").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let email = format!(
        "verify-lockout-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create("Verify Lockout Deferred", &email)
        .await
        .expect("create customer for verify lockout defer regression");

    let token = "verify-token-deferred-lockout";
    repo.set_email_verify_token(
        customer.id,
        token,
        chrono::Utc::now() + chrono::Duration::hours(1),
    )
    .await
    .expect("set verification token");

    sqlx::query(
        "UPDATE customers SET \
            failed_verify_count = 99, \
            failed_verify_window_start = NOW() - INTERVAL '5 minutes', \
            verify_locked_until = NOW() + INTERVAL '2 hours' \
         WHERE id = $1",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed active deferred verify lockout columns");

    let verified = repo
        .verify_email(token)
        .await
        .expect("verify_email query should succeed");
    assert!(
        verified.is_some(),
        "valid verify token must still succeed while deferred verify lockout columns are active"
    );

    cleanup_customer(&pool, &email).await;
}

#[tokio::test]
async fn reset_password_succeeds_even_when_deferred_reset_lockout_columns_are_active() {
    let Some(harness) = pg_schema_harness::connect_and_migrate("reset_lockout_deferred").await
    else {
        return;
    };
    let pool = harness.pool.clone();
    let repo = PgCustomerRepo::new(pool.clone());

    let email = format!(
        "reset-lockout-{}@integration.test",
        &Uuid::new_v4().to_string()[..8]
    );
    let customer = repo
        .create_with_password("Reset Lockout Deferred", &email, "$argon2id$hash")
        .await
        .expect("create customer for reset lockout defer regression");

    let token = "reset-token-deferred-lockout";
    let token_set = repo
        .set_password_reset_token(
            customer.id,
            token,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await
        .expect("set reset token");
    assert!(token_set, "password reset token setup should succeed");

    sqlx::query(
        "UPDATE customers SET \
            failed_reset_count = 99, \
            failed_reset_window_start = NOW() - INTERVAL '5 minutes', \
            reset_locked_until = NOW() + INTERVAL '2 hours' \
         WHERE id = $1",
    )
    .bind(customer.id)
    .execute(&pool)
    .await
    .expect("seed active deferred reset lockout columns");

    let reset = repo
        .reset_password(token, "$argon2id$newhash")
        .await
        .expect("reset_password query should succeed");
    assert!(
        reset,
        "valid reset token must still succeed while deferred reset lockout columns are active"
    );

    cleanup_customer(&pool, &email).await;
}

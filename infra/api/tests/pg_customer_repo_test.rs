/// SQL integration tests for PgCustomerRepo — carry-forward plumbing.
///
/// These tests run against a real Postgres database to verify:
///   - Basic CRUD round-trips (create, create_with_password, find_by_id, find_by_email)
///   - The new `object_storage_egress_carryforward_cents` column defaults to zero
///   - The dedicated `set_object_storage_egress_carryforward_cents` setter persists
///     and round-trips a non-zero decimal value
///
/// ## Running
///
/// Set DATABASE_URL to a Postgres instance with DDL privileges:
///
///   DATABASE_URL=postgres://user:pass@localhost/flapjack_test \
///     cargo test -p api --test pg_customer_repo_test
///
/// If DATABASE_URL is not set, all tests are skipped.
///
/// ## Isolation
///
/// Each test seeds its own data using unique UUIDs and cleans up on success.
use api::repos::{CustomerRepo, PgCustomerRepo};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sqlx::PgPool;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping PgCustomerRepo SQL tests");
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

async fn cleanup_customer(pool: &PgPool, email: &str) {
    sqlx::query("DELETE FROM customers WHERE email = $1")
        .bind(email)
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_customer_has_zero_carryforward() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
async fn soft_delete_retains_row_and_is_idempotent() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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

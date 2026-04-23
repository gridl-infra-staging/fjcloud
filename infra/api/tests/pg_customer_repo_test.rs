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

    cleanup_customer(&pool, &email).await;
}

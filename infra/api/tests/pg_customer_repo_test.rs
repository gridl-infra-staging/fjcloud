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

#[tokio::test]
async fn list_aggregates_billing_health_inputs_without_duplicate_customer_rows() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
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

    let subscription_period_start = chrono::NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let subscription_period_end = chrono::NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();
    // Seed subscription rows to prove the customer list query no longer
    // depends on subscription data after Stage 5 seam removal.
    sqlx::query(
        "INSERT INTO subscriptions \
            (customer_id, stripe_subscription_id, stripe_price_id, plan_tier, status, \
             current_period_start, current_period_end, cancel_at_period_end, created_at, updated_at) \
         VALUES \
            ($1, $2, $3, $4, $5, $6, $7, FALSE, NOW(), NOW()), \
            ($8, $9, $10, $11, $12, $13, $14, FALSE, NOW(), NOW()), \
            ($15, $16, $17, $18, $19, $20, $21, FALSE, NOW(), NOW())",
    )
    .bind(first.id)
    .bind(format!("sub-list-health-trialing-{first_short}"))
    .bind("price_test_trialing")
    .bind("starter")
    .bind("trialing")
    .bind(subscription_period_start)
    .bind(subscription_period_end)
    .bind(first.id)
    .bind(format!("sub-list-health-canceled-{first_short}"))
    .bind("price_test_canceled")
    .bind("starter")
    .bind("canceled")
    .bind(subscription_period_start)
    .bind(subscription_period_end)
    .bind(second.id)
    .bind(format!("sub-list-health-canceled-{second_short}"))
    .bind("price_test_second_canceled")
    .bind("starter")
    .bind("canceled")
    .bind(subscription_period_start)
    .bind(subscription_period_end)
    .execute(&pool)
    .await
    .expect("insert subscription rows that list query must ignore");

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

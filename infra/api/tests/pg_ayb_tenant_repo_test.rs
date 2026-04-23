/// SQL integration tests for PgAybTenantRepo.
///
/// These tests run every method against a real Postgres database to verify:
///   - SQL correctness (column names, types, query logic)
///   - Partial unique index enforcement (one active per customer, one active slug per cluster)
///   - CHECK constraint enforcement (status, plan)
///   - Soft-delete lifecycle (deleted_at filtering, reprovisioning after delete)
///   - Timestamp defaults (database-owned created_at/updated_at, NULL deleted_at)
///
/// ## Running
///
/// Set DATABASE_URL to a Postgres instance with DDL privileges:
///
///   DATABASE_URL=postgres://user:pass@localhost/flapjack_test \
///     cargo test -p api --test pg_ayb_tenant_repo_test
///
/// If DATABASE_URL is not set, all tests are skipped.
///
/// ## Isolation
///
/// Each test seeds its own data using unique UUIDs and cleans up on success.
use api::models::ayb_tenant::{AybTenantStatus, NewAybTenant};
use api::repos::{AybTenantRepo, PgAybTenantRepo, RepoError};
use billing::plan::PlanTier;
use sqlx::PgPool;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping PgAybTenantRepo SQL tests");
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

async fn seed_customer(pool: &PgPool) -> Uuid {
    let customer_id = Uuid::new_v4();
    let short = &customer_id.to_string()[..8];
    sqlx::query("INSERT INTO customers (id, name, email) VALUES ($1, $2, $3)")
        .bind(customer_id)
        .bind(format!("AYB Test {short}"))
        .bind(format!("aybtest-{short}@integration.test"))
        .execute(pool)
        .await
        .expect("insert customer");
    customer_id
}

async fn cleanup_customer(pool: &PgPool, customer_id: Uuid) {
    sqlx::query("DELETE FROM ayb_tenants WHERE customer_id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(customer_id)
        .execute(pool)
        .await
        .ok();
}

fn new_tenant(customer_id: Uuid) -> NewAybTenant {
    let short = &customer_id.to_string()[..8];
    NewAybTenant {
        customer_id,
        ayb_tenant_id: format!("ayb-tid-{short}"),
        ayb_slug: format!("slug-{short}"),
        ayb_cluster_id: "cluster-default".to_string(),
        ayb_url: format!("https://ayb-{short}.test"),
        status: AybTenantStatus::Provisioning,
        plan: PlanTier::Starter,
    }
}

// ---------------------------------------------------------------------------
// Sprint 1: Schema contract — migration lifecycle rules
// ---------------------------------------------------------------------------

#[tokio::test]
async fn pg_create_returns_correct_fields_and_defaults() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let input = new_tenant(cid);
    let created = repo.create(input.clone()).await.expect("create");

    assert_eq!(created.customer_id, cid);
    assert_eq!(created.ayb_tenant_id, input.ayb_tenant_id);
    assert_eq!(created.ayb_slug, input.ayb_slug);
    assert_eq!(created.ayb_cluster_id, input.ayb_cluster_id);
    assert_eq!(created.ayb_url, input.ayb_url);
    assert_eq!(created.status, "provisioning");
    assert_eq!(created.plan, "starter");
    assert!(!created.id.is_nil(), "id must be populated by DB");
    assert!(
        created.deleted_at.is_none(),
        "deleted_at must default to NULL"
    );
    assert!(created.is_active());

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_timestamps_are_database_owned() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let created = repo.create(new_tenant(cid)).await.expect("create");

    // created_at and updated_at should be set by DB DEFAULT NOW()
    let now = chrono::Utc::now();
    let age = now - created.created_at;
    assert!(
        age.num_seconds() < 10,
        "created_at should be recent (within 10s), got age: {age}"
    );
    let update_age = now - created.updated_at;
    assert!(
        update_age.num_seconds() < 10,
        "updated_at should be recent (within 10s), got age: {update_age}"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_one_active_per_customer() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    repo.create(new_tenant(cid)).await.expect("first create");

    // Second active instance for same customer must fail
    let mut second = new_tenant(cid);
    second.ayb_slug = "different-slug".to_string();
    second.ayb_tenant_id = "different-tid".to_string();
    let err = repo.create(second).await.unwrap_err();
    assert!(
        matches!(err, RepoError::Conflict(_)),
        "duplicate active customer must return Conflict, got: {err:?}"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_one_active_slug_per_cluster() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid1 = seed_customer(&pool).await;
    let cid2 = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let t1 = NewAybTenant {
        customer_id: cid1,
        ayb_tenant_id: "tid-1".to_string(),
        ayb_slug: "shared-slug".to_string(),
        ayb_cluster_id: "cluster-a".to_string(),
        ayb_url: "https://ayb-1.test".to_string(),
        status: AybTenantStatus::Provisioning,
        plan: PlanTier::Pro,
    };
    repo.create(t1).await.expect("first create");

    // Same (cluster, slug) for different customer must also fail
    let t2 = NewAybTenant {
        customer_id: cid2,
        ayb_tenant_id: "tid-2".to_string(),
        ayb_slug: "shared-slug".to_string(),
        ayb_cluster_id: "cluster-a".to_string(),
        ayb_url: "https://ayb-2.test".to_string(),
        status: AybTenantStatus::Provisioning,
        plan: PlanTier::Enterprise,
    };
    let err = repo.create(t2).await.unwrap_err();
    assert!(
        matches!(err, RepoError::Conflict(_)),
        "duplicate active (cluster, slug) must return Conflict, got: {err:?}"
    );

    cleanup_customer(&pool, cid1).await;
    cleanup_customer(&pool, cid2).await;
}

#[tokio::test]
async fn pg_soft_deleted_row_coexists_with_replacement() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let first = repo.create(new_tenant(cid)).await.expect("create first");
    repo.soft_delete_for_customer(cid, first.id)
        .await
        .expect("soft delete");

    // Same customer can now create a new active instance
    let second = repo
        .create(new_tenant(cid))
        .await
        .expect("create after soft delete should succeed");
    assert_ne!(first.id, second.id);
    assert!(second.is_active());

    // First row still exists in DB (soft-deleted), but not visible through active queries
    let active = repo
        .find_active_by_customer(cid)
        .await
        .expect("list active");
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, second.id);

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_no_admin_credentials_columns() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    // Verify schema does not contain credential or ownerUserId columns
    let columns: Vec<(String,)> = sqlx::query_as(
        "SELECT column_name::text FROM information_schema.columns \
         WHERE table_name = 'ayb_tenants' ORDER BY ordinal_position",
    )
    .fetch_all(&pool)
    .await
    .expect("query columns");

    let col_names: Vec<&str> = columns.iter().map(|c| c.0.as_str()).collect();

    // Must NOT contain credential/password/token/owner columns
    for forbidden in [
        "password",
        "token",
        "secret",
        "owner_user_id",
        "admin_password",
    ] {
        assert!(
            !col_names.contains(&forbidden),
            "ayb_tenants must not store '{forbidden}' — got columns: {col_names:?}"
        );
    }

    // Must contain expected columns
    for expected in [
        "id",
        "customer_id",
        "ayb_tenant_id",
        "ayb_slug",
        "ayb_cluster_id",
        "ayb_url",
        "status",
        "plan",
        "created_at",
        "updated_at",
        "deleted_at",
    ] {
        assert!(
            col_names.contains(&expected),
            "ayb_tenants must contain '{expected}' — got columns: {col_names:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// Sprint 3: Repository CRUD
// ---------------------------------------------------------------------------

#[tokio::test]
async fn pg_find_active_by_customer_returns_only_active() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    // Empty at start
    let list = repo.find_active_by_customer(cid).await.expect("list");
    assert!(list.is_empty());

    let created = repo.create(new_tenant(cid)).await.expect("create");
    let list = repo.find_active_by_customer(cid).await.expect("list");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, created.id);

    // After soft-delete, list is empty again
    repo.soft_delete_for_customer(cid, created.id)
        .await
        .expect("soft delete");
    let list = repo.find_active_by_customer(cid).await.expect("list");
    assert!(list.is_empty());

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_find_active_by_customer_and_id_returns_active_only() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let created = repo.create(new_tenant(cid)).await.expect("create");

    let found = repo
        .find_active_by_customer_and_id(cid, created.id)
        .await
        .expect("find")
        .expect("must exist");
    assert_eq!(found.id, created.id);
    assert_eq!(found.customer_id, cid);

    // Non-existent ID returns None
    let missing = repo
        .find_active_by_customer_and_id(cid, Uuid::new_v4())
        .await
        .expect("find");
    assert!(missing.is_none());

    // After soft-delete, returns None
    repo.soft_delete_for_customer(cid, created.id)
        .await
        .expect("soft delete");
    let after = repo
        .find_active_by_customer_and_id(cid, created.id)
        .await
        .expect("find");
    assert!(
        after.is_none(),
        "soft-deleted row must not be returned by find_active_by_customer_and_id"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_soft_delete_sets_timestamps() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let created = repo.create(new_tenant(cid)).await.expect("create");
    let before_updated_at = created.updated_at;

    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    repo.soft_delete_for_customer(cid, created.id)
        .await
        .expect("soft delete");

    // Read the raw row (including deleted) to verify timestamps
    let raw: AybTenantRaw =
        sqlx::query_as("SELECT id, updated_at, deleted_at FROM ayb_tenants WHERE id = $1")
            .bind(created.id)
            .fetch_one(&pool)
            .await
            .expect("raw fetch");

    let deleted_at = raw
        .deleted_at
        .expect("deleted_at must be set after soft_delete");
    assert!(
        raw.updated_at > before_updated_at,
        "updated_at must advance on soft_delete"
    );
    assert_eq!(
        deleted_at, raw.updated_at,
        "soft_delete should stamp deleted_at and updated_at together"
    );

    cleanup_customer(&pool, cid).await;
}

/// Minimal struct for reading timestamp columns from raw SQL.
#[derive(sqlx::FromRow)]
struct AybTenantRaw {
    #[allow(dead_code)]
    id: Uuid,
    updated_at: chrono::DateTime<chrono::Utc>,
    deleted_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[tokio::test]
async fn pg_soft_delete_nonexistent_returns_not_found() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let result = repo.soft_delete_for_customer(cid, Uuid::new_v4()).await;
    assert!(
        matches!(result, Err(RepoError::NotFound)),
        "soft_delete on non-existent ID must return NotFound, got: {result:?}"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_soft_delete_already_deleted_returns_not_found() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let created = repo.create(new_tenant(cid)).await.expect("create");
    repo.soft_delete_for_customer(cid, created.id)
        .await
        .expect("first delete");

    let result = repo.soft_delete_for_customer(cid, created.id).await;
    assert!(
        matches!(result, Err(RepoError::NotFound)),
        "second soft_delete must return NotFound (already deleted), got: {result:?}"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_customer_isolation() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid1 = seed_customer(&pool).await;
    let cid2 = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let t1 = repo.create(new_tenant(cid1)).await.expect("create c1");

    let mut input2 = new_tenant(cid2);
    input2.ayb_slug = "different-slug-c2".to_string();
    input2.ayb_tenant_id = "different-tid-c2".to_string();
    let _t2 = repo.create(input2).await.expect("create c2");

    // Customer 1 only sees its own instance
    let list1 = repo.find_active_by_customer(cid1).await.expect("list c1");
    assert_eq!(list1.len(), 1);
    assert_eq!(list1[0].id, t1.id);

    // Customer 2 only sees its own instance
    let list2 = repo.find_active_by_customer(cid2).await.expect("list c2");
    assert_eq!(list2.len(), 1);
    assert_ne!(list2[0].id, t1.id);

    cleanup_customer(&pool, cid1).await;
    cleanup_customer(&pool, cid2).await;
}

#[tokio::test]
async fn pg_find_active_by_customer_and_id_enforces_customer_scope() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid1 = seed_customer(&pool).await;
    let cid2 = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let t1 = repo.create(new_tenant(cid1)).await.expect("create c1");
    let t2 = repo.create(new_tenant(cid2)).await.expect("create c2");

    let found_c1 = repo
        .find_active_by_customer_and_id(cid1, t1.id)
        .await
        .expect("find c1")
        .expect("must exist");
    assert_eq!(found_c1.id, t1.id);

    let wrong_customer = repo
        .find_active_by_customer_and_id(cid1, t2.id)
        .await
        .expect("find wrong customer");
    assert!(
        wrong_customer.is_none(),
        "repo must not return another customer's row"
    );

    cleanup_customer(&pool, cid1).await;
    cleanup_customer(&pool, cid2).await;
}

#[tokio::test]
async fn pg_soft_delete_for_customer_enforces_customer_scope() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid1 = seed_customer(&pool).await;
    let cid2 = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let _t1 = repo.create(new_tenant(cid1)).await.expect("create c1");
    let t2 = repo.create(new_tenant(cid2)).await.expect("create c2");

    let wrong_customer_delete = repo.soft_delete_for_customer(cid1, t2.id).await;
    assert!(
        matches!(wrong_customer_delete, Err(RepoError::NotFound)),
        "repo must not delete another customer's row"
    );

    let still_active = repo
        .find_active_by_customer_and_id(cid2, t2.id)
        .await
        .expect("find c2")
        .is_some();
    assert!(still_active, "target row must remain active");

    cleanup_customer(&pool, cid1).await;
    cleanup_customer(&pool, cid2).await;
}

// ---------------------------------------------------------------------------
// Sprint 3: Conflict paths
// ---------------------------------------------------------------------------

#[tokio::test]
async fn pg_duplicate_active_customer_conflicts() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    repo.create(new_tenant(cid)).await.expect("first create");

    let mut dup = new_tenant(cid);
    dup.ayb_slug = "another-slug".to_string();
    dup.ayb_tenant_id = "another-tid".to_string();

    let err = repo.create(dup).await.unwrap_err();
    assert!(
        matches!(err, RepoError::Conflict(_)),
        "duplicate active customer must Conflict, got: {err:?}"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_duplicate_active_cluster_slug_conflicts() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid1 = seed_customer(&pool).await;
    let cid2 = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let t1 = NewAybTenant {
        customer_id: cid1,
        ayb_tenant_id: "tid-a".to_string(),
        ayb_slug: "collide-slug".to_string(),
        ayb_cluster_id: "cluster-x".to_string(),
        ayb_url: "https://a.test".to_string(),
        status: AybTenantStatus::Ready,
        plan: PlanTier::Pro,
    };
    repo.create(t1).await.expect("create first");

    let t2 = NewAybTenant {
        customer_id: cid2,
        ayb_tenant_id: "tid-b".to_string(),
        ayb_slug: "collide-slug".to_string(),
        ayb_cluster_id: "cluster-x".to_string(),
        ayb_url: "https://b.test".to_string(),
        status: AybTenantStatus::Provisioning,
        plan: PlanTier::Starter,
    };
    let err = repo.create(t2).await.unwrap_err();
    assert!(
        matches!(err, RepoError::Conflict(_)),
        "duplicate active (cluster, slug) must Conflict, got: {err:?}"
    );

    cleanup_customer(&pool, cid1).await;
    cleanup_customer(&pool, cid2).await;
}

#[tokio::test]
async fn pg_recreate_after_soft_delete_succeeds() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;
    let repo = PgAybTenantRepo::new(pool.clone());

    let first = repo.create(new_tenant(cid)).await.expect("create first");
    repo.soft_delete_for_customer(cid, first.id)
        .await
        .expect("soft delete");

    // Reprovisioning after delete must succeed
    let second = repo
        .create(new_tenant(cid))
        .await
        .expect("recreate after soft delete");
    assert_ne!(first.id, second.id);
    assert!(second.is_active());

    cleanup_customer(&pool, cid).await;
}

// ---------------------------------------------------------------------------
// Schema CHECK constraints
// ---------------------------------------------------------------------------

#[tokio::test]
async fn pg_check_constraint_rejects_invalid_status() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;

    // Direct INSERT with invalid status bypasses the repo to test the DB constraint
    let result = sqlx::query(
        "INSERT INTO ayb_tenants \
             (customer_id, ayb_tenant_id, ayb_slug, ayb_cluster_id, ayb_url, status, plan) \
         VALUES ($1, 'tid', 'slug', 'cluster', 'https://url', 'invalid_status', 'starter')",
    )
    .bind(cid)
    .execute(&pool)
    .await;

    assert!(
        result.is_err(),
        "CHECK constraint must reject invalid status"
    );

    cleanup_customer(&pool, cid).await;
}

#[tokio::test]
async fn pg_check_constraint_rejects_invalid_plan() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let cid = seed_customer(&pool).await;

    let result = sqlx::query(
        "INSERT INTO ayb_tenants \
             (customer_id, ayb_tenant_id, ayb_slug, ayb_cluster_id, ayb_url, status, plan) \
         VALUES ($1, 'tid', 'slug', 'cluster', 'https://url', 'provisioning', 'invalid_plan')",
    )
    .bind(cid)
    .execute(&pool)
    .await;

    assert!(result.is_err(), "CHECK constraint must reject invalid plan");

    cleanup_customer(&pool, cid).await;
}

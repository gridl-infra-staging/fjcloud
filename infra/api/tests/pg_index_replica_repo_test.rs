/// SQL integration tests for PgIndexReplicaRepo.
///
/// These tests run every method against a real Postgres database to verify:
///   - SQL correctness (column names, types, query logic)
///   - CHECK constraint enforcement
///   - UNIQUE constraint enforcement
///   - NULL / optional field handling
///
/// ## Running
///
/// Set DATABASE_URL to a Postgres instance with a user that can run DDL:
///
///   DATABASE_URL=postgres://user:pass@localhost/flapjack_test \
///     cargo test -p api --test pg_index_replica_repo_test
///
/// If DATABASE_URL is not set, all tests in this file are skipped (they print
/// "SKIP: DATABASE_URL not set" and return early).
///
/// Migrations are applied automatically before the first test and are
/// idempotent (IF NOT EXISTS), so running against an existing database is safe.
///
/// ## Isolation
///
/// Each test seeds its own data using unique UUIDs and cleans up on success.
/// Tests run sequentially (cargo default for integration test binaries).
/// Panics leave orphaned rows with unique UUIDs that do not affect other runs.
use api::repos::{IndexReplicaRepo, PgIndexReplicaRepo, RepoError};
use sqlx::PgPool;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Prerequisites
// ---------------------------------------------------------------------------

struct Prereqs {
    customer_id: Uuid,
    tenant_id: String,
    primary_vm_id: Uuid,
    replica_vm_id: Uuid,
}

/// Set up the minimal rows required by the index_replicas foreign keys:
///   customers → customer_deployments → customer_tenants
///   vm_inventory (x2)
async fn seed_prereqs(pool: &PgPool) -> Prereqs {
    let customer_id = Uuid::new_v4();
    let short = &customer_id.to_string()[..8];
    let tenant_id = format!("pg-test-{short}");
    let primary_vm_id = Uuid::new_v4();
    let replica_vm_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    let pshort = &primary_vm_id.to_string()[..8];
    let rshort = &replica_vm_id.to_string()[..8];

    sqlx::query("INSERT INTO customers (id, name, email) VALUES ($1, $2, $3)")
        .bind(customer_id)
        .bind(format!("PG Test {short}"))
        .bind(format!("pgtest-{short}@integration.test"))
        .execute(pool)
        .await
        .expect("insert customer");

    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(primary_vm_id)
    .bind("us-east-1")
    .bind("aws")
    .bind(format!("vm-primary-{pshort}.test"))
    .bind(format!("https://vm-primary-{pshort}.test"))
    .execute(pool)
    .await
    .expect("insert primary VM");

    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(replica_vm_id)
    .bind("eu-central-1")
    .bind("aws")
    .bind(format!("vm-replica-{rshort}.test"))
    .bind(format!("https://vm-replica-{rshort}.test"))
    .execute(pool)
    .await
    .expect("insert replica VM");

    sqlx::query(
        "INSERT INTO customer_deployments (id, customer_id, node_id, region, vm_type, vm_provider) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{pshort}"))
    .bind("us-east-1")
    .bind("t4g.small")
    .bind("aws")
    .execute(pool)
    .await
    .expect("insert deployment");

    sqlx::query(
        "INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id, vm_id) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(customer_id)
    .bind(&tenant_id)
    .bind(deployment_id)
    .bind(primary_vm_id)
    .execute(pool)
    .await
    .expect("insert tenant");

    Prereqs {
        customer_id,
        tenant_id,
        primary_vm_id,
        replica_vm_id,
    }
}

/// Delete all rows created by seed_prereqs for a given customer_id.
/// Deletes in reverse FK order so no constraint violations occur.
async fn cleanup_prereqs(pool: &PgPool, p: &Prereqs) {
    sqlx::query("DELETE FROM index_replicas WHERE customer_id = $1")
        .bind(p.customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_tenants WHERE customer_id = $1")
        .bind(p.customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customer_deployments WHERE customer_id = $1")
        .bind(p.customer_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM vm_inventory WHERE id = $1 OR id = $2")
        .bind(p.primary_vm_id)
        .bind(p.replica_vm_id)
        .execute(pool)
        .await
        .ok();
    sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(p.customer_id)
        .execute(pool)
        .await
        .ok();
}

// ---------------------------------------------------------------------------
// Test pool helper — skips the whole test if DATABASE_URL is not set
// ---------------------------------------------------------------------------

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping PgIndexReplicaRepo SQL tests");
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn pg_create_returns_correct_fields() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    let created = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create should succeed");

    assert_eq!(created.customer_id, p.customer_id);
    assert_eq!(created.tenant_id, p.tenant_id);
    assert_eq!(created.primary_vm_id, p.primary_vm_id);
    assert_eq!(created.replica_vm_id, p.replica_vm_id);
    assert_eq!(created.replica_region, "eu-central-1");
    assert_eq!(
        created.status, "provisioning",
        "default status must be 'provisioning'"
    );
    assert_eq!(created.lag_ops, 0, "default lag_ops must be 0");
    assert!(!created.id.is_nil(), "id must be populated by DB");

    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_get_returns_inserted_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    let created = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create");

    let fetched = repo
        .get(created.id)
        .await
        .expect("get")
        .expect("row must exist");
    assert_eq!(fetched.id, created.id);
    assert_eq!(fetched.customer_id, p.customer_id);
    assert_eq!(fetched.replica_region, "eu-central-1");

    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_get_missing_id_returns_none() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let repo = PgIndexReplicaRepo::new(pool);

    let result = repo.get(Uuid::new_v4()).await.expect("no DB error");
    assert!(result.is_none(), "non-existent ID must return None");
}

#[tokio::test]
async fn pg_list_by_index_filters_by_customer_and_tenant() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    // Create a second replica VM for the second replica
    let replica_vm_id_2 = Uuid::new_v4();
    let vm2short = &replica_vm_id_2.to_string()[..8];
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(replica_vm_id_2)
    .bind("eu-north-1")
    .bind("aws")
    .bind(format!("vm-r2-{vm2short}.test"))
    .bind(format!("https://vm-r2-{vm2short}.test"))
    .execute(&pool)
    .await
    .expect("insert second replica VM");

    let repo = PgIndexReplicaRepo::new(pool.clone());

    repo.create(
        p.customer_id,
        &p.tenant_id,
        p.primary_vm_id,
        p.replica_vm_id,
        "eu-central-1",
    )
    .await
    .expect("create replica 1");
    repo.create(
        p.customer_id,
        &p.tenant_id,
        p.primary_vm_id,
        replica_vm_id_2,
        "eu-north-1",
    )
    .await
    .expect("create replica 2");

    // A different customer must not see these rows
    let other_customer = Uuid::new_v4();
    let replicas = repo
        .list_by_index(other_customer, &p.tenant_id)
        .await
        .expect("list");
    assert_eq!(replicas.len(), 0, "different customer must see no rows");

    // Correct customer sees both
    let replicas = repo
        .list_by_index(p.customer_id, &p.tenant_id)
        .await
        .expect("list");
    assert_eq!(replicas.len(), 2);

    // Different tenant_id also returns zero
    let replicas = repo
        .list_by_index(p.customer_id, "nonexistent-tenant")
        .await
        .expect("list");
    assert_eq!(replicas.len(), 0);

    // Cleanup second VM
    sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
        .bind(replica_vm_id_2)
        .execute(&pool)
        .await
        .ok();
    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_list_healthy_returns_only_active_status() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let replica_vm_id_2 = Uuid::new_v4();
    let vm2short = &replica_vm_id_2.to_string()[..8];
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(replica_vm_id_2)
    .bind("eu-north-1")
    .bind("aws")
    .bind(format!("vm-h2-{vm2short}.test"))
    .bind(format!("https://vm-h2-{vm2short}.test"))
    .execute(&pool)
    .await
    .expect("insert second VM");

    let repo = PgIndexReplicaRepo::new(pool.clone());

    let r1 = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create r1");
    let r2 = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            replica_vm_id_2,
            "eu-north-1",
        )
        .await
        .expect("create r2");

    repo.set_status(r1.id, "active")
        .await
        .expect("set r1 active");
    repo.set_status(r2.id, "syncing")
        .await
        .expect("set r2 syncing");

    let healthy = repo
        .list_healthy_by_index(p.customer_id, &p.tenant_id)
        .await
        .expect("list_healthy");

    assert_eq!(healthy.len(), 1, "only 'active' replicas must be returned");
    assert_eq!(healthy[0].id, r1.id);

    sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
        .bind(replica_vm_id_2)
        .execute(&pool)
        .await
        .ok();
    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_set_status_updates_updated_at_and_rejects_invalid_status() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    let created = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create");

    let before = created.updated_at;

    // Small sleep to ensure updated_at advances (NOW() resolution)
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;

    repo.set_status(created.id, "active")
        .await
        .expect("set_status active");

    let updated = repo
        .get(created.id)
        .await
        .expect("get")
        .expect("must exist");
    assert_eq!(updated.status, "active");
    assert!(
        updated.updated_at >= before,
        "updated_at must not regress after set_status"
    );

    // Invalid status must be rejected by the DB CHECK constraint
    let bad = repo.set_status(created.id, "invalid-status").await;
    assert!(
        bad.is_err(),
        "CHECK constraint must reject invalid status values"
    );

    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_set_status_not_found_returns_error() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let repo = PgIndexReplicaRepo::new(pool);

    let result = repo.set_status(Uuid::new_v4(), "active").await;
    assert!(
        matches!(result, Err(RepoError::NotFound)),
        "set_status on non-existent ID must return NotFound"
    );
}

#[tokio::test]
async fn pg_set_lag_does_not_update_updated_at() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    let created = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create");

    let before_updated_at = repo
        .get(created.id)
        .await
        .expect("get")
        .expect("row")
        .updated_at;

    // Advance time slightly then call set_lag
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    repo.set_lag(created.id, 42).await.expect("set_lag");

    let after = repo.get(created.id).await.expect("get").expect("row");
    assert_eq!(after.lag_ops, 42);
    assert_eq!(
        after.updated_at, before_updated_at,
        "set_lag must NOT update updated_at (sync-timeout clock must not reset)"
    );

    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_set_lag_not_found_returns_error() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let repo = PgIndexReplicaRepo::new(pool);

    let result = repo.set_lag(Uuid::new_v4(), 100).await;
    assert!(
        matches!(result, Err(RepoError::NotFound)),
        "set_lag on non-existent ID must return NotFound"
    );
}

#[tokio::test]
async fn pg_delete_removes_row_and_returns_true() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    let created = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create");

    let deleted = repo.delete(created.id).await.expect("delete");
    assert!(deleted, "first delete must return true");

    let after = repo.get(created.id).await.expect("get");
    assert!(after.is_none(), "row must not exist after delete");

    let deleted_again = repo.delete(created.id).await.expect("delete again");
    assert!(
        !deleted_again,
        "second delete must return false (already gone)"
    );

    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_count_by_index_returns_correct_count() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let replica_vm_id_2 = Uuid::new_v4();
    let vm2short = &replica_vm_id_2.to_string()[..8];
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(replica_vm_id_2)
    .bind("eu-north-1")
    .bind("aws")
    .bind(format!("vm-cnt-{vm2short}.test"))
    .bind(format!("https://vm-cnt-{vm2short}.test"))
    .execute(&pool)
    .await
    .expect("insert second VM");

    let repo = PgIndexReplicaRepo::new(pool.clone());

    let c0 = repo
        .count_by_index(p.customer_id, &p.tenant_id)
        .await
        .expect("count before");
    assert_eq!(c0, 0, "should be zero before any replicas");

    repo.create(
        p.customer_id,
        &p.tenant_id,
        p.primary_vm_id,
        p.replica_vm_id,
        "eu-central-1",
    )
    .await
    .expect("create r1");
    repo.create(
        p.customer_id,
        &p.tenant_id,
        p.primary_vm_id,
        replica_vm_id_2,
        "eu-north-1",
    )
    .await
    .expect("create r2");

    let c2 = repo
        .count_by_index(p.customer_id, &p.tenant_id)
        .await
        .expect("count after");
    assert_eq!(c2, 2);

    // Different customer → 0
    let c_other = repo
        .count_by_index(Uuid::new_v4(), &p.tenant_id)
        .await
        .expect("count other");
    assert_eq!(c_other, 0);

    sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
        .bind(replica_vm_id_2)
        .execute(&pool)
        .await
        .ok();
    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_list_actionable_excludes_failed_and_removing() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;

    // Create three extra replica VMs for this test
    let mut extra_vm_ids = Vec::new();
    let statuses = ["active", "failed", "removing"];
    for (i, &status) in statuses.iter().enumerate() {
        let vm_id = Uuid::new_v4();
        let short = &vm_id.to_string()[..8];
        sqlx::query(
            "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(vm_id)
        .bind("eu-west-1")
        .bind("aws")
        .bind(format!("vm-act-{short}-{i}.test"))
        .bind(format!("https://vm-act-{short}-{i}.test"))
        .execute(&pool)
        .await
        .expect("insert extra VM");
        extra_vm_ids.push((vm_id, status));
    }

    let repo = PgIndexReplicaRepo::new(pool.clone());

    let mut created_ids = Vec::new();
    for (vm_id, status) in &extra_vm_ids {
        let r = repo
            .create(
                p.customer_id,
                &p.tenant_id,
                p.primary_vm_id,
                *vm_id,
                "eu-west-1",
            )
            .await
            .expect("create");
        repo.set_status(r.id, status).await.expect("set_status");
        created_ids.push(r.id);
    }

    let actionable = repo.list_actionable().await.expect("list_actionable");

    // Exactly the 'active' one must be in the list (from this test's data)
    let our_ids: std::collections::HashSet<_> = created_ids.iter().copied().collect();
    let our_actionable: Vec<_> = actionable
        .iter()
        .filter(|r| our_ids.contains(&r.id))
        .collect();

    assert_eq!(our_actionable.len(), 1, "only 'active' must be actionable");
    assert_eq!(our_actionable[0].status, "active");

    for (vm_id, _) in &extra_vm_ids {
        sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
            .bind(vm_id)
            .execute(&pool)
            .await
            .ok();
    }
    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_list_all_returns_every_status() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let replica_vm_id_2 = Uuid::new_v4();
    let vm2short = &replica_vm_id_2.to_string()[..8];
    sqlx::query(
        "INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(replica_vm_id_2)
    .bind("eu-north-1")
    .bind("aws")
    .bind(format!("vm-all-{vm2short}.test"))
    .bind(format!("https://vm-all-{vm2short}.test"))
    .execute(&pool)
    .await
    .expect("insert second VM");

    let repo = PgIndexReplicaRepo::new(pool.clone());

    let r1 = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("create r1");
    let r2 = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            replica_vm_id_2,
            "eu-north-1",
        )
        .await
        .expect("create r2");

    repo.set_status(r1.id, "active").await.expect("set active");
    repo.set_status(r2.id, "failed").await.expect("set failed");

    let all = repo.list_all().await.expect("list_all");

    // Both rows must be present (list_all has no status filter)
    let our_ids: std::collections::HashSet<_> = [r1.id, r2.id].into_iter().collect();
    let ours: Vec<_> = all.iter().filter(|r| our_ids.contains(&r.id)).collect();
    assert_eq!(ours.len(), 2, "list_all must include rows of every status");

    sqlx::query("DELETE FROM vm_inventory WHERE id = $1")
        .bind(replica_vm_id_2)
        .execute(&pool)
        .await
        .ok();
    cleanup_prereqs(&pool, &p).await;
}

#[tokio::test]
async fn pg_unique_constraint_rejects_duplicate_replica_vm() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let p = seed_prereqs(&pool).await;
    let repo = PgIndexReplicaRepo::new(pool.clone());

    repo.create(
        p.customer_id,
        &p.tenant_id,
        p.primary_vm_id,
        p.replica_vm_id,
        "eu-central-1",
    )
    .await
    .expect("first create must succeed");

    // Same (customer_id, tenant_id, replica_vm_id) → unique violation
    let result = repo
        .create(
            p.customer_id,
            &p.tenant_id,
            p.primary_vm_id,
            p.replica_vm_id,
            "eu-central-1",
        )
        .await;

    assert!(
        matches!(result, Err(RepoError::Conflict(_))),
        "duplicate (customer, tenant, replica_vm) must return Conflict, got: {:?}",
        result
    );

    cleanup_prereqs(&pool, &p).await;
}

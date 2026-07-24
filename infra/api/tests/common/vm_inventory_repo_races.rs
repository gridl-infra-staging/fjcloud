use std::time::Duration;

use api::repos::{PgVmInventoryRepo, VmDecommissionResult, VmInventoryRepo, VmRetirementBlocker};
use sqlx::PgPool;
use tokio::time::timeout;

use super::support::pg_schema_harness::pool_in_schema;
use super::vm_inventory_reference_guard_races::{
    assert_final_state, assert_guard_rejection, seed_unassigned_tenant, wait_until_blocked,
};

pub async fn assert_repo_inventory_lock_wins_publication(schema: &str, observer: &PgPool) {
    let worker_pool = pool_in_schema(schema, 3).await;
    let repo_pool = pool_in_schema(schema, 1).await;
    let fixture = seed_unassigned_tenant(&worker_pool, "repo_inventory_first").await;
    let mut table_gate = worker_pool.begin().await.expect("begin table gate");
    sqlx::query("LOCK TABLE customer_tenants IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *table_gate)
        .await
        .expect("hold blocker-query table gate");

    let repo_pid = backend_pid(&repo_pool).await;
    let repo = PgVmInventoryRepo::new(repo_pool);
    let vm_id = fixture.vm_id;
    let retirement_task = tokio::spawn(async move {
        repo.decommission_if_unreferenced(vm_id, "repo_inventory_first_vm")
            .await
            .expect("repository retirement completes")
    });
    wait_until_blocked(observer, repo_pid).await;

    let mut publication = worker_pool.begin().await.expect("begin publication");
    let publication_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *publication)
        .await
        .expect("publication backend pid");
    let tenant_id = fixture.tenant_id.clone();
    let customer_id = fixture.customer_id;
    let publication_task = tokio::spawn(async move {
        let result = sqlx::query(
            "UPDATE customer_tenants SET vm_id = $1
             WHERE customer_id = $2 AND tenant_id = $3",
        )
        .bind(vm_id)
        .bind(customer_id)
        .bind(tenant_id)
        .execute(&mut *publication)
        .await;
        publication.rollback().await.expect("rollback publication");
        result
    });
    wait_until_blocked(observer, publication_pid).await;
    table_gate.commit().await.expect("release table gate");

    let retirement = timeout(Duration::from_secs(2), retirement_task)
        .await
        .expect("repository retirement must not deadlock")
        .expect("retirement task joins");
    assert_eq!(retirement, VmDecommissionResult::Decommissioned);
    let publication_error = timeout(Duration::from_secs(2), publication_task)
        .await
        .expect("publication must not deadlock")
        .expect("publication task joins")
        .expect_err("publication must lose after repository retirement");
    assert_guard_rejection(publication_error);
    assert_final_state(observer, &fixture, "decommissioned", None).await;
}

pub async fn assert_repo_reference_publication_wins(schema: &str, observer: &PgPool) {
    let worker_pool = pool_in_schema(schema, 2).await;
    let repo_pool = pool_in_schema(schema, 1).await;
    let fixture = seed_unassigned_tenant(&worker_pool, "repo_reference_first").await;
    let mut publication = worker_pool.begin().await.expect("begin publication");
    sqlx::query(
        "UPDATE customer_tenants SET vm_id = $1
         WHERE customer_id = $2 AND tenant_id = $3",
    )
    .bind(fixture.vm_id)
    .bind(fixture.customer_id)
    .bind(&fixture.tenant_id)
    .execute(&mut *publication)
    .await
    .expect("publish reference before retirement lock");

    let repo_pid = backend_pid(&repo_pool).await;
    let repo = PgVmInventoryRepo::new(repo_pool);
    let vm_id = fixture.vm_id;
    let retirement_task = tokio::spawn(async move {
        repo.decommission_if_unreferenced(vm_id, "repo_reference_first_vm")
            .await
            .expect("repository retirement completes")
    });
    wait_until_blocked(observer, repo_pid).await;
    publication
        .commit()
        .await
        .expect("commit publication winner");

    let retirement = timeout(Duration::from_secs(2), retirement_task)
        .await
        .expect("repository retirement must not deadlock")
        .expect("retirement task joins");
    assert_eq!(
        retirement,
        VmDecommissionResult::Blocked(vec![VmRetirementBlocker {
            owner: "customer_tenants".to_string(),
            reference_column: "vm_id".to_string(),
            count: 1,
        }])
    );
    assert_final_state(observer, &fixture, "active", Some(fixture.vm_id)).await;
}

async fn backend_pid(pool: &PgPool) -> i32 {
    sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(pool)
        .await
        .expect("capture repository backend pid")
}

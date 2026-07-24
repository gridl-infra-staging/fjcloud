use std::time::Duration;

use sqlx::{PgPool, Row};
use tokio::sync::oneshot;
use tokio::time::{sleep, timeout};
use uuid::Uuid;

use super::support::pg_schema_harness::pool_in_schema;
use super::vm_inventory_reference_guard_fixtures::{
    insert_customer, insert_deployment, insert_tenant_without_vm, insert_vm,
};

pub async fn assert_inventory_lock_wins_reference_publication(schema: &str, observer: &PgPool) {
    let pool = pool_in_schema(schema, 3).await;
    let fixture = seed_unassigned_tenant(&pool, "inventory_first").await;
    let mut retirement = pool.begin().await.expect("begin retirement transaction");
    sqlx::query("SELECT id FROM vm_inventory WHERE id = $1 FOR UPDATE")
        .bind(fixture.vm_id)
        .fetch_one(&mut *retirement)
        .await
        .expect("lock inventory row first");

    let mut publication = pool.begin().await.expect("begin publication transaction");
    let publication_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *publication)
        .await
        .expect("publication backend pid");
    sqlx::query(
        "SELECT tenant_id FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = $2 FOR UPDATE",
    )
    .bind(fixture.customer_id)
    .bind(&fixture.tenant_id)
    .fetch_one(&mut *publication)
    .await
    .expect("lock reference row first");

    let publication_tenant_id = fixture.tenant_id.clone();
    let vm_id = fixture.vm_id;
    let customer_id = fixture.customer_id;
    let publication_task = tokio::spawn(async move {
        let result = sqlx::query(
            "UPDATE customer_tenants SET vm_id = $1
             WHERE customer_id = $2 AND tenant_id = $3",
        )
        .bind(vm_id)
        .bind(customer_id)
        .bind(&publication_tenant_id)
        .execute(&mut *publication)
        .await;
        publication.rollback().await.expect("rollback publication");
        result
    });
    wait_until_blocked(observer, publication_pid).await;

    let blocker_total: i64 = sqlx::query_scalar(
        "SELECT COALESCE(SUM(blocker_count), 0)::bigint
         FROM vm_inventory_reference_blockers($1)",
    )
    .bind(vm_id)
    .fetch_one(&mut *retirement)
    .await
    .expect("read blocker total while reference row is locked");
    assert_eq!(blocker_total, 0);
    sqlx::query("UPDATE vm_inventory SET status = 'decommissioned' WHERE id = $1")
        .bind(vm_id)
        .execute(&mut *retirement)
        .await
        .expect("decommission unreferenced VM");
    retirement.commit().await.expect("commit retirement winner");

    let publication_error = timeout(Duration::from_secs(2), publication_task)
        .await
        .expect("publication must not deadlock")
        .expect("publication task joins")
        .expect_err("publication must lose after retirement commits");
    assert_guard_rejection(publication_error);
    assert_final_state(observer, &fixture, "decommissioned", None).await;
}

pub async fn assert_reference_publication_wins_inventory_lock(schema: &str, observer: &PgPool) {
    let pool = pool_in_schema(schema, 3).await;
    let fixture = seed_unassigned_tenant(&pool, "reference_first").await;
    let mut publication = pool.begin().await.expect("begin publication transaction");
    sqlx::query(
        "SELECT tenant_id FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = $2 FOR UPDATE",
    )
    .bind(fixture.customer_id)
    .bind(&fixture.tenant_id)
    .fetch_one(&mut *publication)
    .await
    .expect("lock reference row first");
    sqlx::query(
        "UPDATE customer_tenants SET vm_id = $1
         WHERE customer_id = $2 AND tenant_id = $3",
    )
    .bind(fixture.vm_id)
    .bind(fixture.customer_id)
    .bind(&fixture.tenant_id)
    .execute(&mut *publication)
    .await
    .expect("publish reference while VM is active");

    let (pid_sender, pid_receiver) = oneshot::channel();
    let retirement_pool = pool.clone();
    let vm_id = fixture.vm_id;
    let retirement_task = tokio::spawn(async move {
        let mut retirement = retirement_pool
            .begin()
            .await
            .expect("begin retirement transaction");
        let retirement_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&mut *retirement)
            .await
            .expect("retirement backend pid");
        pid_sender
            .send(retirement_pid)
            .expect("send retirement pid");
        sqlx::query("SELECT id FROM vm_inventory WHERE id = $1 FOR UPDATE")
            .bind(vm_id)
            .fetch_one(&mut *retirement)
            .await
            .expect("lock inventory after publication");
        let blocker_total: i64 = sqlx::query_scalar(
            "SELECT COALESCE(SUM(blocker_count), 0)::bigint
             FROM vm_inventory_reference_blockers($1)",
        )
        .bind(vm_id)
        .fetch_one(&mut *retirement)
        .await
        .expect("read blockers after publication commits");
        retirement
            .commit()
            .await
            .expect("commit blocked retirement");
        blocker_total
    });
    let retirement_pid = pid_receiver.await.expect("receive retirement pid");
    wait_until_blocked(observer, retirement_pid).await;
    publication
        .commit()
        .await
        .expect("commit publication winner");

    let blocker_total = timeout(Duration::from_secs(2), retirement_task)
        .await
        .expect("retirement must not deadlock")
        .expect("retirement task joins");
    assert_eq!(
        blocker_total, 1,
        "committed tenant reference must block retirement"
    );
    assert_final_state(observer, &fixture, "active", Some(fixture.vm_id)).await;
}

pub(super) struct ReferenceRaceFixture {
    pub vm_id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
}

pub(super) async fn seed_unassigned_tenant(pool: &PgPool, label: &str) -> ReferenceRaceFixture {
    let vm_id = insert_vm(pool, &format!("{label}_vm"), "active").await;
    let customer_id = insert_customer(pool, label).await;
    let deployment_id = insert_deployment(pool, customer_id, &format!("{label}_node")).await;
    let tenant_id = format!("{label}_tenant");
    insert_tenant_without_vm(pool, customer_id, deployment_id, &tenant_id).await;
    ReferenceRaceFixture {
        vm_id,
        customer_id,
        tenant_id,
    }
}

pub(super) async fn wait_until_blocked(observer: &PgPool, backend_pid: i32) {
    timeout(Duration::from_secs(2), async {
        loop {
            let blocked: bool = sqlx::query_scalar("SELECT cardinality(pg_blocking_pids($1)) > 0")
                .bind(backend_pid)
                .fetch_one(observer)
                .await
                .expect("inspect PostgreSQL blockers");
            if blocked {
                return;
            }
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("transaction must reach the intended lock wait");
}

pub(super) async fn assert_final_state(
    pool: &PgPool,
    fixture: &ReferenceRaceFixture,
    expected_status: &str,
    expected_reference: Option<Uuid>,
) {
    let status: String = sqlx::query_scalar("SELECT status FROM vm_inventory WHERE id = $1")
        .bind(fixture.vm_id)
        .fetch_one(pool)
        .await
        .expect("read final inventory status");
    let reference: Option<Uuid> =
        sqlx::query("SELECT vm_id FROM customer_tenants WHERE customer_id = $1 AND tenant_id = $2")
            .bind(fixture.customer_id)
            .bind(&fixture.tenant_id)
            .fetch_one(pool)
            .await
            .expect("read final tenant reference")
            .get("vm_id");
    assert_eq!(status, expected_status);
    assert_eq!(reference, expected_reference);
}

pub(super) fn assert_guard_rejection(error: sqlx::Error) {
    let database_error = error
        .as_database_error()
        .expect("guard returns database error");
    assert_eq!(database_error.code().as_deref(), Some("23514"));
    assert!(database_error
        .message()
        .contains("vm_inventory reference customer_tenants.vm_id"));
}

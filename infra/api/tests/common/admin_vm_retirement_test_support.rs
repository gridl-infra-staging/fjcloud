use std::sync::Arc;

use api::repos::PgVmInventoryRepo;
use api::router::build_router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use serde_json::json;
use sqlx::PgPool;
use tokio::time::{timeout, Duration};
use tower::ServiceExt;
use uuid::Uuid;

use super::support::pg_schema_harness::pool_in_schema;
use super::vm_inventory_reference_guard_fixtures::{
    insert_algolia_import_job, insert_cold_snapshot, insert_customer, insert_deployment,
    insert_index_migration, insert_index_replica, insert_restore_job, AlgoliaReservationState,
    EXPECTED_VM_REFERENCE_COLUMNS,
};
use super::vm_inventory_reference_guard_races::{
    assert_final_state, assert_guard_rejection, seed_unassigned_tenant, wait_until_blocked,
};
use super::TestStateBuilder;

pub fn admin_vm_pg_test_app(pool: PgPool) -> Router {
    let mut state = TestStateBuilder::new().with_pool(pool.clone()).build();
    state.vm_inventory_repo = Arc::new(PgVmInventoryRepo::new(pool));
    build_router(state)
}

pub fn expected_live_blockers_json() -> serde_json::Value {
    let mut blockers = EXPECTED_VM_REFERENCE_COLUMNS
        .iter()
        .map(|(owner, reference_column)| {
            json!({
                "owner": owner,
                "reference_column": reference_column,
                "count": 1
            })
        })
        .collect::<Vec<_>>();
    blockers.sort_by(|left, right| {
        (
            left["owner"].as_str().unwrap(),
            left["reference_column"].as_str().unwrap(),
        )
            .cmp(&(
                right["owner"].as_str().unwrap(),
                right["reference_column"].as_str().unwrap(),
            ))
    });
    json!(blockers)
}

pub async fn insert_terminal_reference_modes(
    pool: &PgPool,
    vm_id: Uuid,
    other_vm_id: Uuid,
    label: &str,
) {
    let customer_id = insert_customer(pool, label).await;
    let deployment_id = insert_deployment(pool, customer_id, &format!("{label}-node")).await;
    super::vm_inventory_reference_guard_fixtures::insert_tenant_without_vm(
        pool,
        customer_id,
        deployment_id,
        &format!("{label}_tenant_without_vm"),
    )
    .await;
    insert_index_migration(
        pool,
        customer_id,
        &format!("{label}_completed_migration"),
        vm_id,
        vm_id,
        "completed",
    )
    .await
    .expect("insert completed migration");
    insert_cold_snapshot(
        pool,
        customer_id,
        &format!("{label}_failed_snapshot"),
        vm_id,
        "failed",
    )
    .await
    .expect("insert failed snapshot");
    insert_restore_job(
        pool,
        customer_id,
        &format!("{label}_completed_restore"),
        other_vm_id,
        vm_id,
        "completed",
    )
    .await
    .expect("insert completed restore");
    insert_terminal_replica_tenant(pool, customer_id, deployment_id, label, "suspended").await;
    insert_terminal_replica_tenant(pool, customer_id, deployment_id, label, "removing").await;
    insert_index_replica(
        pool,
        customer_id,
        &format!("{label}_suspended_replica"),
        vm_id,
        other_vm_id,
        "suspended",
    )
    .await
    .expect("insert suspended replica");
    insert_index_replica(
        pool,
        customer_id,
        &format!("{label}_removing_replica"),
        other_vm_id,
        vm_id,
        "removing",
    )
    .await
    .expect("insert removing replica");
    insert_algolia_import_job(
        pool,
        customer_id,
        &format!("{label}_terminal_algolia"),
        vm_id,
        AlgoliaReservationState {
            status: "completed",
            publication_disposition: "promoted",
            resumable: false,
            engine_ack_state: "acknowledged",
        },
    )
    .await
    .expect("insert terminal Algolia reservation");
}

pub async fn inventory_status(pool: &PgPool, vm_id: Uuid) -> String {
    sqlx::query_scalar("SELECT status FROM vm_inventory WHERE id = $1")
        .bind(vm_id)
        .fetch_one(pool)
        .await
        .expect("query vm_inventory status")
}

pub async fn assert_admin_route_inventory_lock_wins_publication(
    schema: &str,
    observer: &PgPool,
    admin_key: &str,
) {
    let worker_pool = pool_in_schema(schema, 3).await;
    let route_pool = pool_in_schema(schema, 1).await;
    let fixture = seed_unassigned_tenant(&worker_pool, "admin_route_inventory_first").await;
    let mut table_gate = worker_pool.begin().await.expect("begin table gate");
    sqlx::query("LOCK TABLE customer_tenants IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *table_gate)
        .await
        .expect("hold blocker-query table gate");

    let route_pid = backend_pid(&route_pool).await;
    let route_task = spawn_decommission_request(
        admin_vm_pg_test_app(route_pool),
        fixture.vm_id,
        "admin_route_inventory_first_vm",
        admin_key,
    );
    wait_until_blocked(observer, route_pid).await;

    let publication_task = spawn_reference_publication(&worker_pool, &fixture).await;
    table_gate.commit().await.expect("release table gate");

    let route_response = timeout(Duration::from_secs(2), route_task)
        .await
        .expect("route retirement must not deadlock")
        .expect("route task joins");
    assert_eq!(route_response.status(), StatusCode::OK);
    assert_eq!(
        response_json(route_response).await["result"],
        "decommissioned"
    );
    let publication_error = timeout(Duration::from_secs(2), publication_task)
        .await
        .expect("publication must not deadlock")
        .expect("publication task joins")
        .expect_err("publication must lose after retirement commits");
    assert_guard_rejection(publication_error);
    assert_final_state(observer, &fixture, "decommissioned", None).await;
}

pub async fn assert_admin_route_reference_publication_wins(
    schema: &str,
    observer: &PgPool,
    admin_key: &str,
) {
    let worker_pool = pool_in_schema(schema, 2).await;
    let route_pool = pool_in_schema(schema, 1).await;
    let fixture = seed_unassigned_tenant(&worker_pool, "admin_route_reference_first").await;
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

    let route_pid = backend_pid(&route_pool).await;
    let route_task = spawn_decommission_request(
        admin_vm_pg_test_app(route_pool),
        fixture.vm_id,
        "admin_route_reference_first_vm",
        admin_key,
    );
    wait_until_blocked(observer, route_pid).await;
    publication
        .commit()
        .await
        .expect("commit publication winner");

    let route_response = timeout(Duration::from_secs(2), route_task)
        .await
        .expect("route retirement must not deadlock")
        .expect("route task joins");
    assert_eq!(route_response.status(), StatusCode::CONFLICT);
    assert_eq!(response_json(route_response).await["result"], "blocked");
    assert_final_state(observer, &fixture, "active", Some(fixture.vm_id)).await;
}

async fn insert_terminal_replica_tenant(
    pool: &PgPool,
    customer_id: Uuid,
    deployment_id: Uuid,
    label: &str,
    status: &str,
) {
    super::vm_inventory_reference_guard_fixtures::insert_tenant_without_vm(
        pool,
        customer_id,
        deployment_id,
        &format!("{label}_{status}_replica"),
    )
    .await;
}

async fn spawn_reference_publication(
    pool: &PgPool,
    fixture: &super::vm_inventory_reference_guard_races::ReferenceRaceFixture,
) -> tokio::task::JoinHandle<Result<sqlx::postgres::PgQueryResult, sqlx::Error>> {
    let mut publication = pool.begin().await.expect("begin publication");
    let tenant_id = fixture.tenant_id.clone();
    let customer_id = fixture.customer_id;
    let vm_id = fixture.vm_id;
    tokio::spawn(async move {
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
    })
}

fn spawn_decommission_request(
    app: Router,
    vm_id: Uuid,
    expected_hostname: &str,
    admin_key: &str,
) -> tokio::task::JoinHandle<axum::response::Response> {
    let expected_hostname = expected_hostname.to_string();
    let admin_key = admin_key.to_string();
    tokio::spawn(async move {
        app.oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{vm_id}/decommission"))
                .header("x-admin-key", admin_key)
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "expected_hostname": expected_hostname }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .expect("route decommission request")
    })
}

async fn response_json(response: axum::response::Response) -> serde_json::Value {
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&body).unwrap()
}

async fn backend_pid(pool: &PgPool) -> i32 {
    sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(pool)
        .await
        .expect("capture route backend pid")
}

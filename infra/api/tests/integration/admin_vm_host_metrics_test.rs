use api::models::NewVmHostMetrics;
use api::repos::{PgVmHostMetricsRepo, PgVmInventoryRepo, VmHostMetricsRepo};
use api::router::build_router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{TimeZone, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::connect_and_migrate;
use crate::common::vm_inventory_reference_guard_fixtures::insert_vm;
use crate::common::{TestStateBuilder, TEST_ADMIN_KEY};

async fn response_json(response: axum::response::Response) -> Value {
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&body).unwrap()
}

fn new_metrics(
    vm_id: Uuid,
    collected_at: chrono::DateTime<Utc>,
    cpu_pct: f64,
    disk_used_bytes: Option<i64>,
    disk_total_bytes: Option<i64>,
) -> NewVmHostMetrics {
    NewVmHostMetrics {
        vm_id,
        collected_at,
        cpu_pct,
        mem_used_bytes: 5_368_709_120,
        mem_total_bytes: 8_589_934_592,
        disk_used_bytes,
        disk_total_bytes,
        net_rx_bytes: 223_456_789,
        net_tx_bytes: 198_765_432,
    }
}

fn admin_request(path: String) -> Request<Body> {
    Request::builder()
        .method("GET")
        .uri(path)
        .header("X-Admin-Key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap()
}

async fn postgres_backed_admin_app(pool: sqlx::PgPool) -> (axum::Router, Arc<PgVmHostMetricsRepo>) {
    let vm_inventory_repo = Arc::new(PgVmInventoryRepo::new(pool.clone()));
    let vm_host_metrics_repo = Arc::new(PgVmHostMetricsRepo::new(pool.clone()));
    let mut state = TestStateBuilder::new().with_pool(pool).build();
    state.vm_inventory_repo = vm_inventory_repo;
    state.vm_host_metrics_repo = vm_host_metrics_repo.clone();
    (build_router(state), vm_host_metrics_repo)
}

#[tokio::test]
async fn admin_vm_host_metrics_returns_latest_sample_with_canonical_shape() {
    let db = connect_and_migrate("it_admin_vm_host_metrics_latest")
        .await
        .expect("DATABASE_URL and PostgreSQL are required for admin host metrics route tests");
    let vm_id = insert_vm(&db.pool, "admin-host-metrics-latest", "active").await;
    let (app, metrics_repo) = postgres_backed_admin_app(db.pool.clone()).await;
    let older_at = Utc
        .with_ymd_and_hms(2026, 7, 20, 12, 0, 0)
        .single()
        .expect("valid older timestamp");
    let newer_at = Utc
        .with_ymd_and_hms(2026, 7, 20, 12, 5, 0)
        .single()
        .expect("valid newer timestamp");

    metrics_repo
        .insert(&new_metrics(vm_id, older_at, 37.5, None, None))
        .await
        .expect("insert older host metrics sample");
    let newer = metrics_repo
        .insert(&new_metrics(
            vm_id,
            newer_at,
            62.25,
            Some(53_687_091_200),
            Some(107_374_182_400),
        ))
        .await
        .expect("insert newer host metrics sample");

    let response = app
        .oneshot(admin_request(format!("/admin/vms/{vm_id}/host-metrics")))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({
            "id": newer.id,
            "vm_id": vm_id,
            "collected_at": newer.collected_at,
            "cpu_pct": 62.25,
            "mem_used_bytes": 5_368_709_120i64,
            "mem_total_bytes": 8_589_934_592i64,
            "disk_used_bytes": 53_687_091_200i64,
            "disk_total_bytes": 107_374_182_400i64,
            "net_rx_bytes": 223_456_789i64,
            "net_tx_bytes": 198_765_432i64,
            "created_at": newer.created_at,
        })
    );
}

#[tokio::test]
async fn admin_vm_host_metrics_requires_admin_key() {
    let db = connect_and_migrate("it_admin_vm_host_metrics_auth")
        .await
        .expect("DATABASE_URL and PostgreSQL are required for admin host metrics route tests");
    let vm_id = insert_vm(&db.pool, "admin-host-metrics-auth", "active").await;
    let (app, _metrics_repo) = postgres_backed_admin_app(db.pool.clone()).await;

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{vm_id}/host-metrics"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_vm_host_metrics_returns_404_for_unknown_vm() {
    let db = connect_and_migrate("it_admin_vm_host_metrics_unknown")
        .await
        .expect("DATABASE_URL and PostgreSQL are required for admin host metrics route tests");
    let (app, _metrics_repo) = postgres_backed_admin_app(db.pool.clone()).await;
    let unknown_vm_id = Uuid::new_v4();

    let response = app
        .oneshot(admin_request(format!(
            "/admin/vms/{unknown_vm_id}/host-metrics"
        )))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_vm_host_metrics_returns_null_for_existing_vm_without_samples() {
    let db = connect_and_migrate("it_admin_vm_host_metrics_empty")
        .await
        .expect("DATABASE_URL and PostgreSQL are required for admin host metrics route tests");
    let vm_id = insert_vm(&db.pool, "admin-host-metrics-empty", "active").await;
    let (app, _metrics_repo) = postgres_backed_admin_app(db.pool.clone()).await;

    let response = app
        .oneshot(admin_request(format!("/admin/vms/{vm_id}/host-metrics")))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response_json(response).await, Value::Null);
}

use std::sync::Arc;

use api::repos::{PgCustomerRepo, PgUsageRepo};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    connect_isolated_and_migrate, create_active_customer, install_scoped_audit_failure_trigger,
    register_operator,
};
use crate::common::TestStateBuilder;

const ACTION_DAILY_USAGE_UPSERTED: &str = "daily_usage_upserted";
const ACTION_DAILY_USAGE_DELETED: &str = "daily_usage_deleted";

fn app_with_pg_usage(pool: PgPool) -> axum::Router {
    let mut state = TestStateBuilder::new().with_pool(pool.clone()).build();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    state.usage_repo = Arc::new(PgUsageRepo::new(pool));
    api::router::build_router(state)
}

fn usage_seed_request(customer_id: Uuid, admin_credential: &str) -> Request<Body> {
    Request::post(format!("/admin/tenants/{customer_id}/usage"))
        .header("x-admin-key", admin_credential)
        .header("content-type", "application/json")
        .body(Body::from(
            json!({
                "entries": [
                    {
                        "date": "2026-08-01",
                        "region": "us-east-1",
                        "search_requests": 1037,
                        "write_operations": 111,
                        "storage_bytes_avg": 2147483648_i64,
                        "documents_count_avg": 50000
                    },
                    {
                        "date": "2026-08-02",
                        "region": "eu-west-1",
                        "search_requests": 1074,
                        "write_operations": 122,
                        "storage_bytes_avg": 2147483648_i64,
                        "documents_count_avg": 50000
                    }
                ]
            })
            .to_string(),
        ))
        .unwrap()
}

fn usage_delete_request(customer_id: Uuid, admin_credential: &str, region: &str) -> Request<Body> {
    Request::delete(format!("/admin/tenants/{customer_id}/usage"))
        .header("x-admin-key", admin_credential)
        .header("content-type", "application/json")
        .body(Body::from(
            json!({"month": "2026-08", "region": region}).to_string(),
        ))
        .unwrap()
}

async fn audit_receipt(
    pool: &PgPool,
    action: &str,
    customer_id: Uuid,
) -> Option<(Uuid, Option<Uuid>, Value)> {
    sqlx::query_as(
        "SELECT actor_id, target_tenant_id, metadata FROM audit_log \
         WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(action)
    .bind(customer_id)
    .fetch_optional(pool)
    .await
    .expect("read usage mutation audit receipt")
}

async fn usage_row_count(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*)::BIGINT FROM usage_daily WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer usage rows")
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn admin_usage_mutations_record_operator_target_scope_and_count() {
    let db = connect_isolated_and_migrate("admin_usage_audit_success").await;
    let (operator_id, credential) = register_operator(
        &db.pool,
        &format!("usage-audit-success-{}@example.com", Uuid::new_v4()),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Usage Audit Success").await;
    let app = app_with_pg_usage(db.pool.clone());

    let seed_response = app
        .clone()
        .oneshot(usage_seed_request(customer_id, &credential))
        .await
        .unwrap();
    let seed_receipt = audit_receipt(&db.pool, ACTION_DAILY_USAGE_UPSERTED, customer_id).await;

    let delete_response = app
        .oneshot(usage_delete_request(customer_id, &credential, "us-east-1"))
        .await
        .unwrap();
    let delete_receipt = audit_receipt(&db.pool, ACTION_DAILY_USAGE_DELETED, customer_id).await;

    assert_eq!(seed_response.status(), StatusCode::CREATED);
    assert_eq!(
        seed_receipt,
        Some((
            operator_id,
            Some(customer_id),
            json!({
                "dates": ["2026-08-01", "2026-08-02"],
                "months": ["2026-08"],
                "regions": ["eu-west-1", "us-east-1"],
                "mutation_count": 2
            })
        ))
    );
    assert_eq!(delete_response.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        delete_receipt,
        Some((
            operator_id,
            Some(customer_id),
            json!({
                "month": "2026-08",
                "start_date": "2026-08-01",
                "end_date": "2026-08-31",
                "region": "us-east-1",
                "mutation_count": 1
            })
        ))
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn admin_usage_upsert_rolls_back_when_audit_insert_fails() {
    let db = connect_isolated_and_migrate("admin_usage_upsert_audit_failure").await;
    let (operator_id, credential) = register_operator(
        &db.pool,
        &format!("usage-upsert-failure-{}@example.com", Uuid::new_v4()),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Usage Upsert Failure").await;
    install_scoped_audit_failure_trigger(
        &db.pool,
        ACTION_DAILY_USAGE_UPSERTED,
        operator_id,
        Some(customer_id),
    )
    .await;

    let response = app_with_pg_usage(db.pool.clone())
        .oneshot(usage_seed_request(customer_id, &credential))
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let row_count = usage_row_count(&db.pool, customer_id).await;

    assert_eq!(
        (status, body.is_empty(), row_count),
        (StatusCode::INTERNAL_SERVER_ERROR, false, 0),
        "audit failure must reject and roll back the usage upsert"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn admin_usage_delete_rolls_back_when_audit_insert_fails() {
    let db = connect_isolated_and_migrate("admin_usage_delete_audit_failure").await;
    let (operator_id, credential) = register_operator(
        &db.pool,
        &format!("usage-delete-failure-{}@example.com", Uuid::new_v4()),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Usage Delete Failure").await;
    sqlx::query(
        "INSERT INTO usage_daily \
         (customer_id, date, region, search_requests, write_operations, \
          storage_bytes_avg, documents_count_avg) \
         VALUES ($1, '2026-08-01', 'us-east-1', 1037, 111, 2147483648, 50000)",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("arrange usage row for audited deletion");
    install_scoped_audit_failure_trigger(
        &db.pool,
        ACTION_DAILY_USAGE_DELETED,
        operator_id,
        Some(customer_id),
    )
    .await;

    let response = app_with_pg_usage(db.pool.clone())
        .oneshot(usage_delete_request(customer_id, &credential, "us-east-1"))
        .await
        .unwrap();
    let status = response.status();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let row_count = usage_row_count(&db.pool, customer_id).await;

    assert_eq!(
        (status, body.is_empty(), row_count),
        (StatusCode::INTERNAL_SERVER_ERROR, false, 1),
        "audit failure must reject and roll back the usage deletion"
    );
}

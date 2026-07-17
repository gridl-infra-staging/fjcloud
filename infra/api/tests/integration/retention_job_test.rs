use std::sync::Arc;

use api::repos::{CustomerRepo, PgCustomerRepo};
use axum::Router;
use chrono::{Duration, Utc};
use retention_job::job::{run_retention, HttpHardEraseClient, RetentionSummary, RunOptions};

use crate::common::support::pg_schema_harness;

async fn serve_app(app: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind retention-job API test listener");
    let addr = listener
        .local_addr()
        .expect("read retention-job API test listener address");
    let handle = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve retention-job API test app");
    });

    (format!("http://127.0.0.1:{}", addr.port()), handle)
}

async fn force_deleted_at(
    pool: &sqlx::PgPool,
    customer_id: uuid::Uuid,
    deleted_at: chrono::DateTime<Utc>,
) {
    sqlx::query("UPDATE customers SET deleted_at = $1, updated_at = $1 WHERE id = $2")
        .bind(deleted_at)
        .bind(customer_id)
        .execute(pool)
        .await
        .expect("force deleted_at retention fixture");
}

#[tokio::test]
async fn retention_job_erases_only_api_selected_eligible_customer() {
    let Some(db) = pg_schema_harness::connect_and_migrate("it_retention_job").await else {
        return;
    };
    let pool = db.pool.clone();
    let repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    let eligible = repo
        .create("Eligible Delete", "retention-eligible@example.test")
        .await
        .expect("create eligible customer");
    let newer = repo
        .create("Newer Delete", "retention-newer@example.test")
        .await
        .expect("create newer customer");

    repo.soft_delete(eligible.id)
        .await
        .expect("soft delete eligible customer");
    repo.soft_delete(newer.id)
        .await
        .expect("soft delete newer customer");

    let now = Utc::now();
    let cutoff = now - Duration::days(30);
    force_deleted_at(&pool, eligible.id, cutoff - Duration::seconds(1)).await;
    force_deleted_at(&pool, newer.id, cutoff + Duration::seconds(1)).await;

    let mut state = crate::common::TestStateBuilder::new().build();
    state.pool = pool.clone();
    state.customer_repo = repo.clone();
    let (api_url, server) = serve_app(api::router::build_router(state)).await;

    let eraser = HttpHardEraseClient::new(api_url, crate::common::TEST_ADMIN_KEY.to_string());
    let summary = run_retention(
        repo.as_ref(),
        &eraser,
        RunOptions {
            now,
            retention_days: 30,
            dry_run: false,
            max_erase_per_run: 25,
        },
    )
    .await
    .expect("run retention job against API route");

    assert_eq!(
        summary,
        RetentionSummary {
            candidates: 1,
            erased: 1,
            failed: 0,
            skipped_by_bound: 0,
        }
    );
    assert!(
        repo.find_by_id(eligible.id)
            .await
            .expect("find eligible after retention job")
            .is_none(),
        "eligible soft-deleted customer should be hard-erased through the admin route"
    );
    let retained_newer = repo
        .find_by_id(newer.id)
        .await
        .expect("find newer deleted customer")
        .expect("newer deleted customer should remain");
    assert_eq!(retained_newer.status, "deleted");

    server.abort();
}

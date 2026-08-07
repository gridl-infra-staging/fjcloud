use super::*;

#[tokio::test]
async fn postgres_reconcile_once_migration_067_upgrades_existing_erased_compaction_contract() {
    let Some(db) = connect_and_migrate_through("algolia_reconcile_migration_067_upgrade", 66).await
    else {
        return;
    };
    let applied_before: i64 = sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations")
        .fetch_one(&db.pool)
        .await
        .expect("read pre-upgrade migration version");
    assert_eq!(applied_before, 66);

    let destination_vm_id = seed_active_vm(&db.pool).await;
    let pending = privacy_scrub_legacy_schema_fixtures::seed_migration_067_erased_specimen_on_vm(
        &db.pool,
        "migration-067-pending-erased",
        destination_vm_id,
    )
    .await;
    let acknowledged =
        privacy_scrub_legacy_schema_fixtures::seed_migration_067_erased_specimen_on_vm(
            &db.pool,
            "migration-067-acknowledged-erased",
            destination_vm_id,
        )
        .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET cleanup_phase = 'exact_target_absent',
             engine_ack_state = 'acknowledged'
         WHERE id = $1",
    )
    .bind(acknowledged.job_id)
    .execute(&db.pool)
    .await
    .expect("seed acknowledged uncompacted erased row under migration 066");

    migrate_through_version(&db.pool, 67)
        .await
        .expect("apply migration 067 to existing erased rows");
    let applied_after: i64 = sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations")
        .fetch_one(&db.pool)
        .await
        .expect("read upgraded migration version");
    assert_eq!(applied_after, 67);

    let premature_compaction = sqlx::query(
        "UPDATE algolia_import_jobs
         SET tombstone_compacted_at = $2, erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(pending.job_id)
    .bind(postgres_timestamp(Utc::now()))
    .execute(&db.pool)
    .await;
    assert!(
        premature_compaction.is_err(),
        "migration 067 must reject compaction without exact-absence ACK"
    );

    let compacted_at = postgres_timestamp(Utc::now());
    let valid_compaction = sqlx::query(
        "UPDATE algolia_import_jobs
         SET tombstone_compacted_at = $2, erasure_handle = NULL
         WHERE id = $1",
    )
    .bind(acknowledged.job_id)
    .bind(compacted_at)
    .execute(&db.pool)
    .await
    .expect("migration 067 permits exactly acknowledged exact-absence compaction");
    assert_eq!(valid_compaction.rows_affected(), 1);

    let rows: Vec<(Uuid, String, String, Option<Uuid>, Option<DateTime<Utc>>)> = sqlx::query_as(
        "SELECT id, cleanup_phase, engine_ack_state, erasure_handle, tombstone_compacted_at
         FROM algolia_import_jobs
         WHERE id = ANY($1)
         ORDER BY id",
    )
    .bind(vec![pending.job_id, acknowledged.job_id])
    .fetch_all(&db.pool)
    .await
    .expect("read upgraded erased compaction specimens");
    let pending_row = rows
        .iter()
        .find(|row| row.0 == pending.job_id)
        .expect("pending upgraded specimen remains");
    assert_eq!(pending_row.1, "exact_target_absence_required");
    assert_eq!(pending_row.2, "pending");
    assert_eq!(pending_row.3, Some(pending.erasure_handle));
    assert_eq!(pending_row.4, None);
    let acknowledged_row = rows
        .iter()
        .find(|row| row.0 == acknowledged.job_id)
        .expect("acknowledged upgraded specimen remains");
    assert_eq!(acknowledged_row.1, "exact_target_absent");
    assert_eq!(acknowledged_row.2, "acknowledged");
    assert_eq!(acknowledged_row.3, None);
    assert_eq!(acknowledged_row.4, Some(compacted_at));
}

/// Reconciliation claims oldest-updated-first with a bounded batch. A scrub
/// attempt that fails must therefore advance its tombstone's `updated_at` the
/// same way a failed import observation does, otherwise a permanently doomed
/// tombstone keeps the oldest timestamp, wins the front of every batch, and
/// starves live imports out of reconciliation entirely.
#[tokio::test]
async fn postgres_failed_scrub_rotates_behind_a_live_import_instead_of_starving_it() {
    let Some(db) = connect_and_migrate("algolia_scrub_rotates_behind_import").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let specimen =
        seed_privacy_scrub_specimen_on_vm(&db.pool, "privacy-scrub-starvation-canary", None, vm_id)
            .await;
    let import_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, import_customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let import_engine_job_id = Uuid::new_v4();
    prepare_running_create_job(
        &repo,
        &db.pool,
        import_customer_id,
        vm_id,
        import_engine_job_id,
        "scrub-starvation-live-import",
    )
    .await;
    let (service, http) = service_harness(vec![
        Err(ProxyError::Unreachable(
            "scrub delivery is permanently failing".to_string(),
        )),
        running_response(import_engine_job_id),
    ])
    .await;
    let runtime = reconciliation_runtime(&db.pool);
    let first_attempt_at = postgres_timestamp(Utc::now());

    let first = service
        .reconcile_once(&runtime, first_attempt_at)
        .await
        .expect("the oldest tombstone is claimed first");

    assert_eq!(first.claimed, 1);
    assert_eq!(
        captured_privacy_scrub_requests(&http).len(),
        1,
        "the first bounded batch belongs to the tombstone"
    );

    let second_attempt_at = first_attempt_at + config().lease_duration + Duration::seconds(1);
    let second = service
        .reconcile_once(&runtime, second_attempt_at)
        .await
        .expect("the next batch must reach the live import");

    assert_eq!(second.claimed, 1);
    assert_eq!(
        captured_privacy_scrub_requests(&http).len(),
        1,
        "a failed scrub must not win the front of the batch a second time"
    );
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::GET);
    assert!(
        requests[0]
            .url
            .ends_with(&format!("/1/migrations/algolia/{import_engine_job_id}")),
        "the second batch must poll the live import, got {}",
        requests[0].url
    );
    assert_ne!(specimen.job_id, Uuid::nil());
}

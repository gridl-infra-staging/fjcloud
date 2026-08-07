use super::*;

#[tokio::test]
async fn postgres_reconciliation_orders_older_erased_tombstone_with_full_public_batch() {
    let Some(db) = connect_and_migrate("algolia_reconcile_erased_scrub_fairness").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let claim_at = postgres_timestamp(Utc::now());

    let erased_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, erased_customer, 1).await;
    let erased = prepare_running_create_job(
        &repo,
        &db.pool,
        erased_customer,
        vm_id,
        Uuid::new_v4(),
        "older-erased-fairness",
    )
    .await;
    let scrub_work = hard_erase_customer(&db.pool, erased_customer).await;
    let erased_updated_at = claim_at - Duration::minutes(5);
    sqlx::query("UPDATE algolia_import_jobs SET updated_at = $2 WHERE id = $1")
        .bind(erased.id)
        .bind(erased_updated_at)
        .execute(&db.pool)
        .await
        .expect("backdate erased fairness specimen");

    let mut public_ids = Vec::new();
    for ordinal in 0..2 {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let job = prepare_running_create_job(
            &repo,
            &db.pool,
            customer_id,
            vm_id,
            Uuid::new_v4(),
            &format!("newer-public-fairness-{ordinal}"),
        )
        .await;
        sqlx::query("UPDATE algolia_import_jobs SET updated_at = $2 WHERE id = $1")
            .bind(job.id)
            .bind(claim_at - Duration::minutes(4 - ordinal))
            .execute(&db.pool)
            .await
            .expect("order public fairness specimen");
        public_ids.push(job.id);
    }

    let lease_expires_at = claim_at + Duration::minutes(5);
    let claims = repo
        .claim_reconciliation_jobs(claim_at, lease_expires_at, 2)
        .await
        .expect("claim one globally ordered bounded reconciliation batch");
    let claimed_ids: Vec<_> = claims.iter().map(|claim| claim.job.id).collect();
    assert_eq!(
        claimed_ids,
        vec![erased.id, public_ids[0]],
        "an older unsent tombstone must not be starved by a full newer public-job batch"
    );
    assert!(matches!(
        claims[0].work,
        AlgoliaImportReconciliationWork::ErasedTombstone(_)
    ));
    assert!(matches!(
        claims[1].work,
        AlgoliaImportReconciliationWork::Import
    ));

    let erased_lease: (Option<DateTime<Utc>>, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT worker_claimed_at, worker_lease_expires_at
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(erased.id)
    .fetch_one(&db.pool)
    .await
    .expect("read fairly claimed erased lease");
    assert_eq!(erased_lease, (Some(claim_at), Some(lease_expires_at)));
    assert_eq!(scrub_work.len(), 1);
}

#[tokio::test]
async fn postgres_reconciliation_prioritizes_active_imports_ahead_of_cleanup_backlog() {
    let Some(db) = connect_and_migrate("algolia_reconcile_active_import_priority").await else {
        return;
    };
    let vm_id = seed_active_vm(&db.pool).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let claim_at = postgres_timestamp(Utc::now());
    let mut cleanup_job_ids = Vec::new();

    for ordinal in 0..2 {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let cleanup_job = prepare_running_create_job(
            &repo,
            &db.pool,
            customer_id,
            vm_id,
            Uuid::new_v4(),
            &format!("old-terminal-ack-backlog-{ordinal}"),
        )
        .await;
        mark_retained_terminal_ack_retry(
            &db.pool,
            cleanup_job.id,
            claim_at - Duration::minutes(10 - ordinal),
        )
        .await;
        cleanup_job_ids.push(cleanup_job.id);
    }

    for ordinal in 0..2 {
        let customer_id = Uuid::new_v4();
        insert_active_customer(&db.pool, customer_id, 1).await;
        let cleanup_job = prepare_running_create_job(
            &repo,
            &db.pool,
            customer_id,
            vm_id,
            Uuid::new_v4(),
            &format!("old-erased-scrub-backlog-{ordinal}"),
        )
        .await;
        hard_erase_customer(&db.pool, customer_id).await;
        sqlx::query("UPDATE algolia_import_jobs SET updated_at = $2 WHERE id = $1")
            .bind(cleanup_job.id)
            .bind(claim_at - Duration::minutes(8 - ordinal))
            .execute(&db.pool)
            .await
            .expect("backdate erased cleanup retry fixture");
        cleanup_job_ids.push(cleanup_job.id);
    }

    let active_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, active_customer_id, 1).await;
    let active_import = prepare_running_create_job(
        &repo,
        &db.pool,
        active_customer_id,
        vm_id,
        Uuid::new_v4(),
        "fresh-local-provider-import",
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET source_provider = $2, updated_at = $3
         WHERE id = $1",
    )
    .bind(active_import.id)
    .bind(SourceImportProvider::Typesense.as_str())
    .bind(claim_at - Duration::seconds(5))
    .execute(&db.pool)
    .await
    .expect("mark fresh provider-neutral import");

    let lease_expires_at = claim_at + Duration::minutes(5);
    let claims = repo
        .claim_reconciliation_jobs(claim_at, lease_expires_at, 4)
        .await
        .expect("claim bounded reconciliation batch");
    let claimed_ids: Vec<_> = claims.iter().map(|claim| claim.job.id).collect();

    assert_eq!(
        claims.len(),
        4,
        "the fixture must fill the whole reconciliation batch"
    );
    assert!(
        claimed_ids.contains(&active_import.id),
        "fresh active imports must not miss the only local-stack reconciliation pass inside the source-change parity gate; claimed {claimed_ids:?} instead of active {} with cleanup backlog {cleanup_job_ids:?}",
        active_import.id
    );
    assert!(
        claims.iter().any(|claim| claim.job.id == active_import.id
            && claim.job.source_provider == SourceImportProvider::Typesense
            && matches!(claim.work, AlgoliaImportReconciliationWork::Import)),
        "the active local-provider import must remain provider-neutral reconciliation work"
    );
}

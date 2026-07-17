use super::*;

#[test]
fn replacement_fact_validation_maps_public_refusal_reasons() {
    let mut cases: Vec<(&str, AlgoliaReplaceTargetFacts, AlgoliaImportErrorCode)> = Vec::new();

    let mut unauthenticated_provider = eligible_replace_facts();
    unauthenticated_provider.provider = "hetzner".into();
    cases.push((
        "authenticated target must be AWS-backed",
        unauthenticated_provider,
        AlgoliaImportErrorCode::MigrationProviderUnsupported,
    ));

    let mut inactive_vm = eligible_replace_facts();
    inactive_vm.vm_status = "draining".into();
    cases.push((
        "target VM must be active",
        inactive_vm,
        AlgoliaImportErrorCode::BackendUnavailable,
    ));

    let mut inactive_deployment = eligible_replace_facts();
    inactive_deployment.deployment_status = "stopped".into();
    cases.push((
        "deployment must be active",
        inactive_deployment,
        AlgoliaImportErrorCode::BackendUnavailable,
    ));

    let mut unhealthy_deployment = eligible_replace_facts();
    unhealthy_deployment.health_status = "unhealthy".into();
    cases.push((
        "deployment must be healthy",
        unhealthy_deployment,
        AlgoliaImportErrorCode::BackendUnavailable,
    ));

    let mut non_standalone = eligible_replace_facts();
    non_standalone.service_type = "shared".into();
    cases.push((
        "target must use standalone service type",
        non_standalone,
        AlgoliaImportErrorCode::MigrationHaNotSupported,
    ));

    let mut lifecycle_operation = eligible_replace_facts();
    lifecycle_operation.has_active_lifecycle_operation = true;
    cases.push((
        "target must not have a lifecycle operation in progress",
        lifecycle_operation,
        AlgoliaImportErrorCode::DestinationConflict,
    ));

    let mut missing_url = eligible_replace_facts();
    missing_url.has_flapjack_url = false;
    cases.push((
        "target must have configured Flapjack URL",
        missing_url,
        AlgoliaImportErrorCode::BackendUnavailable,
    ));

    let mut active_lease = eligible_replace_facts();
    active_lease.has_active_import_lease = true;
    cases.push((
        "target must be free of another active lease",
        active_lease,
        AlgoliaImportErrorCode::DestinationConflict,
    ));

    for (label, facts, expected) in cases {
        assert_eq!(facts.validate(), Err(expected), "{label}");
    }
    assert!(eligible_replace_facts().validate().is_ok());
}

#[tokio::test]
async fn authenticated_replacement_target_refusals_return_stable_public_reasons() {
    let mut cases = vec![
        (
            "replace_auth_provider",
            "vm_inventory",
            "provider",
            "hetzner",
            AlgoliaImportErrorCode::MigrationProviderUnsupported,
        ),
        (
            "replace_auth_vm_status",
            "vm_inventory",
            "status",
            "draining",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            "replace_auth_deploy_status",
            "customer_deployments",
            "status",
            "stopped",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            "replace_auth_health",
            "customer_deployments",
            "health_status",
            "unhealthy",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            "replace_auth_service_type",
            "customer_tenants",
            "service_type",
            "shared",
            AlgoliaImportErrorCode::MigrationHaNotSupported,
        ),
        (
            "replace_auth_deploy_url",
            "customer_deployments",
            "flapjack_url",
            "",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
        (
            "replace_auth_vm_url",
            "vm_inventory",
            "flapjack_url",
            "",
            AlgoliaImportErrorCode::BackendUnavailable,
        ),
    ];

    for (schema, table, column, value, expected) in cases.drain(..) {
        let Some(db) = connect_and_migrate(schema).await else {
            return;
        };
        let customer = Uuid::new_v4();
        insert_replace_target(&db.pool, customer, "products").await;
        update_replace_target_column(&db.pool, customer, "products", table, column, value).await;
        let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

        let replaced = repo
            .create_replace(replace_job(customer, "products", schema))
            .await;

        assert_conflict_code(replaced, expected.as_str());
    }
}

#[tokio::test]
async fn replacement_target_authentication_misses_return_destination_changed() {
    let Some(db) = connect_and_migrate("replace_auth_missing_target").await else {
        return;
    };
    let customer = Uuid::new_v4();
    let other_customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let wrong_customer = repo
        .create_replace(replace_job(other_customer, "products", "wrong-customer"))
        .await;
    let missing_target = repo
        .create_replace(replace_job(customer, "missing", "missing-target"))
        .await;

    assert_conflict_code(
        wrong_customer,
        AlgoliaImportErrorCode::DestinationChanged.as_str(),
    );
    assert_conflict_code(
        missing_target,
        AlgoliaImportErrorCode::DestinationChanged.as_str(),
    );
}

#[tokio::test]
async fn authenticated_replacement_target_rejects_active_migration() {
    let Some(db) = connect_and_migrate("replace_auth_migration").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_active_migration(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let replaced = repo
        .create_replace(replace_job(customer, "products", "active-migration"))
        .await;

    assert_conflict_code(
        replaced,
        AlgoliaImportErrorCode::DestinationConflict.as_str(),
    );
}

#[tokio::test]
async fn authenticated_replacement_target_rejects_active_lease_before_quota_checks() {
    let Some(db) = connect_and_migrate("replace_auth_active_lease").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    repo.create_replace(replace_job(customer, "products", "active-lease"))
        .await
        .expect("active replacement reservation");

    let replaced = repo
        .create_replace(replace_job_with_source_size(
            customer,
            "products",
            "fills-customer-quota",
            10_737_418_240,
        ))
        .await;

    assert_conflict_code(
        replaced,
        AlgoliaImportErrorCode::DestinationConflict.as_str(),
    );
}

fn replace_job_with_source_size(
    customer_id: Uuid,
    target: &str,
    key: &str,
    source_size_bytes: i64,
) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(
        customer_id,
        target,
        source_with_size(key, source_size_bytes),
        key,
    )
}

#[tokio::test]
async fn elapsed_resume_deadline_transfers_worker_lease_without_releasing_target() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_resume_deadline").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = repo
        .create(import_job(customer, "products", "resume-deadline"))
        .await
        .expect("initial active reservation");
    force_resumable_credential_failure(
        &db.pool,
        job.id,
        now - Duration::hours(2),
        now - Duration::hours(1),
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at = $2, worker_lease_expires_at = $3
         WHERE id = $1",
    )
    .bind(job.id)
    .bind(now - Duration::minutes(30))
    .bind(now - Duration::minutes(1))
    .execute(&db.pool)
    .await
    .expect("expire worker lease");

    let before_claim = repo
        .create(import_job(customer, "products", "competitor-before"))
        .await;
    assert_conflict_code(
        before_claim,
        AlgoliaImportErrorCode::DestinationConflict.as_str(),
    );

    let claims = repo
        .claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
        .await
        .expect("claim elapsed resume deadline");
    assert_eq!(
        claims.iter().map(|claim| claim.job_id).collect::<Vec<_>>(),
        vec![job.id]
    );

    let claimed = repo.get(job.id).await.unwrap().unwrap();
    assert_eq!(claimed.worker_claimed_at, Some(now));
    assert_eq!(
        claimed.worker_lease_expires_at,
        Some(now + Duration::minutes(5))
    );
    assert!(claimed.resumable);
    assert_eq!(claimed.publication_disposition.as_str(), "unchanged");
    assert_eq!(claimed.engine_ack_state.as_str(), "pending");

    let after_claim = repo
        .create(import_job(customer, "products", "competitor-after"))
        .await;
    assert_conflict_code(
        after_claim,
        AlgoliaImportErrorCode::DestinationConflict.as_str(),
    );
    let lease = IndexLifecycleLease::new(repo);
    let lifecycle_writer = lease.begin(customer, "products").await;
    assert!(
        matches!(lifecycle_writer, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
}

#[tokio::test]
async fn resumable_credential_failure_keeps_target_excluded_through_resume_race() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_resume_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = repo
        .create(import_job(customer, "products", "resume-race"))
        .await
        .expect("initial active reservation");
    force_resumable_credential_failure(
        &db.pool,
        job.id,
        now - Duration::minutes(10),
        now - Duration::minutes(1),
    )
    .await;

    let resume_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let claim_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (resume, claims) = tokio::join!(
        resume_repo.prepare_resume(job.id),
        claim_repo.claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
    );
    let claimed = claims.expect("claim query");
    assert!(
        resume.is_ok() || !claimed.is_empty(),
        "either resume ownership or deadline claim ownership must win the race"
    );

    let current = repo.get(job.id).await.unwrap().unwrap();
    assert_eq!(current.publication_disposition.as_str(), "unchanged");
    assert_ne!(current.publication_disposition.as_str(), "unknown");
    let competitor = repo
        .create(import_job(customer, "products", "competitor-race"))
        .await;
    assert_conflict_code(
        competitor,
        AlgoliaImportErrorCode::DestinationConflict.as_str(),
    );
}

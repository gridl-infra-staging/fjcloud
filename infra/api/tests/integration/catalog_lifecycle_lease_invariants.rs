use crate::common::algolia_import_reservation_lifetime::{
    assert_algolia_import_job_unchanged_except_worker_claim, force_reservation_lifetime_case,
    reservation_lifetime_denominator, ReservationExpectation,
};

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
    let mut released_import_lease = eligible_replace_facts();
    released_import_lease.has_active_import_lease = false;
    assert!(
        released_import_lease.validate().is_ok(),
        "released import lease facts must not refuse replacement"
    );
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
    let Some(db) = connect_and_migrate("replace_auth_active_lease_boundary").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    for (index, case) in reservation_lifetime_denominator().iter().enumerate() {
        let customer = Uuid::new_v4();
        let target = format!("products-{index}");
        insert_replace_target(&db.pool, customer, &target).await;
        let active_job = repo
            .create_replace(replace_job(customer, &target, &format!("active-{index}")))
            .await
            .unwrap_or_else(|error| panic!("active replacement reservation {index}: {error:?}"));
        force_reservation_lifetime_case(&db.pool, active_job.id, case).await;

        let lifecycle_writer = IndexLifecycleLease::new(repo.clone())
            .begin(customer, &target)
            .await;
        match case.expectation {
            ReservationExpectation::Retain => {
                assert!(
                    matches!(
                        lifecycle_writer,
                        Err(RepoError::Conflict(message)) if message == "destination_conflict"
                    ),
                    "{} must block lifecycle lease admission with destination_conflict",
                    case.label
                );
                let replaced = repo
                    .create_replace(replace_job_with_source_size(
                        customer,
                        &target,
                        &format!("fills-customer-quota-{index}"),
                        10_737_418_240,
                    ))
                    .await;
                assert_conflict_code(
                    replaced,
                    AlgoliaImportErrorCode::DestinationConflict.as_str(),
                );
            }
            ReservationExpectation::Release => {
                let guard = lifecycle_writer.unwrap_or_else(|error| {
                    panic!(
                        "{} must allow lifecycle lease admission: {error:?}",
                        case.label
                    )
                });
                drop(guard);
                repo.create_replace(replace_job(customer, &target, &format!("released-{index}")))
                    .await
                    .unwrap_or_else(|error| {
                        panic!("{} must allow replacement admission: {error:?}", case.label)
                    });
            }
        }
    }
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
    let now = crate::common::support::pg_schema_harness::postgres_timestamp(Utc::now());
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
    let before_takeover = repo
        .get(job.id)
        .await
        .expect("load before claim")
        .expect("job exists before claim");
    let old_worker_claimed_at = now - Duration::minutes(30);
    let old_worker_lease_expires_at = now - Duration::minutes(1);
    assert_eq!(
        before_takeover.worker_claimed_at,
        Some(old_worker_claimed_at)
    );
    assert_eq!(
        before_takeover.worker_lease_expires_at,
        Some(old_worker_lease_expires_at)
    );

    let new_lease_expiry = now + Duration::minutes(5);
    let claims = repo
        .claim_elapsed_resume_deadlines(now, new_lease_expiry, 10)
        .await
        .expect("claim elapsed resume deadline");
    assert_eq!(claims.len(), 1);
    let claim = claims.first().expect("one elapsed resume claim");
    assert_eq!(claim.job_id, before_takeover.id);
    assert_eq!(claim.cloud_job_id, before_takeover.cloud_job_id);
    assert_eq!(
        Some(claim.engine_job_id),
        before_takeover.engine_job_id,
        "claim must return the persisted non-null engine job id"
    );
    assert_eq!(
        claim.resume_intent_generation,
        before_takeover.resume_intent_generation
    );
    assert_eq!(claim.resume_count, before_takeover.resume_count);
    assert_eq!(
        Some(claim.resume_deadline),
        before_takeover.resume_deadline,
        "claim must return the persisted non-null resume deadline"
    );
    assert_eq!(claim.worker_claimed_at, now);
    assert_eq!(claim.worker_lease_expires_at, new_lease_expiry);

    let claimed = repo.get(job.id).await.unwrap().unwrap();
    assert_algolia_import_job_unchanged_except_worker_claim(&before_takeover, &claimed);
    assert_eq!(claimed.worker_claimed_at, Some(now));
    assert_eq!(claimed.worker_lease_expires_at, Some(new_lease_expiry));
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

/// A soft-deleted customer keeps its authenticated replacement target and active
/// import-reservation evidence byte-for-byte, yet the credential-free eligibility
/// snapshot refuses with exactly `LifecycleUnavailable`. The customer-generation
/// gate is the single read-visibility fence: it refuses regardless of the retained
/// target rows, and the refused read holds no lock and mutates nothing.
#[tokio::test]
async fn soft_deleted_customer_snapshot_eligibility_refuses_while_target_retained() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_soft_delete_snapshot").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let reservation = repo
        .create_replace(replace_job(
            customer,
            "products",
            "retained-soft-delete-snapshot",
        ))
        .await
        .expect("seed active replacement reservation at generation G");

    let before_tenants = tenant_rows(&db.pool, customer).await;
    let before_deployments = deployment_rows(&db.pool, customer).await;
    let before_operations = import_operation_rows(&db.pool, customer, "products").await;
    assert_eq!(
        before_operations.len(),
        1,
        "reservation evidence must be present before the delete"
    );
    let reserved_generation = before_operations[0].lifecycle_generation;

    // Real customer soft delete: status active -> deleted, generation G -> G+1.
    assert!(
        PgCustomerRepo::new(db.pool.clone())
            .soft_delete(customer)
            .await
            .expect("soft delete active customer"),
        "soft_delete must report it changed the active customer row"
    );

    let error = repo
        .snapshot_replace_target_eligibility(customer, "products")
        .await
        .expect_err("a soft-deleted customer cannot pin a routing generation");
    assert_eq!(
        error,
        DestinationEligibilityError::LifecycleUnavailable,
        "soft-deleted customer eligibility must refuse with LifecycleUnavailable, got {error:?}"
    );

    // Refused read: retained target and reservation evidence is unchanged, and the
    // reservation still carries the pre-delete generation G.
    assert_eq!(
        tenant_rows(&db.pool, customer).await,
        before_tenants,
        "refused eligibility read must not mutate the retained catalog target"
    );
    assert_eq!(
        deployment_rows(&db.pool, customer).await,
        before_deployments,
        "refused eligibility read must not mutate deployment/routing rows"
    );
    let after_operations = import_operation_rows(&db.pool, customer, "products").await;
    assert_eq!(
        after_operations, before_operations,
        "refused eligibility read must retain the active reservation byte-for-byte"
    );
    assert_eq!(after_operations[0].id, reservation.id);
    assert_eq!(
        after_operations[0].lifecycle_generation, reserved_generation,
        "retained reservation must keep its pre-delete generation G"
    );
}

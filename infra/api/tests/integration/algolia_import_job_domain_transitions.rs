use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSource, AlgoliaImportSourceMetadata,
    AlgoliaImportSummary, EngineResumeMirror, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use api::repos::{
    AlgoliaImportJobRepo, AlgoliaImportTransitionDisposition, AlgoliaLifecycleError,
    CustomerHardDeleteKind, CustomerRepo, PgAlgoliaImportJobRepo, PgCustomerRepo, RepoError,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::{
    connect_and_migrate, insert_active_customer, require_database_url,
};

fn new_job(customer_id: Uuid, key: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), format!("revision-{key}")),
        ),
        key,
    )
}

fn replace_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(
        customer_id,
        target,
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(12_345), Some(1_000), format!("revision-{key}")),
        ),
        key,
    )
}

async fn seed_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://replace-target.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("vm-{vm_id}"))
    .bind(json!({ "disk_bytes": 10_000_000_000_i64 }))
    .bind(json!({ "disk_bytes": 0_i64 }))
    .execute(pool)
    .await
    .expect("seed replace VM");

    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://replace-target.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("seed replace deployment");

    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("seed replace target");
}

async fn soft_delete_customer(pool: &PgPool, customer_id: Uuid) {
    assert!(
        PgCustomerRepo::new(pool.clone())
            .soft_delete(customer_id)
            .await
            .expect("soft-delete customer"),
        "customer fixture should be active before soft-delete"
    );
}

async fn connect_to_harness_schema(schema: &str) -> PgPool {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&require_database_url(std::env::var("DATABASE_URL")))
        .await
        .expect("connect extra harness pool");
    sqlx::query(&format!(
        "SET search_path TO \"{}\"",
        schema.replace('"', "\"\"")
    ))
    .execute(&pool)
    .await
    .expect("set extra harness search_path");
    pool
}

async fn serialized_import_job_row(pool: &PgPool, id: Uuid) -> serde_json::Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("serialize retained import job row")
}

async fn serialized_import_job_rows(pool: &PgPool, ids: &[Uuid]) -> Vec<serde_json::Value> {
    let mut rows = Vec::with_capacity(ids.len());
    for id in ids {
        rows.push(serialized_import_job_row(pool, *id).await);
    }
    rows
}

async fn serialized_import_job_row_by_erasure_handle(
    pool: &PgPool,
    erasure_handle: Uuid,
) -> serde_json::Value {
    sqlx::query_scalar(
        "SELECT to_jsonb(algolia_import_jobs.*)
         FROM algolia_import_jobs WHERE erasure_handle = $1",
    )
    .bind(erasure_handle)
    .fetch_one(pool)
    .await
    .expect("serialize retained import job tombstone by erasure handle")
}

async fn import_job_exists(pool: &PgPool, id: Uuid) -> bool {
    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM algolia_import_jobs WHERE id = $1)")
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("check import job presence")
}

async fn hard_erase_customer(pool: &PgPool, customer_id: Uuid) {
    soft_delete_customer(pool, customer_id).await;
    PgCustomerRepo::new(pool.clone())
        .hard_delete(customer_id, CustomerHardDeleteKind::PrivacyErasure)
        .await
        .expect("hard-erase customer");
}

// Temporary schema-056 tombstone setup for Stage 3 selector tests. This is not a
// second hard-delete owner; Stage 4 owns producing these retained rows naturally.
async fn seed_schema_056_tombstone(
    pool: &PgPool,
    cleanup_phase: &str,
    engine_ack_state: AlgoliaImportEngineAckState,
    publication_disposition: AlgoliaImportPublicationDisposition,
    compacted: bool,
) -> (Uuid, Uuid, serde_json::Value) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;
    let created = repo
        .create(new_job(
            customer_id,
            &format!("schema-056-tombstone-{}", Uuid::new_v4()),
        ))
        .await
        .expect("create public import before tombstone fixture");
    let engine_job_id = Uuid::new_v4();
    repo.record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .expect("commit dispatch before tombstone fixture");
    hard_erase_customer(pool, customer_id).await;
    let compacted_at = compacted.then(|| postgres_timestamp(Utc::now()));
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET publication_disposition = $2,
             engine_ack_state = $3,
             cleanup_phase = $4,
             tombstone_compacted_at = $5
         WHERE id = $1",
    )
    .bind(created.id)
    .bind(publication_disposition.as_str())
    .bind(engine_ack_state.as_str())
    .bind(cleanup_phase)
    .bind(compacted_at)
    .execute(pool)
    .await
    .expect("adjust schema-056 Algolia tombstone reconciliation fields");
    let erasure_handle = sqlx::query_scalar::<_, Uuid>(
        "SELECT erasure_handle
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(created.id)
    .fetch_one(pool)
    .await
    .expect("fetch schema-056 tombstone erasure handle");
    (
        created.id,
        erasure_handle,
        serialized_import_job_row(pool, created.id).await,
    )
}

fn assert_repo_conflict<T>(result: Result<T, RepoError>, context: &str) {
    assert!(
        matches!(result, Err(RepoError::Conflict(_))),
        "{context}: expected RepoError::Conflict"
    );
}

fn is_lock_not_available(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|database_error| database_error.code())
        .as_deref()
        == Some("55P03")
}

async fn wait_until_customer_row_locked(pool: &PgPool, customer_id: Uuid) {
    for _ in 0..100 {
        let mut tx = pool.begin().await.expect("probe customer row lock");
        let result = sqlx::query("SELECT id FROM customers WHERE id = $1 FOR UPDATE NOWAIT")
            .bind(customer_id)
            .execute(&mut *tx)
            .await;
        match result {
            Err(error) if is_lock_not_available(&error) => {
                tx.rollback().await.expect("release lock probe");
                return;
            }
            Ok(_) => {
                tx.rollback().await.expect("release unlocked probe");
                tokio::task::yield_now().await;
            }
            Err(error) => panic!("customer row lock probe failed: {error}"),
        }
    }
    panic!("soft-delete did not acquire the customer row lock");
}

fn persisted_state(job: &AlgoliaImportJob) -> AlgoliaImportJobState {
    let resume_mirror = match (
        job.resume_checkpoint.clone(),
        job.resume_status_observed_at,
        job.resume_deadline,
    ) {
        (Some(checkpoint), Some(observed_at), Some(deadline)) => {
            Some(EngineResumeMirror::new(checkpoint, observed_at, deadline).unwrap())
        }
        _ => None,
    };
    AlgoliaImportJobState {
        status: job.status,
        publication_disposition: job.publication_disposition,
        engine_ack_state: job.engine_ack_state,
        dispatch_intent_state: job.dispatch_intent_state,
        engine_job_id: job.engine_job_id,
        lifecycle_generation: job.lifecycle_generation,
        retryable: job.retryable,
        resume_intent_generation: job.resume_intent_generation,
        resume_mirror,
        resumable: job.resumable,
        resume_count: job.resume_count,
        summary: job.summary.clone(),
        warnings: job.warnings.clone(),
        error_code: job.error_code,
        error_message: job.error_message.clone(),
    }
}

fn postgres_timestamp(timestamp: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::<Utc>::from_timestamp_micros(timestamp.timestamp_micros())
        .expect("test timestamp must fit in Postgres timestamptz precision")
}

fn admitted_state(status: AlgoliaImportJobStatus) -> AlgoliaImportJobState {
    AlgoliaImportJobState {
        status,
        publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
        engine_ack_state: AlgoliaImportEngineAckState::Pending,
        dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
        engine_job_id: Some(Uuid::new_v4()),
        lifecycle_generation: 1,
        retryable: true,
        resume_intent_generation: 0,
        resume_mirror: None,
        resumable: false,
        resume_count: 0,
        summary: AlgoliaImportSummary::default(),
        warnings: json!([]),
        error_code: None,
        error_message: None,
    }
}

fn resumable_failure_state(status: AlgoliaImportJobStatus) -> AlgoliaImportJobState {
    let observed_at = Utc::now();
    resumable_failure_state_with_deadline(status, observed_at, observed_at + Duration::minutes(5))
}

fn resumable_failure_state_with_deadline(
    status: AlgoliaImportJobStatus,
    observed_at: DateTime<Utc>,
    deadline: DateTime<Utc>,
) -> AlgoliaImportJobState {
    let mut state = admitted_state(status);
    state.resume_mirror = Some(
        EngineResumeMirror::new("opaque-resume-handle".into(), observed_at, deadline).unwrap(),
    );
    state.resumable = true;
    state.error_code = Some(match status {
        AlgoliaImportJobStatus::Interrupted => AlgoliaImportErrorCode::Interrupted,
        _ => AlgoliaImportErrorCode::BackendUnavailable,
    });
    state
}

async fn create_resumable_job(
    pool: &PgPool,
    repo: &PgAlgoliaImportJobRepo,
    key: &str,
    deadline: DateTime<Utc>,
) -> AlgoliaImportJob {
    let customer_id = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;
    let created = repo.create(new_job(customer_id, key)).await.unwrap();
    let engine_job_id = Uuid::new_v4();
    repo.record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .unwrap();
    let mut validating = admitted_state(AlgoliaImportJobStatus::ValidatingSource);
    validating.engine_job_id = Some(engine_job_id);
    let admitted = repo
        .update_persisted_state(created.id, validating)
        .await
        .unwrap();
    let observed_at = deadline - Duration::minutes(5);
    let mut failed = resumable_failure_state_with_deadline(
        AlgoliaImportJobStatus::Failed,
        observed_at,
        deadline,
    );
    failed.engine_job_id = admitted.engine_job_id;
    repo.update_persisted_state(admitted.id, failed)
        .await
        .unwrap()
}

async fn create_resumable_replace_job(
    pool: &PgPool,
    repo: &PgAlgoliaImportJobRepo,
    key: &str,
    deadline: DateTime<Utc>,
) -> AlgoliaImportJob {
    let customer_id = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;
    seed_replace_target(pool, customer_id, "products").await;
    let created = repo
        .create_replace(replace_job(customer_id, "products", key))
        .await
        .unwrap();
    let engine_job_id = Uuid::new_v4();
    repo.record_dispatch_intent_committed(created.id, engine_job_id)
        .await
        .unwrap();
    let mut validating = admitted_state(AlgoliaImportJobStatus::ValidatingSource);
    validating.engine_job_id = Some(engine_job_id);
    let admitted = repo
        .update_persisted_state(created.id, validating)
        .await
        .unwrap();
    let mut failed =
        resumable_failure_state_with_deadline(AlgoliaImportJobStatus::Failed, Utc::now(), deadline);
    failed.engine_job_id = admitted.engine_job_id;
    repo.update_persisted_state(admitted.id, failed)
        .await
        .unwrap()
}

async fn create_admitted_job(
    pool: &PgPool,
    repo: &PgAlgoliaImportJobRepo,
    key: &str,
    target_status: AlgoliaImportJobStatus,
) -> AlgoliaImportJob {
    use AlgoliaImportJobStatus::{
        CopyingConfiguration, CopyingDocuments, Promoting, ValidatingSource, Verifying,
    };

    let customer_id = Uuid::new_v4();
    insert_active_customer(pool, customer_id, 1).await;
    let created = repo.create(new_job(customer_id, key)).await.unwrap();
    let phases = [
        ValidatingSource,
        CopyingConfiguration,
        CopyingDocuments,
        Verifying,
        Promoting,
    ];
    let mut current = created;
    let engine_job_id = Uuid::new_v4();
    current = repo
        .record_dispatch_intent_committed(current.id, engine_job_id)
        .await
        .unwrap();
    for status in phases {
        let mut state = admitted_state(status);
        state.engine_job_id = Some(engine_job_id);
        current = repo
            .update_persisted_state(current.id, state)
            .await
            .unwrap();
        if status == target_status {
            return current;
        }
    }
    panic!("unsupported admitted target status {target_status:?}");
}

fn assert_transition(
    from: AlgoliaImportJobState,
    to: AlgoliaImportJobState,
    accepted: bool,
    name: &str,
) {
    assert_eq!(
        to.validate_transition_from(&from).is_ok(),
        accepted,
        "{name}"
    );
}

fn all_statuses() -> [AlgoliaImportJobStatus; 13] {
    use AlgoliaImportJobStatus::{
        Cancelled, Cancelling, Completed, CompletedWithWarnings, CopyingConfiguration,
        CopyingDocuments, Failed, Interrupted, Promoting, Queued, Resuming, ValidatingSource,
        Verifying,
    };
    [
        Queued,
        ValidatingSource,
        CopyingConfiguration,
        CopyingDocuments,
        Verifying,
        Promoting,
        Cancelling,
        Cancelled,
        Resuming,
        Completed,
        CompletedWithWarnings,
        Failed,
        Interrupted,
    ]
}

fn normal_forward_target(mut from: AlgoliaImportJobState) -> AlgoliaImportJobState {
    use AlgoliaImportJobStatus::{Completed, CompletedWithWarnings};
    if matches!(from.status, Completed | CompletedWithWarnings) {
        from.publication_disposition = AlgoliaImportPublicationDisposition::Promoted;
        from.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
    }
    from
}

#[test]
fn algolia_import_job_domain_transition_owner_accepts_only_declared_edges() {
    use AlgoliaImportJobStatus::{
        Cancelled, Cancelling, Completed, CompletedWithWarnings, CopyingConfiguration,
        CopyingDocuments, Failed, Interrupted, Promoting, Queued, Resuming, ValidatingSource,
        Verifying,
    };

    for (from_status, to_status) in [
        (Queued, ValidatingSource),
        (ValidatingSource, CopyingConfiguration),
        (CopyingConfiguration, CopyingDocuments),
        (CopyingDocuments, Verifying),
        (Verifying, Promoting),
        (Promoting, Completed),
        (Promoting, CompletedWithWarnings),
    ] {
        let from = admitted_state(from_status);
        let mut to = from.clone();
        to.status = to_status;
        if matches!(to_status, Completed | CompletedWithWarnings) {
            to.publication_disposition = AlgoliaImportPublicationDisposition::Promoted;
            to.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
        }
        assert_transition(from, to, true, "normal forward edge");
    }

    for from_status in [
        ValidatingSource,
        CopyingConfiguration,
        CopyingDocuments,
        Verifying,
        Promoting,
        Resuming,
    ] {
        for to_status in [Failed, Interrupted] {
            let from = admitted_state(from_status);
            let mut to = resumable_failure_state(to_status);
            to.engine_job_id = from.engine_job_id;
            assert_transition(from, to, true, "engine resumable failure edge");
        }
    }

    for to_status in [Failed, Interrupted] {
        let from = admitted_state(CopyingDocuments);
        let mut to = from.clone();
        to.status = to_status;
        to.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
        to.error_code = Some(match to_status {
            Interrupted => AlgoliaImportErrorCode::Interrupted,
            _ => AlgoliaImportErrorCode::BackendUnavailable,
        });
        assert_transition(from, to, true, "engine terminal failure edge");
    }

    for from_status in [
        Queued,
        ValidatingSource,
        CopyingConfiguration,
        CopyingDocuments,
        Verifying,
        Resuming,
        Promoting,
    ] {
        let mut from = admitted_state(from_status);
        if from_status == Queued {
            from.dispatch_intent_state = AlgoliaImportDispatchIntentState::Absent;
            from.engine_job_id = None;
            from.publication_disposition = AlgoliaImportPublicationDisposition::NotStarted;
        }
        let mut to = from.clone();
        to.status = Cancelling;
        assert_transition(from, to, true, "cancel request edge");
    }

    let mut pre_admission_cancel = admitted_state(Cancelling);
    pre_admission_cancel.dispatch_intent_state = AlgoliaImportDispatchIntentState::Absent;
    pre_admission_cancel.engine_job_id = None;
    pre_admission_cancel.publication_disposition = AlgoliaImportPublicationDisposition::NotStarted;
    let mut pre_admission_interrupted = pre_admission_cancel.clone();
    pre_admission_interrupted.status = Interrupted;
    pre_admission_interrupted.engine_ack_state = AlgoliaImportEngineAckState::SealAcknowledged;
    pre_admission_interrupted.dispatch_intent_state = AlgoliaImportDispatchIntentState::Committed;
    pre_admission_interrupted.error_code = Some(AlgoliaImportErrorCode::Interrupted);
    assert_transition(
        pre_admission_cancel,
        pre_admission_interrupted,
        true,
        "pre-admission cancel reconciliation",
    );

    let admitted_cancel = admitted_state(Cancelling);
    let mut cancelled = admitted_cancel.clone();
    cancelled.status = Cancelled;
    cancelled.publication_disposition = AlgoliaImportPublicationDisposition::Unchanged;
    cancelled.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
    assert_transition(
        admitted_cancel,
        cancelled,
        true,
        "engine-admitted cancel reconciliation",
    );

    for failed_status in [Failed, Interrupted] {
        let from = resumable_failure_state(failed_status);
        let mut resuming = from.clone();
        resuming.status = Resuming;
        resuming.resumable = false;
        resuming.resume_mirror = None;
        resuming.error_code = None;
        assert_transition(from, resuming.clone(), true, "resume preparation");
        let mut copying_documents = resuming.clone();
        copying_documents.status = CopyingDocuments;
        copying_documents.resume_count += 1;
        assert_transition(
            resuming,
            copying_documents,
            true,
            "resume accepted by engine",
        );
    }

    let mut resume_count_missing = resumable_failure_state(Failed);
    resume_count_missing.status = Resuming;
    resume_count_missing.resumable = false;
    resume_count_missing.resume_mirror = None;
    resume_count_missing.error_code = None;
    let mut resume_count_jump = resume_count_missing.clone();
    resume_count_jump.status = CopyingDocuments;
    resume_count_jump.resume_count += 2;
    assert_transition(
        resume_count_missing.clone(),
        resume_count_jump,
        false,
        "resume acceptance cannot skip attempts",
    );
    let mut resume_count_unchanged = resume_count_missing.clone();
    resume_count_unchanged.status = CopyingDocuments;
    assert_transition(
        resume_count_missing,
        resume_count_unchanged,
        false,
        "resume acceptance must increment attempts",
    );

    let from = admitted_state(Queued);
    let to = admitted_state(CopyingDocuments);
    assert_transition(from, to, false, "undeclared forward jump");

    let promoted = {
        let mut state = admitted_state(Completed);
        state.publication_disposition = AlgoliaImportPublicationDisposition::Promoted;
        state.engine_ack_state = AlgoliaImportEngineAckState::Acknowledged;
        state
    };
    let mut cancelling_promoted = promoted.clone();
    cancelling_promoted.status = Cancelling;
    assert_transition(
        promoted,
        cancelling_promoted,
        false,
        "cannot cancel promoted publication",
    );

    for invalid_resume in [
        {
            let mut state = resumable_failure_state(Failed);
            state.dispatch_intent_state = AlgoliaImportDispatchIntentState::Absent;
            state.engine_job_id = None;
            state.publication_disposition = AlgoliaImportPublicationDisposition::NotStarted;
            state.engine_ack_state = AlgoliaImportEngineAckState::NotApplicable;
            state.resumable = false;
            state.resume_mirror = None;
            state
        },
        {
            let mut state = admitted_state(Cancelled);
            state.publication_disposition = AlgoliaImportPublicationDisposition::Unchanged;
            state
        },
        {
            let mut state = resumable_failure_state(Failed);
            state.engine_ack_state = AlgoliaImportEngineAckState::Acknowledged;
            state.resumable = false;
            state
        },
        {
            let observed_at = Utc::now() - Duration::minutes(2);
            let mut state = resumable_failure_state(Failed);
            state.resume_mirror = Some(
                EngineResumeMirror::new(
                    "expired".into(),
                    observed_at,
                    observed_at + Duration::minutes(1),
                )
                .unwrap(),
            );
            state
        },
        admitted_state(Failed),
    ] {
        let mut resuming = invalid_resume.clone();
        resuming.status = Resuming;
        resuming.resumable = false;
        resuming.resume_mirror = None;
        resuming.error_code = Some(AlgoliaImportErrorCode::NotResumable);
        assert_transition(
            invalid_resume,
            resuming,
            false,
            "invalid resume source is rejected",
        );
    }

    for from_status in all_statuses() {
        for to_status in all_statuses() {
            let declared_status_edge = from_status == to_status
                || matches!(
                    (from_status, to_status),
                    (Queued, ValidatingSource)
                        | (ValidatingSource, CopyingConfiguration)
                        | (CopyingConfiguration, CopyingDocuments)
                        | (CopyingDocuments, Verifying)
                        | (Verifying, Promoting)
                        | (Promoting, Completed)
                        | (Promoting, CompletedWithWarnings)
                        | (ValidatingSource, Failed | Interrupted)
                        | (CopyingConfiguration, Failed | Interrupted)
                        | (CopyingDocuments, Failed | Interrupted)
                        | (Verifying, Failed | Interrupted)
                        | (Promoting, Failed | Interrupted)
                        | (Resuming, Failed | Interrupted)
                        | (Queued, Cancelling)
                        | (ValidatingSource, Cancelling)
                        | (CopyingConfiguration, Cancelling)
                        | (CopyingDocuments, Cancelling)
                        | (Verifying, Cancelling)
                        | (Resuming, Cancelling)
                        | (Promoting, Cancelling)
                        | (Cancelling, Interrupted | Cancelled)
                        | (Failed | Interrupted, Resuming)
                        | (Resuming, CopyingDocuments)
                );
            if declared_status_edge {
                continue;
            }
            let from = admitted_state(from_status);
            let mut to = normal_forward_target(from.clone());
            to.status = to_status;
            assert_transition(from, to, false, "undeclared status edge");
        }
    }
}

#[tokio::test]
async fn algolia_import_job_domain_cancel_intent_is_atomic_and_idempotent() {
    let Some(db) = connect_and_migrate("algolia_cancel_atomic").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = create_admitted_job(
        &db.pool,
        &repo,
        "cancel-atomic",
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    let engine_job_id = created.engine_job_id.unwrap();

    let first_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let second_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (first, second) = tokio::join!(
        first_repo.request_cancel(created.id),
        second_repo.request_cancel(created.id)
    );
    let mut outcomes = vec![first.unwrap(), second.unwrap()];
    outcomes.sort_by_key(|outcome| outcome.should_dispatch());
    let idempotent = outcomes.remove(0);
    let dispatching = outcomes.remove(0);

    assert!(!idempotent.should_dispatch());
    assert!(dispatching.should_dispatch());
    assert_eq!(dispatching.job.status, AlgoliaImportJobStatus::Cancelling);
    assert!(dispatching.job.cancel_requested_at.is_some());
    assert_eq!(dispatching.job.cloud_job_id, created.cloud_job_id);
    assert_eq!(dispatching.job.engine_job_id, Some(engine_job_id));
    assert_eq!(dispatching.job.destination_vm_id, created.destination_vm_id);
    assert_eq!(dispatching.job.algolia_app_id, created.algolia_app_id);
    assert_eq!(dispatching.job.source_name, created.source_name);
    assert_eq!(dispatching.job.logical_target, created.logical_target);
    assert_eq!(
        dispatching.job.canonical_fingerprint,
        created.canonical_fingerprint
    );
    assert_eq!(dispatching.job.routing_identity, created.routing_identity);
    assert_eq!(
        dispatching.job.publication_disposition,
        AlgoliaImportPublicationDisposition::Unchanged
    );

    let repeat = repo.request_cancel(created.id).await.unwrap();
    assert!(!repeat.should_dispatch());
    assert_eq!(
        repeat.job.cancel_requested_at,
        dispatching.job.cancel_requested_at
    );

    let mut cancelled = persisted_state(&repeat.job);
    cancelled.status = AlgoliaImportJobStatus::Cancelled;
    cancelled.publication_disposition = AlgoliaImportPublicationDisposition::Unchanged;
    cancelled.engine_ack_state = AlgoliaImportEngineAckState::OutboxPending;
    let cancelled = repo
        .update_persisted_state(repeat.job.id, cancelled)
        .await
        .unwrap();
    let after_cancelled = repo.request_cancel(cancelled.id).await.unwrap();
    assert!(!after_cancelled.should_dispatch());
    assert_eq!(
        after_cancelled.job.cancel_requested_at,
        dispatching.job.cancel_requested_at
    );
}

#[tokio::test]
async fn algolia_import_job_domain_resume_intent_is_atomic_and_idempotent() {
    let Some(db) = connect_and_migrate("algolia_resume_atomic").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = create_admitted_job(
        &db.pool,
        &repo,
        "resume-atomic",
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    let mut failed = resumable_failure_state(AlgoliaImportJobStatus::Failed);
    failed.engine_job_id = created.engine_job_id;
    failed.resume_count = 2;
    failed.summary.documents_imported = 7;
    let failed = repo
        .update_persisted_state(created.id, failed)
        .await
        .unwrap();

    let first_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let second_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (first, second) = tokio::join!(
        first_repo.prepare_resume(failed.id),
        second_repo.prepare_resume(failed.id)
    );
    let mut outcomes = vec![first.unwrap(), second.unwrap()];
    outcomes.sort_by_key(|outcome| outcome.should_dispatch());
    let idempotent = outcomes.remove(0);
    let dispatching = outcomes.remove(0);

    assert!(!idempotent.should_dispatch());
    assert!(dispatching.should_dispatch());
    assert_eq!(dispatching.generation, failed.resume_intent_generation + 1);
    assert_eq!(dispatching.expected_attempt, failed.resume_count + 1);
    assert_eq!(dispatching.job.status, AlgoliaImportJobStatus::Resuming);
    assert_eq!(dispatching.job.resume_count, failed.resume_count);
    assert_eq!(dispatching.job.cloud_job_id, created.cloud_job_id);
    assert_eq!(dispatching.job.engine_job_id, failed.engine_job_id);
    assert_eq!(dispatching.job.destination_vm_id, created.destination_vm_id);

    let duplicate = repo.prepare_resume(failed.id).await.unwrap();
    assert!(!duplicate.should_dispatch());
    assert_eq!(duplicate.generation, dispatching.generation);
    assert_eq!(duplicate.expected_attempt, dispatching.expected_attempt);
}

#[tokio::test]
async fn algolia_import_job_domain_resume_observation_is_generation_gated_and_monotonic() {
    let Some(db) = connect_and_migrate("algolia_resume_observed").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = create_admitted_job(
        &db.pool,
        &repo,
        "resume-observed",
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    let mut failed = resumable_failure_state(AlgoliaImportJobStatus::Interrupted);
    failed.engine_job_id = created.engine_job_id;
    failed.resume_count = 1;
    failed.summary.documents_imported = 50;
    let failed = repo
        .update_persisted_state(created.id, failed)
        .await
        .unwrap();
    let prepared = repo.prepare_resume(failed.id).await.unwrap();

    let lower_summary = AlgoliaImportSummary {
        documents_expected: 75,
        documents_imported: 10,
        documents_rejected: 1,
        settings_applied: 2,
        settings_unsupported: 0,
        synonyms_expected: 0,
        synonyms_imported: 0,
        synonyms_rejected: 0,
        rules_expected: 0,
        rules_imported: 0,
        rules_rejected: 0,
    };
    let observed = repo
        .record_resume_accepted(prepared.job.id, prepared.generation, lower_summary)
        .await
        .unwrap();
    assert_eq!(observed.status, AlgoliaImportJobStatus::CopyingDocuments);
    assert_eq!(observed.resume_count, failed.resume_count + 1);
    assert_eq!(observed.resume_intent_generation, prepared.generation);
    assert!(!observed.resumable);
    assert!(observed.resume_checkpoint.is_none());
    assert!(observed.resume_deadline.is_none());
    assert!(observed.resume_status_observed_at.is_none());
    assert_eq!(observed.summary.documents_imported, 50);
    assert_eq!(observed.summary.documents_expected, 75);
    assert_eq!(observed.cloud_job_id, created.cloud_job_id);
    assert_eq!(observed.engine_job_id, failed.engine_job_id);

    let duplicate = repo
        .record_resume_accepted(
            observed.id,
            prepared.generation,
            AlgoliaImportSummary::default(),
        )
        .await
        .unwrap();
    assert_eq!(duplicate.resume_count, observed.resume_count);
    assert_eq!(
        duplicate.summary.documents_imported,
        observed.summary.documents_imported
    );

    assert!(matches!(
        repo.record_resume_accepted(
            observed.id,
            prepared.generation - 1,
            AlgoliaImportSummary::default()
        )
        .await,
        Err(RepoError::Conflict(_))
    ));

    let mut rewound = persisted_state(&observed);
    rewound.status = AlgoliaImportJobStatus::Verifying;
    rewound.resume_count -= 1;
    assert!(matches!(
        repo.update_persisted_state(observed.id, rewound).await,
        Err(RepoError::Conflict(_))
    ));

    let mut rewound_summary = persisted_state(&observed);
    rewound_summary.status = AlgoliaImportJobStatus::Verifying;
    rewound_summary.summary.documents_imported -= 1;
    assert!(matches!(
        repo.update_persisted_state(observed.id, rewound_summary)
            .await,
        Err(RepoError::Conflict(_))
    ));
}

#[tokio::test]
async fn stale_customer_generation_blocks_state_adoption_and_resume_acceptance() {
    let Some(db) = connect_and_migrate("algolia_stale_state_generation").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = repo
        .create(new_job(customer_id, "stale-state"))
        .await
        .expect("admit import");
    let admitted = repo
        .record_dispatch_intent_committed(created.id, Uuid::new_v4())
        .await
        .expect("commit dispatch before lifecycle transition");

    let mut failed = resumable_failure_state(AlgoliaImportJobStatus::Failed);
    failed.engine_job_id = admitted.engine_job_id;
    let mut validating = admitted_state(AlgoliaImportJobStatus::ValidatingSource);
    validating.engine_job_id = admitted.engine_job_id;
    let admitted = repo
        .update_persisted_state(admitted.id, validating)
        .await
        .expect("record validation before failure");
    let failed = repo
        .update_persisted_state(admitted.id, failed)
        .await
        .expect("record resumable failure");
    let prepared = repo
        .prepare_resume(failed.id)
        .await
        .expect("prepare resume");
    assert!(prepared.should_dispatch());

    sqlx::query(
        "UPDATE customers \
         SET status = 'deleted', lifecycle_generation = lifecycle_generation + 1 \
         WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("advance customer lifecycle generation");

    assert!(matches!(
        repo.record_resume_accepted(
            prepared.job.id,
            prepared.generation,
            AlgoliaImportSummary::default()
        )
        .await,
        Err(RepoError::Conflict(_))
    ));
    let mut attempted = persisted_state(&prepared.job);
    attempted.status = AlgoliaImportJobStatus::CopyingDocuments;
    assert!(matches!(
        repo.update_persisted_state(prepared.job.id, attempted)
            .await,
        Err(RepoError::Conflict(_))
    ));
    assert!(matches!(
        repo.request_cancel(prepared.job.id).await,
        Err(RepoError::Conflict(_))
    ));
    assert!(matches!(
        repo.prepare_resume(prepared.job.id).await,
        Err(RepoError::Conflict(_))
    ));
}

#[tokio::test]
async fn soft_deleted_customer_blocks_state_cancel_and_resume_mutations_without_changing_retained_rows(
) {
    let Some(db) = connect_and_migrate("algolia_deleted_mutation_fence").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let queued = repo
        .create(new_job(customer_id, "deleted-queued-mutations"))
        .await
        .expect("admit queued import");
    let queued_before = serialized_import_job_row(&db.pool, queued.id).await;

    soft_delete_customer(&db.pool, customer_id).await;

    let mut attempted = persisted_state(&queued);
    attempted.status = AlgoliaImportJobStatus::Queued;
    assert_repo_conflict(
        repo.update_persisted_state(queued.id, attempted).await,
        "state update after soft-delete",
    );
    assert_repo_conflict(
        repo.request_cancel(queued.id).await,
        "id-only cancel after soft-delete",
    );
    assert_refused(
        repo.request_cancel_for_customer(customer_id, queued.id)
            .await
            .expect_err("customer-scoped cancel should be typed after soft-delete"),
        AlgoliaImportErrorCode::CancelNotPermitted,
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, queued.id).await,
        queued_before
    );
}

#[tokio::test]
async fn soft_deleted_customer_blocks_failed_and_resuming_resume_mutations_without_changing_retained_rows(
) {
    let Some(db) = connect_and_migrate("algolia_deleted_resume_fence").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let deadline = Utc::now() + Duration::minutes(30);
    let failed = create_resumable_job(&db.pool, &repo, "deleted-resume-failed", deadline).await;
    let failed_before = serialized_import_job_row(&db.pool, failed.id).await;

    soft_delete_customer(&db.pool, failed.customer_id).await;

    assert_repo_conflict(
        repo.prepare_resume(failed.id).await,
        "id-only prepare resume after soft-delete",
    );
    assert_refused(
        repo.prepare_resume_for_customer(failed.customer_id, failed.id, Utc::now())
            .await
            .expect_err("customer-scoped resume should be typed after soft-delete"),
        AlgoliaImportErrorCode::NotResumable,
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, failed.id).await,
        failed_before
    );

    let resuming = create_resumable_job(&db.pool, &repo, "deleted-resume-accepted", deadline).await;
    let prepared = repo
        .prepare_resume(resuming.id)
        .await
        .expect("prepare resume before soft-delete");
    let prepared_before = serialized_import_job_row(&db.pool, prepared.job.id).await;
    soft_delete_customer(&db.pool, prepared.job.customer_id).await;

    assert_repo_conflict(
        repo.record_resume_accepted(
            prepared.job.id,
            prepared.generation,
            AlgoliaImportSummary::default(),
        )
        .await,
        "resume acceptance after soft-delete",
    );
    assert_repo_conflict(
        repo.record_resume_accepted(
            prepared.job.id,
            prepared.generation - 1,
            AlgoliaImportSummary::default(),
        )
        .await,
        "stale resume generation after soft-delete",
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, prepared.job.id).await,
        prepared_before
    );
}

#[tokio::test]
async fn soft_delete_race_prevents_customer_scoped_resume_dispatch() {
    let Some(db) = connect_and_migrate("algolia_delete_resume_race").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "delete-race-resume",
        now + Duration::hours(1),
    )
    .await;
    let before = serialized_import_job_row(&db.pool, job.id).await;
    let customer_id = job.customer_id;
    let job_id = job.id;
    let lock_pool = connect_to_harness_schema(&db.schema).await;
    let delete_pool = connect_to_harness_schema(&db.schema).await;
    let probe_pool = connect_to_harness_schema(&db.schema).await;
    let resume_pool = connect_to_harness_schema(&db.schema).await;

    let mut job_lock = lock_pool.begin().await.expect("begin job lock");
    sqlx::query("SELECT id FROM algolia_import_jobs WHERE id = $1 FOR UPDATE")
        .bind(job_id)
        .execute(&mut *job_lock)
        .await
        .expect("hold import job lock");

    let (delete_started_tx, delete_started_rx) = oneshot::channel();
    let delete_task = tokio::spawn(async move {
        delete_started_tx.send(()).ok();
        soft_delete_customer(&delete_pool, customer_id).await;
    });
    delete_started_rx.await.expect("delete task started");
    wait_until_customer_row_locked(&probe_pool, customer_id).await;

    let resume_repo = PgAlgoliaImportJobRepo::new(resume_pool);
    let (resume_started_tx, resume_started_rx) = oneshot::channel();
    let resume_task = tokio::spawn(async move {
        resume_started_tx.send(()).ok();
        resume_repo
            .prepare_resume_for_customer(customer_id, job_id, now)
            .await
    });
    resume_started_rx.await.expect("resume task started");

    job_lock.commit().await.expect("release import job lock");
    delete_task.await.expect("soft-delete task joins");
    assert_refused(
        resume_task
            .await
            .expect("resume task joins")
            .expect_err("resume must be refused after delete commits"),
        AlgoliaImportErrorCode::NotResumable,
    );
    assert_eq!(serialized_import_job_row(&db.pool, job_id).await, before);
}

#[tokio::test]
async fn soft_delete_race_prevents_elapsed_resume_deadline_claim() {
    let Some(db) = connect_and_migrate("algolia_delete_deadline_claim_race").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "delete-race-claim",
        now - Duration::minutes(1),
    )
    .await;
    let before = serialized_import_job_row(&db.pool, job.id).await;
    let customer_id = job.customer_id;
    let job_id = job.id;
    let lock_pool = connect_to_harness_schema(&db.schema).await;
    let delete_pool = connect_to_harness_schema(&db.schema).await;
    let probe_pool = connect_to_harness_schema(&db.schema).await;
    let claim_pool = connect_to_harness_schema(&db.schema).await;
    let claim_repo = PgAlgoliaImportJobRepo::new(claim_pool);

    let mut job_lock = lock_pool.begin().await.expect("begin job lock");
    sqlx::query("SELECT id FROM algolia_import_jobs WHERE id = $1 FOR UPDATE")
        .bind(job_id)
        .execute(&mut *job_lock)
        .await
        .expect("hold import job lock");

    let (delete_started_tx, delete_started_rx) = oneshot::channel();
    let delete_task = tokio::spawn(async move {
        delete_started_tx.send(()).ok();
        soft_delete_customer(&delete_pool, customer_id).await;
    });
    delete_started_rx.await.expect("delete task started");
    wait_until_customer_row_locked(&probe_pool, customer_id).await;

    assert!(
        claim_repo
            .claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
            .await
            .expect("claim while delete owns customer lock")
            .is_empty(),
        "locked deleting customer must be skipped rather than claimed"
    );

    job_lock.commit().await.expect("release import job lock");
    delete_task.await.expect("soft-delete task joins");
    assert!(
        claim_repo
            .claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
            .await
            .expect("claim after delete commits")
            .is_empty(),
        "deleted customer must not emit stale resume-deadline work"
    );
    assert_eq!(serialized_import_job_row(&db.pool, job_id).await, before);
}

#[tokio::test]
async fn stale_customer_generation_blocks_terminal_ack_and_retention_gc() {
    let Some(db) = connect_and_migrate("algolia_stale_ack_gc_generation").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = repo
        .create(new_job(customer_id, "stale-ack-gc"))
        .await
        .expect("admit import");
    let admitted = repo
        .record_dispatch_intent_committed(created.id, Uuid::new_v4())
        .await
        .expect("commit dispatch before lifecycle transition");

    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'outbox_pending', terminal_at = NOW() - INTERVAL '91 days'
         WHERE id = $1",
    )
    .bind(admitted.id)
    .execute(&db.pool)
    .await
    .expect("seed retained terminal job");
    let acknowledged = repo
        .mark_engine_acknowledged(admitted.id)
        .await
        .expect("acknowledge current-generation terminal job");
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    sqlx::query(
        "UPDATE customers
         SET lifecycle_generation = lifecycle_generation + 1
         WHERE id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("advance customer lifecycle generation");

    assert!(matches!(
        repo.mark_engine_acknowledged(admitted.id).await,
        Err(RepoError::Conflict(_))
    ));
    assert!(repo
        .gc_retained_terminal_history(Utc::now(), 10)
        .await
        .expect("run generation-fenced retention GC")
        .is_empty());

    let retained = repo
        .get(admitted.id)
        .await
        .expect("read retained job")
        .unwrap();
    assert_eq!(
        retained.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
}

#[tokio::test]
async fn soft_deleted_customer_retains_terminal_ack_and_gc_evidence() {
    let Some(db) = connect_and_migrate("algolia_deleted_ack_gc").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let created = repo
        .create(new_job(customer_id, "deleted-ack-gc"))
        .await
        .expect("admit import");
    repo.record_dispatch_intent_committed(created.id, Uuid::new_v4())
        .await
        .expect("commit dispatch before terminal fixture");
    let now = Utc::now();
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'outbox_pending', terminal_at = $2 - INTERVAL '91 days'
         WHERE id = $1",
    )
    .bind(created.id)
    .bind(now)
    .execute(&db.pool)
    .await
    .expect("seed retained terminal job");
    let before = serialized_import_job_row(&db.pool, created.id).await;

    soft_delete_customer(&db.pool, customer_id).await;

    assert_repo_conflict(
        repo.mark_engine_acknowledged(created.id).await,
        "acknowledge deleted-customer terminal job",
    );
    assert!(
        repo.gc_retained_terminal_history(now, 10)
            .await
            .expect("run deleted-customer retention GC")
            .is_empty(),
        "deleted-customer terminal history must not be garbage-collected"
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, created.id).await,
        before
    );
}

#[tokio::test]
async fn retention_gc_collects_current_generation_at_exact_boundary() {
    let Some(db) = connect_and_migrate("algolia_exact_retention_boundary").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let gc_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, gc_customer_id, 1).await;
    let gc_job = repo
        .create(new_job(gc_customer_id, "exact-retention-boundary"))
        .await
        .expect("admit retained history job");
    repo.record_dispatch_intent_committed(gc_job.id, Uuid::new_v4())
        .await
        .expect("commit retained history dispatch");
    let now = Utc::now();
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged', terminal_at = $2 - INTERVAL '90 days'
         WHERE id = $1",
    )
    .bind(gc_job.id)
    .bind(now)
    .execute(&db.pool)
    .await
    .expect("seed exact retention boundary");

    assert_eq!(
        repo.gc_retained_terminal_history(now, 10)
            .await
            .expect("collect exact-boundary history"),
        vec![gc_job.id]
    );
    assert!(repo.get(gc_job.id).await.expect("read GC result").is_none());
}

#[tokio::test]
async fn stale_customer_generation_excludes_elapsed_resume_deadline_claims() {
    let Some(db) = connect_and_migrate("algolia_stale_deadline_generation").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-stale-generation",
        now - Duration::minutes(1),
    )
    .await;

    sqlx::query(
        "UPDATE customers
         SET status = 'deleted', lifecycle_generation = lifecycle_generation + 1
         WHERE id = $1",
    )
    .bind(job.customer_id)
    .execute(&db.pool)
    .await
    .expect("advance customer lifecycle generation before reaper claim");

    let claims = repo
        .claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
        .await
        .expect("claim elapsed resume deadlines");
    assert!(
        claims.is_empty(),
        "stale lifecycle generation must not emit resume-deadline reaper work"
    );

    let unchanged = repo.get(job.id).await.unwrap().unwrap();
    assert_eq!(unchanged.worker_claimed_at, None);
    assert_eq!(unchanged.worker_lease_expires_at, None);
    assert_eq!(unchanged.status, job.status);
    assert_eq!(unchanged.resumable, job.resumable);
}

#[tokio::test]
async fn erased_tombstone_selector_excludes_resume_deadline_claims_idempotently() {
    let Some(db) = connect_and_migrate("algolia_erased_deadline_selector").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = postgres_timestamp(Utc::now());
    let lease_expires_at = postgres_timestamp(now + Duration::minutes(5));

    let live = create_resumable_job(
        &db.pool,
        &repo,
        "erased-selector-live",
        now - Duration::minutes(3),
    )
    .await;
    let stale = create_resumable_job(
        &db.pool,
        &repo,
        "erased-selector-stale",
        now - Duration::minutes(2),
    )
    .await;
    sqlx::query(
        "UPDATE customers
         SET lifecycle_generation = lifecycle_generation + 1
         WHERE id = $1",
    )
    .bind(stale.customer_id)
    .execute(&db.pool)
    .await
    .expect("make public row generation stale");
    let stale_before = serialized_import_job_row(&db.pool, stale.id).await;

    let erased = create_resumable_job(
        &db.pool,
        &repo,
        "erased-selector-tombstone",
        now - Duration::minutes(1),
    )
    .await;
    hard_erase_customer(&db.pool, erased.customer_id).await;
    let tombstone_before = serialized_import_job_row(&db.pool, erased.id).await;

    let claims = repo
        .claim_elapsed_resume_deadlines(now, lease_expires_at, 10)
        .await
        .expect("claim elapsed resume deadlines");
    assert_eq!(
        claims.iter().map(|claim| claim.job_id).collect::<Vec<_>>(),
        vec![live.id],
        "only the current-generation public control should be claimed"
    );
    let claim = claims.first().expect("live control claim");
    assert_eq!(claim.cloud_job_id, live.cloud_job_id);
    assert_eq!(claim.engine_job_id, live.engine_job_id.unwrap());
    assert_eq!(
        claim.resume_intent_generation,
        live.resume_intent_generation
    );
    assert_eq!(claim.resume_count, live.resume_count);
    assert_eq!(
        claim.resume_deadline,
        postgres_timestamp(live.resume_deadline.unwrap())
    );
    assert_eq!(claim.worker_claimed_at, now);
    assert_eq!(claim.worker_lease_expires_at, lease_expires_at);

    assert!(
        repo.claim_elapsed_resume_deadlines(now, lease_expires_at, 10)
            .await
            .expect("replay elapsed resume deadline claim")
            .is_empty(),
        "second claim with an unexpired lease must not duplicate work"
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, stale.id).await,
        stale_before
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, erased.id).await,
        tombstone_before
    );
}

#[tokio::test]
async fn soft_deleted_customer_selector_exclusions_preserve_all_import_evidence() {
    let Some(db) = connect_and_migrate("algolia_deleted_selector_exclusions").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();

    let queued_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, queued_customer, 1).await;
    let queued = repo
        .create(new_job(queued_customer, "deleted-selector-queued"))
        .await
        .expect("create queued import");

    let failed = create_resumable_job(
        &db.pool,
        &repo,
        "deleted-selector-failed",
        now - Duration::minutes(2),
    )
    .await;

    let stale_intent = create_resumable_job(
        &db.pool,
        &repo,
        "deleted-selector-stale-intent",
        now - Duration::minutes(1),
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET resume_intent_generation = resume_intent_generation + 3
         WHERE id = $1",
    )
    .bind(stale_intent.id)
    .execute(&db.pool)
    .await
    .expect("seed stale resume intent generation");

    let resuming = create_resumable_job(
        &db.pool,
        &repo,
        "deleted-selector-resuming",
        now + Duration::hours(1),
    )
    .await;
    let resuming = repo
        .prepare_resume(resuming.id)
        .await
        .expect("prepare resuming selector fixture")
        .job;

    let terminal_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, terminal_customer, 1).await;
    let terminal = repo
        .create(new_job(terminal_customer, "deleted-selector-terminal"))
        .await
        .expect("create terminal fixture");
    repo.record_dispatch_intent_committed(terminal.id, Uuid::new_v4())
        .await
        .expect("commit terminal fixture dispatch");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged', terminal_at = $2 - INTERVAL '91 days'
         WHERE id = $1",
    )
    .bind(terminal.id)
    .bind(now)
    .execute(&db.pool)
    .await
    .expect("seed terminal GC fixture");

    let jobs = [
        queued.id,
        failed.id,
        stale_intent.id,
        resuming.id,
        terminal.id,
    ];
    let before = serialized_import_job_rows(&db.pool, &jobs).await;

    for customer_id in [
        queued_customer,
        failed.customer_id,
        stale_intent.customer_id,
        resuming.customer_id,
        terminal_customer,
    ] {
        soft_delete_customer(&db.pool, customer_id).await;
    }

    assert!(
        repo.claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 10)
            .await
            .expect("claim deleted-customer selector fixtures")
            .is_empty(),
        "deleted customers must be excluded from elapsed resume claims"
    );
    assert!(
        repo.gc_retained_terminal_history(now, 10)
            .await
            .expect("GC deleted-customer selector fixtures")
            .is_empty(),
        "deleted customers must be excluded from retained terminal GC"
    );

    let after = serialized_import_job_rows(&db.pool, &jobs).await;
    assert_eq!(after, before);
}

#[tokio::test]
async fn erased_tombstone_ack_release_compacts_exactly_once() {
    let Some(db) = connect_and_migrate("algolia_erased_ack_compaction").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());

    let (_eligible_id, eligible_handle, eligible_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absent",
        AlgoliaImportEngineAckState::OutboxPending,
        AlgoliaImportPublicationDisposition::Unchanged,
        false,
    )
    .await;
    let (pre_absence_id, pre_absence_handle, pre_absence_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absence_required",
        AlgoliaImportEngineAckState::OutboxPending,
        AlgoliaImportPublicationDisposition::Unchanged,
        false,
    )
    .await;
    let (pre_ack_id, pre_ack_handle, pre_ack_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absent",
        AlgoliaImportEngineAckState::Pending,
        AlgoliaImportPublicationDisposition::Unchanged,
        false,
    )
    .await;

    let stale_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, stale_customer, 1).await;
    let stale_public = repo
        .create(new_job(stale_customer, "erased-ack-stale-public"))
        .await
        .expect("admit stale public ACK fence");
    repo.record_dispatch_intent_committed(stale_public.id, Uuid::new_v4())
        .await
        .expect("commit stale public dispatch");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'outbox_pending', terminal_at = NOW() - INTERVAL '1 day'
         WHERE id = $1",
    )
    .bind(stale_public.id)
    .execute(&db.pool)
    .await
    .expect("seed stale public ACK fence");
    sqlx::query(
        "UPDATE customers
         SET lifecycle_generation = lifecycle_generation + 1
         WHERE id = $1",
    )
    .bind(stale_customer)
    .execute(&db.pool)
    .await
    .expect("make public ACK fence generation stale");
    let stale_public_before = serialized_import_job_row(&db.pool, stale_public.id).await;

    let acknowledged = repo
        .mark_engine_acknowledged(eligible_before["id"].as_str().unwrap().parse().unwrap())
        .await
        .expect("acknowledge eligible erased tombstone");
    assert_eq!(
        acknowledged.engine_ack_state,
        AlgoliaImportEngineAckState::Acknowledged
    );
    let after_first = serialized_import_job_row_by_erasure_handle(&db.pool, eligible_handle).await;
    assert_eq!(after_first["engine_ack_state"], json!("acknowledged"));
    assert!(after_first["tombstone_compacted_at"].is_string());
    for field in [
        "id",
        "erasure_handle",
        "engine_job_id",
        "destination_vm_id",
        "publication_disposition",
        "cleanup_phase",
        "erased_at",
    ] {
        assert_eq!(after_first[field], eligible_before[field], "{field}");
    }

    repo.mark_engine_acknowledged(after_first["id"].as_str().unwrap().parse().unwrap())
        .await
        .expect("replay acknowledged tombstone");
    let after_replay = serialized_import_job_row_by_erasure_handle(&db.pool, eligible_handle).await;
    assert_eq!(after_replay, after_first);

    for (id, handle, before, context) in [
        (
            pre_absence_id,
            pre_absence_handle,
            pre_absence_before,
            "pre-absence tombstone",
        ),
        (
            pre_ack_id,
            pre_ack_handle,
            pre_ack_before,
            "pre-ACK tombstone",
        ),
    ] {
        assert_repo_conflict(repo.mark_engine_acknowledged(id).await, context);
        assert_eq!(
            serialized_import_job_row_by_erasure_handle(&db.pool, handle).await,
            before,
            "{context} must remain unchanged"
        );
    }
    assert_repo_conflict(
        repo.mark_engine_acknowledged(stale_public.id).await,
        "stale public ACK fence",
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, stale_public.id).await,
        stale_public_before
    );
}

#[tokio::test]
async fn erased_tombstone_terminal_gc_preserves_reconciliation_truth() {
    let Some(db) = connect_and_migrate("algolia_erased_terminal_gc").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = postgres_timestamp(Utc::now());

    let current_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, current_customer, 1).await;
    let current = repo
        .create(new_job(current_customer, "erased-gc-current"))
        .await
        .expect("admit current-generation GC control");
    repo.record_dispatch_intent_committed(current.id, Uuid::new_v4())
        .await
        .expect("commit current-generation GC control");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged', terminal_at = $2 - INTERVAL '90 days'
         WHERE id = $1",
    )
    .bind(current.id)
    .bind(now)
    .execute(&db.pool)
    .await
    .expect("seed ordinary eligible GC row");

    let stale_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, stale_customer, 1).await;
    let stale_public = repo
        .create(new_job(stale_customer, "erased-gc-stale-public"))
        .await
        .expect("admit stale GC control");
    repo.record_dispatch_intent_committed(stale_public.id, Uuid::new_v4())
        .await
        .expect("commit stale GC control");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'completed', publication_disposition = 'promoted',
             engine_ack_state = 'acknowledged', terminal_at = $2 - INTERVAL '91 days'
         WHERE id = $1",
    )
    .bind(stale_public.id)
    .bind(now)
    .execute(&db.pool)
    .await
    .expect("seed stale public GC control");
    sqlx::query(
        "UPDATE customers
         SET lifecycle_generation = lifecycle_generation + 1
         WHERE id = $1",
    )
    .bind(stale_customer)
    .execute(&db.pool)
    .await
    .expect("make public GC control generation stale");

    let (pending_id, _, pending_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absence_required",
        AlgoliaImportEngineAckState::Pending,
        AlgoliaImportPublicationDisposition::Unchanged,
        false,
    )
    .await;
    let (ack_id, _, ack_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absent",
        AlgoliaImportEngineAckState::Acknowledged,
        AlgoliaImportPublicationDisposition::Unchanged,
        false,
    )
    .await;
    let (compacted_id, _, compacted_before) = seed_schema_056_tombstone(
        &db.pool,
        "exact_target_absent",
        AlgoliaImportEngineAckState::Acknowledged,
        AlgoliaImportPublicationDisposition::Unchanged,
        true,
    )
    .await;
    let stale_before = serialized_import_job_row(&db.pool, stale_public.id).await;

    assert_eq!(
        repo.gc_retained_terminal_history(now, 10)
            .await
            .expect("run erased tombstone retention GC"),
        vec![current.id]
    );
    assert!(repo
        .gc_retained_terminal_history(now, 10)
        .await
        .expect("replay erased tombstone retention GC")
        .is_empty());
    assert!(!import_job_exists(&db.pool, current.id).await);
    assert_eq!(
        serialized_import_job_row(&db.pool, stale_public.id).await,
        stale_before
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, pending_id).await,
        pending_before
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, ack_id).await,
        ack_before
    );
    assert_eq!(
        serialized_import_job_row(&db.pool, compacted_id).await,
        compacted_before
    );
}

#[tokio::test]
async fn algolia_import_job_domain_claims_elapsed_resume_deadlines_without_finalizing() {
    let Some(db) = connect_and_migrate("algolia_resume_deadline_claim").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let first = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-first",
        now - Duration::minutes(3),
    )
    .await;
    let second = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-second",
        now - Duration::minutes(2),
    )
    .await;
    let _third = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-third",
        now - Duration::minutes(1),
    )
    .await;
    let first_tie = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-first-tie",
        first.resume_deadline.unwrap(),
    )
    .await;
    let future = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-future",
        now + Duration::minutes(1),
    )
    .await;

    let claims = repo
        .claim_elapsed_resume_deadlines(now, now + Duration::minutes(10), 3)
        .await
        .unwrap();
    let mut expected = vec![first.id, first_tie.id];
    expected.sort();
    expected.push(second.id);
    assert_eq!(
        claims.iter().map(|claim| claim.job_id).collect::<Vec<_>>(),
        expected
    );
    let first_claim = claims
        .iter()
        .find(|claim| claim.job_id == first.id)
        .expect("first job must be claimed");
    assert_eq!(first_claim.cloud_job_id, first.cloud_job_id);
    assert_eq!(first_claim.engine_job_id, first.engine_job_id.unwrap());
    assert_eq!(
        first_claim.resume_intent_generation,
        first.resume_intent_generation
    );
    assert_eq!(first_claim.resume_count, first.resume_count);
    assert_eq!(
        first_claim.resume_deadline,
        postgres_timestamp(first.resume_deadline.unwrap())
    );

    let claimed = repo.get(first.id).await.unwrap().unwrap();
    assert_eq!(claimed.status, first.status);
    assert_eq!(claimed.resumable, first.resumable);
    assert_eq!(claimed.engine_ack_state, first.engine_ack_state);
    assert_eq!(
        claimed.publication_disposition,
        first.publication_disposition
    );
    assert_eq!(claimed.lifecycle_generation, first.lifecycle_generation);
    assert_eq!(claimed.destination_vm_id, first.destination_vm_id);
    assert_eq!(claimed.worker_claimed_at, Some(postgres_timestamp(now)));
    assert_eq!(
        claimed.worker_lease_expires_at,
        Some(postgres_timestamp(now + Duration::minutes(10)))
    );

    let future_after_claim = repo.get(future.id).await.unwrap().unwrap();
    assert_eq!(future_after_claim.worker_claimed_at, None);
    assert_eq!(future_after_claim.worker_lease_expires_at, None);
}

#[tokio::test]
async fn algolia_import_job_domain_deadline_claim_excludes_concurrent_and_active_resume() {
    let Some(db) = connect_and_migrate("algolia_resume_deadline_exclusion").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let concurrent = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-concurrent",
        now - Duration::minutes(2),
    )
    .await;
    let prepared = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-prepared",
        now + Duration::minutes(1),
    )
    .await;
    repo.prepare_resume(prepared.id).await.unwrap();

    let first_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let second_repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (first, second) = tokio::join!(
        first_repo.claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 1),
        second_repo.claim_elapsed_resume_deadlines(now, now + Duration::minutes(5), 1)
    );
    let total_claims = first.unwrap().len() + second.unwrap().len();
    assert_eq!(total_claims, 1);

    let prepared_after_claim = repo.get(prepared.id).await.unwrap().unwrap();
    assert_eq!(
        prepared_after_claim.status,
        AlgoliaImportJobStatus::Resuming
    );
    assert_eq!(prepared_after_claim.worker_claimed_at, None);
    assert_eq!(prepared_after_claim.worker_lease_expires_at, None);

    let concurrent_after_claim = repo.get(concurrent.id).await.unwrap().unwrap();
    assert_eq!(
        concurrent_after_claim.worker_claimed_at,
        Some(postgres_timestamp(now))
    );
}

#[tokio::test]
async fn algolia_import_job_domain_deadline_claim_reuses_expired_worker_lease() {
    let Some(db) = connect_and_migrate("algolia_resume_deadline_lease").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "deadline-expired-lease",
        now - Duration::minutes(1),
    )
    .await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at=$2, worker_lease_expires_at=$3
         WHERE id=$1",
    )
    .bind(job.id)
    .bind(now - Duration::hours(1))
    .bind(now - Duration::minutes(30))
    .execute(&db.pool)
    .await
    .unwrap();

    let claims = repo
        .claim_elapsed_resume_deadlines(now, now + Duration::minutes(10), 10)
        .await
        .unwrap();
    assert_eq!(claims.len(), 1);
    assert_eq!(claims[0].job_id, job.id);

    let claimed = repo.get(job.id).await.unwrap().unwrap();
    assert_eq!(claimed.worker_claimed_at, Some(postgres_timestamp(now)));
    assert_eq!(
        claimed.worker_lease_expires_at,
        Some(postgres_timestamp(now + Duration::minutes(10)))
    );
}

// ---------------------------------------------------------------------------
// Customer-scoped cancel/resume adapters (Stage 3 HTTP seam)
// ---------------------------------------------------------------------------

/// Advance a fresh job to a non-resumable `Failed` state: finally terminal (so
/// cancel is refused) and not resumable (so resume is refused).
async fn create_non_resumable_failed_job(
    pool: &PgPool,
    repo: &PgAlgoliaImportJobRepo,
    key: &str,
) -> AlgoliaImportJob {
    let admitted =
        create_admitted_job(pool, repo, key, AlgoliaImportJobStatus::CopyingDocuments).await;
    let mut failed = admitted_state(AlgoliaImportJobStatus::Failed);
    failed.engine_job_id = admitted.engine_job_id;
    failed.resumable = false;
    failed.resume_mirror = None;
    failed.error_code = Some(AlgoliaImportErrorCode::BackendUnavailable);
    failed.error_message = Some("terminal failure".into());
    repo.update_persisted_state(admitted.id, failed)
        .await
        .unwrap()
}

fn assert_not_found(error: AlgoliaLifecycleError) {
    match error {
        AlgoliaLifecycleError::NotFound => {}
        other => panic!("expected NotFound, got {other:?}"),
    }
}

fn assert_refused(error: AlgoliaLifecycleError, expected: AlgoliaImportErrorCode) {
    match error {
        AlgoliaLifecycleError::Refused(code) => assert_eq!(code, expected),
        other => panic!("expected Refused({expected:?}), got {other:?}"),
    }
}

#[tokio::test]
async fn algolia_cloud_job_repo_cancel_for_customer_missing_and_foreign_are_not_found() {
    let Some(db) = connect_and_migrate("algolia_scoped_cancel_notfound").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let owner = Uuid::new_v4();
    insert_active_customer(&db.pool, owner, 1).await;
    let job = repo
        .create(new_job(owner, "scoped-cancel-nf"))
        .await
        .unwrap();
    let intruder = Uuid::new_v4();

    assert_not_found(
        repo.request_cancel_for_customer(owner, Uuid::new_v4())
            .await
            .expect_err("a missing job is NotFound"),
    );
    assert_not_found(
        repo.request_cancel_for_customer(intruder, job.id)
            .await
            .expect_err("a foreign job is NotFound, indistinguishable from missing"),
    );

    // The foreign attempt must not have mutated the owner's job.
    let untouched = repo
        .get_for_customer(owner, job.id)
        .await
        .unwrap()
        .expect("owner still sees the job");
    assert_eq!(untouched.status, AlgoliaImportJobStatus::Queued);
    assert!(untouched.cancel_requested_at.is_none());
}

#[tokio::test]
async fn algolia_cloud_job_repo_cancel_for_customer_queued_is_accepted_without_dispatch() {
    let Some(db) = connect_and_migrate("algolia_scoped_cancel_queued").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    // A freshly created job is Queued with no engine dispatch yet.
    let created = repo
        .create(new_job(customer, "scoped-cancel-queued"))
        .await
        .unwrap();
    assert_eq!(created.status, AlgoliaImportJobStatus::Queued);
    assert!(created.engine_job_id.is_none());

    let outcome = repo
        .request_cancel_for_customer(customer, created.id)
        .await
        .expect("owned queued job cancels");

    // A newly cancelled queued job is Accepted even though it has no dispatch:
    // disposition, not dispatch presence, carries the newly-accepted signal.
    assert_eq!(
        outcome.disposition,
        AlgoliaImportTransitionDisposition::Accepted
    );
    assert!(outcome.was_accepted());
    assert!(!outcome.should_dispatch());
    assert_eq!(outcome.job.status, AlgoliaImportJobStatus::Cancelling);
    assert!(outcome.job.cancel_requested_at.is_some());
}

#[tokio::test]
async fn algolia_cloud_job_repo_cancel_for_customer_non_cancellable_is_refused() {
    let Some(db) = connect_and_migrate("algolia_scoped_cancel_refused").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let job = create_non_resumable_failed_job(&db.pool, &repo, "scoped-cancel-refused").await;

    assert_refused(
        repo.request_cancel_for_customer(job.customer_id, job.id)
            .await
            .expect_err("a finally terminal job cannot be cancelled"),
        AlgoliaImportErrorCode::CancelNotPermitted,
    );

    let untouched = repo
        .get_for_customer(job.customer_id, job.id)
        .await
        .unwrap()
        .expect("job still present");
    assert_eq!(untouched.status, AlgoliaImportJobStatus::Failed);
}

#[tokio::test]
async fn algolia_cloud_job_repo_cancel_for_customer_concurrent_yields_one_accepted() {
    let Some(db) = connect_and_migrate("algolia_scoped_cancel_concurrent").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let job = create_admitted_job(
        &db.pool,
        &repo,
        "scoped-cancel-concurrent",
        AlgoliaImportJobStatus::CopyingDocuments,
    )
    .await;
    let owner = job.customer_id;

    let first = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let second = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (a, b) = tokio::join!(
        first.request_cancel_for_customer(owner, job.id),
        second.request_cancel_for_customer(owner, job.id)
    );
    let a = a.expect("first concurrent cancel ok");
    let b = b.expect("second concurrent cancel ok");

    let accepted = [a.was_accepted(), b.was_accepted()];
    assert_eq!(
        accepted.iter().filter(|x| **x).count(),
        1,
        "exactly one concurrent cancel is Accepted; the other is an idempotent Replay"
    );
    assert_eq!(a.job.status, AlgoliaImportJobStatus::Cancelling);
    assert_eq!(b.job.status, AlgoliaImportJobStatus::Cancelling);
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_missing_and_foreign_are_not_found() {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_notfound").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "scoped-resume-nf",
        now + Duration::hours(1),
    )
    .await;
    let owner = job.customer_id;
    let intruder = Uuid::new_v4();

    assert_not_found(
        repo.prepare_resume_for_customer(owner, Uuid::new_v4(), now)
            .await
            .expect_err("missing is NotFound"),
    );
    assert_not_found(
        repo.prepare_resume_for_customer(intruder, job.id, now)
            .await
            .expect_err("foreign is NotFound"),
    );

    let untouched = repo
        .get_for_customer(owner, job.id)
        .await
        .unwrap()
        .expect("owner still sees the job");
    assert_eq!(untouched.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        untouched.resume_intent_generation,
        job.resume_intent_generation
    );
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_accepts_then_replays() {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_accept").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "scoped-resume-accept",
        now + Duration::hours(1),
    )
    .await;
    let owner = job.customer_id;

    let accepted = repo
        .prepare_resume_for_customer(owner, job.id, now)
        .await
        .expect("resumable job resumes");
    assert_eq!(
        accepted.disposition,
        AlgoliaImportTransitionDisposition::Accepted
    );
    assert!(accepted.should_dispatch());
    assert_eq!(accepted.job.status, AlgoliaImportJobStatus::Resuming);
    assert_eq!(accepted.generation, job.resume_intent_generation + 1);

    // A repeat resume is an idempotent replay: 200, no generation/count advance.
    let replay = repo
        .prepare_resume_for_customer(owner, job.id, now)
        .await
        .expect("repeat resume replays");
    assert_eq!(
        replay.disposition,
        AlgoliaImportTransitionDisposition::Replayed
    );
    assert!(!replay.should_dispatch());
    assert_eq!(replay.generation, accepted.generation);
    assert_eq!(replay.expected_attempt, accepted.expected_attempt);
    assert_eq!(replay.job.resume_intent_generation, accepted.generation);
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_concurrent_yields_one_accepted() {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_concurrent").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_job(
        &db.pool,
        &repo,
        "scoped-resume-concurrent",
        now + Duration::hours(1),
    )
    .await;
    let owner = job.customer_id;

    let first = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let second = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let (a, b) = tokio::join!(
        first.prepare_resume_for_customer(owner, job.id, now),
        second.prepare_resume_for_customer(owner, job.id, now)
    );
    let a = a.expect("first concurrent resume ok");
    let b = b.expect("second concurrent resume ok");

    let accepted = [a.was_accepted(), b.was_accepted()];
    assert_eq!(
        accepted.iter().filter(|x| **x).count(),
        1,
        "exactly one concurrent resume is Accepted; the other is an idempotent Replay"
    );
    assert_eq!(a.job.status, AlgoliaImportJobStatus::Resuming);
    assert_eq!(b.job.status, AlgoliaImportJobStatus::Resuming);
    assert_eq!(a.generation, job.resume_intent_generation + 1);
    assert_eq!(b.generation, job.resume_intent_generation + 1);
    assert_eq!(a.expected_attempt, job.resume_count + 1);
    assert_eq!(b.expected_attempt, job.resume_count + 1);

    let persisted = repo
        .get_for_customer(owner, job.id)
        .await
        .unwrap()
        .expect("job still present");
    assert_eq!(
        persisted.resume_intent_generation,
        job.resume_intent_generation + 1
    );
    assert_eq!(persisted.resume_count, job.resume_count);
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_deadline_equality_and_elapsed_are_not_resumable(
) {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_deadline").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let deadline = Utc::now();

    // Clock exactly at the deadline is already closed: `resume_deadline <= now`.
    let at_deadline = create_resumable_job(&db.pool, &repo, "scoped-resume-eq", deadline).await;
    assert_refused(
        repo.prepare_resume_for_customer(at_deadline.customer_id, at_deadline.id, deadline)
            .await
            .expect_err("deadline equality is not resumable"),
        AlgoliaImportErrorCode::NotResumable,
    );

    // Elapsed deadline is likewise not resumable, and the job is not mutated.
    let elapsed = create_resumable_job(&db.pool, &repo, "scoped-resume-elapsed", deadline).await;
    assert_refused(
        repo.prepare_resume_for_customer(
            elapsed.customer_id,
            elapsed.id,
            deadline + Duration::seconds(1),
        )
        .await
        .expect_err("elapsed deadline is not resumable"),
        AlgoliaImportErrorCode::NotResumable,
    );
    let untouched = repo
        .get_for_customer(elapsed.customer_id, elapsed.id)
        .await
        .unwrap()
        .expect("job still present");
    assert_eq!(untouched.status, AlgoliaImportJobStatus::Failed);
    assert_eq!(
        untouched.resume_intent_generation,
        elapsed.resume_intent_generation
    );
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_non_resumable_is_refused() {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_norefused").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let job = create_non_resumable_failed_job(&db.pool, &repo, "scoped-resume-norefused").await;

    assert_refused(
        repo.prepare_resume_for_customer(job.customer_id, job.id, Utc::now())
            .await
            .expect_err("a non-resumable job cannot resume"),
        AlgoliaImportErrorCode::NotResumable,
    );
}

#[tokio::test]
async fn algolia_cloud_job_repo_resume_for_customer_unhealthy_replace_target_is_backend_unavailable(
) {
    let Some(db) = connect_and_migrate("algolia_scoped_resume_unhealthy").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let now = Utc::now();
    let job = create_resumable_replace_job(
        &db.pool,
        &repo,
        "scoped-resume-unhealthy",
        now + Duration::hours(1),
    )
    .await;
    let before = persisted_state(&job);
    sqlx::query(
        "UPDATE customer_deployments SET health_status = 'degraded' WHERE customer_id = $1",
    )
    .bind(job.customer_id)
    .execute(&db.pool)
    .await
    .expect("degrade retained replace target");

    assert_refused(
        repo.prepare_resume_for_customer(job.customer_id, job.id, now)
            .await
            .expect_err("transient destination readiness blocks resume"),
        AlgoliaImportErrorCode::BackendUnavailable,
    );

    let untouched = repo
        .get_for_customer(job.customer_id, job.id)
        .await
        .unwrap()
        .expect("job still present");
    assert_eq!(persisted_state(&untouched).status, before.status);
    assert_eq!(
        persisted_state(&untouched).resume_intent_generation,
        before.resume_intent_generation
    );
    assert_eq!(
        persisted_state(&untouched).resume_mirror,
        before.resume_mirror
    );
}

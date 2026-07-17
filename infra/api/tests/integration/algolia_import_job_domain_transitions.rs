use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSource, AlgoliaImportSourceMetadata,
    AlgoliaImportSummary, EngineResumeMirror, NewAlgoliaImportJob,
};
use api::repos::{AlgoliaImportJobRepo, PgAlgoliaImportJobRepo, RepoError};
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};

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

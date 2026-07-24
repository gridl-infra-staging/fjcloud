use super::*;
use crate::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState,
    AlgoliaImportEngineAckState, AlgoliaImportErrorCode, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSource, AlgoliaImportSourceMetadata,
    NewAlgoliaImportJob,
};
use crate::repos::algolia_import_job_repo::AlgoliaImportEngineAbsenceProof;
use crate::repos::{AlgoliaImportDispatchAdmission, AlgoliaImportJobRepo};
use chrono::{Duration, Utc};
use sqlx::PgPool;
#[path = "../../tests/common/support/pg_schema_harness.rs"]
mod pg_schema_harness;

use pg_schema_harness::{connect_and_migrate, insert_active_customer, postgres_timestamp};

fn job(customer_id: Uuid, key: &str, canonical_fingerprint: &str) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-east-1"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(100), Some(10), canonical_fingerprint),
        ),
        key,
    )
}

#[test]
fn idempotent_create_accepts_only_matching_canonical_fingerprint() {
    let customer_id = Uuid::new_v4();
    let original = job(customer_id, "same-key", "sha256:canonical-request");
    let replay = job(customer_id, "same-key", "sha256:canonical-request");
    let changed = job(customer_id, "same-key", "sha256:changed-request");

    assert!(support::idempotent_create_replay_is_allowed(
        original.customer_id(),
        original.idempotency_key(),
        original.canonical_fingerprint(),
        &replay
    ));
    assert!(!support::idempotent_create_replay_is_allowed(
        original.customer_id(),
        original.idempotency_key(),
        original.canonical_fingerprint(),
        &changed
    ));
}

#[test]
fn canonical_fingerprint_includes_destination_semantics() {
    let customer_id = Uuid::new_v4();
    let east = job(customer_id, "same-key", "same-source");
    let west = NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new("products", "us-west-2"),
        AlgoliaImportSource::from_final_key_metadata(
            "AB12CD34EF",
            "Products",
            AlgoliaImportSourceMetadata::new(Some(100), Some(10), "same-source"),
        ),
        "same-key",
    );

    assert_ne!(east.canonical_fingerprint(), west.canonical_fingerprint());
    assert!(!support::idempotent_create_replay_is_allowed(
        east.customer_id(),
        east.idempotency_key(),
        east.canonical_fingerprint(),
        &west,
    ));
}

#[test]
fn terminal_catalog_effects_are_closed_over_promoted_disposition() {
    use reconciliation::TerminalCatalogEffect::{
        PublishCreatePlacement, PublishReplacementPlacement, Unchanged,
    };

    assert_eq!(
        reconciliation::terminal_catalog_effect(
            AlgoliaImportDestinationKind::Create,
            AlgoliaImportPublicationDisposition::Promoted
        ),
        PublishCreatePlacement
    );
    assert_eq!(
        reconciliation::terminal_catalog_effect(
            AlgoliaImportDestinationKind::Replace,
            AlgoliaImportPublicationDisposition::Promoted
        ),
        PublishReplacementPlacement
    );

    for disposition in [
        AlgoliaImportPublicationDisposition::NotStarted,
        AlgoliaImportPublicationDisposition::Unchanged,
        AlgoliaImportPublicationDisposition::Unknown,
    ] {
        assert_eq!(
            reconciliation::terminal_catalog_effect(
                AlgoliaImportDestinationKind::Create,
                disposition
            ),
            Unchanged,
            "create {disposition:?} must not publish catalog rows"
        );
        assert_eq!(
            reconciliation::terminal_catalog_effect(
                AlgoliaImportDestinationKind::Replace,
                disposition
            ),
            Unchanged,
            "replace {disposition:?} must not mutate catalog rows"
        );
    }
}

fn dispatch_job(customer_id: Uuid, key: &str) -> NewAlgoliaImportJob {
    job(customer_id, key, &format!("revision-{key}"))
}

async fn admit_create_dispatch(
    repo: &PgAlgoliaImportJobRepo,
    new_job: NewAlgoliaImportJob,
) -> AlgoliaImportJob {
    repo.admit_dispatch(AlgoliaImportDispatchAdmission::Create(new_job))
        .await
        .expect("admit create dispatch fixture")
        .into_job()
}

async fn catalog_row_count(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM customer_tenants WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer tenant rows")
}

async fn deployment_row_count(pool: &PgPool, customer_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM customer_deployments WHERE customer_id = $1")
        .bind(customer_id)
        .fetch_one(pool)
        .await
        .expect("count customer deployment rows")
}

async fn has_active_reservation(pool: &PgPool, job_id: Uuid) -> bool {
    sqlx::query_scalar(&format!(
        "SELECT EXISTS(
            SELECT 1 FROM algolia_import_jobs
            WHERE id = $1 AND {}
         )",
        PgAlgoliaImportJobRepo::active_reservation_predicate_for_contract_tests()
    ))
    .bind(job_id)
    .fetch_one(pool)
    .await
    .expect("evaluate active reservation predicate")
}

#[tokio::test]
async fn authenticated_engine_absence_proof_remains_crate_internal() {
    let Some(db) = connect_and_migrate("algolia_catalog_seal_absent_unit").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let admitted = admit_create_dispatch(&repo, dispatch_job(customer_id, "seal-absent")).await;
    let cancelling = repo
        .request_cancel(admitted.id)
        .await
        .expect("request cancel")
        .job;
    let terminal_at = postgres_timestamp(Utc::now());

    let outcome = repo
        .finalize_authenticated_engine_absence(
            AlgoliaImportEngineAbsenceProof::from_authenticated_engine_absence(
                cancelling.id,
                cancelling.lifecycle_generation,
                terminal_at,
            ),
        )
        .await
        .expect("seal authenticated engine absence");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(sealed) = outcome else {
        panic!("expected Applied seal tombstone finalization");
    };

    assert_eq!(sealed.status, AlgoliaImportJobStatus::Interrupted);
    assert_eq!(
        sealed.publication_disposition,
        AlgoliaImportPublicationDisposition::NotStarted
    );
    assert_eq!(
        sealed.engine_ack_state,
        AlgoliaImportEngineAckState::SealAcknowledged
    );
    assert_eq!(
        sealed.dispatch_intent_state,
        AlgoliaImportDispatchIntentState::Ambiguous
    );
    assert_eq!(sealed.engine_job_id, None);
    assert_eq!(sealed.terminal_at, Some(terminal_at));
    assert_eq!(sealed.error_code, Some(AlgoliaImportErrorCode::Interrupted));
    assert!(!sealed.retryable);
    assert!(!sealed.resumable);
    assert!(!has_active_reservation(&db.pool, sealed.id).await);
    match repo.mark_engine_acknowledged(sealed.id).await {
        Err(RepoError::Conflict(message)) => assert_eq!(
            message,
            "engine acknowledgement requires retained terminal outbox work"
        ),
        Ok(outcome) => panic!("seal absence must not create ACK outbox work: {outcome:?}"),
        Err(other) => panic!("expected ACK conflict for seal absence, got {other:?}"),
    }
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
}

#[tokio::test]
async fn authenticated_engine_absence_seal_wins_ack_race_without_cross_job_release() {
    let Some(db) = connect_and_migrate("algolia_catalog_seal_ack_race").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    let unrelated_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    insert_active_customer(&db.pool, unrelated_customer_id, 1).await;
    let admitted = admit_create_dispatch(&repo, dispatch_job(customer_id, "seal-race")).await;
    let unrelated = admit_create_dispatch(
        &repo,
        dispatch_job(unrelated_customer_id, "seal-race-control"),
    )
    .await;
    let cancelling = repo
        .request_cancel(admitted.id)
        .await
        .expect("request cancel")
        .job;
    let terminal_at = postgres_timestamp(Utc::now());
    let proof = AlgoliaImportEngineAbsenceProof::from_authenticated_engine_absence(
        cancelling.id,
        cancelling.lifecycle_generation,
        terminal_at,
    );
    let ack_repo = repo.clone();

    let (seal_result, ack_result) = tokio::join!(
        repo.finalize_authenticated_engine_absence(proof),
        ack_repo.mark_engine_acknowledged(cancelling.id),
    );

    let AlgoliaImportTerminalFinalizationOutcome::Applied(sealed) =
        seal_result.expect("authenticated absence wins the seal race")
    else {
        panic!("authenticated absence must apply exactly once");
    };
    assert_eq!(
        sealed.engine_ack_state,
        AlgoliaImportEngineAckState::SealAcknowledged
    );
    assert_eq!(sealed.terminal_at, Some(terminal_at));
    match ack_result {
        Err(RepoError::Conflict(message)) => assert_eq!(
            message,
            "engine acknowledgement requires retained terminal outbox work"
        ),
        Err(other) => panic!("seal race ACK must fail with a typed conflict, got {other:?}"),
        Ok(outcome) => panic!("seal race must not create ACK outbox work: {outcome:?}"),
    }
    assert!(!has_active_reservation(&db.pool, sealed.id).await);
    assert!(has_active_reservation(&db.pool, unrelated.id).await);
    assert_eq!(catalog_row_count(&db.pool, customer_id).await, 0);
    assert_eq!(deployment_row_count(&db.pool, customer_id).await, 0);
}

#[tokio::test]
async fn gc_deletes_seal_acknowledged_absence_at_exact_ninety_day_boundary() {
    let Some(db) = connect_and_migrate("algolia_catalog_seal_gc").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, customer_id, 1).await;
    let admitted = admit_create_dispatch(&repo, dispatch_job(customer_id, "seal-gc")).await;
    let cancelling = repo
        .request_cancel(admitted.id)
        .await
        .expect("request cancel")
        .job;
    let terminal_at = postgres_timestamp(Utc::now() - Duration::days(200));

    let outcome = repo
        .finalize_authenticated_engine_absence(
            AlgoliaImportEngineAbsenceProof::from_authenticated_engine_absence(
                cancelling.id,
                cancelling.lifecycle_generation,
                terminal_at,
            ),
        )
        .await
        .expect("seal authenticated engine absence");
    let AlgoliaImportTerminalFinalizationOutcome::Applied(sealed) = outcome else {
        panic!("expected Applied seal tombstone finalization");
    };
    assert_eq!(
        sealed.engine_ack_state,
        AlgoliaImportEngineAckState::SealAcknowledged
    );
    assert!(!has_active_reservation(&db.pool, sealed.id).await);

    let just_before = terminal_at + Duration::days(90) - Duration::seconds(1);
    let deleted = repo
        .gc_retained_terminal_history(just_before, 100)
        .await
        .expect("GC runs before seal boundary");
    assert!(
        !deleted.contains(&sealed.id),
        "seal_acknowledged row is retained at 89d23h59m59s"
    );
    assert!(
        repo.get(sealed.id)
            .await
            .expect("read sealed row before boundary")
            .is_some(),
        "seal_acknowledged row exists before boundary"
    );

    let deleted = repo
        .gc_retained_terminal_history(terminal_at + Duration::days(90), 100)
        .await
        .expect("GC runs at exact seal boundary");
    assert!(
        deleted.contains(&sealed.id),
        "seal_acknowledged row is deleted at exact 90-day boundary"
    );
    assert!(
        repo.get(sealed.id)
            .await
            .expect("read sealed row after boundary")
            .is_none(),
        "seal_acknowledged row is physically deleted at boundary"
    );
}

#[tokio::test]
async fn gc_retains_unknown_and_stale_generation_terminal_controls() {
    let Some(db) = connect_and_migrate("algolia_catalog_gc_defensive").await else {
        return;
    };
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    let anchor = postgres_timestamp(Utc::now() - Duration::days(200));

    let stale_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, stale_customer_id, 1).await;
    let stale_created = repo
        .create(dispatch_job(stale_customer_id, "gc-stale-generation"))
        .await
        .expect("create stale-generation fixture");
    let stale_terminal = repo
        .record_no_dispatch_failure(
            stale_created.id,
            AlgoliaImportErrorCode::InvalidCredentials,
            Some("sanitized local failure"),
        )
        .await
        .expect("record stale-generation terminal fixture");
    sqlx::query("UPDATE customers SET lifecycle_generation = 2 WHERE id = $1")
        .bind(stale_customer_id)
        .execute(&db.pool)
        .await
        .expect("advance customer generation after terminal retention");

    let unknown_customer_id = Uuid::new_v4();
    insert_active_customer(&db.pool, unknown_customer_id, 1).await;
    let unknown = repo
        .create(dispatch_job(unknown_customer_id, "gc-unknown"))
        .await
        .expect("create unknown-disposition fixture");
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'failed',
             publication_disposition = 'unknown',
             engine_ack_state = 'acknowledged',
             dispatch_intent_state = 'committed',
             engine_job_id = $2,
             terminal_at = $3,
             error_code = 'internal',
             retryable = FALSE,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(unknown.id)
    .bind(Uuid::new_v4())
    .bind(anchor)
    .execute(&db.pool)
    .await
    .expect("seed defensive unknown-disposition terminal");

    let deleted = repo
        .gc_retained_terminal_history(anchor + Duration::days(90), 100)
        .await
        .expect("GC runs with defensive retained controls");

    assert!(
        !deleted.contains(&stale_terminal.id),
        "stale-generation terminal row is retained"
    );
    assert!(
        !deleted.contains(&unknown.id),
        "unknown-disposition terminal row is retained"
    );
    assert!(
        repo.get(stale_terminal.id)
            .await
            .expect("read stale-generation row after GC")
            .is_some(),
        "stale-generation terminal row still exists after GC"
    );
    assert!(
        repo.get(unknown.id)
            .await
            .expect("read unknown-disposition row after GC")
            .is_some(),
        "unknown-disposition terminal row still exists after GC"
    );
}

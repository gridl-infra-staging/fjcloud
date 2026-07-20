use std::collections::BTreeSet;

use api::models::algolia_import_job::{
    AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState, AlgoliaImportErrorCode,
    AlgoliaImportJob, AlgoliaImportJobStatus, AlgoliaImportPublicationDisposition,
};
use chrono::Utc;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReservationExpectation {
    Release,
    Retain,
}

#[derive(Debug, Clone)]
pub struct ReservationLifetimeCase {
    pub label: String,
    pub status: AlgoliaImportJobStatus,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub engine_ack_state: AlgoliaImportEngineAckState,
    pub resumable: bool,
    pub expectation: ReservationExpectation,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct DenominatorValidation {
    pub missing: BTreeSet<String>,
    pub duplicate_labels: BTreeSet<String>,
    pub unexpected: BTreeSet<String>,
}

pub fn assert_algolia_import_job_unchanged_except_worker_claim(
    before: &AlgoliaImportJob,
    after: &AlgoliaImportJob,
) {
    let mut expected = before.clone();
    expected.worker_claimed_at = after.worker_claimed_at;
    expected.worker_lease_expires_at = after.worker_lease_expires_at;
    assert_eq!(
        serde_json::to_value(after).expect("serialize observed import job"),
        serde_json::to_value(expected).expect("serialize expected import job"),
        "resume takeover must only change worker-claim ownership"
    );
}

pub fn algolia_import_statuses() -> &'static [AlgoliaImportJobStatus] {
    use AlgoliaImportJobStatus::{
        Cancelled, Cancelling, Completed, CompletedWithWarnings, CopyingConfiguration,
        CopyingDocuments, Failed, Interrupted, Promoting, Queued, Resuming, ValidatingSource,
        Verifying,
    };
    &[
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

pub fn algolia_import_publication_dispositions() -> &'static [AlgoliaImportPublicationDisposition] {
    use AlgoliaImportPublicationDisposition::{NotStarted, Promoted, Unchanged, Unknown};
    &[NotStarted, Unchanged, Promoted, Unknown]
}

pub fn algolia_import_engine_ack_states() -> &'static [AlgoliaImportEngineAckState] {
    use AlgoliaImportEngineAckState::{
        Acknowledged, NotApplicable, OutboxPending, Pending, SealAcknowledged,
    };
    &[
        Pending,
        NotApplicable,
        SealAcknowledged,
        OutboxPending,
        Acknowledged,
    ]
}

pub fn reservation_lifetime_denominator() -> Vec<ReservationLifetimeCase> {
    let mut cases = Vec::new();
    for &status in algolia_import_statuses() {
        for &publication_disposition in algolia_import_publication_dispositions() {
            for &engine_ack_state in algolia_import_engine_ack_states() {
                for resumable in [false, true] {
                    if !schema_valid_reservation_quad(
                        status,
                        publication_disposition,
                        engine_ack_state,
                        resumable,
                    ) {
                        continue;
                    }
                    let expectation = reservation_expectation(
                        status,
                        publication_disposition,
                        engine_ack_state,
                        resumable,
                    );
                    cases.push(ReservationLifetimeCase {
                        label: reservation_case_label(
                            status,
                            publication_disposition,
                            engine_ack_state,
                            resumable,
                        ),
                        status,
                        publication_disposition,
                        engine_ack_state,
                        resumable,
                        expectation,
                    });
                }
            }
        }
    }
    cases
}

pub fn validate_reservation_lifetime_denominator(
    cases: &[ReservationLifetimeCase],
) -> DenominatorValidation {
    let expected = expected_reservation_case_labels();
    let mut seen = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for case in cases {
        if !seen.insert(case.label.clone()) {
            duplicates.insert(case.label.clone());
        }
    }
    DenominatorValidation {
        missing: expected.difference(&seen).cloned().collect(),
        duplicate_labels: duplicates,
        unexpected: seen.difference(&expected).cloned().collect(),
    }
}

pub async fn force_reservation_lifetime_case(
    pool: &PgPool,
    job_id: Uuid,
    case: &ReservationLifetimeCase,
) {
    let engine_job_id = Uuid::new_v4();
    let observed_at = Utc::now();
    let resume_deadline = observed_at + chrono::Duration::minutes(30);
    let engine_job_id_value = if case_uses_engine_job(case) {
        Some(engine_job_id)
    } else {
        None
    };
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = $2, publication_disposition = $3, engine_ack_state = $4,
             dispatch_intent_state = $5, engine_job_id = $6,
             error_code = $7, retryable = $8, resumable = $9,
             resume_checkpoint = $10, resume_status_observed_at = $11,
             resume_deadline = $12, updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .bind(case.status.as_str())
    .bind(case.publication_disposition.as_str())
    .bind(case.engine_ack_state.as_str())
    .bind(case_dispatch_intent(case).as_str())
    .bind(engine_job_id_value)
    .bind(case_error_code(case).map(AlgoliaImportErrorCode::as_str))
    .bind(case_retryable(case))
    .bind(case.resumable)
    .bind(case.resumable.then_some("checkpoint-data"))
    .bind(case.resumable.then_some(observed_at))
    .bind(case.resumable.then_some(resume_deadline))
    .execute(pool)
    .await
    .unwrap_or_else(|error| panic!("force reservation lifetime case {}: {error}", case.label));
}

fn expected_reservation_case_labels() -> BTreeSet<String> {
    let mut labels = BTreeSet::new();
    for &status in algolia_import_statuses() {
        for &publication_disposition in algolia_import_publication_dispositions() {
            for &engine_ack_state in algolia_import_engine_ack_states() {
                for resumable in [false, true] {
                    if schema_valid_reservation_quad(
                        status,
                        publication_disposition,
                        engine_ack_state,
                        resumable,
                    ) {
                        labels.insert(reservation_case_label(
                            status,
                            publication_disposition,
                            engine_ack_state,
                            resumable,
                        ));
                    }
                }
            }
        }
    }
    labels
}

fn reservation_expectation(
    status: AlgoliaImportJobStatus,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
    resumable: bool,
) -> ReservationExpectation {
    let finally_terminal = status.is_finally_terminal(resumable, publication_disposition);
    if finally_terminal
        && publication_disposition != AlgoliaImportPublicationDisposition::Unknown
        && engine_ack_is_accepted(engine_ack_state)
    {
        ReservationExpectation::Release
    } else {
        ReservationExpectation::Retain
    }
}

fn schema_valid_reservation_quad(
    status: AlgoliaImportJobStatus,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
    resumable: bool,
) -> bool {
    if resumable {
        return matches!(
            status,
            AlgoliaImportJobStatus::Failed | AlgoliaImportJobStatus::Interrupted
        ) && publication_disposition == AlgoliaImportPublicationDisposition::Unchanged
            && engine_ack_state == AlgoliaImportEngineAckState::Pending;
    }
    if status == AlgoliaImportJobStatus::Cancelled
        && publication_disposition != AlgoliaImportPublicationDisposition::Unchanged
    {
        return false;
    }
    if status == AlgoliaImportJobStatus::Interrupted {
        return interrupted_ack_state_is_schema_valid(publication_disposition, engine_ack_state);
    }
    match engine_ack_state {
        AlgoliaImportEngineAckState::Pending => true,
        AlgoliaImportEngineAckState::NotApplicable => {
            status == AlgoliaImportJobStatus::Failed
                && publication_disposition == AlgoliaImportPublicationDisposition::NotStarted
        }
        AlgoliaImportEngineAckState::SealAcknowledged => false,
        AlgoliaImportEngineAckState::OutboxPending | AlgoliaImportEngineAckState::Acknowledged => {
            matches!(
                status,
                AlgoliaImportJobStatus::Cancelled
                    | AlgoliaImportJobStatus::Completed
                    | AlgoliaImportJobStatus::CompletedWithWarnings
                    | AlgoliaImportJobStatus::Failed
            )
        }
    }
}

fn interrupted_ack_state_is_schema_valid(
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
) -> bool {
    matches!(
        (publication_disposition, engine_ack_state),
        (
            AlgoliaImportPublicationDisposition::NotStarted,
            AlgoliaImportEngineAckState::SealAcknowledged
        ) | (
            AlgoliaImportPublicationDisposition::Unchanged,
            AlgoliaImportEngineAckState::Pending
                | AlgoliaImportEngineAckState::OutboxPending
                | AlgoliaImportEngineAckState::Acknowledged
        )
    )
}

fn engine_ack_is_accepted(engine_ack_state: AlgoliaImportEngineAckState) -> bool {
    matches!(
        engine_ack_state,
        AlgoliaImportEngineAckState::NotApplicable
            | AlgoliaImportEngineAckState::SealAcknowledged
            | AlgoliaImportEngineAckState::Acknowledged
    )
}

fn case_dispatch_intent(case: &ReservationLifetimeCase) -> AlgoliaImportDispatchIntentState {
    if case.resumable {
        return AlgoliaImportDispatchIntentState::Committed;
    }
    match case.engine_ack_state {
        AlgoliaImportEngineAckState::Pending if !case_requires_terminal_engine(case) => {
            AlgoliaImportDispatchIntentState::Absent
        }
        AlgoliaImportEngineAckState::NotApplicable => AlgoliaImportDispatchIntentState::Absent,
        _ => AlgoliaImportDispatchIntentState::Committed,
    }
}

fn case_uses_engine_job(case: &ReservationLifetimeCase) -> bool {
    case_dispatch_intent(case) != AlgoliaImportDispatchIntentState::Absent
        && case.engine_ack_state != AlgoliaImportEngineAckState::SealAcknowledged
}

fn case_requires_terminal_engine(case: &ReservationLifetimeCase) -> bool {
    case.status
        .is_finally_terminal(case.resumable, case.publication_disposition)
        && matches!(
            case.engine_ack_state,
            AlgoliaImportEngineAckState::Pending
                | AlgoliaImportEngineAckState::OutboxPending
                | AlgoliaImportEngineAckState::Acknowledged
        )
}

fn case_error_code(case: &ReservationLifetimeCase) -> Option<AlgoliaImportErrorCode> {
    match case.status {
        AlgoliaImportJobStatus::Interrupted => Some(AlgoliaImportErrorCode::Interrupted),
        AlgoliaImportJobStatus::Failed => Some(AlgoliaImportErrorCode::Internal),
        _ => None,
    }
}

fn case_retryable(case: &ReservationLifetimeCase) -> bool {
    case.resumable
}

fn reservation_case_label(
    status: AlgoliaImportJobStatus,
    publication_disposition: AlgoliaImportPublicationDisposition,
    engine_ack_state: AlgoliaImportEngineAckState,
    resumable: bool,
) -> String {
    format!(
        "{}__{}__{}__resumable_{}",
        status.as_str(),
        publication_disposition.as_str(),
        engine_ack_state.as_str(),
        resumable
    )
}

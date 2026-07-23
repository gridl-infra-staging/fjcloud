use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use tokio::sync::OwnedMutexGuard;
use uuid::Uuid;

use crate::models::algolia_import_job::AlgoliaImportDestinationKind;
use crate::models::{
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, NewAlgoliaImportJob,
    NewAlgoliaReplaceImportJob,
};
use crate::repos::RepoError;

/// Credential-free identity of a dispatch request, used to short-circuit an
/// exact idempotent replay from persisted state before any credential-bearing
/// source inspection or fresh placement admission runs. It carries only the
/// non-secret request fields (never the temporary key) that a retained job must
/// match for a replay to be exact; a mismatch is inconclusive and falls through
/// to the full transactional admission path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportDispatchReplayIdentity {
    pub app_id: String,
    pub source_name: String,
    pub kind: AlgoliaImportDestinationKind,
    pub logical_target: String,
    pub region: String,
}

impl AlgoliaImportDispatchReplayIdentity {
    /// True when a retained job is the exact same logical request: same app id,
    /// source index, destination kind, logical target, and region.
    pub fn matches(&self, job: &AlgoliaImportJob) -> bool {
        self.app_id == job.algolia_app_id
            && self.source_name == job.source_name
            && self.kind == job.destination_kind
            && self.logical_target == job.logical_target
            && self.region == job.destination_region
    }
}

/// Default retained-list page size when the client requests none.
pub const ALGOLIA_IMPORT_JOB_LIST_DEFAULT_LIMIT: i64 = 50;
/// Hard cap on the retained-list page size.
pub const ALGOLIA_IMPORT_JOB_LIST_MAX_LIMIT: i64 = 200;

/// Clamp a client-requested page size into `[1, MAX]`, defaulting to
/// [`ALGOLIA_IMPORT_JOB_LIST_DEFAULT_LIMIT`] when absent or non-positive. Single
/// source of the retained-list bounds for both the repository and the route.
pub fn clamp_algolia_import_job_list_limit(requested: Option<i64>) -> i64 {
    match requested {
        Some(value) if value > 0 => value.min(ALGOLIA_IMPORT_JOB_LIST_MAX_LIMIT),
        _ => ALGOLIA_IMPORT_JOB_LIST_DEFAULT_LIMIT,
    }
}

/// Exclusive keyset boundary for retained-list pagination: the `(created_at,
/// id)` of the last row on the previous page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlgoliaImportJobListCursor {
    pub created_at: DateTime<Utc>,
    pub id: Uuid,
}

/// One keyset page of retained jobs together with the repository's own answer
/// to "is there another page". `has_more` is decided by a `limit + 1` lookahead
/// inside the query, so a cursor is minted only when a further row genuinely
/// exists — never for an exact-full final page. `jobs` is always clamped to the
/// requested public limit.
#[derive(Debug, Clone)]
pub struct AlgoliaImportJobListPage {
    pub jobs: Vec<AlgoliaImportJob>,
    pub has_more: bool,
}

/// Whether a lifecycle transition entrypoint applied a fresh transition or
/// merely replayed an already-applied one. HTTP callers map `Accepted` to `202`
/// and `Replayed` to `200`; this is the single source of that distinction,
/// because dispatch presence cannot carry it (a newly cancelled queued job has
/// no engine dispatch yet is not a replay).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlgoliaImportTransitionDisposition {
    Accepted,
    Replayed,
}

/// Typed refusal boundary for the customer-scoped lifecycle entrypoints. The
/// route maps each arm to a stable status/code without inspecting job state or
/// parsing `RepoError` strings: `NotFound` -> `404` (missing and foreign are
/// indistinguishable), `Refused(code)` -> the canonical migration code's status,
/// `Repository` -> the shared repository error transport.
#[derive(Debug)]
pub enum AlgoliaLifecycleError {
    NotFound,
    Refused(AlgoliaImportErrorCode),
    Repository(RepoError),
}

impl From<RepoError> for AlgoliaLifecycleError {
    fn from(error: RepoError) -> Self {
        match error {
            RepoError::NotFound => AlgoliaLifecycleError::NotFound,
            other => AlgoliaLifecycleError::Repository(other),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportCancelDispatch {
    pub engine_job_id: Uuid,
}

#[derive(Debug, Clone)]
pub struct AlgoliaImportCancelOutcome {
    pub job: AlgoliaImportJob,
    pub dispatch: Option<AlgoliaImportCancelDispatch>,
    pub disposition: AlgoliaImportTransitionDisposition,
}

impl AlgoliaImportCancelOutcome {
    pub fn should_dispatch(&self) -> bool {
        self.dispatch.is_some()
    }

    pub fn was_accepted(&self) -> bool {
        self.disposition == AlgoliaImportTransitionDisposition::Accepted
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportResumeDispatch {
    pub job_id: Uuid,
    pub generation: i64,
    pub expected_attempt: i64,
}

#[derive(Debug, Clone)]
pub struct AlgoliaImportResumeOutcome {
    pub job: AlgoliaImportJob,
    pub generation: i64,
    pub expected_attempt: i64,
    pub dispatch: Option<AlgoliaImportResumeDispatch>,
    pub disposition: AlgoliaImportTransitionDisposition,
}

impl AlgoliaImportResumeOutcome {
    pub fn should_dispatch(&self) -> bool {
        self.dispatch.is_some()
    }

    pub fn was_accepted(&self) -> bool {
        self.disposition == AlgoliaImportTransitionDisposition::Accepted
    }
}

#[derive(Debug, Clone)]
pub enum AlgoliaImportDispatchAdmission {
    Create(NewAlgoliaImportJob),
    Replace(NewAlgoliaReplaceImportJob),
}

#[derive(Debug, Clone)]
pub enum AlgoliaImportDispatchAdmissionOutcome {
    New(AlgoliaImportJob),
    Replay(AlgoliaImportJob),
}

impl AlgoliaImportDispatchAdmissionOutcome {
    pub fn job(&self) -> &AlgoliaImportJob {
        match self {
            Self::New(job) | Self::Replay(job) => job,
        }
    }

    pub fn into_job(self) -> AlgoliaImportJob {
        match self {
            Self::New(job) | Self::Replay(job) => job,
        }
    }
}

pub struct AlgoliaImportDispatchGuard {
    pub(crate) tx: Transaction<'static, Postgres>,
    pub job_id: Uuid,
    pub cloud_job_id: Uuid,
    pub lifecycle_generation: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportResumeDeadlineClaim {
    pub job_id: Uuid,
    pub cloud_job_id: Uuid,
    pub engine_job_id: Uuid,
    pub resume_intent_generation: i64,
    pub resume_count: i64,
    pub resume_deadline: DateTime<Utc>,
    pub worker_claimed_at: DateTime<Utc>,
    pub worker_lease_expires_at: DateTime<Utc>,
}

/// Exact identity of one post-dispatch reconciliation lease. The pair of
/// timestamps is written atomically by the claim query and acts as the lease
/// token; a takeover necessarily replaces both values, fencing the old worker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlgoliaImportReconciliationLease {
    pub job_id: Uuid,
    pub lifecycle_generation: i64,
    pub claimed_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// Credential-free job snapshot returned by the bounded reconciliation claim.
#[derive(Debug, Clone)]
pub struct AlgoliaImportReconciliationClaim {
    pub job: AlgoliaImportJob,
    pub lease: AlgoliaImportReconciliationLease,
}

/// Result of a fenced observation write. Losing the lease is an expected race,
/// not a repository failure, and never mutates the retained row.
#[derive(Debug, Clone)]
pub enum AlgoliaImportReconciliationWriteOutcome {
    Applied { unavailable_state_changed: bool },
    LeaseLost,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportEngineAckOutcome {
    pub id: Uuid,
    pub engine_ack_state: crate::models::AlgoliaImportEngineAckState,
}

impl From<AlgoliaImportJob> for AlgoliaImportEngineAckOutcome {
    fn from(job: AlgoliaImportJob) -> Self {
        Self {
            id: job.id,
            engine_ack_state: job.engine_ack_state,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogLifecycleTargetIdentity {
    pub deployment_id: Uuid,
    pub vm_id: Option<Uuid>,
    pub tier: String,
    pub cold_snapshot_id: Option<Uuid>,
    pub service_type: String,
}

pub struct CatalogLifecycleTargetGuard {
    pub(crate) state: CatalogLifecycleTargetGuardState,
    pub customer_id: Uuid,
    pub logical_target: String,
    pub lifecycle_generation: i64,
}

pub(crate) enum CatalogLifecycleTargetGuardState {
    Fenced { tx: Transaction<'static, Postgres> },
    InProcess { _guard: OwnedMutexGuard<()> },
}

/// Credential-free snapshot of a replace target's current eligibility.
///
/// Produced by re-authenticating an owned replace target and reading the
/// customer's active lifecycle generation, without holding locks or mutating
/// any row. The migration eligibility route binds these fields into a signed
/// destination envelope so create admission can later detect a routing or
/// generation change before dispatch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DestinationEligibilitySnapshot {
    pub lifecycle_generation: i64,
    pub region: String,
    pub routing_identity: String,
}

/// Typed refusal from the replace-target eligibility snapshot. Keeping this
/// typed (rather than a stringly `RepoError`) lets the migration route map each
/// outcome to a stable code and status in exactly one place, without parsing
/// error strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DestinationEligibilityError {
    /// No owned replace target with this logical name exists for the customer.
    TargetNotFound,
    /// The customer's active lifecycle generation could not be pinned (the
    /// customer is absent or not in an active lifecycle state).
    LifecycleUnavailable,
    /// The target exists but fails the shared replace-target facts contract.
    Ineligible(AlgoliaImportErrorCode),
    /// Unexpected persistence failure while reading the snapshot.
    Internal(String),
}

/// Public job-admission failures preserve their stable migration code while
/// unexpected persistence failures retain the repository error that produced
/// them. HTTP handlers can therefore translate closed domain refusals without
/// inspecting repository error text.
#[derive(Debug, thiserror::Error)]
pub enum AlgoliaImportJobAdmissionError {
    #[error("Algolia import admission refused: {}", .0.as_str())]
    Refused(AlgoliaImportErrorCode),
    #[error(transparent)]
    Repository(#[from] RepoError),
}

impl From<AlgoliaImportJobAdmissionError> for RepoError {
    fn from(error: AlgoliaImportJobAdmissionError) -> Self {
        match error {
            AlgoliaImportJobAdmissionError::Refused(code) => {
                RepoError::Conflict(code.as_str().into())
            }
            AlgoliaImportJobAdmissionError::Repository(error) => error,
        }
    }
}

#[async_trait]
pub trait AlgoliaImportJobRepo {
    async fn create(
        &self,
        job: NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>;
    async fn create_replace(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>;
    async fn admit_dispatch(
        &self,
        admission: AlgoliaImportDispatchAdmission,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError>;
    /// Return a retained job as an exact idempotent replay under a locked active
    /// customer generation, without any credential-bearing work. Errors
    /// (mapped to `DestinationChanged`) when the customer is not active so a
    /// replay against a deleted customer is refused before source inspection.
    /// Returns `Ok(None)` when there is no retained job, or when the retained
    /// job's generation or identity does not match — those inconclusive cases
    /// fall through to the full transactional admission path.
    async fn find_active_dispatch_replay(
        &self,
        customer_id: Uuid,
        idempotency_key: &str,
        identity: &AlgoliaImportDispatchReplayIdentity,
    ) -> Result<Option<AlgoliaImportJob>, AlgoliaImportJobAdmissionError>;
    async fn get(&self, id: Uuid) -> Result<Option<AlgoliaImportJob>, RepoError>;
    /// Tenant-scoped read: returns the job only when it is owned by
    /// `customer_id` and not erased, so HTTP authorization is enforced in SQL
    /// rather than by fetch-then-compare.
    async fn get_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AlgoliaImportJob>, RepoError>;
    /// Tenant-scoped keyset page over the customer's non-erased jobs, newest
    /// `created_at` first with `id` as the deterministic tie-breaker. `after`
    /// is the exclusive boundary from the previous page; `limit` is the
    /// already-clamped page size (see [`clamp_algolia_import_job_list_limit`]).
    /// The returned [`AlgoliaImportJobListPage`] carries at most `limit` rows
    /// plus a `has_more` flag derived from a lookahead, so callers never mint a
    /// continuation cursor for an exact-full final page.
    async fn list_for_customer(
        &self,
        customer_id: Uuid,
        after: Option<AlgoliaImportJobListCursor>,
        limit: i64,
    ) -> Result<AlgoliaImportJobListPage, RepoError>;
    /// Credential-free eligibility snapshot for a replace destination. Reuses
    /// the locked customer-generation read and the authenticated replace-target
    /// query without persisting anything, so the migration route can pin the
    /// current routing generation and identity before signing an envelope.
    async fn snapshot_replace_target_eligibility(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<DestinationEligibilitySnapshot, DestinationEligibilityError>;
    async fn find_by_idempotency_key(
        &self,
        customer_id: Uuid,
        key: &str,
    ) -> Result<Option<AlgoliaImportJob>, RepoError>;
    async fn update_persisted_state(
        &self,
        id: Uuid,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn record_dispatch_intent_committed(
        &self,
        id: Uuid,
        engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn acquire_dispatch_guard(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportDispatchGuard, RepoError>;
    async fn release_dispatch_guard(
        &self,
        guard: AlgoliaImportDispatchGuard,
    ) -> Result<(), RepoError>;
    async fn record_no_dispatch_failure(
        &self,
        id: Uuid,
        error_code: AlgoliaImportErrorCode,
        error_message: Option<&str>,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn request_cancel(&self, id: Uuid) -> Result<AlgoliaImportCancelOutcome, RepoError>;
    async fn prepare_resume(&self, id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError>;
    /// Customer-scoped cancel: a thin locked adapter over the same transition as
    /// [`request_cancel`], enforcing ownership atomically on the locked row. A
    /// missing job and a job owned by another customer are both `NotFound`, so
    /// ownership is not observable. Cancel is available regardless of exposure
    /// or readiness state.
    async fn request_cancel_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportCancelOutcome, AlgoliaLifecycleError>;
    /// Customer-scoped resume: a thin locked adapter over the same transition as
    /// [`prepare_resume`], enforcing ownership atomically on the locked row and
    /// rejecting an elapsed resume deadline (`resume_deadline <= now`) while the
    /// row is held. `now` is injected so deadline behaviour is deterministically
    /// testable.
    async fn prepare_resume_for_customer(
        &self,
        customer_id: Uuid,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<AlgoliaImportResumeOutcome, AlgoliaLifecycleError>;
    async fn record_resume_accepted(
        &self,
        id: Uuid,
        generation: i64,
        summary: crate::models::AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn mark_engine_acknowledged(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportEngineAckOutcome, RepoError>;
    async fn gc_retained_terminal_history(
        &self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<Uuid>, RepoError>;
    /// Claim a bounded batch of active-generation, engine-linked jobs for
    /// credential-free status polling. Rows with a live worker lease are
    /// skipped and concurrent replicas use `SKIP LOCKED` rather than waiting.
    async fn claim_reconciliation_jobs(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportReconciliationClaim>, RepoError>;
    /// Persist a sanitized monotonic observation only while `lease` still owns
    /// the active customer generation, then release that worker lease.
    async fn record_reconciliation_observation(
        &self,
        lease: &AlgoliaImportReconciliationLease,
        observed_at: DateTime<Utc>,
        state: AlgoliaImportJobState,
    ) -> Result<AlgoliaImportReconciliationWriteOutcome, RepoError>;
    async fn claim_elapsed_resume_deadlines(
        &self,
        now: DateTime<Utc>,
        lease_expires_at: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<AlgoliaImportResumeDeadlineClaim>, RepoError>;
    async fn begin_lifecycle_target_guard(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<CatalogLifecycleTargetGuard, RepoError>;
    async fn commit_lifecycle_target_guard(
        &self,
        guard: CatalogLifecycleTargetGuard,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), RepoError>;
}

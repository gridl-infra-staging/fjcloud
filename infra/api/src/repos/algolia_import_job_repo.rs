use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use crate::models::{
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobState, NewAlgoliaImportJob,
    NewAlgoliaReplaceImportJob,
};
use crate::repos::RepoError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportCancelDispatch {
    pub job_id: Uuid,
}

#[derive(Debug, Clone)]
pub struct AlgoliaImportCancelOutcome {
    pub job: AlgoliaImportJob,
    pub dispatch: Option<AlgoliaImportCancelDispatch>,
}

impl AlgoliaImportCancelOutcome {
    pub fn should_dispatch(&self) -> bool {
        self.dispatch.is_some()
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
}

impl AlgoliaImportResumeOutcome {
    pub fn should_dispatch(&self) -> bool {
        self.dispatch.is_some()
    }
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogLifecycleTargetIdentity {
    pub deployment_id: Uuid,
    pub vm_id: Option<Uuid>,
    pub tier: String,
    pub cold_snapshot_id: Option<Uuid>,
    pub service_type: String,
}

pub struct CatalogLifecycleTargetGuard {
    pub(crate) tx: Transaction<'static, Postgres>,
    pub customer_id: Uuid,
    pub logical_target: String,
    pub lifecycle_generation: i64,
}

#[async_trait]
pub trait AlgoliaImportJobRepo {
    async fn create(&self, job: NewAlgoliaImportJob) -> Result<AlgoliaImportJob, RepoError>;
    async fn create_replace(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn get(&self, id: Uuid) -> Result<Option<AlgoliaImportJob>, RepoError>;
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
    async fn record_no_dispatch_failure(
        &self,
        id: Uuid,
        error_code: AlgoliaImportErrorCode,
        error_message: Option<&str>,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn request_cancel(&self, id: Uuid) -> Result<AlgoliaImportCancelOutcome, RepoError>;
    async fn prepare_resume(&self, id: Uuid) -> Result<AlgoliaImportResumeOutcome, RepoError>;
    async fn record_resume_accepted(
        &self,
        id: Uuid,
        generation: i64,
        summary: crate::models::AlgoliaImportSummary,
    ) -> Result<AlgoliaImportJob, RepoError>;
    async fn mark_engine_acknowledged(&self, id: Uuid) -> Result<AlgoliaImportJob, RepoError>;
    async fn gc_retained_terminal_history(
        &self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<Uuid>, RepoError>;
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

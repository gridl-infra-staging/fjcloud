use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::PgAlgoliaImportJobRepo;
use crate::models::algolia_import_job::{
    AlgoliaImportJob, AlgoliaImportJobRow, AlgoliaImportJobState, AlgoliaImportSummary,
    AlgoliaReplaceTargetFacts, AuthenticatedAlgoliaReplacementTarget, EngineResumeMirror,
    NewAlgoliaImportJob,
};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportJobAdmissionError, AlgoliaImportResumeDeadlineClaim,
    CatalogLifecycleTargetIdentity,
};
use crate::repos::error::RepoError;

const OWNED_FENCED_JOB_SQL: &str = "SELECT * FROM algolia_import_jobs
             WHERE id = $1 AND customer_id = $2 AND erased_at IS NULL FOR UPDATE";
const OWNED_JOB_LOGICAL_TARGET_SQL: &str = "SELECT logical_target
             FROM algolia_import_jobs
             WHERE id = $1 AND customer_id = $2 AND erased_at IS NULL";

#[derive(sqlx::FromRow)]
pub(super) struct AlgoliaImportResumeDeadlineClaimRow {
    pub(super) job_id: Uuid,
    pub(super) cloud_job_id: Uuid,
    pub(super) engine_job_id: Uuid,
    pub(super) resume_intent_generation: i64,
    pub(super) resume_count: i64,
    pub(super) resume_deadline: DateTime<Utc>,
    pub(super) worker_claimed_at: DateTime<Utc>,
    pub(super) worker_lease_expires_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
pub(super) struct AuthenticatedReplaceTargetRow {
    logical_target: String,
    region: String,
    deployment_id: Uuid,
    vm_id: Uuid,
    provider: String,
    vm_status: String,
    deployment_status: String,
    health_status: String,
    service_type: String,
    has_active_lifecycle_operation: bool,
    pub(super) has_active_import_lease: bool,
    has_flapjack_url: bool,
}

pub(super) struct ReservationPlan {
    pub(super) lifecycle_generation: i64,
    pub(super) reserved_index_count: i64,
    pub(super) reserved_customer_storage_bytes: i64,
    pub(super) reserved_node_transient_bytes: i64,
}

#[derive(sqlx::FromRow)]
pub(super) struct ActiveReservationRow {
    pub(super) reserved_index_count: i64,
    pub(super) reserved_customer_storage_bytes: i64,
    pub(super) reserved_node_transient_bytes: i64,
}

#[derive(sqlx::FromRow)]
pub(super) struct VmCapacityRow {
    pub(super) capacity: Value,
    pub(super) current_load: Value,
}

#[derive(sqlx::FromRow)]
struct CatalogLifecycleTargetIdentityRow {
    deployment_id: Uuid,
    vm_id: Option<Uuid>,
    tier: String,
    cold_snapshot_id: Option<Uuid>,
    service_type: String,
}

impl AuthenticatedReplaceTargetRow {
    fn facts(&self) -> AlgoliaReplaceTargetFacts {
        AlgoliaReplaceTargetFacts {
            provider: self.provider.clone(),
            vm_status: self.vm_status.clone(),
            deployment_status: self.deployment_status.clone(),
            health_status: self.health_status.clone(),
            service_type: self.service_type.clone(),
            has_active_lifecycle_operation: self.has_active_lifecycle_operation,
            has_active_import_lease: self.has_active_import_lease,
            has_flapjack_url: self.has_flapjack_url,
        }
    }

    pub(super) fn validate(&self) -> Result<(), AlgoliaImportJobAdmissionError> {
        self.facts()
            .validate()
            .map_err(AlgoliaImportJobAdmissionError::Refused)
    }

    /// Typed variant of [`validate`], returning the stable ineligibility code
    /// directly so callers that need a code (rather than a `RepoError` string)
    /// do not have to round-trip through `as_str`.
    pub(super) fn eligibility_code(&self) -> Result<(), crate::models::AlgoliaImportErrorCode> {
        self.facts().validate()
    }

    pub(super) fn destination(&self, customer_id: Uuid) -> AuthenticatedAlgoliaReplacementTarget {
        AuthenticatedAlgoliaReplacementTarget::from_existing_index(
            customer_id,
            self.logical_target.clone(),
            self.region.clone(),
            self.deployment_id,
            self.vm_id,
        )
    }
}

impl From<AlgoliaImportResumeDeadlineClaimRow> for AlgoliaImportResumeDeadlineClaim {
    fn from(row: AlgoliaImportResumeDeadlineClaimRow) -> Self {
        Self {
            job_id: row.job_id,
            cloud_job_id: row.cloud_job_id,
            engine_job_id: row.engine_job_id,
            resume_intent_generation: row.resume_intent_generation,
            resume_count: row.resume_count,
            resume_deadline: row.resume_deadline,
            worker_claimed_at: row.worker_claimed_at,
            worker_lease_expires_at: row.worker_lease_expires_at,
        }
    }
}

impl From<CatalogLifecycleTargetIdentityRow> for CatalogLifecycleTargetIdentity {
    fn from(row: CatalogLifecycleTargetIdentityRow) -> Self {
        Self {
            deployment_id: row.deployment_id,
            vm_id: row.vm_id,
            tier: row.tier,
            cold_snapshot_id: row.cold_snapshot_id,
            service_type: row.service_type,
        }
    }
}

impl PgAlgoliaImportJobRepo {
    pub(super) async fn authenticate_replace_target(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<AuthenticatedReplaceTargetRow, RepoError> {
        self.authenticate_replace_target_excluding_import(tx, customer_id, logical_target, None)
            .await
    }

    pub(super) async fn validate_resume_replace_target_ready(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        current: &AlgoliaImportJob,
    ) -> Result<(), AlgoliaImportJobAdmissionError> {
        let target = self
            .authenticate_replace_target_excluding_import(
                tx,
                current.customer_id,
                &current.logical_target,
                Some(current.id),
            )
            .await
            .map_err(|_| {
                AlgoliaImportJobAdmissionError::Refused(
                    crate::models::AlgoliaImportErrorCode::BackendUnavailable,
                )
            })?;
        target.eligibility_code().map_err(|_| {
            AlgoliaImportJobAdmissionError::Refused(
                crate::models::AlgoliaImportErrorCode::BackendUnavailable,
            )
        })
    }

    async fn authenticate_replace_target_excluding_import(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        logical_target: &str,
        excluded_import_id: Option<Uuid>,
    ) -> Result<AuthenticatedReplaceTargetRow, RepoError> {
        sqlx::query_as::<_, AuthenticatedReplaceTargetRow>(&format!(
            "SELECT ct.tenant_id AS logical_target, cd.region, ct.deployment_id,
                    ct.vm_id, vm.provider, vm.status AS vm_status,
                    CASE WHEN cd.status = 'running' THEN 'active' ELSE cd.status END
                        AS deployment_status,
                    cd.health_status, ct.service_type,
                    (ct.tier IN ('migrating', 'cold', 'restoring', 'provisioning', 'deleting')
                     OR EXISTS (
                        SELECT 1 FROM index_migrations migration
                        WHERE migration.customer_id = ct.customer_id
                          AND migration.index_name = ct.tenant_id
                          AND migration.status NOT IN ('completed', 'failed')
                    )) AS has_active_lifecycle_operation,
                    EXISTS (
                        SELECT 1 FROM algolia_import_jobs active_job
                        WHERE active_job.customer_id = ct.customer_id
                          AND active_job.logical_target = ct.tenant_id
                          AND ($3::uuid IS NULL OR active_job.id <> $3)
                          AND ({})
                    ) AS has_active_import_lease,
                    (NULLIF(vm.flapjack_url, '') IS NOT NULL
                     AND NULLIF(cd.flapjack_url, '') IS NOT NULL) AS has_flapjack_url
             FROM customer_tenants ct
             JOIN customer_deployments cd ON cd.id = ct.deployment_id
             JOIN vm_inventory vm ON vm.id = ct.vm_id
             WHERE ct.customer_id = $1 AND ct.tenant_id = $2
               AND cd.status != 'terminated'
             FOR UPDATE OF ct, cd, vm",
            active_reservation_predicate()
        ))
        .bind(customer_id)
        .bind(logical_target)
        .bind(excluded_import_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)
    }

    /// Read-only replace-target eligibility snapshot. Opens a transaction so it
    /// can reuse the same `FOR UPDATE` customer-generation and replace-target
    /// queries create admission owns, then rolls back — eligibility must never
    /// hold a lock or mutate a row. Returns the current generation plus the
    /// authoritative destination region and derived routing identity.
    pub(super) async fn snapshot_replace_target_eligibility_inner(
        &self,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<
        crate::repos::algolia_import_job_repo::DestinationEligibilitySnapshot,
        crate::repos::algolia_import_job_repo::DestinationEligibilityError,
    > {
        use crate::repos::algolia_import_job_repo::{
            DestinationEligibilityError, DestinationEligibilitySnapshot,
        };
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|error| DestinationEligibilityError::Internal(error.to_string()))?;
        let lifecycle_generation = match self
            .lock_active_customer_generation(&mut tx, customer_id)
            .await
        {
            Ok(generation) => generation,
            Err(RepoError::NotFound) | Err(RepoError::Conflict(_)) => {
                return Err(DestinationEligibilityError::LifecycleUnavailable)
            }
            Err(RepoError::Other(message)) => {
                return Err(DestinationEligibilityError::Internal(message))
            }
        };
        let target = match self
            .authenticate_replace_target(&mut tx, customer_id, logical_target)
            .await
        {
            Ok(target) => target,
            Err(RepoError::NotFound) => return Err(DestinationEligibilityError::TargetNotFound),
            Err(RepoError::Conflict(message)) => {
                return Err(DestinationEligibilityError::Internal(message))
            }
            Err(RepoError::Other(message)) => {
                return Err(DestinationEligibilityError::Internal(message))
            }
        };
        target
            .eligibility_code()
            .map_err(DestinationEligibilityError::Ineligible)?;
        let destination = target.destination(customer_id);
        // Eligibility is a read: release the row locks without persisting.
        let _ = tx.rollback().await;
        Ok(DestinationEligibilitySnapshot {
            lifecycle_generation,
            region: destination.region().to_string(),
            routing_identity: destination.routing_identity().to_string(),
        })
    }

    pub(super) async fn acquire_catalog_target_advisory_lock(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<(), AlgoliaImportJobAdmissionError> {
        let lock_name = catalog_lifecycle_target_lock_name(customer_id, logical_target);
        let acquired: bool =
            sqlx::query_scalar("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))")
                .bind(lock_name)
                .fetch_one(&mut **tx)
                .await
                .map_err(repo_error)?;
        if acquired {
            Ok(())
        } else {
            Err(AlgoliaImportJobAdmissionError::Refused(
                crate::models::AlgoliaImportErrorCode::DestinationConflict,
            ))
        }
    }

    pub(super) async fn reject_active_target_reservation(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        logical_target: &str,
    ) -> Result<(), AlgoliaImportJobAdmissionError> {
        let active_job_id = sqlx::query_scalar::<_, Uuid>(&format!(
            "SELECT id FROM algolia_import_jobs
             WHERE customer_id = $1 AND logical_target = $2 AND ({})
             FOR UPDATE
             LIMIT 1",
            active_reservation_predicate()
        ))
        .bind(customer_id)
        .bind(logical_target)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?;
        if active_job_id.is_some() {
            Err(AlgoliaImportJobAdmissionError::Refused(
                crate::models::AlgoliaImportErrorCode::DestinationConflict,
            ))
        } else {
            Ok(())
        }
    }

    pub(super) async fn assert_catalog_target_identity(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        logical_target: &str,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), AlgoliaImportJobAdmissionError> {
        let current_identity: Option<CatalogLifecycleTargetIdentity> =
            sqlx::query_as::<_, CatalogLifecycleTargetIdentityRow>(
                "SELECT deployment_id, vm_id, tier, cold_snapshot_id, service_type
             FROM customer_tenants
             WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(logical_target)
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)?
            .map(Into::into);
        match (current_identity, expected_identity) {
            (None, None) => Ok(()),
            (Some(current), Some(expected)) if &current == expected => Ok(()),
            _ => Err(AlgoliaImportJobAdmissionError::Refused(
                crate::models::AlgoliaImportErrorCode::DestinationChanged,
            )),
        }
    }

    pub(super) async fn lock_active_customer_generation(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<i64, RepoError> {
        let row = sqlx::query_as::<_, (i64, String)>(
            "SELECT lifecycle_generation, status \
             FROM customers \
             WHERE id = $1 \
             FOR UPDATE",
        )
        .bind(customer_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;
        if row.1 != "active" {
            return Err(RepoError::Conflict(
                "customer lifecycle is not active".into(),
            ));
        }
        Ok(row.0)
    }

    pub(super) async fn read_active_customer_generation(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
    ) -> Result<i64, RepoError> {
        let row = sqlx::query_as::<_, (i64, String)>(
            "SELECT lifecycle_generation, status
             FROM customers
             WHERE id = $1",
        )
        .bind(customer_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;
        if row.1 != "active" {
            return Err(RepoError::Conflict(
                "customer lifecycle is not active".into(),
            ));
        }
        Ok(row.0)
    }

    pub(super) async fn lock_generation_fenced_job(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let customer_id = sqlx::query_scalar::<_, Uuid>(
            "SELECT customer_id FROM algolia_import_jobs
             WHERE id = $1 AND erased_at IS NULL",
        )
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;
        let current_generation = self
            .lock_active_customer_generation(tx, customer_id)
            .await
            .map_err(|error| match error {
                RepoError::NotFound => {
                    RepoError::Conflict("customer lifecycle generation is stale".into())
                }
                other => other,
            })?;
        let job = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "SELECT * FROM algolia_import_jobs
             WHERE id = $1 AND erased_at IS NULL FOR UPDATE",
        )
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .map(AlgoliaImportJob::from)
        .ok_or(RepoError::NotFound)?;
        if job.lifecycle_generation != current_generation {
            return Err(RepoError::Conflict(
                "customer lifecycle generation is stale".into(),
            ));
        }
        Ok(job)
    }

    async fn lock_generation_fenced_job_for_customer(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let current_generation = self
            .lock_active_customer_generation(tx, customer_id)
            .await
            .map_err(|error| match error {
                RepoError::NotFound => {
                    RepoError::Conflict("customer lifecycle generation is stale".into())
                }
                other => other,
            })?;
        let job = sqlx::query_as::<_, AlgoliaImportJobRow>(OWNED_FENCED_JOB_SQL)
            .bind(id)
            .bind(customer_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)?
            .map(AlgoliaImportJob::from)
            .ok_or(RepoError::NotFound)?;
        if job.lifecycle_generation != current_generation {
            return Err(RepoError::Conflict(
                "customer lifecycle generation is stale".into(),
            ));
        }
        Ok(job)
    }

    pub(super) async fn lock_generation_fenced_target_job(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let job_key = sqlx::query_as::<_, (Uuid, String)>(
            "SELECT customer_id, logical_target
             FROM algolia_import_jobs
             WHERE id = $1 AND erased_at IS NULL",
        )
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)?
        .ok_or(RepoError::NotFound)?;
        self.acquire_catalog_target_advisory_lock(tx, job_key.0, &job_key.1)
            .await
            .map_err(RepoError::from)?;
        self.lock_generation_fenced_job(tx, id).await
    }

    pub(super) async fn lock_generation_fenced_target_job_for_customer(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let logical_target = sqlx::query_scalar::<_, String>(OWNED_JOB_LOGICAL_TARGET_SQL)
            .bind(id)
            .bind(customer_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(repo_error)?
            .ok_or(RepoError::NotFound)?;
        self.acquire_catalog_target_advisory_lock(tx, customer_id, &logical_target)
            .await
            .map_err(RepoError::from)?;
        self.lock_generation_fenced_job_for_customer(tx, customer_id, id)
            .await
    }
}

pub(super) fn catalog_lifecycle_target_lock_name(
    customer_id: Uuid,
    logical_target: &str,
) -> String {
    format!("catalog_lifecycle_target:{customer_id}:{logical_target}")
}
pub(super) fn repo_error(error: sqlx::Error) -> RepoError {
    RepoError::Other(error.to_string())
}

pub(super) fn customer_generation_admission_error(
    error: RepoError,
) -> AlgoliaImportJobAdmissionError {
    match error {
        RepoError::NotFound | RepoError::Conflict(_) => AlgoliaImportJobAdmissionError::Refused(
            crate::models::AlgoliaImportErrorCode::DestinationChanged,
        ),
        error => error.into(),
    }
}

pub(super) fn is_stale_customer_generation_error(error: &RepoError) -> bool {
    matches!(error, RepoError::Conflict(message) if message == "customer lifecycle is not active"
        || message == "customer lifecycle generation is stale")
}

pub(super) const DEFAULT_INDEX_LIMIT: i64 = 10;
pub(super) const DEFAULT_STORAGE_LIMIT_BYTES: i64 = 10_737_418_240;
pub(super) const DEFAULT_ACTIVE_CUSTOMER_IMPORT_JOB_LIMIT: i64 = 8;
pub(super) const DEFAULT_ACTIVE_CUSTOMER_IMPORT_BYTES_LIMIT: i64 = DEFAULT_STORAGE_LIMIT_BYTES;
pub(super) const DEFAULT_ACTIVE_NODE_IMPORT_JOB_LIMIT: i64 = 4;
pub(super) const DEFAULT_ACTIVE_NODE_TRANSIENT_BYTES_LIMIT: i64 = DEFAULT_STORAGE_LIMIT_BYTES;

pub(super) fn active_reservation_predicate() -> &'static str {
    "erased_at IS NULL AND (
       publication_disposition = 'unknown'
       OR resumable = TRUE
       OR status NOT IN ('completed', 'completed_with_warnings', 'cancelled', 'failed', 'interrupted')
       OR engine_ack_state NOT IN ('not_applicable', 'seal_acknowledged', 'acknowledged'))"
}

pub(super) fn state_from_job(job: &AlgoliaImportJob) -> Result<AlgoliaImportJobState, RepoError> {
    let resume_mirror = match (
        job.resume_checkpoint.clone(),
        job.resume_status_observed_at,
        job.resume_deadline,
    ) {
        (Some(checkpoint), Some(observed_at), Some(deadline)) => Some(
            EngineResumeMirror::new(checkpoint, observed_at, deadline)
                .map_err(|message| RepoError::Conflict(message.into()))?,
        ),
        _ => None,
    };
    Ok(AlgoliaImportJobState {
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
    })
}

pub(super) fn validate_transition(
    current: &AlgoliaImportJob,
    next: &AlgoliaImportJobState,
) -> Result<(), RepoError> {
    next.validate_transition_from(&state_from_job(current)?)
        .map_err(|message| {
            RepoError::Conflict(format!("invalid Algolia import job transition: {message}"))
        })
}

pub(super) fn merged_summary(
    current: &AlgoliaImportSummary,
    observed: AlgoliaImportSummary,
) -> AlgoliaImportSummary {
    AlgoliaImportSummary {
        documents_expected: current.documents_expected.max(observed.documents_expected),
        documents_imported: current.documents_imported.max(observed.documents_imported),
        documents_rejected: current.documents_rejected.max(observed.documents_rejected),
        settings_applied: current.settings_applied.max(observed.settings_applied),
        settings_unsupported: current
            .settings_unsupported
            .max(observed.settings_unsupported),
        synonyms_expected: current.synonyms_expected.max(observed.synonyms_expected),
        synonyms_imported: current.synonyms_imported.max(observed.synonyms_imported),
        synonyms_rejected: current.synonyms_rejected.max(observed.synonyms_rejected),
        rules_expected: current.rules_expected.max(observed.rules_expected),
        rules_imported: current.rules_imported.max(observed.rules_imported),
        rules_rejected: current.rules_rejected.max(observed.rules_rejected),
    }
}

pub(super) fn idempotent_create_replay_is_allowed(
    existing_customer_id: Uuid,
    existing_key: &str,
    existing_canonical_fingerprint: &str,
    requested: &NewAlgoliaImportJob,
) -> bool {
    existing_customer_id == requested.customer_id()
        && existing_key == requested.idempotency_key()
        && existing_canonical_fingerprint == requested.canonical_fingerprint()
}

pub(super) fn persisted_replay_is_allowed(
    existing: &AlgoliaImportJob,
    requested: &NewAlgoliaImportJob,
) -> bool {
    idempotent_create_replay_is_allowed(
        existing.customer_id,
        &existing.idempotency_key,
        &existing.canonical_fingerprint,
        requested,
    )
}

#[cfg(test)]
mod tests {
    use super::{OWNED_FENCED_JOB_SQL, OWNED_JOB_LOGICAL_TARGET_SQL};

    #[test]
    fn owned_fenced_job_sql_filters_by_customer_before_locking() {
        assert!(
            OWNED_FENCED_JOB_SQL.contains("customer_id = $2"),
            "customer-scoped fenced job lookup must filter by owner in SQL"
        );
    }

    #[test]
    fn owned_job_logical_target_sql_filters_by_customer_before_locking() {
        assert!(
            OWNED_JOB_LOGICAL_TARGET_SQL.contains("customer_id = $2"),
            "customer-scoped logical-target lookup must filter by owner in SQL"
        );
    }
}

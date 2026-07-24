use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{repo_error, PgAlgoliaImportJobRepo};
use crate::models::algolia_import_job::{
    AlgoliaImportDispatchIntentState, AlgoliaImportErrorCode, AlgoliaImportJob,
    AlgoliaImportJobRow, NewAlgoliaImportJob, NewAlgoliaReplaceImportJob,
};
use crate::repos::algolia_import_job_repo::{
    AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportDispatchGuard,
    AlgoliaImportJobAdmissionError,
};
use crate::repos::error::{is_unique_violation, RepoError};

enum DispatchAdmissionInsertError {
    Admission(AlgoliaImportJobAdmissionError),
    Repository(RepoError),
    Sql(sqlx::Error),
}

impl From<AlgoliaImportJobAdmissionError> for DispatchAdmissionInsertError {
    fn from(error: AlgoliaImportJobAdmissionError) -> Self {
        Self::Admission(error)
    }
}

impl From<RepoError> for DispatchAdmissionInsertError {
    fn from(error: RepoError) -> Self {
        Self::Repository(error)
    }
}

impl From<sqlx::Error> for DispatchAdmissionInsertError {
    fn from(error: sqlx::Error) -> Self {
        Self::Sql(error)
    }
}

impl From<DispatchAdmissionInsertError> for AlgoliaImportJobAdmissionError {
    fn from(error: DispatchAdmissionInsertError) -> Self {
        match error {
            DispatchAdmissionInsertError::Admission(error) => error,
            DispatchAdmissionInsertError::Repository(error) => error.into(),
            DispatchAdmissionInsertError::Sql(error) => repo_error(error).into(),
        }
    }
}

impl PgAlgoliaImportJobRepo {
    async fn resolve_dispatch_replay_after_unique_violation(
        &self,
        job: &NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        self.resolve_replay_after_unique_violation(job)
            .await
            .map(AlgoliaImportDispatchAdmissionOutcome::Replay)
    }

    async fn record_ambiguous_dispatch_admission(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        sqlx::query(
            "SELECT 1 FROM algolia_import_environment_contract
             WHERE singleton = TRUE
             FOR UPDATE",
        )
        .execute(&mut **tx)
        .await
        .map_err(repo_error)?;
        sqlx::query(
            "UPDATE algolia_import_environment_contract
             SET rollback_epoch='migration_aware_required'
             WHERE singleton = TRUE",
        )
        .execute(&mut **tx)
        .await
        .map_err(repo_error)?;
        sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET dispatch_intent_state='ambiguous', engine_job_id=NULL, updated_at=NOW()
             WHERE id=$1
               AND status='queued'
               AND dispatch_intent_state='absent'
               AND engine_job_id IS NULL
             RETURNING *",
        )
        .bind(id)
        .fetch_one(&mut **tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)
    }

    async fn insert_dispatch_admission(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        job: &NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportJob, DispatchAdmissionInsertError> {
        let reservation = self.build_reservation_plan(tx, job).await?;
        let job = self.insert_with_reservation(tx, job, &reservation).await?;
        self.record_ambiguous_dispatch_admission(tx, job.id)
            .await
            .map_err(Into::into)
    }

    pub(super) async fn admit_create_dispatch(
        &self,
        job: NewAlgoliaImportJob,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, job.customer_id(), job.tenant_id())
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        match self.resolve_active_customer_replay(&mut tx, &job).await {
            Ok(Some(existing)) => {
                tx.commit().await.map_err(repo_error)?;
                return Ok(AlgoliaImportDispatchAdmissionOutcome::Replay(existing));
            }
            Ok(None) => {}
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        }
        if let Err(error) = self
            .assert_catalog_target_identity(&mut tx, job.customer_id(), job.tenant_id(), None)
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        match self.insert_dispatch_admission(&mut tx, &job).await {
            Ok(job) => {
                tx.commit().await.map_err(repo_error)?;
                Ok(AlgoliaImportDispatchAdmissionOutcome::New(job))
            }
            Err(DispatchAdmissionInsertError::Sql(error)) if is_unique_violation(&error) => {
                tx.rollback().await.map_err(repo_error)?;
                self.resolve_dispatch_replay_after_unique_violation(&job)
                    .await
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                Err(error.into())
            }
        }
    }

    pub(super) async fn admit_replace_dispatch(
        &self,
        job: NewAlgoliaReplaceImportJob,
    ) -> Result<AlgoliaImportDispatchAdmissionOutcome, AlgoliaImportJobAdmissionError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        if let Err(error) = self
            .acquire_catalog_target_advisory_lock(&mut tx, job.customer_id(), job.logical_target())
            .await
        {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        let target = match self
            .authenticate_replace_target(&mut tx, job.customer_id(), job.logical_target())
            .await
        {
            Ok(target) => target,
            Err(RepoError::NotFound) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(AlgoliaImportJobAdmissionError::Refused(
                    AlgoliaImportErrorCode::DestinationChanged,
                ));
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error.into());
            }
        };
        let destination = target.destination(job.customer_id());
        let authenticated_job = job.into_authenticated_job(destination);
        match self
            .resolve_active_customer_replay(&mut tx, &authenticated_job)
            .await
        {
            Ok(Some(existing)) => {
                tx.commit().await.map_err(repo_error)?;
                return Ok(AlgoliaImportDispatchAdmissionOutcome::Replay(existing));
            }
            Ok(None) => {}
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        }
        target.validate()?;
        match self
            .insert_dispatch_admission(&mut tx, &authenticated_job)
            .await
        {
            Ok(job) => {
                tx.commit().await.map_err(repo_error)?;
                Ok(AlgoliaImportDispatchAdmissionOutcome::New(job))
            }
            Err(DispatchAdmissionInsertError::Sql(error)) if is_unique_violation(&error) => {
                tx.rollback().await.map_err(repo_error)?;
                self.resolve_dispatch_replay_after_unique_violation(&authenticated_job)
                    .await
            }
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                Err(error.into())
            }
        }
    }

    pub(super) async fn record_dispatch_intent_committed_inner(
        &self,
        id: Uuid,
        engine_job_id: Uuid,
    ) -> Result<AlgoliaImportJob, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = self.lock_generation_fenced_target_job(&mut tx, id).await?;

        sqlx::query(
            "SELECT 1 FROM algolia_import_environment_contract
             WHERE singleton = TRUE
             FOR UPDATE",
        )
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;

        if current.dispatch_intent_state == AlgoliaImportDispatchIntentState::Committed {
            if current.engine_job_id == Some(engine_job_id) {
                tx.commit().await.map_err(repo_error)?;
                return Ok(current);
            }
            return Err(RepoError::Conflict(
                "dispatch intent already committed for a different engine job".into(),
            ));
        }
        if current.dispatch_intent_state != AlgoliaImportDispatchIntentState::Ambiguous
            || current.engine_job_id.is_some()
        {
            return Err(RepoError::Conflict(
                "dispatch intent cannot be committed from the current job proof".into(),
            ));
        }
        if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            return Err(RepoError::Conflict(
                "finally terminal Algolia import job cannot record dispatch intent".into(),
            ));
        }

        sqlx::query(
            "UPDATE algolia_import_environment_contract
             SET rollback_epoch='migration_aware_required'
             WHERE singleton = TRUE",
        )
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;

        let updated = sqlx::query_as::<_, AlgoliaImportJobRow>(
            "UPDATE algolia_import_jobs
             SET dispatch_intent_state='committed', engine_job_id=$2, updated_at=NOW()
             WHERE id=$1
             RETURNING *",
        )
        .bind(id)
        .bind(engine_job_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(repo_error)
        .map(AlgoliaImportJob::from)?;
        tx.commit().await.map_err(repo_error)?;
        Ok(updated)
    }

    pub(super) async fn acquire_dispatch_guard_inner(
        &self,
        id: Uuid,
    ) -> Result<AlgoliaImportDispatchGuard, RepoError> {
        let mut tx = self.pool.begin().await.map_err(repo_error)?;
        let current = match self.lock_generation_fenced_target_job(&mut tx, id).await {
            Ok(current) => current,
            Err(error) => {
                tx.rollback().await.map_err(repo_error)?;
                return Err(error);
            }
        };
        let validation_error = if current.dispatch_intent_state
            != AlgoliaImportDispatchIntentState::Ambiguous
            || current.engine_job_id.is_some()
        {
            Some(RepoError::Conflict(
                "dispatch guard requires ambiguous pre-send proof".into(),
            ))
        } else if current
            .status
            .is_finally_terminal(current.resumable, current.publication_disposition)
        {
            Some(RepoError::Conflict(
                "finally terminal Algolia import job cannot acquire dispatch guard".into(),
            ))
        } else {
            None
        };
        if let Some(error) = validation_error {
            tx.rollback().await.map_err(repo_error)?;
            return Err(error);
        }
        Ok(AlgoliaImportDispatchGuard {
            tx,
            job_id: current.id,
            cloud_job_id: current.cloud_job_id,
            lifecycle_generation: current.lifecycle_generation,
        })
    }
}

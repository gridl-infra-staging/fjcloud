use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Transaction};
use std::str::FromStr;
use uuid::Uuid;

use crate::models::{NewVmLifecycleEvent, VmLifecycleEvent, VmLifecycleEventType};
use crate::repos::advisory_lock::{
    advisory_lock, vm_autorepair_admission_lock_key, vm_replacement_lock_key, AdvisoryLockGuard,
};
use crate::repos::vm_lifecycle_event_repo::{
    active_replacement_admission, admission_from_event, latest_unfinished_replacements,
    replacement_provisioning_event, summarize_guardrail_history, AutorepairGuardrailHistory,
    AutorepairGuardrailQuery, ReplacementAdmission, ReplacementAdmissionDraft,
};
use crate::repos::{RepoError, VmLifecycleEventRepo};

#[derive(sqlx::FromRow)]
struct VmLifecycleEventRow {
    id: Uuid,
    vm_id: Uuid,
    event_type: String,
    detail: serde_json::Value,
    created_at: DateTime<Utc>,
}

impl TryFrom<VmLifecycleEventRow> for VmLifecycleEvent {
    type Error = RepoError;

    fn try_from(row: VmLifecycleEventRow) -> Result<Self, Self::Error> {
        let event_type =
            VmLifecycleEventType::from_str(&row.event_type).map_err(RepoError::Other)?;
        Ok(Self {
            id: row.id,
            vm_id: row.vm_id,
            event_type,
            detail: row.detail,
            created_at: row.created_at,
        })
    }
}

pub struct PgVmLifecycleEventRepo {
    pool: PgPool,
}

impl PgVmLifecycleEventRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    fn repo_error(error: sqlx::Error) -> RepoError {
        RepoError::Other(error.to_string())
    }

    async fn lock_vm_event_stream(
        transaction: &mut Transaction<'_, Postgres>,
        vm_id: Uuid,
    ) -> Result<(), RepoError> {
        let locked = sqlx::query_scalar::<_, Uuid>(
            "SELECT id
             FROM vm_inventory
             WHERE id = $1
             FOR UPDATE",
        )
        .bind(vm_id)
        .fetch_optional(&mut **transaction)
        .await
        .map_err(Self::repo_error)?;

        if locked.is_some() {
            Ok(())
        } else {
            Err(RepoError::NotFound)
        }
    }

    async fn append_in_transaction(
        transaction: &mut Transaction<'_, Postgres>,
        event: NewVmLifecycleEvent,
    ) -> Result<VmLifecycleEvent, RepoError> {
        let row = sqlx::query_as::<_, VmLifecycleEventRow>(
            "INSERT INTO vm_lifecycle_events (vm_id, event_type, detail)
             VALUES ($1, $2, $3)
             RETURNING id, vm_id, event_type, detail, created_at",
        )
        .bind(event.vm_id)
        .bind(event.event_type.as_str())
        .bind(event.detail)
        .fetch_one(&mut **transaction)
        .await
        .map_err(Self::repo_error)?;
        row.try_into()
    }

    async fn list_for_vm_in_transaction(
        transaction: &mut Transaction<'_, Postgres>,
        vm_id: Uuid,
    ) -> Result<Vec<VmLifecycleEvent>, RepoError> {
        let rows = sqlx::query_as::<_, VmLifecycleEventRow>(
            "SELECT id, vm_id, event_type, detail, created_at
             FROM vm_lifecycle_events
             WHERE vm_id = $1
             ORDER BY created_at ASC, id ASC",
        )
        .bind(vm_id)
        .fetch_all(&mut **transaction)
        .await
        .map_err(Self::repo_error)?;
        rows.into_iter().map(TryInto::try_into).collect()
    }
}

#[async_trait]
impl VmLifecycleEventRepo for PgVmLifecycleEventRepo {
    async fn lock_autorepair_admission(&self) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        let key = vm_autorepair_admission_lock_key(&self.pool).await?;
        advisory_lock(&self.pool, key).await
    }

    async fn lock_replacement_execution(
        &self,
        vm_id: Uuid,
    ) -> Result<AdvisoryLockGuard<'_>, RepoError> {
        let key = vm_replacement_lock_key(&self.pool, vm_id).await?;
        advisory_lock(&self.pool, key).await
    }

    async fn append(&self, event: NewVmLifecycleEvent) -> Result<VmLifecycleEvent, RepoError> {
        let row = sqlx::query_as::<_, VmLifecycleEventRow>(
            "INSERT INTO vm_lifecycle_events (vm_id, event_type, detail)
             VALUES ($1, $2, $3)
             RETURNING id, vm_id, event_type, detail, created_at",
        )
        .bind(event.vm_id)
        .bind(event.event_type.as_str())
        .bind(event.detail)
        .fetch_one(&self.pool)
        .await
        .map_err(Self::repo_error)?;
        row.try_into()
    }

    async fn list_for_vm(&self, vm_id: Uuid) -> Result<Vec<VmLifecycleEvent>, RepoError> {
        let rows = sqlx::query_as::<_, VmLifecycleEventRow>(
            "SELECT id, vm_id, event_type, detail, created_at
             FROM vm_lifecycle_events
             WHERE vm_id = $1
             ORDER BY created_at ASC, id ASC",
        )
        .bind(vm_id)
        .fetch_all(&self.pool)
        .await
        .map_err(Self::repo_error)?;
        rows.into_iter().map(TryInto::try_into).collect()
    }

    async fn latest_for_vm(&self, vm_id: Uuid) -> Result<Option<VmLifecycleEvent>, RepoError> {
        let row = sqlx::query_as::<_, VmLifecycleEventRow>(
            "SELECT id, vm_id, event_type, detail, created_at
             FROM vm_lifecycle_events
             WHERE vm_id = $1
             ORDER BY created_at DESC, id DESC
             LIMIT 1",
        )
        .bind(vm_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(Self::repo_error)?;
        row.map(TryInto::try_into).transpose()
    }

    async fn admit_replacement(
        &self,
        draft: ReplacementAdmissionDraft,
    ) -> Result<ReplacementAdmission, RepoError> {
        let mut transaction = self.pool.begin().await.map_err(Self::repo_error)?;
        Self::lock_vm_event_stream(&mut transaction, draft.dead_vm_id).await?;

        let events = Self::list_for_vm_in_transaction(&mut transaction, draft.dead_vm_id).await?;
        if let Some(admission) = active_replacement_admission(&events)? {
            transaction.commit().await.map_err(Self::repo_error)?;
            return Ok(admission);
        }

        let event =
            Self::append_in_transaction(&mut transaction, replacement_provisioning_event(&draft))
                .await?;
        let admission = admission_from_event(&event, true)?;
        transaction.commit().await.map_err(Self::repo_error)?;
        Ok(admission)
    }

    async fn guardrail_history(
        &self,
        query: AutorepairGuardrailQuery,
    ) -> Result<AutorepairGuardrailHistory, RepoError> {
        let rows = sqlx::query_as::<_, VmLifecycleEventRow>(
            "SELECT events.id,
                    events.vm_id,
                    events.event_type,
                    events.detail || jsonb_build_object('inventory_region', inventory.region) AS detail,
                    events.created_at
             FROM vm_lifecycle_events events
             JOIN vm_inventory inventory ON inventory.id = events.vm_id
             WHERE events.created_at <= $1
             ORDER BY events.created_at ASC, events.id ASC",
        )
        .bind(query.observed_at)
        .fetch_all(&self.pool)
        .await
        .map_err(Self::repo_error)?;
        let events = rows
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<VmLifecycleEvent>, RepoError>>()?;
        summarize_guardrail_history(&events, &query)
    }

    async fn unfinished_replacements(&self) -> Result<Vec<VmLifecycleEvent>, RepoError> {
        let rows = sqlx::query_as::<_, VmLifecycleEventRow>(
            "SELECT id, vm_id, event_type, detail, created_at
             FROM vm_lifecycle_events
             WHERE event_type IN (
                 'replacement_provisioning',
                 'replacement_booted',
                 'tenants_replaced',
                 'replacement_failed',
                 'replacement_completed',
                 'replacement_refused'
             )
             ORDER BY created_at ASC, id ASC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(Self::repo_error)?;
        let events = rows
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<VmLifecycleEvent>, RepoError>>()?;
        latest_unfinished_replacements(&events)
    }
}

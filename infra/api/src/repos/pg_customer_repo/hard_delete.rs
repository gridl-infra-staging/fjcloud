use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::models::{
    AlgoliaImportEngineAckState, AlgoliaImportPublicationDisposition,
    AlgoliaImportTombstoneCleanupPhase, AlgoliaSealScrubWork,
};
use crate::repos::{CustomerHardDeleteKind, CustomerHardDeleteOutcome, RepoError};

#[derive(sqlx::FromRow)]
struct SealScrubWorkRow {
    erasure_handle: Uuid,
    engine_job_id: Option<Uuid>,
    destination_vm_id: Option<Uuid>,
    cleanup_phase: String,
    publication_disposition: String,
    engine_ack_state: String,
}

/// Hard-erases a customer and scrubs its import jobs in one transaction.
pub(super) async fn hard_delete(
    pool: &PgPool,
    id: Uuid,
    kind: CustomerHardDeleteKind,
) -> Result<CustomerHardDeleteOutcome, RepoError> {
    let mut tx = pool.begin().await.map_err(repo_error)?;
    let Some(status) = lock_customer_status(&mut tx, id).await? else {
        tx.rollback().await.map_err(repo_error)?;
        return Ok(CustomerHardDeleteOutcome::NotFound);
    };
    if kind == CustomerHardDeleteKind::PrivacyErasure && status != "deleted" {
        tx.rollback().await.map_err(repo_error)?;
        return Ok(CustomerHardDeleteOutcome::NotSoftDeleted);
    }
    if let Err(error) = reject_open_invoices(&mut tx, id).await {
        tx.rollback().await.map_err(repo_error)?;
        return Err(error);
    }

    sqlx::query(
        "UPDATE customers
         SET lifecycle_generation = lifecycle_generation + 1, updated_at = NOW()
         WHERE id = $1",
    )
    .bind(id)
    .execute(&mut *tx)
    .await
    .map_err(repo_error)?;
    let seal_scrub_work = scrub_algolia_jobs(&mut tx, id).await?;
    delete_customer_dependents(&mut tx, id).await?;
    sqlx::query("DELETE FROM customers WHERE id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await
        .map_err(repo_error)?;
    tx.commit().await.map_err(repo_error)?;

    Ok(CustomerHardDeleteOutcome::Erased { seal_scrub_work })
}

async fn lock_customer_status(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<Option<String>, RepoError> {
    sqlx::query_scalar("SELECT status FROM customers WHERE id = $1 FOR UPDATE")
        .bind(id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(repo_error)
}

async fn reject_open_invoices(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<(), RepoError> {
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::BIGINT FROM invoices
         WHERE customer_id = $1 AND status NOT IN ('paid', 'refunded')",
    )
    .bind(id)
    .fetch_one(&mut **tx)
    .await
    .map_err(repo_error)?;
    if count == 0 {
        return Ok(());
    }
    Err(RepoError::Conflict(
        "customer has open invoices; close or refund before hard-erase".into(),
    ))
}

async fn scrub_algolia_jobs(
    tx: &mut Transaction<'_, Postgres>,
    customer_id: Uuid,
) -> Result<Vec<AlgoliaSealScrubWork>, RepoError> {
    let rows = sqlx::query_as::<_, SealScrubWorkRow>(
        "UPDATE algolia_import_jobs
         SET customer_id = NULL, tenant_id = NULL, algolia_app_id = NULL,
             destination_kind = NULL, logical_target = NULL, destination_region = NULL,
             destination_deployment_id = NULL, physical_uid = NULL, source_name = NULL,
             cloud_job_id = NULL, dispatch_intent_state = NULL, lifecycle_generation = NULL,
             idempotency_key = NULL, canonical_fingerprint = NULL, routing_identity = NULL,
             source_size_bytes = NULL, reserved_index_count = NULL,
             reserved_customer_storage_bytes = NULL, reserved_node_transient_bytes = NULL,
             retryable = NULL, worker_claimed_at = NULL, worker_lease_expires_at = NULL,
             cancel_requested_at = NULL, resume_intent_generation = NULL,
             resume_checkpoint = NULL, resume_deadline = NULL,
             resume_status_observed_at = NULL, resumable = NULL, resume_count = NULL,
             documents_expected = NULL, documents_imported = NULL,
             documents_rejected = NULL, settings_applied = NULL,
             settings_unsupported = NULL, synonyms_expected = NULL,
             synonyms_imported = NULL, synonyms_rejected = NULL, rules_expected = NULL,
             rules_imported = NULL, rules_rejected = NULL, warnings = NULL,
             error_code = NULL, error_message = NULL, status = NULL,
             terminal_at = NULL,
             engine_ack_state = 'pending', erasure_handle = gen_random_uuid(),
             cleanup_phase = CASE WHEN engine_job_id IS NULL
                 THEN 'engine_disposition_required'
                 ELSE 'exact_target_absence_required' END,
             erased_at = NOW(), updated_at = NOW()
         WHERE customer_id = $1
         RETURNING erasure_handle, engine_job_id, destination_vm_id, cleanup_phase,
                   publication_disposition, engine_ack_state",
    )
    .bind(customer_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(repo_error)?;
    rows.into_iter().map(parse_scrub_work).collect()
}

fn parse_scrub_work(row: SealScrubWorkRow) -> Result<AlgoliaSealScrubWork, RepoError> {
    Ok(AlgoliaSealScrubWork {
        erasure_handle: row.erasure_handle,
        engine_job_id: row.engine_job_id,
        destination_vm_id: row.destination_vm_id,
        cleanup_phase: match row.cleanup_phase.as_str() {
            "engine_disposition_required" => {
                AlgoliaImportTombstoneCleanupPhase::EngineDispositionRequired
            }
            "exact_target_absence_required" => {
                AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsenceRequired
            }
            "exact_target_absent" => AlgoliaImportTombstoneCleanupPhase::ExactTargetAbsent,
            value => return Err(invalid_database_value("cleanup phase", value)),
        },
        publication_disposition: match row.publication_disposition.as_str() {
            "not_started" => AlgoliaImportPublicationDisposition::NotStarted,
            "unchanged" => AlgoliaImportPublicationDisposition::Unchanged,
            "promoted" => AlgoliaImportPublicationDisposition::Promoted,
            "unknown" => AlgoliaImportPublicationDisposition::Unknown,
            value => return Err(invalid_database_value("publication disposition", value)),
        },
        engine_ack_state: match row.engine_ack_state.as_str() {
            "pending" => AlgoliaImportEngineAckState::Pending,
            "not_applicable" => AlgoliaImportEngineAckState::NotApplicable,
            "seal_acknowledged" => AlgoliaImportEngineAckState::SealAcknowledged,
            "outbox_pending" => AlgoliaImportEngineAckState::OutboxPending,
            "acknowledged" => AlgoliaImportEngineAckState::Acknowledged,
            value => return Err(invalid_database_value("engine ACK state", value)),
        },
    })
}

async fn delete_customer_dependents(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
) -> Result<(), RepoError> {
    let statements = [
        "DELETE FROM api_keys WHERE customer_id = $1",
        "DELETE FROM index_replicas WHERE customer_id = $1",
        "DELETE FROM restore_jobs WHERE customer_id = $1",
        "DELETE FROM cold_snapshots WHERE customer_id = $1",
        "DELETE FROM storage_access_keys WHERE customer_id = $1",
        "DELETE FROM storage_buckets WHERE customer_id = $1",
        "DELETE FROM customer_tenants WHERE customer_id = $1",
        "DELETE FROM customer_deployments WHERE customer_id = $1",
        "DELETE FROM customer_rate_overrides WHERE customer_id = $1",
        "DELETE FROM usage_records WHERE customer_id = $1",
        "DELETE FROM usage_daily WHERE customer_id = $1",
        "DELETE FROM invoices WHERE customer_id = $1",
        "DELETE FROM audit_log WHERE target_tenant_id = $1",
    ];
    for statement in statements {
        sqlx::query(statement)
            .bind(id)
            .execute(&mut **tx)
            .await
            .map_err(repo_error)?;
    }
    Ok(())
}

fn invalid_database_value(field: &str, value: &str) -> RepoError {
    RepoError::Other(format!("invalid Algolia tombstone {field}: {value}"))
}

fn repo_error(error: sqlx::Error) -> RepoError {
    RepoError::Other(error.to_string())
}

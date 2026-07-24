use chrono::{DateTime, Utc};
use uuid::Uuid;

use super::{
    AlgoliaImportDestinationKind, AlgoliaImportDispatchIntentState, AlgoliaImportEngineAckState,
    AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportJobStatus,
    AlgoliaImportPublicationDisposition, AlgoliaImportSummary,
};

#[derive(sqlx::FromRow)]
pub(crate) struct AlgoliaImportJobRow {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub algolia_app_id: String,
    pub destination_kind: String,
    pub logical_target: String,
    pub destination_region: String,
    pub destination_deployment_id: Option<Uuid>,
    pub destination_vm_id: Option<Uuid>,
    pub physical_uid: Option<String>,
    pub source_name: String,
    pub cloud_job_id: Uuid,
    pub engine_job_id: Option<Uuid>,
    pub dispatch_intent_state: String,
    pub lifecycle_generation: i64,
    pub idempotency_key: String,
    pub canonical_fingerprint: String,
    pub routing_identity: Option<String>,
    pub source_size_bytes: i64,
    pub reserved_index_count: i64,
    pub reserved_customer_storage_bytes: i64,
    pub reserved_node_transient_bytes: i64,
    pub retryable: bool,
    pub worker_claimed_at: Option<DateTime<Utc>>,
    pub worker_lease_expires_at: Option<DateTime<Utc>>,
    pub cancel_requested_at: Option<DateTime<Utc>>,
    pub resume_intent_generation: i64,
    pub resume_checkpoint: Option<String>,
    pub resume_deadline: Option<DateTime<Utc>>,
    pub resume_status_observed_at: Option<DateTime<Utc>>,
    pub resumable: bool,
    pub resume_count: i64,
    pub documents_expected: i64,
    pub documents_imported: i64,
    pub documents_rejected: i64,
    pub settings_applied: i64,
    pub settings_unsupported: i64,
    pub synonyms_expected: i64,
    pub synonyms_imported: i64,
    pub synonyms_rejected: i64,
    pub rules_expected: i64,
    pub rules_imported: i64,
    pub rules_rejected: i64,
    pub warnings: serde_json::Value,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub status: String,
    pub publication_disposition: String,
    pub engine_ack_state: String,
    pub terminal_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<AlgoliaImportJobRow> for AlgoliaImportJob {
    fn from(row: AlgoliaImportJobRow) -> Self {
        let summary = AlgoliaImportSummary {
            documents_expected: row.documents_expected,
            documents_imported: row.documents_imported,
            documents_rejected: row.documents_rejected,
            settings_applied: row.settings_applied,
            settings_unsupported: row.settings_unsupported,
            synonyms_expected: row.synonyms_expected,
            synonyms_imported: row.synonyms_imported,
            synonyms_rejected: row.synonyms_rejected,
            rules_expected: row.rules_expected,
            rules_imported: row.rules_imported,
            rules_rejected: row.rules_rejected,
        };
        Self {
            id: row.id,
            customer_id: row.customer_id,
            tenant_id: row.tenant_id,
            algolia_app_id: row.algolia_app_id,
            destination_kind: parse_destination_kind(&row.destination_kind),
            logical_target: row.logical_target,
            destination_region: row.destination_region,
            destination_deployment_id: row.destination_deployment_id,
            destination_vm_id: row.destination_vm_id,
            physical_uid: row.physical_uid,
            source_name: row.source_name,
            cloud_job_id: row.cloud_job_id,
            engine_job_id: row.engine_job_id,
            dispatch_intent_state: parse_dispatch_intent_state(&row.dispatch_intent_state),
            lifecycle_generation: row.lifecycle_generation,
            idempotency_key: row.idempotency_key,
            canonical_fingerprint: row.canonical_fingerprint,
            routing_identity: row.routing_identity,
            source_size_bytes: row.source_size_bytes,
            reserved_index_count: row.reserved_index_count,
            reserved_customer_storage_bytes: row.reserved_customer_storage_bytes,
            reserved_node_transient_bytes: row.reserved_node_transient_bytes,
            retryable: row.retryable,
            worker_claimed_at: row.worker_claimed_at,
            worker_lease_expires_at: row.worker_lease_expires_at,
            cancel_requested_at: row.cancel_requested_at,
            resume_intent_generation: row.resume_intent_generation,
            resume_checkpoint: row.resume_checkpoint,
            resume_deadline: row.resume_deadline,
            resume_status_observed_at: row.resume_status_observed_at,
            resumable: row.resumable,
            resume_count: row.resume_count,
            summary,
            warnings: row.warnings,
            error_code: row.error_code.as_deref().map(parse_error_code),
            error_message: row.error_message,
            status: parse_status(&row.status),
            publication_disposition: parse_publication_disposition(&row.publication_disposition),
            engine_ack_state: parse_engine_ack_state(&row.engine_ack_state),
            terminal_at: row.terminal_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

fn parse_destination_kind(value: &str) -> AlgoliaImportDestinationKind {
    match value {
        "create" => AlgoliaImportDestinationKind::Create,
        "replace" => AlgoliaImportDestinationKind::Replace,
        _ => unreachable!("algolia_import_jobs destination kind CHECK rejected {value}"),
    }
}

fn parse_status(value: &str) -> AlgoliaImportJobStatus {
    match value {
        "queued" => AlgoliaImportJobStatus::Queued,
        "validating_source" => AlgoliaImportJobStatus::ValidatingSource,
        "copying_configuration" => AlgoliaImportJobStatus::CopyingConfiguration,
        "copying_documents" => AlgoliaImportJobStatus::CopyingDocuments,
        "verifying" => AlgoliaImportJobStatus::Verifying,
        "promoting" => AlgoliaImportJobStatus::Promoting,
        "cancelling" => AlgoliaImportJobStatus::Cancelling,
        "cancelled" => AlgoliaImportJobStatus::Cancelled,
        "resuming" => AlgoliaImportJobStatus::Resuming,
        "completed" => AlgoliaImportJobStatus::Completed,
        "completed_with_warnings" => AlgoliaImportJobStatus::CompletedWithWarnings,
        "failed" => AlgoliaImportJobStatus::Failed,
        "interrupted" => AlgoliaImportJobStatus::Interrupted,
        _ => unreachable!("algolia_import_jobs status CHECK rejected {value}"),
    }
}

fn parse_publication_disposition(value: &str) -> AlgoliaImportPublicationDisposition {
    match value {
        "not_started" => AlgoliaImportPublicationDisposition::NotStarted,
        "unchanged" => AlgoliaImportPublicationDisposition::Unchanged,
        "promoted" => AlgoliaImportPublicationDisposition::Promoted,
        "unknown" => AlgoliaImportPublicationDisposition::Unknown,
        _ => unreachable!("algolia_import_jobs publication disposition CHECK rejected {value}"),
    }
}

fn parse_engine_ack_state(value: &str) -> AlgoliaImportEngineAckState {
    match value {
        "pending" => AlgoliaImportEngineAckState::Pending,
        "not_applicable" => AlgoliaImportEngineAckState::NotApplicable,
        "seal_acknowledged" => AlgoliaImportEngineAckState::SealAcknowledged,
        "outbox_pending" => AlgoliaImportEngineAckState::OutboxPending,
        "acknowledged" => AlgoliaImportEngineAckState::Acknowledged,
        _ => unreachable!("algolia_import_jobs engine ACK CHECK rejected {value}"),
    }
}

fn parse_dispatch_intent_state(value: &str) -> AlgoliaImportDispatchIntentState {
    match value {
        "absent" => AlgoliaImportDispatchIntentState::Absent,
        "committed" => AlgoliaImportDispatchIntentState::Committed,
        "ambiguous" => AlgoliaImportDispatchIntentState::Ambiguous,
        _ => unreachable!("algolia_import_jobs dispatch intent CHECK rejected {value}"),
    }
}

fn parse_error_code(value: &str) -> AlgoliaImportErrorCode {
    match value {
        "invalid_credentials" => AlgoliaImportErrorCode::InvalidCredentials,
        "missing_source_permission" => AlgoliaImportErrorCode::MissingSourcePermission,
        "source_not_found" => AlgoliaImportErrorCode::SourceNotFound,
        "source_catalog_too_large" => AlgoliaImportErrorCode::SourceCatalogTooLarge,
        "destination_conflict" => AlgoliaImportErrorCode::DestinationConflict,
        "quota_exceeded" => AlgoliaImportErrorCode::QuotaExceeded,
        "source_too_large" => AlgoliaImportErrorCode::SourceTooLarge,
        "insufficient_engine_storage" => AlgoliaImportErrorCode::InsufficientEngineStorage,
        "destination_changed" => AlgoliaImportErrorCode::DestinationChanged,
        "source_changed" => AlgoliaImportErrorCode::SourceChanged,
        "incompatible_data" => AlgoliaImportErrorCode::IncompatibleData,
        "engine_upgrade_required" => AlgoliaImportErrorCode::EngineUpgradeRequired,
        "migration_ha_not_supported" => AlgoliaImportErrorCode::MigrationHaNotSupported,
        "migration_provider_unsupported" => AlgoliaImportErrorCode::MigrationProviderUnsupported,
        "backend_unavailable" => AlgoliaImportErrorCode::BackendUnavailable,
        "interrupted" => AlgoliaImportErrorCode::Interrupted,
        "cancel_not_permitted" => AlgoliaImportErrorCode::CancelNotPermitted,
        "not_resumable" => AlgoliaImportErrorCode::NotResumable,
        "internal" => AlgoliaImportErrorCode::Internal,
        _ => unreachable!("algolia_import_jobs error code CHECK rejected {value}"),
    }
}

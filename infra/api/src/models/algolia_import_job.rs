use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use utoipa::ToSchema;
use uuid::Uuid;

mod provider;
mod row;
mod state;
mod target_binding;

pub use provider::{
    algolia_eligible_regions, validate_algolia_create_provider, AlgoliaReplaceTargetFacts,
};
pub(crate) use row::AlgoliaImportJobRow;
pub use state::AlgoliaImportJobState;
pub use target_binding::AlgoliaImportTargetBinding;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportJobStatus {
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
}

impl AlgoliaImportJobStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::ValidatingSource => "validating_source",
            Self::CopyingConfiguration => "copying_configuration",
            Self::CopyingDocuments => "copying_documents",
            Self::Verifying => "verifying",
            Self::Promoting => "promoting",
            Self::Cancelling => "cancelling",
            Self::Cancelled => "cancelled",
            Self::Resuming => "resuming",
            Self::Completed => "completed",
            Self::CompletedWithWarnings => "completed_with_warnings",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
        }
    }

    pub fn is_finally_terminal(
        self,
        resumable: bool,
        publication_disposition: AlgoliaImportPublicationDisposition,
    ) -> bool {
        if matches!(self, Self::Failed | Self::Interrupted) && resumable {
            return false;
        }
        if self == Self::Cancelled {
            return publication_disposition == AlgoliaImportPublicationDisposition::Unchanged;
        }
        matches!(
            self,
            Self::Completed | Self::CompletedWithWarnings | Self::Failed | Self::Interrupted
        )
    }
}

pub const MAX_RESUME_CHECKPOINT_BYTES: usize = 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineResumeMirror {
    checkpoint: String,
    status_observed_at: DateTime<Utc>,
    deadline: DateTime<Utc>,
}

impl EngineResumeMirror {
    pub fn new(
        checkpoint: String,
        status_observed_at: DateTime<Utc>,
        deadline: DateTime<Utc>,
    ) -> Result<Self, &'static str> {
        if checkpoint.is_empty() || checkpoint.len() > MAX_RESUME_CHECKPOINT_BYTES {
            return Err("resume checkpoint must contain between 1 and 1024 bytes");
        }
        if deadline <= status_observed_at {
            return Err("resume deadline must follow its engine status observation");
        }
        Ok(Self {
            checkpoint,
            status_observed_at,
            deadline,
        })
    }

    pub fn checkpoint(&self) -> &str {
        &self.checkpoint
    }
    pub fn status_observed_at(&self) -> DateTime<Utc> {
        self.status_observed_at
    }
    pub fn deadline(&self) -> DateTime<Utc> {
        self.deadline
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportPublicationDisposition {
    NotStarted,
    Unchanged,
    Promoted,
    Unknown,
}

impl AlgoliaImportPublicationDisposition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotStarted => "not_started",
            Self::Unchanged => "unchanged",
            Self::Promoted => "promoted",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportEngineAckState {
    Pending,
    NotApplicable,
    SealAcknowledged,
    OutboxPending,
    Acknowledged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportTombstoneCleanupPhase {
    EngineDispositionRequired,
    ExactTargetAbsenceRequired,
    ExactTargetAbsent,
}

impl AlgoliaImportTombstoneCleanupPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EngineDispositionRequired => "engine_disposition_required",
            Self::ExactTargetAbsenceRequired => "exact_target_absence_required",
            Self::ExactTargetAbsent => "exact_target_absent",
        }
    }
}

/// Opaque cloud-owned work required to reconcile an erased import safely.
///
/// This deliberately excludes every customer, source, credential, object,
/// logical-target, and physical-index identifier.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlgoliaSealScrubWork {
    pub erasure_handle: Uuid,
    pub engine_job_id: Option<Uuid>,
    pub destination_vm_id: Option<Uuid>,
    pub cleanup_phase: AlgoliaImportTombstoneCleanupPhase,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub engine_ack_state: AlgoliaImportEngineAckState,
}

impl AlgoliaImportEngineAckState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::NotApplicable => "not_applicable",
            Self::SealAcknowledged => "seal_acknowledged",
            Self::OutboxPending => "outbox_pending",
            Self::Acknowledged => "acknowledged",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportDispatchIntentState {
    Absent,
    Committed,
    Ambiguous,
}

impl AlgoliaImportDispatchIntentState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Absent => "absent",
            Self::Committed => "committed",
            Self::Ambiguous => "ambiguous",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportErrorCode {
    InvalidCredentials,
    MissingSourcePermission,
    SourceNotFound,
    SourceCatalogTooLarge,
    DestinationConflict,
    QuotaExceeded,
    SourceTooLarge,
    InsufficientEngineStorage,
    DestinationChanged,
    SourceChanged,
    IncompatibleData,
    EngineUpgradeRequired,
    MigrationHaNotSupported,
    MigrationProviderUnsupported,
    BackendUnavailable,
    Interrupted,
    CancelNotPermitted,
    NotResumable,
    Internal,
}

impl AlgoliaImportErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidCredentials => "invalid_credentials",
            Self::MissingSourcePermission => "missing_source_permission",
            Self::SourceNotFound => "source_not_found",
            Self::SourceCatalogTooLarge => "source_catalog_too_large",
            Self::DestinationConflict => "destination_conflict",
            Self::QuotaExceeded => "quota_exceeded",
            Self::SourceTooLarge => "source_too_large",
            Self::InsufficientEngineStorage => "insufficient_engine_storage",
            Self::DestinationChanged => "destination_changed",
            Self::SourceChanged => "source_changed",
            Self::IncompatibleData => "incompatible_data",
            Self::EngineUpgradeRequired => "engine_upgrade_required",
            Self::MigrationHaNotSupported => "migration_ha_not_supported",
            Self::MigrationProviderUnsupported => "migration_provider_unsupported",
            Self::BackendUnavailable => "backend_unavailable",
            Self::Interrupted => "interrupted",
            Self::CancelNotPermitted => "cancel_not_permitted",
            Self::NotResumable => "not_resumable",
            Self::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaImportSummary {
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlgoliaImportJob {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub algolia_app_id: String,
    pub destination_kind: AlgoliaImportDestinationKind,
    pub logical_target: String,
    pub destination_region: String,
    pub destination_deployment_id: Option<Uuid>,
    pub destination_vm_id: Option<Uuid>,
    pub physical_uid: Option<String>,
    pub source_name: String,
    pub cloud_job_id: Uuid,
    pub engine_job_id: Option<Uuid>,
    pub dispatch_intent_state: AlgoliaImportDispatchIntentState,
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
    pub summary: AlgoliaImportSummary,
    pub warnings: serde_json::Value,
    pub error_code: Option<AlgoliaImportErrorCode>,
    pub error_message: Option<String>,
    pub status: AlgoliaImportJobStatus,
    pub publication_disposition: AlgoliaImportPublicationDisposition,
    pub engine_ack_state: AlgoliaImportEngineAckState,
    pub terminal_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct NewAlgoliaImportJob {
    customer_id: Uuid,
    algolia_app_id: String,
    destination: AlgoliaImportDestination,
    source_name: String,
    idempotency_key: String,
    canonical_fingerprint: String,
    source_size_bytes: i64,
    target_binding: Option<AlgoliaImportTargetBinding>,
}

#[derive(Debug, Clone)]
pub struct AlgoliaImportSource {
    algolia_app_id: String,
    source_name: String,
    canonical_fingerprint: String,
    source_size_bytes: i64,
}

pub const UNKNOWN_ALGOLIA_SOURCE_SIZE_BYTES: i64 = 1_073_741_824;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportSourceMetadata {
    source_size_bytes: Option<i64>,
    record_count: Option<i64>,
    revision: String,
}

impl AlgoliaImportSourceMetadata {
    pub fn new(
        source_size_bytes: Option<i64>,
        record_count: Option<i64>,
        revision: impl Into<String>,
    ) -> Self {
        Self {
            source_size_bytes: source_size_bytes.filter(|value| *value >= 0),
            record_count: record_count.filter(|value| *value >= 0),
            revision: revision.into(),
        }
    }
}

impl AlgoliaImportSource {
    pub fn from_final_key_metadata(
        algolia_app_id: impl Into<String>,
        source_name: impl Into<String>,
        metadata: AlgoliaImportSourceMetadata,
    ) -> Self {
        let algolia_app_id = algolia_app_id.into();
        let source_name = source_name.into();
        let source_size_bytes = metadata
            .source_size_bytes
            .unwrap_or(UNKNOWN_ALGOLIA_SOURCE_SIZE_BYTES);
        let canonical_fingerprint = source_metadata_fingerprint(
            &algolia_app_id,
            &source_name,
            source_size_bytes,
            &metadata,
        );
        Self {
            algolia_app_id,
            source_name,
            canonical_fingerprint,
            source_size_bytes,
        }
    }

    pub fn canonical_fingerprint(&self) -> &str {
        &self.canonical_fingerprint
    }

    pub fn source_size_bytes(&self) -> i64 {
        self.source_size_bytes
    }
}

fn source_metadata_fingerprint(
    algolia_app_id: &str,
    source_name: &str,
    source_size_bytes: i64,
    metadata: &AlgoliaImportSourceMetadata,
) -> String {
    let mut hasher = Sha256::new();
    for part in [
        algolia_app_id,
        source_name,
        &source_size_bytes.to_string(),
        &metadata
            .record_count
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".into()),
        &metadata.revision,
    ] {
        hasher.update(part.as_bytes());
        hasher.update([0]);
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[derive(Debug, Clone)]
pub struct NewAlgoliaReplaceImportJob {
    customer_id: Uuid,
    logical_target: String,
    source: AlgoliaImportSource,
    idempotency_key: String,
    target_binding: Option<AlgoliaImportTargetBinding>,
}

impl NewAlgoliaReplaceImportJob {
    pub fn new(
        customer_id: Uuid,
        logical_target: impl Into<String>,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Self {
        Self {
            customer_id,
            logical_target: logical_target.into(),
            source,
            idempotency_key: idempotency_key.into(),
            target_binding: None,
        }
    }

    pub fn customer_id(&self) -> Uuid {
        self.customer_id
    }

    pub fn logical_target(&self) -> &str {
        &self.logical_target
    }

    pub(crate) fn into_authenticated_job(
        self,
        destination: AuthenticatedAlgoliaReplacementTarget,
    ) -> NewAlgoliaImportJob {
        NewAlgoliaImportJob::replace(
            self.customer_id,
            destination,
            self.source,
            self.idempotency_key,
            self.target_binding,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaImportDestinationKind {
    Create,
    Replace,
}

impl AlgoliaImportDestinationKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Replace => "replace",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AlgoliaImportDestination {
    Create(AlgoliaImportCreateDestination),
    Replace(AuthenticatedAlgoliaReplacementTarget),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaImportCreateDestination {
    logical_target: String,
    region: String,
    vm_id: Option<Uuid>,
    physical_uid: Option<String>,
    routing_identity: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedAlgoliaReplacementTarget {
    logical_target: String,
    region: String,
    deployment_id: Uuid,
    vm_id: Uuid,
    physical_uid: String,
    routing_identity: String,
}

impl AlgoliaImportCreateDestination {
    pub fn new(logical_target: impl Into<String>, region: impl Into<String>) -> Self {
        Self {
            logical_target: logical_target.into(),
            region: region.into(),
            vm_id: None,
            physical_uid: None,
            routing_identity: None,
        }
    }

    fn with_placement(mut self, vm_id: Uuid, physical_uid: String) -> Self {
        self.vm_id = Some(vm_id);
        self.routing_identity = Some(physical_uid.clone());
        self.physical_uid = Some(physical_uid);
        self
    }
}

impl AuthenticatedAlgoliaReplacementTarget {
    pub(crate) fn region(&self) -> &str {
        &self.region
    }

    pub(crate) fn routing_identity(&self) -> &str {
        &self.routing_identity
    }

    pub(crate) fn from_existing_index(
        customer_id: Uuid,
        logical_target: impl Into<String>,
        region: impl Into<String>,
        deployment_id: Uuid,
        vm_id: Uuid,
    ) -> Self {
        let logical_target = logical_target.into();
        let physical_uid =
            crate::services::flapjack_node::flapjack_index_uid(customer_id, &logical_target);
        Self {
            routing_identity: physical_uid.clone(),
            logical_target,
            region: region.into(),
            deployment_id,
            vm_id,
            physical_uid,
        }
    }
}

impl AlgoliaImportDestination {
    pub fn kind(&self) -> AlgoliaImportDestinationKind {
        match self {
            Self::Create(_) => AlgoliaImportDestinationKind::Create,
            Self::Replace(_) => AlgoliaImportDestinationKind::Replace,
        }
    }

    pub fn logical_target(&self) -> &str {
        match self {
            Self::Create(destination) => &destination.logical_target,
            Self::Replace(destination) => &destination.logical_target,
        }
    }

    pub fn region(&self) -> &str {
        match self {
            Self::Create(destination) => &destination.region,
            Self::Replace(destination) => &destination.region,
        }
    }

    pub fn deployment_id(&self) -> Option<Uuid> {
        match self {
            Self::Create(_) => None,
            Self::Replace(destination) => Some(destination.deployment_id),
        }
    }

    pub fn vm_id(&self) -> Option<Uuid> {
        match self {
            Self::Create(destination) => destination.vm_id,
            Self::Replace(destination) => Some(destination.vm_id),
        }
    }

    pub fn physical_uid(&self) -> Option<&str> {
        match self {
            Self::Create(destination) => destination.physical_uid.as_deref(),
            Self::Replace(destination) => Some(&destination.physical_uid),
        }
    }

    pub fn routing_identity(&self) -> Option<&str> {
        match self {
            Self::Create(destination) => destination.routing_identity.as_deref(),
            Self::Replace(destination) => Some(&destination.routing_identity),
        }
    }
}

impl NewAlgoliaImportJob {
    pub fn create(
        customer_id: Uuid,
        destination: AlgoliaImportCreateDestination,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
    ) -> Self {
        Self::from_destination(
            customer_id,
            AlgoliaImportDestination::Create(destination),
            source,
            idempotency_key,
            None,
        )
    }

    pub fn replace(
        customer_id: Uuid,
        destination: AuthenticatedAlgoliaReplacementTarget,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
        target_binding: Option<AlgoliaImportTargetBinding>,
    ) -> Self {
        Self::from_destination(
            customer_id,
            AlgoliaImportDestination::Replace(destination),
            source,
            idempotency_key,
            target_binding,
        )
    }

    fn from_destination(
        customer_id: Uuid,
        destination: AlgoliaImportDestination,
        source: AlgoliaImportSource,
        idempotency_key: impl Into<String>,
        target_binding: Option<AlgoliaImportTargetBinding>,
    ) -> Self {
        let canonical_fingerprint =
            request_fingerprint(&source.canonical_fingerprint, &destination);
        Self {
            customer_id,
            algolia_app_id: source.algolia_app_id,
            destination,
            source_name: source.source_name,
            idempotency_key: idempotency_key.into(),
            canonical_fingerprint,
            source_size_bytes: source.source_size_bytes,
            target_binding,
        }
    }

    pub fn customer_id(&self) -> Uuid {
        self.customer_id
    }

    pub fn tenant_id(&self) -> &str {
        self.destination.logical_target()
    }

    pub fn algolia_app_id(&self) -> &str {
        &self.algolia_app_id
    }

    pub fn destination(&self) -> &AlgoliaImportDestination {
        &self.destination
    }

    pub fn source_name(&self) -> &str {
        &self.source_name
    }

    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }

    pub fn canonical_fingerprint(&self) -> &str {
        &self.canonical_fingerprint
    }

    pub fn source_size_bytes(&self) -> i64 {
        self.source_size_bytes
    }

    pub(crate) fn with_create_placement(
        mut self,
        vm_id: Uuid,
        physical_uid: String,
    ) -> Result<Self, &'static str> {
        let AlgoliaImportDestination::Create(destination) = self.destination else {
            return Err("Algolia create admission requires a create destination");
        };
        self.destination =
            AlgoliaImportDestination::Create(destination.with_placement(vm_id, physical_uid));
        Ok(self)
    }
}

fn request_fingerprint(source_fingerprint: &str, destination: &AlgoliaImportDestination) -> String {
    let mut hasher = Sha256::new();
    for part in [
        source_fingerprint,
        destination.kind().as_str(),
        destination.logical_target(),
        destination.region(),
    ] {
        hasher.update(part.as_bytes());
        hasher.update([0]);
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use serde_json::json;

    #[test]
    fn engine_resume_mirror_validates_checkpoint_and_deadline() {
        let observed_at = Utc::now();
        let deadline = observed_at + Duration::seconds(1);
        assert!(EngineResumeMirror::new("opaque".into(), observed_at, deadline).is_ok());
        assert!(EngineResumeMirror::new(String::new(), observed_at, deadline).is_err());
        assert!(EngineResumeMirror::new("x".repeat(1025), observed_at, deadline).is_err());
        assert!(EngineResumeMirror::new("opaque".into(), observed_at, observed_at).is_err());
    }

    #[test]
    fn resumable_engine_failure_is_not_finally_terminal() {
        let observed_at = Utc::now();
        let state = AlgoliaImportJobState {
            status: AlgoliaImportJobStatus::Failed,
            publication_disposition: AlgoliaImportPublicationDisposition::Unchanged,
            engine_ack_state: AlgoliaImportEngineAckState::Pending,
            dispatch_intent_state: AlgoliaImportDispatchIntentState::Committed,
            engine_job_id: Some(Uuid::new_v4()),
            lifecycle_generation: 1,
            retryable: true,
            resume_intent_generation: 0,
            resume_mirror: Some(
                EngineResumeMirror::new(
                    "opaque".into(),
                    observed_at,
                    observed_at + Duration::minutes(5),
                )
                .unwrap(),
            ),
            resumable: true,
            resume_count: 0,
            summary: AlgoliaImportSummary::default(),
            warnings: json!([]),
            error_code: Some(AlgoliaImportErrorCode::InvalidCredentials),
            error_message: None,
        };
        assert!(state.validate().is_ok());
        assert!(!state
            .status
            .is_finally_terminal(true, state.publication_disposition));
        let mut acknowledged = state;
        acknowledged.engine_ack_state = AlgoliaImportEngineAckState::Acknowledged;
        assert!(acknowledged.validate().is_err());
    }
}

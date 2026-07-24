use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tracing::warn;
use uuid::Uuid;

use crate::models::index_migration::IndexMigration;
use crate::models::vm_inventory::VmInventory;
use crate::repos::index_migration_repo::IndexMigrationRepo;
use crate::repos::{CatalogLifecycleTargetIdentity, RepoError, TenantRepo, VmInventoryRepo};
use crate::secrets::NodeSecretManager;
use crate::services::alerting::AlertService;
use crate::services::discovery::DiscoveryService;
use crate::services::index_lifecycle_lease::{IndexLifecycleLease, LifecycleGuardPauseHook};
use crate::services::scheduler::{
    MigrationRequest as SchedulerMigrationRequest, SchedulerMigrationService,
};

mod alerting;
mod client;
mod protocol;
mod recovery;
mod replication;
mod validation;

const OPLOG_SEQ_METRIC: &str = "flapjack_oplog_current_seq";

pub use client::{
    MigrationConfig, MigrationHttpClient, MigrationHttpClientError, MigrationHttpRequest,
    MigrationHttpResponse, ReqwestMigrationHttpClient,
};

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationRequest {
    pub index_name: String,
    pub customer_id: Uuid,
    pub source_vm_id: Uuid,
    pub dest_vm_id: Uuid,
    pub requested_by: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationExecutionOutcome {
    pub migration_id: Uuid,
    pub start_replication_auth_header_value: String,
}

#[derive(Debug, Clone)]
struct MigrationIntent {
    row: IndexMigration,
    target_identity: CatalogLifecycleTargetIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationStatus {
    Pending,
    Replicating,
    CuttingOver,
    Completed,
    Failed(String),
    RolledBack,
}

impl MigrationStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Replicating => "replicating",
            Self::CuttingOver => "cutting_over",
            Self::Completed => "completed",
            Self::Failed(_) => "failed",
            Self::RolledBack => "rolled_back",
        }
    }
}

/// Errors that can occur during index migration execution, validation,
/// replication convergence, rollback, or persistence.
#[derive(Debug, thiserror::Error)]
pub enum MigrationError {
    #[error("active migrations limit reached: {active}/{max}")]
    ConcurrencyLimitReached { active: i64, max: u32 },

    #[error("vm not found: {0}")]
    VmNotFound(Uuid),

    #[error("migration not found: {0}")]
    MigrationNotFound(Uuid),

    #[error(
        "rollback window expired for migration {migration_id} (completed_at={completed_at}, deadline={deadline})"
    )]
    RollbackWindowExpired {
        migration_id: Uuid,
        completed_at: chrono::DateTime<chrono::Utc>,
        deadline: chrono::DateTime<chrono::Utc>,
    },

    #[error("rollback unsupported for migration {migration_id} in status '{status}'")]
    RollbackUnsupportedStatus { migration_id: Uuid, status: String },

    #[error("http error: {0}")]
    Http(String),

    #[error("protocol error: {0}")]
    Protocol(String),

    #[error(
        "replication lag timeout for index '{index_name}' after {waited_secs}s (source_seq={source_seq}, dest_seq={dest_seq})"
    )]
    ReplicationLagTimeout {
        index_name: String,
        source_seq: i64,
        dest_seq: i64,
        waited_secs: u64,
    },

    #[error("repo error: {0}")]
    Repo(String),

    #[error("destination_conflict")]
    DestinationConflict,

    #[error("destination_changed")]
    DestinationChanged,
}

pub struct MigrationService {
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    alert_service: Arc<dyn AlertService>,
    discovery_cache: Arc<DiscoveryService>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
    rollback_window: chrono::Duration,
    replication_timeout: Duration,
    replication_poll_interval: Duration,
    replication_near_zero_lag_ops: i64,
    long_running_warning_threshold: Duration,
    max_concurrent: u32,
    lifecycle_lease: Option<Arc<IndexLifecycleLease>>,
    post_intent_pause_hook: Option<LifecycleGuardPauseHook>,
}

#[derive(Debug, Default)]
struct ExecuteProgress {
    replication_started: bool,
    destination_write_admitted: bool,
    start_replication_auth_header_value: Option<String>,
    intent_identity: Option<CatalogLifecycleTargetIdentity>,
}

impl MigrationService {
    /// Creates a [`MigrationService`] with a production reqwest HTTP client
    /// and environment-derived configuration. Delegates to
    /// [`Self::with_http_client_and_config`].
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        discovery_cache: Arc<DiscoveryService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: reqwest::Client,
        max_concurrent: u32,
    ) -> Self {
        Self::with_http_client_and_config(
            tenant_repo,
            vm_inventory_repo,
            migration_repo,
            alert_service,
            discovery_cache,
            node_secret_manager,
            Arc::new(ReqwestMigrationHttpClient::new(http_client)),
            MigrationConfig::from_env(max_concurrent),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_with_lifecycle_lease(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        discovery_cache: Arc<DiscoveryService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: reqwest::Client,
        max_concurrent: u32,
        lifecycle_lease: Arc<IndexLifecycleLease>,
    ) -> Self {
        Self::with_http_client_config_and_lifecycle(
            tenant_repo,
            vm_inventory_repo,
            migration_repo,
            alert_service,
            discovery_cache,
            node_secret_manager,
            Arc::new(ReqwestMigrationHttpClient::new(http_client)),
            MigrationConfig::from_env(max_concurrent),
            Some(lifecycle_lease),
        )
    }

    /// Creates a [`MigrationService`] with an injectable HTTP client and
    /// environment-derived configuration. Used in tests to supply a mock
    /// HTTP client while still reading config from env vars.
    #[allow(clippy::too_many_arguments)]
    pub fn with_http_client(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        discovery_cache: Arc<DiscoveryService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
        max_concurrent: u32,
    ) -> Self {
        Self::with_http_client_and_config(
            tenant_repo,
            vm_inventory_repo,
            migration_repo,
            alert_service,
            discovery_cache,
            node_secret_manager,
            http_client,
            MigrationConfig::from_env(max_concurrent),
        )
    }

    /// Canonical constructor: creates a [`MigrationService`] with fully
    /// explicit HTTP client and [`MigrationConfig`]. All other constructors
    /// delegate here.
    #[allow(clippy::too_many_arguments)]
    pub fn with_http_client_and_config(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        discovery_cache: Arc<DiscoveryService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
        config: MigrationConfig,
    ) -> Self {
        Self::with_http_client_config_and_lifecycle(
            tenant_repo,
            vm_inventory_repo,
            migration_repo,
            alert_service,
            discovery_cache,
            node_secret_manager,
            http_client,
            config,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_http_client_config_and_lifecycle(
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
        alert_service: Arc<dyn AlertService>,
        discovery_cache: Arc<DiscoveryService>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
        config: MigrationConfig,
        lifecycle_lease: Option<Arc<IndexLifecycleLease>>,
    ) -> Self {
        Self {
            tenant_repo,
            vm_inventory_repo,
            migration_repo,
            alert_service,
            discovery_cache,
            node_secret_manager,
            http_client,
            rollback_window: config.rollback_window,
            replication_timeout: config.replication_timeout,
            replication_poll_interval: config.replication_poll_interval,
            replication_near_zero_lag_ops: config.replication_near_zero_lag_ops,
            long_running_warning_threshold: config.long_running_warning_threshold,
            max_concurrent: config.max_concurrent,
            lifecycle_lease,
            post_intent_pause_hook: None,
        }
    }

    pub fn with_post_intent_pause_hook_for_tests(mut self, hook: LifecycleGuardPauseHook) -> Self {
        self.post_intent_pause_hook = Some(hook);
        self
    }

    pub fn max_concurrent(&self) -> u32 {
        self.max_concurrent
    }

    pub fn rollback_window(&self) -> chrono::Duration {
        self.rollback_window
    }

    /// Runs a full index migration: validates the request, checks concurrency
    /// limits, creates a migration record, then drives the replication →
    /// cut-over → finalize protocol. On success marks the migration completed
    /// and sends an info alert; on failure triggers best-effort source
    /// recovery, records the failure, resets the tenant tier, and sends a
    /// critical alert. Returns the migration row ID.
    pub async fn execute(&self, req: MigrationRequest) -> Result<Uuid, MigrationError> {
        self.execute_with_observation(req)
            .await
            .map(|outcome| outcome.migration_id)
    }

    pub async fn execute_with_observation(
        &self,
        req: MigrationRequest,
    ) -> Result<MigrationExecutionOutcome, MigrationError> {
        if let Some(lease) = &self.lifecycle_lease {
            lease
                .admit_mutation(req.customer_id, &req.index_name)
                .await
                .map_err(map_repo_error)?;
        }
        self.ensure_execute_capacity().await?;
        let (source_vm, dest_vm) = self.validate_request(&req).await?;
        let intent = self.begin_migration_intent(&req).await?;
        self.pause_after_migration_intent_for_tests().await;

        let started = Instant::now();
        let mut long_running_warning_sent = false;
        let mut progress = ExecuteProgress {
            intent_identity: Some(intent.target_identity.clone()),
            ..Default::default()
        };

        match self
            .execute_protocol(
                &req,
                intent.row.id,
                &source_vm,
                &dest_vm,
                started,
                &mut long_running_warning_sent,
                &mut progress,
            )
            .await
        {
            Ok(()) => self
                .finish_successful_execute(
                    intent.row.id,
                    &req,
                    started,
                    &mut long_running_warning_sent,
                )
                .await
                .map(|migration_id| MigrationExecutionOutcome {
                    migration_id,
                    start_replication_auth_header_value: progress
                        .start_replication_auth_header_value
                        .unwrap_or_default(),
                }),
            Err(err) => {
                self.handle_execute_failure(
                    intent.row.id,
                    &req,
                    &source_vm,
                    &dest_vm,
                    &err,
                    &progress,
                )
                .await;
                Err(err)
            }
        }
    }

    /// Checks that the number of active (non-terminal) migrations is below
    /// `max_concurrent`. Returns [`MigrationError::ConcurrencyLimitReached`]
    /// if the limit would be exceeded.
    async fn ensure_execute_capacity(&self) -> Result<(), MigrationError> {
        let active = self
            .migration_repo
            .count_active()
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        if active >= self.max_concurrent as i64 {
            return Err(MigrationError::ConcurrencyLimitReached {
                active,
                max: self.max_concurrent,
            });
        }

        Ok(())
    }

    /// Completes a successful migration: checks whether a long-running
    /// warning should be sent, marks the migration record as completed,
    /// and fires an info-severity success alert with duration metadata.
    async fn finish_successful_execute(
        &self,
        migration_id: Uuid,
        req: &MigrationRequest,
        started: Instant,
        long_running_warning_sent: &mut bool,
    ) -> Result<Uuid, MigrationError> {
        self.maybe_send_long_running_warning(req, started, long_running_warning_sent)
            .await;

        self.migration_repo
            .set_completed(migration_id)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;
        self.send_success_alert(req, started.elapsed()).await;
        Ok(migration_id)
    }

    /// Orchestrates failure handling: attempts best-effort source recovery,
    /// records the migration as failed in the repo, resets the tenant tier
    /// back to "active", and sends a critical failure alert.
    async fn handle_execute_failure(
        &self,
        migration_id: Uuid,
        req: &MigrationRequest,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        err: &MigrationError,
        progress: &ExecuteProgress,
    ) {
        let error_message = err.to_string();
        if !is_lifecycle_conflict(err) {
            self.recover_execute_failure(req, source_vm, dest_vm, migration_id, progress)
                .await;
        }
        if !preserves_migration_row_on_failure(err) {
            self.record_failed_execute(migration_id, &error_message)
                .await;
        }
        if !is_lifecycle_conflict(err) {
            self.reset_tenant_tier_after_execute_failure(req, progress.intent_identity.as_ref())
                .await;
        }
        self.send_failure_alert(req, &error_message).await;
    }

    /// Delegates to [`Self::recover_source_on_failure`] and logs a warning
    /// if recovery itself fails. `replication_started` controls whether the
    /// destination index is cleaned up.
    async fn recover_execute_failure(
        &self,
        req: &MigrationRequest,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        migration_id: Uuid,
        progress: &ExecuteProgress,
    ) {
        if let Err(recovery_err) = self
            .recover_source_on_failure(
                req,
                source_vm,
                dest_vm,
                progress.replication_started,
                !progress.destination_write_admitted,
                progress.intent_identity.as_ref(),
            )
            .await
        {
            warn!(
                migration_id = %migration_id,
                customer_id = %req.customer_id,
                index_name = %req.index_name,
                error = %recovery_err,
                "failed best-effort source recovery after migration error"
            );
        }
    }

    /// Persists the "failed" status and error message to the migration record.
    /// Logs a warning if the repo update itself fails (best-effort).
    async fn record_failed_execute(&self, migration_id: Uuid, error_message: &str) {
        if let Err(repo_err) = self
            .migration_repo
            .update_status(
                migration_id,
                MigrationStatus::Failed(error_message.to_string()).as_str(),
                Some(error_message),
            )
            .await
        {
            warn!(
                migration_id = %migration_id,
                error = %repo_err,
                "failed to mark migration as failed"
            );
        }
    }

    async fn reset_tenant_tier_after_execute_failure(
        &self,
        req: &MigrationRequest,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) {
        if let Err(error) = self
            .guarded_target_mutation(
                req.customer_id,
                &req.index_name,
                expected_identity,
                || async {
                    self.tenant_repo
                        .set_tier(req.customer_id, &req.index_name, "active")
                        .await
                },
            )
            .await
        {
            warn!(
                customer_id = %req.customer_id,
                index_name = %req.index_name,
                error = %error,
                "failed to reset tenant tier after migration failure"
            );
        }
    }

    async fn begin_migration_intent(
        &self,
        req: &MigrationRequest,
    ) -> Result<MigrationIntent, MigrationError> {
        let expected_identity = self
            .target_identity(req.customer_id, &req.index_name)
            .await?;
        let mut intent_identity = expected_identity.clone();
        intent_identity.tier = "migrating".to_string();
        self.guarded_target_mutation(
            req.customer_id,
            &req.index_name,
            Some(&expected_identity),
            || async {
                let mut row = self.migration_repo.create(req).await?;
                let metadata = row.metadata_with_intent_target_identity(&intent_identity);
                self.migration_repo
                    .update_metadata(row.id, metadata.clone())
                    .await?;
                row.metadata = metadata;
                self.tenant_repo
                    .set_tier(req.customer_id, &req.index_name, "migrating")
                    .await?;
                self.migration_repo
                    .update_status(row.id, MigrationStatus::Replicating.as_str(), None)
                    .await?;
                row.status = MigrationStatus::Replicating.as_str().to_string();
                Ok(MigrationIntent {
                    row,
                    target_identity: intent_identity,
                })
            },
        )
        .await
    }

    pub(super) async fn pause_after_migration_intent_for_tests(&self) {
        if let Some(hook) = &self.post_intent_pause_hook {
            hook().await;
        }
    }

    async fn target_identity(
        &self,
        customer_id: Uuid,
        index_name: &str,
    ) -> Result<CatalogLifecycleTargetIdentity, MigrationError> {
        let tenant = self
            .tenant_repo
            .find_raw(customer_id, index_name)
            .await
            .map_err(map_repo_error)?
            .ok_or_else(|| {
                MigrationError::Protocol(format!(
                    "tenant '{index_name}' for customer '{customer_id}' disappeared before migration intent"
                ))
            })?;
        Ok(CatalogLifecycleTargetIdentity {
            deployment_id: tenant.deployment_id,
            vm_id: tenant.vm_id,
            tier: tenant.tier,
            cold_snapshot_id: tenant.cold_snapshot_id,
            service_type: tenant.service_type,
        })
    }

    pub(super) async fn guarded_target_mutation<F, Fut, T>(
        &self,
        customer_id: Uuid,
        index_name: &str,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
        mutation: F,
    ) -> Result<T, MigrationError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, RepoError>>,
    {
        match &self.lifecycle_lease {
            Some(lease) => lease
                .guarded_mutation(customer_id, index_name, expected_identity, mutation)
                .await
                .map_err(map_repo_error),
            None => mutation().await.map_err(map_repo_error),
        }
    }
}

fn is_lifecycle_conflict(error: &MigrationError) -> bool {
    matches!(
        error,
        MigrationError::DestinationConflict | MigrationError::DestinationChanged
    )
}

fn preserves_migration_row_on_failure(error: &MigrationError) -> bool {
    matches!(error, MigrationError::DestinationChanged)
}

pub(super) fn map_repo_error(error: RepoError) -> MigrationError {
    match error {
        RepoError::Conflict(message) if message == "destination_conflict" => {
            MigrationError::DestinationConflict
        }
        RepoError::Conflict(message) if message == "destination_changed" => {
            MigrationError::DestinationChanged
        }
        other => MigrationError::Repo(other.to_string()),
    }
}

#[async_trait]
impl SchedulerMigrationService for MigrationService {
    async fn request_migration(&self, req: SchedulerMigrationRequest) -> Result<(), String> {
        self.execute(MigrationRequest {
            index_name: req.index_name,
            customer_id: req.customer_id,
            source_vm_id: req.source_vm_id,
            dest_vm_id: req.dest_vm_id,
            requested_by: req.reason,
        })
        .await
        .map(|_| ())
        .map_err(|err| err.to_string())
    }
}

fn endpoint_url(base: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_url_trims_trailing_slash() {
        let url = endpoint_url("http://node:7700/", "/internal/health");
        assert_eq!(url, "http://node:7700/internal/health");
    }

    #[test]
    fn endpoint_url_handles_no_slashes() {
        let url = endpoint_url("http://node:7700", "internal/health");
        assert_eq!(url, "http://node:7700/internal/health");
    }

    #[test]
    fn endpoint_url_double_slash_normalized() {
        let url = endpoint_url("http://node:7700/", "/health");
        assert_eq!(url, "http://node:7700/health");
    }

    #[test]
    fn migration_status_as_str_all_variants() {
        assert_eq!(MigrationStatus::Pending.as_str(), "pending");
        assert_eq!(MigrationStatus::Replicating.as_str(), "replicating");
        assert_eq!(MigrationStatus::CuttingOver.as_str(), "cutting_over");
        assert_eq!(MigrationStatus::Completed.as_str(), "completed");
        assert_eq!(
            MigrationStatus::Failed("something broke".into()).as_str(),
            "failed"
        );
        assert_eq!(MigrationStatus::RolledBack.as_str(), "rolled_back");
    }

    #[test]
    fn migration_error_display_concurrency_limit() {
        let err = MigrationError::ConcurrencyLimitReached { active: 3, max: 3 };
        assert_eq!(err.to_string(), "active migrations limit reached: 3/3");
    }

    #[test]
    fn migration_error_display_vm_not_found() {
        let id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let err = MigrationError::VmNotFound(id);
        assert!(err.to_string().contains("550e8400"));
    }

    #[test]
    fn migration_error_display_http() {
        let err = MigrationError::Http("timeout".into());
        assert_eq!(err.to_string(), "http error: timeout");
    }

    #[test]
    fn migration_error_display_repo() {
        let err = MigrationError::Repo("connection refused".into());
        assert_eq!(err.to_string(), "repo error: connection refused");
    }

    #[test]
    fn migration_status_equality() {
        assert_eq!(MigrationStatus::Pending, MigrationStatus::Pending);
        assert_ne!(MigrationStatus::Pending, MigrationStatus::Completed);
        assert_eq!(
            MigrationStatus::Failed("a".into()),
            MigrationStatus::Failed("a".into())
        );
        assert_ne!(
            MigrationStatus::Failed("a".into()),
            MigrationStatus::Failed("b".into())
        );
    }
}

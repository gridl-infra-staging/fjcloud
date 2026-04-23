//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/mod.rs.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use reqwest::Method;
use tracing::warn;
use uuid::Uuid;

use crate::models::vm_inventory::VmInventory;
use crate::repos::index_migration_repo::IndexMigrationRepo;
use crate::repos::{TenantRepo, VmInventoryRepo};
use crate::secrets::NodeSecretManager;
use crate::services::alerting::AlertService;
use crate::services::discovery::DiscoveryService;
use crate::services::scheduler::{
    MigrationRequest as SchedulerMigrationRequest, SchedulerMigrationService,
};

mod alerting;
mod protocol;
mod recovery;
mod replication;
mod validation;

const DEFAULT_ROLLBACK_WINDOW_SECS: i64 = 300;
const DEFAULT_REPLICATION_TIMEOUT_SECS: u64 = 600;
const DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS: u64 = 2000;
const DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS: i64 = 10;
const DEFAULT_LONG_RUNNING_WARNING_SECS: u64 = 600;
const OPLOG_SEQ_METRIC: &str = "flapjack_oplog_current_seq";

#[derive(Debug, Clone)]
pub struct MigrationConfig {
    pub max_concurrent: u32,
    pub rollback_window: chrono::Duration,
    pub replication_timeout: Duration,
    pub replication_poll_interval: Duration,
    pub replication_near_zero_lag_ops: i64,
    pub long_running_warning_threshold: Duration,
}

impl MigrationConfig {
    /// Builds a [`MigrationConfig`] from environment variables, falling back
    /// to compiled defaults for any variable that is unset or unparseable.
    ///
    /// Reads `MIGRATION_ROLLBACK_WINDOW_SECS`, `MIGRATION_REPLICATION_TIMEOUT_SECS`,
    /// `MIGRATION_REPLICATION_POLL_INTERVAL_MILLIS`, `MIGRATION_REPLICATION_NEAR_ZERO_LAG_OPS`,
    /// and `MIGRATION_LONG_RUNNING_WARNING_SECS`. The caller supplies `max_concurrent`
    /// directly (typically from a higher-level config source).
    pub fn from_env(max_concurrent: u32) -> Self {
        let rollback_secs = env_i64(
            "MIGRATION_ROLLBACK_WINDOW_SECS",
            DEFAULT_ROLLBACK_WINDOW_SECS,
        );
        let replication_timeout_secs = env_u64(
            "MIGRATION_REPLICATION_TIMEOUT_SECS",
            DEFAULT_REPLICATION_TIMEOUT_SECS,
        );
        let replication_poll_interval_ms = env_u64(
            "MIGRATION_REPLICATION_POLL_INTERVAL_MILLIS",
            DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS,
        );
        let replication_near_zero_lag_ops = env_i64(
            "MIGRATION_REPLICATION_NEAR_ZERO_LAG_OPS",
            DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS,
        );
        let long_running_warning_secs = env_u64(
            "MIGRATION_LONG_RUNNING_WARNING_SECS",
            DEFAULT_LONG_RUNNING_WARNING_SECS,
        );

        Self {
            max_concurrent,
            rollback_window: chrono::Duration::seconds(rollback_secs),
            replication_timeout: Duration::from_secs(replication_timeout_secs),
            replication_poll_interval: Duration::from_millis(replication_poll_interval_ms),
            replication_near_zero_lag_ops,
            long_running_warning_threshold: Duration::from_secs(long_running_warning_secs),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationRequest {
    pub index_name: String,
    pub customer_id: Uuid,
    pub source_vm_id: Uuid,
    pub dest_vm_id: Uuid,
    pub requested_by: String,
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
}

#[derive(Debug, thiserror::Error, Clone, PartialEq)]
pub enum MigrationHttpClientError {
    #[error("http timeout")]
    Timeout,
    #[error("unreachable: {0}")]
    Unreachable(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationHttpRequest {
    pub method: Method,
    pub url: String,
    pub json_body: Option<serde_json::Value>,
    pub headers: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MigrationHttpResponse {
    pub status: u16,
    pub body: String,
}

#[async_trait]
pub trait MigrationHttpClient: Send + Sync {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError>;
}

pub struct ReqwestMigrationHttpClient {
    client: reqwest::Client,
}

impl ReqwestMigrationHttpClient {
    pub fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl MigrationHttpClient for ReqwestMigrationHttpClient {
    /// Sends a [`MigrationHttpRequest`] via reqwest, mapping transport
    /// failures to [`MigrationHttpClientError::Timeout`] or
    /// [`MigrationHttpClientError::Unreachable`]. Returns the raw status
    /// code and response body on success.
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        let mut req = self.client.request(request.method, &request.url);
        for (key, value) in &request.headers {
            req = req.header(key, value);
        }
        if let Some(body) = request.json_body {
            req = req.json(&body);
        }

        let response = req.send().await.map_err(|e| {
            if e.is_timeout() {
                MigrationHttpClientError::Timeout
            } else {
                MigrationHttpClientError::Unreachable(e.to_string())
            }
        })?;

        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .map_err(|e| MigrationHttpClientError::Unreachable(e.to_string()))?;

        Ok(MigrationHttpResponse { status, body })
    }
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
        }
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
        self.ensure_execute_capacity().await?;
        let (source_vm, dest_vm) = self.validate_request(&req).await?;
        let row = self
            .migration_repo
            .create(&req)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        let started = Instant::now();
        let mut long_running_warning_sent = false;
        let mut replication_started = false;

        match self
            .execute_protocol(
                &req,
                row.id,
                &source_vm,
                &dest_vm,
                started,
                &mut long_running_warning_sent,
                &mut replication_started,
            )
            .await
        {
            Ok(()) => {
                self.finish_successful_execute(
                    row.id,
                    &req,
                    started,
                    &mut long_running_warning_sent,
                )
                .await
            }
            Err(err) => {
                self.handle_execute_failure(
                    row.id,
                    &req,
                    &source_vm,
                    &dest_vm,
                    &err,
                    replication_started,
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
        replication_started: bool,
    ) {
        let error_message = err.to_string();
        self.recover_execute_failure(req, source_vm, dest_vm, migration_id, replication_started)
            .await;
        self.record_failed_execute(migration_id, &error_message)
            .await;
        self.reset_tenant_tier_after_execute_failure(req).await;
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
        replication_started: bool,
    ) {
        if let Err(recovery_err) = self
            .recover_source_on_failure(req, source_vm, dest_vm, replication_started)
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

    async fn reset_tenant_tier_after_execute_failure(&self, req: &MigrationRequest) {
        if let Err(repo_err) = self
            .tenant_repo
            .set_tier(req.customer_id, &req.index_name, "active")
            .await
        {
            warn!(
                customer_id = %req.customer_id,
                index_name = %req.index_name,
                error = %repo_err,
                "failed to reset tenant tier after migration failure"
            );
        }
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

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
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
    fn migration_http_client_error_display() {
        assert_eq!(
            MigrationHttpClientError::Timeout.to_string(),
            "http timeout"
        );
        let err = MigrationHttpClientError::Unreachable("dns failure".into());
        assert_eq!(err.to_string(), "unreachable: dns failure");
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

    #[test]
    fn default_constants_are_positive() {
        const { assert!(DEFAULT_ROLLBACK_WINDOW_SECS > 0) };
        const { assert!(DEFAULT_REPLICATION_TIMEOUT_SECS > 0) };
        const { assert!(DEFAULT_REPLICATION_POLL_INTERVAL_MILLIS > 0) };
        const { assert!(DEFAULT_REPLICATION_NEAR_ZERO_LAG_OPS > 0) };
        const { assert!(DEFAULT_LONG_RUNNING_WARNING_SECS > 0) };
    }
}

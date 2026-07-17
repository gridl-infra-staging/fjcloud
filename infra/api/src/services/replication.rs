use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use reqwest::Method;
use serde_json::json;
use tokio::sync::watch;
use tracing::{info, warn};

use crate::models::index_replica::IndexReplica;
use crate::models::vm_inventory::VmInventory;
use crate::repos::index_replica_repo::IndexReplicaRepo;
use crate::repos::vm_inventory_repo::VmInventoryRepo;
use crate::secrets::NodeSecretManager;
use crate::services::migration::{
    MigrationHttpClient, MigrationHttpClientError, MigrationHttpRequest, MigrationHttpResponse,
};
use crate::services::prometheus_parser::{extract_label, parse_metrics};
use crate::services::replication_error::{
    classify_response as classify_error_response, INTERNAL_APP_ID_HEADER, INTERNAL_AUTH_HEADER,
    REPLICATION_APP_ID,
};

const STATUS_PROVISIONING: &str = "provisioning";
const STATUS_SYNCING: &str = "syncing";
const STATUS_REPLICATING: &str = "replicating";
const STATUS_ACTIVE: &str = "active";
const STATUS_FAILED: &str = "failed";
const OPLOG_SEQ_METRIC: &str = "flapjack_oplog_current_seq";

const MAX_CONSECUTIVE_AUTH_FAILURES: u32 = 5;

const DEFAULT_CYCLE_INTERVAL_SECS: u64 = 30;
const DEFAULT_NEAR_ZERO_LAG_OPS: i64 = 100;
const DEFAULT_MAX_ACCEPTABLE_LAG_OPS: i64 = 100_000;
const DEFAULT_SYNCING_TIMEOUT_SECS: u64 = 3600;

#[derive(Debug, Clone)]
pub struct ReplicationConfig {
    /// How often the orchestrator runs a cycle, in seconds.
    pub cycle_interval_secs: u64,
    /// Lag threshold below which a syncing replica transitions to active.
    pub near_zero_lag_ops: i64,
    /// Lag threshold above which an active replica is marked failed.
    pub max_acceptable_lag_ops: i64,
    /// Maximum time a replica can stay in syncing before being marked failed.
    pub syncing_timeout_secs: u64,
}

impl Default for ReplicationConfig {
    fn default() -> Self {
        Self {
            cycle_interval_secs: DEFAULT_CYCLE_INTERVAL_SECS,
            near_zero_lag_ops: DEFAULT_NEAR_ZERO_LAG_OPS,
            max_acceptable_lag_ops: DEFAULT_MAX_ACCEPTABLE_LAG_OPS,
            syncing_timeout_secs: DEFAULT_SYNCING_TIMEOUT_SECS,
        }
    }
}

impl ReplicationConfig {
    pub fn from_env() -> Self {
        Self::from_reader(|key| std::env::var(key).ok())
    }

    /// Reads replication configuration from environment variables via the `ConfigReader`.
    ///
    /// Parses cycle interval, replication lag thresholds (near-zero and max), and
    /// syncing timeout. Falls back to compiled defaults for any missing or
    /// unparseable values.
    pub fn from_reader<F>(read: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        let cycle_interval_secs = read("REPLICATION_CYCLE_INTERVAL_SECS")
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_CYCLE_INTERVAL_SECS);
        let near_zero_lag_ops = read("REPLICATION_NEAR_ZERO_LAG_OPS")
            .and_then(|v| v.parse::<i64>().ok())
            .filter(|v| *v >= 0)
            .unwrap_or(DEFAULT_NEAR_ZERO_LAG_OPS);
        let max_acceptable_lag_ops = read("REPLICATION_MAX_ACCEPTABLE_LAG_OPS")
            .and_then(|v| v.parse::<i64>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_MAX_ACCEPTABLE_LAG_OPS);
        let syncing_timeout_secs = read("REPLICATION_SYNCING_TIMEOUT_SECS")
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| *v > 0)
            .unwrap_or(DEFAULT_SYNCING_TIMEOUT_SECS);

        Self {
            cycle_interval_secs,
            near_zero_lag_ops,
            max_acceptable_lag_ops,
            syncing_timeout_secs,
        }
    }
}

pub use crate::services::replication_error::ReplicationError;

pub fn classify_response(
    response: MigrationHttpResponse,
) -> Result<MigrationHttpResponse, ReplicationError> {
    if (200..300).contains(&response.status) {
        return Ok(response);
    }

    Err(classify_error_response(response.status, &response.body))
}

fn classify_client_error(error: MigrationHttpClientError) -> ReplicationError {
    match error {
        MigrationHttpClientError::Timeout => ReplicationError::Timeout,
        MigrationHttpClientError::Unreachable(msg) => ReplicationError::TransportError(msg),
    }
}

pub fn classify_replication_result(
    result: Result<MigrationHttpResponse, MigrationHttpClientError>,
) -> Result<MigrationHttpResponse, ReplicationError> {
    match result {
        Ok(response) => classify_response(response),
        Err(error) => Err(classify_client_error(error)),
    }
}

pub struct ReplicationOrchestrator {
    replica_repo: Arc<dyn IndexReplicaRepo>,
    vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    config: ReplicationConfig,
    auth_failure_counts: std::sync::Mutex<HashMap<uuid::Uuid, u32>>,
}

impl ReplicationOrchestrator {
    /// Constructs a new orchestrator with the given repos (index replica,
    /// VM inventory), HTTP client, secret manager, and config.
    pub fn new(
        replica_repo: Arc<dyn IndexReplicaRepo>,
        vm_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        config: ReplicationConfig,
    ) -> Self {
        Self {
            replica_repo,
            vm_repo,
            http_client,
            node_secret_manager,
            config,
            auth_failure_counts: std::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Run the orchestrator loop until shutdown is signaled.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        info!(
            cycle_interval_secs = self.config.cycle_interval_secs,
            syncing_timeout_secs = self.config.syncing_timeout_secs,
            "replication orchestrator started"
        );

        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(self.config.cycle_interval_secs)) => {
                    self.run_cycle().await;
                }
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("replication orchestrator shutting down");
                        return;
                    }
                }
            }
        }
    }

    /// Run one orchestration cycle: scan all replicas and drive state transitions.
    pub async fn run_cycle(&self) {
        let replicas = match self.replica_repo.list_actionable().await {
            Ok(replicas) => replicas,
            Err(err) => {
                warn!(error = %err, "replication orchestrator failed to list actionable replicas");
                return;
            }
        };

        for replica in replicas {
            match replica.status.as_str() {
                STATUS_PROVISIONING => self.handle_provisioning(replica).await,
                STATUS_SYNCING | STATUS_REPLICATING | STATUS_ACTIVE => {
                    if matches!(replica.status.as_str(), STATUS_SYNCING | STATUS_REPLICATING)
                        && self.is_syncing_timed_out(&replica)
                    {
                        self.mark_failed(
                            replica.id,
                            &format!(
                                "syncing replica timed out after {}s",
                                self.config.syncing_timeout_secs
                            ),
                        )
                        .await;
                    } else {
                        self.handle_lag_monitoring(replica).await;
                    }
                }
                _ => {}
            }
        }
    }

    fn is_syncing_timed_out(&self, replica: &IndexReplica) -> bool {
        let elapsed = Utc::now()
            .signed_duration_since(replica.updated_at)
            .num_seconds();
        elapsed > self.config.syncing_timeout_secs as i64
    }

    async fn handle_provisioning(&self, replica: IndexReplica) {
        let (source_vm, replica_vm) = match self.load_replica_vms(&replica).await {
            Ok(vms) => vms,
            Err(err) => {
                self.mark_failed(replica.id, &err).await;
                return;
            }
        };

        let headers = match self.build_auth_headers(&replica_vm).await {
            Ok(h) => h,
            Err(err) => {
                self.mark_failed(
                    replica.id,
                    &format!(
                        "failed to load internal key for replica {}: {}",
                        replica_vm.id, err
                    ),
                )
                .await;
                self.clear_auth_failure(replica.id);
                return;
            }
        };

        self.initiate_replication(&replica, &source_vm, &replica_vm, headers)
            .await;
    }

    /// Sends a POST to `/internal/replicate` and processes the result:
    /// transitions to syncing on success, applies auth-failure circuit breaker,
    /// or marks failed on other errors.
    async fn initiate_replication(
        &self,
        replica: &IndexReplica,
        source_vm: &VmInventory,
        replica_vm: &VmInventory,
        headers: HashMap<String, String>,
    ) {
        let request = MigrationHttpRequest {
            method: Method::POST,
            url: endpoint_url(&replica_vm.flapjack_url, "/internal/replicate"),
            json_body: Some(json!({
                "index_name": replica.tenant_id,
                "source_flapjack_url": source_vm.flapjack_url
            })),
            headers,
        };

        let result = classify_replication_result(self.http_client.send(request).await);

        match result {
            Ok(_response) => {
                self.clear_auth_failure(replica.id);
                if let Err(err) = self
                    .replica_repo
                    .set_status(replica.id, STATUS_SYNCING)
                    .await
                {
                    warn!(replica_id = %replica.id, error = %err, "failed to update replica status to syncing");
                }
            }
            Err(ReplicationError::AuthFailed(ref msg)) => {
                let count = self.increment_auth_failure(replica.id);
                if count >= MAX_CONSECUTIVE_AUTH_FAILURES {
                    self.mark_failed(
                        replica.id,
                        &format!("replication auth failed after {} attempts: {}", count, msg),
                    )
                    .await;
                    self.clear_auth_failure(replica.id);
                }
            }
            Err(ref err) => {
                self.mark_failed(replica.id, &err.to_string()).await;
                self.clear_auth_failure(replica.id);
            }
        }
    }

    /// Fetches the current replication lag for a syncing or active replica. Promotes
    /// `syncing` replicas to `active` when lag is at or below the near-zero threshold.
    /// Marks `active` replicas as failed when lag exceeds the max threshold.
    /// Canonicalizes legacy `replicating` status to `syncing` during convergence.
    async fn handle_lag_monitoring(&self, replica: IndexReplica) {
        let lag = match self.fetch_replication_lag(&replica).await {
            Ok(lag) => lag,
            Err(err) => {
                self.mark_failed(replica.id, &err).await;
                return;
            }
        };

        if let Err(err) = self.replica_repo.set_lag(replica.id, lag).await {
            warn!(replica_id = %replica.id, error = %err, lag_ops = lag, "failed to update replica lag");
        }

        if matches!(replica.status.as_str(), STATUS_SYNCING | STATUS_REPLICATING)
            && lag <= self.config.near_zero_lag_ops
        {
            if let Err(err) = self
                .replica_repo
                .set_status(replica.id, STATUS_ACTIVE)
                .await
            {
                warn!(replica_id = %replica.id, error = %err, "failed to activate synced replica");
            }
            return;
        }

        // Canonicalize legacy "replicating" → "syncing" during normal convergence
        if replica.status == STATUS_REPLICATING {
            if let Err(err) = self
                .replica_repo
                .set_status(replica.id, STATUS_SYNCING)
                .await
            {
                warn!(replica_id = %replica.id, error = %err, "failed to canonicalize replicating → syncing");
            }
        }

        if replica.status == STATUS_ACTIVE && lag > self.config.max_acceptable_lag_ops {
            self.mark_failed(
                replica.id,
                &format!(
                    "replica lag {} exceeds max acceptable lag {}",
                    lag, self.config.max_acceptable_lag_ops
                ),
            )
            .await;
        }
    }

    async fn fetch_replication_lag(&self, replica: &IndexReplica) -> Result<i64, String> {
        let (source_vm, replica_vm) = self.load_replica_vms(replica).await?;
        let source_seq = self.fetch_oplog_seq(&source_vm, &replica.tenant_id).await?;
        let replica_seq = self
            .fetch_oplog_seq(&replica_vm, &replica.tenant_id)
            .await?;
        Ok((source_seq - replica_seq).abs())
    }

    async fn load_replica_vms(
        &self,
        replica: &IndexReplica,
    ) -> Result<(VmInventory, VmInventory), String> {
        let source_vm = self.load_vm(replica.primary_vm_id).await?;
        let replica_vm = self.load_vm(replica.replica_vm_id).await?;
        Ok((source_vm, replica_vm))
    }

    async fn load_vm(&self, vm_id: uuid::Uuid) -> Result<VmInventory, String> {
        self.vm_repo
            .get(vm_id)
            .await
            .map_err(|err| format!("failed to load vm {vm_id}: {err}"))?
            .ok_or_else(|| format!("vm not found: {vm_id}"))
    }

    /// GETs the `/metrics` endpoint on a flapjack VM and parses the Prometheus text
    /// output to extract the `flapjack_oplog_current_seq` gauge value for the specified
    /// index. Returns an error if the metric is missing or the response cannot be parsed.
    async fn fetch_oplog_seq(&self, vm: &VmInventory, index_name: &str) -> Result<i64, String> {
        let metrics_url = endpoint_url(&vm.flapjack_url, "/metrics");
        let headers = self
            .build_auth_headers(vm)
            .await
            .map_err(|err| format!("failed to load internal key for vm {}: {}", vm.id, err))?;

        let response = classify_replication_result(
            self.http_client
                .send(MigrationHttpRequest {
                    method: Method::GET,
                    url: metrics_url.clone(),
                    json_body: None,
                    headers,
                })
                .await,
        )
        .map_err(|err| format!("metrics request failed for {metrics_url}: {err}"))?;

        let parsed = parse_metrics(&response.body);
        let Some(series) = parsed.get(OPLOG_SEQ_METRIC) else {
            return Err(format!(
                "metric '{OPLOG_SEQ_METRIC}' missing for index '{index_name}'"
            ));
        };

        for (labels, value) in series {
            if extract_label(labels, "index").as_deref() == Some(index_name) {
                return Ok((*value).floor() as i64);
            }
        }

        Err(format!(
            "metric '{OPLOG_SEQ_METRIC}' missing index label for '{index_name}'"
        ))
    }

    async fn mark_failed(&self, replica_id: uuid::Uuid, reason: &str) {
        warn!(replica_id = %replica_id, reason, "replication orchestrator marking replica failed");
        if let Err(err) = self
            .replica_repo
            .set_status(replica_id, STATUS_FAILED)
            .await
        {
            warn!(replica_id = %replica_id, error = %err, "failed to set replica status to failed");
        }
    }

    fn increment_auth_failure(&self, replica_id: uuid::Uuid) -> u32 {
        let mut counts = self.auth_failure_counts.lock().unwrap();
        let count = counts.entry(replica_id).or_insert(0);
        *count += 1;
        *count
    }

    fn clear_auth_failure(&self, replica_id: uuid::Uuid) {
        let mut counts = self.auth_failure_counts.lock().unwrap();
        counts.remove(&replica_id);
    }

    /// Loads the node API key from the secret manager and constructs HTTP headers
    /// containing `x-algolia-api-key` and `x-algolia-application-id` for authenticating
    /// requests to flapjack VMs.
    async fn build_auth_headers(
        &self,
        vm: &VmInventory,
    ) -> Result<HashMap<String, String>, crate::secrets::NodeSecretError> {
        let key = self
            .node_secret_manager
            .get_node_api_key(&vm.id.to_string(), &vm.region)
            .await?;
        let mut headers = HashMap::new();
        headers.insert(INTERNAL_AUTH_HEADER.to_string(), key);
        headers.insert(
            INTERNAL_APP_ID_HEADER.to_string(),
            REPLICATION_APP_ID.to_string(),
        );
        Ok(headers)
    }
}

fn endpoint_url(base: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use std::time::Duration as StdDuration;
use tokio::sync::watch;

use crate::helpers::parse_with_default;
use crate::models::tenant::CustomerTenant;
use crate::repos::{
    CatalogLifecycleTargetIdentity, ColdSnapshotRepo, IndexMigrationRepo, RepoError, TenantRepo,
    VmInventoryRepo,
};
use crate::secrets::NodeSecretManager;
use crate::services::alerting::AlertService;
use crate::services::discovery::DiscoveryService;
use crate::services::index_lifecycle_lease::{IndexLifecycleLease, LifecycleGuardPauseHook};
use crate::services::object_store::RegionObjectStoreResolver;

mod node_client;
mod pipeline;

pub use self::node_client::{FlapjackNodeClient, ReqwestNodeClient};

const DEFAULT_IDLE_THRESHOLD_DAYS: u64 = 30;
const DEFAULT_CYCLE_INTERVAL_SECS: u64 = 3600;
const DEFAULT_MAX_CONCURRENT_SNAPSHOTS: u32 = 2;
const DEFAULT_SNAPSHOT_TIMEOUT_SECS: u64 = 600;
const DEFAULT_MAX_SNAPSHOT_RETRIES: u32 = 3;
const DEFAULT_MAX_CANDIDATES_PER_CYCLE: u32 = 5;

#[derive(Debug, Clone, PartialEq)]
pub struct ColdTierConfig {
    pub idle_threshold_days: u64,
    pub cycle_interval_secs: u64,
    pub max_concurrent_snapshots: u32,
    pub snapshot_timeout_secs: u64,
    pub max_snapshot_retries: u32,
    pub max_candidates_per_cycle: u32,
}

impl Default for ColdTierConfig {
    fn default() -> Self {
        Self {
            idle_threshold_days: DEFAULT_IDLE_THRESHOLD_DAYS,
            cycle_interval_secs: DEFAULT_CYCLE_INTERVAL_SECS,
            max_concurrent_snapshots: DEFAULT_MAX_CONCURRENT_SNAPSHOTS,
            snapshot_timeout_secs: DEFAULT_SNAPSHOT_TIMEOUT_SECS,
            max_snapshot_retries: DEFAULT_MAX_SNAPSHOT_RETRIES,
            max_candidates_per_cycle: DEFAULT_MAX_CANDIDATES_PER_CYCLE,
        }
    }
}

impl ColdTierConfig {
    pub fn from_env() -> Self {
        Self::from_reader(|key| std::env::var(key).ok())
    }

    /// Builds a [`ColdTierConfig`] from a key-value reader function (typically
    /// backed by environment variables). Falls back to compiled defaults for
    /// any missing or unparseable value.
    pub fn from_reader<F>(read: F) -> Self
    where
        F: Fn(&str) -> Option<String>,
    {
        Self {
            idle_threshold_days: parse_with_default(
                &read,
                "COLD_TIER_IDLE_THRESHOLD_DAYS",
                DEFAULT_IDLE_THRESHOLD_DAYS,
            ),
            cycle_interval_secs: parse_with_default(
                &read,
                "COLD_TIER_CYCLE_INTERVAL_SECS",
                DEFAULT_CYCLE_INTERVAL_SECS,
            ),
            max_concurrent_snapshots: parse_with_default(
                &read,
                "COLD_TIER_MAX_CONCURRENT_SNAPSHOTS",
                DEFAULT_MAX_CONCURRENT_SNAPSHOTS,
            ),
            snapshot_timeout_secs: parse_with_default(
                &read,
                "COLD_TIER_SNAPSHOT_TIMEOUT_SECS",
                DEFAULT_SNAPSHOT_TIMEOUT_SECS,
            ),
            max_snapshot_retries: parse_with_default(
                &read,
                "COLD_TIER_MAX_SNAPSHOT_RETRIES",
                DEFAULT_MAX_SNAPSHOT_RETRIES,
            ),
            max_candidates_per_cycle: parse_with_default(
                &read,
                "COLD_TIER_MAX_CANDIDATES_PER_CYCLE",
                DEFAULT_MAX_CANDIDATES_PER_CYCLE,
            ),
        }
    }
}

/// Errors that can occur during cold-tier snapshot operations: repository
/// persistence, index export, S3 upload, node eviction, import, or
/// post-import verification.
#[derive(Debug, thiserror::Error)]
pub enum ColdTierError {
    #[error("repo error: {0}")]
    Repo(String),

    #[error("destination_conflict")]
    DestinationConflict,

    #[error("destination_changed")]
    DestinationChanged,

    #[error("export error: {0}")]
    Export(String),

    #[error("upload error: {0}")]
    Upload(String),

    #[error("evict error: {0}")]
    Evict(String),

    #[error("import error: {0}")]
    Import(String),

    #[error("verify error: {0}")]
    Verify(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColdTierCandidate {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub source_vm_id: Uuid,
    pub last_accessed_at: Option<DateTime<Utc>>,
    catalog_identity: CatalogLifecycleTargetIdentity,
}

impl ColdTierCandidate {
    /// Builds a candidate while capturing the exact catalog identity that its
    /// lifecycle mutations must continue to own.
    pub fn from_tenant(tenant: &CustomerTenant) -> Option<Self> {
        Some(Self {
            customer_id: tenant.customer_id,
            tenant_id: tenant.tenant_id.clone(),
            source_vm_id: tenant.vm_id?,
            last_accessed_at: tenant.last_accessed_at,
            catalog_identity: identity_from_tenant(tenant),
        })
    }

    fn cold_intent_identity(&self) -> CatalogLifecycleTargetIdentity {
        CatalogLifecycleTargetIdentity {
            tier: "cold".to_string(),
            ..self.catalog_identity.clone()
        }
    }

    fn published_cold_identity(&self, snapshot_id: Uuid) -> CatalogLifecycleTargetIdentity {
        CatalogLifecycleTargetIdentity {
            vm_id: None,
            cold_snapshot_id: Some(snapshot_id),
            ..self.cold_intent_identity()
        }
    }
}

pub struct ColdTierDependencies {
    pub tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    pub index_migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    pub cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    pub vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    pub object_store_resolver: Arc<RegionObjectStoreResolver>,
    pub alert_service: Arc<dyn AlertService>,
    pub discovery_service: Arc<DiscoveryService>,
    pub node_client: Arc<dyn FlapjackNodeClient>,
    pub node_secret_manager: Arc<dyn NodeSecretManager>,
    pub lifecycle_lease: Option<Arc<IndexLifecycleLease>>,
}

pub struct ColdTierService {
    config: ColdTierConfig,
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    index_migration_repo: Arc<dyn IndexMigrationRepo + Send + Sync>,
    cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    object_store_resolver: Arc<RegionObjectStoreResolver>,
    alert_service: Arc<dyn AlertService>,
    discovery_service: Arc<DiscoveryService>,
    node_client: Arc<dyn FlapjackNodeClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    lifecycle_lease: Option<Arc<IndexLifecycleLease>>,
    /// Test-only pause hooks fired inside the matching guarded closure, after
    /// the lifecycle guard is acquired and before the guarded mutation runs.
    /// Unlike `ReplicaService`/`RestoreService`, a single cold-tier operation
    /// opens two guarded windows (snapshot intent, then cold publication) plus
    /// a compensation window, so each phase carries its own optional hook to let
    /// a test pause exactly one window without cross-firing. Production always
    /// leaves these `None`.
    begin_snapshot_pause_hook: Option<LifecycleGuardPauseHook>,
    cold_publication_pause_hook: Option<LifecycleGuardPauseHook>,
    rollback_pause_hook: Option<LifecycleGuardPauseHook>,
    /// Track retry counts per (customer_id, tenant_id) — resets on success.
    retry_counts: std::sync::Mutex<HashMap<(Uuid, String), u32>>,
}

impl ColdTierService {
    /// Creates a [`ColdTierService`] from a config and dependency bundle.
    /// Destructures the [`ColdTierDependencies`] into owned fields and
    /// initializes an empty retry-count tracker.
    pub fn new(config: ColdTierConfig, dependencies: ColdTierDependencies) -> Self {
        let ColdTierDependencies {
            tenant_repo,
            index_migration_repo,
            cold_snapshot_repo,
            vm_inventory_repo,
            object_store_resolver,
            alert_service,
            discovery_service,
            node_client,
            node_secret_manager,
            lifecycle_lease,
        } = dependencies;

        Self {
            config,
            tenant_repo,
            index_migration_repo,
            cold_snapshot_repo,
            vm_inventory_repo,
            object_store_resolver,
            alert_service,
            discovery_service,
            node_client,
            node_secret_manager,
            lifecycle_lease,
            begin_snapshot_pause_hook: None,
            cold_publication_pause_hook: None,
            rollback_pause_hook: None,
            retry_counts: std::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Installs a test-only hook fired inside the `begin_snapshot_record`
    /// guarded closure, immediately before the snapshot-intent mutation.
    pub fn with_begin_snapshot_pause_hook_for_tests(
        mut self,
        hook: LifecycleGuardPauseHook,
    ) -> Self {
        self.begin_snapshot_pause_hook = Some(hook);
        self
    }

    /// Installs a test-only hook fired inside the
    /// `transition_tenant_to_cold_storage` guarded closure, immediately before
    /// the cold-publication mutation.
    pub fn with_cold_publication_pause_hook_for_tests(
        mut self,
        hook: LifecycleGuardPauseHook,
    ) -> Self {
        self.cold_publication_pause_hook = Some(hook);
        self
    }

    /// Installs a test-only hook fired inside the
    /// `rollback_tenant_snapshot_state` guarded closure, immediately before the
    /// compensation mutation.
    pub fn with_rollback_pause_hook_for_tests(mut self, hook: LifecycleGuardPauseHook) -> Self {
        self.rollback_pause_hook = Some(hook);
        self
    }

    pub fn config(&self) -> &ColdTierConfig {
        &self.config
    }

    /// Scans all active tenants and returns those eligible for cold storage:
    /// the tenant must be in `"active"` tier, assigned to a VM, idle beyond
    /// `idle_threshold_days`, not currently migrating, and under the
    /// per-cycle candidate cap.
    pub async fn detect_candidates(&self) -> Result<Vec<ColdTierCandidate>, ColdTierError> {
        let cutoff = Utc::now() - Duration::days(self.config.idle_threshold_days as i64);

        let tenants = self
            .tenant_repo
            .list_active_global()
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        let active_migrations = self
            .index_migration_repo
            .list_active()
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        let migrating_indexes: HashSet<(Uuid, String)> = active_migrations
            .into_iter()
            .map(|m| (m.customer_id, m.index_name))
            .collect();

        let mut candidates = Vec::new();

        for tenant in tenants {
            if tenant.tier != "active" {
                continue;
            }

            if tenant.vm_id.is_none() {
                continue;
            }

            if migrating_indexes.contains(&(tenant.customer_id, tenant.tenant_id.clone())) {
                continue;
            }

            if tenant
                .last_accessed_at
                .is_some_and(|last_accessed| last_accessed >= cutoff)
            {
                continue;
            }

            candidates.push(
                ColdTierCandidate::from_tenant(&tenant)
                    .expect("candidate VM presence was validated"),
            );

            if candidates.len() >= self.config.max_candidates_per_cycle as usize {
                break;
            }
        }

        Ok(candidates)
    }

    /// Check if a candidate has exceeded its max retry count.
    pub fn is_max_retries_exceeded(&self, customer_id: Uuid, tenant_id: &str) -> bool {
        let counts = self.retry_counts.lock().unwrap();
        counts
            .get(&(customer_id, tenant_id.to_string()))
            .copied()
            .unwrap_or(0)
            >= self.config.max_snapshot_retries
    }

    /// Run a single cold-tier cycle with an external VM info lookup.
    /// The lookup returns `(flapjack_url, region)` for a VM ID.
    /// Used in tests where VM info is provided by the test harness.
    pub async fn run_cycle(
        &self,
        vm_info_lookup: &(dyn Fn(Uuid) -> Option<(String, String)> + Sync),
    ) -> Result<(), ColdTierError> {
        let candidates = self.detect_candidates().await?;
        let max_snapshots = self.config.max_concurrent_snapshots as usize;

        if max_snapshots == 0 {
            return Ok(());
        }

        for candidate in candidates.iter().take(max_snapshots) {
            if self.is_max_retries_exceeded(candidate.customer_id, &candidate.tenant_id) {
                continue;
            }

            let Some((flapjack_url, region)) = vm_info_lookup(candidate.source_vm_id) else {
                warn!(
                    vm_id = %candidate.source_vm_id,
                    tenant_id = %candidate.tenant_id,
                    "could not resolve flapjack URL for source VM; skipping"
                );
                continue;
            };

            self.snapshot_or_handle_failure(candidate, &flapjack_url, &region)
                .await;
        }

        Ok(())
    }

    /// Run a single cycle resolving VM info from vm_inventory_repo.
    /// Used by the background loop — fully self-contained, no closures.
    pub async fn run_cycle_auto(&self) -> Result<(), ColdTierError> {
        let vms = self
            .vm_inventory_repo
            .list_active(None)
            .await
            .map_err(|e| ColdTierError::Repo(e.to_string()))?;

        let vm_info: HashMap<Uuid, (String, String)> = vms
            .into_iter()
            .map(|vm| (vm.id, (vm.flapjack_url, vm.region)))
            .collect();

        self.run_cycle(&|vm_id| vm_info.get(&vm_id).cloned()).await
    }

    /// Background loop: run cold-tier cycles on a timer until shutdown.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        info!(
            cycle_interval_secs = self.config.cycle_interval_secs,
            idle_threshold_days = self.config.idle_threshold_days,
            "cold tier manager started"
        );

        loop {
            tokio::select! {
                _ = tokio::time::sleep(StdDuration::from_secs(self.config.cycle_interval_secs)) => {
                    if let Err(err) = self.run_cycle_auto().await {
                        warn!(error = %err, "cold tier cycle failed");
                    }
                }
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("cold tier manager shutting down");
                        return;
                    }
                }
            }
        }
    }
}

impl ColdTierService {
    pub(super) async fn guarded_target_mutation<F, Fut, T>(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
        mutation: F,
    ) -> Result<T, ColdTierError>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<T, RepoError>>,
    {
        match &self.lifecycle_lease {
            Some(lease) => lease
                .guarded_mutation(customer_id, tenant_id, expected_identity, mutation)
                .await
                .map_err(map_repo_error),
            None => mutation().await.map_err(map_repo_error),
        }
    }
}

pub(super) fn identity_from_tenant(tenant: &CustomerTenant) -> CatalogLifecycleTargetIdentity {
    CatalogLifecycleTargetIdentity {
        deployment_id: tenant.deployment_id,
        vm_id: tenant.vm_id,
        tier: tenant.tier.clone(),
        cold_snapshot_id: tenant.cold_snapshot_id,
        service_type: tenant.service_type.clone(),
    }
}

pub(super) fn map_repo_error(error: RepoError) -> ColdTierError {
    match error {
        RepoError::Conflict(message) if message == "destination_conflict" => {
            ColdTierError::DestinationConflict
        }
        RepoError::Conflict(message) if message == "destination_changed" => {
            ColdTierError::DestinationChanged
        }
        other => ColdTierError::Repo(other.to_string()),
    }
}

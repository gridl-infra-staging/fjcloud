//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/restore.rs.
use std::collections::HashMap;
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use tracing::{info, warn};
use uuid::Uuid;

use crate::models::resource_vector::ResourceVector;
use crate::models::restore_job::NewRestoreJob;
use crate::models::vm_inventory::VmInventory;
use crate::repos::{ColdSnapshotRepo, RestoreJobRepo, TenantRepo, VmInventoryRepo};
use crate::secrets::NodeSecretManager;
use crate::services::alerting::{Alert, AlertService, AlertSeverity};
use crate::services::cold_tier::FlapjackNodeClient;
use crate::services::discovery::DiscoveryService;
use crate::services::flapjack_node::{flapjack_index_uid, get_or_create_node_api_key};
use crate::services::object_store::RegionObjectStoreResolver;
use crate::services::placement::{place_index, VmWithLoad};

const DEFAULT_MAX_CONCURRENT_RESTORES: u32 = 3;
const DEFAULT_RESTORE_TIMEOUT_SECS: u64 = 300;
const MIN_RESTORE_ESTIMATE_SECS: i64 = 60;
const BYTES_PER_GIB: i128 = 1024 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct RestoreConfig {
    pub max_concurrent_restores: u32,
    pub restore_timeout_secs: u64,
}

impl Default for RestoreConfig {
    fn default() -> Self {
        Self {
            max_concurrent_restores: DEFAULT_MAX_CONCURRENT_RESTORES,
            restore_timeout_secs: DEFAULT_RESTORE_TIMEOUT_SECS,
        }
    }
}

impl RestoreConfig {
    pub fn from_env() -> Self {
        Self {
            max_concurrent_restores: std::env::var("RESTORE_MAX_CONCURRENT")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(DEFAULT_MAX_CONCURRENT_RESTORES),
            restore_timeout_secs: std::env::var("RESTORE_TIMEOUT_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(DEFAULT_RESTORE_TIMEOUT_SECS),
        }
    }
}

/// Error variants for the cold-to-hot restore pipeline.
///
/// Covers precondition failures (index not cold, not found, no snapshot,
/// capacity limit reached, no VM available), repository-level I/O errors,
/// and restore execution failures with a descriptive message.
#[derive(Debug, thiserror::Error)]
pub enum RestoreError {
    #[error("index is not in cold storage")]
    NotCold,

    #[error("index not found")]
    NotFound,

    #[error("no cold snapshot found for index")]
    NoSnapshot,

    #[error("restore capacity reached")]
    AtLimit,

    #[error("no VMs available for restore placement")]
    NoVmAvailable,

    #[error("repo error: {0}")]
    Repo(String),

    #[error("restore failed: {0}")]
    RestoreFailed(String),
}

/// Response from initiating a restore.
#[derive(Debug)]
pub struct RestoreResponse {
    pub job_id: Uuid,
    pub status: String,
    pub created_new_job: bool,
}

/// Active restore status for API polling responses.
#[derive(Debug, Clone)]
pub struct RestoreStatus {
    pub job: crate::models::restore_job::RestoreJob,
    pub estimated_completion_at: Option<DateTime<Utc>>,
}

pub struct RestoreService {
    config: RestoreConfig,
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
    restore_job_repo: Arc<dyn RestoreJobRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    object_store_resolver: Arc<RegionObjectStoreResolver>,
    alert_service: Arc<dyn AlertService>,
    discovery_service: Arc<DiscoveryService>,
    node_client: Arc<dyn FlapjackNodeClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
}

impl RestoreService {
    /// Constructs the restore service with its full dependency set.
    ///
    /// Requires cold tier config, tenant/cold-snapshot/restore-job/VM-inventory
    /// repos, a region-aware object store resolver (for per-region cold storage),
    /// alert service, discovery service, and a node client for flapjack HTTP
    /// operations (snapshot import and index verification).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        config: RestoreConfig,
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        cold_snapshot_repo: Arc<dyn ColdSnapshotRepo + Send + Sync>,
        restore_job_repo: Arc<dyn RestoreJobRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        object_store_resolver: Arc<RegionObjectStoreResolver>,
        alert_service: Arc<dyn AlertService>,
        discovery_service: Arc<DiscoveryService>,
        node_client: Arc<dyn FlapjackNodeClient>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
    ) -> Self {
        Self {
            config,
            tenant_repo,
            cold_snapshot_repo,
            restore_job_repo,
            vm_inventory_repo,
            object_store_resolver,
            alert_service,
            discovery_service,
            node_client,
            node_secret_manager,
        }
    }

    /// Initiate a restore for a cold index. Idempotent: if a restore is already
    /// in progress for this index, returns the existing job.
    pub async fn initiate_restore(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<RestoreResponse, RestoreError> {
        // 1. Look up tenant
        let tenant = self
            .tenant_repo
            .find_raw(customer_id, tenant_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
            .ok_or(RestoreError::NotFound)?;

        // 2. Check idempotency — if tier is 'restoring', return existing job
        let idempotency_key = format!("{}:{}", customer_id, tenant_id);
        if tenant.tier == "restoring" {
            if let Some(existing_job) = self
                .restore_job_repo
                .find_by_idempotency_key(&idempotency_key)
                .await
                .map_err(|e| RestoreError::Repo(e.to_string()))?
            {
                return Ok(RestoreResponse {
                    job_id: existing_job.id,
                    status: existing_job.status,
                    created_new_job: false,
                });
            }
        }

        // 3. Must be cold to initiate a new restore
        if tenant.tier != "cold" {
            return Err(RestoreError::NotCold);
        }

        // 4. Get the cold snapshot
        let snapshot_id = tenant.cold_snapshot_id.ok_or(RestoreError::NoSnapshot)?;

        let snapshot = self
            .cold_snapshot_repo
            .get(snapshot_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
            .ok_or(RestoreError::NoSnapshot)?;

        // 5. Check for existing active job (idempotency for cold tier)
        if let Some(existing_job) = self
            .restore_job_repo
            .find_by_idempotency_key(&idempotency_key)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
        {
            return Ok(RestoreResponse {
                job_id: existing_job.id,
                status: existing_job.status,
                created_new_job: false,
            });
        }

        // 6. Check capacity
        let active_count = self
            .restore_job_repo
            .count_active()
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        if active_count >= self.config.max_concurrent_restores as i64 {
            return Err(RestoreError::AtLimit);
        }

        // 7. Choose destination VM via placement
        let dest_vm_id = self.find_destination_vm().await?;

        // 8. Create restore job
        let job = self
            .restore_job_repo
            .create(NewRestoreJob {
                customer_id,
                tenant_id: tenant_id.to_string(),
                snapshot_id: snapshot.id,
                dest_vm_id: Some(dest_vm_id),
                idempotency_key,
            })
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        // 9. Set tenant tier to 'restoring'
        self.tenant_repo
            .set_tier(customer_id, tenant_id, "restoring")
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        info!(
            customer_id = %customer_id,
            tenant_id = %tenant_id,
            job_id = %job.id,
            snapshot_id = %snapshot.id,
            dest_vm_id = %dest_vm_id,
            "restore job created"
        );

        Ok(RestoreResponse {
            job_id: job.id,
            status: job.status,
            created_new_job: true,
        })
    }

    /// Execute the restore pipeline for a job. Handles success and failure internally —
    /// updates job status and tenant tier, fires alerts.
    pub async fn execute_restore(&self, job_id: Uuid) {
        let timeout_duration = std::time::Duration::from_secs(self.config.restore_timeout_secs);

        let restore_result =
            tokio::time::timeout(timeout_duration, self.execute_restore_inner(job_id)).await;

        match restore_result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                self.handle_restore_failure(job_id, &e.to_string()).await;
            }
            Err(_) => {
                // Timeout - restore took too long
                let timeout_error = format!(
                    "restore timed out after {} seconds",
                    self.config.restore_timeout_secs
                );
                self.handle_restore_failure(job_id, &timeout_error).await;
            }
        }
    }

    /// Executes the multi-step cold-to-hot restore pipeline for a single job.
    ///
    /// Steps: loads the restore job record, retrieves cold snapshot metadata,
    /// resolves the storage region from the snapshot's object key (falling back
    /// to the source VM region for legacy keys), downloads the snapshot from the
    /// region-appropriate object store, imports it into the target flapjack VM,
    /// verifies the import, updates the tenant's tier back to hot, invalidates
    /// the discovery cache, and marks the job as complete. On failure at any
    /// step, the caller marks the job as failed with the error details.
    async fn execute_restore_inner(&self, job_id: Uuid) -> Result<(), RestoreError> {
        let job = self
            .restore_job_repo
            .get(job_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
            .ok_or(RestoreError::NotFound)?;

        let snapshot = self
            .cold_snapshot_repo
            .get(job.snapshot_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
            .ok_or(RestoreError::NoSnapshot)?;

        let dest_vm_id = job.dest_vm_id.ok_or(RestoreError::NoVmAvailable)?;

        let dest_vm = self
            .vm_inventory_repo
            .get(dest_vm_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?
            .ok_or(RestoreError::NoVmAvailable)?;

        let flapjack_url = &dest_vm.flapjack_url;
        let node_api_key = self.node_api_key_for_destination_vm(&dest_vm).await?;
        let flapjack_uid = flapjack_index_uid(job.customer_id, &job.tenant_id);

        // Resolve storage region:
        // 1) Prefer region embedded in object_key (new format: cold/{region}/...).
        // 2) Fallback to source VM region for legacy snapshots.
        // 3) Final fallback to default region.
        let source_vm = self
            .vm_inventory_repo
            .get(snapshot.source_vm_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;
        let storage_region = parse_region_from_object_key(&snapshot.object_key)
            .or_else(|| source_vm.as_ref().map(|vm| vm.region.clone()))
            .unwrap_or_else(|| "us-east-1".to_string());
        let object_store = self.object_store_resolver.for_region(&storage_region);

        // Step a: downloading
        self.restore_job_repo
            .update_status(job.id, "downloading", None)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        // Step b: download snapshot from region-specific object store
        let data = object_store
            .get(&snapshot.object_key)
            .await
            .map_err(|e| RestoreError::RestoreFailed(format!("download failed: {e}")))?;

        // Step c: importing
        self.restore_job_repo
            .update_status(job.id, "importing", None)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        // Step d: import tarball onto destination flapjack node
        self.node_client
            .import_index(flapjack_url, &flapjack_uid, &data, &node_api_key)
            .await
            .map_err(|e| RestoreError::RestoreFailed(format!("import failed: {e}")))?;

        // Step e: verify index is queryable
        self.node_client
            .verify_index(flapjack_url, &flapjack_uid, &node_api_key)
            .await
            .map_err(|e| RestoreError::RestoreFailed(format!("verify failed: {e}")))?;

        // Step f: update tenant catalog
        self.tenant_repo
            .set_vm_id(job.customer_id, &job.tenant_id, dest_vm_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        self.tenant_repo
            .set_tier(job.customer_id, &job.tenant_id, "active")
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        self.tenant_repo
            .set_cold_snapshot_id(job.customer_id, &job.tenant_id, None)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        // Step g: invalidate discovery cache
        self.discovery_service
            .invalidate(job.customer_id, &job.tenant_id);

        // Step h: mark job completed
        self.restore_job_repo
            .set_completed(job.id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        let _ = self
            .alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Info,
                title: "Index restored from cold storage".to_string(),
                message: format!(
                    "Index '{}' (customer {}) restored to VM {}",
                    job.tenant_id, job.customer_id, dest_vm_id
                ),
                metadata: HashMap::from([
                    ("customer_id".to_string(), job.customer_id.to_string()),
                    ("tenant_id".to_string(), job.tenant_id.clone()),
                    ("job_id".to_string(), job.id.to_string()),
                    ("dest_vm_id".to_string(), dest_vm_id.to_string()),
                ]),
            })
            .await;

        info!(
            customer_id = %job.customer_id,
            tenant_id = %job.tenant_id,
            job_id = %job.id,
            dest_vm_id = %dest_vm_id,
            "restore completed"
        );

        Ok(())
    }

    async fn node_api_key_for_destination_vm(
        &self,
        vm: &VmInventory,
    ) -> Result<String, RestoreError> {
        get_or_create_node_api_key(self.node_secret_manager.as_ref(), vm)
            .await
            .map_err(|e| {
                RestoreError::RestoreFailed(format!(
                    "failed to load admin key for destination VM {}: {e}",
                    vm.id
                ))
            })
    }

    /// Handle a failed restore: reset tier to cold, update job status, alert.
    async fn handle_restore_failure(&self, job_id: Uuid, error: &str) {
        let job = match self.restore_job_repo.get(job_id).await {
            Ok(Some(job)) => job,
            _ => return,
        };

        let _ = self
            .restore_job_repo
            .update_status(job_id, "failed", Some(error))
            .await;

        // Reset tier back to cold
        let _ = self
            .tenant_repo
            .set_tier(job.customer_id, &job.tenant_id, "cold")
            .await;

        let _ = self
            .alert_service
            .send_alert(Alert {
                severity: AlertSeverity::Warning,
                title: "Index restore failed".to_string(),
                message: format!(
                    "Restore of index '{}' (customer {}) failed: {}",
                    job.tenant_id, job.customer_id, error
                ),
                metadata: HashMap::from([
                    ("customer_id".to_string(), job.customer_id.to_string()),
                    ("tenant_id".to_string(), job.tenant_id.clone()),
                    ("job_id".to_string(), job.id.to_string()),
                    ("error".to_string(), error.to_string()),
                ]),
            })
            .await;

        warn!(
            customer_id = %job.customer_id,
            tenant_id = %job.tenant_id,
            job_id = %job.id,
            error,
            "restore failed"
        );
    }

    /// Find a destination VM for the restored index using dot-product bin-packing.
    async fn find_destination_vm(&self) -> Result<Uuid, RestoreError> {
        let vms = self
            .vm_inventory_repo
            .list_active(None)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        if vms.is_empty() {
            return Err(RestoreError::NoVmAvailable);
        }

        let vm_loads: Vec<VmWithLoad> = vms
            .iter()
            .map(|vm| VmWithLoad {
                vm_id: vm.id,
                capacity: ResourceVector::from(vm.capacity.clone()),
                current_load: ResourceVector::from(vm.current_load.clone()),
                status: vm.status.clone(),
                load_scraped_at: vm.load_scraped_at,
            })
            .collect();

        let index_vector = ResourceVector::zero();
        place_index(&index_vector, &vm_loads).ok_or(RestoreError::NoVmAvailable)
    }

    /// Get the status of a restore job for an index.
    pub async fn get_restore_status(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<RestoreStatus>, RestoreError> {
        let idempotency_key = format!("{}:{}", customer_id, tenant_id);
        let job = self
            .restore_job_repo
            .find_latest_by_idempotency_key(&idempotency_key)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        let Some(job) = job else {
            return Ok(None);
        };

        let snapshot = self
            .cold_snapshot_repo
            .get(job.snapshot_id)
            .await
            .map_err(|e| RestoreError::Repo(e.to_string()))?;

        let estimated_completion_at = snapshot.map(|snapshot| {
            let baseline = job.started_at.unwrap_or(job.created_at);
            self.estimate_completion_at(baseline, snapshot.size_bytes)
        });

        Ok(Some(RestoreStatus {
            job,
            estimated_completion_at,
        }))
    }

    fn estimate_completion_at(
        &self,
        baseline: DateTime<Utc>,
        snapshot_size_bytes: i64,
    ) -> DateTime<Utc> {
        let size_bytes = i128::from(snapshot_size_bytes.max(0));
        let mut seconds =
            ((size_bytes * MIN_RESTORE_ESTIMATE_SECS as i128) + BYTES_PER_GIB - 1) / BYTES_PER_GIB;
        if seconds < MIN_RESTORE_ESTIMATE_SECS as i128 {
            seconds = MIN_RESTORE_ESTIMATE_SECS as i128;
        }
        baseline + Duration::seconds(seconds as i64)
    }
}

/// Extracts the region component from new-format cold storage object keys.
///
/// New-format keys follow the pattern `cold/{region}/{customer_id}/{tenant_id}/{snapshot}.fj`.
/// Returns `None` for legacy keys that lack an embedded region prefix (e.g.
/// where the second segment is a UUID customer ID rather than a region string).
fn parse_region_from_object_key(object_key: &str) -> Option<String> {
    let mut parts = object_key.split('/');
    let prefix = parts.next()?;
    if prefix != "cold" {
        return None;
    }

    let region = parts.next()?;
    if region.is_empty() || Uuid::parse_str(region).is_ok() {
        return None;
    }

    // New-format keys are: cold/{region}/{customer_id}/{tenant_id}/{snapshot}.fj
    // Only treat the second segment as a region when the rest of the shape matches.
    let customer_id = parts.next()?;
    if customer_id.is_empty() || Uuid::parse_str(customer_id).is_err() {
        return None;
    }

    let tenant_id = parts.next()?;
    if tenant_id.is_empty() {
        return None;
    }

    let snapshot_name = parts.next()?;
    if snapshot_name.is_empty() {
        return None;
    }
    if parts.next().is_some() {
        return None;
    }

    Some(region.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_region_valid_key() {
        let key = "cold/us-east-1/550e8400-e29b-41d4-a716-446655440000/my-index/snap.fj";
        assert_eq!(
            parse_region_from_object_key(key),
            Some("us-east-1".to_string())
        );
    }

    #[test]
    fn parse_region_rejects_wrong_prefix() {
        let key = "hot/us-east-1/550e8400-e29b-41d4-a716-446655440000/my-index/snap.fj";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_uuid_as_region() {
        // Second segment is a UUID — old-format key, not a region
        let key = "cold/550e8400-e29b-41d4-a716-446655440000/tenant/snap.fj";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_missing_customer_id() {
        let key = "cold/us-east-1";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_non_uuid_customer_id() {
        let key = "cold/us-east-1/not-a-uuid/my-index/snap.fj";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_extra_segments() {
        let key = "cold/us-east-1/550e8400-e29b-41d4-a716-446655440000/my-index/snap.fj/extra";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_missing_snapshot() {
        let key = "cold/us-east-1/550e8400-e29b-41d4-a716-446655440000/my-index";
        assert!(parse_region_from_object_key(key).is_none());
    }

    #[test]
    fn parse_region_rejects_empty_string() {
        assert!(parse_region_from_object_key("").is_none());
    }
}

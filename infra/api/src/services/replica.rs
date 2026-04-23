//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/replica.rs.
use std::sync::Arc;

use uuid::Uuid;

use crate::models::index_replica::{IndexReplica, IndexReplicaSummary};
use crate::models::resource_vector::ResourceVector;
use crate::provisioner::region_map::RegionConfig;
use crate::repos::index_replica_repo::IndexReplicaRepo;
use crate::repos::tenant_repo::TenantRepo;
use crate::repos::vm_inventory_repo::VmInventoryRepo;
use crate::services::placement::{place_index, VmWithLoad};

const MAX_REPLICAS_PER_INDEX: i64 = 5;

/// Error variants for index replica operations: replica not found, target region
/// unavailable, replica limit reached, replication already in progress, source
/// index not active, and repository-level failures.
#[derive(Debug, thiserror::Error)]
pub enum ReplicaError {
    #[error("index not found")]
    IndexNotFound,

    #[error("replica not found")]
    ReplicaNotFound,

    #[error("region not available: {0}")]
    RegionNotAvailable(String),

    #[error("replica limit reached ({0})")]
    LimitReached(i64),

    #[error("replica already exists in region {0}")]
    AlreadyExistsInRegion(String),

    #[error("cannot create replica in same region as primary")]
    SameRegionAsPrimary,

    #[error("no VM capacity in region {0}")]
    NoCapacityInRegion(String),

    #[error("index has no primary VM assignment")]
    NoPrimaryVm,

    #[error("repo error: {0}")]
    Repo(String),
}

pub struct ReplicaService {
    replica_repo: Arc<dyn IndexReplicaRepo>,
    tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
    vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
    region_config: RegionConfig,
}

impl ReplicaService {
    pub fn new(
        replica_repo: Arc<dyn IndexReplicaRepo>,
        tenant_repo: Arc<dyn TenantRepo + Send + Sync>,
        vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync>,
        region_config: RegionConfig,
    ) -> Self {
        Self {
            replica_repo,
            tenant_repo,
            vm_inventory_repo,
            region_config,
        }
    }

    /// Create a read replica of an index in the specified region.
    pub async fn create_replica(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        target_region: &str,
    ) -> Result<IndexReplica, ReplicaError> {
        // Validate target region is available
        if self
            .region_config
            .get_available_region(target_region)
            .is_none()
        {
            return Err(ReplicaError::RegionNotAvailable(target_region.to_string()));
        }

        // Look up the index
        let tenant = self
            .tenant_repo
            .find_raw(customer_id, tenant_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?
            .ok_or(ReplicaError::IndexNotFound)?;

        let primary_vm_id = tenant.vm_id.ok_or(ReplicaError::NoPrimaryVm)?;

        // Get primary VM to check its region
        let primary_vm = self
            .vm_inventory_repo
            .get(primary_vm_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?
            .ok_or(ReplicaError::NoPrimaryVm)?;

        if primary_vm.region == target_region {
            return Err(ReplicaError::SameRegionAsPrimary);
        }

        // Check no existing replica in this region and enforce replica limit
        // using only non-terminal replicas.
        let existing = self
            .replica_repo
            .list_by_index(customer_id, tenant_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;
        let non_terminal_count = existing
            .iter()
            .filter(|r| r.status != "failed" && r.status != "removing")
            .count() as i64;
        if non_terminal_count >= MAX_REPLICAS_PER_INDEX {
            return Err(ReplicaError::LimitReached(MAX_REPLICAS_PER_INDEX));
        }
        if existing.iter().any(|r| {
            r.replica_region == target_region && r.status != "failed" && r.status != "removing"
        }) {
            return Err(ReplicaError::AlreadyExistsInRegion(
                target_region.to_string(),
            ));
        }

        // Find a VM with capacity in the target region
        let vms = self
            .vm_inventory_repo
            .list_active(Some(target_region))
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;

        if vms.is_empty() {
            return Err(ReplicaError::NoCapacityInRegion(target_region.to_string()));
        }

        // Use placement algorithm to find best VM
        let vm_with_loads: Vec<VmWithLoad> = vms
            .iter()
            .map(|vm| VmWithLoad {
                vm_id: vm.id,
                capacity: ResourceVector::from(vm.capacity.clone()),
                current_load: ResourceVector::from(vm.current_load.clone()),
                status: vm.status.clone(),
                load_scraped_at: vm.load_scraped_at,
            })
            .collect();

        // Use a small default resource vector for the replica (read-only, lighter load)
        let replica_vector = crate::models::resource_vector::ResourceVector {
            cpu_weight: 0.5,
            mem_rss_bytes: 256 * 1024 * 1024, // 256 MB
            disk_bytes: 0,                    // shared disk with other tenants
            query_rps: 10.0,
            indexing_rps: 1.0, // replication ingestion only
        };

        let replica_vm_id = place_index(&replica_vector, &vm_with_loads)
            .ok_or_else(|| ReplicaError::NoCapacityInRegion(target_region.to_string()))?;

        // Create the replica record
        let replica = self
            .replica_repo
            .create(
                customer_id,
                tenant_id,
                primary_vm_id,
                replica_vm_id,
                target_region,
            )
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;

        Ok(replica)
    }

    /// Remove a read replica.
    pub async fn remove_replica(
        &self,
        customer_id: Uuid,
        replica_id: Uuid,
    ) -> Result<(), ReplicaError> {
        let replica = self
            .replica_repo
            .get(replica_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?
            .ok_or(ReplicaError::ReplicaNotFound)?;

        // Verify ownership
        if replica.customer_id != customer_id {
            return Err(ReplicaError::ReplicaNotFound);
        }

        // Mark as removing first, then delete
        self.replica_repo
            .set_status(replica_id, "removing")
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;

        self.replica_repo
            .delete(replica_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;

        Ok(())
    }

    /// List all replicas for an index with VM details.
    pub async fn list_replicas(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplicaSummary>, ReplicaError> {
        let replicas = self
            .replica_repo
            .list_by_index(customer_id, tenant_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))?;

        let mut summaries = Vec::with_capacity(replicas.len());
        for replica in replicas {
            let vm = self
                .vm_inventory_repo
                .get(replica.replica_vm_id)
                .await
                .map_err(|e| ReplicaError::Repo(e.to_string()))?;

            let (hostname, flapjack_url) = match vm {
                Some(vm) => (vm.hostname, vm.flapjack_url),
                None => ("unknown".to_string(), "".to_string()),
            };

            summaries.push(IndexReplicaSummary {
                id: replica.id,
                replica_region: replica.replica_region,
                status: replica.status,
                lag_ops: replica.lag_ops,
                replica_vm_hostname: hostname,
                replica_flapjack_url: flapjack_url,
                created_at: replica.created_at,
            });
        }

        Ok(summaries)
    }

    /// Get healthy replicas for discovery (active status only).
    pub async fn healthy_replicas(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Vec<IndexReplica>, ReplicaError> {
        self.replica_repo
            .list_healthy_by_index(customer_id, tenant_id)
            .await
            .map_err(|e| ReplicaError::Repo(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_replicas_per_index_is_reasonable() {
        assert_eq!(MAX_REPLICAS_PER_INDEX, 5);
    }

    /// Verifies that the `Display` implementation for every `ReplicaError` variant
    /// produces a non-empty, human-readable message.
    #[test]
    fn replica_error_display_variants() {
        assert_eq!(ReplicaError::IndexNotFound.to_string(), "index not found");
        assert_eq!(
            ReplicaError::ReplicaNotFound.to_string(),
            "replica not found"
        );
        assert_eq!(
            ReplicaError::RegionNotAvailable("ap-south-1".into()).to_string(),
            "region not available: ap-south-1"
        );
        assert_eq!(
            ReplicaError::LimitReached(5).to_string(),
            "replica limit reached (5)"
        );
        assert_eq!(
            ReplicaError::AlreadyExistsInRegion("us-east-1".into()).to_string(),
            "replica already exists in region us-east-1"
        );
        assert_eq!(
            ReplicaError::SameRegionAsPrimary.to_string(),
            "cannot create replica in same region as primary"
        );
        assert_eq!(
            ReplicaError::NoCapacityInRegion("eu-west-1".into()).to_string(),
            "no VM capacity in region eu-west-1"
        );
        assert_eq!(
            ReplicaError::NoPrimaryVm.to_string(),
            "index has no primary VM assignment"
        );
        assert_eq!(
            ReplicaError::Repo("timeout".into()).to_string(),
            "repo error: timeout"
        );
    }
}

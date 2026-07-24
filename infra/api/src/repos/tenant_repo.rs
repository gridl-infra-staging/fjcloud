use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::models::tenant::{CustomerTenant, CustomerTenantSummary};
use crate::repos::algolia_import_job_repo::CatalogLifecycleTargetIdentity;
use crate::repos::error::RepoError;

/// Tenant catalog repository: maps customer indexes to deployments and VMs.
/// Manages index placement, migration tiers, resource quotas, cold-snapshot
/// links, and last-accessed timestamps. Active queries exclude terminated
/// deployments.
#[async_trait]
pub trait TenantRepo {
    /// Insert a new index mapping. Returns `Conflict` if `(customer_id, tenant_id)` already exists.
    async fn create(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        deployment_id: Uuid,
    ) -> Result<CustomerTenant, RepoError>;

    async fn create_lifecycle_intent(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        deployment_id: Uuid,
        tier: &str,
    ) -> Result<CustomerTenant, RepoError>;

    async fn publish_delete_lifecycle_intent(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        expected_identity: &CatalogLifecycleTargetIdentity,
    ) -> Result<CustomerTenant, RepoError>;

    async fn publish_lifecycle_placement(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        expected_identity: &CatalogLifecycleTargetIdentity,
        vm_id: Option<Uuid>,
    ) -> Result<CustomerTenant, RepoError>;

    async fn remove_lifecycle_intent(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        expected_identity: &CatalogLifecycleTargetIdentity,
    ) -> Result<bool, RepoError>;

    /// All indexes for a customer, joined with deployment info. Excludes indexes on terminated deployments.
    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenantSummary>, RepoError>;

    /// Single index lookup with deployment info.
    async fn find_by_name(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError>;

    /// Remove an index from the catalog. Returns `false` if not found.
    async fn delete(&self, customer_id: Uuid, tenant_id: &str) -> Result<bool, RepoError>;

    /// Count of indexes for a customer (for limit enforcement).
    async fn count_by_customer(&self, customer_id: Uuid) -> Result<i64, RepoError>;

    /// Count logical index slots consumed by published catalog rows and
    /// unpublished create reservations. PostgreSQL overrides this with the
    /// canonical import-reservation calculation; repositories without import
    /// persistence use their catalog count.
    async fn count_logical_index_slots(&self, customer_id: Uuid) -> Result<i64, RepoError> {
        self.count_by_customer(customer_id).await
    }

    /// All indexes on a given deployment (for cleanup when terminating a VM).
    async fn find_by_deployment(
        &self,
        deployment_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError>;

    /// Assign a VM to an index (multi-tenancy: index lives on this physical VM).
    async fn set_vm_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        vm_id: Uuid,
    ) -> Result<(), RepoError>;

    /// Move a tenant from an expected source VM to a replacement VM.
    ///
    /// Retries are idempotent when the tenant is already on the replacement.
    /// A tenant on any other VM is a conflict so autorepair cannot overwrite
    /// concurrent migration or lifecycle placement.
    async fn replace_vm_if_current(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        expected_source_vm_id: Uuid,
        replacement_vm_id: Uuid,
    ) -> Result<CustomerTenant, RepoError>;

    /// Set the migration tier for an index (active/migrating/pinned).
    async fn set_tier(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        tier: &str,
    ) -> Result<(), RepoError>;

    /// All indexes on a specific physical VM.
    async fn list_by_vm(&self, vm_id: Uuid) -> Result<Vec<CustomerTenant>, RepoError>;

    /// All indexes on the requested physical VMs, with the same raw inclusion
    /// semantics as `list_by_vm`; deployment status is not filtered.
    async fn list_by_vms(&self, vm_ids: &[Uuid]) -> Result<Vec<CustomerTenant>, RepoError>;

    /// All indexes currently in the migrating tier.
    async fn list_migrating(&self) -> Result<Vec<CustomerTenant>, RepoError>;

    /// All indexes that have not been assigned to a physical VM yet.
    async fn list_unplaced(&self) -> Result<Vec<CustomerTenant>, RepoError>;

    /// All active tenant mappings globally (used by internal metering map).
    /// Excludes tenants on terminated deployments.
    async fn list_active_global(&self) -> Result<Vec<CustomerTenant>, RepoError>;

    /// Look up an index by name without knowing the customer_id.
    /// Used by discovery service (customer_id resolved separately from API key).
    async fn find_by_tenant_id_global(
        &self,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenantSummary>, RepoError>;

    /// Raw tenant lookup (includes vm_id, tier, resource_quota) without joining deployments.
    /// Used by discovery service to check vm_id in a single query.
    async fn find_raw(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
    ) -> Result<Option<CustomerTenant>, RepoError>;

    /// Update the per-index resource quota JSONB for a tenant.
    async fn set_resource_quota(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        quota: serde_json::Value,
    ) -> Result<(), RepoError>;

    /// All indexes for a customer (raw — includes vm_id, tier, resource_quota).
    async fn list_raw_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<CustomerTenant>, RepoError>;

    /// Batch-update tenant `last_accessed_at` values.
    async fn update_last_accessed_batch(
        &self,
        updates: &[(Uuid, String, DateTime<Utc>)],
    ) -> Result<(), RepoError>;

    /// Set or clear the `cold_snapshot_id` on a tenant.
    async fn set_cold_snapshot_id(
        &self,
        customer_id: Uuid,
        tenant_id: &str,
        snapshot_id: Option<Uuid>,
    ) -> Result<(), RepoError>;

    /// Clear the VM assignment for a tenant (set `vm_id = NULL`).
    async fn clear_vm_id(&self, customer_id: Uuid, tenant_id: &str) -> Result<(), RepoError>;
}

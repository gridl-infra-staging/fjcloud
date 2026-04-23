use async_trait::async_trait;
use uuid::Uuid;

use crate::models::ayb_tenant::{AybTenant, NewAybTenant};
use crate::repos::error::RepoError;

/// Repository trait for `ayb_tenants` persistence.
///
/// All read methods filter to active rows (`deleted_at IS NULL`) so handlers
/// never re-implement soft-delete logic.
#[async_trait]
pub trait AybTenantRepo: Send + Sync {
    /// Insert a new AYB tenant row. Returns `Conflict` if the customer already
    /// has an active instance or the `(ayb_cluster_id, ayb_slug)` pair is taken.
    async fn create(&self, tenant: NewAybTenant) -> Result<AybTenant, RepoError>;

    /// List all active AYB instances for a customer.
    async fn find_active_by_customer(&self, customer_id: Uuid)
        -> Result<Vec<AybTenant>, RepoError>;

    /// Get a single active AYB instance scoped to the owning customer.
    async fn find_active_by_customer_and_id(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AybTenant>, RepoError>;

    /// Soft-delete an active row scoped to the owning customer.
    /// Returns `NotFound` if the row does not exist for that customer or is already deleted.
    async fn soft_delete_for_customer(&self, customer_id: Uuid, id: Uuid) -> Result<(), RepoError>;
}

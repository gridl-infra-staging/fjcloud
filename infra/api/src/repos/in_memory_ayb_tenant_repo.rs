//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/in_memory_ayb_tenant_repo.rs.
use async_trait::async_trait;
use chrono::Utc;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use crate::models::ayb_tenant::{AybTenant, NewAybTenant};
use crate::repos::ayb_tenant_repo::AybTenantRepo;
use crate::repos::error::RepoError;

#[derive(Clone, Default)]
pub struct InMemoryAybTenantRepo {
    tenants: Arc<Mutex<HashMap<Uuid, AybTenant>>>,
}

impl InMemoryAybTenantRepo {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl AybTenantRepo for InMemoryAybTenantRepo {
    /// In-memory AYB tenant creation for tests/local dev. Enforces active-customer
    /// and active-slug uniqueness via HashMap scan (no SQL transactions).
    async fn create(&self, new: NewAybTenant) -> Result<AybTenant, RepoError> {
        let mut tenants = self.tenants.lock().unwrap();

        let has_active_customer = tenants
            .values()
            .any(|t| t.customer_id == new.customer_id && t.deleted_at.is_none());
        if has_active_customer {
            return Err(RepoError::Conflict(
                "customer already has an active AYB tenant".into(),
            ));
        }

        let has_active_slug = tenants.values().any(|t| {
            t.ayb_cluster_id == new.ayb_cluster_id
                && t.ayb_slug == new.ayb_slug
                && t.deleted_at.is_none()
        });
        if has_active_slug {
            return Err(RepoError::Conflict(
                "AYB slug already taken in cluster".into(),
            ));
        }

        let now = Utc::now();
        let tenant = AybTenant {
            id: Uuid::new_v4(),
            customer_id: new.customer_id,
            ayb_tenant_id: new.ayb_tenant_id,
            ayb_slug: new.ayb_slug,
            ayb_cluster_id: new.ayb_cluster_id,
            ayb_url: new.ayb_url,
            status: new.status.to_string(),
            plan: new.plan.as_str().to_string(),
            created_at: now,
            updated_at: now,
            deleted_at: None,
        };
        tenants.insert(tenant.id, tenant.clone());
        Ok(tenant)
    }

    async fn find_active_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<AybTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        Ok(tenants
            .values()
            .filter(|t| t.customer_id == customer_id && t.deleted_at.is_none())
            .cloned()
            .collect())
    }

    async fn find_active_by_customer_and_id(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AybTenant>, RepoError> {
        let tenants = self.tenants.lock().unwrap();
        Ok(tenants
            .get(&id)
            .filter(|t| t.customer_id == customer_id && t.deleted_at.is_none())
            .cloned())
    }

    /// Soft-deletes by setting `deleted_at` and status to "deleting". Returns
    /// `NotFound` if no active tenant matches the (customer_id, id) pair.
    async fn soft_delete_for_customer(&self, customer_id: Uuid, id: Uuid) -> Result<(), RepoError> {
        let mut tenants = self.tenants.lock().unwrap();
        let tenant = tenants
            .get_mut(&id)
            .filter(|t| t.customer_id == customer_id && t.deleted_at.is_none());
        match tenant {
            Some(t) => {
                let now = Utc::now();
                t.deleted_at = Some(now);
                t.updated_at = now;
                t.status = "deleting".to_string();
                Ok(())
            }
            None => Err(RepoError::NotFound),
        }
    }
}

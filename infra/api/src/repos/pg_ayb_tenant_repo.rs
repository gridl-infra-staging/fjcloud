//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_ayb_tenant_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::ayb_tenant::{AybTenant, NewAybTenant};
use crate::repos::ayb_tenant_repo::AybTenantRepo;
use crate::repos::error::{is_unique_violation, RepoError};

pub struct PgAybTenantRepo {
    pool: PgPool,
}

impl PgAybTenantRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl AybTenantRepo for PgAybTenantRepo {
    /// Inserts a new AYB tenant and returns the created record.
    /// Returns `Conflict` if an active instance already exists for the customer or slug.
    async fn create(&self, tenant: NewAybTenant) -> Result<AybTenant, RepoError> {
        sqlx::query_as::<_, AybTenant>(
            "INSERT INTO ayb_tenants \
                 (customer_id, ayb_tenant_id, ayb_slug, ayb_cluster_id, ayb_url, status, plan) \
             VALUES ($1, $2, $3, $4, $5, $6, $7) \
             RETURNING *",
        )
        .bind(tenant.customer_id)
        .bind(&tenant.ayb_tenant_id)
        .bind(&tenant.ayb_slug)
        .bind(&tenant.ayb_cluster_id)
        .bind(&tenant.ayb_url)
        .bind(tenant.status.as_str())
        .bind(tenant.plan.as_str())
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(
                    "active AYB instance already exists for this customer or slug".to_string(),
                )
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn find_active_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Vec<AybTenant>, RepoError> {
        sqlx::query_as::<_, AybTenant>(
            "SELECT * FROM ayb_tenants \
             WHERE customer_id = $1 AND deleted_at IS NULL \
             ORDER BY created_at",
        )
        .bind(customer_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_active_by_customer_and_id(
        &self,
        customer_id: Uuid,
        id: Uuid,
    ) -> Result<Option<AybTenant>, RepoError> {
        sqlx::query_as::<_, AybTenant>(
            "SELECT * FROM ayb_tenants \
             WHERE customer_id = $1 AND id = $2 AND deleted_at IS NULL",
        )
        .bind(customer_id)
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Soft-deletes an AYB tenant by setting `deleted_at` and `updated_at`.
    /// Only affects non-deleted rows; returns `NotFound` if no row is updated.
    async fn soft_delete_for_customer(&self, customer_id: Uuid, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE ayb_tenants \
             SET deleted_at = NOW(), updated_at = NOW() \
             WHERE customer_id = $1 AND id = $2 AND deleted_at IS NULL",
        )
        .bind(customer_id)
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }
}

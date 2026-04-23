//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_vm_inventory_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::repos::error::RepoError;
use crate::repos::vm_inventory_repo::VmInventoryRepo;

pub struct PgVmInventoryRepo {
    pool: PgPool,
}

impl PgVmInventoryRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl VmInventoryRepo for PgVmInventoryRepo {
    /// Lists VMs with `active` status, optionally filtered by region,
    /// ordered by creation time.
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        match region {
            Some(r) => {
                sqlx::query_as::<_, VmInventory>(
                    "SELECT * FROM vm_inventory WHERE status = 'active' AND region = $1 ORDER BY created_at",
                )
                .bind(r)
                .fetch_all(&self.pool)
                .await
            }
            None => {
                sqlx::query_as::<_, VmInventory>(
                    "SELECT * FROM vm_inventory WHERE status = 'active' ORDER BY created_at",
                )
                .fetch_all(&self.pool)
                .await
            }
        }
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError> {
        sqlx::query_as::<_, VmInventory>("SELECT * FROM vm_inventory WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn create(&self, vm: NewVmInventory) -> Result<VmInventory, RepoError> {
        sqlx::query_as::<_, VmInventory>(
            "INSERT INTO vm_inventory (region, provider, hostname, flapjack_url, capacity) \
             VALUES ($1, $2, $3, $4, $5) RETURNING *",
        )
        .bind(&vm.region)
        .bind(&vm.provider)
        .bind(&vm.hostname)
        .bind(&vm.flapjack_url)
        .bind(&vm.capacity)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn update_load(&self, id: Uuid, load: serde_json::Value) -> Result<(), RepoError> {
        sqlx::query(
            "UPDATE vm_inventory \
             SET current_load = $1, load_scraped_at = NOW(), updated_at = NOW() \
             WHERE id = $2",
        )
        .bind(&load)
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(())
    }

    async fn set_status(&self, id: Uuid, status: &str) -> Result<(), RepoError> {
        sqlx::query("UPDATE vm_inventory SET status = $1, updated_at = NOW() WHERE id = $2")
            .bind(status)
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(())
    }

    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError> {
        sqlx::query_as::<_, VmInventory>("SELECT * FROM vm_inventory WHERE hostname = $1")
            .bind(hostname)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }
}

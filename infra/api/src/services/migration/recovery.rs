//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/migration/recovery.rs.
use chrono::{DateTime, Utc};
use tracing::warn;
use uuid::Uuid;

use crate::models::index_migration::IndexMigration;
use crate::models::vm_inventory::VmInventory;

use super::{MigrationError, MigrationService, MigrationStatus};

impl MigrationService {
    pub async fn rollback(&self, migration_id: Uuid) -> Result<(), MigrationError> {
        let migration = self.load_migration_for_rollback(migration_id).await?;
        self.rollback_by_status(&migration).await?;
        self.mark_rolled_back(migration.id).await?;

        Ok(())
    }

    async fn load_migration_for_rollback(
        &self,
        migration_id: Uuid,
    ) -> Result<IndexMigration, MigrationError> {
        self.migration_repo
            .get(migration_id)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?
            .ok_or(MigrationError::MigrationNotFound(migration_id))
    }

    async fn rollback_by_status(&self, migration: &IndexMigration) -> Result<(), MigrationError> {
        match migration.status.as_str() {
            "replicating" => self.rollback_replicating(migration).await,
            "cutting_over" => self.rollback_after_source_pause(migration).await,
            "completed" => self.rollback_completed(migration).await,
            status => Err(MigrationError::RollbackUnsupportedStatus {
                migration_id: migration.id,
                status: status.to_string(),
            }),
        }
    }

    async fn rollback_replicating(&self, migration: &IndexMigration) -> Result<(), MigrationError> {
        let dest_vm = self.load_vm(migration.dest_vm_id).await?;

        // Flapjack exposes replication start but no explicit stop endpoint today.
        // Deleting the destination index tears down the replica state.
        self.delete_index(&dest_vm.flapjack_url, &migration.index_name)
            .await?;

        self.set_index_active(migration.customer_id, &migration.index_name)
            .await
    }

    async fn rollback_after_source_pause(
        &self,
        migration: &IndexMigration,
    ) -> Result<(), MigrationError> {
        let source_vm = self.load_vm(migration.source_vm_id).await?;
        self.restore_source_assignment(migration, &source_vm).await
    }

    async fn rollback_completed(&self, migration: &IndexMigration) -> Result<(), MigrationError> {
        self.ensure_rollback_window_open(migration)?;
        let source_vm = self.load_vm(migration.source_vm_id).await?;
        self.restore_source_assignment(migration, &source_vm).await
    }

    /// Validates that the rollback window has not expired for a completed
    /// migration. Returns [`MigrationError::RollbackWindowExpired`] if
    /// `now > completed_at + rollback_window`, or [`MigrationError::Protocol`]
    /// if `completed_at` is missing.
    fn ensure_rollback_window_open(
        &self,
        migration: &IndexMigration,
    ) -> Result<(), MigrationError> {
        let completed_at = migration.completed_at.ok_or_else(|| {
            MigrationError::Protocol(format!(
                "completed migration '{}' missing completed_at",
                migration.id
            ))
        })?;
        let deadline = completed_at + self.rollback_window;
        if Utc::now() > deadline {
            return Err(MigrationError::RollbackWindowExpired {
                migration_id: migration.id,
                completed_at,
                deadline,
            });
        }

        Ok(())
    }

    /// Reverts an index back to its source VM: resumes the index on the
    /// source, reassigns the tenant's `vm_id`, invalidates the discovery
    /// cache, and resets the tier to "active".
    async fn restore_source_assignment(
        &self,
        migration: &IndexMigration,
        source_vm: &VmInventory,
    ) -> Result<(), MigrationError> {
        self.resume_index(source_vm, &migration.index_name).await?;

        self.tenant_repo
            .set_vm_id(
                migration.customer_id,
                &migration.index_name,
                migration.source_vm_id,
            )
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))?;

        self.discovery_cache
            .invalidate(migration.customer_id, &migration.index_name);

        self.set_index_active(migration.customer_id, &migration.index_name)
            .await
    }

    async fn set_index_active(
        &self,
        customer_id: Uuid,
        index_name: &str,
    ) -> Result<(), MigrationError> {
        self.tenant_repo
            .set_tier(customer_id, index_name, "active")
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))
    }

    async fn mark_rolled_back(&self, migration_id: Uuid) -> Result<(), MigrationError> {
        self.migration_repo
            .update_status(migration_id, MigrationStatus::RolledBack.as_str(), None)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))
    }

    /// Best-effort recovery after a migration failure: resumes the index on
    /// the source VM, reassigns the tenant's `vm_id` back to source, and
    /// optionally deletes the destination index if replication had started.
    /// Invalidates the discovery cache. Returns the first error encountered
    /// but attempts all steps regardless.
    pub(super) async fn recover_source_on_failure(
        &self,
        req: &super::MigrationRequest,
        source_vm: &VmInventory,
        dest_vm: &VmInventory,
        cleanup_destination: bool,
    ) -> Result<(), MigrationError> {
        let mut first_error: Option<MigrationError> = None;

        if let Err(err) = self.resume_index(source_vm, &req.index_name).await {
            first_error = Some(err);
        }

        if let Err(err) = self
            .tenant_repo
            .set_vm_id(req.customer_id, &req.index_name, req.source_vm_id)
            .await
            .map_err(|repo_err| MigrationError::Repo(repo_err.to_string()))
        {
            if first_error.is_none() {
                first_error = Some(err);
            }
        }

        if cleanup_destination {
            if let Err(err) = self
                .delete_index(&dest_vm.flapjack_url, &req.index_name)
                .await
            {
                warn!(
                    customer_id = %req.customer_id,
                    index_name = %req.index_name,
                    source_vm_id = %source_vm.id,
                    dest_vm_id = %dest_vm.id,
                    error = %err,
                    "failed best-effort destination index cleanup after migration failure"
                );
            }
        }

        self.discovery_cache
            .invalidate(req.customer_id, &req.index_name);

        match first_error {
            Some(err) => Err(err),
            None => Ok(()),
        }
    }

    #[allow(dead_code)]
    pub fn rollback_deadline_from(&self, completed_at: DateTime<Utc>) -> DateTime<Utc> {
        completed_at + self.rollback_window
    }
}

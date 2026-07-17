use chrono::{DateTime, Utc};
use tracing::warn;
use uuid::Uuid;

use crate::models::index_migration::IndexMigration;
use crate::models::vm_inventory::VmInventory;
use crate::repos::CatalogLifecycleTargetIdentity;
use crate::services::flapjack_node::flapjack_index_uid;

use super::{MigrationError, MigrationService, MigrationStatus};

impl MigrationService {
    pub async fn rollback(&self, migration_id: Uuid) -> Result<(), MigrationError> {
        let migration = self.load_migration_for_rollback(migration_id).await?;
        self.ensure_rollback_status_supported(&migration)?;
        let expected_identity = self.intent_target_identity_for_rollback(&migration)?;
        self.guard_rollback_admission(&migration, &expected_identity)
            .await?;
        self.rollback_by_status(&migration).await?;
        self.publish_rollback(&migration, &expected_identity)
            .await?;

        Ok(())
    }

    fn ensure_rollback_status_supported(
        &self,
        migration: &IndexMigration,
    ) -> Result<(), MigrationError> {
        if matches!(
            migration.status.as_str(),
            "replicating" | "cutting_over" | "completed"
        ) {
            return Ok(());
        }

        Err(MigrationError::RollbackUnsupportedStatus {
            migration_id: migration.id,
            status: migration.status.clone(),
        })
    }

    fn intent_target_identity_for_rollback(
        &self,
        migration: &IndexMigration,
    ) -> Result<CatalogLifecycleTargetIdentity, MigrationError> {
        migration.intent_target_identity().map_err(|err| {
            MigrationError::Protocol(format!(
                "migration '{}' cannot roll back without captured catalog lifecycle identity: {err}",
                migration.id
            ))
        })
    }

    async fn guard_rollback_admission(
        &self,
        migration: &IndexMigration,
        expected_identity: &CatalogLifecycleTargetIdentity,
    ) -> Result<(), MigrationError> {
        self.guarded_target_mutation(
            migration.customer_id,
            &migration.index_name,
            Some(expected_identity),
            || async { Ok(()) },
        )
        .await
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
        let index_uid = flapjack_index_uid(migration.customer_id, &migration.index_name);
        self.delete_index_observing(
            "migration.recovery.rollback_replicating",
            &dest_vm,
            &index_uid,
        )
        .await
    }

    async fn rollback_after_source_pause(
        &self,
        migration: &IndexMigration,
    ) -> Result<(), MigrationError> {
        self.ensure_source_restore_allowed(migration)?;
        let source_vm = self.load_vm(migration.source_vm_id).await?;
        self.resume_source_index(migration, &source_vm).await
    }

    async fn rollback_completed(&self, migration: &IndexMigration) -> Result<(), MigrationError> {
        self.ensure_rollback_window_open(migration)?;
        self.ensure_source_restore_allowed(migration)?;
        let source_vm = self.load_vm(migration.source_vm_id).await?;
        self.resume_source_index(migration, &source_vm).await
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

    pub(super) async fn set_source_restore_allowed(
        &self,
        migration_id: Uuid,
        allowed: bool,
    ) -> Result<(), MigrationError> {
        let migration = self.load_migration_for_rollback(migration_id).await?;
        let metadata = migration.metadata_with_source_restore_allowed(allowed);
        self.migration_repo
            .update_metadata(migration_id, metadata)
            .await
            .map_err(|err| MigrationError::Repo(err.to_string()))
    }

    fn ensure_source_restore_allowed(
        &self,
        migration: &IndexMigration,
    ) -> Result<(), MigrationError> {
        if migration.source_restore_allowed() {
            return Ok(());
        }

        Err(MigrationError::Protocol(format!(
            "source rollback fence closed for migration '{}'",
            migration.id
        )))
    }

    async fn resume_source_index(
        &self,
        migration: &IndexMigration,
        source_vm: &VmInventory,
    ) -> Result<(), MigrationError> {
        let index_uid = flapjack_index_uid(migration.customer_id, &migration.index_name);
        self.resume_index(source_vm, &index_uid).await
    }

    async fn publish_rollback(
        &self,
        migration: &IndexMigration,
        expected_identity: &CatalogLifecycleTargetIdentity,
    ) -> Result<(), MigrationError> {
        self.guarded_target_mutation(
            migration.customer_id,
            &migration.index_name,
            Some(expected_identity),
            || async {
                self.tenant_repo
                    .publish_lifecycle_placement(
                        migration.customer_id,
                        &migration.index_name,
                        expected_identity,
                        Some(migration.source_vm_id),
                    )
                    .await?;
                self.migration_repo
                    .update_status(migration.id, MigrationStatus::RolledBack.as_str(), None)
                    .await
            },
        )
        .await?;

        self.discovery_cache
            .invalidate(migration.customer_id, &migration.index_name);
        Ok(())
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
        source_restore_allowed: bool,
        expected_identity: Option<&CatalogLifecycleTargetIdentity>,
    ) -> Result<(), MigrationError> {
        let mut first_error: Option<MigrationError> = None;

        let index_uid = flapjack_index_uid(req.customer_id, &req.index_name);

        if source_restore_allowed {
            if let Err(err) = self.resume_index(source_vm, &index_uid).await {
                first_error = Some(err);
            }

            match expected_identity {
                Some(identity) => {
                    if let Err(err) = self
                        .guarded_target_mutation(
                            req.customer_id,
                            &req.index_name,
                            Some(identity),
                            || async {
                                self.tenant_repo
                                    .publish_lifecycle_placement(
                                        req.customer_id,
                                        &req.index_name,
                                        identity,
                                        Some(req.source_vm_id),
                                    )
                                    .await
                                    .map(|_| ())
                            },
                        )
                        .await
                    {
                        if first_error.is_none() {
                            first_error = Some(err);
                        }
                    }
                }
                None => {
                    if first_error.is_none() {
                        first_error = Some(MigrationError::Protocol(format!(
                            "migration recovery for '{}' missing catalog lifecycle intent identity",
                            req.index_name
                        )));
                    }
                }
            }
        }

        if cleanup_destination && source_restore_allowed {
            if let Err(err) = self
                .delete_index_observing(
                    "migration.recovery.recover_source_on_failure",
                    dest_vm,
                    &index_uid,
                )
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

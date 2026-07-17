use async_trait::async_trait;
use uuid::Uuid;

use crate::models::index_migration::IndexMigration;
use crate::repos::error::RepoError;
use crate::services::migration::MigrationRequest;

/// Index-migration repository: tracks live index migrations between VMs.
/// Records creation, status transitions, completion timestamps, and provides
/// active/recent queries for the migration orchestrator.
#[async_trait]
pub trait IndexMigrationRepo {
    /// Lookup a migration by id.
    async fn get(&self, id: Uuid) -> Result<Option<IndexMigration>, RepoError>;

    /// Insert a new migration record.
    async fn create(&self, req: &MigrationRequest) -> Result<IndexMigration, RepoError>;

    /// Update status and optional error details.
    async fn update_status(
        &self,
        id: Uuid,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), RepoError>;

    /// Mark a migration completed and set completion timestamp.
    async fn set_completed(&self, id: Uuid) -> Result<(), RepoError>;

    /// Replace the metadata JSON for an existing migration row.
    async fn update_metadata(&self, id: Uuid, metadata: serde_json::Value)
        -> Result<(), RepoError>;

    /// Active migrations (pending/replicating/cutting_over).
    async fn list_active(&self) -> Result<Vec<IndexMigration>, RepoError>;

    /// Most recent migration rows.
    async fn list_recent(&self, limit: i64) -> Result<Vec<IndexMigration>, RepoError>;

    /// Count of active migrations.
    async fn count_active(&self) -> Result<i64, RepoError>;
}

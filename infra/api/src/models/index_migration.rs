use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from `index_migrations` tracking index movement across VMs.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct IndexMigration {
    pub id: Uuid,
    pub index_name: String,
    pub customer_id: Uuid,
    pub source_vm_id: Uuid,
    pub dest_vm_id: Uuid,
    pub status: String,
    pub requested_by: String,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub error: Option<String>,
    pub metadata: serde_json::Value,
}

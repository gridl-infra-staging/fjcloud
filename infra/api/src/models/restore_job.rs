use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from `restore_jobs` — async restore of cold indexes back to active VMs.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct RestoreJob {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub snapshot_id: Uuid,
    pub dest_vm_id: Option<Uuid>,
    pub status: String,
    pub idempotency_key: String,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
}

/// Input struct for creating a new restore job.
#[derive(Debug, Clone)]
pub struct NewRestoreJob {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub snapshot_id: Uuid,
    pub dest_vm_id: Option<Uuid>,
    pub idempotency_key: String,
}

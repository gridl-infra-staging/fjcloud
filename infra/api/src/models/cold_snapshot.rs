use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from `cold_snapshots` — index data exported to object storage.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct ColdSnapshot {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub source_vm_id: Uuid,
    pub object_key: String,
    pub size_bytes: i64,
    pub checksum: Option<String>,
    pub status: String,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
}

/// Input struct for creating a new cold snapshot.
#[derive(Debug, Clone)]
pub struct NewColdSnapshot {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub source_vm_id: Uuid,
    pub object_key: String,
}

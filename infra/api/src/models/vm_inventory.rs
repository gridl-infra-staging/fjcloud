use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct VmInventory {
    pub id: Uuid,
    pub region: String,
    pub provider: String,
    pub hostname: String,
    pub flapjack_url: String,
    pub capacity: serde_json::Value,
    pub current_load: serde_json::Value,
    pub load_scraped_at: Option<DateTime<Utc>>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl VmInventory {
    /// Shared-VM proxy traffic must use a stable VM-owned secret identifier rather
    /// than a per-customer deployment node_id. Hostname is unique in vm_inventory
    /// and already persists with the VM for its whole lifetime.
    pub fn node_secret_id(&self) -> &str {
        &self.hostname
    }
}

/// Input struct for creating a new VM inventory entry.
#[derive(Debug, Clone)]
pub struct NewVmInventory {
    pub region: String,
    pub provider: String,
    pub hostname: String,
    pub flapjack_url: String,
    pub capacity: serde_json::Value,
}

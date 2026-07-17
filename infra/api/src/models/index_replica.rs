use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from `index_replicas` — a persistent read-only copy of an index on
/// a different VM, kept in sync via continuous replication.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct IndexReplica {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub primary_vm_id: Uuid,
    pub replica_vm_id: Uuid,
    pub replica_region: String,
    pub status: String,
    pub lag_ops: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Enriched view for admin API responses — includes VM hostnames and flapjack URLs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexReplicaSummary {
    pub id: Uuid,
    pub replica_region: String,
    pub status: String,
    pub lag_ops: i64,
    pub replica_vm_hostname: String,
    pub replica_flapjack_url: String,
    pub created_at: DateTime<Utc>,
}

/// Customer-facing view — omits VM hostname, renames flapjack_url to endpoint.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct CustomerIndexReplicaSummary {
    pub id: Uuid,
    pub replica_region: String,
    pub status: String,
    pub lag_ops: i64,
    pub endpoint: String,
    pub created_at: DateTime<Utc>,
}

impl IndexReplicaSummary {
    pub fn to_customer_summary(&self) -> CustomerIndexReplicaSummary {
        CustomerIndexReplicaSummary {
            id: self.id,
            replica_region: self.replica_region.clone(),
            status: self.status.clone(),
            lag_ops: self.lag_ops,
            endpoint: self.replica_flapjack_url.clone(),
            created_at: self.created_at,
        }
    }
}

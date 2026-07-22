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
    #[serde(skip)]
    pub replica_vm_id: Uuid,
    pub replica_vm_hostname: String,
    pub replica_flapjack_url: String,
    pub created_at: DateTime<Utc>,
}

/// Customer-facing view — omits internal VM details while exposing the
/// stable endpoint clients can use for this replica.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct CustomerIndexReplicaSummary {
    pub id: Uuid,
    pub replica_region: String,
    pub status: String,
    pub lag_ops: i64,
    pub endpoint: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl IndexReplicaSummary {
    pub fn to_customer_summary(&self) -> CustomerIndexReplicaSummary {
        CustomerIndexReplicaSummary {
            id: self.id,
            replica_region: self.replica_region.clone(),
            status: self.status.clone(),
            lag_ops: self.lag_ops,
            endpoint: Some(self.replica_flapjack_url.clone()),
            created_at: self.created_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    #[test]
    fn customer_summary_exposes_endpoint_and_omits_internal_vm_details() {
        let summary = IndexReplicaSummary {
            id: Uuid::parse_str("aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa").unwrap(),
            replica_region: "eu-central-1".to_string(),
            status: "active".to_string(),
            lag_ops: 37,
            replica_vm_id: Uuid::parse_str("bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb").unwrap(),
            replica_vm_hostname: "private-replica.internal".to_string(),
            replica_flapjack_url: "https://replica-public.flapjack.foo".to_string(),
            created_at: Utc::now(),
        };

        let customer = serde_json::to_value(summary.to_customer_summary()).unwrap();
        assert_eq!(customer["endpoint"], "https://replica-public.flapjack.foo");

        let serialized = customer.to_string();
        for forbidden in [
            "replica_vm_id",
            "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
            "replica_vm_hostname",
            "private-replica.internal",
            "replica_flapjack_url",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "customer replica response leaked {forbidden}: {serialized}"
            );
        }
    }
}

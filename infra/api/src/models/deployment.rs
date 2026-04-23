//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/models/deployment.rs.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// VM deployment record with node ID, region, VM type/provider, IP address,
/// status, hostname, flapjack URL, and health-check fields.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Deployment {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub node_id: String,
    pub region: String,
    pub vm_type: String,
    pub vm_provider: String,
    pub ip_address: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub terminated_at: Option<DateTime<Utc>>,
    pub provider_vm_id: Option<String>,
    pub hostname: Option<String>,
    pub flapjack_url: Option<String>,
    pub last_health_check_at: Option<DateTime<Utc>>,
    pub health_status: String,
}

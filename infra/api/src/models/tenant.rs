use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A row from the `customer_tenants` table — maps a flapjack index name to a customer and deployment.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CustomerTenant {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub deployment_id: Uuid,
    pub created_at: DateTime<Utc>,
    pub vm_id: Option<Uuid>,
    pub tier: String,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub cold_snapshot_id: Option<Uuid>,
    pub resource_quota: serde_json::Value,
    pub service_type: String,
}

/// Enriched view joining `customer_tenants` with `customer_deployments` — includes region,
/// flapjack_url, and health_status from the deployment, plus tier info from customer_tenants.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CustomerTenantSummary {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub deployment_id: Uuid,
    pub created_at: DateTime<Utc>,
    pub region: String,
    pub flapjack_url: Option<String>,
    pub health_status: String,
    pub tier: String,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub cold_snapshot_id: Option<Uuid>,
    pub service_type: String,
}

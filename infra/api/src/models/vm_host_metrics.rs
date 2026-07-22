use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, sqlx::FromRow)]
pub struct VmHostMetrics {
    pub id: Uuid,
    pub vm_id: Uuid,
    pub collected_at: DateTime<Utc>,
    pub cpu_pct: f64,
    pub mem_used_bytes: i64,
    pub mem_total_bytes: i64,
    pub disk_used_bytes: Option<i64>,
    pub disk_total_bytes: Option<i64>,
    pub net_rx_bytes: i64,
    pub net_tx_bytes: i64,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewVmHostMetrics {
    pub vm_id: Uuid,
    pub collected_at: DateTime<Utc>,
    pub cpu_pct: f64,
    pub mem_used_bytes: i64,
    pub mem_total_bytes: i64,
    pub disk_used_bytes: Option<i64>,
    pub disk_total_bytes: Option<i64>,
    pub net_rx_bytes: i64,
    pub net_tx_bytes: i64,
}

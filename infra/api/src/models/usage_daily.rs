use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct UsageDaily {
    pub customer_id: Uuid,
    pub date: NaiveDate,
    pub region: String,
    pub search_requests: i64,
    pub write_operations: i64,
    pub storage_bytes_avg: i64,
    pub documents_count_avg: i64,
    pub aggregated_at: DateTime<Utc>,
}

impl From<&UsageDaily> for billing::types::DailyUsageRecord {
    fn from(u: &UsageDaily) -> Self {
        billing::types::DailyUsageRecord {
            customer_id: u.customer_id,
            date: u.date,
            region: u.region.clone(),
            search_requests: u.search_requests,
            write_operations: u.write_operations,
            storage_bytes_avg: u.storage_bytes_avg,
            documents_count_avg: u.documents_count_avg,
        }
    }
}

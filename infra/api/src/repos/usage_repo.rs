use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::models::UsageDaily;
use crate::repos::error::RepoError;

#[async_trait]
pub trait UsageRepo {
    async fn get_daily_usage(
        &self,
        customer_id: Uuid,
        start_date: NaiveDate,
        end_date: NaiveDate,
    ) -> Result<Vec<UsageDaily>, RepoError>;

    async fn get_monthly_search_count(
        &self,
        customer_id: Uuid,
        year: i32,
        month: u32,
    ) -> Result<i64, RepoError>;
}

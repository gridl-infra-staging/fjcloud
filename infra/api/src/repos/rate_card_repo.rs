//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/rate_card_repo.rs.
use async_trait::async_trait;
use uuid::Uuid;

use crate::models::{CustomerRateOverrideRow, RateCardRow};
use crate::repos::error::RepoError;

/// Pricing rate-card repository: retrieves the single active rate card and
/// manages per-customer JSONB rate overrides via upsert.
#[async_trait]
pub trait RateCardRepo {
    async fn get_active(&self) -> Result<Option<RateCardRow>, RepoError>;

    async fn get_by_id(&self, id: Uuid) -> Result<Option<RateCardRow>, RepoError>;

    async fn get_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
    ) -> Result<Option<CustomerRateOverrideRow>, RepoError>;

    async fn upsert_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
        overrides: serde_json::Value,
    ) -> Result<CustomerRateOverrideRow, RepoError>;
}

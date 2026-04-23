//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_rate_card_repo.rs.
use async_trait::async_trait;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{CustomerRateOverrideRow, RateCardRow};
use crate::repos::error::RepoError;
use crate::repos::rate_card_repo::RateCardRepo;

pub struct PgRateCardRepo {
    pool: PgPool,
}

impl PgRateCardRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl RateCardRepo for PgRateCardRepo {
    async fn get_active(&self) -> Result<Option<RateCardRow>, RepoError> {
        sqlx::query_as::<_, RateCardRow>(
            "SELECT * FROM rate_cards WHERE effective_until IS NULL ORDER BY effective_from DESC LIMIT 1",
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get_by_id(&self, id: Uuid) -> Result<Option<RateCardRow>, RepoError> {
        sqlx::query_as::<_, RateCardRow>("SELECT * FROM rate_cards WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn get_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
    ) -> Result<Option<CustomerRateOverrideRow>, RepoError> {
        sqlx::query_as::<_, CustomerRateOverrideRow>(
            "SELECT * FROM customer_rate_overrides \
             WHERE customer_id = $1 AND rate_card_id = $2",
        )
        .bind(customer_id)
        .bind(rate_card_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Inserts or replaces a customer rate override using
    /// `ON CONFLICT DO UPDATE`, returning the resulting row.
    async fn upsert_override(
        &self,
        customer_id: Uuid,
        rate_card_id: Uuid,
        overrides: serde_json::Value,
    ) -> Result<CustomerRateOverrideRow, RepoError> {
        sqlx::query_as::<_, CustomerRateOverrideRow>(
            "INSERT INTO customer_rate_overrides (customer_id, rate_card_id, overrides) \
             VALUES ($1, $2, $3) \
             ON CONFLICT (customer_id, rate_card_id) DO UPDATE SET overrides = $3 \
             RETURNING *",
        )
        .bind(customer_id)
        .bind(rate_card_id)
        .bind(overrides)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }
}

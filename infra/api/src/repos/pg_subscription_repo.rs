//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/pg_subscription_repo.rs.
use async_trait::async_trait;
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

use crate::models::{PlanTier, SubscriptionRow, SubscriptionStatus};
use crate::repos::error::{is_unique_violation, RepoError};
use crate::repos::subscription_repo::{NewSubscription, SubscriptionRepo};

pub struct PgSubscriptionRepo {
    pool: PgPool,
}

impl PgSubscriptionRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl SubscriptionRepo for PgSubscriptionRepo {
    /// Inserts a new subscription row and returns the created record.
    /// Returns `RepoError::AlreadyExists` on unique-constraint violation.
    async fn create(&self, subscription: NewSubscription) -> Result<SubscriptionRow, RepoError> {
        sqlx::query_as::<_, SubscriptionRow>(
            "INSERT INTO subscriptions \
             (customer_id, stripe_subscription_id, stripe_price_id, plan_tier, status, \
              current_period_start, current_period_end, cancel_at_period_end) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8) \
             RETURNING *",
        )
        .bind(subscription.customer_id)
        .bind(&subscription.stripe_subscription_id)
        .bind(&subscription.stripe_price_id)
        .bind(subscription.plan_tier.as_str())
        .bind(subscription.status.as_str())
        .bind(subscription.current_period_start)
        .bind(subscription.current_period_end)
        .bind(subscription.cancel_at_period_end)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                RepoError::Conflict(
                    "subscription already exists for this customer or stripe subscription id"
                        .into(),
                )
            } else {
                RepoError::Other(e.to_string())
            }
        })
    }

    async fn find_by_id(&self, id: Uuid) -> Result<Option<SubscriptionRow>, RepoError> {
        sqlx::query_as::<_, SubscriptionRow>("SELECT * FROM subscriptions WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Option<SubscriptionRow>, RepoError> {
        sqlx::query_as::<_, SubscriptionRow>(
            "SELECT * FROM subscriptions \
             WHERE customer_id = $1 AND status != 'canceled' \
             ORDER BY created_at DESC \
             LIMIT 1",
        )
        .bind(customer_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_stripe_id(
        &self,
        stripe_subscription_id: &str,
    ) -> Result<Option<SubscriptionRow>, RepoError> {
        sqlx::query_as::<_, SubscriptionRow>(
            "SELECT * FROM subscriptions WHERE stripe_subscription_id = $1",
        )
        .bind(stripe_subscription_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    /// Updates the subscription status by id.
    /// Returns `RepoError::NotFound` if no row matches.
    async fn update_status(&self, id: Uuid, status: SubscriptionStatus) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE subscriptions \
             SET status = $2, updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(status.as_str())
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Updates the plan tier and Stripe price id for a subscription.
    async fn update_plan(
        &self,
        id: Uuid,
        plan_tier: PlanTier,
        stripe_price_id: &str,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE subscriptions \
             SET plan_tier = $2, stripe_price_id = $3, updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(plan_tier.as_str())
        .bind(stripe_price_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Updates the billing period start and end timestamps.
    async fn update_period(
        &self,
        id: Uuid,
        period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE subscriptions \
             SET current_period_start = $2, current_period_end = $3, updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(period_start)
        .bind(period_end)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Sets the cancel-at-period-end flag on a subscription.
    async fn set_cancel_at_period_end(&self, id: Uuid, cancel: bool) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE subscriptions \
             SET cancel_at_period_end = $2, updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .bind(cancel)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }

    /// Marks a subscription as canceled and clears the cancel-at-period-end flag.
    async fn mark_canceled(&self, id: Uuid) -> Result<(), RepoError> {
        let result = sqlx::query(
            "UPDATE subscriptions \
             SET status = 'canceled', cancel_at_period_end = false, updated_at = NOW() \
             WHERE id = $1",
        )
        .bind(id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        if result.rows_affected() == 0 {
            return Err(RepoError::NotFound);
        }
        Ok(())
    }
}

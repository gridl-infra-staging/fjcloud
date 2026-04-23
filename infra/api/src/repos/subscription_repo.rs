use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::models::{PlanTier, SubscriptionRow, SubscriptionStatus};
use crate::repos::error::RepoError;

/// Input for creating a new subscription.
#[derive(Debug, Clone)]
pub struct NewSubscription {
    pub customer_id: Uuid,
    pub stripe_subscription_id: String,
    pub stripe_price_id: String,
    pub plan_tier: PlanTier,
    pub status: SubscriptionStatus,
    pub current_period_start: NaiveDate,
    pub current_period_end: NaiveDate,
    pub cancel_at_period_end: bool,
}

/// Repository trait for subscription lifecycle management.
#[async_trait]
pub trait SubscriptionRepo: Send + Sync {
    /// Creates a new subscription record.
    /// Returns Conflict error if customer already has a subscription or
    /// if stripe_subscription_id is already in use.
    async fn create(&self, subscription: NewSubscription) -> Result<SubscriptionRow, RepoError>;

    /// Finds a subscription by its UUID.
    async fn find_by_id(&self, id: Uuid) -> Result<Option<SubscriptionRow>, RepoError>;

    /// Finds the active subscription for a customer (if any).
    async fn find_by_customer(
        &self,
        customer_id: Uuid,
    ) -> Result<Option<SubscriptionRow>, RepoError>;

    /// Finds a subscription by its Stripe subscription ID.
    async fn find_by_stripe_id(
        &self,
        stripe_subscription_id: &str,
    ) -> Result<Option<SubscriptionRow>, RepoError>;

    /// Updates the subscription status (e.g., active → past_due).
    async fn update_status(&self, id: Uuid, status: SubscriptionStatus) -> Result<(), RepoError>;

    /// Updates the plan tier and associated Stripe price ID.
    async fn update_plan(
        &self,
        id: Uuid,
        plan_tier: PlanTier,
        stripe_price_id: &str,
    ) -> Result<(), RepoError>;

    /// Updates the current billing period boundaries.
    async fn update_period(
        &self,
        id: Uuid,
        period_start: NaiveDate,
        period_end: NaiveDate,
    ) -> Result<(), RepoError>;

    /// Sets or clears the cancel_at_period_end flag.
    async fn set_cancel_at_period_end(&self, id: Uuid, cancel: bool) -> Result<(), RepoError>;

    /// Soft-deletes a subscription by marking it as canceled.
    /// Use this when a subscription is fully canceled (not just cancel_at_period_end).
    async fn mark_canceled(&self, id: Uuid) -> Result<(), RepoError>;
}

//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/models/subscription.rs.
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use uuid::Uuid;

// Re-export PlanTier from the billing crate — single source of truth.
pub use billing::plan::PlanTier;

/// Represents a Stripe subscription for a customer.
/// One active subscription per customer (enforced by UNIQUE constraint).
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SubscriptionRow {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub stripe_subscription_id: String,
    pub stripe_price_id: String,
    pub plan_tier: String,
    pub status: String,
    pub current_period_start: NaiveDate,
    pub current_period_end: NaiveDate,
    pub cancel_at_period_end: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Subscription status enumeration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscriptionStatus {
    /// Subscription is active and in good standing.
    Active,
    /// Subscription has past due payment but retries are ongoing.
    PastDue,
    /// Subscription is in trial period.
    Trialing,
    /// Subscription has been canceled.
    Canceled,
    /// Subscription is unpaid after retries exhausted.
    Unpaid,
    /// Subscription is incomplete (e.g., pending payment method).
    Incomplete,
}

impl SubscriptionStatus {
    /// Returns the string representation used in the database.
    pub fn as_str(&self) -> &'static str {
        match self {
            SubscriptionStatus::Active => "active",
            SubscriptionStatus::PastDue => "past_due",
            SubscriptionStatus::Trialing => "trialing",
            SubscriptionStatus::Canceled => "canceled",
            SubscriptionStatus::Unpaid => "unpaid",
            SubscriptionStatus::Incomplete => "incomplete",
        }
    }

    /// Returns true if the subscription is in a state that allows API access.
    pub fn allows_access(&self) -> bool {
        matches!(
            self,
            SubscriptionStatus::Active | SubscriptionStatus::Trialing
        )
    }

    /// Returns true if the subscription is in a delinquent state.
    pub fn is_delinquent(&self) -> bool {
        matches!(
            self,
            SubscriptionStatus::PastDue | SubscriptionStatus::Unpaid
        )
    }
}

impl std::fmt::Display for SubscriptionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for SubscriptionStatus {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "active" => Ok(SubscriptionStatus::Active),
            "past_due" => Ok(SubscriptionStatus::PastDue),
            "trialing" => Ok(SubscriptionStatus::Trialing),
            "canceled" => Ok(SubscriptionStatus::Canceled),
            "unpaid" => Ok(SubscriptionStatus::Unpaid),
            "incomplete" => Ok(SubscriptionStatus::Incomplete),
            _ => Err(format!("unknown subscription status: {}", s)),
        }
    }
}

impl SubscriptionRow {
    /// Parses the `plan_tier` column into a typed `PlanTier`.
    pub fn parsed_plan_tier(&self) -> Result<PlanTier, String> {
        self.plan_tier.parse()
    }

    /// Parses the `status` column into a typed `SubscriptionStatus`.
    pub fn parsed_status(&self) -> Result<SubscriptionStatus, String> {
        self.status.parse()
    }
}

/// Subscription plan configuration from the database.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SubscriptionPlanRow {
    pub id: Uuid,
    pub tier: String,
    pub stripe_product_id: String,
    pub stripe_price_id: String,
    pub max_searches_per_month: i64,
    pub max_records: i64,
    pub max_storage_gb: i64,
    pub max_indexes: i32,
    pub price_cents_monthly: Option<i64>,
    pub created_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_subscription_status_allows_access() {
        assert!(SubscriptionStatus::Active.allows_access());
        assert!(SubscriptionStatus::Trialing.allows_access());
        assert!(!SubscriptionStatus::PastDue.allows_access());
        assert!(!SubscriptionStatus::Canceled.allows_access());
        assert!(!SubscriptionStatus::Unpaid.allows_access());
        assert!(!SubscriptionStatus::Incomplete.allows_access());
    }

    #[test]
    fn test_subscription_status_is_delinquent() {
        assert!(SubscriptionStatus::PastDue.is_delinquent());
        assert!(SubscriptionStatus::Unpaid.is_delinquent());
        assert!(!SubscriptionStatus::Active.is_delinquent());
        assert!(!SubscriptionStatus::Trialing.is_delinquent());
        assert!(!SubscriptionStatus::Canceled.is_delinquent());
        assert!(!SubscriptionStatus::Incomplete.is_delinquent());
    }

    /// Verifies that all [`SubscriptionStatus`] variants survive an
    /// `as_str` → `parse` roundtrip.
    #[test]
    fn test_subscription_status_roundtrip() {
        let all = [
            SubscriptionStatus::Active,
            SubscriptionStatus::PastDue,
            SubscriptionStatus::Trialing,
            SubscriptionStatus::Canceled,
            SubscriptionStatus::Unpaid,
            SubscriptionStatus::Incomplete,
        ];
        for status in all {
            let s = status.as_str();
            let parsed: SubscriptionStatus = s.parse().unwrap();
            assert_eq!(status, parsed, "roundtrip failed for {:?}", status);
            assert_eq!(format!("{}", status), s, "Display failed for {:?}", status);
        }
    }

    #[test]
    fn test_subscription_status_from_str_unknown_returns_error() {
        assert!("bogus".parse::<SubscriptionStatus>().is_err());
    }

    /// Verifies that a [`SubscriptionPlanRow`] accepts a null enterprise
    /// price field.
    #[test]
    fn test_subscription_plan_row_allows_null_enterprise_price() {
        let value = serde_json::json!({
            "id": Uuid::new_v4(),
            "tier": "enterprise",
            "stripe_product_id": "prod_enterprise",
            "stripe_price_id": "price_enterprise",
            "max_searches_per_month": 10_000_000_i64,
            "max_records": 100_000_000_i64,
            "max_storage_gb": 10_000_i64,
            "max_indexes": 1_000_i32,
            "price_cents_monthly": null,
            "created_at": Utc::now(),
        });

        let _row: SubscriptionPlanRow =
            serde_json::from_value(value).expect("enterprise plan row should deserialize");
    }
}

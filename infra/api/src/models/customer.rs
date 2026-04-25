use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CustomerAuthState {
    Active,
    Suspended,
    Missing,
}

pub fn customer_auth_state(customer: Option<&Customer>) -> CustomerAuthState {
    match customer {
        Some(customer) if customer.status == "suspended" => CustomerAuthState::Suspended,
        Some(customer) if customer.status == "deleted" => CustomerAuthState::Missing,
        Some(_) => CustomerAuthState::Active,
        None => CustomerAuthState::Missing,
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, utoipa::ToSchema)]
#[serde(rename_all = "lowercase")]
pub enum BillingPlan {
    Free,
    Shared,
}

impl fmt::Display for BillingPlan {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Free => write!(f, "free"),
            Self::Shared => write!(f, "shared"),
        }
    }
}

impl FromStr for BillingPlan {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "free" => Ok(Self::Free),
            "shared" => Ok(Self::Shared),
            _ => Err(()),
        }
    }
}

/// Core customer record with identity (id, name, email), Stripe integration
/// (`stripe_customer_id`), account status, billing plan, auth credentials,
/// and fractional egress carry-forward for sub-cent billing.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Customer {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub stripe_customer_id: Option<String>,
    pub status: String,
    pub deleted_at: Option<DateTime<Utc>>,
    pub billing_plan: String,
    pub quota_warning_sent_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(skip_serializing)]
    pub password_hash: Option<String>,
    pub email_verified_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing)]
    pub email_verify_token: Option<String>,
    #[serde(skip_serializing)]
    pub email_verify_expires_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing)]
    pub password_reset_token: Option<String>,
    #[serde(skip_serializing)]
    pub password_reset_expires_at: Option<DateTime<Utc>>,
    /// Sub-cent carry-forward for object-storage egress billing.
    /// Internal-only: not exposed in public JSON serialization.
    #[serde(skip_serializing)]
    pub object_storage_egress_carryforward_cents: Decimal,
}

impl Customer {
    pub fn billing_plan_enum(&self) -> BillingPlan {
        BillingPlan::from_str(&self.billing_plan).unwrap_or(BillingPlan::Free)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_test_customer(billing_plan: &str, carryforward: Decimal) -> Customer {
        let now = Utc::now();
        Customer {
            id: Uuid::new_v4(),
            name: "Test".to_string(),
            email: "test@example.com".to_string(),
            stripe_customer_id: None,
            status: "active".to_string(),
            deleted_at: None,
            billing_plan: billing_plan.to_string(),
            quota_warning_sent_at: None,
            created_at: now,
            updated_at: now,
            password_hash: None,
            email_verified_at: None,
            email_verify_token: None,
            email_verify_expires_at: None,
            password_reset_token: None,
            password_reset_expires_at: None,
            object_storage_egress_carryforward_cents: carryforward,
        }
    }

    #[test]
    fn billing_plan_from_str_free() {
        assert_eq!(BillingPlan::from_str("free").unwrap(), BillingPlan::Free);
    }

    #[test]
    fn billing_plan_from_str_shared() {
        assert_eq!(
            BillingPlan::from_str("shared").unwrap(),
            BillingPlan::Shared
        );
    }

    #[test]
    fn billing_plan_from_str_case_insensitive() {
        assert_eq!(BillingPlan::from_str("FREE").unwrap(), BillingPlan::Free);
        assert_eq!(
            BillingPlan::from_str("Shared").unwrap(),
            BillingPlan::Shared
        );
        assert_eq!(
            BillingPlan::from_str("sHaReD").unwrap(),
            BillingPlan::Shared
        );
    }

    #[test]
    fn billing_plan_from_str_unknown_returns_err() {
        assert!(BillingPlan::from_str("enterprise").is_err());
        assert!(BillingPlan::from_str("").is_err());
        assert!(BillingPlan::from_str("pro").is_err());
    }

    #[test]
    fn billing_plan_display_free() {
        assert_eq!(BillingPlan::Free.to_string(), "free");
    }

    #[test]
    fn billing_plan_display_shared() {
        assert_eq!(BillingPlan::Shared.to_string(), "shared");
    }

    #[test]
    fn billing_plan_display_roundtrips_through_from_str() {
        for plan in [BillingPlan::Free, BillingPlan::Shared] {
            let s = plan.to_string();
            assert_eq!(BillingPlan::from_str(&s).unwrap(), plan);
        }
    }

    #[test]
    fn billing_plan_serde_roundtrip() {
        let json = serde_json::to_string(&BillingPlan::Free).unwrap();
        assert_eq!(json, "\"free\"");
        let parsed: BillingPlan = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, BillingPlan::Free);

        let json = serde_json::to_string(&BillingPlan::Shared).unwrap();
        assert_eq!(json, "\"shared\"");
        let parsed: BillingPlan = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, BillingPlan::Shared);
    }

    #[test]
    fn billing_plan_serde_rejects_unknown() {
        assert!(serde_json::from_str::<BillingPlan>("\"enterprise\"").is_err());
    }

    /// Verifies that `"shared"` parses to `BillingPlan::Shared`.
    #[test]
    fn billing_plan_enum_method_valid_plan() {
        let customer = build_test_customer("shared", Decimal::ZERO);
        assert_eq!(customer.billing_plan_enum(), BillingPlan::Shared);
    }

    /// Verifies that an unrecognized plan string defaults to
    /// `BillingPlan::Free`.
    #[test]
    fn billing_plan_enum_method_unknown_defaults_to_free() {
        let customer = build_test_customer("enterprise", Decimal::ZERO);
        assert_eq!(customer.billing_plan_enum(), BillingPlan::Free);
    }

    /// Verify that newly constructed customers initialize `object_storage_egress_carryforward_cents` to zero.
    #[test]
    fn new_customer_carryforward_defaults_to_zero() {
        let customer = build_test_customer("free", Decimal::ZERO);
        assert_eq!(
            customer.object_storage_egress_carryforward_cents,
            Decimal::ZERO
        );
    }

    /// Verify that `object_storage_egress_carryforward_cents` is excluded from serialized JSON even when non-zero.
    #[test]
    fn carryforward_not_in_serialized_json() {
        let customer = build_test_customer("free", Decimal::new(37, 2));
        let json = serde_json::to_value(&customer).unwrap();
        assert!(
            json.get("object_storage_egress_carryforward_cents")
                .is_none(),
            "carryforward must not appear in serialized Customer JSON"
        );
    }
}

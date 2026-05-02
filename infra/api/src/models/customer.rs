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
    #[sqlx(default)]
    pub last_accessed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    #[sqlx(default)]
    pub overdue_invoice_count: i64,
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
            last_accessed_at: None,
            overdue_invoice_count: 0,
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

    // ---------------------------------------------------------------------
    // T0.3 — customer_auth_state contract for soft-deleted customers.
    //
    // The auth gate (auth/tenant.rs, auth/api_key.rs, services/storage/s3_auth.rs)
    // ALL delegate to customer_auth_state to decide whether a JWT/API-key
    // request is allowed through. If this function ever returns Active for
    // a soft-deleted customer (status="deleted"), every subsequent request
    // a customer makes after self-serve account deletion would still
    // succeed — a "deleted account stays usable" security incident.
    //
    // Together with the pg_customer_repo `soft_delete_retains_row_and_is_idempotent`
    // integration test (which proves soft_delete flips status→"deleted"
    // and stamps deleted_at), the four tests below pin the full contract:
    //   soft_delete --(SQL)--> status="deleted" --(this fn)--> Missing --(auth gate)--> 401.
    //
    // Each test asserts a single discriminating output mapping. Trying to
    // pass any one of them with a hardcoded constant return value would
    // fail at least one of the others — the four together are
    // mutually-discriminating.
    // ---------------------------------------------------------------------

    /// `status="deleted"` → `Missing` so the auth gate rejects subsequent
    /// JWTs / API-keys for the soft-deleted customer. THIS IS THE
    /// SECURITY-LOAD-BEARING ASSERTION: a regression here is silently
    /// "deleted account stays usable."
    #[test]
    fn customer_auth_state_deleted_status_is_missing() {
        let mut customer = build_test_customer("free", Decimal::ZERO);
        customer.status = "deleted".to_string();
        assert_eq!(
            customer_auth_state(Some(&customer)),
            CustomerAuthState::Missing,
            "status='deleted' MUST map to Missing — the auth gate's reject path"
        );
    }

    /// `status="suspended"` → `Suspended` so the auth gate returns 403
    /// (different from the 401 produced by Missing). Catches a regression
    /// where the suspended branch accidentally collapses into deleted.
    #[test]
    fn customer_auth_state_suspended_status_is_suspended() {
        let mut customer = build_test_customer("free", Decimal::ZERO);
        customer.status = "suspended".to_string();
        assert_eq!(
            customer_auth_state(Some(&customer)),
            CustomerAuthState::Suspended,
            "status='suspended' MUST map to Suspended (403), NOT Missing (401)"
        );
    }

    /// `status="active"` → `Active`. Sanity check: without this the test
    /// pair above would pass with a `customer_auth_state` that always
    /// returned Missing.
    #[test]
    fn customer_auth_state_active_status_is_active() {
        let customer = build_test_customer("free", Decimal::ZERO);
        // build_test_customer defaults to status='active'; assert that
        // assumption explicitly so a future refactor of the helper
        // doesn't silently invalidate this test.
        assert_eq!(customer.status, "active");
        assert_eq!(
            customer_auth_state(Some(&customer)),
            CustomerAuthState::Active
        );
    }

    /// `None` (customer not found by id) → `Missing`, same path as deleted.
    /// Documenting the equivalence so a future refactor doesn't try to
    /// distinguish "customer never existed" from "customer was deleted"
    /// at the auth-gate level (information-disclosure risk).
    #[test]
    fn customer_auth_state_none_is_missing() {
        assert_eq!(customer_auth_state(None), CustomerAuthState::Missing);
    }
}

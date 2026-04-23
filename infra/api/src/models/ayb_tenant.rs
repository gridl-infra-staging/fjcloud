//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/models/ayb_tenant.rs.
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use uuid::Uuid;

// Re-export from the single source of truth for plan tiers.
pub use billing::plan::PlanTier;

/// Local lifecycle status for an AYB tenant instance managed by fjcloud_dev.
///
/// These statuses track the local control-plane state, not live AYB health.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AybTenantStatus {
    Provisioning,
    Ready,
    Deleting,
    Error,
}

impl AybTenantStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            AybTenantStatus::Provisioning => "provisioning",
            AybTenantStatus::Ready => "ready",
            AybTenantStatus::Deleting => "deleting",
            AybTenantStatus::Error => "error",
        }
    }
}

impl std::fmt::Display for AybTenantStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for AybTenantStatus {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "provisioning" => Ok(AybTenantStatus::Provisioning),
            "ready" => Ok(AybTenantStatus::Ready),
            "deleting" => Ok(AybTenantStatus::Deleting),
            "error" => Ok(AybTenantStatus::Error),
            _ => Err(format!("unknown AYB tenant status: {s}")),
        }
    }
}

/// A row from the `ayb_tenants` table — local control-plane metadata for an AYB instance.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct AybTenant {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub ayb_tenant_id: String,
    pub ayb_slug: String,
    pub ayb_cluster_id: String,
    pub ayb_url: String,
    pub status: String,
    pub plan: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub deleted_at: Option<DateTime<Utc>>,
}

impl AybTenant {
    /// Returns true if the row has not been soft-deleted.
    pub fn is_active(&self) -> bool {
        self.deleted_at.is_none()
    }

    /// Parses the `status` column into a typed `AybTenantStatus`.
    pub fn parsed_status(&self) -> Result<AybTenantStatus, String> {
        self.status.parse()
    }

    /// Parses the `plan` column into a typed `PlanTier`.
    pub fn parsed_plan(&self) -> Result<PlanTier, String> {
        self.plan.parse()
    }
}

/// Input struct for creating a new AYB tenant row.
#[derive(Debug, Clone)]
pub struct NewAybTenant {
    pub customer_id: Uuid,
    pub ayb_tenant_id: String,
    pub ayb_slug: String,
    pub ayb_cluster_id: String,
    pub ayb_url: String,
    pub status: AybTenantStatus,
    pub plan: PlanTier,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_roundtrip() {
        let all = [
            AybTenantStatus::Provisioning,
            AybTenantStatus::Ready,
            AybTenantStatus::Deleting,
            AybTenantStatus::Error,
        ];
        for status in all {
            let s = status.as_str();
            let parsed: AybTenantStatus = s.parse().unwrap();
            assert_eq!(status, parsed, "roundtrip failed for {status:?}");
            assert_eq!(format!("{status}"), s, "Display mismatch for {status:?}");
        }
    }

    #[test]
    fn status_from_str_unknown_returns_error() {
        assert!("bogus".parse::<AybTenantStatus>().is_err());
    }

    #[test]
    fn status_serde_uses_lowercase() {
        let json = serde_json::to_string(&AybTenantStatus::Ready).unwrap();
        assert_eq!(json, "\"ready\"");

        let parsed: AybTenantStatus = serde_json::from_str("\"deleting\"").unwrap();
        assert_eq!(parsed, AybTenantStatus::Deleting);
    }

    #[test]
    fn plan_reuses_billing_plan_tier() {
        // Verify PlanTier is the same type from billing crate
        let tier = PlanTier::Starter;
        assert_eq!(tier.as_str(), "starter");
        assert!(tier.is_paid());
    }

    /// Verifies that a tenant with `deleted_at = None` is considered active.
    #[test]
    fn is_active_when_not_deleted() {
        let tenant = AybTenant {
            id: Uuid::new_v4(),
            customer_id: Uuid::new_v4(),
            ayb_tenant_id: "t-1".to_string(),
            ayb_slug: "slug-1".to_string(),
            ayb_cluster_id: "cluster-1".to_string(),
            ayb_url: "https://ayb.test".to_string(),
            status: "ready".to_string(),
            plan: "starter".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            deleted_at: None,
        };
        assert!(tenant.is_active());
    }

    /// Verifies that a tenant with `deleted_at = Some(…)` is not active.
    #[test]
    fn is_not_active_when_deleted() {
        let tenant = AybTenant {
            id: Uuid::new_v4(),
            customer_id: Uuid::new_v4(),
            ayb_tenant_id: "t-1".to_string(),
            ayb_slug: "slug-1".to_string(),
            ayb_cluster_id: "cluster-1".to_string(),
            ayb_url: "https://ayb.test".to_string(),
            status: "ready".to_string(),
            plan: "starter".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            deleted_at: Some(Utc::now()),
        };
        assert!(!tenant.is_active());
    }

    /// Verifies that `"provisioning"` parses to `AybTenantStatus::Provisioning`
    /// and `"pro"` parses to `PlanTier::Pro`.
    #[test]
    fn parsed_status_returns_typed_value() {
        let tenant = AybTenant {
            id: Uuid::new_v4(),
            customer_id: Uuid::new_v4(),
            ayb_tenant_id: "t-1".to_string(),
            ayb_slug: "slug-1".to_string(),
            ayb_cluster_id: "cluster-1".to_string(),
            ayb_url: "https://ayb.test".to_string(),
            status: "provisioning".to_string(),
            plan: "pro".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            deleted_at: None,
        };
        assert_eq!(
            tenant.parsed_status().unwrap(),
            AybTenantStatus::Provisioning
        );
        assert_eq!(tenant.parsed_plan().unwrap(), PlanTier::Pro);
    }

    /// Verifies that invalid status and plan strings return parse errors.
    #[test]
    fn parsed_status_invalid_returns_error() {
        let tenant = AybTenant {
            id: Uuid::new_v4(),
            customer_id: Uuid::new_v4(),
            ayb_tenant_id: "t-1".to_string(),
            ayb_slug: "slug-1".to_string(),
            ayb_cluster_id: "cluster-1".to_string(),
            ayb_url: "https://ayb.test".to_string(),
            status: "invalid".to_string(),
            plan: "invalid".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            deleted_at: None,
        };
        assert!(tenant.parsed_status().is_err());
        assert!(tenant.parsed_plan().is_err());
    }
}

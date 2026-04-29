use serde::{Deserialize, Serialize};
use std::str::FromStr;

/// Plan tier enumeration.
///
/// Tiers are ordered by capability: Free < Starter < Pro < Enterprise.
/// This ordering is used for upgrade/downgrade decisions.
#[derive(
    Debug,
    Clone,
    Copy,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    Serialize,
    Deserialize,
    utoipa::ToSchema,
)]
#[serde(rename_all = "lowercase")]
pub enum PlanTier {
    /// Free tier with hard limits.
    Free,
    /// Starter tier: 100K searches, 500K records, 50GB, 5 indexes.
    Starter,
    /// Pro tier: 500K searches, 2M records, 200GB, 20 indexes.
    Pro,
    /// Enterprise tier: custom limits.
    Enterprise,
}

impl PlanTier {
    /// Returns the string representation.
    pub fn as_str(&self) -> &'static str {
        match self {
            PlanTier::Free => "free",
            PlanTier::Starter => "starter",
            PlanTier::Pro => "pro",
            PlanTier::Enterprise => "enterprise",
        }
    }

    /// Returns true if this is a paid tier.
    pub fn is_paid(&self) -> bool {
        matches!(
            self,
            PlanTier::Starter | PlanTier::Pro | PlanTier::Enterprise
        )
    }

    /// Returns true if upgrading from `self` to `other`.
    pub fn is_upgrade_to(&self, other: PlanTier) -> bool {
        other > *self
    }

    /// Returns true if downgrading from `self` to `other`.
    pub fn is_downgrade_to(&self, other: PlanTier) -> bool {
        other < *self
    }
}

impl std::fmt::Display for PlanTier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for PlanTier {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "free" => Ok(PlanTier::Free),
            "starter" => Ok(PlanTier::Starter),
            "pro" => Ok(PlanTier::Pro),
            "enterprise" => Ok(PlanTier::Enterprise),
            _ => Err(format!("unknown plan tier: {}", s)),
        }
    }
}

/// Usage limits for a plan tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlanLimits {
    /// Maximum search requests per month. This is a quota gate (hard cap),
    /// NOT a billable pricing dimension under the flat hot-storage pricing
    /// model.
    pub max_searches_per_month: i64,
    /// Maximum records (documents) across all indexes.
    pub max_records: i64,
    /// Maximum storage in GB across all indexes.
    pub max_storage_gb: i64,
    /// Maximum number of indexes.
    pub max_indexes: i32,
}

impl PlanLimits {
    /// Returns the limits for the Free tier.
    pub fn free() -> Self {
        Self {
            max_searches_per_month: 50_000,
            max_records: 100_000,
            max_storage_gb: 10,
            max_indexes: 1,
        }
    }

    /// Returns the limits for the Starter tier.
    pub fn starter() -> Self {
        Self {
            max_searches_per_month: 100_000,
            max_records: 500_000,
            max_storage_gb: 50,
            max_indexes: 5,
        }
    }

    /// Returns the limits for the Pro tier.
    pub fn pro() -> Self {
        Self {
            max_searches_per_month: 500_000,
            max_records: 2_000_000,
            max_storage_gb: 200,
            max_indexes: 20,
        }
    }

    /// Returns the limits for the Enterprise tier.
    /// Uses high defaults that can be overridden per-customer.
    pub fn enterprise() -> Self {
        Self {
            max_searches_per_month: 10_000_000,
            max_records: 100_000_000,
            max_storage_gb: 10_000,
            max_indexes: 1000,
        }
    }

    /// Returns the limits for a given tier.
    pub fn for_tier(tier: PlanTier) -> Self {
        match tier {
            PlanTier::Free => Self::free(),
            PlanTier::Starter => Self::starter(),
            PlanTier::Pro => Self::pro(),
            PlanTier::Enterprise => Self::enterprise(),
        }
    }

    /// Returns true if the given usage is within limits.
    pub fn is_within_limits(
        &self,
        searches: i64,
        records: i64,
        storage_gb: i64,
        indexes: i32,
    ) -> bool {
        searches <= self.max_searches_per_month
            && records <= self.max_records
            && storage_gb <= self.max_storage_gb
            && indexes <= self.max_indexes
    }
}

/// Registry for plan configuration.
///
/// This trait abstracts plan lookups so tests can use hardcoded values
/// while production can load from environment variables or database.
pub trait PlanRegistry: Send + Sync {
    /// Returns the usage limits for a plan tier.
    fn get_limits(&self, tier: PlanTier) -> PlanLimits;

    /// Returns the Stripe price ID for a plan tier (if applicable).
    fn get_stripe_price_id(&self, tier: PlanTier) -> Option<String>;

    /// Returns the plan tier for a given Stripe price ID.
    fn get_tier_by_price_id(&self, price_id: &str) -> Option<PlanTier>;
}

/// Default plan registry that loads Stripe price IDs from environment variables.
///
/// Environment variables expected:
/// - STRIPE_PRICE_STARTER
/// - STRIPE_PRICE_PRO
/// - STRIPE_PRICE_ENTERPRISE
pub struct EnvPlanRegistry;

const LOCAL_STRIPE_FALLBACK_PRICE_IDS: [(&str, PlanTier); 3] = [
    ("price_starter_test", PlanTier::Starter),
    ("price_pro_test", PlanTier::Pro),
    ("price_enterprise_test", PlanTier::Enterprise),
];

impl EnvPlanRegistry {
    pub fn new() -> Self {
        Self
    }

    fn is_local_mode_enabled() -> bool {
        std::env::var("STRIPE_LOCAL_MODE").ok().as_deref() == Some("1")
    }

    fn stripe_price_env_var(tier: PlanTier) -> Option<&'static str> {
        match tier {
            PlanTier::Free => None,
            PlanTier::Starter => Some("STRIPE_PRICE_STARTER"),
            PlanTier::Pro => Some("STRIPE_PRICE_PRO"),
            PlanTier::Enterprise => Some("STRIPE_PRICE_ENTERPRISE"),
        }
    }

    fn local_fallback_price_id(tier: PlanTier) -> Option<&'static str> {
        LOCAL_STRIPE_FALLBACK_PRICE_IDS
            .iter()
            .find_map(|(price_id, mapped_tier)| (*mapped_tier == tier).then_some(*price_id))
    }

    fn local_fallback_tier(price_id: &str) -> Option<PlanTier> {
        LOCAL_STRIPE_FALLBACK_PRICE_IDS
            .iter()
            .find_map(|(mapped_price_id, mapped_tier)| {
                (*mapped_price_id == price_id).then_some(*mapped_tier)
            })
    }
}

impl Default for EnvPlanRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl PlanRegistry for EnvPlanRegistry {
    fn get_limits(&self, tier: PlanTier) -> PlanLimits {
        PlanLimits::for_tier(tier)
    }

    fn get_stripe_price_id(&self, tier: PlanTier) -> Option<String> {
        let env_var = Self::stripe_price_env_var(tier)?;

        std::env::var(env_var).ok().or_else(|| {
            Self::is_local_mode_enabled()
                .then(|| Self::local_fallback_price_id(tier).map(str::to_string))
                .flatten()
        })
    }

    fn get_tier_by_price_id(&self, price_id: &str) -> Option<PlanTier> {
        let env_tier = LOCAL_STRIPE_FALLBACK_PRICE_IDS
            .iter()
            .filter_map(|(_, tier)| {
                Self::stripe_price_env_var(*tier).map(|env_var| (env_var, *tier))
            })
            .find_map(|(env_var, tier)| {
                std::env::var(env_var)
                    .ok()
                    .filter(|configured| configured == price_id)
                    .map(|_| tier)
            });

        env_tier.or_else(|| {
            Self::is_local_mode_enabled()
                .then(|| Self::local_fallback_tier(price_id))
                .flatten()
        })
    }
}

/// Hardcoded plan registry for tests.
pub struct StaticPlanRegistry {
    starter_price: String,
    pro_price: String,
    enterprise_price: String,
}

impl StaticPlanRegistry {
    pub fn new(
        starter_price: impl Into<String>,
        pro_price: impl Into<String>,
        enterprise_price: impl Into<String>,
    ) -> Self {
        Self {
            starter_price: starter_price.into(),
            pro_price: pro_price.into(),
            enterprise_price: enterprise_price.into(),
        }
    }
}

impl PlanRegistry for StaticPlanRegistry {
    fn get_limits(&self, tier: PlanTier) -> PlanLimits {
        PlanLimits::for_tier(tier)
    }

    fn get_stripe_price_id(&self, tier: PlanTier) -> Option<String> {
        match tier {
            PlanTier::Free => None,
            PlanTier::Starter => Some(self.starter_price.clone()),
            PlanTier::Pro => Some(self.pro_price.clone()),
            PlanTier::Enterprise => Some(self.enterprise_price.clone()),
        }
    }

    fn get_tier_by_price_id(&self, price_id: &str) -> Option<PlanTier> {
        if price_id == self.starter_price {
            Some(PlanTier::Starter)
        } else if price_id == self.pro_price {
            Some(PlanTier::Pro)
        } else if price_id == self.enterprise_price {
            Some(PlanTier::Enterprise)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn plan_env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvGuard<'a> {
        vars: Vec<(&'static str, Option<String>)>,
        _lock: std::sync::MutexGuard<'a, ()>,
    }

    impl<'a> EnvGuard<'a> {
        fn new(lock: std::sync::MutexGuard<'a, ()>, keys: &[&'static str]) -> Self {
            let vars = keys
                .iter()
                .map(|k| (*k, std::env::var(k).ok()))
                .collect::<Vec<_>>();
            Self { vars, _lock: lock }
        }
    }

    impl Drop for EnvGuard<'_> {
        fn drop(&mut self) {
            for (k, v) in &self.vars {
                if let Some(value) = v {
                    std::env::set_var(k, value);
                } else {
                    std::env::remove_var(k);
                }
            }
        }
    }

    #[test]
    fn test_plan_tier_ordering() {
        assert!(PlanTier::Free < PlanTier::Starter);
        assert!(PlanTier::Starter < PlanTier::Pro);
        assert!(PlanTier::Pro < PlanTier::Enterprise);
    }

    #[test]
    fn test_plan_tier_is_upgrade() {
        assert!(PlanTier::Starter.is_upgrade_to(PlanTier::Pro));
        assert!(!PlanTier::Pro.is_upgrade_to(PlanTier::Starter));
        assert!(!PlanTier::Pro.is_upgrade_to(PlanTier::Pro));
    }

    #[test]
    fn test_plan_tier_is_downgrade() {
        assert!(PlanTier::Pro.is_downgrade_to(PlanTier::Starter));
        assert!(!PlanTier::Starter.is_downgrade_to(PlanTier::Pro));
        assert!(!PlanTier::Starter.is_downgrade_to(PlanTier::Starter));
    }

    #[test]
    fn test_plan_tier_from_str() {
        assert_eq!(PlanTier::from_str("free").unwrap(), PlanTier::Free);
        assert_eq!(PlanTier::from_str("starter").unwrap(), PlanTier::Starter);
        assert_eq!(PlanTier::from_str("pro").unwrap(), PlanTier::Pro);
        assert_eq!(
            PlanTier::from_str("enterprise").unwrap(),
            PlanTier::Enterprise
        );
        assert!(PlanTier::from_str("unknown").is_err());
    }

    #[test]
    fn test_plan_limits_free() {
        let limits = PlanLimits::free();
        assert_eq!(limits.max_searches_per_month, 50_000);
        assert_eq!(limits.max_records, 100_000);
        assert_eq!(limits.max_storage_gb, 10);
        assert_eq!(limits.max_indexes, 1);
    }

    #[test]
    fn test_plan_limits_starter() {
        let limits = PlanLimits::starter();
        assert_eq!(limits.max_searches_per_month, 100_000);
        assert_eq!(limits.max_records, 500_000);
        assert_eq!(limits.max_storage_gb, 50);
        assert_eq!(limits.max_indexes, 5);
    }

    #[test]
    fn test_plan_limits_pro() {
        let limits = PlanLimits::pro();
        assert_eq!(limits.max_searches_per_month, 500_000);
        assert_eq!(limits.max_records, 2_000_000);
        assert_eq!(limits.max_storage_gb, 200);
        assert_eq!(limits.max_indexes, 20);
    }

    #[test]
    fn test_plan_limits_enterprise() {
        let limits = PlanLimits::enterprise();
        assert_eq!(limits.max_searches_per_month, 10_000_000);
        assert_eq!(limits.max_records, 100_000_000);
        assert_eq!(limits.max_storage_gb, 10_000);
        assert_eq!(limits.max_indexes, 1000);
    }

    #[test]
    fn test_plan_tier_is_paid() {
        assert!(!PlanTier::Free.is_paid());
        assert!(PlanTier::Starter.is_paid());
        assert!(PlanTier::Pro.is_paid());
        assert!(PlanTier::Enterprise.is_paid());
    }

    #[test]
    fn test_plan_tier_roundtrip() {
        for tier in [
            PlanTier::Free,
            PlanTier::Starter,
            PlanTier::Pro,
            PlanTier::Enterprise,
        ] {
            let s = tier.as_str();
            let parsed = PlanTier::from_str(s).unwrap();
            assert_eq!(tier, parsed, "roundtrip failed for {:?}", tier);
        }
    }

    #[test]
    fn test_plan_tier_serde_uses_lowercase_strings() {
        let json = serde_json::to_string(&PlanTier::Starter).unwrap();
        assert_eq!(json, "\"starter\"");

        let parsed: PlanTier = serde_json::from_str("\"pro\"").unwrap();
        assert_eq!(parsed, PlanTier::Pro);
    }

    #[test]
    fn test_plan_limits_for_tier_dispatch() {
        assert_eq!(PlanLimits::for_tier(PlanTier::Free), PlanLimits::free());
        assert_eq!(
            PlanLimits::for_tier(PlanTier::Starter),
            PlanLimits::starter()
        );
        assert_eq!(PlanLimits::for_tier(PlanTier::Pro), PlanLimits::pro());
        assert_eq!(
            PlanLimits::for_tier(PlanTier::Enterprise),
            PlanLimits::enterprise()
        );
    }

    #[test]
    fn test_plan_limits_is_within_limits() {
        let limits = PlanLimits::starter();
        assert!(limits.is_within_limits(50_000, 100_000, 25, 3));
        assert!(!limits.is_within_limits(200_000, 100_000, 25, 3)); // over searches
        assert!(!limits.is_within_limits(50_000, 1_000_000, 25, 3)); // over records
        assert!(!limits.is_within_limits(50_000, 100_000, 100, 3)); // over storage
        assert!(!limits.is_within_limits(50_000, 100_000, 25, 10)); // over indexes
    }

    /// Verifies the full round-trip contract of `StaticPlanRegistry`: Stripe price IDs supplied
    /// at construction time are returned by `get_stripe_price_id` for each paid tier, `None` is
    /// returned for `Free`, and `get_tier_by_price_id` correctly maps price strings back to their
    /// `PlanTier` variants (returning `None` for an unrecognised string).
    #[test]
    fn test_static_plan_registry() {
        let registry = StaticPlanRegistry::new("price_starter", "price_pro", "price_enterprise");

        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Starter),
            Some("price_starter".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Pro),
            Some("price_pro".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Enterprise),
            Some("price_enterprise".to_string())
        );
        assert_eq!(registry.get_stripe_price_id(PlanTier::Free), None);

        assert_eq!(
            registry.get_tier_by_price_id("price_starter"),
            Some(PlanTier::Starter)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_pro"),
            Some(PlanTier::Pro)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_enterprise"),
            Some(PlanTier::Enterprise)
        );
        assert_eq!(registry.get_tier_by_price_id("unknown"), None);
    }

    #[test]
    fn test_env_plan_registry_uses_local_mode_fallback_prices() {
        let lock = plan_env_lock().lock().unwrap_or_else(|p| p.into_inner());
        let _guard = EnvGuard::new(
            lock,
            &[
                "STRIPE_LOCAL_MODE",
                "STRIPE_PRICE_STARTER",
                "STRIPE_PRICE_PRO",
                "STRIPE_PRICE_ENTERPRISE",
            ],
        );
        std::env::set_var("STRIPE_LOCAL_MODE", "1");
        std::env::remove_var("STRIPE_PRICE_STARTER");
        std::env::remove_var("STRIPE_PRICE_PRO");
        std::env::remove_var("STRIPE_PRICE_ENTERPRISE");

        let registry = EnvPlanRegistry::new();

        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Starter),
            Some("price_starter_test".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Pro),
            Some("price_pro_test".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Enterprise),
            Some("price_enterprise_test".to_string())
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_starter_test"),
            Some(PlanTier::Starter)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_pro_test"),
            Some(PlanTier::Pro)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_enterprise_test"),
            Some(PlanTier::Enterprise)
        );
    }

    #[test]
    fn test_env_plan_registry_explicit_prices_override_local_fallback() {
        let lock = plan_env_lock().lock().unwrap_or_else(|p| p.into_inner());
        let _guard = EnvGuard::new(
            lock,
            &[
                "STRIPE_LOCAL_MODE",
                "STRIPE_PRICE_STARTER",
                "STRIPE_PRICE_PRO",
                "STRIPE_PRICE_ENTERPRISE",
            ],
        );
        std::env::set_var("STRIPE_LOCAL_MODE", "1");
        std::env::set_var("STRIPE_PRICE_STARTER", "price_starter_override");
        std::env::set_var("STRIPE_PRICE_PRO", "price_pro_override");
        std::env::set_var("STRIPE_PRICE_ENTERPRISE", "price_enterprise_override");

        let registry = EnvPlanRegistry::new();

        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Starter),
            Some("price_starter_override".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Pro),
            Some("price_pro_override".to_string())
        );
        assert_eq!(
            registry.get_stripe_price_id(PlanTier::Enterprise),
            Some("price_enterprise_override".to_string())
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_starter_override"),
            Some(PlanTier::Starter)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_pro_override"),
            Some(PlanTier::Pro)
        );
        assert_eq!(
            registry.get_tier_by_price_id("price_enterprise_override"),
            Some(PlanTier::Enterprise)
        );
    }

    #[test]
    fn test_plan_tier_display_matches_as_str() {
        for tier in [
            PlanTier::Free,
            PlanTier::Starter,
            PlanTier::Pro,
            PlanTier::Enterprise,
        ] {
            assert_eq!(
                tier.to_string(),
                tier.as_str(),
                "Display and as_str must agree for {:?}",
                tier
            );
        }
    }

    #[test]
    fn test_plan_limits_at_exact_boundary() {
        let limits = PlanLimits::starter();
        // Exactly at limits should pass
        assert!(limits.is_within_limits(100_000, 500_000, 50, 5));
        // One over any dimension should fail
        assert!(!limits.is_within_limits(100_001, 500_000, 50, 5));
        assert!(!limits.is_within_limits(100_000, 500_001, 50, 5));
        assert!(!limits.is_within_limits(100_000, 500_000, 51, 5));
        assert!(!limits.is_within_limits(100_000, 500_000, 50, 6));
    }

    #[test]
    fn test_plan_limits_zero_usage_within_limits() {
        let limits = PlanLimits::free();
        assert!(limits.is_within_limits(0, 0, 0, 0));
    }

    /// Guards the upgrade-path invariant: every higher tier must have strictly greater limits
    /// across all four dimensions (searches, records, storage, indexes) than the tier below it.
    /// Regression test against accidental limit regressions during tier config changes — if any
    /// limit is equal to or lower than the preceding tier the test fails with a descriptive message.
    #[test]
    fn test_plan_tier_each_successive_tier_has_higher_limits() {
        let tiers = [
            PlanTier::Free,
            PlanTier::Starter,
            PlanTier::Pro,
            PlanTier::Enterprise,
        ];
        for window in tiers.windows(2) {
            let lower = PlanLimits::for_tier(window[0]);
            let higher = PlanLimits::for_tier(window[1]);
            assert!(
                higher.max_searches_per_month > lower.max_searches_per_month,
                "{:?} must have more searches than {:?}",
                window[1],
                window[0]
            );
            assert!(
                higher.max_records > lower.max_records,
                "{:?} must have more records than {:?}",
                window[1],
                window[0]
            );
            assert!(
                higher.max_indexes > lower.max_indexes,
                "{:?} must have more indexes than {:?}",
                window[1],
                window[0]
            );
        }
    }
}

//! Rate card definition: per-unit pricing configuration for billing calculations.
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// Pricing configuration used to compute customer invoices.
///
/// A `RateCard` captures the per-unit rates for every billable dimension, optional per-region
/// multipliers, and minimum spend floors. Multiple cards can coexist in the database; the active
/// card is selected by matching `effective_from` / `effective_until` against the billing period.
///
/// Pricing model summary:
/// - Hot storage: flat `storage_rate_per_mb_month` USD per MB-month (currently $0.05).
/// - Cold storage: `cold_storage_rate_per_gb_month` USD per GB-month (object-storage snapshots).
/// - Object (Garage) storage: `object_storage_rate_per_gb_month` USD per GB-month.
/// - Object egress: `object_storage_egress_rate_per_gb` USD per GB.
/// - Searches and writes are free (quota-gated, not billed).
/// - Regional surcharges are applied via `region_multipliers` (multiplicative, not additive).
/// - `minimum_spend_cents` and `shared_minimum_spend_cents` enforce a floor charge per cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateCard {
    pub id: Uuid,
    pub name: String,
    /// When this rate card becomes active.
    pub effective_from: DateTime<Utc>,
    /// None means this is the current active rate card.
    pub effective_until: Option<DateTime<Utc>>,
    /// USD per MB per billing period for hot storage (flat rate: $0.05/MB/month).
    pub storage_rate_per_mb_month: Decimal,
    /// Per-region cost multiplier. A missing entry defaults to 1.0.
    /// Example: {"eu-west-1": 1.3} means EU traffic costs 30% more.
    pub region_multipliers: HashMap<String, Decimal>,
    /// Floor spend per billing cycle in cents. Prevents penny-abuse.
    pub minimum_spend_cents: i64,
    /// Floor spend per billing cycle in cents for shared-plan customers.
    pub shared_minimum_spend_cents: i64,
    /// USD per GB per billing period for cold (object-storage) snapshots.
    pub cold_storage_rate_per_gb_month: Decimal,
    /// USD per GB per billing period for object (Garage) storage.
    pub object_storage_rate_per_gb_month: Decimal,
    /// USD per GB of egress for object (Garage) storage.
    pub object_storage_egress_rate_per_gb: Decimal,
}

impl RateCard {
    /// Returns the multiplier for `region`. Defaults to 1.0 if not configured.
    pub fn region_multiplier(&self, region: &str) -> Decimal {
        self.region_multipliers
            .get(region)
            .copied()
            .unwrap_or(dec!(1.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    /// Test helper: builds a `RateCard` with canonical rates and the given region multipliers.
    ///
    /// Rates used: $0.05/MB/month hot, $0.02/GB/month cold, $0.024/GB/month object, $0.01/GB
    /// egress. Minimum spend 1000 cents, shared minimum 500 cents. Pass an empty vec to get a
    /// card with no regional adjustments (all regions default to 1.0×).
    fn card_with_multipliers(multipliers: Vec<(&str, Decimal)>) -> RateCard {
        RateCard {
            id: Uuid::new_v4(),
            name: "test".to_string(),
            effective_from: chrono::Utc::now(),
            effective_until: None,
            storage_rate_per_mb_month: dec!(0.05),
            region_multipliers: multipliers
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
            minimum_spend_cents: 1000,
            shared_minimum_spend_cents: 500,
            cold_storage_rate_per_gb_month: dec!(0.02),
            object_storage_rate_per_gb_month: dec!(0.024),
            object_storage_egress_rate_per_gb: dec!(0.01),
        }
    }

    #[test]
    fn region_multiplier_returns_configured_value() {
        let card = card_with_multipliers(vec![("eu-west-1", dec!(1.3))]);
        assert_eq!(card.region_multiplier("eu-west-1"), dec!(1.3));
    }

    #[test]
    fn region_multiplier_defaults_to_one_for_unknown() {
        let card = card_with_multipliers(vec![("eu-west-1", dec!(1.3))]);
        assert_eq!(card.region_multiplier("us-east-1"), dec!(1.0));
    }

    #[test]
    fn region_multiplier_defaults_to_one_when_empty_map() {
        let card = card_with_multipliers(vec![]);
        assert_eq!(card.region_multiplier("us-east-1"), dec!(1.0));
    }

    #[test]
    fn region_multiplier_handles_fractional_discount() {
        let card = card_with_multipliers(vec![("us-west-2", dec!(0.8))]);
        assert_eq!(card.region_multiplier("us-west-2"), dec!(0.8));
    }

    #[test]
    fn region_multiplier_multiple_regions() {
        let card = card_with_multipliers(vec![
            ("eu-west-1", dec!(1.3)),
            ("ap-southeast-1", dec!(1.5)),
            ("us-west-2", dec!(0.9)),
        ]);
        assert_eq!(card.region_multiplier("eu-west-1"), dec!(1.3));
        assert_eq!(card.region_multiplier("ap-southeast-1"), dec!(1.5));
        assert_eq!(card.region_multiplier("us-west-2"), dec!(0.9));
        assert_eq!(card.region_multiplier("us-east-1"), dec!(1.0));
    }

    #[test]
    fn rate_card_serde_roundtrip() {
        let card = card_with_multipliers(vec![("eu-west-1", dec!(1.3))]);
        let json = serde_json::to_string(&card).unwrap();
        let parsed: RateCard = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.region_multiplier("eu-west-1"), dec!(1.3));
        assert_eq!(parsed.storage_rate_per_mb_month, dec!(0.05));
        assert_eq!(parsed.minimum_spend_cents, 1000);
        assert_eq!(parsed.shared_minimum_spend_cents, 500);
    }
}

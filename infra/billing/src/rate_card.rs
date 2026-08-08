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
/// multipliers, and minimum spend floors.
///
/// # Card selection is NOT period-aware
///
/// Multiple cards can coexist in the database, but `RateCardRepo::get_active()` takes no billing
/// period — it runs `WHERE effective_until IS NULL ORDER BY effective_from DESC LIMIT 1`, i.e. the
/// newest open card at *execution* time. `invoicing::compute_invoice_for_customer` uses that path,
/// and the `invoices` table has no `rate_card_id` column, so an invoice does not record which card
/// priced it.
///
/// Consequences, which matter the moment a second card exists:
/// - Recomputing a past period prices it at today's rates, not the rates in force then.
/// - `invoicing::compute_invoice_for_customer_with_rate_card_id` (the replay/audit seam) cannot be
///   used in production, because nothing persists the id it needs. It currently has test callers
///   only.
///
/// Until `invoices.rate_card_id` exists, historical reproducibility rests entirely on the operating
/// rule in `docs/design/pricing_contract.md`: never `UPDATE` a rate card that has already priced an
/// invoice — supersede it by closing `effective_until` and `INSERT`ing a new row. Every pricing
/// migration to date (016, 019, 031, 036, 042, 049) mutates the `launch-2026` row in place, which is
/// safe only while no invoices have been issued against it.
///
/// Pricing model summary:
/// - Hot storage: flat `storage_rate_per_mb_month` USD per MB-month (currently $0.05).
/// - Cold storage: `cold_storage_rate_per_gb_month` USD per GB-month (object-storage snapshots).
/// - Object (Garage) storage: `object_storage_rate_per_gb_month` USD per GB-month.
/// - Object egress: `object_storage_egress_rate_per_gb` USD per GB.
/// - Searches and writes are free (quota-gated, not billed).
/// - Regional surcharges are applied via `region_multipliers` (multiplicative, not additive).
/// - `minimum_spend_cents` is a retired dedicated/free-plan column retained for compatibility.
/// - `shared_minimum_spend_cents` is the only invoice floor, and applies to Shared plans.
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
    /// Retired dedicated/free-plan column retained for database and parity compatibility.
    /// Invoice calculation does not read this value.
    pub minimum_spend_cents: i64,
    /// The only shared-plan floor read by `invoice_total_with_minimum`.
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
    /// egress. Dedicated/free minimum 0 cents, shared minimum 1500 cents. Pass an empty vec to get a
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
            // Migration 049 retired the dedicated/free minimum at zero.
            minimum_spend_cents: 0,
            // Migration 072 set the shared launch floor to 1500 cents.
            shared_minimum_spend_cents: 1500,
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
        assert_eq!(parsed.minimum_spend_cents, 0);
        assert_eq!(parsed.shared_minimum_spend_cents, 1500);
    }
}

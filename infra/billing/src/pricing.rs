//! Invoice calculation engine: applies rate card pricing to usage summaries.
use crate::invoice::{InvoiceCalculation, LineItem};
use crate::rate_card::RateCard;
use crate::types::MonthlyUsageSummary;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

/// A billable resource dimension: quantity used, per-unit rate, and display metadata.
struct UsageDimension<'a> {
    quantity: Decimal,
    rate_per_unit: Decimal,
    description: &'a str,
    unit: &'a str,
}

/// Build a line item from a usage dimension, applying the region multiplier.
/// Returns None if the quantity is zero (nothing to bill).
fn line_item_from_dimension(
    dim: &UsageDimension<'_>,
    multiplier: Decimal,
    region: &str,
) -> Option<LineItem> {
    if dim.quantity <= Decimal::ZERO {
        return None;
    }
    let unit_price_cents = dim.rate_per_unit * multiplier * dec!(100);
    let amount_cents = round_to_cents(dim.quantity * unit_price_cents);
    Some(LineItem {
        description: format!("{} ({})", dim.description, region),
        quantity: dim.quantity,
        unit: dim.unit.to_string(),
        unit_price_cents,
        amount_cents,
        region: region.to_string(),
    })
}

/// Calculate an invoice for one billing period in one region.
/// Applies the rate card's per-unit prices and region multiplier. Searches and writes are free (unlimited).
pub fn calculate_invoice(usage: &MonthlyUsageSummary, rate: &RateCard) -> InvoiceCalculation {
    let multiplier = rate.region_multiplier(&usage.region);

    let dimensions = [
        UsageDimension {
            quantity: usage.storage_mb_months,
            rate_per_unit: rate.storage_rate_per_mb_month,
            description: "Hot storage",
            unit: "mb_months",
        },
        UsageDimension {
            quantity: usage.cold_storage_gb_months,
            rate_per_unit: rate.cold_storage_rate_per_gb_month,
            description: "Cold storage",
            unit: "cold_gb_months",
        },
        UsageDimension {
            quantity: usage.object_storage_gb_months,
            rate_per_unit: rate.object_storage_rate_per_gb_month,
            description: "Object storage",
            unit: "object_storage_gb_months",
        },
        UsageDimension {
            quantity: usage.object_storage_egress_gb,
            rate_per_unit: rate.object_storage_egress_rate_per_gb,
            description: "Object storage egress",
            unit: "object_storage_egress_gb",
        },
    ];

    let line_items: Vec<LineItem> = dimensions
        .iter()
        .filter_map(|dim| line_item_from_dimension(dim, multiplier, &usage.region))
        .collect();

    let subtotal_cents: i64 = line_items.iter().map(|li| li.amount_cents).sum();

    InvoiceCalculation {
        customer_id: usage.customer_id,
        period_start: usage.period_start,
        period_end: usage.period_end,
        line_items,
        subtotal_cents,
        minimum_applied: false,
        total_cents: subtotal_cents,
    }
}

/// Rounds a Decimal cent amount to the nearest whole cent as i64.
fn round_to_cents(cents: Decimal) -> i64 {
    cents
        .round_dp(0)
        .to_string()
        .parse::<i64>()
        .expect("billing amount overflow: invoice total exceeds i64::MAX cents")
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rate_card::RateCard;
    use crate::types::MonthlyUsageSummary;
    use chrono::NaiveDate;
    use rust_decimal_macros::dec;
    use std::collections::HashMap;
    use uuid::Uuid;

    /// Test rate card with per-MB storage pricing. Searches and writes are free.
    fn test_rate_card() -> RateCard {
        RateCard {
            id: Uuid::new_v4(),
            name: "test".to_string(),
            effective_from: chrono::Utc::now(),
            effective_until: None,
            storage_rate_per_mb_month: dec!(0.05),
            region_multipliers: HashMap::new(),
            minimum_spend_cents: 1000,
            shared_minimum_spend_cents: 500,
            cold_storage_rate_per_gb_month: dec!(0.02),
            object_storage_rate_per_gb_month: dec!(0.024),
            object_storage_egress_rate_per_gb: dec!(0.01),
        }
    }

    fn period() -> (NaiveDate, NaiveDate) {
        (
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        )
    }

    fn zero_usage(customer_id: Uuid) -> MonthlyUsageSummary {
        let (start, end) = period();
        MonthlyUsageSummary {
            customer_id,
            period_start: start,
            period_end: end,
            region: "us-east-1".to_string(),
            total_search_requests: 0,
            total_write_operations: 0,
            storage_mb_months: dec!(0),
            cold_storage_gb_months: dec!(0),
            object_storage_gb_months: dec!(0),
            object_storage_egress_gb: dec!(0),
        }
    }

    // -------------------------------------------------------------------------
    // Hot storage billing (flat $0.05/MB/month)
    // -------------------------------------------------------------------------

    /// Verifies hot storage is billed per MB-month at the rate card rate.
    #[test]
    fn hot_storage_billed_per_mb_month() {
        // 100 MB × $0.05/MB = $5.00 = 500 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(100),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.subtotal_cents, 500);
        assert!(!calc.minimum_applied);
        assert_eq!(calc.total_cents, 500);
        assert_eq!(calc.line_items.len(), 1);
        assert_eq!(calc.line_items[0].unit, "mb_months");
        assert_eq!(calc.line_items[0].description, "Hot storage (us-east-1)");
    }

    #[test]
    fn fractional_mb_months_billed_correctly() {
        // 1.5 MB × $0.05/MB = $0.075 = 8 cents (rounded)
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(1.5),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.subtotal_cents, 8);
        assert!(!calc.minimum_applied);
    }

    // -------------------------------------------------------------------------
    // Search/write requests produce no line items
    // -------------------------------------------------------------------------

    #[test]
    fn search_requests_not_billed() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            total_search_requests: 100_000,
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert!(calc.line_items.is_empty());
        assert_eq!(calc.subtotal_cents, 0);
    }

    #[test]
    fn write_operations_not_billed() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            total_write_operations: 10_000,
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert!(calc.line_items.is_empty());
        assert_eq!(calc.subtotal_cents, 0);
    }

    // -------------------------------------------------------------------------
    // Subtotal-only behavior (minimum enforcement owned by API layer)
    // -------------------------------------------------------------------------

    #[test]
    fn zero_usage_returns_zero_subtotal_without_minimum() {
        let rate = test_rate_card();
        let usage = zero_usage(Uuid::new_v4());

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.subtotal_cents, 0);
        assert_eq!(calc.total_cents, calc.subtotal_cents);
        assert!(!calc.minimum_applied);
        assert!(calc.line_items.is_empty());
    }

    #[test]
    fn high_usage_returns_uncapped_subtotal() {
        // 10000 MB × $0.05/MB = $500.00 = 50000 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(10000),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.total_cents, 50_000);
        assert_eq!(calc.total_cents, calc.subtotal_cents);
        assert!(!calc.minimum_applied);
    }

    // -------------------------------------------------------------------------
    // Region multiplier
    // -------------------------------------------------------------------------

    /// Verifies that the region multiplier is applied multiplicatively to hot storage.
    /// 100 MB × $0.05/MB × 1.3 (eu-west-1 surcharge) = $6.50 = 650 cents.
    /// Ensures the multiplier is sourced from the rate card's `region_multipliers` map using
    /// the region string in the usage summary.
    #[test]
    fn region_multiplier_scales_hot_storage() {
        // 100 MB × $0.05/MB × 1.3 = $6.50 = 650 cents
        let mut rate = test_rate_card();
        rate.region_multipliers
            .insert("eu-west-1".to_string(), dec!(1.3));

        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(100),
            ..zero_usage(Uuid::new_v4())
        };
        let mut usage = usage;
        usage.region = "eu-west-1".to_string();

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.total_cents, 650);
        assert!(!calc.minimum_applied);
    }

    #[test]
    fn unknown_region_defaults_to_1x_multiplier() {
        // 200 MB × $0.05/MB × 1.0 = $10.00 = 1000 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(200),
            ..zero_usage(Uuid::new_v4())
        };
        let mut usage = usage;
        usage.region = "ap-southeast-1".to_string();

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.total_cents, 1000);
    }

    // -------------------------------------------------------------------------
    // Combined dimensions (hot + cold + object)
    // -------------------------------------------------------------------------

    /// When a summary has both hot and cold storage, both line items must be produced and their
    /// `amount_cents` values must add up to the invoice `subtotal_cents`.
    /// 200 MB hot ($10.00 = 1000 ¢) + 10 GB cold ($0.20 = 20 ¢) = $10.20 = 1020 ¢.
    #[test]
    fn all_storage_dimensions_summed_correctly() {
        // 200 MB hot  = 200 × $0.05  = $10.00 → 1000 cents
        // 10 GiB cold = 10  × $0.02  = $0.20  → 20 cents
        // Total = $10.20 → 1020 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(200),
            cold_storage_gb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.subtotal_cents, 1020);
        assert_eq!(calc.total_cents, 1020);
        assert!(!calc.minimum_applied);
        assert_eq!(calc.line_items.len(), 2);
    }

    // -------------------------------------------------------------------------
    // Line item correctness
    // -------------------------------------------------------------------------

    /// Validates the individual fields of a hot-storage line item: `quantity` must match the
    /// input MB-months, `unit` must be `"mb_months"`, `unit_price_cents` must equal the rate
    /// converted to cents (0.05 × 100 = 5), and `amount_cents` must equal quantity × unit_price.
    /// 50 MB × 5 ¢/MB = 250 ¢.
    #[test]
    fn line_items_carry_correct_quantity_and_unit_price() {
        // 50 MB × $0.05/MB: quantity=50, unit_price_cents=5, amount=250
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(50),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let li = &calc.line_items[0];
        assert_eq!(li.quantity, dec!(50));
        assert_eq!(li.unit, "mb_months");
        assert_eq!(li.unit_price_cents, dec!(5));
        assert_eq!(li.amount_cents, 250);
    }

    #[test]
    fn line_item_region_matches_usage_region() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        assert_eq!(calc.line_items[0].region, "us-east-1");
    }

    // -------------------------------------------------------------------------
    // Cold storage billing
    // -------------------------------------------------------------------------

    /// Cold storage must be billed at `cold_storage_rate_per_gb_month`, not the hot MB rate.
    /// 10 GB-months × $0.02/GB = $0.20 = 20 ¢; `unit_price_cents` must be 2 (i.e. $0.02 × 100).
    /// The line item unit must be `"cold_gb_months"` to distinguish it from hot storage.
    #[test]
    fn cold_storage_line_item_uses_cold_rate() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            cold_storage_gb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let cold_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "cold_gb_months")
            .expect("cold storage line item missing");
        assert_eq!(cold_li.amount_cents, 20);
        assert_eq!(cold_li.unit_price_cents, dec!(2));
    }

    /// Hot and cold storage must appear as independent line items with distinct `unit` keys
    /// (`"mb_months"` and `"cold_gb_months"`) so operators can audit each pricing dimension
    /// separately. The combined subtotal must equal the sum of the two individual charges.
    /// 100 MB hot (500 ¢) + 10 GB cold (20 ¢) = 520 ¢.
    #[test]
    fn hot_and_cold_storage_separate_line_items() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(100),
            cold_storage_gb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let hot = calc.line_items.iter().find(|li| li.unit == "mb_months");
        let cold = calc
            .line_items
            .iter()
            .find(|li| li.unit == "cold_gb_months");
        assert!(hot.is_some(), "hot storage line item missing");
        assert!(cold.is_some(), "cold storage line item missing");
        assert_eq!(hot.unwrap().description, "Hot storage (us-east-1)");
        // hot: 100 × $0.05 = $5.00 = 500 cents; cold: 10 × $0.02 = $0.20 = 20 cents
        assert_eq!(calc.subtotal_cents, 520);
    }

    /// The cold storage rate is configurable per `RateCard`; changing `cold_storage_rate_per_gb_month`
    /// at runtime must be reflected in the resulting line item. This guards against the rate being
    /// hard-coded anywhere in the calculation path.
    /// 100 GB × $0.01/GB (custom rate) = $1.00 = 100 ¢.
    #[test]
    fn cold_storage_rate_overrideable() {
        let mut rate = test_rate_card();
        rate.cold_storage_rate_per_gb_month = dec!(0.01);
        let usage = MonthlyUsageSummary {
            cold_storage_gb_months: dec!(100),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let cold_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "cold_gb_months")
            .expect("cold storage line item missing");
        assert_eq!(cold_li.amount_cents, 100);
    }

    #[test]
    fn no_vm_hours_line_item() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            storage_mb_months: dec!(100),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let vm_li = calc.line_items.iter().find(|li| li.unit == "vm_hours");
        assert!(vm_li.is_none(), "VM hours line items should not exist");
    }

    // -------------------------------------------------------------------------
    // Object storage billing
    // -------------------------------------------------------------------------

    /// Garage object storage must be billed at `object_storage_rate_per_gb_month`, not the hot
    /// or cold rates. 10 GB-months × $0.024/GB = $0.24 = 24 ¢; `unit_price_cents` must equal
    /// 2.4, and the line item `unit` must be `"object_storage_gb_months"`.
    #[test]
    fn object_storage_line_item_uses_object_rate() {
        // 10 GB-months × $0.024/GB = $0.24 = 24 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            object_storage_gb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let obj_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_gb_months")
            .expect("object storage line item missing");
        assert_eq!(obj_li.amount_cents, 24);
        assert_eq!(obj_li.unit_price_cents, dec!(2.4));
        assert_eq!(obj_li.description, "Object storage (us-east-1)");
    }

    /// Egress must be billed at `object_storage_egress_rate_per_gb`, which is distinct from the
    /// capacity rate. 5 GB × $0.01/GB = $0.05 = 5 ¢; `unit_price_cents` must equal 1 and the
    /// line item `unit` must be `"object_storage_egress_gb"`.
    #[test]
    fn object_storage_egress_line_item_uses_egress_rate() {
        // 5 GB egress × $0.01/GB = $0.05 = 5 cents
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            object_storage_egress_gb: dec!(5),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let egress_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_egress_gb")
            .expect("object storage egress line item missing");
        assert_eq!(egress_li.amount_cents, 5);
        assert_eq!(egress_li.unit_price_cents, dec!(1));
        assert_eq!(egress_li.description, "Object storage egress (us-east-1)");
    }

    /// Cold storage, object storage capacity, and object storage egress are three independent
    /// billing dimensions and must each produce a separate line item. None may be collapsed into
    /// another. Verifies per-dimension amounts:
    /// cold: 10 × $0.02 = 20 ¢; object: 20 × $0.024 = 48 ¢; egress: 50 × $0.01 = 50 ¢.
    #[test]
    fn object_and_cold_storage_separate_line_items() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            cold_storage_gb_months: dec!(10),
            object_storage_gb_months: dec!(20),
            object_storage_egress_gb: dec!(50),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let cold = calc
            .line_items
            .iter()
            .find(|li| li.unit == "cold_gb_months");
        let obj = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_gb_months");
        let egress = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_egress_gb");
        assert!(cold.is_some(), "cold storage line item missing");
        assert!(obj.is_some(), "object storage line item missing");
        assert!(egress.is_some(), "object storage egress line item missing");

        // cold: 10 × $0.02 = $0.20 = 20 cents
        assert_eq!(cold.unwrap().amount_cents, 20);
        // object: 20 × $0.024 = $0.48 = 48 cents
        assert_eq!(obj.unwrap().amount_cents, 48);
        // egress: 50 × $0.01 = $0.50 = 50 cents
        assert_eq!(egress.unwrap().amount_cents, 50);
    }

    /// Both `object_storage_rate_per_gb_month` and `object_storage_egress_rate_per_gb` are
    /// read from the `RateCard` at invoice time; neither may be hard-coded. Overriding both to
    /// higher values must be reflected in the resulting `amount_cents`.
    /// 100 GB × $0.05 = 500 ¢; 100 GB egress × $0.02 = 200 ¢.
    #[test]
    fn object_storage_rates_overrideable() {
        let mut rate = test_rate_card();
        rate.object_storage_rate_per_gb_month = dec!(0.05);
        rate.object_storage_egress_rate_per_gb = dec!(0.02);
        let usage = MonthlyUsageSummary {
            object_storage_gb_months: dec!(100),
            object_storage_egress_gb: dec!(100),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let obj_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_gb_months")
            .expect("object storage line item missing");
        // 100 × $0.05 = $5.00 = 500 cents
        assert_eq!(obj_li.amount_cents, 500);

        let egress_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_egress_gb")
            .expect("object storage egress line item missing");
        // 100 × $0.02 = $2.00 = 200 cents
        assert_eq!(egress_li.amount_cents, 200);
    }

    /// Under the flat storage pricing model, search requests are free and must not produce a
    /// `"requests_1k"` (or any other search-unit) line item — even when `total_search_requests`
    /// is non-zero. The only line item emitted is the hot-storage charge at $0.05/MB/month
    /// (unit_price_cents = 5). Guards against regressions from an older per-request pricing model.
    #[test]
    fn no_search_request_line_item_in_new_pricing() {
        let rate = test_rate_card();
        let usage = MonthlyUsageSummary {
            total_search_requests: 100_000,
            storage_mb_months: dec!(10),
            ..zero_usage(Uuid::new_v4())
        };

        let calc = calculate_invoice(&usage, &rate);

        let search_li = calc.line_items.iter().find(|li| li.unit == "requests_1k");
        assert!(
            search_li.is_none(),
            "search request line item should not exist"
        );

        let hot_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "mb_months")
            .expect("hot storage mb_months line item missing");
        assert_eq!(hot_li.unit_price_cents, dec!(5));
    }

    /// The region multiplier must apply to all storage dimensions, not just hot storage.
    /// With a 1.5× surcharge on eu-west-1:
    /// - Object storage: 100 GB × $0.024 × 1.5 = $3.60 = 360 ¢.
    /// - Egress:         100 GB × $0.01  × 1.5 = $1.50 = 150 ¢.
    ///
    /// Ensures `line_item_from_dimension` threads the multiplier through for every dimension.
    #[test]
    fn region_multiplier_applies_to_object_storage() {
        let mut rate = test_rate_card();
        rate.region_multipliers
            .insert("eu-west-1".to_string(), dec!(1.5));

        let (start, end) = period();
        let usage = MonthlyUsageSummary {
            customer_id: Uuid::new_v4(),
            period_start: start,
            period_end: end,
            region: "eu-west-1".to_string(),
            total_search_requests: 0,
            total_write_operations: 0,
            storage_mb_months: dec!(0),
            cold_storage_gb_months: dec!(0),
            object_storage_gb_months: dec!(100),
            object_storage_egress_gb: dec!(100),
        };

        let calc = calculate_invoice(&usage, &rate);

        let obj_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_gb_months")
            .unwrap();
        // 100 × $0.024 × 1.5 = $3.60 = 360 cents
        assert_eq!(obj_li.amount_cents, 360);

        let egress_li = calc
            .line_items
            .iter()
            .find(|li| li.unit == "object_storage_egress_gb")
            .unwrap();
        // 100 × $0.01 × 1.5 = $1.50 = 150 cents
        assert_eq!(egress_li.amount_cents, 150);
    }
}

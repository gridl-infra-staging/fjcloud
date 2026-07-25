use chrono::NaiveDate;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::customer::BillingPlan;
use crate::repos::invoice_repo::NewLineItem;
use billing::pricing::PricingError;

use super::{ObjectStorageEgressMetadata, StorageInputs};

const OBJECT_STORAGE_EGRESS_UNIT: &str = "object_storage_egress_gb";

pub(super) fn synthetic_storage_only_record(
    customer_id: Uuid,
    period_start: NaiveDate,
) -> billing::types::DailyUsageRecord {
    billing::types::DailyUsageRecord {
        customer_id,
        date: period_start,
        region: "global".to_string(),
        search_requests: 0,
        write_operations: 0,
        storage_bytes_avg: 0,
        documents_count_avg: 0,
    }
}

pub(super) fn object_storage_egress_metadata_value(
    storage: &StorageInputs,
    next_cycle_carryforward_cents: Decimal,
) -> serde_json::Value {
    serde_json::to_value(ObjectStorageEgressMetadata {
        watermark_targets: storage.object_storage_egress_watermark_targets.clone(),
        next_cycle_carryforward_cents,
    })
    .expect("object storage egress metadata should serialize")
}

/// Compute the billable amount for an object storage egress line item, carrying forward sub-cent remainders to the next billing cycle.
///
/// # Arguments
/// * `line_item` - The egress line item from the billing crate
/// * `storage` - Storage inputs containing watermark targets for metadata
/// * `next_cycle_carryforward_cents` - Mutable reference to accumulated fractional cents; updated with remainder after this cycle
///
/// # Returns
/// Tuple of (amount_cents billed as i64, optional metadata containing watermark targets and next cycle carryforward). Only whole cents are included in the billing amount; fractional portions are retained in carryforward for the next cycle.
pub(super) fn bill_object_storage_egress_line_item(
    line_item: &billing::invoice::LineItem,
    storage: &StorageInputs,
    next_cycle_carryforward_cents: &mut Decimal,
) -> Result<(i64, Option<serde_json::Value>), PricingError> {
    let raw_egress_cents = line_item.quantity * line_item.unit_price_cents;
    let total_egress_cents = raw_egress_cents + *next_cycle_carryforward_cents;
    let whole_egress_cents = total_egress_cents.floor();
    *next_cycle_carryforward_cents = total_egress_cents - whole_egress_cents;
    let amount_cents = whole_egress_cents
        .to_i64()
        .ok_or(PricingError::AmountOverflow)?;
    let metadata = Some(object_storage_egress_metadata_value(
        storage,
        *next_cycle_carryforward_cents,
    ));
    Ok((amount_cents, metadata))
}

pub(super) fn carryforward_only_egress_line_item(
    storage: &StorageInputs,
    next_cycle_carryforward_cents: Decimal,
) -> NewLineItem {
    NewLineItem {
        description: "Object Storage Egress (carry-forward only)".to_string(),
        quantity: Decimal::ZERO,
        unit: OBJECT_STORAGE_EGRESS_UNIT.to_string(),
        unit_price_cents: Decimal::ZERO,
        amount_cents: 0,
        region: "global".to_string(),
        metadata: Some(object_storage_egress_metadata_value(
            storage,
            next_cycle_carryforward_cents,
        )),
    }
}

pub(super) fn new_invoice_line_item(
    line_item: billing::invoice::LineItem,
    storage: &StorageInputs,
    next_cycle_egress_carryforward_cents: &mut Decimal,
) -> Result<NewLineItem, PricingError> {
    let (amount_cents, metadata) = if line_item.unit == OBJECT_STORAGE_EGRESS_UNIT {
        bill_object_storage_egress_line_item(
            &line_item,
            storage,
            next_cycle_egress_carryforward_cents,
        )?
    } else {
        (line_item.amount_cents, None)
    };

    Ok(NewLineItem {
        description: line_item.description,
        quantity: line_item.quantity,
        unit: line_item.unit,
        unit_price_cents: line_item.unit_price_cents,
        amount_cents,
        region: line_item.region,
        metadata,
    })
}

pub(super) fn append_carryforward_snapshot_if_needed(
    line_items: &mut Vec<NewLineItem>,
    storage: &StorageInputs,
    next_cycle_egress_carryforward_cents: Decimal,
) {
    if next_cycle_egress_carryforward_cents <= Decimal::ZERO {
        return;
    }

    let egress_already_emitted = line_items
        .iter()
        .any(|line_item| line_item.unit == OBJECT_STORAGE_EGRESS_UNIT);
    if !egress_already_emitted {
        line_items.push(carryforward_only_egress_line_item(
            storage,
            next_cycle_egress_carryforward_cents,
        ));
    }
}

pub(super) fn invoice_total_with_minimum(
    subtotal_cents: i64,
    billing_plan: BillingPlan,
    rate_card: &billing::rate_card::RateCard,
) -> (i64, bool) {
    let minimum_cents = match billing_plan {
        BillingPlan::Free => 0,
        BillingPlan::Shared => rate_card.shared_minimum_spend_cents,
    };
    if subtotal_cents < minimum_cents {
        (minimum_cents, true)
    } else {
        (subtotal_cents, false)
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn line_item(unit_price_cents: Decimal) -> billing::invoice::LineItem {
        billing::invoice::LineItem {
            description: "Object storage egress".to_string(),
            quantity: dec!(1),
            unit: OBJECT_STORAGE_EGRESS_UNIT.to_string(),
            unit_price_cents,
            amount_cents: 0,
            region: "us-east-1".to_string(),
        }
    }

    #[test]
    fn egress_whole_cents_at_i64_max_returns_exact_value() {
        let storage = StorageInputs::default();
        let mut carryforward = Decimal::ZERO;

        let (amount_cents, metadata) = bill_object_storage_egress_line_item(
            &line_item(Decimal::from(i64::MAX)),
            &storage,
            &mut carryforward,
        )
        .unwrap();

        assert_eq!(amount_cents, i64::MAX);
        assert_eq!(carryforward, Decimal::ZERO);
        assert!(metadata.is_some());
    }

    #[test]
    fn egress_whole_cents_at_i64_max_with_fractional_carryforward_floors_correctly() {
        let storage = StorageInputs::default();
        let mut carryforward = dec!(0.5);

        let (amount_cents, metadata) = bill_object_storage_egress_line_item(
            &line_item(Decimal::from(i64::MAX)),
            &storage,
            &mut carryforward,
        )
        .unwrap();

        assert_eq!(amount_cents, i64::MAX);
        assert_eq!(carryforward, dec!(0.5));
        assert!(metadata.is_some());
    }

    #[test]
    fn egress_whole_cents_one_past_i64_max_returns_overflow_error_without_panic() {
        let storage = StorageInputs::default();
        let mut carryforward = Decimal::ZERO;
        let unit_price_cents = Decimal::from(i64::MAX) + Decimal::ONE;

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            bill_object_storage_egress_line_item(
                &line_item(unit_price_cents),
                &storage,
                &mut carryforward,
            )
        }));

        assert!(
            result.is_ok(),
            "object storage egress billing must not panic above i64::MAX"
        );
        assert_eq!(result.unwrap(), Err(PricingError::AmountOverflow));
    }
}

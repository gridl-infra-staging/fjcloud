use super::*;
use chrono::Utc;
use rust_decimal_macros::dec;

// -------------------------------------------------------------------------
// Billing-plan-aware minimum selection
// -------------------------------------------------------------------------

/// Verify that shared plan customers are charged the lower shared minimum rather than the free plan minimum.
#[test]
fn shared_plan_uses_shared_minimum() {
    let card = test_rate_card(); // minimum_spend_cents=500, shared_minimum_spend_cents=200
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let result = generate_invoice(
        &[],
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        BillingPlan::Shared,
    );

    assert_eq!(result.subtotal_cents, 0);
    assert!(result.minimum_applied);
    // Shared plan minimum is 200, not 500
    assert_eq!(result.total_cents, 200);
}

/// Verifies that a Shared plan with usage above the 200¢ shared minimum
/// is not clamped—the actual usage total applies.
#[test]
fn shared_plan_usage_above_shared_minimum_no_clamp() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 11;
    let rows: Vec<UsageDaily> = (1..=28)
        .map(|d| {
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, d).unwrap(),
                "us-east-1",
                0,
                0,
                hot_storage_bytes_per_day,
                0,
            )
        })
        .collect();

    let result = generate_invoice(
        &rows,
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        BillingPlan::Shared,
    );

    // Usage above shared minimum of 200 → no minimum applied
    assert!(!result.minimum_applied);
    assert_eq!(result.total_cents, result.subtotal_cents);
}

/// Verifies that a Shared plan with 300¢ usage (between 200¢ shared
/// and 500¢ free minimums) uses the actual total with no minimum.
#[test]
fn shared_plan_usage_between_minimums_uses_shared() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 15;
    let rows: Vec<UsageDaily> = (1..=28)
        .map(|d| {
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, d).unwrap(),
                "us-east-1",
                0,
                0,
                hot_storage_bytes_per_day,
                0,
            )
        })
        .collect();
    let result = generate_invoice(
        &rows,
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        BillingPlan::Shared,
    );

    assert_eq!(result.subtotal_cents, 300);
    assert!(!result.minimum_applied);
    assert_eq!(result.total_cents, 300);
}

/// Verifies that a Free plan with the same 300¢ usage is clamped up
/// to the 500¢ free-tier minimum.
#[test]
fn free_plan_usage_between_minimums_clamps_to_free() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 15;
    let rows: Vec<UsageDaily> = (1..=28)
        .map(|d| {
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, d).unwrap(),
                "us-east-1",
                0,
                0,
                hot_storage_bytes_per_day,
                0,
            )
        })
        .collect();
    let result = generate_invoice(
        &rows,
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        BillingPlan::Free,
    );

    assert_eq!(result.subtotal_cents, 300);
    assert!(result.minimum_applied);
    assert_eq!(result.total_cents, 500);
}

/// Verify that customers with unknown/unsupported billing plan strings default to the free plan's minimum when converted via billing_plan_enum().
#[test]
fn unknown_billing_plan_defaults_to_free_minimum_via_customer_enum() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();
    let customer = Customer {
        id: cid,
        name: "Unknown Plan Customer".to_string(),
        email: "unknown@example.com".to_string(),
        stripe_customer_id: None,
        status: "active".to_string(),
        deleted_at: None,
        billing_plan: "enterprise".to_string(),
        quota_warning_sent_at: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
        password_hash: None,
        email_verified_at: None,
        email_verify_token: None,
        email_verify_expires_at: None,
        password_reset_token: None,
        password_reset_expires_at: None,
        object_storage_egress_carryforward_cents: Decimal::ZERO,
    };

    let result = generate_invoice(
        &[],
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        customer.billing_plan_enum(),
    );

    assert_eq!(result.subtotal_cents, 0);
    assert!(result.minimum_applied);
    assert_eq!(result.total_cents, 500);
}

/// Verify that billing cycles with only carry-forward (no new egress) produce an egress line item with zero amount but metadata containing the retained fractional cents.
#[test]
fn carryforward_only_month_persists_remainder_in_metadata() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    // No new egress, no storage — only carry-forward from a previous cycle
    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: Decimal::ZERO,
        object_storage_egress_carryforward_cents: dec!(0.7),
        object_storage_egress_watermark_targets: Vec::new(),
    };
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    let egress = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("carry-forward-only month must produce egress line item with metadata");
    assert_eq!(
        egress.amount_cents, 0,
        "no new egress means zero billed cents"
    );
    assert_eq!(egress.quantity, Decimal::ZERO);
    let parsed: ObjectStorageEgressMetadata =
        serde_json::from_value(egress.metadata.clone().expect("metadata must be attached"))
            .expect("metadata should deserialize");
    assert_eq!(
        parsed.next_cycle_carryforward_cents,
        dec!(0.7),
        "carry-forward should be retained for the next cycle"
    );
}

#[test]
fn has_non_zero_storage_includes_carryforward() {
    let with_carryforward = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: Decimal::ZERO,
        object_storage_egress_carryforward_cents: dec!(0.3),
        object_storage_egress_watermark_targets: Vec::new(),
    };
    assert!(
        with_carryforward.has_non_zero_storage(),
        "carry-forward alone should count as non-zero storage state"
    );
}

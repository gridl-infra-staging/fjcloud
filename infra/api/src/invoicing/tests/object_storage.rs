use super::*;
use chrono::Utc;
use rust_decimal_macros::dec;

/// Test helper: creates a [`StorageBucket`] with the given size, egress,
/// and watermark values.
fn make_bucket(
    customer_id: Uuid,
    size_bytes: i64,
    egress_bytes: i64,
    watermark: i64,
) -> StorageBucket {
    StorageBucket {
        id: Uuid::new_v4(),
        customer_id,
        name: "test-bucket".to_string(),
        garage_bucket: "garage-test".to_string(),
        size_bytes,
        object_count: 0,
        egress_bytes,
        egress_watermark_bytes: watermark,
        status: "active".to_string(),
        created_at: Utc::now(),
        updated_at: Utc::now(),
    }
}

#[test]
fn compute_object_storage_gb_months_sums_active_buckets() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    let buckets = vec![
        make_bucket(cid, one_gb * 3, 0, 0),
        make_bucket(cid, one_gb * 7, 0, 0),
    ];

    let gb = compute_object_storage_gb_months(&buckets, cid);
    assert_eq!(gb, Decimal::from(10));
}

#[test]
fn compute_object_storage_gb_months_filters_by_customer() {
    let cid = Uuid::new_v4();
    let other = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    let buckets = vec![
        make_bucket(cid, one_gb * 5, 0, 0),
        make_bucket(other, one_gb * 100, 0, 0),
    ];

    let gb = compute_object_storage_gb_months(&buckets, cid);
    assert_eq!(gb, Decimal::from(5));
}

#[test]
fn compute_object_storage_gb_months_excludes_deleted() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    let mut deleted_bucket = make_bucket(cid, one_gb * 50, 0, 0);
    deleted_bucket.status = "deleted".to_string();
    let buckets = vec![make_bucket(cid, one_gb * 2, 0, 0), deleted_bucket];

    let gb = compute_object_storage_gb_months(&buckets, cid);
    assert_eq!(gb, Decimal::from(2));
}

#[test]
fn compute_object_storage_egress_gb_subtracts_watermark() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    // 10 GB total egress, 3 GB already billed → 7 GB unbilled
    let buckets = vec![make_bucket(cid, 0, one_gb * 10, one_gb * 3)];

    let gb = compute_object_storage_egress_gb(&buckets, cid);
    assert_eq!(gb, Decimal::from(7));
}

#[test]
fn compute_object_storage_egress_gb_clamps_negative_to_zero() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    // Watermark exceeds egress (shouldn't happen, but defensive)
    let buckets = vec![make_bucket(cid, 0, one_gb * 2, one_gb * 5)];

    let gb = compute_object_storage_egress_gb(&buckets, cid);
    assert_eq!(gb, Decimal::ZERO);
}

#[test]
fn compute_object_storage_egress_gb_sums_multiple_buckets() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    let buckets = vec![
        make_bucket(cid, 0, one_gb * 5, one_gb * 2), // 3 GB unbilled
        make_bucket(cid, 0, one_gb * 8, one_gb),     // 7 GB unbilled
    ];

    let gb = compute_object_storage_egress_gb(&buckets, cid);
    assert_eq!(gb, Decimal::from(10));
}

/// Verifies that only buckets with unbilled egress receive watermark
/// targets after invoicing.
#[test]
fn compute_object_storage_egress_watermark_targets_capture_billed_snapshot() {
    let cid = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;
    let mut settled = make_bucket(cid, 0, one_gb * 4, one_gb * 4);
    settled.name = "settled".to_string();
    let buckets = vec![
        make_bucket(cid, 0, one_gb * 5, one_gb * 2),
        make_bucket(cid, 0, one_gb * 8, 0),
        settled,
    ];

    let targets = compute_object_storage_egress_watermark_targets(&buckets, cid);

    assert_eq!(targets.len(), 2);
    assert_eq!(targets[0].egress_bytes, one_gb * 5);
    assert_eq!(targets[1].egress_bytes, one_gb * 8);
}

/// Verifies object storage billing: 10 GB × $0.024 = 24¢ storage,
/// 5 GB × $0.01 = 5¢ egress.
#[test]
fn invoice_with_object_storage_line_items() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let rows: Vec<UsageDaily> = (1..=28)
        .map(|d| {
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, d).unwrap(),
                "us-east-1",
                1000,
                0,
                0,
                0,
            )
        })
        .collect();

    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: dec!(10),
        object_storage_egress_gb: dec!(5),
        object_storage_egress_carryforward_cents: Decimal::ZERO,
        object_storage_egress_watermark_targets: Vec::new(),
    };
    let result = generate_invoice(&rows, &card, cid, start, end, &storage, BillingPlan::Free);

    let obj_li = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing");
    // 10 GB × $0.024 = 24 cents
    assert_eq!(obj_li.amount_cents, 24);

    let egress_li = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("egress line item missing");
    // 5 GB × $0.01 = 5 cents
    assert_eq!(egress_li.amount_cents, 5);
}

/// Verifies fractional egress carry-forward: 0.6¢ carry + 0.5¢ fresh =
/// 1.1¢ total, bills 1¢, retains 0.1¢ remainder.
#[test]
fn object_storage_egress_carryforward_crossing_cent_boundary_bills_only_whole_cents() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();
    let target_bucket = Uuid::new_v4();

    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: dec!(0.5), // 0.5 cents at $0.01/GB
        object_storage_egress_carryforward_cents: dec!(0.6),
        object_storage_egress_watermark_targets: vec![ObjectStorageEgressWatermarkTarget {
            bucket_id: target_bucket,
            egress_bytes: billing::types::BYTES_PER_GIB / 2,
        }],
    };
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    let egress = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(
        egress.amount_cents, 1,
        "carry-forward + fresh egress should bill only whole cents"
    );
    let parsed: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("egress metadata should be attached"),
    )
    .expect("egress metadata should deserialize");
    assert_eq!(
        parsed.next_cycle_carryforward_cents,
        dec!(0.1),
        "fractional cents should be retained for the next cycle"
    );
    assert_eq!(parsed.watermark_targets.len(), 1);
    assert_eq!(result.subtotal_cents, 1);
}

/// Verifies sub-cent accumulation: 0.2¢ carry + 0.5¢ fresh = 0.7¢,
/// bills 0¢, retains full 0.7¢ in metadata.
#[test]
fn object_storage_egress_sub_cent_cycle_retains_remainder_in_metadata() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: dec!(0.5), // 0.5 cents at $0.01/GB
        object_storage_egress_carryforward_cents: dec!(0.2),
        object_storage_egress_watermark_targets: vec![ObjectStorageEgressWatermarkTarget {
            bucket_id: Uuid::new_v4(),
            egress_bytes: billing::types::BYTES_PER_GIB / 2,
        }],
    };
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    let egress = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress.amount_cents, 0);
    let parsed: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("egress metadata should be attached even for zero-cent egress"),
    )
    .expect("egress metadata should deserialize");
    assert_eq!(parsed.next_cycle_carryforward_cents, dec!(0.7));
    assert_eq!(result.subtotal_cents, 0);
}

/// Verifies that 5 GB × $0.01 = 5¢ with zero carry-forward bills
/// exactly 5¢ with no remainder.
#[test]
fn object_storage_egress_whole_cent_behavior_unchanged_with_zero_carryforward() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: dec!(5),
        object_storage_egress_carryforward_cents: Decimal::ZERO,
        object_storage_egress_watermark_targets: vec![ObjectStorageEgressWatermarkTarget {
            bucket_id: Uuid::new_v4(),
            egress_bytes: billing::types::BYTES_PER_GIB * 5,
        }],
    };
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    let egress = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_egress_gb")
        .expect("object storage egress line item missing");
    assert_eq!(egress.amount_cents, 5);
    let parsed: ObjectStorageEgressMetadata = serde_json::from_value(
        egress
            .metadata
            .clone()
            .expect("egress metadata should be attached"),
    )
    .expect("egress metadata should deserialize");
    assert_eq!(parsed.next_cycle_carryforward_cents, Decimal::ZERO);
}

/// Verifies that object-storage-only usage (100 GB = 240¢ < 500¢
/// minimum) triggers the minimum spend floor.
#[test]
fn object_storage_billed_without_hot_usage_rows() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let storage = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: dec!(100),
        object_storage_egress_gb: Decimal::ZERO,
        object_storage_egress_carryforward_cents: Decimal::ZERO,
        object_storage_egress_watermark_targets: Vec::new(),
    };
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    // 100 GB × $0.024 = $2.40 = 240 cents
    assert_eq!(result.subtotal_cents, 240);
    // Below $5.00 minimum (Free plan)
    assert!(result.minimum_applied);
    assert_eq!(result.total_cents, 500);

    let obj_li = result
        .line_items
        .iter()
        .find(|li| li.unit == "object_storage_gb_months")
        .expect("object storage line item missing for storage-only customer");
    assert_eq!(obj_li.amount_cents, 240);
}

/// Verifies that each storage field (hot, cold, object, egress)
/// independently triggers `has_non_zero_storage`.
#[test]
fn storage_inputs_has_non_zero_storage_detects_all_fields() {
    let empty = zero_storage();
    assert!(!empty.has_non_zero_storage());

    let cold = StorageInputs::cold_only(dec!(1));
    assert!(cold.has_non_zero_storage());

    let obj = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: dec!(1),
        object_storage_egress_gb: Decimal::ZERO,
        object_storage_egress_carryforward_cents: Decimal::ZERO,
        object_storage_egress_watermark_targets: Vec::new(),
    };
    assert!(obj.has_non_zero_storage());

    let egress = StorageInputs {
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: dec!(1),
        object_storage_egress_carryforward_cents: Decimal::ZERO,
        object_storage_egress_watermark_targets: Vec::new(),
    };
    assert!(egress.has_non_zero_storage());
}

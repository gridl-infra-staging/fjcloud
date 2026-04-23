use super::*;
use crate::models::customer::{BillingPlan, Customer};
use chrono::Utc;
use rust_decimal_macros::dec;

mod billing_plan;
mod object_storage;

/// Test helper: creates a billing [`RateCard`] with standard test values
/// (storage_rate=0.20, minimum=500¢, shared_min=200¢, cold=0.02, obj=0.024,
/// egress=0.01).
pub(super) fn test_rate_card() -> billing::rate_card::RateCard {
    billing::rate_card::RateCard {
        id: Uuid::new_v4(),
        name: "default".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: HashMap::new(),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
    }
}

/// Test helper: creates a [`UsageDaily`] with the given parameters.
pub(super) fn make_usage(
    customer_id: Uuid,
    date: NaiveDate,
    region: &str,
    search: i64,
    write: i64,
    storage_bytes: i64,
    docs: i64,
) -> UsageDaily {
    UsageDaily {
        customer_id,
        date,
        region: region.to_string(),
        search_requests: search,
        write_operations: write,
        storage_bytes_avg: storage_bytes,
        documents_count_avg: docs,
        aggregated_at: Utc::now(),
    }
}

pub(super) fn zero_storage() -> StorageInputs {
    StorageInputs::default()
}

/// Verify that invoices with zero usage are charged the applicable minimum.
#[test]
fn empty_usage_applies_minimum() {
    let card = test_rate_card();
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
        BillingPlan::Free,
    );

    assert_eq!(result.customer_id, cid);
    assert_eq!(result.subtotal_cents, 0);
    assert_eq!(result.total_cents, 500);
    assert!(result.minimum_applied);
    assert!(result.line_items.is_empty());
}

/// Verifies that hot storage usage across 28 days produces line items
/// all attributed to us-east-1.
#[test]
fn single_region_with_usage() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 30;

    let rows: Vec<UsageDaily> = (1..=28)
        .map(|day| {
            let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
            make_usage(
                cid,
                date,
                "us-east-1",
                3571,
                357,
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

    assert!(!result.minimum_applied);
    assert!(result.subtotal_cents > 0);
    assert_eq!(result.total_cents, result.subtotal_cents);
    assert!(!result.line_items.is_empty());
    for li in &result.line_items {
        assert_eq!(li.region, "us-east-1");
    }
}

/// Verifies that both hot and cold storage line items are present,
/// with cold billed at 5 GB × $0.02 = 10¢.
#[test]
fn invoice_with_hot_and_cold_storage() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let one_gb = billing::types::BYTES_PER_GIB;
    let rows: Vec<UsageDaily> = (1..=28)
        .map(|d| {
            make_usage(
                cid,
                NaiveDate::from_ymd_opt(2026, 2, d).unwrap(),
                "us-east-1",
                10_000,
                0,
                one_gb,
                0,
            )
        })
        .collect();

    let storage = StorageInputs::cold_only(Decimal::from(5));
    let result = generate_invoice(&rows, &card, cid, start, end, &storage, BillingPlan::Free);

    let hot_li = result.line_items.iter().find(|li| li.unit == "mb_months");
    let cold_li = result
        .line_items
        .iter()
        .find(|li| li.unit == "cold_gb_months");
    let vm_li = result.line_items.iter().find(|li| li.unit == "vm_hours");

    assert!(hot_li.is_some(), "hot storage line item missing");
    assert!(cold_li.is_some(), "cold storage line item missing");
    assert!(vm_li.is_none(), "VM hours line items should not exist");

    assert_eq!(cold_li.unwrap().amount_cents, 10);
    assert!(hot_li.unwrap().amount_cents > 0);

    assert!(!result.minimum_applied);
    assert_eq!(result.total_cents, result.subtotal_cents);
}

/// Verifies that cold-only usage (200 GB = 400¢ < 500¢ minimum)
/// triggers the minimum spend floor.
#[test]
fn cold_storage_billed_without_hot_usage_rows() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();

    let storage = StorageInputs::cold_only(Decimal::from(200));
    let result = generate_invoice(&[], &card, cid, start, end, &storage, BillingPlan::Free);

    assert_eq!(result.subtotal_cents, 400);
    // 400 cents cold storage < 500 minimum → minimum applies
    assert_eq!(result.total_cents, 500);
    assert!(result.minimum_applied);

    let cold = result
        .line_items
        .iter()
        .find(|li| li.unit == "cold_gb_months")
        .expect("cold storage line item missing");
    assert_eq!(cold.amount_cents, 400);
}

/// Verifies that only completed snapshots for the target customer are
/// counted, excluding other customers and failed snapshots.
#[test]
fn compute_cold_storage_gb_months_filters_by_customer() {
    use crate::models::cold_snapshot::ColdSnapshot;
    use chrono::Utc;

    let cid = Uuid::new_v4();
    let other = Uuid::new_v4();
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let one_gb = billing::types::BYTES_PER_GIB;

    let snapshots = vec![
        ColdSnapshot {
            id: Uuid::new_v4(),
            customer_id: cid,
            tenant_id: "idx-1".to_string(),
            source_vm_id: vm_id,
            object_key: "cold/a/b/c.fj".to_string(),
            size_bytes: one_gb * 2,
            checksum: Some("abc".to_string()),
            status: "completed".to_string(),
            error: None,
            created_at: now,
            completed_at: Some(now),
            expires_at: None,
        },
        ColdSnapshot {
            id: Uuid::new_v4(),
            customer_id: cid,
            tenant_id: "idx-2".to_string(),
            source_vm_id: vm_id,
            object_key: "cold/a/b/d.fj".to_string(),
            size_bytes: one_gb * 3,
            checksum: Some("def".to_string()),
            status: "completed".to_string(),
            error: None,
            created_at: now,
            completed_at: Some(now),
            expires_at: None,
        },
        ColdSnapshot {
            id: Uuid::new_v4(),
            customer_id: other,
            tenant_id: "idx-3".to_string(),
            source_vm_id: vm_id,
            object_key: "cold/x/y/z.fj".to_string(),
            size_bytes: one_gb * 10,
            checksum: Some("ghi".to_string()),
            status: "completed".to_string(),
            error: None,
            created_at: now,
            completed_at: Some(now),
            expires_at: None,
        },
        ColdSnapshot {
            id: Uuid::new_v4(),
            customer_id: cid,
            tenant_id: "idx-4".to_string(),
            source_vm_id: vm_id,
            object_key: "cold/a/b/e.fj".to_string(),
            size_bytes: one_gb * 100,
            checksum: None,
            status: "failed".to_string(),
            error: Some("oops".to_string()),
            created_at: now,
            completed_at: None,
            expires_at: None,
        },
    ];

    let gb_months = super::compute_cold_storage_gb_months(&snapshots, cid);
    assert_eq!(gb_months, Decimal::from(5));
}

/// Verifies that when multi-region usage falls below the minimum, a
/// single minimum is applied across all regions combined.
#[test]
fn multi_region_single_minimum() {
    let card = test_rate_card();
    let cid = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 5;
    let mut rows = Vec::new();
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        rows.push(make_usage(
            cid,
            date,
            "us-east-1",
            1000,
            500,
            hot_storage_bytes_per_day,
            0,
        ));
        rows.push(make_usage(
            cid,
            date,
            "eu-west-1",
            1000,
            500,
            hot_storage_bytes_per_day,
            0,
        ));
    }

    let result = generate_invoice(
        &rows,
        &card,
        cid,
        start,
        end,
        &zero_storage(),
        BillingPlan::Free,
    );

    assert!(!result.line_items.is_empty());
    let regions: Vec<&str> = result
        .line_items
        .iter()
        .map(|li| li.region.as_str())
        .collect();
    assert!(
        regions.contains(&"us-east-1"),
        "missing us-east-1 line items"
    );
    assert!(
        regions.contains(&"eu-west-1"),
        "missing eu-west-1 line items"
    );

    assert!(result.subtotal_cents > 0);
    assert!(result.subtotal_cents < 500);

    assert!(result.minimum_applied);
    assert_eq!(result.total_cents, 500);
}

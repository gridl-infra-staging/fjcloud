//! Billing regression test harness for hot-storage, cold-storage, object-storage,
//! and minimum-spend scenarios.
//!
//! Pinned to a fixed Feb 2026 billing period and production rate-card values.
//! Hot-storage and repo-backed scenarios flow through `compute_invoice_for_customer()`;
//! cold-storage and carry-forward scenarios use `compute_invoice_for_customer_with_shared_inputs()`
//! to bypass repo timestamp paths and control carry-forward input directly.

mod common;

use api::invoicing::{
    compute_invoice_for_customer, compute_invoice_for_customer_with_shared_inputs, BillingRepos,
    GeneratedInvoice, ObjectStorageEgressMetadata, SharedBillingData,
};
use api::models::cold_snapshot::ColdSnapshot;
use api::models::customer::BillingPlan;
use api::models::storage::NewStorageBucket;
use api::models::{CustomerRateOverrideRow, RateCardRow};
use api::repos::invoice_repo::NewLineItem;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::RateCardRepo;
use billing::types::BYTES_PER_GIB;
use chrono::{NaiveDate, TimeZone, Utc};
use common::{
    mock_cold_snapshot_repo, mock_rate_card_repo, mock_storage_bucket_repo, mock_usage_repo,
    MockRateCardRepo, MockUsageRepo,
};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Fixed billing period: Feb 2026 (28 days)
// ---------------------------------------------------------------------------

fn feb_2026_bounds() -> (NaiveDate, NaiveDate) {
    let start = NaiveDate::from_ymd_opt(2026, 2, 1).expect("valid date");
    let end = NaiveDate::from_ymd_opt(2026, 2, 28).expect("valid date");
    (start, end)
}

// ---------------------------------------------------------------------------
// Production rate-card fixture (single source of truth for all Stage 1 tests)
// ---------------------------------------------------------------------------

/// Returns a `RateCardRow` with the exact production pricing values.
/// These flow through `RateCardRow::to_billing_rate_card()` into the billing crate.
fn production_rate_card_row() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "production-default".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.05),
        region_multipliers: json!({}),
        minimum_spend_cents: 1000,
        shared_minimum_spend_cents: 500,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: Utc::now(),
    }
}

// ---------------------------------------------------------------------------
// Shared setup: seeds the active rate card and returns mock repos
// ---------------------------------------------------------------------------

struct MockRepos {
    rate_card_repo: Arc<MockRateCardRepo>,
    usage_repo: Arc<MockUsageRepo>,
    cold_snapshot_repo: Arc<api::repos::InMemoryColdSnapshotRepo>,
    storage_bucket_repo: Arc<api::repos::InMemoryStorageBucketRepo>,
}

/// Creates all mock repos and seeds the production rate card as the active card.
fn setup_repos() -> MockRepos {
    let rate_card_repo = mock_rate_card_repo();
    let usage_repo = mock_usage_repo();
    let cold_snapshot_repo = mock_cold_snapshot_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();

    rate_card_repo.seed_active_card(production_rate_card_row());

    MockRepos {
        rate_card_repo,
        usage_repo,
        cold_snapshot_repo,
        storage_bucket_repo,
    }
}

impl MockRepos {
    fn billing_repos(&self) -> BillingRepos<'_> {
        BillingRepos {
            rate_card_repo: self.rate_card_repo.as_ref(),
            usage_repo: self.usage_repo.as_ref(),
            cold_snapshot_repo: self.cold_snapshot_repo.as_ref(),
            storage_bucket_repo: self.storage_bucket_repo.as_ref(),
        }
    }
}

// ---------------------------------------------------------------------------
// Daily usage seeder: constant MB across each day of Feb 2026
// ---------------------------------------------------------------------------

/// Seeds one row per day in Feb 2026, each with `target_mb * BYTES_PER_MB` as
/// `storage_bytes_avg`. After `billing::aggregation::summarize()` this yields
/// exactly `target_mb` MB-months.
fn seed_constant_daily_usage(
    usage_repo: &MockUsageRepo,
    customer_id: Uuid,
    target_mb: i64,
    region: &str,
) {
    let (start, end) = feb_2026_bounds();
    let bytes_per_day = target_mb * billing::types::BYTES_PER_MB;
    let mut day = start;
    while day <= end {
        usage_repo.seed(customer_id, day, region, 0, 0, bytes_per_day, 0);
        day = day.succ_opt().expect("valid next day in billing period");
    }
}

async fn generate_invoice(
    mocks: &MockRepos,
    customer_id: Uuid,
    plan: BillingPlan,
) -> GeneratedInvoice {
    let (start, end) = feb_2026_bounds();
    compute_invoice_for_customer(
        &mocks.billing_repos(),
        customer_id,
        start,
        end,
        plan,
        dec!(0),
    )
    .await
    .expect("invoice generation should succeed")
}

async fn generate_invoice_with_shared_inputs(
    mocks: &MockRepos,
    shared: &SharedBillingData<'_>,
    customer_id: Uuid,
    carryforward_cents: Decimal,
) -> GeneratedInvoice {
    let (start, end) = feb_2026_bounds();
    compute_invoice_for_customer_with_shared_inputs(
        &mocks.billing_repos(),
        shared,
        customer_id,
        start,
        end,
        BillingPlan::Free,
        carryforward_cents,
    )
    .await
    .expect("shared-input invoice generation should succeed")
}

// ---------------------------------------------------------------------------
// Invoice invariant assertions
// ---------------------------------------------------------------------------

/// Validates structural invariants that must hold for every generated invoice:
/// 1. subtotal_cents == sum of all line_items.amount_cents
/// 2. total_cents >= subtotal_cents (minimum can only raise the total)
/// 3. minimum_applied iff total_cents > subtotal_cents
fn assert_invoice_invariants(invoice: &GeneratedInvoice) {
    let line_item_sum: i64 = invoice.line_items.iter().map(|li| li.amount_cents).sum();
    assert_eq!(
        invoice.subtotal_cents, line_item_sum,
        "subtotal_cents ({}) != sum of line_items.amount_cents ({})",
        invoice.subtotal_cents, line_item_sum,
    );
    assert!(
        invoice.total_cents >= invoice.subtotal_cents,
        "total_cents ({}) < subtotal_cents ({}): minimum must not lower the total",
        invoice.total_cents,
        invoice.subtotal_cents,
    );
    assert_eq!(
        invoice.minimum_applied,
        invoice.total_cents > invoice.subtotal_cents,
        "minimum_applied ({}) inconsistent with total ({}) vs subtotal ({})",
        invoice.minimum_applied,
        invoice.total_cents,
        invoice.subtotal_cents,
    );
}

fn line_items_with_unit<'a>(invoice: &'a GeneratedInvoice, unit: &str) -> Vec<&'a NewLineItem> {
    invoice
        .line_items
        .iter()
        .filter(|line_item| line_item.unit == unit)
        .collect()
}

fn assert_single_line_item_by_unit<'a>(
    invoice: &'a GeneratedInvoice,
    unit: &str,
) -> &'a NewLineItem {
    let line_items = line_items_with_unit(invoice, unit);
    assert_eq!(
        line_items.len(),
        1,
        "expected exactly one {} line item, got {}",
        unit,
        line_items.len(),
    );
    line_items[0]
}

fn assert_no_line_items_by_unit(invoice: &GeneratedInvoice, unit: &str) {
    let line_items = line_items_with_unit(invoice, unit);
    assert_eq!(
        line_items.len(),
        0,
        "expected no {} line items, got {}",
        unit,
        line_items.len(),
    );
}

fn parse_object_storage_egress_metadata(line_item: &NewLineItem) -> ObjectStorageEgressMetadata {
    serde_json::from_value(
        line_item
            .metadata
            .clone()
            .expect("object-storage egress metadata should be attached"),
    )
    .expect("object-storage egress metadata should deserialize")
}

fn assert_single_watermark_target(
    metadata: &ObjectStorageEgressMetadata,
    expected_bucket_id: Uuid,
    expected_egress_bytes: i64,
) {
    assert_eq!(metadata.watermark_targets.len(), 1);
    assert_eq!(metadata.watermark_targets[0].bucket_id, expected_bucket_id);
    assert_eq!(
        metadata.watermark_targets[0].egress_bytes,
        expected_egress_bytes
    );
}

async fn create_bucket(
    mocks: &MockRepos,
    customer_id: Uuid,
    name: &str,
    garage_bucket: &str,
) -> Uuid {
    let bucket = mocks
        .storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id,
                name: name.to_string(),
            },
            garage_bucket,
        )
        .await
        .expect("bucket creation should succeed");
    bucket.id
}

async fn increment_bucket_size(mocks: &MockRepos, bucket_id: Uuid, size_bytes: i64) {
    mocks
        .storage_bucket_repo
        .increment_size(bucket_id, size_bytes, 1)
        .await
        .expect("increment_size should succeed");
}

async fn increment_bucket_egress(mocks: &MockRepos, bucket_id: Uuid, egress_bytes: i64) {
    mocks
        .storage_bucket_repo
        .increment_egress(bucket_id, egress_bytes)
        .await
        .expect("increment_egress should succeed");
}

// ---------------------------------------------------------------------------
// Free-plan hot-storage regression (table-driven)
// ---------------------------------------------------------------------------

struct HotStorageCase {
    target_mb: i64,
    expected_subtotal_cents: i64,
    expected_total_cents: i64,
}

const FREE_PLAN_CASES: &[HotStorageCase] = &[
    // 100 MB * $0.05 = 500¢, below 1000¢ minimum → total = 1000
    HotStorageCase {
        target_mb: 100,
        expected_subtotal_cents: 500,
        expected_total_cents: 1000,
    },
    // 250 MB * $0.05 = 1250¢, above minimum → total = 1250
    HotStorageCase {
        target_mb: 250,
        expected_subtotal_cents: 1250,
        expected_total_cents: 1250,
    },
    // 1000 MB * $0.05 = 5000¢
    HotStorageCase {
        target_mb: 1000,
        expected_subtotal_cents: 5000,
        expected_total_cents: 5000,
    },
    // 5000 MB * $0.05 = 25000¢
    HotStorageCase {
        target_mb: 5000,
        expected_subtotal_cents: 25000,
        expected_total_cents: 25000,
    },
    // 10000 MB * $0.05 = 50000¢
    HotStorageCase {
        target_mb: 10000,
        expected_subtotal_cents: 50000,
        expected_total_cents: 50000,
    },
];

#[tokio::test]
async fn free_plan_hot_storage_regression() {
    for case in FREE_PLAN_CASES {
        let mocks = setup_repos();
        let customer_id = Uuid::new_v4();

        seed_constant_daily_usage(&mocks.usage_repo, customer_id, case.target_mb, "us-east-1");

        let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Free).await;

        assert_invoice_invariants(&invoice);

        // Exactly one hot-storage line item.
        assert_single_line_item_by_unit(&invoice, "mb_months");

        assert_eq!(
            invoice.subtotal_cents, case.expected_subtotal_cents,
            "subtotal mismatch for {} MB: got {}, expected {}",
            case.target_mb, invoice.subtotal_cents, case.expected_subtotal_cents,
        );
        assert_eq!(
            invoice.total_cents, case.expected_total_cents,
            "total mismatch for {} MB: got {}, expected {}",
            case.target_mb, invoice.total_cents, case.expected_total_cents,
        );
    }
}

// ---------------------------------------------------------------------------
// Shared-plan minimum regression (50 MB hot storage)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn shared_plan_minimum_regression() {
    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();

    seed_constant_daily_usage(&mocks.usage_repo, customer_id, 50, "us-east-1");

    let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Shared).await;

    assert_invoice_invariants(&invoice);

    // Exactly one hot-storage line item.
    assert_single_line_item_by_unit(&invoice, "mb_months");

    // 50 MB * $0.05 = 250¢ subtotal, below shared minimum of 500¢.
    assert_eq!(invoice.subtotal_cents, 250);
    assert_eq!(invoice.total_cents, 500);
    assert!(invoice.minimum_applied);
}

// ---------------------------------------------------------------------------
// Region-multiplier hot-storage regression (eu-central-1 @ 0.70)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn region_multiplier_hot_storage_regression() {
    // Seed a rate card with a 0.70 multiplier for eu-central-1.
    let mut card = production_rate_card_row();
    card.region_multipliers = json!({"eu-central-1": "0.70"});

    let mocks = setup_repos();
    mocks.rate_card_repo.seed_active_card(card);

    let customer_id = Uuid::new_v4();
    seed_constant_daily_usage(&mocks.usage_repo, customer_id, 1000, "eu-central-1");

    let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice);

    // Exactly one hot-storage line item in the eu-central-1 region.
    let mb_month_item = assert_single_line_item_by_unit(&invoice, "mb_months");
    assert_eq!(mb_month_item.region, "eu-central-1");

    // 1000 MB × $0.05 × 0.70 × 100 = 3500¢, above 1000¢ minimum.
    assert_eq!(invoice.subtotal_cents, 3500);
    assert_eq!(invoice.total_cents, 3500);
    assert!(!invoice.minimum_applied);
}

// ---------------------------------------------------------------------------
// Multi-region storage-attachment regression
// ---------------------------------------------------------------------------

#[tokio::test]
async fn multi_region_storage_attachment_regression() {
    // Seed a rate card with eu-central-1 at 0.70.
    let mut card = production_rate_card_row();
    card.region_multipliers = json!({"eu-central-1": "0.70"});

    let mocks = setup_repos();
    mocks.rate_card_repo.seed_active_card(card);

    let customer_id = Uuid::new_v4();

    // Seed hot usage in both regions so the customer has eu-central-1 and us-east-1.
    seed_constant_daily_usage(&mocks.usage_repo, customer_id, 100, "eu-central-1");
    seed_constant_daily_usage(&mocks.usage_repo, customer_id, 100, "us-east-1");

    // Create a storage bucket and seed 10 GiB size + 10 GiB egress.
    // Aggregation attaches object storage to the lexicographically smallest region
    // (eu-central-1 < us-east-1), so the multiplier 0.70 applies.
    let bucket_id = create_bucket(&mocks, customer_id, "test-bucket", "test-garage-bucket").await;
    increment_bucket_size(&mocks, bucket_id, 10 * BYTES_PER_GIB).await;
    increment_bucket_egress(&mocks, bucket_id, 10 * BYTES_PER_GIB).await;

    let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice);

    // Object storage GB-months: 10 GiB × $0.024 × 0.70 × 100 = 16.8 → round = 17¢.
    let storage_item = assert_single_line_item_by_unit(&invoice, "object_storage_gb_months");
    assert_eq!(storage_item.region, "eu-central-1");
    assert_eq!(storage_item.amount_cents, 17);

    // Object storage egress: 10 GiB × $0.01 × 0.70 × 100 = 7¢.
    let egress_item = assert_single_line_item_by_unit(&invoice, "object_storage_egress_gb");
    assert_eq!(egress_item.region, "eu-central-1");
    assert_eq!(egress_item.amount_cents, 7);
}

// ---------------------------------------------------------------------------
// Override-isolation two-customer regression
// ---------------------------------------------------------------------------

#[tokio::test]
async fn override_isolation_regression() {
    let mocks = setup_repos();

    let customer_a = Uuid::new_v4();
    let customer_b = Uuid::new_v4();

    // Both customers get 1000 MB daily usage in us-east-1.
    seed_constant_daily_usage(&mocks.usage_repo, customer_a, 1000, "us-east-1");
    seed_constant_daily_usage(&mocks.usage_repo, customer_b, 1000, "us-east-1");

    // Retrieve the seeded card's id (override is keyed by (customer_id, rate_card_id)).
    let active_card = mocks
        .rate_card_repo
        .get_active()
        .await
        .expect("get_active should succeed")
        .expect("active card should exist");

    // Customer A gets a $0.07/MB override; customer B stays at default $0.05/MB.
    mocks.rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer_a,
        rate_card_id: active_card.id,
        overrides: json!({"storage_rate_per_mb_month": "0.07"}),
        created_at: Utc::now(),
    });

    // Customer A: 1000 MB × $0.07 × 100 = 7000¢.
    let invoice_a = generate_invoice(&mocks, customer_a, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice_a);
    assert_eq!(invoice_a.subtotal_cents, 7000);
    assert_eq!(invoice_a.total_cents, 7000);

    // Customer B: 1000 MB × $0.05 × 100 = 5000¢ (no override).
    let invoice_b = generate_invoice(&mocks, customer_b, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice_b);
    assert_eq!(invoice_b.subtotal_cents, 5000);
    assert_eq!(invoice_b.total_cents, 5000);

    // Confirm isolation: A's override must not leak to B.
    assert!(!invoice_b.minimum_applied);
}

// ---------------------------------------------------------------------------
// Cold-storage exact-rate regression (shared-input path)
// ---------------------------------------------------------------------------
#[tokio::test]
async fn cold_storage_exact_rate_regression() {
    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();
    // Hand-construct a completed ColdSnapshot inside Feb 2026 to bypass the
    // InMemoryColdSnapshotRepo::set_completed() path that stamps Utc::now().
    let cold_snapshot = ColdSnapshot {
        id: Uuid::new_v4(),
        customer_id,
        tenant_id: "test-tenant".to_string(),
        source_vm_id: Uuid::new_v4(),
        object_key: "snapshots/test.tar.zst".to_string(),
        size_bytes: 10 * billing::types::BYTES_PER_GIB,
        checksum: None,
        status: "completed".to_string(),
        error: None,
        created_at: Utc.with_ymd_and_hms(2026, 2, 1, 0, 0, 0).unwrap(),
        completed_at: Some(Utc.with_ymd_and_hms(2026, 2, 10, 12, 0, 0).unwrap()),
        expires_at: None,
    };

    let base_card = production_rate_card_row();
    // Re-seed the card so SharedBillingData references match the active card.
    mocks.rate_card_repo.seed_active_card(base_card.clone());

    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &[cold_snapshot],
        storage_buckets: &[],
    };

    let invoice = generate_invoice_with_shared_inputs(&mocks, &shared, customer_id, dec!(0)).await;

    assert_invoice_invariants(&invoice);

    // Exactly one cold_gb_months line item: 10 GiB × $0.02/GiB/month = 20¢.
    let cold_item = assert_single_line_item_by_unit(&invoice, "cold_gb_months");
    assert_eq!(cold_item.amount_cents, 20);
    assert_eq!(invoice.subtotal_cents, 20);
}

// ---------------------------------------------------------------------------
// Object-storage exact-rate regression (repo-backed, storage-only customer)
// ---------------------------------------------------------------------------
#[tokio::test]
async fn object_storage_exact_rate_regression() {
    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();
    // Create a storage bucket with 10 GiB, no hot-usage rows.
    let bucket_id = create_bucket(
        &mocks,
        customer_id,
        "regression-bucket",
        "garage-regression-bucket",
    )
    .await;
    increment_bucket_size(&mocks, bucket_id, 10 * BYTES_PER_GIB).await;

    let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice);

    // Exactly one object_storage_gb_months line item: 10 GiB × $0.024/GiB/month = 24¢.
    let storage_item = assert_single_line_item_by_unit(&invoice, "object_storage_gb_months");
    assert_eq!(storage_item.amount_cents, 24);

    // No duplicate hot-storage line items for a storage-only customer.
    assert_no_line_items_by_unit(&invoice, "mb_months");

    assert_eq!(invoice.subtotal_cents, 24);
}

// ---------------------------------------------------------------------------
// Object-storage egress exact-rate regression (repo-backed)
// ---------------------------------------------------------------------------
#[tokio::test]
async fn object_storage_egress_exact_rate_regression() {
    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();
    // One bucket with 5 GiB unbilled egress, zero carry-forward.
    let bucket_id =
        create_bucket(&mocks, customer_id, "egress-bucket", "garage-egress-bucket").await;
    increment_bucket_egress(&mocks, bucket_id, 5 * BYTES_PER_GIB).await;

    let invoice = generate_invoice(&mocks, customer_id, BillingPlan::Free).await;

    assert_invoice_invariants(&invoice);

    // Exactly one object_storage_egress_gb line item: 5 GiB × $0.01/GiB = 5¢.
    let egress_item = assert_single_line_item_by_unit(&invoice, "object_storage_egress_gb");
    assert_eq!(egress_item.amount_cents, 5);

    // Verify metadata: next_cycle_carryforward_cents == 0, watermark target present.
    let metadata = parse_object_storage_egress_metadata(egress_item);
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0));
    assert_single_watermark_target(&metadata, bucket_id, 5 * BYTES_PER_GIB);
}

// ---------------------------------------------------------------------------
// Sub-cent egress carry-forward regression (shared-input path)
// ---------------------------------------------------------------------------
#[tokio::test]
async fn object_storage_egress_sub_cent_carryforward_regression() {
    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();
    // One bucket with half a GiB of egress.
    let bucket_id = create_bucket(
        &mocks,
        customer_id,
        "carryforward-bucket",
        "garage-carryforward-bucket",
    )
    .await;
    increment_bucket_egress(&mocks, bucket_id, BYTES_PER_GIB / 2).await;

    // Use the shared-input path to control carry-forward input directly.
    let base_card = production_rate_card_row();
    mocks.rate_card_repo.seed_active_card(base_card.clone());

    let storage_buckets = mocks
        .storage_bucket_repo
        .list_all()
        .await
        .expect("list_all should succeed");

    let shared = SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &[],
        storage_buckets: &storage_buckets,
    };

    // 0.5 GiB × $0.01 = 0.5¢ raw egress + 0.2¢ carry-forward = 0.7¢ total,
    // so 0¢ is billed and 0.7¢ is carried.
    let invoice =
        generate_invoice_with_shared_inputs(&mocks, &shared, customer_id, dec!(0.2)).await;

    assert_invoice_invariants(&invoice);

    let egress_item = assert_single_line_item_by_unit(&invoice, "object_storage_egress_gb");
    assert_eq!(egress_item.amount_cents, 0);

    // Verify metadata preserves the fractional carry-forward and watermark target.
    let metadata = parse_object_storage_egress_metadata(egress_item);
    assert_eq!(metadata.next_cycle_carryforward_cents, dec!(0.7));
    assert_single_watermark_target(&metadata, bucket_id, BYTES_PER_GIB / 2);
}

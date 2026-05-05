//! Billing regression test harness for hot-storage, cold-storage, object-storage,
//! and minimum-spend scenarios.
//!
//! Pinned to a fixed Feb 2026 billing period and production rate-card values.
//! Hot-storage and repo-backed scenarios flow through `compute_invoice_for_customer()`;
//! cold-storage and carry-forward scenarios use `compute_invoice_for_customer_with_shared_inputs()`
//! to bypass repo timestamp paths and control carry-forward input directly.

mod common;

use api::invoicing::{
    compute_invoice_for_customer, compute_invoice_for_customer_with_rate_card_id,
    compute_invoice_for_customer_with_shared_inputs, BillingRepos, GeneratedInvoice,
    ObjectStorageEgressMetadata, SharedBillingData,
};
use api::models::cold_snapshot::ColdSnapshot;
use api::models::customer::{BillingPlan, Customer};
use api::models::storage::NewStorageBucket;
use api::models::{CustomerRateOverrideRow, RateCardRow};
use api::repos::invoice_repo::NewLineItem;
use api::repos::storage_bucket_repo::StorageBucketRepo;
use api::repos::{RateCardRepo, UsageRepo};
use billing::types::{MonthlyUsageSummary, BYTES_PER_GIB};
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use common::{
    mock_cold_snapshot_repo, mock_rate_card_repo, mock_storage_bucket_repo, mock_usage_repo,
    MockRateCardRepo, MockUsageRepo,
};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::Deserialize;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
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

const STAGE2_BUNDLE_DIR: &str =
    "docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean";
const STAGE2_EXPECTED_INVOICE_ID: &str = "e7806ad2-977d-4f4b-9ff9-95c7ddab49e3";
const STAGE2_EXPECTED_CUSTOMER_ID: &str = "0a65f0b7-14b3-4e08-acf6-2222a02c7858";
const STAGE2_EXPECTED_RATE_CARD_ID: &str = "aa60c93f-3ed4-44e8-8fe2-54e364eaad26";

#[derive(Debug, Deserialize)]
struct Stage2InvoiceDbRow {
    id: Uuid,
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    subtotal_cents: i64,
    total_cents: i64,
    minimum_applied: bool,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct Stage2InvoiceLineItem {
    description: String,
    quantity: Decimal,
    unit: String,
    unit_price_cents: Decimal,
    amount_cents: i64,
    region: String,
}

#[derive(Debug, Deserialize)]
struct Stage2CustomerBillingContext {
    id: Uuid,
    billing_plan: String,
    object_storage_egress_carryforward_cents: Decimal,
}

#[derive(Debug, Deserialize)]
struct Stage2RateCardSelection {
    selection_basis: String,
    invoice_selection_timestamp: DateTime<Utc>,
    effective_rate_card: Stage2RateCardFixture,
    override_exists: bool,
    active_rate_card_when_different: Option<Stage2RateCardFixture>,
}

#[derive(Debug, Deserialize)]
struct Stage2RateCardFixture {
    id: Uuid,
    name: String,
    effective_from: DateTime<Utc>,
    effective_until: Option<DateTime<Utc>>,
    storage_rate_per_mb_month: Decimal,
    region_multipliers: serde_json::Value,
    minimum_spend_cents: i64,
    shared_minimum_spend_cents: i64,
    cold_storage_rate_per_gb_month: Decimal,
    object_storage_rate_per_gb_month: Decimal,
    object_storage_egress_rate_per_gb: Decimal,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct Stage2UsageDailyReplayRow {
    customer_id: Uuid,
    date: NaiveDate,
    region: String,
    search_requests: i64,
    write_operations: i64,
    storage_bytes_avg: i64,
    documents_count_avg: i64,
    aggregated_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct Stage2UsageRecordProvenanceRow {
    customer_id: Uuid,
    region: String,
    recorded_at: DateTime<Utc>,
}

struct Stage2BundleFixtures {
    invoice_db_row: Stage2InvoiceDbRow,
    invoice_line_items: Vec<Stage2InvoiceLineItem>,
    customer_billing_context: Stage2CustomerBillingContext,
    rate_card_selection: Stage2RateCardSelection,
    customer_rate_override: Option<api::models::CustomerRateOverrideRow>,
    usage_daily_replay_rows: Vec<Stage2UsageDailyReplayRow>,
    usage_records_provenance: Vec<Stage2UsageRecordProvenanceRow>,
}

fn stage2_bundle_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../")
        .join(STAGE2_BUNDLE_DIR)
}

fn read_stage2_fixture<T: serde::de::DeserializeOwned>(
    path: &std::path::Path,
    file_name: &str,
) -> T {
    let full_path = path.join(file_name);
    let raw = std::fs::read_to_string(&full_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", full_path.display(), e));
    serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("failed to parse {}: {}", full_path.display(), e))
}

fn load_stage2_bundle_fixtures() -> Stage2BundleFixtures {
    let bundle_dir = stage2_bundle_dir();
    Stage2BundleFixtures {
        invoice_db_row: read_stage2_fixture(&bundle_dir, "invoice_db_row.json"),
        invoice_line_items: read_stage2_fixture(&bundle_dir, "invoice_line_items.json"),
        customer_billing_context: read_stage2_fixture(&bundle_dir, "customer_billing_context.json"),
        rate_card_selection: read_stage2_fixture(&bundle_dir, "rate_card_selection.json"),
        customer_rate_override: read_stage2_fixture(&bundle_dir, "customer_rate_override.json"),
        usage_daily_replay_rows: read_stage2_fixture(&bundle_dir, "usage_daily_replay_rows.json"),
        usage_records_provenance: read_stage2_fixture(&bundle_dir, "usage_records_provenance.json"),
    }
}

fn stage2_customer_from_context(
    context: &Stage2CustomerBillingContext,
    created_at: DateTime<Utc>,
) -> Customer {
    Customer {
        id: context.id,
        name: "stage2-replay-customer".to_string(),
        email: "stage2-replay-customer@synthetic.invalid".to_string(),
        stripe_customer_id: None,
        status: "active".to_string(),
        deleted_at: None,
        billing_plan: context.billing_plan.clone(),
        quota_warning_sent_at: None,
        created_at,
        updated_at: created_at,
        password_hash: None,
        email_verified_at: None,
        email_verify_token: None,
        email_verify_expires_at: None,
        resend_verification_sent_at: None,
        password_reset_token: None,
        password_reset_expires_at: None,
        last_accessed_at: None,
        overdue_invoice_count: 0,
        object_storage_egress_carryforward_cents: context.object_storage_egress_carryforward_cents,
    }
}

fn stage2_rate_card_row(fixture: &Stage2RateCardFixture) -> RateCardRow {
    RateCardRow {
        id: fixture.id,
        name: fixture.name.clone(),
        effective_from: fixture.effective_from,
        effective_until: fixture.effective_until,
        storage_rate_per_mb_month: fixture.storage_rate_per_mb_month,
        region_multipliers: fixture.region_multipliers.clone(),
        minimum_spend_cents: fixture.minimum_spend_cents,
        shared_minimum_spend_cents: fixture.shared_minimum_spend_cents,
        cold_storage_rate_per_gb_month: fixture.cold_storage_rate_per_gb_month,
        object_storage_rate_per_gb_month: fixture.object_storage_rate_per_gb_month,
        object_storage_egress_rate_per_gb: fixture.object_storage_egress_rate_per_gb,
        created_at: fixture.created_at,
    }
}

fn seed_stage2_usage_rows(mocks: &MockRepos, rows: &[Stage2UsageDailyReplayRow]) {
    for row in rows {
        mocks.usage_repo.seed_with_aggregated_at(
            row.customer_id,
            row.date,
            &row.region,
            row.search_requests,
            row.write_operations,
            row.storage_bytes_avg,
            row.documents_count_avg,
            row.aggregated_at,
        );
    }
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
    region: &'static str,
    billing_plan: BillingPlan,
    minimum_spend_cents_override: Option<i64>,
}

const FREE_PLAN_CASES: &[HotStorageCase] = &[
    // 68 MB * $0.05 = 340¢, pinned known-answer case for Feb 2026.
    // Override minimum to observe the pre-clamp amount in this harness.
    HotStorageCase {
        target_mb: 68,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: Some(0),
    },
    // 100 MB * $0.05 = 500¢, below 1000¢ minimum → total = 1000
    HotStorageCase {
        target_mb: 100,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: None,
    },
    // 250 MB * $0.05 = 1250¢, above minimum → total = 1250
    HotStorageCase {
        target_mb: 250,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: None,
    },
    // 1000 MB * $0.05 = 5000¢
    HotStorageCase {
        target_mb: 1000,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: None,
    },
    // 5000 MB * $0.05 = 25000¢
    HotStorageCase {
        target_mb: 5000,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: None,
    },
    // 10000 MB * $0.05 = 50000¢
    HotStorageCase {
        target_mb: 10000,
        region: "us-east-1",
        billing_plan: BillingPlan::Free,
        minimum_spend_cents_override: None,
    },
];

fn billing_rate_card_for_hot_storage_case(case: &HotStorageCase) -> billing::rate_card::RateCard {
    let base_card = production_rate_card_row();
    let effective_card_row = if let Some(minimum_spend_cents) = case.minimum_spend_cents_override {
        base_card
            .with_overrides(&json!({"minimum_spend_cents": minimum_spend_cents}))
            .expect("minimum spend override should parse")
    } else {
        base_card
    };

    effective_card_row
        .to_billing_rate_card()
        .expect("production rate card should convert to billing crate format")
}

fn expected_hot_storage_totals(case: &HotStorageCase) -> (i64, i64) {
    let (period_start, period_end) = feb_2026_bounds();
    let billing_rate_card = billing_rate_card_for_hot_storage_case(case);
    let usage_summary = MonthlyUsageSummary {
        customer_id: Uuid::new_v4(),
        period_start,
        period_end,
        region: case.region.to_string(),
        total_search_requests: 0,
        total_write_operations: 0,
        storage_mb_months: Decimal::from(case.target_mb),
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: Decimal::ZERO,
    };

    let pricing_calc = billing::pricing::calculate_invoice(&usage_summary, &billing_rate_card);
    let minimum_cents = match case.billing_plan {
        BillingPlan::Free => billing_rate_card.minimum_spend_cents,
        BillingPlan::Shared => billing_rate_card.shared_minimum_spend_cents,
    };
    let total_cents = pricing_calc.subtotal_cents.max(minimum_cents);
    (pricing_calc.subtotal_cents, total_cents)
}

fn assert_hot_storage_amounts(
    invoice: &GeneratedInvoice,
    case: &HotStorageCase,
    expected_subtotal_cents: i64,
    expected_total_cents: i64,
) {
    let mb_month_item = assert_single_line_item_by_unit(invoice, "mb_months");
    assert_eq!(mb_month_item.region, case.region);
    assert_eq!(
        mb_month_item.amount_cents, expected_subtotal_cents,
        "mb_months amount mismatch for {} MB: got {}, expected {}",
        case.target_mb, mb_month_item.amount_cents, expected_subtotal_cents,
    );
    assert_eq!(
        invoice.subtotal_cents, expected_subtotal_cents,
        "subtotal mismatch for {} MB: got {}, expected {}",
        case.target_mb, invoice.subtotal_cents, expected_subtotal_cents,
    );
    assert_eq!(
        invoice.total_cents, expected_total_cents,
        "total mismatch for {} MB: got {}, expected {}",
        case.target_mb, invoice.total_cents, expected_total_cents,
    );
}

#[tokio::test]
async fn free_plan_hot_storage_regression() {
    for case in FREE_PLAN_CASES {
        let mocks = setup_repos();
        let customer_id = Uuid::new_v4();

        seed_constant_daily_usage(&mocks.usage_repo, customer_id, case.target_mb, case.region);

        if let Some(minimum_spend_cents) = case.minimum_spend_cents_override {
            let active_card = mocks
                .rate_card_repo
                .get_active()
                .await
                .expect("get_active should succeed")
                .expect("active card should exist");
            mocks.rate_card_repo.seed_override(CustomerRateOverrideRow {
                customer_id,
                rate_card_id: active_card.id,
                overrides: json!({"minimum_spend_cents": minimum_spend_cents}),
                created_at: Utc::now(),
            });
        }

        let invoice = generate_invoice(&mocks, customer_id, case.billing_plan).await;

        assert_invoice_invariants(&invoice);
        assert_no_line_items_by_unit(&invoice, "requests_1k");
        assert_no_line_items_by_unit(&invoice, "write_ops_1k");

        let (expected_subtotal_cents, expected_total_cents) = expected_hot_storage_totals(case);
        assert_hot_storage_amounts(
            &invoice,
            case,
            expected_subtotal_cents,
            expected_total_cents,
        );
    }
}

#[tokio::test]
async fn free_plan_hot_storage_mutation_proof() {
    let case = FREE_PLAN_CASES
        .iter()
        .find(|candidate| candidate.target_mb == 68)
        .expect("68 MB free-plan case should exist");

    let mocks = setup_repos();
    let customer_id = Uuid::new_v4();
    seed_constant_daily_usage(&mocks.usage_repo, customer_id, case.target_mb, case.region);

    if let Some(minimum_spend_cents) = case.minimum_spend_cents_override {
        let active_card = mocks
            .rate_card_repo
            .get_active()
            .await
            .expect("get_active should succeed")
            .expect("active card should exist");
        mocks.rate_card_repo.seed_override(CustomerRateOverrideRow {
            customer_id,
            rate_card_id: active_card.id,
            overrides: json!({"minimum_spend_cents": minimum_spend_cents}),
            created_at: Utc::now(),
        });
    }

    let invoice = generate_invoice(&mocks, customer_id, case.billing_plan).await;
    assert_invoice_invariants(&invoice);
    assert_no_line_items_by_unit(&invoice, "requests_1k");
    assert_no_line_items_by_unit(&invoice, "write_ops_1k");

    let (expected_subtotal_cents, expected_total_cents) = expected_hot_storage_totals(case);
    let panic_result = catch_unwind(AssertUnwindSafe(|| {
        assert_hot_storage_amounts(
            &invoice,
            case,
            expected_subtotal_cents + 1,
            expected_total_cents,
        );
    }));

    assert!(
        panic_result.is_err(),
        "expected +1 cent mutation to panic in shared hot-storage assertions",
    );
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

#[tokio::test]
async fn shared_plan_staging_bundle_known_answer_regression() {
    let fixtures = load_stage2_bundle_fixtures();
    let expected_customer_id = Uuid::parse_str(STAGE2_EXPECTED_CUSTOMER_ID)
        .expect("stage2 fixture customer id should parse");
    let expected_invoice_id = Uuid::parse_str(STAGE2_EXPECTED_INVOICE_ID)
        .expect("stage2 fixture invoice id should parse");
    let expected_rate_card_id = Uuid::parse_str(STAGE2_EXPECTED_RATE_CARD_ID)
        .expect("stage2 fixture rate-card id should parse");

    assert_eq!(fixtures.invoice_db_row.id, expected_invoice_id);
    assert_eq!(fixtures.invoice_db_row.customer_id, expected_customer_id);
    assert_eq!(fixtures.customer_billing_context.id, expected_customer_id);
    assert_eq!(
        fixtures.customer_billing_context.billing_plan,
        BillingPlan::Shared.to_string()
    );
    assert_eq!(
        fixtures
            .customer_billing_context
            .object_storage_egress_carryforward_cents,
        Decimal::ZERO
    );
    assert!(fixtures.customer_rate_override.is_none());
    assert_eq!(
        fixtures.rate_card_selection.selection_basis,
        "invoice_created_at"
    );
    assert_eq!(
        fixtures.rate_card_selection.invoice_selection_timestamp,
        fixtures.invoice_db_row.created_at
    );
    assert!(fixtures
        .rate_card_selection
        .active_rate_card_when_different
        .is_none());
    assert!(!fixtures.rate_card_selection.override_exists);
    assert_eq!(
        fixtures.rate_card_selection.effective_rate_card.id,
        expected_rate_card_id
    );

    let mocks = setup_repos();
    mocks.rate_card_repo.seed_active_card(stage2_rate_card_row(
        &fixtures.rate_card_selection.effective_rate_card,
    ));
    seed_stage2_usage_rows(&mocks, &fixtures.usage_daily_replay_rows);

    let fixture_customer = stage2_customer_from_context(
        &fixtures.customer_billing_context,
        fixtures.invoice_db_row.created_at,
    );
    let billing_plan = fixture_customer.billing_plan_enum();
    let invoice = compute_invoice_for_customer(
        &mocks.billing_repos(),
        expected_customer_id,
        fixtures.invoice_db_row.period_start,
        fixtures.invoice_db_row.period_end,
        billing_plan,
        fixtures
            .customer_billing_context
            .object_storage_egress_carryforward_cents,
    )
    .await
    .expect("invoice generation should succeed");

    assert_eq!(fixtures.invoice_db_row.subtotal_cents, 11);
    assert_eq!(fixtures.invoice_db_row.total_cents, 500);
    assert!(fixtures.invoice_db_row.minimum_applied);
    assert_eq!(
        invoice.subtotal_cents,
        fixtures.invoice_db_row.subtotal_cents
    );
    assert_eq!(invoice.total_cents, fixtures.invoice_db_row.total_cents);
    assert_eq!(
        invoice.minimum_applied,
        fixtures.invoice_db_row.minimum_applied
    );
    assert_eq!(
        fixtures.invoice_line_items.len(),
        1,
        "stage2 fixture should pin exactly one line item for invoice replay"
    );
    assert_eq!(
        invoice.line_items.len(),
        fixtures.invoice_line_items.len(),
        "generated line-item count should match stage2 fixture count"
    );
    let fixture_units: BTreeSet<&str> = fixtures
        .invoice_line_items
        .iter()
        .map(|line_item| line_item.unit.as_str())
        .collect();
    let generated_units: BTreeSet<&str> = invoice
        .line_items
        .iter()
        .map(|line_item| line_item.unit.as_str())
        .collect();
    assert_eq!(
        generated_units, fixture_units,
        "generated line-item units should exactly match fixture units"
    );

    let hot_storage_fixture = fixtures
        .invoice_line_items
        .iter()
        .find(|line_item| line_item.unit == "mb_months")
        .expect("fixture hot-storage line item should exist");
    let hot_storage_generated = assert_single_line_item_by_unit(&invoice, "mb_months");
    assert_eq!(
        hot_storage_generated.description,
        hot_storage_fixture.description
    );
    assert_eq!(
        hot_storage_generated.quantity.round_dp(6),
        hot_storage_fixture.quantity
    );
    assert_eq!(hot_storage_generated.unit, hot_storage_fixture.unit);
    assert_eq!(
        hot_storage_generated.unit_price_cents,
        hot_storage_fixture.unit_price_cents
    );
    assert_eq!(
        hot_storage_generated.amount_cents,
        hot_storage_fixture.amount_cents
    );
    assert_eq!(hot_storage_generated.region, hot_storage_fixture.region);
    assert_eq!(
        mocks.rate_card_repo.get_override_call_count(),
        1,
        "replay should query override seam for the selected base card even when fixture override is absent"
    );
}

#[tokio::test]
async fn shared_plan_stage2_replay_distinguishes_fixture_card_from_current_active_card() {
    let fixtures = load_stage2_bundle_fixtures();
    let expected_customer_id = Uuid::parse_str(STAGE2_EXPECTED_CUSTOMER_ID)
        .expect("stage2 fixture customer id should parse");
    let expected_rate_card_id = Uuid::parse_str(STAGE2_EXPECTED_RATE_CARD_ID)
        .expect("stage2 fixture rate-card id should parse");
    let fixture_customer = stage2_customer_from_context(
        &fixtures.customer_billing_context,
        fixtures.invoice_db_row.created_at,
    );
    let billing_plan = fixture_customer.billing_plan_enum();

    let fixture_rate_card = stage2_rate_card_row(&fixtures.rate_card_selection.effective_rate_card);
    assert_eq!(fixture_rate_card.id, expected_rate_card_id);

    let mut divergent_active_card = fixture_rate_card.clone();
    divergent_active_card.id = Uuid::new_v4();
    divergent_active_card.storage_rate_per_mb_month = dec!(0.20);
    divergent_active_card.minimum_spend_cents = 0;
    divergent_active_card.shared_minimum_spend_cents = 0;

    let mocks = setup_repos();
    mocks
        .rate_card_repo
        .seed_active_card(divergent_active_card.clone());
    mocks
        .rate_card_repo
        .seed_card_by_id(fixture_rate_card.clone());
    seed_stage2_usage_rows(&mocks, &fixtures.usage_daily_replay_rows);

    let replay_invoice = compute_invoice_for_customer_with_rate_card_id(
        &mocks.billing_repos(),
        expected_customer_id,
        expected_rate_card_id,
        fixtures.invoice_db_row.period_start,
        fixtures.invoice_db_row.period_end,
        billing_plan,
        fixtures
            .customer_billing_context
            .object_storage_egress_carryforward_cents,
    )
    .await
    .expect("fixture-card replay invoice generation should succeed");

    let active_card_invoice = compute_invoice_for_customer(
        &mocks.billing_repos(),
        expected_customer_id,
        fixtures.invoice_db_row.period_start,
        fixtures.invoice_db_row.period_end,
        billing_plan,
        fixtures
            .customer_billing_context
            .object_storage_egress_carryforward_cents,
    )
    .await
    .expect("active-card replay invoice generation should succeed");

    assert_ne!(
        replay_invoice.subtotal_cents, active_card_invoice.subtotal_cents,
        "replay seam should detect different invoice results when current-active card diverges"
    );
    assert_eq!(
        mocks.rate_card_repo.get_by_id_call_count(),
        1,
        "fixture-card replay should resolve the base card via get_by_id exactly once"
    );
    assert!(
        mocks.rate_card_repo.get_active_call_count() >= 1,
        "active-card replay should still query get_active via compute_invoice_for_customer"
    );
}

#[tokio::test]
async fn shared_plan_stage2_usage_rows_preserve_fixture_aggregated_at_provenance() {
    let fixtures = load_stage2_bundle_fixtures();
    let expected_customer_id = Uuid::parse_str(STAGE2_EXPECTED_CUSTOMER_ID)
        .expect("stage2 fixture customer id should parse");

    let mocks = setup_repos();
    seed_stage2_usage_rows(&mocks, &fixtures.usage_daily_replay_rows);

    let replay_rows = mocks
        .usage_repo
        .get_daily_usage(
            expected_customer_id,
            fixtures.invoice_db_row.period_start,
            fixtures.invoice_db_row.period_end,
        )
        .await
        .expect("usage replay rows should load from mock repo");

    let expected_rows: BTreeMap<(NaiveDate, String), DateTime<Utc>> = fixtures
        .usage_daily_replay_rows
        .iter()
        .map(|row| ((row.date, row.region.clone()), row.aggregated_at))
        .collect();
    let actual_rows: BTreeMap<(NaiveDate, String), DateTime<Utc>> = replay_rows
        .iter()
        .map(|row| ((row.date, row.region.clone()), row.aggregated_at))
        .collect();

    assert_eq!(
        actual_rows, expected_rows,
        "stage2 replay must preserve fixture aggregated_at values exactly"
    );
    assert!(
        fixtures
            .usage_daily_replay_rows
            .iter()
            .all(|row| row.aggregated_at <= fixtures.invoice_db_row.created_at),
        "stage2 usage fixture rows must not include post-invoice aggregates"
    );
}

#[tokio::test]
async fn shared_plan_stage2_usage_record_provenance_stays_within_replay_cutoff() {
    let fixtures = load_stage2_bundle_fixtures();
    let expected_customer_id = Uuid::parse_str(STAGE2_EXPECTED_CUSTOMER_ID)
        .expect("stage2 fixture customer id should parse");
    let replay_row_cutoffs: BTreeMap<(NaiveDate, String), DateTime<Utc>> = fixtures
        .usage_daily_replay_rows
        .iter()
        .map(|row| ((row.date, row.region.clone()), row.aggregated_at))
        .collect();

    assert!(
        !fixtures.usage_records_provenance.is_empty(),
        "stage2 fixture should preserve raw usage provenance rows"
    );
    assert!(
        fixtures
            .usage_records_provenance
            .iter()
            .all(|row| row.customer_id == expected_customer_id),
        "raw usage provenance rows must stay pinned to the fixture customer"
    );
    assert!(
        fixtures
            .usage_records_provenance
            .iter()
            .all(|row| row.recorded_at <= fixtures.invoice_db_row.created_at),
        "raw usage provenance rows must not extend beyond the invoice-created replay cutoff"
    );
    assert!(
        fixtures.usage_records_provenance.iter().all(|row| {
            replay_row_cutoffs
                .get(&(row.recorded_at.date_naive(), row.region.clone()))
                .is_some_and(|cutoff| row.recorded_at <= *cutoff)
        }),
        "raw usage provenance rows must stay within the captured replay day/region cutoffs"
    );
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

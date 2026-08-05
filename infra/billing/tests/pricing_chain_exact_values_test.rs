use billing::aggregation::{summarize, CustomerBillingContext};
use billing::pricing::{calculate_invoice, PricingError};
use billing::rate_card::RateCard;
use billing::types::{DailyUsageRecord, MonthlyUsageSummary};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use std::collections::HashMap;
use uuid::Uuid;

fn february_period() -> (NaiveDate, NaiveDate) {
    (
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
    )
}

fn february_day(day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 2, day).unwrap()
}

fn daily_usage_record(
    customer_id: Uuid,
    date: NaiveDate,
    region: &str,
    storage_bytes_avg: i64,
) -> DailyUsageRecord {
    DailyUsageRecord {
        customer_id,
        date,
        region: region.to_string(),
        search_requests: 0,
        write_operations: 0,
        storage_bytes_avg,
        documents_count_avg: 0,
    }
}

fn canonical_rate_card(region_multipliers: HashMap<String, Decimal>) -> RateCard {
    RateCard {
        id: Uuid::new_v4(),
        name: "test".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.05),
        region_multipliers,
        minimum_spend_cents: 1000,
        shared_minimum_spend_cents: 500,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
    }
}

fn no_billing_context() -> HashMap<Uuid, CustomerBillingContext> {
    HashMap::new()
}

fn zero_monthly_usage() -> MonthlyUsageSummary {
    let (period_start, period_end) = february_period();
    MonthlyUsageSummary {
        customer_id: Uuid::new_v4(),
        period_start,
        period_end,
        region: "us-east-1".to_string(),
        total_search_requests: 0,
        total_write_operations: 0,
        storage_mb_months: Decimal::ZERO,
        cold_storage_gb_months: Decimal::ZERO,
        object_storage_gb_months: Decimal::ZERO,
        object_storage_egress_gb: Decimal::ZERO,
    }
}

fn line_item_amount(
    summary: &billing::types::MonthlyUsageSummary,
    rate: &RateCard,
    unit: &str,
) -> i64 {
    calculate_invoice(summary, rate)
        .unwrap()
        .line_items
        .into_iter()
        .find(|line_item| line_item.unit == unit)
        .map(|line_item| line_item.amount_cents)
        .unwrap_or(0)
}

fn total_line_item_amount(
    summaries: &[billing::types::MonthlyUsageSummary],
    rate: &RateCard,
) -> i64 {
    summaries
        .iter()
        .flat_map(|summary| calculate_invoice(summary, rate).unwrap().line_items)
        .map(|line_item| line_item.amount_cents)
        .sum()
}

#[test]
fn multi_region_hot_storage_sums_exact_rounded_region_charges() {
    let customer_id = Uuid::new_v4();
    let (period_start, period_end) = february_period();
    let mut records = Vec::new();

    for day in 1..=28 {
        records.push(daily_usage_record(
            customer_id,
            february_day(day),
            "us-east-1",
            2_000_000,
        ));
        records.push(daily_usage_record(
            customer_id,
            february_day(day),
            "eu-west-1",
            1_000_000,
        ));
    }

    let summaries = summarize(&records, period_start, period_end, &no_billing_context());
    let us_summary = summaries
        .iter()
        .find(|summary| summary.region == "us-east-1")
        .expect("us-east-1 summary missing");
    let eu_summary = summaries
        .iter()
        .find(|summary| summary.region == "eu-west-1")
        .expect("eu-west-1 summary missing");
    let rate = canonical_rate_card(HashMap::from([("eu-west-1".to_string(), dec!(1.3))]));

    // us-east-1: 56 MB-days / 28 days = 2.0 MB-months.
    assert_eq!(us_summary.storage_mb_months, dec!(2));
    // eu-west-1: 28 MB-days / 28 days = 1.0 MB-month.
    assert_eq!(eu_summary.storage_mb_months, dec!(1));

    assert_eq!(line_item_amount(us_summary, &rate, "mb_months"), 10);
    // 1.0 MB-month * 5 cents/MB * 1.3 = 6.5 cents, banker-rounded to 6 cents.
    assert_eq!(line_item_amount(eu_summary, &rate, "mb_months"), 6);
    assert_eq!(total_line_item_amount(&summaries, &rate), 16);
}

#[test]
fn sparse_three_day_average_rounds_repeating_decimal_invoice_to_exact_cents() {
    let customer_id = Uuid::new_v4();
    let period_start = february_day(1);
    let period_end = february_day(3);
    let records = vec![daily_usage_record(
        customer_id,
        february_day(1),
        "us-east-1",
        10_000_000,
    )];
    let rate = canonical_rate_card(HashMap::new());

    let summaries = summarize(&records, period_start, period_end, &no_billing_context());
    let summary = summaries
        .iter()
        .find(|summary| summary.region == "us-east-1")
        .expect("us-east-1 summary missing");

    assert_eq!(summary.storage_mb_months, dec!(10) / dec!(3));
    // 10/3 MB-months * 5 cents/MB = 50/3 cents = 16.666... cents -> 17 cents.
    assert_eq!(line_item_amount(summary, &rate, "mb_months"), 17);
}

#[test]
fn cold_storage_context_is_billed_once_across_regions() {
    let customer_id = Uuid::new_v4();
    let (period_start, period_end) = february_period();
    let records = vec![
        daily_usage_record(customer_id, february_day(1), "us-east-1", 0),
        daily_usage_record(customer_id, february_day(1), "eu-west-1", 0),
    ];
    let billing_context = HashMap::from([(
        customer_id,
        CustomerBillingContext {
            cold_storage_gb_months: dec!(4),
            object_storage_gb_months: dec!(0),
            object_storage_egress_gb: dec!(0),
        },
    )]);
    let rate = canonical_rate_card(HashMap::new());

    let summaries = summarize(&records, period_start, period_end, &billing_context);
    let eu_summary = summaries
        .iter()
        .find(|summary| summary.region == "eu-west-1")
        .expect("eu-west-1 summary missing");
    let us_summary = summaries
        .iter()
        .find(|summary| summary.region == "us-east-1")
        .expect("us-east-1 summary missing");

    assert_eq!(eu_summary.cold_storage_gb_months, dec!(4));
    assert_eq!(us_summary.cold_storage_gb_months, dec!(0));
    assert_eq!(line_item_amount(eu_summary, &rate, "cold_gb_months"), 8);
    assert_eq!(
        total_line_item_amount(std::slice::from_ref(us_summary), &rate),
        0
    );
    assert_eq!(total_line_item_amount(&summaries, &rate), 8);
}

#[test]
fn invoice_subtotal_overflow_returns_error() {
    let mut rate = canonical_rate_card(HashMap::new());
    rate.storage_rate_per_mb_month = Decimal::from(i64::MAX) / dec!(200);
    rate.cold_storage_rate_per_gb_month = Decimal::from(i64::MAX) / dec!(200);
    let usage = MonthlyUsageSummary {
        storage_mb_months: dec!(1),
        cold_storage_gb_months: dec!(1),
        ..zero_monthly_usage()
    };

    assert_eq!(
        calculate_invoice(&usage, &rate),
        Err(PricingError::AmountOverflow)
    );
}

#[test]
fn decimal_multiplication_overflow_returns_error_without_panic() {
    let mut rate = canonical_rate_card(HashMap::new());
    rate.storage_rate_per_mb_month = Decimal::ONE;
    let usage = MonthlyUsageSummary {
        storage_mb_months: Decimal::MAX,
        ..zero_monthly_usage()
    };

    let result = std::panic::catch_unwind(|| calculate_invoice(&usage, &rate));

    assert!(
        result.is_ok(),
        "calculate_invoice must not panic when Decimal multiplication overflows"
    );
    assert_eq!(result.unwrap(), Err(PricingError::AmountOverflow));
}

use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};
use aggregation_job::rollup::{day_window, ROLLUP_SQL};
use billing::aggregation::summarize;
use billing::types::{DailyUsageRecord, MonthlyUsageSummary};
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal_macros::dec;
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

type DailyUsageRow = (Uuid, NaiveDate, String, i64, i64, i64, i64);

struct FixtureIdentity {
    customer_id: Uuid,
    tenant: String,
    region: String,
    node: String,
}

impl FixtureIdentity {
    fn new(label: &str) -> Self {
        Self {
            customer_id: Uuid::new_v4(),
            tenant: format!("{label}_tenant"),
            region: format!("{label}_region"),
            node: format!("{label}_node"),
        }
    }
}

struct RawUsageRecord<'a> {
    identity: &'a FixtureIdentity,
    event_type: &'static str,
    value: i64,
    recorded_at: DateTime<Utc>,
}

impl<'a> RawUsageRecord<'a> {
    fn new(
        identity: &'a FixtureIdentity,
        event_type: &'static str,
        value: i64,
        recorded_at: DateTime<Utc>,
    ) -> Self {
        Self {
            identity,
            event_type,
            value,
            recorded_at,
        }
    }
}

#[derive(Clone, Copy)]
struct PeriodSpec {
    label: &'static str,
    period_start: NaiveDate,
    period_end: NaiveDate,
    active_start: NaiveDate,
    storage_bytes: i64,
    writes_per_day: i64,
}

struct PeriodResult {
    identity: FixtureIdentity,
    summary: MonthlyUsageSummary,
}

fn date(year: i32, month: u32, day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(year, month, day).expect("fixture date must be valid")
}

fn at_utc(date: NaiveDate, hour: u32, minute: u32, second: u32) -> DateTime<Utc> {
    date.and_hms_opt(hour, minute, second)
        .expect("fixture timestamp must be valid")
        .and_utc()
}

async fn create_fixture_identity(pool: &PgPool, label: &str) -> FixtureIdentity {
    let identity = FixtureIdentity::new(label);
    insert_active_customer(pool, identity.customer_id, 1).await;
    identity
}

async fn insert_raw_usage(pool: &PgPool, record: RawUsageRecord<'_>) {
    sqlx::query(
        "INSERT INTO usage_records
         (idempotency_key, customer_id, tenant_id, region, node_id,
          event_type, value, recorded_at, flapjack_ts)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(format!(
        "{}:{}:{}:{}:{}:{}",
        record.identity.customer_id,
        record.identity.tenant,
        record.identity.node,
        record.event_type,
        record.value,
        record.recorded_at.timestamp_micros()
    ))
    .bind(record.identity.customer_id)
    .bind(&record.identity.tenant)
    .bind(&record.identity.region)
    .bind(&record.identity.node)
    .bind(record.event_type)
    .bind(record.value)
    .bind(record.recorded_at)
    .bind(record.recorded_at)
    .execute(pool)
    .await
    .expect("insert raw usage fixture");
}

async fn run_rollup_for_day(pool: &PgPool, target: NaiveDate) {
    let (window_start, window_end) = day_window(target);
    sqlx::query(ROLLUP_SQL)
        .bind(window_start)
        .bind(window_end)
        .bind(target)
        .execute(pool)
        .await
        .unwrap_or_else(|error| panic!("production rollup failed for {target}: {error}"));
}

fn daily_usage_from_row(row: DailyUsageRow) -> DailyUsageRecord {
    DailyUsageRecord {
        customer_id: row.0,
        date: row.1,
        region: row.2,
        search_requests: row.3,
        write_operations: row.4,
        storage_bytes_avg: row.5,
        documents_count_avg: row.6,
    }
}

async fn read_daily_usage_for_day(
    pool: &PgPool,
    identity: &FixtureIdentity,
    target: NaiveDate,
) -> DailyUsageRecord {
    let rows = sqlx::query_as::<_, DailyUsageRow>(
        "SELECT customer_id, date, region, search_requests, write_operations,
                storage_bytes_avg, documents_count_avg
         FROM usage_daily
         WHERE customer_id = $1 AND region = $2 AND date = $3",
    )
    .bind(identity.customer_id)
    .bind(&identity.region)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("read rolled-up daily usage");

    assert_eq!(
        rows.len(),
        1,
        "expected exactly one usage_daily row for {} on {target}",
        identity.region
    );
    daily_usage_from_row(rows.into_iter().next().expect("row count checked"))
}

async fn read_daily_usage_for_period(
    pool: &PgPool,
    identity: &FixtureIdentity,
    period_start: NaiveDate,
    period_end: NaiveDate,
) -> Vec<DailyUsageRecord> {
    sqlx::query_as::<_, DailyUsageRow>(
        "SELECT customer_id, date, region, search_requests, write_operations,
                storage_bytes_avg, documents_count_avg
         FROM usage_daily
         WHERE customer_id = $1 AND region = $2
           AND date >= $3 AND date <= $4
         ORDER BY date",
    )
    .bind(identity.customer_id)
    .bind(&identity.region)
    .bind(period_start)
    .bind(period_end)
    .fetch_all(pool)
    .await
    .expect("read rolled-up usage period")
    .into_iter()
    .map(daily_usage_from_row)
    .collect()
}

async fn run_period_case(pool: &PgPool, spec: PeriodSpec) -> PeriodResult {
    let identity = create_fixture_identity(pool, spec.label).await;
    let mut current = spec.active_start;

    while current <= spec.period_end {
        let recorded_at = at_utc(current, 12, 0, 0);
        insert_raw_usage(
            pool,
            RawUsageRecord::new(&identity, "storage_bytes", spec.storage_bytes, recorded_at),
        )
        .await;
        if spec.writes_per_day > 0 {
            insert_raw_usage(
                pool,
                RawUsageRecord::new(
                    &identity,
                    "write_operations",
                    spec.writes_per_day,
                    recorded_at,
                ),
            )
            .await;
        }
        run_rollup_for_day(pool, current).await;
        current = current.succ_opt().expect("fixture period must advance");
    }

    let records =
        read_daily_usage_for_period(pool, &identity, spec.period_start, spec.period_end).await;
    let matching: Vec<_> = summarize(
        &records,
        spec.period_start,
        spec.period_end,
        &HashMap::new(),
    )
    .into_iter()
    .filter(|summary| {
        summary.customer_id == identity.customer_id && summary.region == identity.region
    })
    .collect();
    assert_eq!(
        matching.len(),
        1,
        "expected exactly one monthly summary for {}",
        identity.region
    );

    PeriodResult {
        identity,
        summary: matching.into_iter().next().expect("summary count checked"),
    }
}

#[tokio::test]
async fn aggregation_known_answer_postgres_gauge_rounding() {
    let Some(harness) = connect_and_migrate("it_aggregation_kat").await else {
        return;
    };
    let target = date(2026, 1, 10);
    let identity = create_fixture_identity(&harness.pool, "gauge_rounding").await;

    for value in [2_000_000, 4_000_000, 6_000_000] {
        insert_raw_usage(
            &harness.pool,
            RawUsageRecord::new(&identity, "storage_bytes", value, at_utc(target, 10, 0, 0)),
        )
        .await;
    }
    for value in [1_000_000, 2_000_001] {
        insert_raw_usage(
            &harness.pool,
            RawUsageRecord::new(&identity, "document_count", value, at_utc(target, 11, 0, 0)),
        )
        .await;
    }

    run_rollup_for_day(&harness.pool, target).await;
    let daily = read_daily_usage_for_day(&harness.pool, &identity, target).await;

    // (2_000_000 + 4_000_000 + 6_000_000) / 3 = 4_000_000.
    assert_eq!(daily.storage_bytes_avg, 4_000_000);
    // (1_000_000 + 2_000_001) / 2 = 1_500_000.5; PostgreSQL ROUND(numeric) = 1_500_001.
    assert_eq!(daily.documents_count_avg, 1_500_001);
    println!(
        "aggregation_known_answer gauge expected_storage=4_000_000 observed_storage={} \
         expected_tie=1_500_001 observed_tie={}",
        daily.storage_bytes_avg, daily.documents_count_avg
    );
}

#[tokio::test]
async fn aggregation_known_answer_half_open_utc_day_boundary() {
    let Some(harness) = connect_and_migrate("it_aggregation_kat").await else {
        return;
    };
    let target = date(2026, 1, 20);
    let next_day = target.succ_opt().expect("target date must advance");
    let identity = create_fixture_identity(&harness.pool, "utc_boundary").await;

    for (value, recorded_at) in [
        (10, at_utc(target, 0, 0, 0)),
        (20, at_utc(target, 23, 59, 59)),
        (40, at_utc(next_day, 0, 0, 0)),
    ] {
        insert_raw_usage(
            &harness.pool,
            RawUsageRecord::new(&identity, "write_operations", value, recorded_at),
        )
        .await;
    }

    run_rollup_for_day(&harness.pool, target).await;
    run_rollup_for_day(&harness.pool, next_day).await;
    let target_daily = read_daily_usage_for_day(&harness.pool, &identity, target).await;
    let next_daily = read_daily_usage_for_day(&harness.pool, &identity, next_day).await;

    assert_eq!(target_daily.write_operations, 30);
    assert_eq!(next_daily.write_operations, 40);
    println!(
        "aggregation_known_answer boundary target={} next={}",
        target_daily.write_operations, next_daily.write_operations
    );
}

#[tokio::test]
async fn aggregation_known_answer_month_length_and_sparse_normalization() {
    let Some(harness) = connect_and_migrate("it_aggregation_kat").await else {
        return;
    };
    let cases = [
        PeriodSpec {
            label: "jan_31_day",
            period_start: date(2026, 1, 1),
            period_end: date(2026, 1, 31),
            active_start: date(2026, 1, 1),
            storage_bytes: 2_000_000,
            writes_per_day: 100,
        },
        PeriodSpec {
            label: "leap_feb_29_day",
            period_start: date(2024, 2, 1),
            period_end: date(2024, 2, 29),
            active_start: date(2024, 2, 1),
            storage_bytes: 1_000_000,
            writes_per_day: 0,
        },
        PeriodSpec {
            label: "apr_30_day",
            period_start: date(2026, 4, 1),
            period_end: date(2026, 4, 30),
            active_start: date(2026, 4, 1),
            storage_bytes: 3_000_000,
            writes_per_day: 0,
        },
        PeriodSpec {
            label: "feb_28_day",
            period_start: date(2026, 2, 1),
            period_end: date(2026, 2, 28),
            active_start: date(2026, 2, 1),
            storage_bytes: 1_000_000,
            writes_per_day: 0,
        },
        PeriodSpec {
            label: "sparse_feb_14_day",
            period_start: date(2026, 2, 1),
            period_end: date(2026, 2, 28),
            active_start: date(2026, 2, 15),
            storage_bytes: 2_000_000,
            writes_per_day: 0,
        },
    ];

    let jan = run_period_case(&harness.pool, cases[0]).await;
    let leap_feb = run_period_case(&harness.pool, cases[1]).await;
    let april = run_period_case(&harness.pool, cases[2]).await;
    let feb = run_period_case(&harness.pool, cases[3]).await;
    let sparse_feb = run_period_case(&harness.pool, cases[4]).await;

    // 31 × 2_000_000 / 1_000_000 / 31 = 2.
    assert_eq!(jan.summary.storage_mb_months, dec!(2));
    // 31 × 100 = 3_100.
    assert_eq!(jan.summary.total_write_operations, 3_100);
    // 29 × 1_000_000 / 1_000_000 / 29 = 1.
    assert_eq!(leap_feb.summary.storage_mb_months, dec!(1));
    // 30 × 3_000_000 / 1_000_000 / 30 = 3.
    assert_eq!(april.summary.storage_mb_months, dec!(3));
    // 28 × 1_000_000 / 1_000_000 / 28 = 1.
    assert_eq!(feb.summary.storage_mb_months, dec!(1));
    // 14 × 2_000_000 / 1_000_000 / 28 = 1.
    assert_eq!(sparse_feb.summary.storage_mb_months, dec!(1));

    let sparse_early_rows = read_daily_usage_for_period(
        &harness.pool,
        &sparse_feb.identity,
        date(2026, 2, 1),
        date(2026, 2, 14),
    )
    .await;
    assert!(
        sparse_early_rows.is_empty(),
        "sparse period must not fabricate usage_daily rows for February 1-14"
    );

    println!(
        "aggregation_known_answer months jan={} leap_feb={} april={} feb={} sparse={} \
         expected_writes=3_100 observed_writes={}",
        jan.summary.storage_mb_months,
        leap_feb.summary.storage_mb_months,
        april.summary.storage_mb_months,
        feb.summary.storage_mb_months,
        sparse_feb.summary.storage_mb_months,
        jan.summary.total_write_operations
    );
}

// Integration tests for the metering and aggregation pipeline.
//
// Scope: this file is intentionally limited to real Postgres-backed pipeline
// semantics and one live metering capture probe.

mod common;
#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use aggregation_job::rollup::{day_window, ROLLUP_SQL};
use api::invoicing::{generate_invoice, StorageInputs};
use api::models::customer::BillingPlan;
use api::models::{RateCardRow, UsageDaily};
use api::repos::{PgUsageRepo, UsageRepo};
use chrono::{NaiveDate, TimeZone, Utc};
use integration_helpers::{db_url, endpoint_reachable, seed_verified_user_directly};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use uuid::Uuid;

fn unique_email(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string();
    format!("{prefix}-{}@integration-test.local", &id[..8])
}

fn flapjack_documents_url(base: &str, index_name: &str) -> String {
    format!("{base}/1/indexes/{index_name}/documents")
}

fn flapjack_query_url(base: &str, index_name: &str) -> String {
    format!("{base}/1/indexes/{index_name}/query")
}

fn metering_key_request_payload() -> serde_json::Value {
    serde_json::json!({
        "description": "metering test key",
        "acl": ["search", "addObject"]
    })
}

fn metering_create_index_payload(index_name: &str) -> serde_json::Value {
    serde_json::json!({
        "name": index_name,
        "region": "us-east-1"
    })
}

fn test_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "integration-test-rate-card".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: serde_json::json!({}),
        minimum_spend_cents: 100,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: chrono::Utc::now(),
    }
}

async fn usage_totals_for_index_since(
    pool: &sqlx::PgPool,
    customer_id: Uuid,
    index_name: &str,
    since: chrono::DateTime<chrono::Utc>,
) -> (i64, i64) {
    let search_total: i64 = sqlx::query_scalar(
        "SELECT COALESCE(SUM(value), 0) FROM usage_records \
         WHERE customer_id = $1 \
           AND tenant_id = $2 \
           AND event_type = 'search_requests' \
           AND recorded_at >= $3",
    )
    .bind(customer_id)
    .bind(index_name)
    .bind(since)
    .fetch_one(pool)
    .await
    .expect("failed to query search_requests total");

    let write_total: i64 = sqlx::query_scalar(
        "SELECT COALESCE(SUM(value), 0) FROM usage_records \
         WHERE customer_id = $1 \
           AND tenant_id = $2 \
           AND event_type = 'write_operations' \
           AND recorded_at >= $3",
    )
    .bind(customer_id)
    .bind(index_name)
    .bind(since)
    .fetch_one(pool)
    .await
    .expect("failed to query write_operations total");

    (search_total, write_total)
}

async fn wait_for_usage_totals(
    pool: &sqlx::PgPool,
    customer_id: Uuid,
    index_name: &str,
    since: chrono::DateTime<chrono::Utc>,
    min_search: i64,
    min_write: i64,
) -> (i64, i64) {
    let timeout = std::time::Duration::from_secs(15);
    let poll_interval = std::time::Duration::from_millis(250);
    let deadline = std::time::Instant::now() + timeout;
    let (mut search_total, mut write_total) =
        usage_totals_for_index_since(pool, customer_id, index_name, since).await;

    loop {
        if search_total >= min_search && write_total >= min_write {
            return (search_total, write_total);
        }

        if std::time::Instant::now() >= deadline {
            return (search_total, write_total);
        }

        tokio::time::sleep(poll_interval).await;
        (search_total, write_total) =
            usage_totals_for_index_since(pool, customer_id, index_name, since).await;
    }
}

async fn insert_usage_event(
    pool: &sqlx::PgPool,
    customer_id: Uuid,
    event_type: &str,
    value: i64,
    recorded_at: chrono::DateTime<chrono::Utc>,
) {
    let idempotency_key = format!("{}-{}-{event_type}-{value}", customer_id, Uuid::new_v4());

    sqlx::query(
        "INSERT INTO usage_records
         (idempotency_key, customer_id, tenant_id, region, node_id, event_type, value, recorded_at, flapjack_ts)
         VALUES ($1, $2, 'test-tenant', 'us-east-1', 'test-node', $3, $4, $5, $5)",
    )
    .bind(idempotency_key)
    .bind(customer_id)
    .bind(event_type)
    .bind(value)
    .bind(recorded_at)
    .execute(pool)
    .await
    .unwrap_or_else(|e| panic!("failed to insert usage record for {event_type}: {e}"));
}

async fn run_rollup_for_day(pool: &sqlx::PgPool, date: NaiveDate) {
    let (start, end) = day_window(date);
    sqlx::query(ROLLUP_SQL)
        .bind(start)
        .bind(end)
        .bind(date)
        .execute(pool)
        .await
        .unwrap_or_else(|e| panic!("rollup failed for {date}: {e}"));
}

async fn get_daily_usage_via_repo(
    pool: &sqlx::PgPool,
    customer_id: Uuid,
    start_date: NaiveDate,
    end_date: NaiveDate,
) -> Vec<UsageDaily> {
    let usage_repo = PgUsageRepo::new(pool.clone());
    usage_repo
        .get_daily_usage(customer_id, start_date, end_date)
        .await
        .expect("PgUsageRepo::get_daily_usage failed")
}

integration_test!(metering_agent_captures_real_flapjack_usage, async {
    use integration_helpers::{api_base, flapjack_base, http_client, register_and_login};

    let client = http_client();
    let base = api_base();
    let flapjack = flapjack_base();

    require_live!(
        endpoint_reachable(&base).await,
        "API endpoint unreachable for metering capture test"
    );
    require_live!(
        endpoint_reachable(&flapjack).await,
        "flapjack endpoint unreachable for metering capture test"
    );

    let email = unique_email("metering-capture");
    let token = register_and_login(&client, &base, &email).await;

    let index_name = format!("metering-{}", &Uuid::new_v4().to_string()[..8]);

    let create_resp = client
        .post(format!("{base}/indexes"))
        .bearer_auth(&token)
        .json(&metering_create_index_payload(&index_name))
        .send()
        .await
        .expect("create index request failed");
    assert!(
        create_resp.status().is_success(),
        "create index failed: {}",
        create_resp.text().await.unwrap_or_default()
    );

    let keys_resp = client
        .post(format!("{base}/indexes/{index_name}/keys"))
        .bearer_auth(&token)
        .json(&metering_key_request_payload())
        .send()
        .await
        .expect("create key request failed");
    assert!(
        keys_resp.status().is_success(),
        "create key failed: {}",
        keys_resp.text().await.unwrap_or_default()
    );

    let keys_body: serde_json::Value = keys_resp.json().await.expect("keys response not JSON");
    let search_key = keys_body["key"]
        .as_str()
        .expect("key field missing")
        .to_string();

    let test_started_at = chrono::Utc::now();

    for i in 0..10i64 {
        let doc_resp = client
            .post(flapjack_documents_url(&flapjack, &index_name))
            .header("X-Algolia-API-Key", &search_key)
            .json(&serde_json::json!([{ "id": i, "content": format!("metering test doc {i}") }]))
            .send()
            .await
            .expect("push doc request failed");
        assert!(
            doc_resp.status().is_success(),
            "push doc failed (i={i}): {}",
            doc_resp.text().await.unwrap_or_default()
        );
    }

    for _ in 0..5 {
        let search_resp = client
            .post(flapjack_query_url(&flapjack, &index_name))
            .header("X-Algolia-API-Key", &search_key)
            .json(&serde_json::json!({ "query": "metering", "hitsPerPage": 10 }))
            .send()
            .await
            .expect("search request failed");
        assert!(
            search_resp.status().is_success(),
            "search failed: {}",
            search_resp.text().await.unwrap_or_default()
        );
    }

    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");

    let customer_id: Uuid = sqlx::query_scalar("SELECT id FROM customers WHERE email = $1")
        .bind(&email)
        .fetch_one(&pool)
        .await
        .expect("failed to find customer by email");

    let (search_total, write_total) =
        wait_for_usage_totals(&pool, customer_id, &index_name, test_started_at, 5, 10).await;

    assert!(
        write_total >= 10,
        "expected at least 10 write_operations for index {index_name}, got {write_total}"
    );
    assert!(
        search_total >= 5,
        "expected at least 5 search_requests for index {index_name}, got {search_total}"
    );

    pool.close().await;
});

integration_test!(rollup_rerun_overwrites_row_after_same_day_mutation, async {
    require_live!(
        integration_helpers::db_url_available().await,
        "Database unreachable"
    );

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    let customer_id = seed_verified_user_directly(&pool, &unique_email("rollup-rerun")).await;
    let target_day = NaiveDate::from_ymd_opt(2026, 2, 17).unwrap();

    let first_snapshot = Utc.from_utc_datetime(&target_day.and_hms_opt(10, 0, 0).unwrap());
    insert_usage_event(&pool, customer_id, "search_requests", 1_000, first_snapshot).await;
    insert_usage_event(&pool, customer_id, "write_operations", 200, first_snapshot).await;
    insert_usage_event(&pool, customer_id, "storage_bytes", 100, first_snapshot).await;
    insert_usage_event(&pool, customer_id, "document_count", 10, first_snapshot).await;

    run_rollup_for_day(&pool, target_day).await;

    let later_snapshot = Utc.from_utc_datetime(&target_day.and_hms_opt(16, 0, 0).unwrap());
    insert_usage_event(&pool, customer_id, "search_requests", 500, later_snapshot).await;
    insert_usage_event(&pool, customer_id, "write_operations", 50, later_snapshot).await;
    insert_usage_event(&pool, customer_id, "storage_bytes", 300, later_snapshot).await;
    insert_usage_event(&pool, customer_id, "document_count", 30, later_snapshot).await;

    run_rollup_for_day(&pool, target_day).await;

    let rows = get_daily_usage_via_repo(&pool, customer_id, target_day, target_day).await;
    assert_eq!(rows.len(), 1, "expected one usage_daily row after rerun");

    let row = &rows[0];
    assert_eq!(row.search_requests, 1_500);
    assert_eq!(row.write_operations, 250);
    assert_eq!(row.storage_bytes_avg, 200);
    assert_eq!(row.documents_count_avg, 20);

    pool.close().await;
});

integration_test!(rollup_averages_and_rounds_same_day_gauge_snapshots, async {
    require_live!(
        integration_helpers::db_url_available().await,
        "Database unreachable"
    );

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    let customer_id = seed_verified_user_directly(&pool, &unique_email("rollup-gauges")).await;
    let target_day = NaiveDate::from_ymd_opt(2026, 2, 18).unwrap();

    let morning = Utc.from_utc_datetime(&target_day.and_hms_opt(8, 0, 0).unwrap());
    let evening = Utc.from_utc_datetime(&target_day.and_hms_opt(20, 0, 0).unwrap());

    insert_usage_event(&pool, customer_id, "storage_bytes", 100, morning).await;
    insert_usage_event(&pool, customer_id, "storage_bytes", 101, evening).await;
    insert_usage_event(&pool, customer_id, "document_count", 10, morning).await;
    insert_usage_event(&pool, customer_id, "document_count", 11, evening).await;

    run_rollup_for_day(&pool, target_day).await;

    let rows = get_daily_usage_via_repo(&pool, customer_id, target_day, target_day).await;
    assert_eq!(rows.len(), 1, "expected one usage_daily row");

    let row = &rows[0];
    assert_eq!(row.search_requests, 0);
    assert_eq!(row.write_operations, 0);
    assert_eq!(row.storage_bytes_avg, 101, "100.5 rounds to 101");
    assert_eq!(row.documents_count_avg, 11, "10.5 rounds to 11");

    pool.close().await;
});

integration_test!(rollup_excludes_rows_on_next_day_boundary, async {
    require_live!(
        integration_helpers::db_url_available().await,
        "Database unreachable"
    );

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    let customer_id = seed_verified_user_directly(&pool, &unique_email("rollup-boundary")).await;

    let day_one = NaiveDate::from_ymd_opt(2026, 2, 19).unwrap();
    let day_two = NaiveDate::from_ymd_opt(2026, 2, 20).unwrap();

    let day_one_start = Utc.from_utc_datetime(&day_one.and_hms_opt(0, 0, 0).unwrap());
    let day_one_end_minus_1s = Utc.from_utc_datetime(&day_one.and_hms_opt(23, 59, 59).unwrap());
    let day_two_start = Utc.from_utc_datetime(&day_two.and_hms_opt(0, 0, 0).unwrap());

    insert_usage_event(&pool, customer_id, "search_requests", 100, day_one_start).await;
    insert_usage_event(
        &pool,
        customer_id,
        "search_requests",
        200,
        day_one_end_minus_1s,
    )
    .await;
    insert_usage_event(&pool, customer_id, "search_requests", 400, day_two_start).await;

    run_rollup_for_day(&pool, day_one).await;
    run_rollup_for_day(&pool, day_two).await;

    let day_one_rows = get_daily_usage_via_repo(&pool, customer_id, day_one, day_one).await;
    let day_two_rows = get_daily_usage_via_repo(&pool, customer_id, day_two, day_two).await;

    assert_eq!(day_one_rows.len(), 1, "expected one day-one row");
    assert_eq!(day_two_rows.len(), 1, "expected one day-two row");

    assert_eq!(day_one_rows[0].search_requests, 300);
    assert_eq!(day_two_rows[0].search_requests, 400);

    pool.close().await;
});

integration_test!(billing_smoke_uses_pg_usage_repo_read_path, async {
    require_live!(
        integration_helpers::db_url_available().await,
        "Database unreachable"
    );

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    let customer_id = seed_verified_user_directly(&pool, &unique_email("billing-smoke")).await;

    let period_start = NaiveDate::from_ymd_opt(2026, 2, 21).unwrap();
    let period_end = NaiveDate::from_ymd_opt(2026, 2, 22).unwrap();

    let day_one_ts = Utc.from_utc_datetime(&period_start.and_hms_opt(12, 0, 0).unwrap());
    let day_two_ts = Utc.from_utc_datetime(&period_end.and_hms_opt(12, 0, 0).unwrap());

    insert_usage_event(&pool, customer_id, "search_requests", 10_000, day_one_ts).await;
    insert_usage_event(&pool, customer_id, "write_operations", 2_000, day_one_ts).await;
    insert_usage_event(
        &pool,
        customer_id,
        "storage_bytes",
        billing::types::BYTES_PER_GIB,
        day_one_ts,
    )
    .await;

    insert_usage_event(&pool, customer_id, "search_requests", 12_000, day_two_ts).await;
    insert_usage_event(&pool, customer_id, "write_operations", 3_000, day_two_ts).await;
    insert_usage_event(
        &pool,
        customer_id,
        "storage_bytes",
        billing::types::BYTES_PER_GIB * 2,
        day_two_ts,
    )
    .await;

    run_rollup_for_day(&pool, period_start).await;
    run_rollup_for_day(&pool, period_end).await;

    let usage_rows = get_daily_usage_via_repo(&pool, customer_id, period_start, period_end).await;
    assert_eq!(usage_rows.len(), 2, "expected two rolled-up daily rows");

    let total_search_requests: i64 = usage_rows.iter().map(|row| row.search_requests).sum();
    let total_write_operations: i64 = usage_rows.iter().map(|row| row.write_operations).sum();
    assert_eq!(total_search_requests, 22_000);
    assert_eq!(total_write_operations, 5_000);

    let billing_rate_card = test_rate_card()
        .to_billing_rate_card()
        .expect("test rate card should convert to billing rate card");

    let invoice = generate_invoice(
        &usage_rows,
        &billing_rate_card,
        customer_id,
        period_start,
        period_end,
        &StorageInputs::cold_only(Decimal::ZERO),
        BillingPlan::Free,
    );

    assert!(
        invoice
            .line_items
            .iter()
            .any(|line| line.unit == "requests_1k"),
        "invoice should include requests_1k line item"
    );
    assert!(
        invoice
            .line_items
            .iter()
            .any(|line| line.unit == "write_ops_1k"),
        "invoice should include write_ops_1k line item"
    );
    assert!(
        invoice
            .line_items
            .iter()
            .any(|line| line.unit == "gb_months"),
        "invoice should include gb_months line item"
    );
    assert!(!invoice.minimum_applied);
    assert!(invoice.total_cents > 0);

    pool.close().await;
});

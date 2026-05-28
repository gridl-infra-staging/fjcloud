// Integration tests for the metering and aggregation pipeline.
//
// Scope: this file is intentionally limited to real Postgres-backed pipeline
// semantics and one live metering capture probe.

use crate::common::integration_helpers::{db_url, endpoint_reachable, seed_verified_user_directly};
use aggregation_job::rollup::{day_window, ROLLUP_SQL};
use api::invoicing::{generate_invoice, StorageInputs};
use api::models::customer::BillingPlan;
use api::models::{RateCardRow, UsageDaily};
use api::repos::{PgUsageRepo, UsageRepo};
use chrono::{NaiveDate, TimeZone, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use uuid::Uuid;

fn unique_email(prefix: &str) -> String {
    let id = Uuid::new_v4().to_string();
    format!("{prefix}-{}@integration-test.local", &id[..8])
}

fn flapjack_batch_url(base: &str, index_name: &str) -> String {
    format!("{base}/1/indexes/{index_name}/batch")
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

fn flapjack_uid_for_customer_index(customer_id: Uuid, index_name: &str) -> String {
    format!("{}_{}", customer_id.as_simple(), index_name)
}

async fn create_index_and_metering_key(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    index_name: &str,
) -> String {
    let create_resp = client
        .post(format!("{base}/indexes"))
        .bearer_auth(token)
        .json(&metering_create_index_payload(index_name))
        .send()
        .await
        .expect("create index request failed");
    assert!(
        create_resp.status().is_success(),
        "create index failed for {index_name}: {}",
        create_resp.text().await.unwrap_or_default()
    );

    let keys_resp = client
        .post(format!("{base}/indexes/{index_name}/keys"))
        .bearer_auth(token)
        .json(&metering_key_request_payload())
        .send()
        .await
        .expect("create key request failed");
    assert!(
        keys_resp.status().is_success(),
        "create key failed for {index_name}: {}",
        keys_resp.text().await.unwrap_or_default()
    );

    let keys_body: serde_json::Value = keys_resp.json().await.expect("keys response not JSON");
    keys_body["key"]
        .as_str()
        .expect("key field missing")
        .to_string()
}

async fn run_metered_write_and_query_load(
    client: &reqwest::Client,
    flapjack: &str,
    index_name: &str,
    search_key: &str,
    write_count: i64,
    search_count: i64,
    load_label: &str,
) {
    for i in 0..write_count {
        let doc_resp = client
            .post(flapjack_batch_url(flapjack, index_name))
            .header("X-Algolia-API-Key", search_key)
            .header("X-Algolia-Application-Id", "flapjack")
            .json(&serde_json::json!({
                "requests": [{
                    "action": "addObject",
                    "body": { "objectID": format!("{load_label}-{i}"), "content": format!("{load_label} doc {i}") }
                }]
            }))
            .send()
            .await
            .expect("push doc request failed");
        assert!(
            doc_resp.status().is_success(),
            "push doc failed for {index_name} (i={i}): {}",
            doc_resp.text().await.unwrap_or_default()
        );
    }

    for _ in 0..search_count {
        let search_resp = client
            .post(flapjack_query_url(flapjack, index_name))
            .header("X-Algolia-API-Key", search_key)
            .header("X-Algolia-Application-Id", "flapjack")
            .json(&serde_json::json!({ "query": load_label, "hitsPerPage": 10 }))
            .send()
            .await
            .expect("search request failed");
        assert!(
            search_resp.status().is_success(),
            "search failed for {index_name}: {}",
            search_resp.text().await.unwrap_or_default()
        );
    }
}

async fn seed_verified_user_and_login(
    client: &reqwest::Client,
    base: &str,
    email: &str,
) -> (Uuid, String) {
    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");
    let customer_id = seed_verified_user_directly(&pool, email).await;

    let login_resp = client
        .post(format!("{base}/auth/login"))
        .json(&serde_json::json!({
            "email": email,
            "password": "Integration-Test-Pass-1!"
        }))
        .send()
        .await
        .expect("login request failed");
    assert!(
        login_resp.status().is_success(),
        "login failed for {email}: {}",
        login_resp.text().await.unwrap_or_default()
    );

    let body: serde_json::Value = login_resp.json().await.expect("login response not JSON");
    let token = body["token"]
        .as_str()
        .expect("login response missing token")
        .to_string();

    pool.close().await;
    (customer_id, token)
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
        "SELECT COALESCE(SUM(value), 0)::BIGINT FROM usage_records \
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
        "SELECT COALESCE(SUM(value), 0)::BIGINT FROM usage_records \
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

crate::integration_test!(metering_agent_captures_real_flapjack_usage, async {
    use crate::common::integration_helpers::{api_base, flapjack_base, http_client};

    let client = http_client();
    let base = api_base();
    let flapjack = flapjack_base();

    crate::require_live!(
        endpoint_reachable(&base).await,
        "API endpoint unreachable for metering capture test"
    );
    crate::require_live!(
        endpoint_reachable(&flapjack).await,
        "flapjack endpoint unreachable for metering capture test"
    );

    let email = unique_email("metering-capture");
    let (customer_id, token) = seed_verified_user_and_login(&client, &base, &email).await;

    let index_name = format!("metering-{}", &Uuid::new_v4().to_string()[..8]);
    let search_key = create_index_and_metering_key(&client, &base, &token, &index_name).await;
    let flapjack_uid = flapjack_uid_for_customer_index(customer_id, &index_name);

    let test_started_at = chrono::Utc::now();

    run_metered_write_and_query_load(
        &client,
        &flapjack,
        &flapjack_uid,
        &search_key,
        10,
        5,
        "metering",
    )
    .await;

    tokio::time::sleep(std::time::Duration::from_secs(3)).await;

    let pool = sqlx::PgPool::connect(&db_url())
        .await
        .expect("failed to connect to integration DB");

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

crate::integration_test!(
    metering_agent_attributes_usage_to_correct_customer_across_two_tenants,
    async {
        use crate::common::integration_helpers::{api_base, flapjack_base, http_client};

        let client = http_client();
        let base = api_base();
        let flapjack = flapjack_base();

        crate::require_live!(
            endpoint_reachable(&base).await,
            "API endpoint unreachable for two-tenant metering attribution test"
        );
        crate::require_live!(
            endpoint_reachable(&flapjack).await,
            "flapjack endpoint unreachable for two-tenant metering attribution test"
        );

        let customer_a_email = unique_email("metering-tenant-a");
        let customer_b_email = unique_email("metering-tenant-b");
        let (customer_a_id, customer_a_token) =
            seed_verified_user_and_login(&client, &base, &customer_a_email).await;
        let (customer_b_id, customer_b_token) =
            seed_verified_user_and_login(&client, &base, &customer_b_email).await;

        let customer_a_index = format!("tenant-a-{}", &Uuid::new_v4().to_string()[..8]);
        let customer_b_index = format!("tenant-b-{}", &Uuid::new_v4().to_string()[..8]);
        let customer_a_flapjack_uid =
            flapjack_uid_for_customer_index(customer_a_id, &customer_a_index);
        let customer_b_flapjack_uid =
            flapjack_uid_for_customer_index(customer_b_id, &customer_b_index);

        let customer_a_key =
            create_index_and_metering_key(&client, &base, &customer_a_token, &customer_a_index)
                .await;
        let customer_b_key =
            create_index_and_metering_key(&client, &base, &customer_b_token, &customer_b_index)
                .await;

        let test_started_at = chrono::Utc::now();

        tokio::join!(
            run_metered_write_and_query_load(
                &client,
                &flapjack,
                &customer_a_flapjack_uid,
                &customer_a_key,
                6,
                3,
                "tenant-a",
            ),
            run_metered_write_and_query_load(
                &client,
                &flapjack,
                &customer_b_flapjack_uid,
                &customer_b_key,
                4,
                2,
                "tenant-b",
            )
        );

        let pool = sqlx::PgPool::connect(&db_url())
            .await
            .expect("failed to connect to integration DB");

        let (customer_a_search, customer_a_write) = wait_for_usage_totals(
            &pool,
            customer_a_id,
            &customer_a_index,
            test_started_at,
            3,
            6,
        )
        .await;
        let (customer_b_search, customer_b_write) = wait_for_usage_totals(
            &pool,
            customer_b_id,
            &customer_b_index,
            test_started_at,
            2,
            4,
        )
        .await;

        assert!(
        customer_a_search >= 3 && customer_a_write >= 6,
        "expected tenant A usage to be attributed to customer A, got search={customer_a_search} write={customer_a_write}"
    );
        assert!(
        customer_b_search >= 2 && customer_b_write >= 4,
        "expected tenant B usage to be attributed to customer B, got search={customer_b_search} write={customer_b_write}"
    );

        let (swapped_a_search, swapped_a_write) =
            usage_totals_for_index_since(&pool, customer_b_id, &customer_a_index, test_started_at)
                .await;
        let (swapped_b_search, swapped_b_write) =
            usage_totals_for_index_since(&pool, customer_a_id, &customer_b_index, test_started_at)
                .await;

        assert_eq!(
            swapped_a_search, 0,
            "customer B must not receive tenant A search_requests"
        );
        assert_eq!(
            swapped_a_write, 0,
            "customer B must not receive tenant A write_operations"
        );
        assert_eq!(
            swapped_b_search, 0,
            "customer A must not receive tenant B search_requests"
        );
        assert_eq!(
            swapped_b_write, 0,
            "customer A must not receive tenant B write_operations"
        );

        pool.close().await;
    }
);

crate::integration_test!(rollup_rerun_overwrites_row_after_same_day_mutation, async {
    crate::require_live!(
        crate::common::integration_helpers::db_url_available().await,
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

crate::integration_test!(rollup_averages_and_rounds_same_day_gauge_snapshots, async {
    crate::require_live!(
        crate::common::integration_helpers::db_url_available().await,
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

crate::integration_test!(rollup_excludes_rows_on_next_day_boundary, async {
    crate::require_live!(
        crate::common::integration_helpers::db_url_available().await,
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

crate::integration_test!(billing_smoke_uses_pg_usage_repo_read_path, async {
    crate::require_live!(
        crate::common::integration_helpers::db_url_available().await,
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

    // Under the current pricing model, search and write operations are free
    // (see billing::pricing::calculate_invoice — "Searches and writes are free
    // (unlimited)", guarded by no_search_request_line_item_in_new_pricing), so
    // the invoice bills storage only. The rolled-up storage_bytes usage must
    // therefore surface as a hot-storage "mb_months" line item, and there must
    // be NO per-request ("requests_1k"/"write_ops_1k") line items.
    assert!(
        invoice
            .line_items
            .iter()
            .any(|line| line.unit == "mb_months"),
        "invoice should include a hot-storage mb_months line item; got units: {:?}",
        invoice
            .line_items
            .iter()
            .map(|line| line.unit.as_str())
            .collect::<Vec<_>>()
    );
    assert!(
        !invoice
            .line_items
            .iter()
            .any(|line| line.unit == "requests_1k" || line.unit == "write_ops_1k"),
        "search/write are free in the current pricing model; no per-request line items expected"
    );
    assert!(!invoice.minimum_applied);
    assert!(invoice.total_cents > 0);

    pool.close().await;
});

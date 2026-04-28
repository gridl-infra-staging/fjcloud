//! Live Stripe test-clock lifecycle integration test owner.
//!
//! Stage 2 scope: prove subscription lifecycle ordering (create -> trial ->
//! renewal -> immediate cancel) using real Stripe test clocks and webhook
//! reconciliation into the local subscription row.

mod common;
#[path = "common/integration_helpers.rs"]
mod integration_helpers;
#[path = "common/live_stripe_helpers.rs"]
mod live_stripe_helpers;

use api::stripe::StripeService;
use chrono::{NaiveDate, Utc};
use live_stripe_helpers::{
    attach_declining_payment_method, attach_test_payment_method, build_live_stripe_handles,
    delete_stripe_customer, stripe_webhook_available, validate_stripe_key_live,
};
use reqwest::{Client, StatusCode};
use rust_decimal::Decimal;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use sqlx::PgPool;
use std::collections::HashMap;
use std::time::Duration;
use uuid::Uuid;

const POLL_TIMEOUT: Duration = Duration::from_secs(90);
const POLL_INTERVAL: Duration = Duration::from_millis(500);

macro_rules! require_live_locked {
    ($condition:expr, $reason:expr) => {{
        let _env_guard = integration_helpers::test_env_lock();
        require_live!($condition, $reason);
    }};
}

fn stripe_starter_price_id() -> Option<String> {
    let price = std::env::var("STRIPE_PRICE_STARTER").ok()?;
    if price.trim().is_empty() {
        None
    } else {
        Some(price)
    }
}

// ---------------------------------------------------------------------------
// Stripe test-clock helpers (local to this test owner)
// ---------------------------------------------------------------------------

async fn create_test_clock(
    client: &stripe::Client,
    clock_name: &str,
    frozen_time: i64,
) -> stripe::TestHelpersTestClock {
    let mut params = stripe::CreateTestClock::new();
    params.name = clock_name;
    params.frozen_time = frozen_time;

    stripe::TestHelpersTestClock::create(client, &params)
        .await
        .expect("failed to create Stripe test clock")
}

async fn wait_for_test_clock_ready(
    client: &stripe::Client,
    clock_id: &stripe::TestHelpersTestClockId,
    predicate_name: &'static str,
) -> stripe::TestHelpersTestClock {
    common::poll::poll_until(
        predicate_name,
        Duration::from_secs(45),
        Duration::from_millis(400),
        || {
            let client = client.clone();
            let clock_id = clock_id.clone();
            async move {
                let clock = stripe::TestHelpersTestClock::retrieve(&client, &clock_id)
                    .await
                    .ok()?;
                matches!(
                    clock.status,
                    Some(stripe::TestHelpersTestClockStatus::Ready)
                )
                .then_some(clock)
            }
        },
    )
    .await
}

async fn advance_test_clock(
    client: &stripe::Client,
    clock_id: &stripe::TestHelpersTestClockId,
    frozen_time: i64,
    ready_predicate_name: &'static str,
) -> stripe::TestHelpersTestClock {
    let params = stripe::AdvanceTestClock { frozen_time };

    stripe::TestHelpersTestClock::advance(client, clock_id, &params)
        .await
        .expect("failed to advance Stripe test clock");

    wait_for_test_clock_ready(client, clock_id, ready_predicate_name).await
}

async fn delete_test_clock(client: &stripe::Client, clock_id: &stripe::TestHelpersTestClockId) {
    if let Err(err) = stripe::TestHelpersTestClock::delete(client, clock_id).await {
        eprintln!("[cleanup] failed to delete Stripe test clock {clock_id}: {err}");
    }
}

async fn create_customer_with_test_clock(
    client: &stripe::Client,
    email: &str,
    clock_id: &stripe::TestHelpersTestClockId,
) -> String {
    let mut params = stripe::CreateCustomer::new();
    params.email = Some(email);
    params.name = Some("Stripe Clock Lifecycle Test");
    params.test_clock = Some(clock_id.as_ref());

    let customer = stripe::Customer::create(client, params)
        .await
        .expect("failed to create Stripe customer on test clock");

    customer.id.to_string()
}

async fn create_trial_subscription(
    client: &stripe::Client,
    stripe_customer_id: &str,
    price_id: &str,
    trial_end_unix: i64,
) -> String {
    let customer_id: stripe::CustomerId = stripe_customer_id
        .parse()
        .expect("invalid Stripe customer ID");

    let mut params = stripe::CreateSubscription::new(customer_id);
    params.items = Some(vec![stripe::CreateSubscriptionItems {
        price: Some(price_id.to_string()),
        quantity: Some(1),
        ..Default::default()
    }]);
    params.trial_end = Some(stripe::Scheduled::at(trial_end_unix));

    let subscription = stripe::Subscription::create(client, params)
        .await
        .expect("failed to create Stripe trial subscription");

    subscription.id.to_string()
}

async fn set_subscription_default_payment_method(
    client: &stripe::Client,
    stripe_subscription_id: &str,
    payment_method_id: &str,
) {
    let subscription_id: stripe::SubscriptionId = stripe_subscription_id
        .parse()
        .expect("invalid Stripe subscription ID");
    let mut params = stripe::UpdateSubscription::new();
    params.default_payment_method = Some(payment_method_id);

    stripe::Subscription::update(client, &subscription_id, params)
        .await
        .expect("failed setting default payment method on Stripe subscription");
}

// ---------------------------------------------------------------------------
// Request builders
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct SubscriptionRouteResponse {
    id: String,
    plan_tier: String,
    status: String,
    current_period_end: String,
    cancel_at_period_end: bool,
}

async fn get_subscription_route(
    client: &Client,
    base: &str,
    jwt: &str,
) -> Option<SubscriptionRouteResponse> {
    let response = client
        .get(format!("{base}/billing/subscription"))
        .bearer_auth(jwt)
        .send()
        .await
        .expect("GET /billing/subscription request failed");

    let status = response.status();
    let body_text = response
        .text()
        .await
        .expect("GET /billing/subscription body read failed");

    if status == StatusCode::NOT_FOUND {
        return None;
    }

    assert_eq!(
        status,
        StatusCode::OK,
        "GET /billing/subscription returned unexpected status: {body_text}"
    );

    Some(
        serde_json::from_str(&body_text)
            .expect("GET /billing/subscription response must decode as JSON"),
    )
}

async fn cancel_subscription_now(
    client: &Client,
    base: &str,
    jwt: &str,
) -> SubscriptionRouteResponse {
    let response = client
        .post(format!("{base}/billing/subscription/cancel"))
        .bearer_auth(jwt)
        .json(&serde_json::json!({
            "cancel_at_period_end": false
        }))
        .send()
        .await
        .expect("POST /billing/subscription/cancel request failed");

    let status = response.status();
    let body_text = response
        .text()
        .await
        .expect("POST /billing/subscription/cancel body read failed");

    assert_eq!(
        status,
        StatusCode::OK,
        "POST /billing/subscription/cancel returned unexpected status: {body_text}"
    );

    serde_json::from_str(&body_text)
        .expect("POST /billing/subscription/cancel response must decode as JSON")
}

#[derive(Debug, Deserialize)]
struct AdminTenantResponse {
    id: Uuid,
    billing_plan: String,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq)]
struct AdminInvoiceLineItemResponse {
    description: String,
    quantity: String,
    unit: String,
    unit_price_cents: String,
    amount_cents: i64,
    region: String,
}

#[derive(Debug, Deserialize, Clone)]
struct AdminInvoiceResponse {
    id: Uuid,
    status: String,
    subtotal_cents: i64,
    total_cents: i64,
    minimum_applied: bool,
    line_items: Vec<AdminInvoiceLineItemResponse>,
}

#[derive(Debug, Clone)]
struct ExpectedInvoiceTotals {
    subtotal_cents: i64,
    total_cents: i64,
    minimum_applied: bool,
    line_item_signatures: Vec<(String, String, String, String, i64, String)>,
}

#[derive(Debug, Clone, Copy)]
struct UsageDailySeedRow {
    date: NaiveDate,
    region: &'static str,
    search_requests: i64,
    write_operations: i64,
    storage_bytes_avg: i64,
    documents_count_avg: i64,
}

async fn decode_response_json<T: DeserializeOwned>(
    response: reqwest::Response,
    expected_status: StatusCode,
    request_label: &str,
) -> T {
    let status = response.status();
    let body_text = response
        .text()
        .await
        .expect("admin request body read should succeed");
    assert_eq!(
        status, expected_status,
        "{request_label} returned unexpected status: {body_text}"
    );
    serde_json::from_str(&body_text).expect("admin response must decode as JSON")
}

async fn put_admin_tenant_billing_plan(
    client: &Client,
    base: &str,
    tenant_id: Uuid,
    billing_plan: &str,
) -> AdminTenantResponse {
    let response = client
        .put(format!("{base}/admin/tenants/{tenant_id}"))
        .header("x-admin-key", integration_helpers::admin_key())
        .json(&serde_json::json!({ "billing_plan": billing_plan }))
        .send()
        .await
        .expect("PUT /admin/tenants/{id} request failed");

    decode_response_json(response, StatusCode::OK, "PUT /admin/tenants/{id}").await
}

async fn post_admin_generate_invoice(
    client: &Client,
    base: &str,
    tenant_id: Uuid,
    month: &str,
) -> AdminInvoiceResponse {
    let response = client
        .post(format!("{base}/admin/tenants/{tenant_id}/invoices"))
        .header("x-admin-key", integration_helpers::admin_key())
        .json(&serde_json::json!({ "month": month }))
        .send()
        .await
        .expect("POST /admin/tenants/{id}/invoices request failed");

    decode_response_json(
        response,
        StatusCode::CREATED,
        "POST /admin/tenants/{id}/invoices",
    )
    .await
}

async fn post_admin_finalize_invoice(
    client: &Client,
    base: &str,
    invoice_id: Uuid,
) -> AdminInvoiceResponse {
    let response = client
        .post(format!("{base}/admin/invoices/{invoice_id}/finalize"))
        .header("x-admin-key", integration_helpers::admin_key())
        .send()
        .await
        .expect("POST /admin/invoices/{id}/finalize request failed");

    decode_response_json(
        response,
        StatusCode::OK,
        "POST /admin/invoices/{id}/finalize",
    )
    .await
}

fn seeded_usage_rows_for_month(
    period_start: NaiveDate,
    period_end: NaiveDate,
    region: &'static str,
) -> Vec<UsageDailySeedRow> {
    let storage_bytes_avg = billing::types::BYTES_PER_MB * 200;
    let mut current_day = period_start;
    let mut rows = Vec::new();

    loop {
        rows.push(UsageDailySeedRow {
            date: current_day,
            region,
            search_requests: 12_000,
            write_operations: 2_500,
            storage_bytes_avg,
            documents_count_avg: 20_000,
        });
        if current_day == period_end {
            break;
        }
        current_day = current_day
            .succ_opt()
            .expect("period end should be reachable from period start");
    }

    rows
}

async fn reseed_usage_daily_rows_for_month(
    pool: &PgPool,
    customer_id: Uuid,
    seeded_rows: &[UsageDailySeedRow],
) {
    assert!(
        !seeded_rows.is_empty(),
        "seeded usage rows must include at least one day"
    );

    let period_start = seeded_rows
        .iter()
        .map(|row| row.date)
        .min()
        .expect("seeded rows should not be empty");
    let period_end = seeded_rows
        .iter()
        .map(|row| row.date)
        .max()
        .expect("seeded rows should not be empty");

    sqlx::query(
        "DELETE FROM usage_daily \
         WHERE customer_id = $1 AND date >= $2 AND date <= $3",
    )
    .bind(customer_id)
    .bind(period_start)
    .bind(period_end)
    .execute(pool)
    .await
    .expect("failed deleting existing usage_daily rows for deterministic month");

    for row in seeded_rows {
        sqlx::query(
            "INSERT INTO usage_daily \
             (customer_id, date, region, search_requests, write_operations, storage_bytes_avg, documents_count_avg) \
             VALUES ($1, $2, $3, $4, $5, $6, $7) \
             ON CONFLICT (customer_id, date, region) DO UPDATE SET \
                 search_requests = EXCLUDED.search_requests, \
                 write_operations = EXCLUDED.write_operations, \
                 storage_bytes_avg = EXCLUDED.storage_bytes_avg, \
                 documents_count_avg = EXCLUDED.documents_count_avg, \
                 aggregated_at = NOW()",
        )
        .bind(customer_id)
        .bind(row.date)
        .bind(row.region)
        .bind(row.search_requests)
        .bind(row.write_operations)
        .bind(row.storage_bytes_avg)
        .bind(row.documents_count_avg)
        .execute(pool)
        .await
        .expect("failed inserting deterministic usage_daily row");
    }
}

async fn expected_shared_plan_invoice_for_seeded_usage(
    customer_id: Uuid,
    seeded_rows: &[UsageDailySeedRow],
    pool: &PgPool,
) -> ExpectedInvoiceTotals {
    assert!(
        !seeded_rows.is_empty(),
        "seeded usage rows must include at least one day"
    );
    let period_start = seeded_rows
        .iter()
        .map(|row| row.date)
        .min()
        .expect("seeded rows should not be empty");
    let period_end = seeded_rows
        .iter()
        .map(|row| row.date)
        .max()
        .expect("seeded rows should not be empty");

    let base_rate_card = sqlx::query_as::<_, api::models::RateCardRow>(
        "SELECT * FROM rate_cards WHERE effective_until IS NULL ORDER BY effective_from DESC LIMIT 1",
    )
    .fetch_one(pool)
    .await
    .expect("active rate card should exist");

    let override_json = sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT overrides FROM customer_rate_overrides WHERE customer_id = $1 AND rate_card_id = $2",
    )
    .bind(customer_id)
    .bind(base_rate_card.id)
    .fetch_optional(pool)
    .await
    .expect("failed loading customer rate override");

    let effective_rate_card_row = match override_json {
        Some(overrides) => base_rate_card
            .with_overrides(&overrides)
            .expect("customer override must deserialize into a valid effective rate card"),
        None => base_rate_card,
    };

    let effective_rate_card = effective_rate_card_row
        .to_billing_rate_card()
        .expect("effective rate card should convert to billing::rate_card::RateCard");

    let usage_records: Vec<billing::types::DailyUsageRecord> = seeded_rows
        .iter()
        .map(|row| billing::types::DailyUsageRecord {
            customer_id,
            date: row.date,
            region: row.region.to_string(),
            search_requests: row.search_requests,
            write_operations: row.write_operations,
            storage_bytes_avg: row.storage_bytes_avg,
            documents_count_avg: row.documents_count_avg,
        })
        .collect();
    let billing_context: HashMap<Uuid, billing::aggregation::CustomerBillingContext> =
        HashMap::new();

    let usage_summaries =
        billing::aggregation::summarize(&usage_records, period_start, period_end, &billing_context);
    assert_eq!(
        usage_summaries.len(),
        1,
        "seeded invoice month should aggregate to exactly one (customer, region) usage summary"
    );

    let pricing_result = billing::pricing::calculate_invoice(
        usage_summaries
            .first()
            .expect("seeded month summary should be present"),
        &effective_rate_card,
    );
    let mut line_item_signatures = pricing_result
        .line_items
        .iter()
        .map(|line_item| {
            (
                line_item.description.clone(),
                line_item.quantity.to_string(),
                line_item.unit.clone(),
                line_item.unit_price_cents.to_string(),
                line_item.amount_cents,
                line_item.region.clone(),
            )
        })
        .collect::<Vec<_>>();
    line_item_signatures.sort();

    let usage_rows = seeded_rows
        .iter()
        .map(|row| api::models::UsageDaily {
            customer_id,
            date: row.date,
            region: row.region.to_string(),
            search_requests: row.search_requests,
            write_operations: row.write_operations,
            storage_bytes_avg: row.storage_bytes_avg,
            documents_count_avg: row.documents_count_avg,
            aggregated_at: Utc::now(),
        })
        .collect::<Vec<_>>();

    let generated_invoice = api::invoicing::generate_invoice(
        &usage_rows,
        &effective_rate_card,
        customer_id,
        period_start,
        period_end,
        &api::invoicing::StorageInputs::default(),
        api::models::customer::BillingPlan::Shared,
    );
    assert_eq!(
        generated_invoice.subtotal_cents, pricing_result.subtotal_cents,
        "app-owned invoice generation should preserve billing::pricing subtotal"
    );

    ExpectedInvoiceTotals {
        subtotal_cents: generated_invoice.subtotal_cents,
        total_cents: generated_invoice.total_cents,
        minimum_applied: generated_invoice.minimum_applied,
        line_item_signatures,
    }
}

fn assert_invoice_totals_match_expected(
    invoice: &AdminInvoiceResponse,
    expected_subtotal_cents: i64,
    expected_total_cents: i64,
    expected_minimum_applied: bool,
) {
    assert_eq!(
        invoice.subtotal_cents, expected_subtotal_cents,
        "invoice subtotal_cents should match the app-owned pricing output"
    );
    assert_eq!(
        invoice.total_cents, expected_total_cents,
        "invoice total_cents should match the shared-plan minimum contract"
    );
    assert_eq!(
        invoice.minimum_applied, expected_minimum_applied,
        "invoice minimum_applied should match shared minimum behavior"
    );
}

fn assert_no_search_or_write_invoice_lines(line_items: &[AdminInvoiceLineItemResponse]) {
    for line_item in line_items {
        assert_ne!(
            line_item.unit, "requests_1k",
            "search requests are free and must not produce a billed line item"
        );
        assert_ne!(
            line_item.unit, "write_ops_1k",
            "write operations are free and must not produce a billed line item"
        );

        let description = line_item.description.to_ascii_lowercase();
        let mentions_search_or_write =
            description.contains("search") || description.contains("write");
        assert!(
            !mentions_search_or_write,
            "search/write line items (including compensating negatives) are out of contract: {:?}",
            line_item
        );
    }
}

fn invoice_line_item_signatures(
    line_items: &[AdminInvoiceLineItemResponse],
) -> Vec<(String, String, String, String, i64, String)> {
    let mut signatures = line_items
        .iter()
        .map(|line_item| {
            (
                line_item.description.clone(),
                normalize_decimal_string(&line_item.quantity),
                line_item.unit.clone(),
                normalize_decimal_string(&line_item.unit_price_cents),
                line_item.amount_cents,
                line_item.region.clone(),
            )
        })
        .collect::<Vec<_>>();
    signatures.sort();
    signatures
}

fn normalize_decimal_string(raw: &str) -> String {
    raw.parse::<Decimal>()
        .expect("decimal line-item fields should parse")
        .normalize()
        .to_string()
}

fn is_expected_invoice_payment_failure_message(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("card_declined")
        || lower.contains("payment_failed")
        || lower.contains("your card was declined")
        || lower.contains("insufficient_funds")
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RefundLookupTarget {
    Charge(String),
    PaymentIntent(String),
}

fn choose_refund_lookup_target(
    charge_id: Option<String>,
    payment_intent_id: Option<String>,
) -> Option<RefundLookupTarget> {
    if let Some(charge_id) = charge_id {
        return Some(RefundLookupTarget::Charge(charge_id));
    }

    payment_intent_id.map(RefundLookupTarget::PaymentIntent)
}

fn assert_invoice_line_items_match_expected(
    line_items: &[AdminInvoiceLineItemResponse],
    expected_signatures: &[(String, String, String, String, i64, String)],
) {
    let actual = invoice_line_item_signatures(line_items);
    let mut expected = expected_signatures
        .iter()
        .map(
            |(description, quantity, unit, unit_price_cents, amount_cents, region)| {
                (
                    description.clone(),
                    normalize_decimal_string(quantity),
                    unit.clone(),
                    normalize_decimal_string(unit_price_cents),
                    *amount_cents,
                    region.clone(),
                )
            },
        )
        .collect::<Vec<_>>();
    expected.sort();

    assert_eq!(
        actual, expected,
        "draft invoice line items should match deterministic app-owned pricing payload"
    );
}

// ---------------------------------------------------------------------------
// State reads
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct LocalSubscriptionState {
    stripe_subscription_id: String,
    stripe_price_id: String,
    plan_tier: String,
    status: String,
    current_period_start: NaiveDate,
    current_period_end: NaiveDate,
    cancel_at_period_end: bool,
}

const LOCAL_SUBSCRIPTION_SELECT_QUERY: &str =
    "SELECT stripe_subscription_id, stripe_price_id, plan_tier, status, \
            current_period_start, current_period_end, cancel_at_period_end \
     FROM public.subscriptions \
     WHERE customer_id = $1";

#[derive(Debug, Clone)]
struct LocalInvoiceState {
    status: String,
    subtotal_cents: i64,
    total_cents: i64,
    minimum_applied: bool,
    stripe_invoice_id: Option<String>,
}

struct StripeInvoiceSnapshot {
    subtotal_cents: i64,
    total_cents: i64,
    amount_paid_cents: i64,
    paid: bool,
}

async fn fetch_customer_id_for_email(pool: &PgPool, email: &str) -> Uuid {
    sqlx::query_scalar("SELECT id FROM customers WHERE email = $1")
        .bind(email)
        .fetch_one(pool)
        .await
        .expect("customer not found for registered email")
}

async fn bind_customer_to_stripe_customer(
    pool: &PgPool,
    customer_id: Uuid,
    stripe_customer_id: &str,
) {
    sqlx::query("UPDATE customers SET stripe_customer_id = $1 WHERE id = $2")
        .bind(stripe_customer_id)
        .bind(customer_id)
        .execute(pool)
        .await
        .expect("failed to bind fjcloud customer to Stripe customer");
}

async fn fetch_local_invoice_state_any_status(
    pool: &PgPool,
    invoice_id: Uuid,
) -> Option<LocalInvoiceState> {
    let row = sqlx::query_as::<_, (String, i64, i64, bool, Option<String>)>(
        "SELECT status, subtotal_cents, total_cents, minimum_applied, stripe_invoice_id \
         FROM invoices \
         WHERE id = $1",
    )
    .bind(invoice_id)
    .fetch_optional(pool)
    .await
    .expect("failed querying invoices row");

    row.map(
        |(status, subtotal_cents, total_cents, minimum_applied, stripe_invoice_id)| {
            LocalInvoiceState {
                status,
                subtotal_cents,
                total_cents,
                minimum_applied,
                stripe_invoice_id,
            }
        },
    )
}

async fn fetch_local_invoice_state(pool: &PgPool, invoice_id: Uuid) -> Option<LocalInvoiceState> {
    fetch_local_invoice_state_any_status(pool, invoice_id)
        .await
        .filter(|state| state.status == "finalized")
}

async fn fetch_local_customer_status(pool: &PgPool, customer_id: Uuid) -> Option<String> {
    sqlx::query_scalar::<_, String>("SELECT status FROM customers WHERE id = $1")
        .bind(customer_id)
        .fetch_optional(pool)
        .await
        .expect("failed querying customers status")
}

async fn fetch_payment_failed_event_with_next_attempt(
    pool: &PgPool,
    stripe_invoice_id: &str,
) -> bool {
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM webhook_events \
         WHERE event_type = 'invoice.payment_failed' \
         AND payload->'data'->'object'->>'id' = $1 \
         AND payload->'data'->'object'->>'next_payment_attempt' IS NOT NULL",
    )
    .bind(stripe_invoice_id)
    .fetch_one(pool)
    .await
    .expect("failed querying webhook_events for invoice.payment_failed");

    count > 0
}

async fn fetch_local_subscription(
    pool: &PgPool,
    customer_id: Uuid,
) -> Option<LocalSubscriptionState> {
    let row = sqlx::query_as::<_, (String, String, String, String, NaiveDate, NaiveDate, bool)>(
        LOCAL_SUBSCRIPTION_SELECT_QUERY,
    )
    .bind(customer_id)
    .fetch_optional(pool)
    .await
    .expect("failed querying subscriptions row");

    row.map(
        |(
            stripe_subscription_id,
            stripe_price_id,
            plan_tier,
            status,
            current_period_start,
            current_period_end,
            cancel_at_period_end,
        )| LocalSubscriptionState {
            stripe_subscription_id,
            stripe_price_id,
            plan_tier,
            status,
            current_period_start,
            current_period_end,
            cancel_at_period_end,
        },
    )
}

fn unix_to_date(unix_seconds: i64) -> NaiveDate {
    chrono::DateTime::from_timestamp(unix_seconds, 0)
        .expect("Stripe timestamp should be valid")
        .date_naive()
}

#[derive(Debug, Clone)]
struct StripeSubscriptionSnapshot {
    status: String,
    current_period_start: i64,
    current_period_end: i64,
    cancel_at_period_end: bool,
}

async fn fetch_stripe_subscription_snapshot(
    client: &stripe::Client,
    stripe_subscription_id: &str,
) -> Option<StripeSubscriptionSnapshot> {
    let subscription_id: stripe::SubscriptionId = stripe_subscription_id.parse().ok()?;
    let subscription = stripe::Subscription::retrieve(client, &subscription_id, &[])
        .await
        .ok()?;

    Some(StripeSubscriptionSnapshot {
        status: subscription.status.to_string(),
        current_period_start: subscription.current_period_start,
        current_period_end: subscription.current_period_end,
        cancel_at_period_end: subscription.cancel_at_period_end,
    })
}

// ---------------------------------------------------------------------------
// Lifecycle assertions
// ---------------------------------------------------------------------------

fn assert_local_and_route_core_fields(
    local: &LocalSubscriptionState,
    route: &SubscriptionRouteResponse,
    expected_subscription_id: &str,
    expected_plan_tier: &str,
    expected_status: &str,
    expected_cancel_at_period_end: bool,
    expected_price_id: &str,
) {
    assert_eq!(local.stripe_subscription_id, expected_subscription_id);
    assert_eq!(local.plan_tier, expected_plan_tier);
    assert_eq!(local.status, expected_status);
    assert_eq!(
        local.cancel_at_period_end, expected_cancel_at_period_end,
        "local cancel_at_period_end should match expected transition"
    );
    assert_eq!(
        local.stripe_price_id, expected_price_id,
        "local stripe_price_id should reconcile to the expected plan"
    );

    assert_eq!(route.id, expected_subscription_id);
    assert_eq!(route.plan_tier, expected_plan_tier);
    assert_eq!(route.status, expected_status);
    assert_eq!(route.cancel_at_period_end, expected_cancel_at_period_end);
    assert_eq!(
        route.current_period_end,
        local.current_period_end.to_string(),
        "route current_period_end should match persisted subscription row"
    );
}

fn assert_subscription_initial_period_window(
    local: &LocalSubscriptionState,
    route: &SubscriptionRouteResponse,
    expected_period_start: NaiveDate,
    expected_period_end: NaiveDate,
) {
    assert_eq!(
        local.current_period_start, expected_period_start,
        "current_period_start should match Stripe-managed period start"
    );
    assert_eq!(
        local.current_period_end, expected_period_end,
        "current_period_end should match Stripe-managed period end"
    );
    assert_eq!(
        route.current_period_end,
        expected_period_end.to_string(),
        "route current_period_end should mirror the persisted period window"
    );
}

fn is_exactly_one_period_rollover(
    _previous_period_start: NaiveDate,
    previous_period_end: NaiveDate,
    next_period_start: NaiveDate,
    next_period_end: NaiveDate,
) -> bool {
    next_period_start == previous_period_end && next_period_end > next_period_start
}

fn assert_exactly_one_period_rollover(
    previous_period_start: NaiveDate,
    previous_period_end: NaiveDate,
    next_period_start: NaiveDate,
    next_period_end: NaiveDate,
) {
    assert!(
        is_exactly_one_period_rollover(
            previous_period_start,
            previous_period_end,
            next_period_start,
            next_period_end,
        ),
        "exactly one period rollover is required for renewal boundary assertions"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn stripe_test_clock_full_cycle_live_subscription_lifecycle() {
    require_live_locked!(
        integration_helpers::integration_enabled(),
        "set INTEGRATION=1 to run stripe_test_clock_full_cycle_test"
    );
    require_live_locked!(
        validate_stripe_key_live().await.is_ok(),
        "STRIPE_SECRET_KEY missing or rejected by Stripe API"
    );
    require_live_locked!(
        stripe_starter_price_id().is_some(),
        "STRIPE_PRICE_STARTER must be set for test-clock lifecycle test"
    );
    require_live_locked!(
        integration_helpers::db_url_available().await,
        "integration DB is unreachable"
    );
    require_live_locked!(
        stripe_webhook_available().await,
        "stripe webhook forwarding unavailable; run stripe listen --forward-to localhost:3099/webhooks/stripe"
    );

    let starter_price_id = stripe_starter_price_id().expect("starter price id already gated");
    let client = integration_helpers::http_client();
    let base = integration_helpers::api_base();
    let db_url = integration_helpers::db_url();
    let pool = PgPool::connect(&db_url)
        .await
        .expect("failed connecting to integration DB");

    let email = format!("stripe-clock-full-cycle-{}@flapjack.foo", Uuid::new_v4());
    let jwt = integration_helpers::register_and_login(&client, &base, &email).await;
    let fj_customer_id = fetch_customer_id_for_email(&pool, &email).await;

    let stripe = build_live_stripe_handles();
    let clock_start = Utc::now().timestamp();
    let clock_name = format!("fjcloud-stage2-clock-{}", Uuid::new_v4());
    let test_clock = create_test_clock(&stripe.client, &clock_name, clock_start).await;
    let test_clock_id = test_clock.id.clone();

    let stripe_customer_id =
        create_customer_with_test_clock(&stripe.client, &email, &test_clock_id).await;
    bind_customer_to_stripe_customer(&pool, fj_customer_id, &stripe_customer_id).await;

    let payment_method_id = attach_test_payment_method(&stripe.client, &stripe_customer_id).await;
    stripe
        .service
        .set_default_payment_method(&stripe_customer_id, &payment_method_id)
        .await
        .expect("failed setting default payment method for Stripe test-clock customer");

    let trial_end_unix = clock_start + (3 * 24 * 60 * 60);
    let stripe_subscription_id = create_trial_subscription(
        &stripe.client,
        &stripe_customer_id,
        &starter_price_id,
        trial_end_unix,
    )
    .await;

    let created_state = common::poll::poll_until(
        "checkout_session_completed",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            let starter_price_id = starter_price_id.clone();
            let stripe_client = stripe.client.clone();
            async move {
                let local = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route = get_subscription_route(&client, &base, &jwt).await?;
                let stripe_subscription =
                    fetch_stripe_subscription_snapshot(&stripe_client, &stripe_subscription_id)
                        .await?;

                if local.stripe_subscription_id != stripe_subscription_id {
                    return None;
                }
                if local.status != "trialing"
                    || route.status != "trialing"
                    || stripe_subscription.status != "trialing"
                {
                    return None;
                }
                if local.plan_tier != "starter" || local.stripe_price_id != starter_price_id {
                    return None;
                }
                if route.plan_tier != "starter" {
                    return None;
                }
                if unix_to_date(stripe_subscription.current_period_start)
                    != local.current_period_start
                    || unix_to_date(stripe_subscription.current_period_end)
                        != local.current_period_end
                {
                    return None;
                }

                Some((local, route, stripe_subscription))
            }
        },
    )
    .await;

    assert_local_and_route_core_fields(
        &created_state.0,
        &created_state.1,
        &stripe_subscription_id,
        "starter",
        "trialing",
        false,
        &starter_price_id,
    );
    let initial_period_start = unix_to_date(created_state.2.current_period_start);
    let initial_period_end = unix_to_date(created_state.2.current_period_end);
    assert_subscription_initial_period_window(
        &created_state.0,
        &created_state.1,
        initial_period_start,
        initial_period_end,
    );

    let trial_warning_unix = trial_end_unix - (12 * 60 * 60);
    advance_test_clock(
        &stripe.client,
        &test_clock_id,
        trial_warning_unix,
        "trial_warning_clock_ready",
    )
    .await;

    let trial_warning_state = common::poll::poll_until(
        "trial_warning_checkpoint",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            let starter_price_id = starter_price_id.clone();
            let stripe_client = stripe.client.clone();
            async move {
                let local = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route = get_subscription_route(&client, &base, &jwt).await?;
                let stripe_subscription =
                    fetch_stripe_subscription_snapshot(&stripe_client, &stripe_subscription_id)
                        .await?;

                if local.status != "trialing"
                    || route.status != "trialing"
                    || stripe_subscription.status != "trialing"
                {
                    return None;
                }
                if local.plan_tier != "starter" || local.stripe_price_id != starter_price_id {
                    return None;
                }

                Some((local, route))
            }
        },
    )
    .await;

    assert_local_and_route_core_fields(
        &trial_warning_state.0,
        &trial_warning_state.1,
        &stripe_subscription_id,
        "starter",
        "trialing",
        false,
        &starter_price_id,
    );
    assert_subscription_initial_period_window(
        &trial_warning_state.0,
        &trial_warning_state.1,
        initial_period_start,
        initial_period_end,
    );

    let post_trial_activation_unix = trial_end_unix + (2 * 60 * 60);
    advance_test_clock(
        &stripe.client,
        &test_clock_id,
        post_trial_activation_unix,
        "post_trial_clock_ready",
    )
    .await;

    let activated_state =
        common::poll::poll_until("post_trial_activation", POLL_TIMEOUT, POLL_INTERVAL, || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            let starter_price_id = starter_price_id.clone();
            let stripe_client = stripe.client.clone();
            async move {
                let local = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route = get_subscription_route(&client, &base, &jwt).await?;
                let stripe_subscription =
                    fetch_stripe_subscription_snapshot(&stripe_client, &stripe_subscription_id)
                        .await?;

                if local.status != "active"
                    || route.status != "active"
                    || stripe_subscription.status != "active"
                {
                    return None;
                }
                if local.plan_tier != "starter" || local.stripe_price_id != starter_price_id {
                    return None;
                }

                Some((local, route, stripe_subscription))
            }
        })
        .await;

    assert_local_and_route_core_fields(
        &activated_state.0,
        &activated_state.1,
        &stripe_subscription_id,
        "starter",
        "active",
        false,
        &starter_price_id,
    );

    // SSOT: the Stripe Price object is the canonical fixture for starter-plan pricing.
    // A fixture misconfiguration (wrong STRIPE_PRICE_STARTER env) would still be caught
    // because the subscription itself would fail to create at the expected tier.
    let starter_price_unit_amount_cents = {
        let starter_price: stripe::PriceId = starter_price_id
            .parse()
            .expect("starter Stripe price id should parse");
        let starter_price = stripe::Price::retrieve(&stripe.client, &starter_price, &[])
            .await
            .expect("failed to retrieve starter Stripe price fixture");
        starter_price
            .unit_amount
            .expect("starter Stripe price fixture should define unit_amount cents")
    };
    let first_subscription_invoice = common::poll::poll_until(
        "first_subscription_invoice_paid",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let stripe_client = stripe.client.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            async move {
                let stripe_subscription_id: stripe::SubscriptionId =
                    stripe_subscription_id.parse().ok()?;
                let mut params = stripe::ListInvoices::new();
                params.subscription = Some(stripe_subscription_id);
                params.limit = Some(10);
                let invoices = stripe::Invoice::list(&stripe_client, &params).await.ok()?;
                // Stripe issues a $0 subscription_create invoice at trial start,
                // then a subscription_cycle invoice when the trial ends. Accept
                // either reason but require non-zero amount_paid to skip the $0
                // trial-create invoice.
                invoices
                    .data
                    .into_iter()
                    .find(|invoice| {
                        matches!(
                            invoice.billing_reason,
                            Some(
                                stripe::InvoiceBillingReason::SubscriptionCreate
                                    | stripe::InvoiceBillingReason::SubscriptionCycle
                            )
                        ) && invoice.paid == Some(true)
                            && invoice.amount_paid.unwrap_or(0) > 0
                    })
                    .and_then(|invoice| {
                        Some(StripeInvoiceSnapshot {
                            subtotal_cents: invoice.subtotal?,
                            total_cents: invoice.total?,
                            amount_paid_cents: invoice.amount_paid?,
                            paid: invoice.paid?,
                        })
                    })
            }
        },
    )
    .await;
    // Starter plan first paid invoice known answer: quantity 1 * starter monthly unit amount.
    let expected_first_subscription_invoice_cents = starter_price_unit_amount_cents;
    assert_eq!(
        first_subscription_invoice.subtotal_cents, expected_first_subscription_invoice_cents,
        "first post-trial Stripe invoice subtotal should match starter fixture arithmetic (1 * unit_amount)"
    );
    assert_eq!(
        first_subscription_invoice.total_cents, expected_first_subscription_invoice_cents,
        "first post-trial Stripe invoice total should match starter fixture arithmetic (1 * unit_amount)"
    );
    assert_eq!(
        first_subscription_invoice.amount_paid_cents, expected_first_subscription_invoice_cents,
        "first post-trial Stripe invoice amount_paid should match starter fixture arithmetic (1 * unit_amount)"
    );
    assert!(
        first_subscription_invoice.paid,
        "first post-trial Stripe subscription invoice should be paid"
    );

    let pre_renewal_start = activated_state.0.current_period_start;
    let pre_renewal_end = activated_state.0.current_period_end;
    let renewal_target_unix = activated_state.2.current_period_end + (2 * 60 * 60);

    advance_test_clock(
        &stripe.client,
        &test_clock_id,
        renewal_target_unix,
        "renewal_clock_ready",
    )
    .await;

    let renewed_state =
        common::poll::poll_until("renewal_boundary", POLL_TIMEOUT, POLL_INTERVAL, || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            let starter_price_id = starter_price_id.clone();
            let stripe_client = stripe.client.clone();
            async move {
                let local = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route = get_subscription_route(&client, &base, &jwt).await?;
                let stripe_subscription =
                    fetch_stripe_subscription_snapshot(&stripe_client, &stripe_subscription_id)
                        .await?;

                if !is_exactly_one_period_rollover(
                    pre_renewal_start,
                    pre_renewal_end,
                    local.current_period_start,
                    local.current_period_end,
                ) {
                    return None;
                }
                if local.status != "active" || route.status != "active" {
                    return None;
                }
                if local.plan_tier != "starter" || local.stripe_price_id != starter_price_id {
                    return None;
                }
                if unix_to_date(stripe_subscription.current_period_start)
                    != local.current_period_start
                    || unix_to_date(stripe_subscription.current_period_end)
                        != local.current_period_end
                {
                    return None;
                }

                Some((local, route))
            }
        })
        .await;

    assert_local_and_route_core_fields(
        &renewed_state.0,
        &renewed_state.1,
        &stripe_subscription_id,
        "starter",
        "active",
        false,
        &starter_price_id,
    );
    assert_exactly_one_period_rollover(
        pre_renewal_start,
        pre_renewal_end,
        renewed_state.0.current_period_start,
        renewed_state.0.current_period_end,
    );

    // Stage 3 invoice phase (red-first): define exact expected totals and
    // line-item guards before wiring any plan switch or usage seeding.
    let invoice_period_start = NaiveDate::from_ymd_opt(2026, 2, 1).expect("valid date");
    let invoice_period_end = NaiveDate::from_ymd_opt(2026, 2, 28).expect("valid date");
    let invoice_month = "2026-02";
    let seeded_usage_rows =
        seeded_usage_rows_for_month(invoice_period_start, invoice_period_end, "us-east-1");
    let expected_invoice =
        expected_shared_plan_invoice_for_seeded_usage(fj_customer_id, &seeded_usage_rows, &pool)
            .await;

    let updated_tenant =
        put_admin_tenant_billing_plan(&client, &base, fj_customer_id, "shared").await;
    assert_eq!(updated_tenant.id, fj_customer_id);
    assert_eq!(
        updated_tenant.billing_plan, "shared",
        "tenant billing_plan should canonicalize to shared before invoice generation"
    );

    reseed_usage_daily_rows_for_month(&pool, fj_customer_id, &seeded_usage_rows).await;

    let draft_invoice =
        post_admin_generate_invoice(&client, &base, fj_customer_id, invoice_month).await;
    assert_invoice_totals_match_expected(
        &draft_invoice,
        expected_invoice.subtotal_cents,
        expected_invoice.total_cents,
        expected_invoice.minimum_applied,
    );
    assert_no_search_or_write_invoice_lines(&draft_invoice.line_items);
    assert_invoice_line_items_match_expected(
        &draft_invoice.line_items,
        &expected_invoice.line_item_signatures,
    );

    let finalized_invoice = post_admin_finalize_invoice(&client, &base, draft_invoice.id).await;
    assert_eq!(
        finalized_invoice.status, "finalized",
        "invoice status should transition to finalized"
    );
    assert_invoice_totals_match_expected(
        &finalized_invoice,
        expected_invoice.subtotal_cents,
        expected_invoice.total_cents,
        expected_invoice.minimum_applied,
    );
    assert_eq!(
        invoice_line_item_signatures(&finalized_invoice.line_items),
        invoice_line_item_signatures(&draft_invoice.line_items),
        "finalization must not mutate deterministic line-item amounts"
    );

    let finalized_invoice_row = common::poll::poll_until(
        "admin_invoice_finalized_transition",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let invoice_id = draft_invoice.id;
            async move { fetch_local_invoice_state(&pool, invoice_id).await }
        },
    )
    .await;
    assert_eq!(
        finalized_invoice_row.status, "finalized",
        "invoice row should persist finalized status after finalize endpoint returns"
    );
    assert_eq!(
        finalized_invoice_row.subtotal_cents, expected_invoice.subtotal_cents,
        "persisted subtotal must match draft and finalized responses"
    );
    assert_eq!(
        finalized_invoice_row.total_cents, expected_invoice.total_cents,
        "persisted total must match draft and finalized responses"
    );
    assert_eq!(
        finalized_invoice_row.minimum_applied, expected_invoice.minimum_applied,
        "persisted minimum_applied flag must stay stable through finalization"
    );
    assert!(
        finalized_invoice_row.stripe_invoice_id.is_some(),
        "finalized invoice row should retain Stripe invoice id for webhook reconciliation"
    );

    // Stage 4 invoice phase (red-first shell): this stage is incomplete until a
    // second app-owned invoice receives invoice.payment_failed while the
    // subscription remains active.
    let second_invoice_period_start = NaiveDate::from_ymd_opt(2026, 3, 1).expect("valid date");
    let second_invoice_period_end = NaiveDate::from_ymd_opt(2026, 3, 31).expect("valid date");
    let second_invoice_month = "2026-03";
    let second_seeded_usage_rows = seeded_usage_rows_for_month(
        second_invoice_period_start,
        second_invoice_period_end,
        "us-east-1",
    );
    let second_expected_invoice = expected_shared_plan_invoice_for_seeded_usage(
        fj_customer_id,
        &second_seeded_usage_rows,
        &pool,
    )
    .await;

    reseed_usage_daily_rows_for_month(&pool, fj_customer_id, &second_seeded_usage_rows).await;

    let declining_payment_method_id =
        attach_declining_payment_method(&stripe.client, &stripe_customer_id).await;
    stripe
        .service
        .set_default_payment_method(&stripe_customer_id, &declining_payment_method_id)
        .await
        .expect("failed setting declining default payment method for first-failure stage");
    set_subscription_default_payment_method(
        &stripe.client,
        &stripe_subscription_id,
        &declining_payment_method_id,
    )
    .await;

    let second_draft_invoice =
        post_admin_generate_invoice(&client, &base, fj_customer_id, second_invoice_month).await;
    assert_invoice_totals_match_expected(
        &second_draft_invoice,
        second_expected_invoice.subtotal_cents,
        second_expected_invoice.total_cents,
        second_expected_invoice.minimum_applied,
    );
    assert_no_search_or_write_invoice_lines(&second_draft_invoice.line_items);
    assert_invoice_line_items_match_expected(
        &second_draft_invoice.line_items,
        &second_expected_invoice.line_item_signatures,
    );

    let second_finalized_invoice =
        post_admin_finalize_invoice(&client, &base, second_draft_invoice.id).await;
    assert_eq!(
        second_finalized_invoice.status, "finalized",
        "second invoice should remain finalized after first payment failure"
    );
    assert_invoice_totals_match_expected(
        &second_finalized_invoice,
        second_expected_invoice.subtotal_cents,
        second_expected_invoice.total_cents,
        second_expected_invoice.minimum_applied,
    );
    assert_eq!(
        invoice_line_item_signatures(&second_finalized_invoice.line_items),
        invoice_line_item_signatures(&second_draft_invoice.line_items),
        "second invoice finalization must preserve deterministic line-item amounts"
    );

    let second_invoice_row_for_failure = common::poll::poll_until(
        "second_invoice_stripe_id_ready_for_forced_failure_attempt",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let second_invoice_id = second_draft_invoice.id;
            async move {
                fetch_local_invoice_state_any_status(&pool, second_invoice_id)
                    .await
                    .and_then(|state| state.stripe_invoice_id.clone().map(|_| state))
            }
        },
    )
    .await;
    let second_invoice_stripe_id = second_invoice_row_for_failure
        .stripe_invoice_id
        .expect("second finalized invoice should include stripe_invoice_id");
    let second_invoice_stripe_id: stripe::InvoiceId = second_invoice_stripe_id
        .parse()
        .expect("second finalized invoice stripe id should parse");
    if let Err(err) = stripe::Invoice::pay(&stripe.client, &second_invoice_stripe_id).await {
        assert!(
            is_expected_invoice_payment_failure_message(&err.to_string()),
            "unexpected Stripe error while forcing first failed payment attempt on second invoice: {err}"
        );
    }

    let first_failure_state = common::poll::poll_until(
        "second_invoice_first_failure_reconciled",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let second_invoice_id = second_draft_invoice.id;
            async move {
                let second_invoice = fetch_local_invoice_state(&pool, second_invoice_id).await?;
                let stripe_invoice_id = second_invoice.stripe_invoice_id.clone()?;
                if !fetch_payment_failed_event_with_next_attempt(&pool, &stripe_invoice_id).await {
                    return None;
                }

                let customer_status = fetch_local_customer_status(&pool, fj_customer_id).await?;
                let local_subscription = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route_subscription = get_subscription_route(&client, &base, &jwt).await?;

                if customer_status != "active"
                    || local_subscription.status != "active"
                    || route_subscription.status != "active"
                {
                    return None;
                }

                Some((
                    second_invoice,
                    customer_status,
                    local_subscription,
                    route_subscription,
                ))
            }
        },
    )
    .await;

    assert_eq!(
        first_failure_state.0.status, "finalized",
        "second invoice row should stay finalized after invoice.payment_failed with retries remaining"
    );
    assert_eq!(
        first_failure_state.0.subtotal_cents, second_expected_invoice.subtotal_cents,
        "second invoice subtotal should remain stable through first failure reconciliation"
    );
    assert_eq!(
        first_failure_state.0.total_cents, second_expected_invoice.total_cents,
        "second invoice total should remain stable through first failure reconciliation"
    );
    assert_eq!(
        first_failure_state.0.minimum_applied, second_expected_invoice.minimum_applied,
        "second invoice minimum_applied should remain stable through first failure reconciliation"
    );
    assert_eq!(
        first_failure_state.1, "active",
        "customer should remain active on first payment failure with next_payment_attempt present"
    );
    assert_local_and_route_core_fields(
        &first_failure_state.2,
        &first_failure_state.3,
        &stripe_subscription_id,
        "starter",
        "active",
        false,
        &starter_price_id,
    );
    assert!(
        !matches!(
            first_failure_state.2.status.as_str(),
            "past_due" | "unpaid" | "canceled"
        ),
        "subscription row must not transition to past_due/unpaid/canceled on first payment failure"
    );
    assert!(
        !matches!(first_failure_state.3.status.as_str(), "past_due" | "unpaid" | "canceled"),
        "GET /billing/subscription must not transition to past_due/unpaid/canceled on first payment failure"
    );

    let recovery_payment_method_id =
        attach_test_payment_method(&stripe.client, &stripe_customer_id).await;
    stripe
        .service
        .set_default_payment_method(&stripe_customer_id, &recovery_payment_method_id)
        .await
        .expect("failed setting healthy default payment method for same-invoice recovery");
    set_subscription_default_payment_method(
        &stripe.client,
        &stripe_subscription_id,
        &recovery_payment_method_id,
    )
    .await;

    let recovered_invoice_stripe_id = first_failure_state
        .0
        .stripe_invoice_id
        .clone()
        .expect("first-failure checkpoint should keep stripe_invoice_id");
    let recovered_invoice_id: stripe::InvoiceId = recovered_invoice_stripe_id
        .parse()
        .expect("finalized invoice stripe_invoice_id should parse as Stripe InvoiceId");
    stripe::Invoice::pay(&stripe.client, &recovered_invoice_id)
        .await
        .expect("failed to trigger invoice pay on same failed Stripe invoice");

    let same_invoice_recovered_state = common::poll::poll_until(
        "second_invoice_recovered_paid",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let second_invoice_id = second_draft_invoice.id;
            async move {
                let second_invoice =
                    fetch_local_invoice_state_any_status(&pool, second_invoice_id).await?;
                let customer_status = fetch_local_customer_status(&pool, fj_customer_id).await?;
                let local_subscription = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route_subscription = get_subscription_route(&client, &base, &jwt).await?;

                if second_invoice.status != "paid"
                    || customer_status != "active"
                    || local_subscription.status != "active"
                    || route_subscription.status != "active"
                {
                    return None;
                }

                Some((
                    second_invoice,
                    customer_status,
                    local_subscription,
                    route_subscription,
                ))
            }
        },
    )
    .await;
    assert_eq!(
        same_invoice_recovered_state.0.status, "paid",
        "same invoice should recover to paid when retried with a healthy payment method"
    );
    assert_eq!(
        same_invoice_recovered_state.0.subtotal_cents, second_expected_invoice.subtotal_cents,
        "second invoice subtotal should remain stable through same-invoice recovery"
    );
    assert_eq!(
        same_invoice_recovered_state.0.total_cents, second_expected_invoice.total_cents,
        "second invoice total should remain stable through same-invoice recovery"
    );
    assert_eq!(
        same_invoice_recovered_state.0.minimum_applied, second_expected_invoice.minimum_applied,
        "second invoice minimum_applied should remain stable through same-invoice recovery"
    );
    assert_eq!(
        same_invoice_recovered_state.0.stripe_invoice_id.as_deref(),
        Some(recovered_invoice_stripe_id.as_str()),
        "same invoice recovery must reconcile on the originally failed Stripe invoice id"
    );
    assert_eq!(
        same_invoice_recovered_state.1, "active",
        "customer should remain active after same-invoice payment recovery"
    );
    assert_local_and_route_core_fields(
        &same_invoice_recovered_state.2,
        &same_invoice_recovered_state.3,
        &stripe_subscription_id,
        "starter",
        "active",
        false,
        &starter_price_id,
    );

    let paid_stripe_invoice = stripe::Invoice::retrieve(&stripe.client, &recovered_invoice_id, &[])
        .await
        .expect("failed to retrieve paid Stripe invoice before refund checkpoint");
    assert_eq!(
        paid_stripe_invoice.paid,
        Some(true),
        "Stripe invoice should be paid before refund checkpoint"
    );

    let mut refund_params = stripe::CreateRefund::new();
    match choose_refund_lookup_target(
        paid_stripe_invoice
            .charge
            .as_ref()
            .map(|charge| charge.id().to_string()),
        paid_stripe_invoice
            .payment_intent
            .as_ref()
            .map(|payment_intent| payment_intent.id().to_string()),
    ) {
        Some(RefundLookupTarget::Charge(charge_id)) => {
            refund_params.charge = Some(
                charge_id
                    .parse()
                    .expect("charge id should parse for refund checkpoint"),
            );
        }
        Some(RefundLookupTarget::PaymentIntent(payment_intent_id)) => {
            let payment_intent_id: stripe::PaymentIntentId = payment_intent_id
                .parse()
                .expect("payment_intent id should parse for refund checkpoint");
            let payment_intent =
                stripe::PaymentIntent::retrieve(&stripe.client, &payment_intent_id, &[])
                    .await
                    .expect("failed retrieving payment intent for refund checkpoint");
            if let Some(latest_charge) = payment_intent.latest_charge.as_ref() {
                refund_params.charge = Some(latest_charge.id().clone());
            } else {
                refund_params.payment_intent = Some(payment_intent_id);
            }
        }
        None => panic!("paid Stripe invoice should include payment_intent or charge for refund"),
    }
    stripe::Refund::create(&stripe.client, refund_params)
        .await
        .expect("failed creating Stripe refund for paid-invoice lifecycle checkpoint");

    let second_invoice_refunded_state = common::poll::poll_until(
        "second_invoice_refunded_after_charge_refunded",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let second_invoice_id = second_draft_invoice.id;
            async move {
                let second_invoice =
                    fetch_local_invoice_state_any_status(&pool, second_invoice_id).await?;
                let customer_status = fetch_local_customer_status(&pool, fj_customer_id).await?;
                let local_subscription = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route_subscription = get_subscription_route(&client, &base, &jwt).await?;

                if second_invoice.status != "refunded"
                    || customer_status != "active"
                    || local_subscription.status != "active"
                    || route_subscription.status != "active"
                {
                    return None;
                }

                Some((
                    second_invoice,
                    customer_status,
                    local_subscription,
                    route_subscription,
                ))
            }
        },
    )
    .await;
    assert_eq!(
        second_invoice_refunded_state.0.status, "refunded",
        "paid invoice should transition to refunded after charge.refunded lifecycle checkpoint"
    );
    assert_eq!(
        second_invoice_refunded_state.0.subtotal_cents, second_expected_invoice.subtotal_cents,
        "second invoice subtotal should remain stable through refund checkpoint"
    );
    assert_eq!(
        second_invoice_refunded_state.0.total_cents, second_expected_invoice.total_cents,
        "second invoice total should remain stable through refund checkpoint"
    );
    assert_eq!(
        second_invoice_refunded_state.0.minimum_applied, second_expected_invoice.minimum_applied,
        "second invoice minimum_applied should remain stable through refund checkpoint"
    );
    assert_eq!(
        second_invoice_refunded_state.0.stripe_invoice_id.as_deref(),
        Some(recovered_invoice_stripe_id.as_str()),
        "refund checkpoint should reconcile on the same Stripe invoice id recovered to paid"
    );
    assert_eq!(
        second_invoice_refunded_state.1, "active",
        "customer should remain active after the paid-invoice refund checkpoint"
    );
    assert_local_and_route_core_fields(
        &second_invoice_refunded_state.2,
        &second_invoice_refunded_state.3,
        &stripe_subscription_id,
        "starter",
        "active",
        false,
        &starter_price_id,
    );

    let cancel_response = cancel_subscription_now(&client, &base, &jwt).await;
    assert_eq!(cancel_response.id, stripe_subscription_id);

    let cancelled_state = common::poll::poll_until(
        "subscription_cancelled",
        POLL_TIMEOUT,
        POLL_INTERVAL,
        || {
            let pool = pool.clone();
            let client = client.clone();
            let base = base.clone();
            let jwt = jwt.clone();
            let stripe_subscription_id = stripe_subscription_id.clone();
            let starter_price_id = starter_price_id.clone();
            let stripe_client = stripe.client.clone();
            async move {
                let local = fetch_local_subscription(&pool, fj_customer_id).await?;
                let route = get_subscription_route(&client, &base, &jwt).await?;
                let stripe_subscription =
                    fetch_stripe_subscription_snapshot(&stripe_client, &stripe_subscription_id)
                        .await?;

                if local.status != "canceled"
                    || route.status != "canceled"
                    || stripe_subscription.status != "canceled"
                {
                    return None;
                }
                if local.cancel_at_period_end
                    || route.cancel_at_period_end
                    || stripe_subscription.cancel_at_period_end
                {
                    return None;
                }
                if local.plan_tier != "starter" || local.stripe_price_id != starter_price_id {
                    return None;
                }

                Some((local, route))
            }
        },
    )
    .await;

    assert_local_and_route_core_fields(
        &cancelled_state.0,
        &cancelled_state.1,
        &stripe_subscription_id,
        "starter",
        "canceled",
        false,
        &starter_price_id,
    );

    delete_stripe_customer(&stripe.client, &stripe_customer_id).await;
    delete_test_clock(&stripe.client, &test_clock_id).await;
}

#[cfg(test)]
mod lifecycle_assertion_tests {
    use super::*;
    use chrono::NaiveDate;

    fn sample_local_state() -> LocalSubscriptionState {
        LocalSubscriptionState {
            stripe_subscription_id: "sub_123".to_string(),
            stripe_price_id: "price_starter_test".to_string(),
            plan_tier: "starter".to_string(),
            status: "trialing".to_string(),
            current_period_start: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            current_period_end: NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
            cancel_at_period_end: false,
        }
    }

    fn sample_route_state() -> SubscriptionRouteResponse {
        SubscriptionRouteResponse {
            id: "sub_123".to_string(),
            plan_tier: "starter".to_string(),
            status: "trialing".to_string(),
            current_period_end: "2026-03-01".to_string(),
            cancel_at_period_end: false,
        }
    }

    #[test]
    #[should_panic(expected = "current_period_start")]
    fn create_phase_rejects_mismatched_initial_period_window() {
        let local = sample_local_state();
        let route = sample_route_state();
        assert_subscription_initial_period_window(
            &local,
            &route,
            NaiveDate::from_ymd_opt(2026, 2, 2).unwrap(),
            NaiveDate::from_ymd_opt(2026, 3, 2).unwrap(),
        );
    }

    #[test]
    fn create_phase_accepts_matching_initial_period_window() {
        let local = sample_local_state();
        let route = sample_route_state();
        assert_subscription_initial_period_window(
            &local,
            &route,
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        );
    }

    #[test]
    #[should_panic(expected = "exactly one period rollover")]
    fn renewal_rejects_multiple_period_jumps() {
        assert_exactly_one_period_rollover(
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 4, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
        );
    }

    #[test]
    fn renewal_accepts_single_period_rollover() {
        assert_exactly_one_period_rollover(
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 4, 1).unwrap(),
        );
    }

    #[test]
    fn invoice_phase_accepts_exact_line_item_payload_match() {
        let actual = vec![AdminInvoiceLineItemResponse {
            description: "Hot storage (us-east-1)".to_string(),
            quantity: "5600".to_string(),
            unit: "mb_months".to_string(),
            unit_price_cents: "5.0".to_string(),
            amount_cents: 28_000,
            region: "us-east-1".to_string(),
        }];
        let expected = vec![(
            "Hot storage (us-east-1)".to_string(),
            "5600".to_string(),
            "mb_months".to_string(),
            "5.0".to_string(),
            28_000,
            "us-east-1".to_string(),
        )];

        assert_invoice_line_items_match_expected(&actual, &expected);
    }

    #[test]
    fn invoice_phase_accepts_decimal_equivalent_line_item_payload_match() {
        let actual = vec![AdminInvoiceLineItemResponse {
            description: "Hot storage (us-east-1)".to_string(),
            quantity: "200.000000".to_string(),
            unit: "mb_months".to_string(),
            unit_price_cents: "5.0000".to_string(),
            amount_cents: 1_000,
            region: "us-east-1".to_string(),
        }];
        let expected = vec![(
            "Hot storage (us-east-1)".to_string(),
            "200".to_string(),
            "mb_months".to_string(),
            "5.0000000".to_string(),
            1_000,
            "us-east-1".to_string(),
        )];

        assert_invoice_line_items_match_expected(&actual, &expected);
    }

    #[test]
    fn expected_invoice_payment_failure_message_recognizes_decline_signatures() {
        assert!(is_expected_invoice_payment_failure_message(
            "Stripe API error: card_declined"
        ));
        assert!(is_expected_invoice_payment_failure_message(
            "payment_failed: invoice payment failed"
        ));
        assert!(is_expected_invoice_payment_failure_message(
            "The card was declined with insufficient_funds"
        ));
    }

    #[test]
    fn expected_invoice_payment_failure_message_rejects_unrelated_errors() {
        assert!(!is_expected_invoice_payment_failure_message(
            "invalid api key provided"
        ));
    }

    #[test]
    fn refund_lookup_prefers_charge_when_both_ids_exist() {
        let selected =
            choose_refund_lookup_target(Some("ch_123".to_string()), Some("pi_123".to_string()));
        assert_eq!(
            selected,
            Some(RefundLookupTarget::Charge("ch_123".to_string()))
        );
    }

    #[test]
    fn refund_lookup_falls_back_to_payment_intent() {
        let selected = choose_refund_lookup_target(None, Some("pi_123".to_string()));
        assert_eq!(
            selected,
            Some(RefundLookupTarget::PaymentIntent("pi_123".to_string()))
        );
    }

    #[test]
    fn refund_lookup_returns_none_when_no_identifiers_exist() {
        let selected = choose_refund_lookup_target(None, None);
        assert_eq!(selected, None);
    }

    #[test]
    fn local_subscription_query_is_schema_qualified() {
        assert!(
            LOCAL_SUBSCRIPTION_SELECT_QUERY.contains("FROM public.subscriptions"),
            "subscription query must stay schema-qualified to avoid search_path drift"
        );
    }

    #[test]
    #[should_panic(
        expected = "draft invoice line items should match deterministic app-owned pricing payload"
    )]
    fn invoice_phase_rejects_line_item_payload_mismatch() {
        let actual = vec![AdminInvoiceLineItemResponse {
            description: "Hot storage (us-east-1)".to_string(),
            quantity: "5600".to_string(),
            unit: "mb_months".to_string(),
            unit_price_cents: "5.0".to_string(),
            amount_cents: 27_999,
            region: "us-east-1".to_string(),
        }];
        let expected = vec![(
            "Hot storage (us-east-1)".to_string(),
            "5600".to_string(),
            "mb_months".to_string(),
            "5.0".to_string(),
            28_000,
            "us-east-1".to_string(),
        )];

        assert_invoice_line_items_match_expected(&actual, &expected);
    }
}

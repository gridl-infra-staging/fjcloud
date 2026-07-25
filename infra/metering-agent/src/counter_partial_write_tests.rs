use crate::record::tests::FailableUsageRecordWriter;
use axum::{extract::State, routing::get, Router};
use std::sync::{atomic::Ordering, Mutex};
use tokio::net::TcpListener;

type MetricsBody = Arc<Mutex<String>>;

struct MetricsFixture {
    flapjack_url: String,
    body: MetricsBody,
    server_handle: tokio::task::JoinHandle<()>,
}

impl MetricsFixture {
    async fn spawn(initial_body: String) -> Self {
        let body = Arc::new(Mutex::new(initial_body));
        let app = Router::new()
            .route("/metrics", get(serve_metrics))
            .with_state(Arc::clone(&body));
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("metrics listener should bind");
        let addr = listener
            .local_addr()
            .expect("metrics listener should expose its address");
        let server_handle = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("metrics server should run");
        });
        Self {
            flapjack_url: format!("http://{addr}"),
            body,
            server_handle,
        }
    }

    fn replace_body(&self, body: String) {
        *self.body.lock().expect("metrics body mutex should lock") = body;
    }
}

impl Drop for MetricsFixture {
    fn drop(&mut self) {
        self.server_handle.abort();
    }
}

async fn serve_metrics(State(body): State<MetricsBody>) -> String {
    body.lock().expect("metrics body mutex should lock").clone()
}

fn counter_metrics(search_requests: u64, write_operations: u64) -> String {
    format!(
        "flapjack_search_requests_total{{index=\"products\"}} {search_requests}\n\
         flapjack_write_operations_total{{index=\"products\"}} {write_operations}\n"
    )
}

#[test]
fn missing_counter_dimension_preserves_baseline_until_valid_sample_returns() {
    let cfg = test_config();
    let state: TenantStateMap = Arc::new(DashMap::new());
    let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
    let customer_id = Uuid::new_v4();
    tenant_map.insert(
        "products".to_string(),
        TenantAttribution {
            customer_id,
            tenant_id: "products".to_string(),
            tier: "active".to_string(),
            created_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
        },
    );
    state.insert(
        "products".to_string(),
        CounterState {
            search_requests: Some(100),
            write_operations: Some(50),
            documents_indexed: Some(0),
            documents_deleted: Some(0),
        },
    );

    let mut partial_metrics = crate::scraper::FlapjackMetrics::default();
    partial_metrics
        .search_requests_total
        .insert("products".to_string(), 110);
    let partial_records =
        build_counter_usage_records(&cfg, &partial_metrics, &state, &tenant_map, Utc::now());

    assert_eq!(partial_records.len(), 1);
    assert_eq!(
        partial_records[0].event_type,
        record::EventType::SearchRequests
    );
    assert_eq!(partial_records[0].value, 10);
    assert_eq!(
        state
            .get("products")
            .expect("tenant state should remain present")
            .write_operations,
        Some(50)
    );

    let mut recovered_metrics = crate::scraper::FlapjackMetrics::default();
    recovered_metrics
        .search_requests_total
        .insert("products".to_string(), 120);
    recovered_metrics
        .write_operations_total
        .insert("products".to_string(), 55);
    let recovered_records =
        build_counter_usage_records(&cfg, &recovered_metrics, &state, &tenant_map, Utc::now());
    let recovered_write = recovered_records
        .iter()
        .find(|usage| usage.event_type == record::EventType::WriteOperations)
        .expect("recovered write counter should produce its incremental delta");

    assert_eq!(recovered_write.value, 5);
}

#[tokio::test]
async fn scrape_retries_only_unwritten_counter_delta_after_partial_write_failure() {
    let metrics_fixture = MetricsFixture::spawn(counter_metrics(100, 20)).await;
    let mut cfg = test_config();
    cfg.flapjack_url = metrics_fixture.flapjack_url.clone();
    let state: TenantStateMap = Arc::new(DashMap::new());
    let tenant_map: TenantCustomerMap = Arc::new(DashMap::new());
    let customer_id = Uuid::new_v4();
    tenant_map.insert(
        "products".to_string(),
        TenantAttribution {
            customer_id,
            tenant_id: "products".to_string(),
            tier: "active".to_string(),
            created_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
        },
    );
    let writer = FailableUsageRecordWriter::new(false);
    let http = reqwest::Client::new();

    scrape_and_record(&cfg, &writer, &http, &state, &tenant_map)
        .await
        .expect("initial scrape should establish counter baselines");

    metrics_fixture.replace_body(counter_metrics(150, 45));
    writer.set_fail_from_call(Some(2));
    let partial_write = scrape_and_record(&cfg, &writer, &http, &state, &tenant_map).await;
    assert!(
        partial_write.is_err(),
        "the second counter write should abort the scrape"
    );

    // Clone the captured records out of the guard so no `MutexGuard` is held
    // across the retry `scrape_and_record(...).await` below (clippy
    // `await_holding_lock` does not honor an explicit `drop`).
    let successful_records = writer
        .successful_records
        .lock()
        .expect("successful records mutex should lock")
        .clone();
    assert_eq!(successful_records.len(), 1);
    assert_eq!(
        successful_records[0].event_type,
        record::EventType::SearchRequests
    );
    assert_eq!(successful_records[0].value, 50);
    assert_eq!(successful_records[0].tenant_id, "products");
    assert_eq!(successful_records[0].customer_id, customer_id);
    let successful_before_retry = successful_records.len();

    writer.set_fail_from_call(None);
    scrape_and_record(&cfg, &writer, &http, &state, &tenant_map)
        .await
        .expect("retry should persist the previously unwritten delta");

    let retry_records = writer
        .successful_records
        .lock()
        .expect("successful records mutex should lock")[successful_before_retry..]
        .to_vec();
    let retried_writes: Vec<_> = retry_records
        .iter()
        .filter(|record| record.event_type == record::EventType::WriteOperations)
        .collect();
    assert_eq!(retried_writes.len(), 1);
    assert_eq!(retried_writes[0].value, 25);
    assert_eq!(retried_writes[0].tenant_id, "products");
    assert_eq!(retried_writes[0].customer_id, customer_id);
    assert!(
        retry_records.iter().all(|record| {
            record.event_type != record::EventType::SearchRequests || record.value == 0
        }),
        "retry must not re-bill the already persisted search delta"
    );
    assert_eq!(writer.attempt_count.load(Ordering::SeqCst), 3);
}

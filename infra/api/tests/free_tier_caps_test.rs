mod common;

use api::models::IngestQuotaWarningMetric;
use api::repos::tenant_repo::TenantRepo;
use api::repos::CustomerRepo;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::NodeSecretManager;
use api::services::email::MockEmailService;
use api::services::flapjack_proxy::FlapjackProxy;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Datelike, Utc};
use common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use common::indexes_route_test_support::response_json;
use common::{
    create_test_jwt, mock_deployment_repo, mock_repo, mock_tenant_repo, mock_usage_repo,
    mock_vm_inventory_repo, TestStateBuilder,
};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tower::ServiceExt;

async fn setup_index_with_usage(
    billing_plan: &str,
    documents_count_avg: i64,
    storage_bytes_avg: i64,
) -> (
    axum::Router,
    String,
    Arc<MockFlapjackHttpClient>,
    uuid::Uuid,
    Arc<common::MockCustomerRepo>,
    Arc<MockEmailService>,
) {
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant_repo = mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let usage_repo = mock_usage_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let email_service = common::mock_email_service();
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());

    let customer = match billing_plan {
        "shared" => customer_repo.seed_verified_shared_customer("Alice", "alice@cap.test"),
        _ => customer_repo.seed_verified_free_customer("Alice", "alice@cap.test"),
    };
    let jwt = create_test_jwt(customer.id);

    let today = Utc::now().date_naive();
    usage_repo.seed(
        customer.id,
        today,
        "us-east-1",
        0,
        0,
        storage_bytes_avg,
        documents_count_avg,
    );

    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-test.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "test-index", deployment.id)
        .await
        .unwrap();

    let vm = vm_inventory_repo.seed("us-east-1", "https://vm-test.flapjack.foo");
    tenant_repo
        .set_vm_id(customer.id, "test-index", vm.id)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager,
    ));

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_deployment_repo(deployment_repo)
        .with_tenant_repo(tenant_repo)
        .with_usage_repo(usage_repo)
        .with_flapjack_proxy(flapjack_proxy)
        .with_vm_inventory_repo(vm_inventory_repo)
        .with_email_service(email_service.clone())
        .build_app();

    (
        app,
        jwt,
        http_client,
        customer.id,
        customer_repo,
        email_service,
    )
}

fn batch_request(count: usize) -> serde_json::Value {
    let operations: Vec<serde_json::Value> = (0..count)
        .map(|i| {
            json!({
                "action": "addObject",
                "body": { "title": format!("doc-{i}") }
            })
        })
        .collect();
    json!({ "requests": operations })
}

fn batch_request_with_large_payload(count: usize, payload_bytes: usize) -> serde_json::Value {
    let large_value = "x".repeat(payload_bytes);
    let operations: Vec<serde_json::Value> = (0..count)
        .map(|i| {
            json!({
                "action": "addObject",
                "body": { "title": format!("doc-{i}"), "blob": large_value }
            })
        })
        .collect();
    json!({ "requests": operations })
}

#[tokio::test]
async fn free_plan_max_records_blocks_over_100k() {
    let (app, jwt, _http, _cid, _customer_repo, _email_service) =
        setup_index_with_usage("free", 99_999, 0).await;

    let body = batch_request(2);
    let (status, json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "body: {json}");
    assert_eq!(json["error"], "quota_exceeded");
    assert_eq!(json["limit"], "max_records");
}

#[tokio::test]
async fn free_plan_max_storage_mb_blocks_over_250mb() {
    let storage_bytes = (250 * 1024 * 1024) - 1024;
    let (app, jwt, _http, _cid, _customer_repo, _email_service) =
        setup_index_with_usage("free", 0, storage_bytes).await;

    let body = batch_request_with_large_payload(1, 4096);
    let (status, json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "body: {json}");
    assert_eq!(json["error"], "quota_exceeded");
    assert_eq!(json["limit"], "max_storage_mb");
}

#[tokio::test]
async fn shared_plan_ingest_above_free_caps() {
    let (app, jwt, http, _cid, _customer_repo, email_service) =
        setup_index_with_usage("shared", 150_000, 300 * 1024 * 1024).await;

    http.push_json_response(200, json!({"results": []}));

    let body = batch_request(1);
    let (status, _json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(
        status,
        StatusCode::OK,
        "Shared plan must not be blocked by free-tier caps"
    );
    assert_eq!(email_service.sent_emails().len(), 0);
}

#[tokio::test]
async fn free_plan_records_ingest_at_80_percent_sends_warning_email() {
    let (app, jwt, http, customer_id, customer_repo, email_service) =
        setup_index_with_usage("free", 79_999, 0).await;
    http.push_json_response(200, json!({"results": []}));

    let body = batch_request(1);
    let (status, _json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    let sent = common::poll::poll_until(
        "records_ingest_warning_email",
        Duration::from_secs(2),
        Duration::from_millis(10),
        || {
            let email_service = email_service.clone();
            async move {
                let sent = email_service.sent_emails();
                if sent.len() == 1 {
                    Some(sent)
                } else {
                    None
                }
            }
        },
    )
    .await;
    assert!(sent[0].html_body.contains("max_records"));
    assert!(sent[0].html_body.contains("80.0"));

    let now = chrono::Utc::now();
    let customer = customer_repo
        .find_by_id(customer_id)
        .await
        .unwrap()
        .expect("customer should exist");
    assert!(customer.ingest_quota_warning_sent_for_month(
        IngestQuotaWarningMetric::Records,
        now.year(),
        now.month()
    ));
}

#[tokio::test]
async fn free_plan_storage_ingest_at_80_percent_sends_warning_email() {
    let storage_bytes = (200_u64 * 1024 * 1024) as i64;
    let (app, jwt, http, customer_id, customer_repo, email_service) =
        setup_index_with_usage("free", 0, storage_bytes).await;
    http.push_json_response(200, json!({"results": []}));

    let body = batch_request_with_large_payload(1, 1024);
    let (status, _json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    let sent = common::poll::poll_until(
        "storage_ingest_warning_email",
        Duration::from_secs(2),
        Duration::from_millis(10),
        || {
            let email_service = email_service.clone();
            async move {
                let sent = email_service.sent_emails();
                if sent.len() == 1 {
                    Some(sent)
                } else {
                    None
                }
            }
        },
    )
    .await;
    assert!(sent[0].html_body.contains("max_storage_mb"));
    assert!(sent[0].html_body.contains("80.0"));

    let now = chrono::Utc::now();
    let customer = customer_repo
        .find_by_id(customer_id)
        .await
        .unwrap()
        .expect("customer should exist");
    assert!(customer.ingest_quota_warning_sent_for_month(
        IngestQuotaWarningMetric::StorageMb,
        now.year(),
        now.month()
    ));
}

#[tokio::test]
async fn free_plan_ingest_warning_not_sent_twice_in_same_month() {
    let (app, jwt, http, customer_id, customer_repo, email_service) =
        setup_index_with_usage("free", 90_000, 0).await;
    let now = chrono::Utc::now();
    customer_repo
        .claim_ingest_quota_warning_for_month(
            customer_id,
            IngestQuotaWarningMetric::Records,
            now.year(),
            now.month(),
        )
        .await
        .unwrap();
    http.push_json_response(200, json!({"results": []}));

    let body = batch_request(1);
    let (status, _json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(email_service.sent_emails().len(), 0);
    let customer = customer_repo
        .find_by_id(customer_id)
        .await
        .unwrap()
        .expect("customer should exist");
    assert!(customer.ingest_quota_warning_sent_for_month(
        IngestQuotaWarningMetric::Records,
        now.year(),
        now.month()
    ));
}

#[tokio::test]
async fn free_plan_over_cap_ingest_rejection_does_not_send_warning_or_consume_monthly_slot() {
    let (app, jwt, _http, customer_id, customer_repo, email_service) =
        setup_index_with_usage("free", 99_999, 0).await;

    let body = batch_request(2);
    let (status, json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "body: {json}");
    assert_eq!(json["error"], "quota_exceeded");
    assert_eq!(json["limit"], "max_records");
    assert_eq!(email_service.sent_emails().len(), 0);

    let customer = customer_repo
        .find_by_id(customer_id)
        .await
        .unwrap()
        .expect("customer should exist");
    let now = chrono::Utc::now();
    assert!(!customer.ingest_quota_warning_sent_for_month(
        IngestQuotaWarningMetric::Records,
        now.year(),
        now.month()
    ));
}

#[tokio::test]
async fn free_plan_storage_over_cap_ingest_rejection_does_not_send_warning_or_consume_monthly_slot()
{
    let storage_bytes = (250 * 1024 * 1024) - 1024;
    let (app, jwt, _http, customer_id, customer_repo, email_service) =
        setup_index_with_usage("free", 0, storage_bytes).await;

    let body = batch_request_with_large_payload(1, 4096);
    let (status, json) = response_json(
        app.oneshot(
            Request::post("/indexes/test-index/batch")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::to_string(&body).unwrap()))
                .unwrap(),
        )
        .await
        .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::FORBIDDEN, "body: {json}");
    assert_eq!(json["error"], "quota_exceeded");
    assert_eq!(json["limit"], "max_storage_mb");
    assert_eq!(email_service.sent_emails().len(), 0);

    let customer = customer_repo
        .find_by_id(customer_id)
        .await
        .unwrap()
        .expect("customer should exist");
    let now = chrono::Utc::now();
    assert!(!customer.ingest_quota_warning_sent_for_month(
        IngestQuotaWarningMetric::StorageMb,
        now.year(),
        now.month()
    ));
}

mod common;

use std::sync::Arc;

// `with_day` lives on the chrono::Datelike trait; needed below to compute a
// same-month timestamp without depending on `now - 1 day` (which crosses the
// month boundary at the start of every month).
use chrono::Datelike;

use api::models::vm_inventory::NewVmInventory;
use api::models::Deployment;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::CustomerRepo;
use api::router::build_router;
use api::secrets::NodeSecretManager;
use api::services::email::{EmailService, MockEmailService};
use api::services::flapjack_proxy::{
    FlapjackHttpClient, FlapjackHttpRequest, FlapjackHttpResponse, FlapjackProxy, ProxyError,
};
use api::services::provisioning::{ProvisioningService, DEFAULT_DNS_DOMAIN};
use api::services::tenant_quota::{
    FreeTierLimits, QuotaDefaults, ResolvedQuota, TenantQuotaService,
};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::time::Duration;
use tower::ServiceExt;

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

#[derive(Default)]
struct StaticSuccessFlapjackHttpClient;

#[async_trait]
impl FlapjackHttpClient for StaticSuccessFlapjackHttpClient {
    async fn send(
        &self,
        _request: FlapjackHttpRequest,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        Ok(FlapjackHttpResponse {
            status: 200,
            body: json!({"hits": [], "nbHits": 0}).to_string(),
        })
    }
}

struct QuotaTestApp {
    app: axum::Router,
    vm_id: uuid::Uuid,
    email_service: Arc<MockEmailService>,
    tenant_repo: Arc<common::MockTenantRepo>,
}

async fn build_quota_app(
    customer_repo: Arc<common::MockCustomerRepo>,
    deployment_repo: Arc<common::MockDeploymentRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    usage_repo: Arc<common::MockUsageRepo>,
    free_tier_limits: FreeTierLimits,
) -> QuotaTestApp {
    let vm_inventory_repo = common::mock_vm_inventory_repo();
    let email_service = common::mock_email_service();

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-quota-test.flapjack.foo".to_string(),
            flapjack_url: "https://vm-quota-test.flapjack.foo".to_string(),
            capacity: json!({
                "cpu_weight": 4.0,
                "mem_rss_bytes": 8_589_934_592_u64,
                "disk_bytes": 107_374_182_400_u64,
                "query_rps": 500.0,
                "indexing_rps": 200.0
            }),
        })
        .await
        .unwrap();

    // Set load so placement considers this VM (load_scraped_at must be fresh)
    vm_inventory_repo
        .update_load(vm.id, json!({}))
        .await
        .unwrap();

    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key("node-a1", "us-east-1")
        .await
        .unwrap();
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(StaticSuccessFlapjackHttpClient),
        node_secret_manager.clone(),
    ));
    let provisioning_service = Arc::new(ProvisioningService::new(
        common::mock_vm_provisioner(),
        common::mock_dns_manager(),
        node_secret_manager,
        deployment_repo.clone(),
        customer_repo.clone(),
        DEFAULT_DNS_DOMAIN.to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo,
    );
    state.usage_repo = usage_repo;
    state.free_tier_limits = free_tier_limits;
    state.provisioning_service = provisioning_service;
    state.email_service = email_service.clone() as Arc<dyn EmailService>;

    QuotaTestApp {
        app: build_router(state),
        vm_id: vm.id,
        email_service,
        tenant_repo,
    }
}

fn post_bearer_json(uri: &str, jwt: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn seed_searchable_index(
    deployment_repo: Arc<common::MockDeploymentRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    customer_id: uuid::Uuid,
    index_name: &str,
    vm_id: uuid::Uuid,
) -> Deployment {
    let deployment = deployment_repo.seed_provisioned(
        customer_id,
        "node-a1",
        "us-east-1",
        "shared",
        "aws",
        "running",
        Some("https://vm-quota-test.flapjack.foo"),
    );
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some("https://vm-quota-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, index_name, deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, index_name, vm_id)
        .await
        .unwrap();
    deployment
}

async fn wait_for_email_count(email_service: &MockEmailService, expected_count: usize) {
    // For zero expected emails, observe the full window to catch delayed async sends.
    if expected_count == 0 {
        for _ in 0..40 {
            if !email_service.sent_emails().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(email_service.sent_emails().len(), 0);
        return;
    }

    for _ in 0..40 {
        let actual = email_service.sent_emails().len();
        if actual == expected_count {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert_eq!(email_service.sent_emails().len(), expected_count);
}

/// Default quota for rate-limiting tests: 100 query RPS, 50 write RPS.
fn default_test_quota() -> ResolvedQuota {
    ResolvedQuota {
        max_query_rps: 100,
        max_write_rps: 50,
        max_storage_bytes: 10_737_418_240,
        max_indexes: 10,
    }
}

#[tokio::test]
async fn free_tier_customer_blocked_at_index_limit() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();

    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");
    let existing_deployment_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        existing_deployment_id,
        "us-east-1",
        Some("https://vm-quota-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "existing-index", existing_deployment_id)
        .await
        .unwrap();

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes",
            &jwt,
            json!({"name": "blocked-index", "region": "us-east-1"}),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        body,
        json!({
            "error": "quota_exceeded",
            "limit": "max_indexes",
            "upgrade_url": "/billing/upgrade"
        })
    );
}

#[tokio::test]
async fn free_tier_customer_can_create_first_index() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();

    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes",
            &jwt,
            json!({"name": "first-index", "region": "us-east-1"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn shared_plan_customer_not_blocked_at_index_limit() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();

    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");
    let existing_deployment_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        existing_deployment_id,
        "us-east-1",
        Some("https://vm-quota-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "existing-index", existing_deployment_id)
        .await
        .unwrap();

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes",
            &jwt,
            json!({"name": "shared-second-index", "region": "us-east-1"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn shared_plan_create_index_honors_customer_quota_override_above_default_limit() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();

    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");

    for index_number in 0..10 {
        let deployment_id = uuid::Uuid::new_v4();
        tenant_repo.seed_deployment(
            deployment_id,
            "us-east-1",
            Some("https://vm-quota-test.flapjack.foo"),
            "healthy",
            "running",
        );
        let index_name = format!("existing-index-{index_number}");
        tenant_repo
            .create(customer.id, &index_name, deployment_id)
            .await
            .unwrap();
        tenant_repo
            .set_resource_quota(customer.id, &index_name, json!({ "max_indexes": 11 }))
            .await
            .unwrap();
    }

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes",
            &jwt,
            json!({"name": "shared-eleventh-index", "region": "us-east-1"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn new_shared_index_inherits_existing_customer_quota_override() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();

    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");
    let existing_deployment_id = uuid::Uuid::new_v4();
    tenant_repo.seed_deployment(
        existing_deployment_id,
        "us-east-1",
        Some("https://vm-quota-test.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "existing-index", existing_deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_resource_quota(customer.id, "existing-index", json!({ "max_indexes": 11 }))
        .await
        .unwrap();

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes",
            &jwt,
            json!({"name": "new-index", "region": "us-east-1"}),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);

    let created = setup
        .tenant_repo
        .find_raw(customer.id, "new-index")
        .await
        .unwrap()
        .expect("new index should exist");
    assert_eq!(created.resource_quota, json!({ "max_indexes": 11 }));
}

#[tokio::test]
async fn free_tier_search_blocked_at_monthly_quota() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 100, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        body,
        json!({
            "error": "quota_exceeded",
            "limit": "monthly_searches",
            "upgrade_url": "/billing/upgrade"
        })
    );
}

#[tokio::test]
async fn shared_plan_search_not_blocked_at_monthly_quota() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 10_000, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn free_tier_search_succeeds_under_quota() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 99, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn quota_warning_email_sent_at_80_percent() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 80, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_email_count(&setup.email_service, 1).await;
    let emails = setup.email_service.sent_emails();
    assert_eq!(emails[0].to, "free@example.com");
    assert!(emails[0].html_body.contains("monthly_searches"));
    assert!(emails[0].html_body.contains("80.0"));
    assert!(emails[0].text_body.contains("monthly_searches"));
    assert!(emails[0].text_body.contains("80.0"));
}

#[tokio::test]
async fn quota_warning_not_sent_below_80_percent() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 79, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_email_count(&setup.email_service, 0).await;
}

#[tokio::test]
async fn quota_warning_not_sent_twice_in_same_month() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");
    // Seed `quota_warning_sent_at` to a timestamp guaranteed to be in the SAME
    // calendar month as `Utc::now()`. Using `now - 1 day` is unsafe across
    // month boundaries: when CI runs on the first day of a month, "yesterday"
    // lands in the previous month and the production suppression check
    // (`sent_at.month() == now.month()` in routes/indexes/search.rs) treats the
    // seeded warning as belonging to a different month — so a second email
    // gets dispatched and this test fails. CI run 25195410333 hit exactly
    // that on 2026-05-01T00:30:56Z. Computing the first-of-month from `now`
    // is unambiguously "earlier in the same month" regardless of when the
    // test runs.
    let now = chrono::Utc::now();
    let earlier_this_month = now
        .with_day(1)
        .expect("day=1 is always valid for any month");
    customer_repo
        .set_quota_warning_sent_at(customer.id, earlier_this_month)
        .await
        .unwrap();

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 90, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_email_count(&setup.email_service, 0).await;
}

#[tokio::test]
async fn quota_warning_resets_next_month() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_free_customer("Free", "free@example.com");
    customer_repo
        .set_quota_warning_sent_at(customer.id, chrono::Utc::now() - chrono::Duration::days(40))
        .await
        .unwrap();

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 80, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_email_count(&setup.email_service, 1).await;
}

#[tokio::test]
async fn query_rate_limiting_exceeds_limit_returns_429() {
    let quota_service = TenantQuotaService::new(QuotaDefaults::default());
    let customer_id = uuid::Uuid::new_v4();
    let quota = default_test_quota();

    for _ in 0..100 {
        let result = quota_service.check_query_rate(customer_id, "test-index", &quota);
        assert!(result.is_ok(), "first 100 queries should succeed");
    }

    let result = quota_service.check_query_rate(customer_id, "test-index", &quota);
    assert!(result.is_err(), "101st query should be rate limited");
    let err = result.unwrap_err();
    assert!(
        err.retry_after > 0 && err.retry_after <= 1,
        "retry_after should be ~1 second"
    );
}

#[tokio::test]
async fn write_rate_limiting_exceeds_limit_returns_429() {
    let quota_service = TenantQuotaService::new(QuotaDefaults::default());
    let customer_id = uuid::Uuid::new_v4();
    let quota = default_test_quota();

    for _ in 0..50 {
        let result = quota_service.check_write_rate(customer_id, "test-index", &quota);
        assert!(result.is_ok(), "first 50 writes should succeed");
    }

    let result = quota_service.check_write_rate(customer_id, "test-index", &quota);
    assert!(result.is_err(), "51st write should be rate limited");
}

#[tokio::test]
async fn rate_limiting_is_per_customer_and_index() {
    let quota_service = TenantQuotaService::new(QuotaDefaults::default());
    let customer_a = uuid::Uuid::new_v4();
    let customer_b = uuid::Uuid::new_v4();
    let quota = default_test_quota();

    for _ in 0..100 {
        quota_service
            .check_query_rate(customer_a, "index-a", &quota)
            .unwrap();
    }

    let result = quota_service.check_query_rate(customer_b, "index-b", &quota);
    assert!(result.is_ok(), "customer B should not be rate limited");

    let result = quota_service.check_query_rate(customer_a, "index-b", &quota);
    assert!(result.is_ok(), "different index should have separate quota");
}

#[tokio::test]
async fn rate_limiting_recovers_after_window() {
    let quota_service = TenantQuotaService::new(QuotaDefaults::default());
    let customer_id = uuid::Uuid::new_v4();
    let quota = default_test_quota();

    for _ in 0..101 {
        let _ = quota_service.check_query_rate(customer_id, "test-index", &quota);
    }

    tokio::time::sleep(tokio::time::Duration::from_millis(1100)).await;

    let result = quota_service.check_query_rate(customer_id, "test-index", &quota);
    assert!(result.is_ok(), "should recover after rate limit window");
}

/// Verifies that duplicate index creation returns 409 CONFLICT under concurrent
/// create requests for the same customer/index.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_index_creation_only_one_succeeds() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo,
        tenant_repo,
        usage_repo,
        FreeTierLimits {
            max_indexes: 100,
            max_searches_per_month: 50_000,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);

    let mut handles = Vec::new();
    let start_barrier = Arc::new(tokio::sync::Barrier::new(6));
    for _ in 0..5 {
        let app = setup.app.clone();
        let jwt = jwt.clone();
        let start_barrier = Arc::clone(&start_barrier);
        let handle = tokio::spawn(async move {
            start_barrier.wait().await;
            app.oneshot(post_bearer_json(
                "/indexes",
                &jwt,
                json!({"name": "concurrent-test-index", "region": "us-east-1"}),
            ))
            .await
            .unwrap()
        });
        handles.push(handle);
    }
    start_barrier.wait().await;

    let mut success_count = 0;
    let mut conflict_count = 0;
    for handle in handles {
        let resp = handle.await.unwrap();
        if resp.status() == StatusCode::CREATED {
            success_count += 1;
        } else if resp.status() == StatusCode::CONFLICT {
            conflict_count += 1;
        }
    }

    assert_eq!(success_count, 1, "exactly one creation should succeed");
    assert_eq!(conflict_count, 4, "remaining should get conflict");
}

#[tokio::test]
async fn shared_plan_no_quota_warning() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let usage_repo = common::mock_usage_repo();
    let customer = customer_repo.seed_verified_shared_customer("Shared", "shared@example.com");

    let setup = build_quota_app(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo.clone(),
        usage_repo.clone(),
        FreeTierLimits {
            max_indexes: 1,
            max_searches_per_month: 100,
        },
    )
    .await;

    let jwt = common::create_test_jwt(customer.id);
    seed_searchable_index(
        deployment_repo,
        tenant_repo,
        customer.id,
        "searchable",
        setup.vm_id,
    )
    .await;

    let today = chrono::Utc::now().date_naive();
    usage_repo.seed(customer.id, today, "us-east-1", 50_000, 0, 0, 0);

    let resp = setup
        .app
        .oneshot(post_bearer_json(
            "/indexes/searchable/search",
            &jwt,
            json!({ "query": "hello" }),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    wait_for_email_count(&setup.email_service, 0).await;
}

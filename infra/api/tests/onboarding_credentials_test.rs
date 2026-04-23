mod common;

use api::repos::tenant_repo::TenantRepo;
use api::repos::VmInventoryRepo;
use api::secrets::NodeSecretManager;
use api::services::flapjack_proxy::FlapjackProxy;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use common::{
    create_test_jwt, mock_api_key_repo, mock_deployment_repo, mock_flapjack_proxy_with_secrets,
    mock_node_secret_manager, mock_repo, mock_stripe_service, mock_tenant_repo,
    mock_vm_inventory_repo, test_app_with_onboarding,
};
use http_body_util::BodyExt;
use std::sync::Arc;
use tower::ServiceExt;

const EXPECTED_ONBOARDING_ACLS: &[&str] = &["search", "browse"];

async fn post_credentials(app: axum::Router, jwt: &str) -> (StatusCode, serde_json::Value) {
    let req = Request::builder()
        .method("POST")
        .uri("/onboarding/credentials")
        .header("Authorization", format!("Bearer {jwt}"))
        .header("Content-Type", "application/json")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let body = Body::new(resp.into_body())
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    (status, json)
}

/// Returns credentials when deployment is running and customer has indexes.
#[tokio::test]
async fn returns_credentials_when_deployment_running() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Alice", "alice@test.com");

    let deployment_repo = mock_deployment_repo();
    let node_id = "node-alice";
    let flapjack_url = "https://node-alice.flapjack.foo";
    let http_client = Arc::new(MockFlapjackHttpClient::default());

    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        node_id,
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(flapjack_url),
    );

    // Seed the node secret for the proxy
    let secret_manager = mock_node_secret_manager();
    secret_manager
        .create_node_api_key(node_id, "us-east-1")
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        secret_manager.clone(),
    ));

    let tenant_repo = mock_tenant_repo();
    tenant_repo.seed_deployment(
        deployment.id,
        "us-east-1",
        Some(flapjack_url),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer.id, "products", deployment.id)
        .await
        .unwrap();

    http_client.push_json_response(
        200,
        serde_json::json!({
            "key": "fj_search_abc123",
            "createdAt": "2026-02-21T12:00:00Z"
        }),
    );

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_api_key_repo(),
        mock_stripe_service(),
        flapjack_proxy,
    );

    let (status, body) = post_credentials(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["endpoint"], flapjack_url);
    assert_eq!(body["api_key"], "fj_search_abc123");
    assert_eq!(body["application_id"], "flapjack");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, reqwest::Method::POST);
    assert_eq!(requests[0].url, format!("{flapjack_url}/1/keys"));
    let expected_uid = format!("{}_{}", customer.id.as_simple(), "products");
    assert_eq!(
        requests[0].json_body,
        Some(serde_json::json!({
            "acl": EXPECTED_ONBOARDING_ACLS,
            "indexes": [expected_uid],
            "description": "default API key"
        }))
    );
}

/// Returns 400 when deployment is running but customer has no indexes.
#[tokio::test]
async fn returns_400_when_running_but_no_indexes() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Dave", "dave@test.com");

    let deployment_repo = mock_deployment_repo();

    deployment_repo.seed_provisioned(
        customer.id,
        "node-dave",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://node-dave.flapjack.foo"),
    );

    // No indexes created for this customer
    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy_with_secrets(mock_node_secret_manager()),
    );

    let (status, body) = post_credentials(app, &jwt).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("Create at least one index"),
        "expected 'Create at least one index' error, got: {}",
        body["error"]
    );
}

/// Returns 400 when no deployment exists.
#[tokio::test]
async fn returns_400_when_no_deployment() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Bob", "bob@test.com");
    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        mock_deployment_repo(),
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy_with_secrets(mock_node_secret_manager()),
    );

    let (status, body) = post_credentials(app, &jwt).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "No active endpoint yet");
}

/// Returns 400 when deployment is still provisioning (not running).
#[tokio::test]
async fn returns_400_when_deployment_still_provisioning() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Carol", "carol@test.com");

    let deployment_repo = mock_deployment_repo();
    deployment_repo.seed(
        customer.id,
        "node-carol",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let jwt = create_test_jwt(customer.id);

    let app = test_app_with_onboarding(
        customer_repo,
        deployment_repo,
        mock_tenant_repo(),
        mock_api_key_repo(),
        mock_stripe_service(),
        mock_flapjack_proxy_with_secrets(mock_node_secret_manager()),
    );

    let (status, body) = post_credentials(app, &jwt).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "No active endpoint yet");
}

#[tokio::test]
async fn shared_vm_credentials_use_vm_secret_instead_of_deployment_secret() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Eve", "eve@test.com");

    let deployment_repo = mock_deployment_repo();
    let running = deployment_repo.seed_provisioned(
        customer.id,
        "synthetic-shared-deployment-node",
        "us-east-1",
        "shared",
        "aws",
        "running",
        Some("https://shared-auth.flapjack.foo"),
    );

    let tenant_repo = mock_tenant_repo();
    tenant_repo.seed_deployment(
        running.id,
        "us-east-1",
        Some("https://shared-auth.flapjack.foo"),
        "healthy",
        "running",
    );
    let tenant = tenant_repo
        .create(customer.id, "products", running.id)
        .await
        .unwrap();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-shared-auth.flapjack.foo".into(),
            flapjack_url: "https://shared-auth.flapjack.foo".into(),
            capacity: serde_json::json!({"cpu_weight": 4.0}),
        })
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, &tenant.tenant_id, vm.id)
        .await
        .unwrap();

    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let secret_manager = mock_node_secret_manager();
    let vm_secret = secret_manager
        .create_node_api_key(vm.node_secret_id(), "us-east-1")
        .await
        .unwrap();
    let deployment_secret = secret_manager
        .create_node_api_key(&running.node_id, "us-east-1")
        .await
        .unwrap();
    assert_ne!(
        vm_secret, deployment_secret,
        "test requires the shared VM and deployment secrets to differ"
    );

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        secret_manager.clone(),
    ));

    http_client.push_json_response(
        200,
        serde_json::json!({
            "key": "fj_search_shared_vm",
            "createdAt": "2026-03-19T12:00:00Z"
        }),
    );

    let mut state = common::test_state_with_onboarding(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo,
        mock_api_key_repo(),
        mock_stripe_service(),
        flapjack_proxy,
    );
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    state.vm_provisioner = vm_provisioner.clone();
    state.dns_manager = dns_manager.clone();
    state.provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner,
        dns_manager,
        secret_manager,
        deployment_repo,
        state.customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));
    state.vm_inventory_repo = vm_inventory_repo;
    let app = api::router::build_router(state);

    let jwt = create_test_jwt(customer.id);
    let (status, body) = post_credentials(app, &jwt).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["api_key"], "fj_search_shared_vm");

    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].api_key, vm_secret);
    assert_ne!(
        requests[0].api_key, deployment_secret,
        "credentials generation must authenticate against the shared VM, not the synthetic deployment key"
    );
}

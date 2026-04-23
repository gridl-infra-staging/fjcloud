mod common;

use std::sync::Arc;
use std::sync::Mutex;

use api::repos::deployment_repo::DeploymentRepo;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::secrets::{NodeSecretError, NodeSecretManager};
use api::services::flapjack_proxy::FlapjackProxy;
use api::vm_providers::{AWS_VM_PROVIDER, BARE_METAL_VM_PROVIDER};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use tower::ServiceExt;

use common::{
    create_test_jwt, flapjack_proxy_test_support::MockFlapjackHttpClient,
    mock_flapjack_proxy_with_secrets, mock_vm_inventory_repo, MockCustomerRepo, MockDeploymentRepo,
    TEST_ADMIN_KEY,
};

#[derive(Default)]
struct FailOnSecondCreateSecretManager {
    create_calls: Mutex<u32>,
}

#[async_trait]
impl NodeSecretManager for FailOnSecondCreateSecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        let mut create_calls = self.create_calls.lock().expect("create_calls poisoned");
        *create_calls += 1;
        if *create_calls >= 2 {
            return Err(NodeSecretError::Api(format!(
                "injected failure creating key for {node_id}"
            )));
        }
        Ok(format!("fj_live_seed_{node_id}"))
    }

    async fn delete_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        Err(NodeSecretError::Api(format!(
            "no key found for node {node_id}"
        )))
    }

    async fn rotate_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        Err(NodeSecretError::Api(
            "rotation not supported in this test".into(),
        ))
    }

    async fn commit_rotation(
        &self,
        _node_id: &str,
        _region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }
}

#[tokio::test]
async fn seed_index_without_flapjack_url_creates_placeholder() {
    let customer_repo = std::sync::Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed("Acme", "acme@test.com");

    let deployment_repo = std::sync::Arc::new(MockDeploymentRepo::new());
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = common::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        proxy,
        vm_inventory_repo.clone(),
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({ "name": "products", "region": "us-east-1" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let resp: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(resp["name"], "products");
    assert_eq!(resp["region"], "us-east-1");

    // Without flapjack_url, no VM should be created and tenant has no vm_id.
    let vms = vm_inventory_repo.list_active(None).await.unwrap();
    assert!(
        vms.is_empty(),
        "no VM should be seeded without flapjack_url"
    );

    let tenant = tenant_repo
        .find_raw(customer.id, "products")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert!(
        tenant.vm_id.is_none(),
        "vm_id should be None without flapjack_url"
    );
}

#[tokio::test]
async fn seed_index_with_flapjack_url_creates_vm_and_sets_vm_id() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");
    let jwt = create_test_jwt(customer.id);

    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client.clone(),
        node_secret_manager.clone(),
    ));
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo.clone(),
        deployment_repo.clone(),
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    let app = api::router::build_router(state);

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "products",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let resp: serde_json::Value = serde_json::from_slice(&body).unwrap();

    // Response should include the endpoint.
    assert_eq!(resp["name"], "products");
    assert_eq!(resp["endpoint"], "http://localhost:7700");

    // A VM record should have been created in vm_inventory.
    let vms = vm_inventory_repo.list_active(None).await.unwrap();
    assert_eq!(vms.len(), 1);
    assert_eq!(vms[0].flapjack_url, "http://localhost:7700");
    assert_eq!(vms[0].region, "us-east-1");
    assert_eq!(
        vms[0].provider, BARE_METAL_VM_PROVIDER,
        "seeded local flapjack VMs must use a provider accepted by vm_inventory"
    );
    assert!(
        vms[0].load_scraped_at.is_some(),
        "seeded local flapjack VMs should be immediately placeable for shared-VM onboarding"
    );
    assert_eq!(
        vms[0].current_load,
        json!({
            "cpu_weight": 0.0,
            "mem_rss_bytes": 0,
            "disk_bytes": 0,
            "query_rps": 0.0,
            "indexing_rps": 0.0
        }),
        "seeded local flapjack VMs should start with zero load so placement can reuse them"
    );

    let deployments = deployment_repo
        .list_by_customer(customer.id, false)
        .await
        .unwrap();
    assert_eq!(deployments.len(), 1);
    let deployment = &deployments[0];
    assert_eq!(
        deployment.vm_provider, BARE_METAL_VM_PROVIDER,
        "synthetic flapjack-backed deployments should use the same provider as their seeded VM"
    );
    assert!(
        node_secret_manager
            .get_secret(&deployment.node_id)
            .is_some(),
        "synthetic deployment should receive an admin key for dashboard search proxying"
    );
    let vm_secret = node_secret_manager
        .get_secret(vms[0].node_secret_id())
        .expect("seeded shared VM secret should exist for shared placement and proxying");

    // The tenant should have vm_id set to the new VM.
    let tenant = tenant_repo
        .find_raw(customer.id, "products")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(vms[0].id));

    // Keep the mock tenant summary in sync with the seeded deployment so the
    // route-level search path can resolve the target during this test.
    tenant_repo.seed_deployment(
        deployment.id,
        &deployment.region,
        Some("http://localhost:7700"),
        "healthy",
        "running",
    );

    http_client.push_json_response(
        200,
        json!({
            "hits": [{"objectID": "1", "title": "Rust Programming Language"}],
            "nbHits": 1,
            "processingTimeMS": 2
        }),
    );

    let search_response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/indexes/products/search")
                .header("authorization", format!("Bearer {jwt}"))
                .header("content-type", "application/json")
                .body(Body::from(json!({ "query": "Rust" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(search_response.status(), StatusCode::OK);
    let search_requests = http_client.take_requests();
    assert_eq!(search_requests.len(), 1);
    let expected_uid = format!("{}_{}", customer.id.as_simple(), "products");
    assert_eq!(
        search_requests[0].url,
        format!("http://localhost:7700/1/indexes/{expected_uid}/query")
    );
    assert_eq!(search_requests[0].api_key, vm_secret);
}

#[tokio::test]
async fn seed_index_with_flapjack_url_reuses_existing_vm() {
    let customer_repo = std::sync::Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed("Acme", "acme@test.com");

    let deployment_repo = std::sync::Arc::new(MockDeploymentRepo::new());
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();

    // Pre-seed a VM with the same flapjack_url.
    let existing_vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: BARE_METAL_VM_PROVIDER.into(),
            hostname: "e2e-flapjack".into(),
            flapjack_url: "http://localhost:7700".into(),
            capacity: json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .unwrap();

    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = common::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        proxy,
        vm_inventory_repo.clone(),
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "orders",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let resp: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(resp["endpoint"], "http://localhost:7700");

    // Should reuse the existing VM, not create a second one.
    let vms = vm_inventory_repo.list_active(None).await.unwrap();
    assert_eq!(
        vms.len(),
        1,
        "should reuse existing VM, not create a new one"
    );
    assert_eq!(vms[0].id, existing_vm.id);
    assert!(
        vms[0].load_scraped_at.is_some(),
        "reused local flapjack VMs should be backfilled with fresh load metadata for placement"
    );

    // Tenant should point to the existing VM.
    let tenant = tenant_repo
        .find_raw(customer.id, "orders")
        .await
        .unwrap()
        .expect("tenant should exist");
    assert_eq!(tenant.vm_id, Some(existing_vm.id));
}

#[tokio::test]
async fn seed_index_with_flapjack_url_ignores_existing_vm_with_mismatched_provider() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");

    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let reused_deployment = deployment_repo.seed(
        customer.id,
        "existing-node",
        "us-east-1",
        "t4g.small",
        AWS_VM_PROVIDER,
        "running",
    );
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: BARE_METAL_VM_PROVIDER.into(),
            hostname: "e2e-flapjack-mismatch".into(),
            flapjack_url: "http://localhost:7700".into(),
            capacity: json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .unwrap();

    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(MockFlapjackHttpClient::default()),
        node_secret_manager.clone(),
    ));
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo.clone(),
        deployment_repo.clone(),
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    let app = api::router::build_router(state);
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "products",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    let tenant = tenant_repo
        .find_raw(customer.id, "products")
        .await
        .unwrap()
        .expect("tenant should exist");
    let linked_vm = vm_inventory_repo
        .get(tenant.vm_id.expect("tenant should link to a VM"))
        .await
        .unwrap()
        .expect("linked VM should exist");
    assert_eq!(
        linked_vm.provider, reused_deployment.vm_provider,
        "seeding should not reuse a flapjack VM row whose provider conflicts with the deployment"
    );

    let vms = vm_inventory_repo
        .list_active(Some("us-east-1"))
        .await
        .unwrap();
    assert_eq!(vms.len(), 2);
    assert_eq!(
        vms.iter()
            .filter(|vm| vm.flapjack_url == "http://localhost:7700")
            .count(),
        2,
        "the route should create a provider-aligned replacement VM instead of reusing the mismatched row"
    );
}

#[tokio::test]
async fn seed_index_with_flapjack_url_backfills_missing_node_key_on_reused_deployment() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");

    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let existing = deployment_repo.seed(
        customer.id,
        "node-existing",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: AWS_VM_PROVIDER.into(),
            hostname: "e2e-flapjack".into(),
            flapjack_url: "http://localhost:7700".into(),
            capacity: json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .unwrap();

    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    assert!(
        node_secret_manager.get_secret(&existing.node_id).is_none(),
        "precondition: reused deployment starts without node key"
    );

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(MockFlapjackHttpClient::default()),
        node_secret_manager.clone(),
    ));
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));
    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;
    let app = api::router::build_router(state);

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "searchable-products",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    assert!(
        node_secret_manager.get_secret(&existing.node_id).is_some(),
        "reused running deployment must have a node key after seeded flapjack-backed index creation"
    );

    let deployments = deployment_repo
        .list_by_customer(customer.id, false)
        .await
        .unwrap();
    assert_eq!(
        deployments.len(),
        1,
        "seeding should reuse the existing deployment instead of creating another one"
    );
    let vms = vm_inventory_repo
        .list_active(None)
        .await
        .expect("vm inventory should be readable after seeding");
    assert_eq!(vms.len(), 1);
    assert_eq!(
        deployments[0].vm_provider, vms[0].provider,
        "reused deployments and linked VMs must keep the same provider for fleet lookups"
    );
}

#[tokio::test]
async fn seed_index_with_flapjack_url_preserves_existing_node_key_on_reused_deployment() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");

    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let existing = deployment_repo.seed(
        customer.id,
        "node-existing",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: AWS_VM_PROVIDER.into(),
            hostname: "e2e-flapjack".into(),
            flapjack_url: "http://localhost:7700".into(),
            capacity: json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .unwrap();

    let node_secret_manager = Arc::new(api::secrets::mock::MockNodeSecretManager::new());
    let existing_key = node_secret_manager
        .create_node_api_key(&existing.node_id, &existing.region)
        .await
        .unwrap();

    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(MockFlapjackHttpClient::default()),
        node_secret_manager.clone(),
    ));
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));
    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo.clone(),
        tenant_repo,
        flapjack_proxy,
        vm_inventory_repo.clone(),
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;
    let app = api::router::build_router(state);

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "searchable-orders",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CREATED);
    assert_eq!(
        node_secret_manager.get_secret(&existing.node_id),
        Some(existing_key),
        "existing node key should be reused instead of being rotated by admin seeding"
    );
    let deployments = deployment_repo
        .list_by_customer(customer.id, false)
        .await
        .expect("deployments should be readable after seeding");
    let vms = vm_inventory_repo
        .list_active(None)
        .await
        .expect("vm inventory should be readable after seeding");
    assert_eq!(deployments.len(), 1);
    assert_eq!(vms.len(), 1);
    assert_eq!(
        deployments[0].vm_provider, vms[0].provider,
        "reused deployments and linked VMs must keep the same provider for fleet lookups"
    );
}

#[tokio::test]
async fn seed_index_with_flapjack_url_does_not_leave_tenant_when_vm_key_setup_fails() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");

    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let node_secret_manager = Arc::new(FailOnSecondCreateSecretManager::default());
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        Arc::new(MockFlapjackHttpClient::default()),
        node_secret_manager.clone(),
    ));
    let vm_provisioner = Arc::new(api::provisioner::mock::MockVmProvisioner::new());
    let dns_manager = Arc::new(api::dns::mock::MockDnsManager::new());
    let provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager.clone(),
        node_secret_manager,
        deployment_repo.clone(),
        customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        flapjack_proxy,
        vm_inventory_repo,
    );
    state.vm_provisioner = vm_provisioner;
    state.dns_manager = dns_manager;
    state.provisioning_service = provisioning_service;

    let app = api::router::build_router(state);
    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "products",
                        "region": "us-east-1",
                        "flapjack_url": "http://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert!(
        tenant_repo
            .find_raw(customer.id, "products")
            .await
            .unwrap()
            .is_none(),
        "failed flapjack-backed seeding must not leave a partially created tenant behind"
    );
}

#[tokio::test]
async fn seed_index_with_flapjack_url_rejects_non_http_scheme() {
    let customer_repo = Arc::new(MockCustomerRepo::new());
    let customer = customer_repo.seed_verified_free_customer("Acme", "acme@test.com");
    let deployment_repo = Arc::new(MockDeploymentRepo::new());
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = mock_vm_inventory_repo();
    let proxy = mock_flapjack_proxy_with_secrets(Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = common::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        proxy,
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/tenants/{}/indexes", customer.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .header("Content-Type", "application/json")
                .body(axum::body::Body::from(
                    json!({
                        "name": "products",
                        "region": "us-east-1",
                        "flapjack_url": "ftp://localhost:7700"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let resp: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert!(
        resp["error"]
            .as_str()
            .unwrap_or_default()
            .contains("http or https"),
        "expected flapjack_url scheme validation error, got: {resp}"
    );
}

mod common;

use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::DeploymentRepo;
use axum::http::{Request, StatusCode};
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    mock_flapjack_proxy_with_secrets, mock_vm_inventory_repo, MockCustomerRepo, MockDeploymentRepo,
    TEST_ADMIN_KEY,
};

#[tokio::test]
async fn get_vm_detail_returns_vm_with_tenant_breakdown() {
    let customer_id = Uuid::new_v4();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-test.flapjack.foo".into(),
            flapjack_url: "https://vm-test.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let tenant_repo = common::mock_tenant_repo();
    let deployment_repo = MockDeploymentRepo::new();
    let dep = deployment_repo
        .create(
            customer_id,
            "node-1",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            dep.id,
            "aws:i-test1234567890",
            "203.0.113.10",
            "vm-test.flapjack.foo",
            "https://vm-test.flapjack.foo",
        )
        .await
        .unwrap();

    tenant_repo
        .create(customer_id, "products", dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();

    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = common::test_app_with_indexes_and_vm_inventory(
        std::sync::Arc::new(MockCustomerRepo::new()),
        std::sync::Arc::new(deployment_repo),
        tenant_repo,
        proxy,
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", vm.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["vm"]["hostname"], "vm-test.flapjack.foo");
    assert_eq!(json["vm"]["region"], "us-east-1");
    assert_eq!(json["vm"]["status"], "active");
    assert_eq!(json["vm"]["provider_vm_id"], "i-test1234567890");
    assert_eq!(json["tenants"][0]["tenant_id"], "products");
}

#[tokio::test]
async fn get_vm_detail_returns_404_for_unknown_vm() {
    let app = common::test_app();

    let unknown_id = Uuid::new_v4();
    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", unknown_id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn get_vm_detail_ignores_stale_deployment_provider_vm_id() {
    let customer_id = Uuid::new_v4();

    let vm_inventory_repo = mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-test.flapjack.foo".into(),
            flapjack_url: "https://vm-test.flapjack.foo".into(),
            capacity: json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let tenant_repo = common::mock_tenant_repo();
    let deployment_repo = MockDeploymentRepo::new();

    let active_dep = deployment_repo
        .create(
            customer_id,
            "node-good",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            active_dep.id,
            "aws:i-good123",
            "203.0.113.10",
            "vm-test.flapjack.foo",
            "https://vm-test.flapjack.foo",
        )
        .await
        .unwrap();

    let stale_dep = deployment_repo
        .create(
            customer_id,
            "node-stale",
            "us-east-1",
            "t4g.medium",
            "aws",
            None,
        )
        .await
        .unwrap();
    deployment_repo
        .update_provisioning(
            stale_dep.id,
            "aws:i-aaa-stale",
            "203.0.113.11",
            "vm-old.flapjack.foo",
            "https://vm-old.flapjack.foo",
        )
        .await
        .unwrap();

    tenant_repo
        .create(customer_id, "products", active_dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_id, "orders", stale_dep.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "orders", vm.id)
        .await
        .unwrap();

    let proxy = mock_flapjack_proxy_with_secrets(std::sync::Arc::new(
        api::secrets::mock::MockNodeSecretManager::new(),
    ));

    let app = common::test_app_with_indexes_and_vm_inventory(
        std::sync::Arc::new(MockCustomerRepo::new()),
        std::sync::Arc::new(deployment_repo),
        tenant_repo,
        proxy,
        vm_inventory_repo,
    );

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/admin/vms/{}", vm.id))
                .header("X-Admin-Key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["vm"]["provider_vm_id"], "i-good123");
}

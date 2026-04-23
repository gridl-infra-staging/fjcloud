//! Tests for the `POST /admin/vms/{id}/kill` endpoint.
//!
//! The kill endpoint is local-mode only: it kills the Flapjack process on a
//! localhost port. These tests verify the URL validation, 404 handling, and
//! response format. Actual process killing is not tested here (requires a
//! running Flapjack) — the unit tests in vms.rs cover the helper functions.

mod common;

use api::repos::vm_inventory_repo::VmInventoryRepo;
use axum::http::{Request, StatusCode};
use serde_json::json;
use tower::ServiceExt;

use std::sync::Arc;

use common::{
    mock_flapjack_proxy_with_secrets, mock_vm_inventory_repo, MockCustomerRepo, MockDeploymentRepo,
    MockVmInventoryRepo, TEST_ADMIN_KEY,
};

/// Helper: build a test app with a custom VM inventory repo.
fn build_app(vm_repo: Arc<MockVmInventoryRepo>) -> axum::Router {
    common::test_app_with_indexes_and_vm_inventory(
        Arc::new(MockCustomerRepo::new()),
        Arc::new(MockDeploymentRepo::new()),
        common::mock_tenant_repo(),
        mock_flapjack_proxy_with_secrets(
            Arc::new(api::secrets::mock::MockNodeSecretManager::new()),
        ),
        vm_repo,
    )
}

#[tokio::test]
async fn kill_vm_returns_404_for_nonexistent_vm() {
    let app = build_app(mock_vm_inventory_repo());
    let fake_id = uuid::Uuid::new_v4();

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{fake_id}/kill"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn kill_vm_rejects_non_localhost_url() {
    let vm_repo = mock_vm_inventory_repo();

    // Create a VM with a remote (non-localhost) flapjack_url
    let vm = vm_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-remote.flapjack.foo".into(),
            flapjack_url: "https://vm-remote.flapjack.foo:7700".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/kill", vm.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Should be 400 Bad Request — remote VMs can't be killed via this endpoint
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn kill_vm_requires_admin_auth() {
    let vm_repo = mock_vm_inventory_repo();
    let vm = vm_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "local".into(),
            hostname: "local-dev-us-east-1".into(),
            flapjack_url: "http://127.0.0.1:7700".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);

    // No admin key header → should fail auth
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/kill", vm.id))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn list_vms_returns_all_active_vms() {
    let vm_repo = mock_vm_inventory_repo();

    // Seed two VMs
    vm_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: "local".into(),
            hostname: "local-dev-us-east-1".into(),
            flapjack_url: "http://127.0.0.1:7700".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    vm_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "eu-west-1".into(),
            provider: "local".into(),
            hostname: "local-dev-eu-west-1".into(),
            flapjack_url: "http://127.0.0.1:7701".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);

    let resp = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/admin/vms")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), 1_000_000)
        .await
        .unwrap();
    let vms: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(vms.len(), 2);

    // Verify both regions are present
    let regions: Vec<&str> = vms.iter().map(|v| v["region"].as_str().unwrap()).collect();
    assert!(regions.contains(&"us-east-1"));
    assert!(regions.contains(&"eu-west-1"));
}

//! Integration tests for the full HA demo flow.
//!
//! Tests the integration between:
//! - GET /admin/vms — lists VMs from inventory
//! - POST /admin/vms/{id}/kill — kills a local Flapjack process
//! - POST /admin/deployments/{id}/health-check — detects unhealthy VM
//! - Region failover — promotes replicas when region goes down
//!
//! These tests use mock repos (no database needed) and wiremock for health
//! endpoints. They verify the API layer correctly wires to the underlying
//! services without needing a running local stack.

mod common;

use api::models::vm_inventory::NewVmInventory;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use axum::http::{Request, StatusCode};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

use common::{
    mock_flapjack_proxy_with_secrets, mock_vm_inventory_repo, MockCustomerRepo, MockDeploymentRepo,
    MockVmInventoryRepo, TEST_ADMIN_KEY,
};

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

// ---------------------------------------------------------------------------
// VM list endpoint tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_vms_returns_seeded_local_vms() {
    let vm_repo = mock_vm_inventory_repo();

    // Seed 3 local VMs — same topology as local-dev-up.sh multi-region mode
    for (region, port) in [
        ("us-east-1", 7700),
        ("eu-west-1", 7701),
        ("eu-central-1", 7702),
    ] {
        vm_repo
            .create(NewVmInventory {
                region: region.into(),
                provider: "local".into(),
                hostname: format!("local-dev-{region}"),
                flapjack_url: format!("http://127.0.0.1:{port}"),
                capacity: json!({"cpu_cores": 4}),
            })
            .await
            .unwrap();
    }

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

    // All 3 regions should be present
    assert_eq!(vms.len(), 3);
    let regions: Vec<&str> = vms.iter().map(|v| v["region"].as_str().unwrap()).collect();
    assert!(regions.contains(&"us-east-1"));
    assert!(regions.contains(&"eu-west-1"));
    assert!(regions.contains(&"eu-central-1"));

    // All should have localhost URLs
    for vm in &vms {
        let url = vm["flapjack_url"].as_str().unwrap();
        assert!(
            url.starts_with("http://127.0.0.1:"),
            "VM URL should be localhost: {url}"
        );
    }
}

// ---------------------------------------------------------------------------
// Kill endpoint security tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn kill_rejects_remote_url_even_with_admin_auth() {
    // Ensure the kill endpoint is a genuine local-only safety gate
    let vm_repo = mock_vm_inventory_repo();
    let remote_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "prod-vm-1.flapjack.foo".into(),
            flapjack_url: "https://prod-vm-1.flapjack.foo:7700".into(),
            capacity: json!({"cpu_cores": 8}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/kill", remote_vm.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body = axum::body::to_bytes(resp.into_body(), 1_000_000)
        .await
        .unwrap();
    let error: serde_json::Value = serde_json::from_slice(&body).unwrap();
    // Error message should clearly state this is local-only
    assert!(
        error["error"].as_str().unwrap().contains("local"),
        "Error should mention 'local': {:?}",
        error
    );
}

#[tokio::test]
async fn kill_rejects_prefix_attack_urls() {
    // Regression test for the prefix-matching security bug.
    // URLs that START WITH a valid loopback string but aren't actually loopback
    // must be rejected.
    let vm_repo = mock_vm_inventory_repo();
    let evil_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "local".into(),
            hostname: "evil-local".into(),
            // This starts with "http://127.0.0.1" but is a different IP
            flapjack_url: "http://127.0.0.199:7700".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/kill", evil_vm.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Must be rejected — 127.0.0.199 is NOT 127.0.0.1
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn kill_rejects_localhost_subdomain_attack() {
    let vm_repo = mock_vm_inventory_repo();
    let evil_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "local".into(),
            hostname: "evil-local-2".into(),
            flapjack_url: "http://localhost.evil.com:7700".into(),
            capacity: json!({"cpu_cores": 4}),
        })
        .await
        .unwrap();

    let app = build_app(vm_repo);
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/vms/{}/kill", evil_vm.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Must be rejected — localhost.evil.com is NOT localhost
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

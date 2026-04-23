mod common;

use api::models::cold_snapshot::NewColdSnapshot;
use api::models::vm_inventory::NewVmInventory;
use api::repos::{ColdSnapshotRepo, InMemoryColdSnapshotRepo, TenantRepo, VmInventoryRepo};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Harness for admin cold storage endpoint tests.
struct ColdAdminHarness {
    app: axum::Router,
    customer_id: Uuid,
    snapshot_id: Uuid,
}

async fn setup_cold_admin_harness() -> ColdAdminHarness {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant_repo = common::mock_tenant_repo();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let customer = customer_repo.seed("ColdCorp", "cold@cold.dev");

    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, "my-cold-index", deployment_id)
        .await
        .expect("seed tenant");

    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm1.flapjack.foo".to_string(),
            flapjack_url: "http://vm1.flapjack.foo".to_string(),
            capacity: json!({"cpu": 100.0, "memory_mb": 4096.0, "disk_gb": 100.0}),
        })
        .await
        .expect("seed vm");

    let cold_snapshot_repo = Arc::new(InMemoryColdSnapshotRepo::new());

    // Create and complete a snapshot
    let snapshot = cold_snapshot_repo
        .create(NewColdSnapshot {
            customer_id: customer.id,
            tenant_id: "my-cold-index".to_string(),
            source_vm_id: vm.id,
            object_key: format!("cold/{}/my-cold-index/snap.fj", customer.id),
        })
        .await
        .expect("create snapshot");
    cold_snapshot_repo
        .set_exporting(snapshot.id)
        .await
        .expect("set exporting");
    cold_snapshot_repo
        .set_completed(snapshot.id, 512_000, "sha256abc")
        .await
        .expect("set completed");

    // Mark tenant as cold with snapshot id
    tenant_repo
        .set_tier(customer.id, "my-cold-index", "cold")
        .await
        .expect("set cold tier");
    tenant_repo
        .set_cold_snapshot_id(customer.id, "my-cold-index", Some(snapshot.id))
        .await
        .expect("set cold snapshot id");

    let mut state = common::test_state_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo.clone(),
        common::mock_flapjack_proxy(),
        vm_inventory_repo,
    );
    state.cold_snapshot_repo = cold_snapshot_repo;

    ColdAdminHarness {
        app: api::router::build_router(state),
        customer_id: customer.id,
        snapshot_id: snapshot.id,
    }
}

#[tokio::test]
async fn admin_cold_list_returns_snapshot_metadata() {
    let h = setup_cold_admin_harness().await;

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/admin/cold")
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let json = body_json(resp).await;
    let entries = json.as_array().expect("should be array");
    assert_eq!(entries.len(), 1, "should have one cold index");

    let entry = &entries[0];
    assert_eq!(entry["customer_id"], h.customer_id.to_string());
    assert_eq!(entry["tenant_id"], "my-cold-index");
    assert_eq!(entry["snapshot_id"], h.snapshot_id.to_string());
    assert_eq!(entry["size_bytes"], 512_000);
    assert_eq!(entry["status"], "completed");
    // cold_since should be populated from snapshot completed_at
    assert!(
        entry["cold_since"].is_string(),
        "cold_since should be present"
    );
}

#[tokio::test]
async fn admin_cold_detail_returns_snapshot_detail() {
    let h = setup_cold_admin_harness().await;

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/admin/cold/{}", h.snapshot_id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let json = body_json(resp).await;
    assert_eq!(json["id"], h.snapshot_id.to_string());
    assert_eq!(json["customer_id"], h.customer_id.to_string());
    assert_eq!(json["tenant_id"], "my-cold-index");
    assert_eq!(json["size_bytes"], 512_000);
    assert_eq!(json["checksum"], "sha256abc");
    assert_eq!(json["status"], "completed");
    assert!(json["object_key"].as_str().unwrap().contains("cold/"));
}

#[tokio::test]
async fn admin_cold_detail_not_found() {
    let h = setup_cold_admin_harness().await;

    let resp = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/admin/cold/{}", Uuid::new_v4()))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

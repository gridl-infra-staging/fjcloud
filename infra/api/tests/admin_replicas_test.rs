mod common;

use api::models::vm_inventory::NewVmInventory;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Seed two VMs + two replicas (one active, one failed) across different regions.
async fn seed_replicas(state: &api::state::AppState) -> (Uuid, Uuid) {
    let vm_aws = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-aws-1.flapjack.foo".into(),
            flapjack_url: "https://vm-aws-1.flapjack.foo:7700".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let vm_hetzner = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "eu-central-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-hetzner-1.flapjack.foo".into(),
            flapjack_url: "https://vm-hetzner-1.flapjack.foo:7700".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();

    // Active replica in eu-central-1
    let r1 = state
        .index_replica_repo
        .create(
            customer_id,
            "products",
            vm_aws.id,
            vm_hetzner.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    state
        .index_replica_repo
        .set_status(r1.id, "active")
        .await
        .unwrap();
    state.index_replica_repo.set_lag(r1.id, 42).await.unwrap();

    // Failed replica in us-east-1
    let r2 = state
        .index_replica_repo
        .create(customer_id, "orders", vm_hetzner.id, vm_aws.id, "us-east-1")
        .await
        .unwrap();
    state
        .index_replica_repo
        .set_status(r2.id, "failed")
        .await
        .unwrap();

    (r1.id, r2.id)
}

#[tokio::test]
async fn admin_replicas_endpoint_returns_all_replicas() {
    let state = common::test_state();
    let (r1_id, r2_id) = seed_replicas(&state).await;

    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/replicas")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2, "both active and failed replicas returned");

    // Verify fields present on each replica
    let active = arr
        .iter()
        .find(|r| r["id"] == r1_id.to_string())
        .expect("active replica should be present");
    assert_eq!(active["status"], "active");
    assert_eq!(active["replica_region"], "eu-central-1");
    assert_eq!(active["tenant_id"], "products");
    assert_eq!(active["lag_ops"], 42);
    assert!(active["primary_vm_hostname"].is_string());
    assert!(active["replica_vm_hostname"].is_string());

    let failed = arr
        .iter()
        .find(|r| r["id"] == r2_id.to_string())
        .expect("failed replica should be present");
    assert_eq!(failed["status"], "failed");
    assert_eq!(failed["replica_region"], "us-east-1");
    assert_eq!(failed["tenant_id"], "orders");
}

#[tokio::test]
async fn admin_replicas_filter_by_status() {
    let state = common::test_state();
    seed_replicas(&state).await;

    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/replicas?status=active")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 1, "only active replicas returned");
    assert_eq!(arr[0]["status"], "active");
}

/// Regression: ?status=syncing must include legacy "replicating" replicas because
/// "replicating" is the old name for syncing (backward-compat status).
#[tokio::test]
async fn admin_replicas_syncing_filter_includes_replicating_status() {
    let state = common::test_state();

    let vm_aws = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-aws-1.flapjack.foo".into(),
            flapjack_url: "https://vm-aws-1.flapjack.foo:7700".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    let vm_hetzner = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "eu-central-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-hetzner-1.flapjack.foo".into(),
            flapjack_url: "https://vm-hetzner-1.flapjack.foo:7700".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    let customer_id = Uuid::new_v4();

    // A modern "syncing" replica
    let r_syncing = state
        .index_replica_repo
        .create(
            customer_id,
            "products",
            vm_aws.id,
            vm_hetzner.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    state
        .index_replica_repo
        .set_status(r_syncing.id, "syncing")
        .await
        .unwrap();

    // A legacy "replicating" replica (semantically the same as syncing)
    let r_replicating = state
        .index_replica_repo
        .create(customer_id, "orders", vm_hetzner.id, vm_aws.id, "us-east-1")
        .await
        .unwrap();
    state
        .index_replica_repo
        .set_status(r_replicating.id, "replicating")
        .await
        .unwrap();

    // An active replica that should NOT appear in ?status=syncing
    let r_active = state
        .index_replica_repo
        .create(
            customer_id,
            "logs",
            vm_aws.id,
            vm_hetzner.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    state
        .index_replica_repo
        .set_status(r_active.id, "active")
        .await
        .unwrap();

    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/replicas?status=syncing")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(
        arr.len(),
        2,
        "?status=syncing should include both 'syncing' and 'replicating' replicas"
    );

    let ids: Vec<&str> = arr.iter().map(|r| r["id"].as_str().unwrap()).collect();
    assert!(
        ids.contains(&r_syncing.id.to_string().as_str()),
        "syncing replica present"
    );
    assert!(
        ids.contains(&r_replicating.id.to_string().as_str()),
        "legacy replicating replica present"
    );
    assert!(
        !ids.contains(&r_active.id.to_string().as_str()),
        "active replica excluded"
    );
}

#[tokio::test]
async fn admin_replicas_empty_when_none_exist() {
    let state = common::test_state();
    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/replicas")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 0);
}

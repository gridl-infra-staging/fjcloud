mod common;

use api::models::vm_inventory::NewVmInventory;
use api::provisioner::region_map::{RegionConfig, RegionEntry};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use std::collections::HashMap;
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn regions(entry: &serde_json::Value) -> Vec<&str> {
    entry["regions"]
        .as_array()
        .expect("regions should be an array")
        .iter()
        .map(|region| region.as_str().expect("region should be a string"))
        .collect()
}

#[tokio::test]
async fn admin_providers_endpoint_returns_summary() {
    let state = common::test_state();

    state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".into(),
            provider: "aws".into(),
            hostname: "vm-aws-1.flapjack.foo".into(),
            flapjack_url: "https://vm-aws-1.flapjack.foo".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "eu-central-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-hetzner-1.flapjack.foo".into(),
            flapjack_url: "https://vm-hetzner-1.flapjack.foo".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    let inactive_hetzner = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "us-west-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-hetzner-2.flapjack.foo".into(),
            flapjack_url: "https://vm-hetzner-2.flapjack.foo".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();
    state
        .vm_inventory_repo
        .set_status(inactive_hetzner.id, "decommissioned")
        .await
        .unwrap();

    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/providers")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2, "aws + hetzner should be summarized");

    let aws = arr
        .iter()
        .find(|entry| entry["provider"] == "aws")
        .expect("aws entry should exist");
    assert_eq!(aws["region_count"], 2);
    assert_eq!(aws["vm_count"], 1);
    assert_eq!(regions(aws), vec!["eu-west-1", "us-east-1"]);

    let hetzner = arr
        .iter()
        .find(|entry| entry["provider"] == "hetzner")
        .expect("hetzner entry should exist");
    assert_eq!(hetzner["region_count"], 4);
    assert_eq!(hetzner["vm_count"], 1);
    assert_eq!(
        regions(hetzner),
        vec!["eu-central-1", "eu-north-1", "us-east-2", "us-west-1"]
    );
}

#[tokio::test]
async fn admin_providers_includes_configured_provider_with_zero_active_vms() {
    let state = common::test_state();

    state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: "eu-central-1".into(),
            provider: "hetzner".into(),
            hostname: "vm-hetzner-1.flapjack.foo".into(),
            flapjack_url: "https://vm-hetzner-1.flapjack.foo".into(),
            capacity: serde_json::json!({"cpu_cores": 4, "ram_mb": 8192, "disk_gb": 100}),
        })
        .await
        .unwrap();

    let app = api::router::build_router(state);

    let req = Request::builder()
        .uri("/admin/providers")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2, "default region config has aws + hetzner");

    let aws = arr
        .iter()
        .find(|entry| entry["provider"] == "aws")
        .expect("aws entry should exist even with no active VMs");
    assert_eq!(aws["region_count"], 2);
    assert_eq!(aws["vm_count"], 0);
    assert_eq!(regions(aws), vec!["eu-west-1", "us-east-1"]);
}

#[tokio::test]
async fn admin_providers_includes_unavailable_configured_provider_regions() {
    let mut state = common::test_state();

    let mut custom_regions = HashMap::new();
    custom_regions.insert(
        "us-east-1".to_string(),
        RegionEntry {
            provider: "aws".to_string(),
            provider_location: "us-east-1".to_string(),
            display_name: "US East (Virginia)".to_string(),
            available: false,
        },
    );
    custom_regions.insert(
        "eu-central-1".to_string(),
        RegionEntry {
            provider: "hetzner".to_string(),
            provider_location: "fsn1".to_string(),
            display_name: "EU Central (Germany)".to_string(),
            available: true,
        },
    );
    state.region_config = RegionConfig::from_regions(custom_regions);

    let app = api::router::build_router(state);
    let req = Request::builder()
        .uri("/admin/providers")
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
        "configured providers should be listed even when their regions are unavailable"
    );

    let aws = arr
        .iter()
        .find(|entry| entry["provider"] == "aws")
        .expect("aws entry should exist");
    assert_eq!(aws["region_count"], 1);
    assert_eq!(aws["vm_count"], 0);
    assert_eq!(regions(aws), vec!["us-east-1"]);
}

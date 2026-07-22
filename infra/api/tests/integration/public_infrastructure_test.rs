use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use tower::ServiceExt;

use api::models::NewVmInventory;
use api::repos::{DeploymentRepo, TenantRepo, VmInventoryRepo};

const SENTINEL_HOSTNAME: &str = "SENTINEL-HOSTNAME-DO-NOT-LEAK.internal";
const SENTINEL_URL: &str = "http://10.11.12.13:7700";
const SENTINEL_IP: &str = "10.11.12.13";
const SENTINEL_CAPACITY: u64 = 424_242_424_242;

fn capacity(cpu_weight: f64, mem_rss_bytes: u64, disk_bytes: u64) -> Value {
    json!({
        "cpu_weight": cpu_weight,
        "mem_rss_bytes": mem_rss_bytes,
        "disk_bytes": disk_bytes,
        "query_rps": cpu_weight,
        "indexing_rps": cpu_weight,
    })
}

fn load(ratio: f64) -> Value {
    json!({
        "cpu_weight": 100.0 * ratio,
        "mem_rss_bytes": (10_000_u64 as f64 * ratio) as u64,
        "disk_bytes": (10_000_u64 as f64 * ratio) as u64,
        "query_rps": 100.0 * ratio,
        "indexing_rps": 100.0 * ratio,
    })
}

struct VmSeed<'a> {
    region: &'a str,
    hostname: &'a str,
    flapjack_url: &'a str,
    capacity: Value,
}

async fn seed_vm(
    vm_repo: &crate::common::MockVmInventoryRepo,
    tenant_repo: &crate::common::MockTenantRepo,
    deployment_repo: &crate::common::MockDeploymentRepo,
    seed: VmSeed<'_>,
) {
    let customer_id = uuid::Uuid::new_v4();
    let deployment = deployment_repo.seed_provisioned(
        customer_id,
        seed.hostname,
        seed.region,
        "shared",
        "aws",
        "running",
        Some(seed.flapjack_url),
    );
    deployment_repo
        .update_health(deployment.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();
    let vm = vm_repo
        .create(NewVmInventory {
            region: seed.region.to_string(),
            provider: "aws".to_string(),
            hostname: seed.hostname.to_string(),
            flapjack_url: seed.flapjack_url.to_string(),
            capacity: seed.capacity,
        })
        .await
        .unwrap();
    vm_repo.update_load(vm.id, load(0.25)).await.unwrap();
    tenant_repo
        .create(customer_id, &format!("tenant-{}", vm.id), deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, &format!("tenant-{}", vm.id), vm.id)
        .await
        .unwrap();
}

async fn get_public_infrastructure(app: axum::Router) -> (StatusCode, Value, String) {
    let response = app
        .oneshot(
            Request::builder()
                .uri("/public/infrastructure")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let text = String::from_utf8(bytes.to_vec()).unwrap();
    let json = serde_json::from_str(&text).unwrap_or_else(|error| {
        panic!("response body must be JSON, got {text}: {error}");
    });
    (status, json, text)
}

#[tokio::test]
async fn public_infrastructure_never_leaks_per_machine_detail() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();

    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "us-east-1",
            hostname: SENTINEL_HOSTNAME,
            flapjack_url: SENTINEL_URL,
            capacity: capacity(
                SENTINEL_CAPACITY as f64,
                SENTINEL_CAPACITY,
                SENTINEL_CAPACITY,
            ),
        },
    )
    .await;
    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "us-east-1",
            hostname: "public-vm-2.internal",
            flapjack_url: "http://public-vm-2.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
        },
    )
    .await;
    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "eu-central-1",
            hostname: "public-vm-3.internal",
            flapjack_url: "http://public-vm-3.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
        },
    )
    .await;
    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "moon-1",
            hostname: "hidden-vm.internal",
            flapjack_url: "http://hidden-vm.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
        },
    )
    .await;

    let app = crate::common::TestStateBuilder::new()
        .with_vm_inventory_repo(vm_repo)
        .with_tenant_repo(tenant_repo)
        .with_deployment_repo(deployment_repo)
        .build_app();

    let (status, body, text) = get_public_infrastructure(app).await;
    assert_eq!(status, StatusCode::OK);

    let regions = body["regions"].as_array().unwrap();
    assert_eq!(regions.len(), 6, "all configured regions remain present");
    let nonzero_regions = regions
        .iter()
        .filter(|region| region["vm_count"].as_u64().unwrap() > 0)
        .collect::<Vec<_>>();
    assert_eq!(nonzero_regions.len(), 2);
    let row_sum = regions
        .iter()
        .map(|region| region["vm_count"].as_u64().unwrap())
        .sum::<u64>();
    assert_eq!(row_sum, 3);
    assert_eq!(body["overall"]["total_vms"], row_sum);
    assert_eq!(body["overall"]["total_regions"], 6);

    assert!(
        regions.iter().all(|region| region["region"] != "moon-1"),
        "unconfigured region must not appear as a row: {body}"
    );
    assert_eq!(
        body["overall"]["total_vms"], 3,
        "unconfigured VMs must not create hidden denominator contributions"
    );

    for sentinel in [
        SENTINEL_HOSTNAME,
        SENTINEL_URL,
        SENTINEL_IP,
        "424242424242",
        "hidden-vm.internal",
    ] {
        assert!(
            !text.contains(sentinel),
            "public infrastructure leaked sentinel {sentinel}: {text}"
        );
    }

    for region in regions {
        let keys = region
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>();
        assert_eq!(
            keys,
            BTreeSet::from([
                "display_name".to_string(),
                "health".to_string(),
                "provider".to_string(),
                "provider_location".to_string(),
                "region".to_string(),
                "utilization".to_string(),
                "vm_count".to_string(),
            ])
        );
        assert!(
            region.get("vms").is_none() && region.get("machines").is_none(),
            "region must not expose per-machine collections: {region}"
        );
    }
}

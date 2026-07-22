use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Utc};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::sync::Arc;
use tower::ServiceExt;

use api::models::{Deployment, NewVmInventory, VmInventory};
use api::provisioner::region_map::{RegionConfig, RegionEntry};
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
        "mem_rss_bytes": (10_000_f64 * ratio) as u64,
        "disk_bytes": (10_000_f64 * ratio) as u64,
        "query_rps": 100.0 * ratio,
        "indexing_rps": 100.0 * ratio,
    })
}

struct VmSeed<'a> {
    region: &'a str,
    hostname: &'a str,
    flapjack_url: &'a str,
    capacity: Value,
    deployment_status: &'a str,
    create_tenant: bool,
}

async fn seed_vm(
    vm_repo: &crate::common::MockVmInventoryRepo,
    tenant_repo: &crate::common::MockTenantRepo,
    deployment_repo: &crate::common::MockDeploymentRepo,
    seed: VmSeed<'_>,
) -> (VmInventory, Deployment) {
    let customer_id = uuid::Uuid::new_v4();
    let deployment = deployment_repo.seed_provisioned(
        customer_id,
        seed.hostname,
        seed.region,
        "shared",
        "aws",
        seed.deployment_status,
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
    if seed.create_tenant {
        tenant_repo
            .create(customer_id, &format!("tenant-{}", vm.id), deployment.id)
            .await
            .unwrap();
        tenant_repo
            .set_vm_id(customer_id, &format!("tenant-{}", vm.id), vm.id)
            .await
            .unwrap();
    }
    (vm, deployment)
}

fn fixed_now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-07-22T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn two_region_config() -> RegionConfig {
    RegionConfig::from_regions(HashMap::from([
        (
            "alpha-1".to_string(),
            RegionEntry {
                provider: "aws".to_string(),
                provider_location: "alpha-location".to_string(),
                display_name: "Alpha Region".to_string(),
                available: true,
            },
        ),
        (
            "zeta-1".to_string(),
            RegionEntry {
                provider: "hetzner".to_string(),
                provider_location: "zeta-location".to_string(),
                display_name: "Zeta Region".to_string(),
                available: true,
            },
        ),
    ]))
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

fn public_infrastructure_repo_counts(
    vm_repo: &crate::common::MockVmInventoryRepo,
    tenant_repo: &crate::common::MockTenantRepo,
    deployment_repo: &crate::common::MockDeploymentRepo,
) -> (usize, usize, usize, usize, usize) {
    (
        vm_repo.list_active_call_count(),
        tenant_repo.list_by_vms_call_count(),
        deployment_repo.find_by_ids_call_count(),
        tenant_repo.list_by_vm_call_count(),
        deployment_repo.find_by_id_call_count(),
    )
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
            deployment_status: "running",
            create_tenant: true,
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
            deployment_status: "running",
            create_tenant: true,
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
            deployment_status: "running",
            create_tenant: true,
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
            deployment_status: "running",
            create_tenant: true,
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

#[tokio::test]
async fn uncached_compute_uses_exactly_three_bulk_round_trips() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let mut seeded_vms = Vec::new();
    let mut seeded_deployments = Vec::new();

    for (index, region) in [
        "us-east-1",
        "us-east-1",
        "eu-central-1",
        "eu-central-1",
        "eu-central-1",
    ]
    .into_iter()
    .enumerate()
    {
        let hostname = format!("bulk-vm-{index}.internal");
        let flapjack_url = format!("http://bulk-vm-{index}.internal:7700");
        let (vm, deployment) = seed_vm(
            &vm_repo,
            &tenant_repo,
            &deployment_repo,
            VmSeed {
                region,
                hostname: &hostname,
                flapjack_url: &flapjack_url,
                capacity: capacity(100.0, 10_000, 10_000),
                deployment_status: "running",
                create_tenant: true,
            },
        )
        .await;
        vm_repo.set_load_scraped_at(vm.id, Some(fixed_now()));
        seeded_vms.push(vm);
        seeded_deployments.push(deployment);
    }

    let shared_deployment_id = seeded_deployments[0].id;
    for vm in &seeded_vms[1..] {
        let customer_id = uuid::Uuid::new_v4();
        let tenant_id = format!("shared-deployment-tenant-{}", vm.id);
        tenant_repo
            .create(customer_id, &tenant_id, shared_deployment_id)
            .await
            .unwrap();
        tenant_repo
            .set_vm_id(customer_id, &tenant_id, vm.id)
            .await
            .unwrap();
    }

    let state = crate::common::TestStateBuilder::new()
        .with_vm_inventory_repo(vm_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .with_deployment_repo(deployment_repo.clone())
        .build();

    api::routes::public_infrastructure::compute_public_infrastructure(
        state.vm_inventory_repo.as_ref(),
        state.tenant_repo.as_ref(),
        state.deployment_repo.as_ref(),
        &state.region_config,
        fixed_now(),
    )
    .await
    .unwrap();

    assert_eq!(vm_repo.list_active_call_count(), 1);
    assert_eq!(
        tenant_repo.list_by_vm_call_count(),
        0,
        "legacy tenant lookups must be eliminated; tenant_bulk={}, deployment_legacy={}, deployment_bulk={}",
        tenant_repo.list_by_vms_call_count(),
        deployment_repo.find_by_id_call_count(),
        deployment_repo.find_by_ids_call_count()
    );
    assert_eq!(
        deployment_repo.find_by_id_call_count(),
        0,
        "legacy deployment lookups must be eliminated; bulk calls={}",
        deployment_repo.find_by_ids_call_count()
    );
    assert_eq!(tenant_repo.list_by_vms_call_count(), 1);
    assert_eq!(deployment_repo.find_by_ids_call_count(), 1);
}

#[tokio::test]
async fn bulk_repository_mocks_omit_missing_unique_inputs_without_legacy_fanout() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();

    let (vm, deployment) = seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "us-east-1",
            hostname: "duplicate-contract.internal",
            flapjack_url: "http://duplicate-contract.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "running",
            create_tenant: true,
        },
    )
    .await;

    let missing_vm_id = uuid::Uuid::new_v4();
    let repeated_tenants = tenant_repo
        .list_by_vms(&[vm.id, missing_vm_id])
        .await
        .unwrap();
    assert_eq!(
        repeated_tenants.len(),
        1,
        "bulk tenant mocks must return matching unique VM rows and omit missing VMs"
    );
    assert!(repeated_tenants
        .iter()
        .all(|tenant| tenant.vm_id == Some(vm.id)));
    assert_eq!(tenant_repo.list_by_vms_call_count(), 1);
    assert_eq!(
        tenant_repo.list_by_vm_call_count(),
        0,
        "bulk tenant mock must not call the legacy single-VM method"
    );

    let missing_deployment_id = uuid::Uuid::new_v4();
    let repeated_deployments = deployment_repo
        .find_by_ids(&[deployment.id, missing_deployment_id])
        .await
        .unwrap();
    assert_eq!(
        repeated_deployments
            .iter()
            .map(|deployment| deployment.id)
            .collect::<Vec<_>>(),
        vec![deployment.id],
        "bulk deployment mocks must return matching unique deployments and omit missing IDs"
    );
    assert_eq!(deployment_repo.find_by_ids_call_count(), 1);
    assert_eq!(
        deployment_repo.find_by_id_call_count(),
        0,
        "bulk deployment mock must not call the legacy single-ID method"
    );
}

#[tokio::test]
async fn public_infrastructure_json_matches_preoptimization_contract() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();

    let (terminated_vm, _) = seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "alpha-1",
            hostname: "terminated-but-healthy.internal",
            flapjack_url: "http://terminated-but-healthy.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "terminated",
            create_tenant: true,
        },
    )
    .await;
    let (tenantless_vm, _) = seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "zeta-1",
            hostname: "tenantless.internal",
            flapjack_url: "http://tenantless.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "running",
            create_tenant: false,
        },
    )
    .await;
    vm_repo.set_load_scraped_at(terminated_vm.id, Some(fixed_now()));
    vm_repo.set_load_scraped_at(tenantless_vm.id, Some(fixed_now()));

    let state = crate::common::TestStateBuilder::new()
        .with_vm_inventory_repo(vm_repo)
        .with_tenant_repo(tenant_repo)
        .with_deployment_repo(deployment_repo)
        .build();
    let response = api::routes::public_infrastructure::compute_public_infrastructure(
        state.vm_inventory_repo.as_ref(),
        state.tenant_repo.as_ref(),
        state.deployment_repo.as_ref(),
        &two_region_config(),
        fixed_now(),
    )
    .await
    .unwrap();

    assert_eq!(
        serde_json::to_value(response).unwrap(),
        json!({
            "regions": [
                {
                    "region": "alpha-1",
                    "provider": "aws",
                    "display_name": "Alpha Region",
                    "provider_location": "alpha-location",
                    "health": "operational",
                    "utilization": null,
                    "vm_count": 1
                },
                {
                    "region": "zeta-1",
                    "provider": "hetzner",
                    "display_name": "Zeta Region",
                    "provider_location": "zeta-location",
                    "health": "outage",
                    "utilization": null,
                    "vm_count": 1
                }
            ],
            "overall": {
                "availability_pct": 50.0,
                "total_regions": 2,
                "total_vms": 2
            }
        })
    );
}

#[tokio::test]
async fn empty_published_inventory_skips_bulk_fetches() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();

    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "unpublished-1",
            hostname: "unpublished-vm.internal",
            flapjack_url: "http://unpublished-vm.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "running",
            create_tenant: true,
        },
    )
    .await;

    let app = crate::common::TestStateBuilder::new()
        .with_region_config(two_region_config())
        .with_vm_inventory_repo(vm_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .with_deployment_repo(deployment_repo.clone())
        .build_app();

    let (status, body, _) = get_public_infrastructure(app).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({
            "regions": [
                {
                    "region": "alpha-1",
                    "provider": "aws",
                    "display_name": "Alpha Region",
                    "provider_location": "alpha-location",
                    "health": "unknown",
                    "utilization": null,
                    "vm_count": 0
                },
                {
                    "region": "zeta-1",
                    "provider": "hetzner",
                    "display_name": "Zeta Region",
                    "provider_location": "zeta-location",
                    "health": "unknown",
                    "utilization": null,
                    "vm_count": 0
                }
            ],
            "overall": {
                "availability_pct": null,
                "total_regions": 2,
                "total_vms": 0
            }
        })
    );
    assert_eq!(vm_repo.list_active_call_count(), 1);
    assert_eq!(tenant_repo.list_by_vm_call_count(), 0);
    assert_eq!(tenant_repo.list_by_vms_call_count(), 0);
    assert_eq!(deployment_repo.find_by_id_call_count(), 0);
    assert_eq!(deployment_repo.find_by_ids_call_count(), 0);
}

#[tokio::test]
async fn second_request_within_ttl_uses_cached_response() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "us-east-1",
            hostname: "cached-vm.internal",
            flapjack_url: "http://cached-vm.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "running",
            create_tenant: true,
        },
    )
    .await;

    let app = crate::common::TestStateBuilder::new()
        .with_vm_inventory_repo(vm_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .with_deployment_repo(deployment_repo.clone())
        .build_app();

    let (first_status, first_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(first_status, StatusCode::OK);
    let first_repo_counts =
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo);
    assert_eq!(
        first_repo_counts,
        (1, 1, 1, 0, 0),
        "first request must use VM/bulk-tenant/bulk-deployment once and no legacy fan-out"
    );

    let (second_status, second_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(second_status, StatusCode::OK);
    assert_eq!(second_body, first_body);
    let second_repo_counts =
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo);
    assert_eq!(
        second_repo_counts, first_repo_counts,
        "second request must reuse the first response"
    );
}

#[tokio::test]
async fn forced_cache_expiry_recomputes_exactly_once() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    seed_vm(
        &vm_repo,
        &tenant_repo,
        &deployment_repo,
        VmSeed {
            region: "us-east-1",
            hostname: "expiry-vm.internal",
            flapjack_url: "http://expiry-vm.internal:7700",
            capacity: capacity(100.0, 10_000, 10_000),
            deployment_status: "running",
            create_tenant: true,
        },
    )
    .await;
    let cache = Arc::new(api::state::PublicInfrastructureCache::default());

    let app = crate::common::TestStateBuilder::new()
        .with_public_infrastructure_cache(cache.clone())
        .with_vm_inventory_repo(vm_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .with_deployment_repo(deployment_repo.clone())
        .build_app();

    let (first_status, first_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(first_status, StatusCode::OK);
    assert_eq!(
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo),
        (1, 1, 1, 0, 0)
    );

    let (second_status, second_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(second_status, StatusCode::OK);
    assert_eq!(second_body, first_body);
    assert_eq!(
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo),
        (1, 1, 1, 0, 0)
    );

    cache.expire_for_test();
    let (third_status, third_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(third_status, StatusCode::OK);
    assert_eq!(third_body, first_body);
    assert_eq!(
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo),
        (2, 2, 2, 0, 0)
    );
}

#[tokio::test]
async fn repository_error_is_retried_not_cached() {
    let vm_repo = crate::common::mock_vm_inventory_repo();
    let tenant_repo = crate::common::mock_tenant_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    vm_repo.set_should_fail(true);

    let app = crate::common::TestStateBuilder::new()
        .with_region_config(two_region_config())
        .with_vm_inventory_repo(vm_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .with_deployment_repo(deployment_repo.clone())
        .build_app();

    let (first_status, first_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(first_status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(first_body, json!({ "error": "internal server error" }));
    assert_eq!(
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo),
        (1, 0, 0, 0, 0)
    );

    vm_repo.set_should_fail(false);
    let (second_status, second_body, _) = get_public_infrastructure(app.clone()).await;
    assert_eq!(second_status, StatusCode::OK);
    assert_eq!(
        second_body,
        json!({
            "regions": [
                {
                    "region": "alpha-1",
                    "provider": "aws",
                    "display_name": "Alpha Region",
                    "provider_location": "alpha-location",
                    "health": "unknown",
                    "utilization": null,
                    "vm_count": 0
                },
                {
                    "region": "zeta-1",
                    "provider": "hetzner",
                    "display_name": "Zeta Region",
                    "provider_location": "zeta-location",
                    "health": "unknown",
                    "utilization": null,
                    "vm_count": 0
                }
            ],
            "overall": {
                "availability_pct": null,
                "total_regions": 2,
                "total_vms": 0
            }
        })
    );
    assert_eq!(
        public_infrastructure_repo_counts(&vm_repo, &tenant_repo, &deployment_repo),
        (2, 0, 0, 0, 0)
    );
}

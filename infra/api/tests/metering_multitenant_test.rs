mod common;

use api::provisioner::region_map::RegionConfig;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{mock_flapjack_proxy, mock_repo, MockTenantRepo};
use http_body_util::BodyExt;
use std::collections::HashSet;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

fn internal_get(path: &str) -> Request<Body> {
    Request::builder()
        .uri(path)
        .header("x-internal-key", common::TEST_INTERNAL_AUTH_TOKEN)
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn tenant_map_endpoint_returns_all_active_tenants() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("Alice", "alice@example.com");
    let customer_b = customer_repo.seed("Bob", "bob@example.com");

    let deployment_repo = common::mock_deployment_repo();

    let dep_a = deployment_repo.seed_provisioned(
        customer_a.id,
        "node-a",
        "us-east-1",
        "t4g.medium",
        "aws",
        "running",
        Some("https://vm-a.flapjack.foo"),
    );
    let dep_b = deployment_repo.seed_provisioned(
        customer_b.id,
        "node-b",
        "us-east-1",
        "t4g.medium",
        "aws",
        "running",
        Some("https://vm-b.flapjack.foo"),
    );
    let dep_terminated = deployment_repo.seed_provisioned(
        customer_a.id,
        "node-z",
        "us-east-1",
        "t4g.medium",
        "aws",
        "terminated",
        Some("https://vm-z.flapjack.foo"),
    );

    let tenant_repo: Arc<MockTenantRepo> = Arc::new(MockTenantRepo::new());
    tenant_repo.seed_deployment(
        dep_a.id,
        &dep_a.region,
        dep_a.flapjack_url.as_deref(),
        &dep_a.health_status,
        &dep_a.status,
    );
    tenant_repo.seed_deployment(
        dep_b.id,
        &dep_b.region,
        dep_b.flapjack_url.as_deref(),
        &dep_b.health_status,
        &dep_b.status,
    );
    tenant_repo.seed_deployment(
        dep_terminated.id,
        &dep_terminated.region,
        dep_terminated.flapjack_url.as_deref(),
        &dep_terminated.health_status,
        &dep_terminated.status,
    );

    tenant_repo
        .create(customer_a.id, "products", dep_a.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_b.id, "orders", dep_b.id)
        .await
        .unwrap();
    tenant_repo
        .create(customer_a.id, "old-index", dep_terminated.id)
        .await
        .unwrap();

    let vm_a = Uuid::new_v4();
    let vm_b = Uuid::new_v4();
    tenant_repo
        .set_vm_id(customer_a.id, "products", vm_a)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_b.id, "orders", vm_b)
        .await
        .unwrap();

    let app = common::test_app_with_indexes(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
    );

    let req = internal_get("/internal/tenant-map");

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let arr = json
        .as_array()
        .expect("tenant map response should be an array");

    assert_eq!(
        arr.len(),
        2,
        "terminated deployment tenant must be excluded"
    );

    let products = arr
        .iter()
        .find(|entry| entry["tenant_id"] == "products")
        .expect("products entry should be present");
    assert_eq!(products["customer_id"], customer_a.id.to_string());
    assert_eq!(products["vm_id"], vm_a.to_string());
    assert_eq!(products["flapjack_url"], "https://vm-a.flapjack.foo");
    assert_eq!(
        products["flapjack_uid"],
        format!("{}_products", customer_a.id.as_simple())
    );

    let orders = arr
        .iter()
        .find(|entry| entry["tenant_id"] == "orders")
        .expect("orders entry should be present");
    assert_eq!(orders["customer_id"], customer_b.id.to_string());
    assert_eq!(orders["vm_id"], vm_b.to_string());
    assert_eq!(orders["flapjack_url"], "https://vm-b.flapjack.foo");
    assert_eq!(
        orders["flapjack_uid"],
        format!("{}_orders", customer_b.id.as_simple())
    );

    assert!(arr.iter().all(|entry| entry["tenant_id"] != "old-index"));
}

/// Contract test: when a tenant is attached to a shared VM via the seeded
/// flow (`POST /admin/tenants/:id/indexes` with `flapjack_url`), the
/// deployment row has `flapjack_url=NULL` and the routable URL lives on
/// `vm_inventory`. The `/internal/tenant-map` endpoint must fall back to
/// the VM's URL so the metering agent on the shared VM doesn't filter the
/// tenant out (it skips entries whose flapjack_url is None or doesn't
/// match the local URL). Without this fallback, `usage_records` for
/// shared-VM tenants is never written.
#[tokio::test]
async fn tenant_map_falls_back_to_vm_inventory_url_when_deployment_has_none() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Carol", "carol@example.com");

    let deployment_repo = common::mock_deployment_repo();
    // Provision the deployment with flapjack_url = None — this is the
    // seeded shared-VM contract from admin/indexes.rs::seed_index, which
    // delegates routable-URL ownership to vm_inventory.
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "e2e-node-shared",
        "us-east-1",
        "t4g.medium",
        api::vm_providers::BARE_METAL_VM_PROVIDER,
        "running",
        None,
    );

    let vm_inventory_repo = common::mock_vm_inventory_repo();
    let vm = vm_inventory_repo
        .create(api::models::vm_inventory::NewVmInventory {
            region: "us-east-1".into(),
            provider: api::vm_providers::BARE_METAL_VM_PROVIDER.into(),
            hostname: "vm-shared-aaaaaaaa.flapjack.foo".into(),
            flapjack_url: "http://vm-shared-aaaaaaaa.flapjack.foo:7700".into(),
            capacity: serde_json::json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .unwrap();

    let tenant_repo: Arc<MockTenantRepo> = Arc::new(MockTenantRepo::new());
    tenant_repo.seed_deployment(
        deployment.id,
        &deployment.region,
        deployment.flapjack_url.as_deref(),
        &deployment.health_status,
        &deployment.status,
    );
    tenant_repo
        .create(customer.id, "demo-shared-free", deployment.id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer.id, "demo-shared-free", vm.id)
        .await
        .unwrap();

    let app = common::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
        vm_inventory_repo,
    );

    let req = internal_get("/internal/tenant-map");
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let arr = json
        .as_array()
        .expect("tenant map response should be an array");

    let entry = arr
        .iter()
        .find(|e| e["tenant_id"] == "demo-shared-free")
        .expect("seeded shared-VM tenant should appear in tenant-map");
    assert_eq!(
        entry["flapjack_url"], "http://vm-shared-aaaaaaaa.flapjack.foo:7700",
        "tenant-map must fall back to vm_inventory.flapjack_url when deployment.flapjack_url is null; otherwise the metering agent filters this tenant out and usage_records is never written"
    );
    assert_eq!(entry["vm_id"], vm.id.to_string());
}

/// Regression guard: when neither the deployment row nor any
/// `vm_inventory` row carries a routable `flapjack_url`, the
/// `tenant-map` fallback should leave `flapjack_url: null` rather than
/// fabricate one. The metering agent treats null as "drop the tenant"
/// (which is the legitimate behavior for an index that has not yet
/// been placed on a shared VM); a future regression that backfilled
/// some default placeholder would silently route writes to nowhere.
#[tokio::test]
async fn tenant_map_keeps_flapjack_url_null_when_neither_deployment_nor_vm_has_one() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Dave", "dave@example.com");

    let deployment_repo = common::mock_deployment_repo();
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "e2e-node-no-url",
        "us-east-1",
        "t4g.medium",
        api::vm_providers::BARE_METAL_VM_PROVIDER,
        "running",
        None,
    );

    let vm_inventory_repo = common::mock_vm_inventory_repo();
    // Note: NO vm_inventory row created here — tenant.vm_id is None,
    // so the fallback has nowhere to look.

    let tenant_repo: Arc<MockTenantRepo> = Arc::new(MockTenantRepo::new());
    tenant_repo.seed_deployment(
        deployment.id,
        &deployment.region,
        deployment.flapjack_url.as_deref(),
        &deployment.health_status,
        &deployment.status,
    );
    tenant_repo
        .create(customer.id, "demo-shared-free", deployment.id)
        .await
        .unwrap();
    // intentionally NOT linking via set_vm_id

    let app = common::test_app_with_indexes_and_vm_inventory(
        customer_repo,
        deployment_repo,
        tenant_repo,
        mock_flapjack_proxy(),
        vm_inventory_repo,
    );

    let req = internal_get("/internal/tenant-map");
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let arr = json.as_array().expect("array response");
    let entry = arr
        .iter()
        .find(|e| e["tenant_id"] == "demo-shared-free")
        .expect("tenant should still be present in the map");

    assert!(
        entry["flapjack_url"].is_null(),
        "flapjack_url should remain null when neither deployment nor vm has one; got {entry}"
    );
    assert!(
        entry["vm_id"].is_null(),
        "vm_id should remain null when set_vm_id was never called; got {entry}"
    );
}

#[tokio::test]
async fn internal_regions_endpoint_returns_available_regions() {
    let app = common::test_app();

    let req = internal_get("/internal/regions");

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let arr = json
        .as_array()
        .expect("regions response should be an array");

    assert_eq!(
        arr.len(),
        6,
        "default region config should expose 6 regions"
    );
    assert!(
        arr.iter()
            .all(|entry| entry["available"] == serde_json::Value::Bool(true)),
        "endpoint should only return available regions"
    );

    let us_east_1 = arr
        .iter()
        .find(|entry| entry["id"] == "us-east-1")
        .expect("us-east-1 should be present");
    assert_eq!(us_east_1["provider"], "aws");
    assert_eq!(us_east_1["provider_location"], "us-east-1");
    assert_eq!(us_east_1["display_name"], "US East (Virginia)");

    let eu_central_1 = arr
        .iter()
        .find(|entry| entry["id"] == "eu-central-1")
        .expect("eu-central-1 should be present");
    assert_eq!(eu_central_1["provider"], "hetzner");
    assert_eq!(eu_central_1["provider_location"], "fsn1");
    assert_eq!(eu_central_1["display_name"], "EU Central (Germany)");
}

#[tokio::test]
async fn internal_regions_endpoint_excludes_unconfigured_provider_regions() {
    let mut state = common::test_state();
    let providers: HashSet<String> = HashSet::from(["aws".to_string()]);
    state.region_config = RegionConfig::defaults().filter_to_providers(&providers);
    let app = api::router::build_router(state);

    let req = internal_get("/internal/regions");

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let arr = json
        .as_array()
        .expect("regions response should be an array");

    assert_eq!(arr.len(), 2, "only aws regions should be exposed");
    assert!(
        arr.iter().all(|entry| entry["provider"] == "aws"),
        "all returned regions should belong to configured providers"
    );
}

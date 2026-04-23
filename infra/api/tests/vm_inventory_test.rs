mod common;

use api::models::vm_inventory::NewVmInventory;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use chrono::{Duration, Utc};
use common::{mock_vm_inventory_repo, MockTenantRepo};
use std::sync::Arc;
use uuid::Uuid;

fn new_vm(region: &str, hostname: &str) -> NewVmInventory {
    NewVmInventory {
        region: region.to_string(),
        provider: "aws".to_string(),
        hostname: hostname.to_string(),
        flapjack_url: format!("https://{hostname}"),
        capacity: serde_json::json!({
            "cpu_weight": 4.0,
            "mem_rss_bytes": 8_589_934_592_u64,
            "disk_bytes": 107_374_182_400_u64,
            "query_rps": 500.0,
            "indexing_rps": 200.0,
        }),
    }
}

fn setup_tenant_repo() -> (Arc<MockTenantRepo>, Uuid, Uuid) {
    let repo = Arc::new(MockTenantRepo::new());
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("https://vm-abc.flapjack.foo"),
        "healthy",
        "running",
    );
    (repo, customer_id, deployment_id)
}

// ---- VmInventory repo tests ----

#[tokio::test]
async fn vm_inventory_create_and_get() {
    let repo = mock_vm_inventory_repo();
    let vm = repo
        .create(new_vm("us-east-1", "vm-001.flapjack.foo"))
        .await
        .unwrap();

    assert_eq!(vm.region, "us-east-1");
    assert_eq!(vm.provider, "aws");
    assert_eq!(vm.hostname, "vm-001.flapjack.foo");
    assert_eq!(vm.status, "active");
    assert_eq!(vm.load_scraped_at, None);

    let fetched = repo.get(vm.id).await.unwrap().expect("should exist");
    assert_eq!(fetched.id, vm.id);
    assert_eq!(fetched.hostname, "vm-001.flapjack.foo");
    assert_eq!(fetched.load_scraped_at, None);
}

#[tokio::test]
async fn vm_inventory_new_vm_has_null_load_scraped_at() {
    let repo = mock_vm_inventory_repo();
    let vm = repo
        .create(new_vm("us-east-1", "vm-fresh.flapjack.foo"))
        .await
        .unwrap();

    assert_eq!(
        vm.load_scraped_at, None,
        "newly created VM should start with load_scraped_at=NULL until first scrape"
    );
}

#[tokio::test]
async fn vm_inventory_list_active_filters_by_region() {
    let repo = mock_vm_inventory_repo();
    repo.create(new_vm("us-east-1", "vm-east.flapjack.foo"))
        .await
        .unwrap();
    repo.create(new_vm("eu-west-1", "vm-eu.flapjack.foo"))
        .await
        .unwrap();
    repo.create(new_vm("us-east-1", "vm-east2.flapjack.foo"))
        .await
        .unwrap();

    let us_vms = repo.list_active(Some("us-east-1")).await.unwrap();
    assert_eq!(us_vms.len(), 2);
    assert!(us_vms.iter().all(|v| v.region == "us-east-1"));

    let all_vms = repo.list_active(None).await.unwrap();
    assert_eq!(all_vms.len(), 3);
}

#[tokio::test]
async fn vm_inventory_list_active_excludes_decommissioned() {
    let repo = mock_vm_inventory_repo();
    let vm1 = repo
        .create(new_vm("us-east-1", "vm-active.flapjack.foo"))
        .await
        .unwrap();
    let vm2 = repo
        .create(new_vm("us-east-1", "vm-decom.flapjack.foo"))
        .await
        .unwrap();

    repo.set_status(vm2.id, "decommissioned").await.unwrap();

    let active = repo.list_active(None).await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, vm1.id);
}

#[tokio::test]
async fn vm_inventory_update_load() {
    let repo = mock_vm_inventory_repo();
    let vm = repo
        .create(new_vm("us-east-1", "vm-load.flapjack.foo"))
        .await
        .unwrap();

    let load = serde_json::json!({
        "cpu_weight": 2.5,
        "mem_rss_bytes": 4_294_967_296_u64,
        "disk_bytes": 50_000_000_000_u64,
        "query_rps": 120.0,
        "indexing_rps": 45.0,
    });
    repo.update_load(vm.id, load.clone()).await.unwrap();

    let fetched = repo.get(vm.id).await.unwrap().unwrap();
    assert_eq!(fetched.current_load["cpu_weight"], 2.5);
    assert_eq!(fetched.current_load["mem_rss_bytes"], 4_294_967_296_u64);
    assert_eq!(fetched.current_load["disk_bytes"], 50_000_000_000_u64);
    assert_eq!(fetched.current_load["query_rps"], 120.0);
    assert_eq!(fetched.current_load["indexing_rps"], 45.0);
    let scraped_at = fetched
        .load_scraped_at
        .expect("load_scraped_at must be set by update_load");
    let age = Utc::now().signed_duration_since(scraped_at);
    assert!(
        age >= Duration::zero() && age < Duration::seconds(5),
        "load_scraped_at should be recent, got age={age:?}"
    );
}

#[tokio::test]
async fn vm_inventory_set_status() {
    let repo = mock_vm_inventory_repo();
    let vm = repo
        .create(new_vm("us-east-1", "vm-status.flapjack.foo"))
        .await
        .unwrap();
    assert_eq!(vm.status, "active");

    repo.set_status(vm.id, "draining").await.unwrap();
    let fetched = repo.get(vm.id).await.unwrap().unwrap();
    assert_eq!(fetched.status, "draining");

    repo.set_status(vm.id, "decommissioned").await.unwrap();
    let fetched = repo.get(vm.id).await.unwrap().unwrap();
    assert_eq!(fetched.status, "decommissioned");
}

#[tokio::test]
async fn vm_inventory_find_by_hostname() {
    let repo = mock_vm_inventory_repo();
    let vm = repo
        .create(new_vm("us-east-1", "vm-lookup.flapjack.foo"))
        .await
        .unwrap();

    let found = repo
        .find_by_hostname("vm-lookup.flapjack.foo")
        .await
        .unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, vm.id);

    let not_found = repo
        .find_by_hostname("nonexistent.flapjack.foo")
        .await
        .unwrap();
    assert!(not_found.is_none());
}

// ---- Tenant repo multi-tenancy tests ----

#[tokio::test]
async fn tenant_repo_set_vm_id_and_list_by_vm() {
    let (repo, customer_id, deployment_id) = setup_tenant_repo();
    let vm_id = Uuid::new_v4();

    repo.create(customer_id, "index-a", deployment_id)
        .await
        .unwrap();
    repo.create(customer_id, "index-b", deployment_id)
        .await
        .unwrap();

    // Assign vm_id to index-a only
    repo.set_vm_id(customer_id, "index-a", vm_id).await.unwrap();

    let on_vm = repo.list_by_vm(vm_id).await.unwrap();
    assert_eq!(on_vm.len(), 1);
    assert_eq!(on_vm[0].tenant_id, "index-a");
    assert_eq!(on_vm[0].vm_id, Some(vm_id));
}

#[tokio::test]
async fn tenant_repo_tier_transitions() {
    let (repo, customer_id, deployment_id) = setup_tenant_repo();

    repo.create(customer_id, "index-migrate", deployment_id)
        .await
        .unwrap();

    // Default tier is active
    let migrating = repo.list_migrating().await.unwrap();
    assert_eq!(migrating.len(), 0);

    // Transition to migrating
    repo.set_tier(customer_id, "index-migrate", "migrating")
        .await
        .unwrap();
    let migrating = repo.list_migrating().await.unwrap();
    assert_eq!(migrating.len(), 1);
    assert_eq!(migrating[0].tenant_id, "index-migrate");

    // Transition back to active
    repo.set_tier(customer_id, "index-migrate", "active")
        .await
        .unwrap();
    let migrating = repo.list_migrating().await.unwrap();
    assert_eq!(migrating.len(), 0);
}

#[tokio::test]
async fn tenant_repo_find_by_tenant_id_global() {
    let (repo, customer_id, deployment_id) = setup_tenant_repo();

    repo.create(customer_id, "global-lookup", deployment_id)
        .await
        .unwrap();

    // Look up by index name without knowing customer_id
    let found = repo
        .find_by_tenant_id_global("global-lookup")
        .await
        .unwrap();
    assert!(found.is_some());
    let summary = found.unwrap();
    assert_eq!(summary.tenant_id, "global-lookup");
    assert_eq!(summary.customer_id, customer_id);
    assert_eq!(summary.region, "us-east-1");

    // Non-existent index returns None
    let missing = repo
        .find_by_tenant_id_global("no-such-index")
        .await
        .unwrap();
    assert!(missing.is_none());
}

#[tokio::test]
async fn tenant_repo_find_raw_returns_vm_id_and_tier() {
    let (repo, customer_id, deployment_id) = setup_tenant_repo();
    let vm_id = Uuid::new_v4();

    repo.create(customer_id, "raw-idx", deployment_id)
        .await
        .unwrap();
    repo.set_vm_id(customer_id, "raw-idx", vm_id).await.unwrap();
    repo.set_tier(customer_id, "raw-idx", "pinned")
        .await
        .unwrap();

    let raw = repo
        .find_raw(customer_id, "raw-idx")
        .await
        .unwrap()
        .expect("should exist");
    assert_eq!(raw.vm_id, Some(vm_id));
    assert_eq!(raw.tier, "pinned");
    assert_eq!(raw.tenant_id, "raw-idx");

    // Non-existent returns None
    let missing = repo.find_raw(customer_id, "no-such").await.unwrap();
    assert!(missing.is_none());
}

#![allow(clippy::await_holding_lock)]

mod common;

use std::sync::{Arc, Mutex, OnceLock};

use api::models::vm_inventory::NewVmInventory;
use api::provisioner::region_map::RegionConfig;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::{InMemoryIndexReplicaRepo, IndexReplicaRepo};
use api::services::replica::{ReplicaError, ReplicaService};
use uuid::Uuid;

fn region_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    old_value: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let old_value = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, old_value }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.old_value {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

#[tokio::test]
async fn create_replica_rejects_unavailable_region() {
    let _lock = region_env_lock()
        .lock()
        .expect("region env lock should not be poisoned");
    let _region_guard = EnvVarGuard::set(
        "REGION_CONFIG",
        r#"{
          "us-east-1": {
            "provider": "aws",
            "provider_location": "us-east-1",
            "display_name": "US East",
            "available": true
          },
          "eu-central-1": {
            "provider": "hetzner",
            "provider_location": "fsn1",
            "display_name": "EU Central",
            "available": false
          }
        }"#,
    );

    let tenant_repo = common::mock_tenant_repo();
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();

    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-primary.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .expect("seed tenant");

    let primary_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-primary.flapjack.foo".to_string(),
            flapjack_url: "http://vm-primary.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed primary vm");
    tenant_repo
        .set_vm_id(customer_id, "products", primary_vm.id)
        .await
        .expect("assign primary vm");

    vm_repo
        .create(NewVmInventory {
            region: "eu-central-1".to_string(),
            provider: "hetzner".to_string(),
            hostname: "vm-replica.flapjack.foo".to_string(),
            flapjack_url: "http://vm-replica.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed replica vm");

    let replica_repo: Arc<dyn IndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let service = ReplicaService::new(
        replica_repo,
        tenant_repo.clone(),
        vm_repo.clone(),
        RegionConfig::from_env(),
    );

    let err = service
        .create_replica(customer_id, "products", "eu-central-1")
        .await
        .expect_err("unavailable region should be rejected");

    assert!(matches!(
        err,
        ReplicaError::RegionNotAvailable(ref region) if region == "eu-central-1"
    ));
}

#[tokio::test]
async fn create_replica_assigns_active_vm_in_target_region() {
    let tenant_repo = common::mock_tenant_repo();
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();

    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-primary.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .expect("seed tenant");

    let primary_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-primary.flapjack.foo".to_string(),
            flapjack_url: "http://vm-primary.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed primary vm");
    tenant_repo
        .set_vm_id(customer_id, "products", primary_vm.id)
        .await
        .expect("assign primary vm");

    let target_vm = vm_repo
        .create(NewVmInventory {
            region: "eu-central-1".to_string(),
            provider: "hetzner".to_string(),
            hostname: "vm-replica.flapjack.foo".to_string(),
            flapjack_url: "http://vm-replica.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed target vm");
    vm_repo
        .update_load(
            target_vm.id,
            serde_json::json!({
                "cpu_weight": 0.0,
                "mem_rss_bytes": 0_u64,
                "disk_bytes": 0_u64,
                "query_rps": 0.0,
                "indexing_rps": 0.0
            }),
        )
        .await
        .expect("mark target vm as freshly scraped for placement");

    let replica_repo: Arc<dyn IndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let service = ReplicaService::new(
        replica_repo.clone(),
        tenant_repo.clone(),
        vm_repo.clone(),
        RegionConfig::defaults(),
    );

    let replica = service
        .create_replica(customer_id, "products", "eu-central-1")
        .await
        .expect("replica should be created");

    assert_eq!(replica.customer_id, customer_id);
    assert_eq!(replica.tenant_id, "products");
    assert_eq!(replica.primary_vm_id, primary_vm.id);
    assert_eq!(replica.replica_vm_id, target_vm.id);
    assert_eq!(replica.replica_region, "eu-central-1");
    assert_eq!(replica.status, "provisioning");
}

#[tokio::test]
async fn create_replica_ignores_failed_replicas_for_limit() {
    let tenant_repo = common::mock_tenant_repo();
    let vm_repo = common::mock_vm_inventory_repo();
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();

    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-primary.flapjack.foo"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .expect("seed tenant");

    let primary_vm = vm_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "vm-primary.flapjack.foo".to_string(),
            flapjack_url: "http://vm-primary.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed primary vm");
    tenant_repo
        .set_vm_id(customer_id, "products", primary_vm.id)
        .await
        .expect("assign primary vm");

    let replica_repo: Arc<dyn IndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    for i in 0..5 {
        let failed_vm = vm_repo
            .create(NewVmInventory {
                region: "eu-north-1".to_string(),
                provider: "hetzner".to_string(),
                hostname: format!("vm-failed-{i}.flapjack.foo"),
                flapjack_url: format!("http://vm-failed-{i}.flapjack.foo"),
                capacity: serde_json::json!({
                    "cpu_weight": 100.0,
                    "mem_rss_bytes": 1_000_000_000_u64,
                    "disk_bytes": 10_000_000_000_u64,
                    "query_rps": 10_000.0,
                    "indexing_rps": 10_000.0
                }),
            })
            .await
            .expect("seed failed replica vm");

        let failed_replica = replica_repo
            .create(
                customer_id,
                "products",
                primary_vm.id,
                failed_vm.id,
                "eu-north-1",
            )
            .await
            .expect("create failed replica");
        replica_repo
            .set_status(failed_replica.id, "failed")
            .await
            .expect("mark replica failed");
    }

    let target_vm = vm_repo
        .create(NewVmInventory {
            region: "us-west-1".to_string(),
            provider: "hetzner".to_string(),
            hostname: "vm-new-replica.flapjack.foo".to_string(),
            flapjack_url: "http://vm-new-replica.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 1_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("seed target vm");
    vm_repo
        .update_load(
            target_vm.id,
            serde_json::json!({
                "cpu_weight": 0.0,
                "mem_rss_bytes": 0_u64,
                "disk_bytes": 0_u64,
                "query_rps": 0.0,
                "indexing_rps": 0.0
            }),
        )
        .await
        .expect("mark target vm as freshly scraped for placement");

    let service = ReplicaService::new(
        replica_repo.clone(),
        tenant_repo.clone(),
        vm_repo.clone(),
        RegionConfig::defaults(),
    );

    let replica = service
        .create_replica(customer_id, "products", "us-west-1")
        .await
        .expect("failed replicas should not consume replica limit");

    assert_eq!(replica.replica_vm_id, target_vm.id);
    assert_eq!(replica.replica_region, "us-west-1");
}

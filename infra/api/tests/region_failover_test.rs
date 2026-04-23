mod common;

use std::sync::Arc;
use std::time::Duration;

use api::models::vm_inventory::NewVmInventory;
use api::repos::tenant_repo::TenantRepo;
use api::repos::vm_inventory_repo::VmInventoryRepo;
use api::repos::{InMemoryIndexReplicaRepo, IndexReplicaRepo};
use api::services::region_failover::{
    RegionFailoverConfig, RegionFailoverMonitor, RegionHealthStatus,
};
use tokio::sync::watch;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn vm_seed(region: &str, provider: &str, hostname: &str) -> NewVmInventory {
    NewVmInventory {
        region: region.to_string(),
        provider: provider.to_string(),
        hostname: hostname.to_string(),
        flapjack_url: format!("http://{hostname}:7700"),
        capacity: serde_json::json!({
            "cpu_weight": 100.0,
            "mem_rss_bytes": 10_000_000_000_u64,
            "disk_bytes": 10_000_000_000_u64,
            "query_rps": 10_000.0,
            "indexing_rps": 10_000.0
        }),
    }
}

fn failover_config() -> RegionFailoverConfig {
    RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 3,
        recovery_threshold: 2,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// When all VMs in a region are healthy, the region status should be Healthy.
#[tokio::test]
async fn region_failover_healthy_region_stays_healthy() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Two healthy VMs in us-east-1
    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-2"))
        .await
        .unwrap();

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo,
        replica_repo,
        alert_service.clone(),
        failover_config(),
    );

    // Provide health results: all healthy
    monitor.run_cycle_with_health(|_url| true).await;

    let statuses = monitor.region_statuses();
    assert_eq!(
        statuses.get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );
    assert_eq!(alert_service.alert_count(), 0);
}

/// When all VMs in a region are unreachable for consecutive cycles exceeding
/// the unhealthy threshold, the region should transition to Down and trigger
/// failover: promoting replicas for affected indexes.
#[tokio::test]
async fn region_failover_promotes_replica_when_region_goes_down() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Primary region VMs
    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    // Healthy replica region VM
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    // Create a tenant on the primary region VM
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    // Create an active replica in eu-central-1
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 2, // faster for testing
        recovery_threshold: 2,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Cycle 1: us-east-1 VMs unhealthy, eu-central-1 healthy
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;

    // Not yet failed over (threshold=2)
    let statuses = monitor.region_statuses();
    assert_ne!(statuses.get("us-east-1"), Some(&RegionHealthStatus::Down));

    // Cycle 2: still unhealthy — should trigger failover
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;

    let statuses = monitor.region_statuses();
    assert_eq!(statuses.get("us-east-1"), Some(&RegionHealthStatus::Down));

    // Verify the tenant was failed over: vm_id should now point to the replica's VM
    let raw_tenant = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_tenant.vm_id, Some(vm_central.id));

    // Verify a critical alert was fired
    let alerts = alert_service.recorded_alerts();
    assert!(
        alerts.iter().any(|a| a.title.contains("Region down")),
        "expected 'Region down' alert, got: {:?}",
        alerts.iter().map(|a| &a.title).collect::<Vec<_>>()
    );
}

/// When a region recovers (VMs become healthy again), the monitor should
/// transition the region back to Healthy and fire a recovery alert.
/// The original primary assignment is NOT automatically restored (admin decision).
#[tokio::test]
async fn region_failover_recovery_fires_alert_without_automatic_switchback() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    let replica = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1, // immediate for testing
        recovery_threshold: 1,  // immediate recovery
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Cycle 1: region goes down, failover triggers
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );

    // Cycle 2: region recovers
    monitor.run_cycle_with_health(|_| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );

    // Verify recovery alert was fired
    let alerts = alert_service.recorded_alerts();
    assert!(
        alerts.iter().any(|a| a.title.contains("Region recovered")),
        "expected 'Region recovered' alert, got: {:?}",
        alerts.iter().map(|a| &a.title).collect::<Vec<_>>()
    );

    // The tenant should NOT be automatically switched back — stays on the failover VM
    let raw_tenant = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_tenant.vm_id, Some(vm_central.id));
}

/// When a region goes down but no replicas exist for affected indexes,
/// no failover should be attempted and a warning alert should be fired.
#[tokio::test]
async fn region_failover_no_replica_fires_warning_without_panic() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    // No replicas exist

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Region goes down
    monitor.run_cycle_with_health(|_| false).await;

    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );

    // Should fire a warning about no failover target
    let alerts = alert_service.recorded_alerts();
    assert!(
        alerts
            .iter()
            .any(|a| a.message.contains("no active replica")),
        "expected 'no active replica' warning, got: {:?}",
        alerts.iter().map(|a| &a.message).collect::<Vec<_>>()
    );
}

/// The failover monitor should only promote the lowest-lag active replica
/// for a given index (not just any replica).
#[tokio::test]
async fn region_failover_selects_lowest_lag_replica() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();
    let vm_north = vm_repo
        .create(vm_seed("eu-north-1", "hetzner", "vm-north-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    // High-lag replica in eu-central-1
    let replica_high = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(replica_high.id, "active")
        .await
        .unwrap();
    replica_repo.set_lag(replica_high.id, 5000).await.unwrap();

    // Low-lag replica in eu-north-1
    let replica_low = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_north.id,
            "eu-north-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(replica_low.id, "active")
        .await
        .unwrap();
    replica_repo.set_lag(replica_low.id, 10).await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Region goes down — should select the low-lag replica (vm_north)
    monitor
        .run_cycle_with_health(|url| !url.contains("vm-east"))
        .await;

    let raw_tenant = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        raw_tenant.vm_id,
        Some(vm_north.id),
        "should failover to lowest-lag replica"
    );
}

/// Failover target selection must consider replica VM health, not just lag.
/// If the lowest-lag replica VM is unhealthy, choose the next healthy replica.
#[tokio::test]
async fn region_failover_skips_unhealthy_replica_vm_even_with_lower_lag() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let vm_west = vm_repo
        .create(vm_seed("eu-west-1", "aws", "vm-west-1"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    // Unhealthy target has lower lag.
    let unhealthy_low_lag = replica_repo
        .create(customer_id, "products", vm_east.id, vm_west.id, "eu-west-1")
        .await
        .unwrap();
    replica_repo
        .set_status(unhealthy_low_lag.id, "active")
        .await
        .unwrap();
    replica_repo.set_lag(unhealthy_low_lag.id, 5).await.unwrap();

    // Healthy target has higher lag.
    let healthy_higher_lag = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(healthy_higher_lag.id, "active")
        .await
        .unwrap();
    replica_repo
        .set_lag(healthy_higher_lag.id, 20)
        .await
        .unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service,
        config,
    );

    // Source region is down; eu-west replica VM is down; eu-central replica VM is healthy.
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;

    let raw_tenant = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        raw_tenant.vm_id,
        Some(vm_central.id),
        "should choose healthy replica VM, not lowest-lag unhealthy VM"
    );
}

/// When two regions are down and one recovers, recovery cleanup must only clear
/// failover tracking for the recovering region. The still-down region's indexes
/// must NOT be re-promoted on the next failover cycle.
#[tokio::test]
async fn region_failover_recovery_scoped_to_region() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Region A: us-east-1 (AWS)
    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    // Region B: eu-west-1 (AWS)
    let vm_west = vm_repo
        .create(vm_seed("eu-west-1", "aws", "vm-west-1"))
        .await
        .unwrap();

    // Healthy failover target region
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    // Tenant A in us-east-1 with replica in eu-central-1
    let cust_a = Uuid::new_v4();
    let dep_a = Uuid::new_v4();
    tenant_repo.seed_deployment(
        dep_a,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo.create(cust_a, "idx-a", dep_a).await.unwrap();
    tenant_repo
        .set_vm_id(cust_a, "idx-a", vm_east.id)
        .await
        .unwrap();
    let rep_a = replica_repo
        .create(cust_a, "idx-a", vm_east.id, vm_central.id, "eu-central-1")
        .await
        .unwrap();
    replica_repo.set_status(rep_a.id, "active").await.unwrap();

    // Tenant B in eu-west-1 with replica in eu-central-1
    let cust_b = Uuid::new_v4();
    let dep_b = Uuid::new_v4();
    tenant_repo.seed_deployment(
        dep_b,
        "eu-west-1",
        Some("http://vm-west-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo.create(cust_b, "idx-b", dep_b).await.unwrap();
    tenant_repo
        .set_vm_id(cust_b, "idx-b", vm_west.id)
        .await
        .unwrap();
    let rep_b = replica_repo
        .create(cust_b, "idx-b", vm_west.id, vm_central.id, "eu-central-1")
        .await
        .unwrap();
    replica_repo.set_status(rep_b.id, "active").await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Cycle 1: both us-east-1 and eu-west-1 go down, eu-central-1 stays healthy
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;

    // Both regions should be Down
    let statuses = monitor.region_statuses();
    assert_eq!(statuses.get("us-east-1"), Some(&RegionHealthStatus::Down));
    assert_eq!(statuses.get("eu-west-1"), Some(&RegionHealthStatus::Down));

    // Both tenants should be failed over to vm_central
    let raw_a = tenant_repo
        .find_raw(cust_a, "idx-a")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_a.vm_id, Some(vm_central.id));
    let raw_b = tenant_repo
        .find_raw(cust_b, "idx-b")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_b.vm_id, Some(vm_central.id));

    // Cycle 2: us-east-1 recovers, eu-west-1 stays down
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east") || url.contains("vm-central"))
        .await;

    // us-east-1 healthy, eu-west-1 still down
    let statuses = monitor.region_statuses();
    assert_eq!(
        statuses.get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );
    assert_eq!(statuses.get("eu-west-1"), Some(&RegionHealthStatus::Down));

    // Cycle 3: eu-west-1 goes down again — idx-b must NOT be re-promoted
    // (it was already failed over and the tracking entry must still exist)
    let alert_count_before = alert_service.alert_count();
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east") || url.contains("vm-central"))
        .await;

    // idx-b should NOT trigger another failover alert (already tracked)
    let alerts_after = alert_service.recorded_alerts();
    let new_failover_alerts: Vec<_> = alerts_after
        .iter()
        .skip(alert_count_before)
        .filter(|a| a.title.contains("Index failed over") && a.message.contains("idx-b"))
        .collect();
    assert!(
        new_failover_alerts.is_empty(),
        "expected no re-promotion for idx-b, but got: {:?}",
        new_failover_alerts
            .iter()
            .map(|a| &a.title)
            .collect::<Vec<_>>()
    );
}

/// While a region remains Down, failover should continue attempting promotion
/// for newly affected indexes created during the same outage window.
#[tokio::test]
async fn region_failover_continues_failover_for_new_indexes_while_region_stays_down() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    // Seed first index before outage.
    let customer_id = Uuid::new_v4();
    let deployment_a = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_a,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "idx-a", deployment_a)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "idx-a", vm_east.id)
        .await
        .unwrap();
    let replica_a = replica_repo
        .create(
            customer_id,
            "idx-a",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(replica_a.id, "active")
        .await
        .unwrap();

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service,
        RegionFailoverConfig {
            cycle_interval_secs: 30,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    );

    // Cycle 1: region transitions to Down and idx-a is failed over.
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;
    let raw_a = tenant_repo
        .find_raw(customer_id, "idx-a")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_a.vm_id, Some(vm_central.id));
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );

    // Create a new index during the same outage.
    let deployment_b = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_b,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "idx-b", deployment_b)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "idx-b", vm_east.id)
        .await
        .unwrap();
    let replica_b = replica_repo
        .create(
            customer_id,
            "idx-b",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo
        .set_status(replica_b.id, "active")
        .await
        .unwrap();

    // Cycle 2: region is still Down; idx-b should still be auto-failed-over.
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;
    let raw_b = tenant_repo
        .find_raw(customer_id, "idx-b")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        raw_b.vm_id,
        Some(vm_central.id),
        "new index should fail over even when region was already Down"
    );
}

/// When some VMs in a region are healthy and some are down, the region should
/// be Degraded — not Healthy, not Down. No failover should trigger.
#[tokio::test]
async fn region_failover_partial_health_sets_degraded() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let _vm_healthy = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let _vm_unhealthy = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-2"))
        .await
        .unwrap();

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo,
        replica_repo,
        alert_service.clone(),
        RegionFailoverConfig {
            cycle_interval_secs: 30,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    );

    // vm-east-1 is healthy, vm-east-2 is not
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east-1"))
        .await;

    let statuses = monitor.region_statuses();
    assert_eq!(
        statuses.get("us-east-1"),
        Some(&RegionHealthStatus::Degraded),
        "partial health should set region to Degraded"
    );
    // No critical alerts should fire for degraded (only for Down)
    assert_eq!(alert_service.alert_count(), 0);
}

/// RegionFailoverConfig::from_reader should parse all env vars correctly.
#[test]
fn failover_config_from_reader_reads_all_vars() {
    let config = RegionFailoverConfig::from_reader(|key| match key {
        "REGION_FAILOVER_CYCLE_INTERVAL_SECS" => Some("120".to_string()),
        "REGION_FAILOVER_UNHEALTHY_THRESHOLD" => Some("5".to_string()),
        "REGION_FAILOVER_RECOVERY_THRESHOLD" => Some("3".to_string()),
        _ => None,
    });

    assert_eq!(config.cycle_interval_secs, 120);
    assert_eq!(config.unhealthy_threshold, 5);
    assert_eq!(config.recovery_threshold, 3);
}

/// Defaults should be sensible when no env vars are set.
#[test]
fn failover_config_defaults_are_sensible() {
    let config = RegionFailoverConfig::from_reader(|_| None);

    assert_eq!(config.cycle_interval_secs, 60);
    assert_eq!(config.unhealthy_threshold, 3);
    assert_eq!(config.recovery_threshold, 2);
}

/// Zero/negative config values should fall back to defaults to prevent
/// tight-loop polling or impossible thresholds.
#[test]
fn failover_config_invalid_values_fall_back_to_defaults() {
    let config = RegionFailoverConfig::from_reader(|key| match key {
        "REGION_FAILOVER_CYCLE_INTERVAL_SECS" => Some("0".to_string()),
        "REGION_FAILOVER_UNHEALTHY_THRESHOLD" => Some("0".to_string()),
        "REGION_FAILOVER_RECOVERY_THRESHOLD" => Some("-1".to_string()),
        _ => None,
    });

    assert_eq!(config.cycle_interval_secs, 60);
    assert_eq!(config.unhealthy_threshold, 3);
    assert_eq!(config.recovery_threshold, 2);
}

/// Regression: failed_over_indexes must be cleared when a region transitions
/// Down → Degraded → Healthy (not just Down → Healthy directly). Without the
/// fix, a second outage would not re-failover already-tracked indexes.
#[tokio::test]
async fn region_failover_clears_tracking_after_down_degraded_healthy() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Two VMs in us-east-1 so the region can go partially healthy (Degraded)
    let vm_east_1 = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    // vm_east_2 registered in VM inventory so the region has 2 VMs; needed for
    // Degraded state (1 healthy, 1 down). Variable unused beyond repo side-effect.
    let _vm_east_2 = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-2"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east_1.id)
        .await
        .unwrap();

    let replica = replica_repo
        .create(
            customer_id,
            "products",
            vm_east_1.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1, // immediate for testing
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Cycle 1: both us-east-1 VMs down → region goes Down, failover triggered
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );
    let raw = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        raw.vm_id,
        Some(vm_central.id),
        "failover completed to replica VM"
    );

    // Cycle 2: vm-east-1 comes back but vm-east-2 still down → Degraded
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east-1") || url.contains("vm-central"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded),
        "partial health → Degraded"
    );

    // Cycle 3: both VMs back → Healthy; failed_over_indexes should be cleared
    monitor.run_cycle_with_health(|_| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy),
        "full recovery → Healthy"
    );

    // Reset the tenant back to primary VM to simulate "admin restored topology".
    // This also requires un-suspending the replica (failover suspends it to
    // prevent the replication orchestrator from fighting the failover).
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east_1.id)
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    // Cycle 4: region goes Down again — without the fix, failover would be SKIPPED
    // because the tracking entry from cycle 1 was never cleared.
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );

    let raw = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        raw.vm_id,
        Some(vm_central.id),
        "second outage should re-trigger failover (tracking was cleared on recovery)"
    );
}

/// Spawned monitor task should stop promptly once shutdown is signaled.
#[tokio::test]
async fn region_failover_spawn_stops_on_shutdown_signal() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let monitor = Arc::new(RegionFailoverMonitor::new(
        vm_repo,
        tenant_repo,
        replica_repo,
        alert_service,
        RegionFailoverConfig {
            cycle_interval_secs: 3600,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    ));

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let handle = monitor.spawn(shutdown_rx);
    shutdown_tx.send(true).unwrap();

    tokio::time::timeout(Duration::from_millis(300), handle)
        .await
        .expect("monitor task should exit after shutdown signal")
        .expect("monitor task should join cleanly");
}

/// Anti-flap test: alternating healthy/down should NOT oscillate to Down.
/// The unhealthy counter should reset on healthy cycles, preventing flapping.
#[tokio::test]
async fn region_failover_anti_flap_prevents_down_transition() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 3,
        recovery_threshold: 2,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo,
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Cycle 1: all healthy
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );

    // Cycle 2: all down - increment counter
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded)
    );

    // Cycle 3: healthy again - counter should reset
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );

    // Cycle 4: all down again - should be Degraded, not Down
    // because the unhealthy counter was reset
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded),
        "should be Degraded, not Down - anti-flap should reset counter"
    );

    // Cycle 5: healthy again - reset counter again
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );

    // Cycle 6: all down again - still Degraded, not Down.
    // Without the healthy-cycle reset, this third down cycle would hit threshold=3.
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded),
        "alternating healthy/down should never accumulate to Down"
    );

    // No Critical alert should fire for Down
    let alerts = alert_service.recorded_alerts();
    let critical_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == api::services::alerting::AlertSeverity::Critical)
        .collect();
    assert!(
        critical_alerts.is_empty(),
        "anti-flap should prevent Down transition and Critical alerts"
    );
}

/// Degraded -> Down transition test: when a region starts with partial health
/// (some VMs unhealthy), then all VMs become unreachable, it should transition
/// to Down after the unhealthy threshold.
#[tokio::test]
async fn region_failover_degraded_to_down_transition() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-2"))
        .await
        .unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 2,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo,
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Cycle 1: partial health (one VM unhealthy) -> Degraded
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east-1"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded)
    );

    // Cycle 2: all down -> should reach Down threshold now
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down),
        "Degraded + 1 unhealthy cycle should reach Down threshold"
    );

    // Critical alert should fire
    let alerts = alert_service.recorded_alerts();
    let critical_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == api::services::alerting::AlertSeverity::Critical)
        .collect();
    assert!(
        !critical_alerts.is_empty(),
        "Down transition should fire Critical alert"
    );
}

/// Recovery threshold > 1 test: recovery should require sustained healthy cycles,
/// not just one healthy cycle.
#[tokio::test]
async fn region_failover_recovery_requires_sustained_healthy_cycles() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let _vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 3, // require 3 healthy cycles
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Cycle 1: region goes Down
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );

    // Cycle 2: one healthy cycle - should still be Down
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down),
        "1 healthy cycle should NOT recover with recovery_threshold=3"
    );

    // Cycle 3: two healthy cycles - should still be Down
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down),
        "2 healthy cycles should NOT recover with recovery_threshold=3"
    );

    // Cycle 4: third healthy cycle - should transition to Healthy
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy),
        "3 healthy cycles should recover with recovery_threshold=3"
    );

    // Info alert should fire for recovery
    let alerts = alert_service.recorded_alerts();
    let info_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == api::services::alerting::AlertSeverity::Info)
        .collect();
    assert!(!info_alerts.is_empty(), "Recovery should fire Info alert");
}

/// Full lifecycle alert sequence test: drive region through
/// Healthy -> Degraded -> Down -> Recovery -> Healthy and verify alert sequence.
#[tokio::test]
async fn region_failover_full_lifecycle_alert_sequence() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Two VMs to allow partial health (Degraded) state
    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-2"))
        .await
        .unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 2,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo,
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Healthy
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );
    let alert_count_after_healthy = alert_service.alert_count();

    // Degraded (partial failure)
    monitor
        .run_cycle_with_health(|url| url.contains("vm-east-1"))
        .await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Degraded)
    );
    // No alert should fire on Degraded
    assert_eq!(
        alert_service.alert_count(),
        alert_count_after_healthy,
        "Degraded should NOT fire alerts"
    );

    // Down (all failed)
    monitor.run_cycle_with_health(|_url| false).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Down)
    );
    let alerts_after_down = alert_service.recorded_alerts();
    let alert_count_after_down = alerts_after_down.len();
    assert_eq!(
        alert_count_after_down,
        alert_count_after_healthy + 1,
        "Down should add exactly one alert in this test path"
    );
    let down_alert = alerts_after_down.last().unwrap();
    assert_eq!(
        down_alert.severity,
        api::services::alerting::AlertSeverity::Critical,
        "Down transition should fire a Critical alert"
    );
    assert!(down_alert.title.contains("Region down"));

    // Recovery
    monitor.run_cycle_with_health(|_url| true).await;
    assert_eq!(
        monitor.region_statuses().get("us-east-1"),
        Some(&RegionHealthStatus::Healthy)
    );
    let alerts_after_recovery = alert_service.recorded_alerts();
    let alert_count_after_recovery = alerts_after_recovery.len();
    assert_eq!(
        alert_count_after_recovery,
        alert_count_after_down + 1,
        "Recovery should add exactly one alert in this test path"
    );
    let recovery_alert = alerts_after_recovery.last().unwrap();
    assert_eq!(
        recovery_alert.severity,
        api::services::alerting::AlertSeverity::Info,
        "Recovery should fire an Info alert"
    );
    assert!(recovery_alert.title.contains("Region recovered"));
}

/// No-replica warning alert should include correct metadata.
#[tokio::test]
async fn region_failover_no_replica_warning_includes_metadata() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    // Primary VM in us-east-1
    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();

    // Tenant with index on primary
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    // No replica exists - this should trigger warning

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 1,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo,
        alert_service.clone(),
        config,
    );

    // Region goes down
    monitor.run_cycle_with_health(|_url| false).await;

    // Check for warning alert with metadata
    let alerts = alert_service.recorded_alerts();
    let warning_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == api::services::alerting::AlertSeverity::Warning)
        .filter(|a| a.title.contains("No failover target"))
        .collect();

    assert!(
        !warning_alerts.is_empty(),
        "Should fire warning for no replica"
    );

    // Verify metadata contains required fields and expected values.
    let alert = &warning_alerts[0];
    assert_eq!(
        alert.metadata.get("region"),
        Some(&serde_json::json!("us-east-1")),
        "Alert should include source region"
    );
    assert_eq!(
        alert.metadata.get("customer_id"),
        Some(&serde_json::json!(customer_id.to_string())),
        "Alert should include correct customer_id"
    );
    assert_eq!(
        alert.metadata.get("tenant_id"),
        Some(&serde_json::json!("products")),
        "Alert should include correct tenant_id"
    );
}

/// When failover promotes a replica, the replica's status must be set to
/// "suspended" so the replication orchestrator does not try to fetch lag
/// from the dead primary VM and erroneously mark it failed.
#[tokio::test]
async fn region_failover_suspends_promoted_replica() {
    let vm_repo = common::mock_vm_inventory_repo();
    let tenant_repo = common::mock_tenant_repo();
    let replica_repo: Arc<InMemoryIndexReplicaRepo> = Arc::new(InMemoryIndexReplicaRepo::new());
    let alert_service = common::mock_alert_service();

    let vm_east = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-east-1"))
        .await
        .unwrap();
    let vm_central = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-central-1"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-east-1:7700"),
        "healthy",
        "running",
    );
    tenant_repo
        .create(customer_id, "products", deployment_id)
        .await
        .unwrap();
    tenant_repo
        .set_vm_id(customer_id, "products", vm_east.id)
        .await
        .unwrap();

    let replica = replica_repo
        .create(
            customer_id,
            "products",
            vm_east.id,
            vm_central.id,
            "eu-central-1",
        )
        .await
        .unwrap();
    replica_repo.set_status(replica.id, "active").await.unwrap();

    let config = RegionFailoverConfig {
        cycle_interval_secs: 30,
        unhealthy_threshold: 1,
        recovery_threshold: 2,
    };

    let monitor = RegionFailoverMonitor::new(
        vm_repo.clone(),
        tenant_repo.clone(),
        replica_repo.clone(),
        alert_service.clone(),
        config,
    );

    // Region goes down — failover promotes the replica
    monitor
        .run_cycle_with_health(|url| url.contains("vm-central"))
        .await;

    // Tenant should be promoted to the replica VM
    let raw_tenant = tenant_repo
        .find_raw(customer_id, "products")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(raw_tenant.vm_id, Some(vm_central.id));

    // The promoted replica must be suspended so the replication orchestrator
    // does not try to fetch lag from the dead primary_vm_id.
    let replica_after = replica_repo.get(replica.id).await.unwrap().unwrap();
    assert_eq!(
        replica_after.status, "suspended",
        "promoted replica should be suspended to prevent orchestrator interference"
    );

    // Suspended replicas must not appear in the actionable list
    let actionable = replica_repo.list_actionable().await.unwrap();
    assert!(
        actionable.is_empty(),
        "suspended replica should be excluded from actionable list"
    );
}

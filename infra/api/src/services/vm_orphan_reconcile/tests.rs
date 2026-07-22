use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{DateTime, Duration, Utc};
use serde_json::json;
use uuid::Uuid;

use super::*;
use crate::dns::mock::MockDnsManager;
use crate::dns::UnconfiguredDnsManager;
use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::provisioner::mock::MockVmProvisioner;
use crate::provisioner::{VmProvisioner, VmStatus};
use crate::repos::error::RepoError;
use crate::repos::vm_inventory_repo::{
    VmDecommissionResult, VmInventoryRepo, VmRetirementAssessment,
};
use crate::secrets::mock::MockNodeSecretManager;
use crate::secrets::UnconfiguredNodeSecretManager;

struct TestInventoryRepo {
    rows: Mutex<Vec<VmInventory>>,
    fail_listing: bool,
}

impl TestInventoryRepo {
    fn new(rows: Vec<VmInventory>) -> Self {
        Self {
            rows: Mutex::new(rows),
            fail_listing: false,
        }
    }
}

#[async_trait]
impl VmInventoryRepo for TestInventoryRepo {
    async fn list_active(&self, region: Option<&str>) -> Result<Vec<VmInventory>, RepoError> {
        Ok(self
            .rows
            .lock()
            .unwrap()
            .iter()
            .filter(|row| row.status == "active")
            .filter(|row| region.is_none_or(|region| row.region == region))
            .cloned()
            .collect())
    }

    async fn list_non_decommissioned(&self) -> Result<Vec<VmInventory>, RepoError> {
        if self.fail_listing {
            return Err(RepoError::Other("inventory listing failed".to_string()));
        }
        Ok(self
            .rows
            .lock()
            .unwrap()
            .iter()
            .filter(|row| row.status != "decommissioned")
            .cloned()
            .collect())
    }

    async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, RepoError> {
        Ok(self
            .rows
            .lock()
            .unwrap()
            .iter()
            .find(|row| row.id == id)
            .cloned())
    }

    async fn create(&self, _vm: NewVmInventory) -> Result<VmInventory, RepoError> {
        Err(RepoError::Other("not used".to_string()))
    }

    async fn update_load(&self, _id: Uuid, _load: serde_json::Value) -> Result<(), RepoError> {
        Err(RepoError::Other("not used".to_string()))
    }

    async fn set_status(&self, _id: Uuid, _status: &str) -> Result<(), RepoError> {
        Err(RepoError::Other("not used".to_string()))
    }

    async fn retirement_blockers(
        &self,
        _id: Uuid,
        _expected_hostname: &str,
    ) -> Result<VmRetirementAssessment, RepoError> {
        Err(RepoError::Other("not used".to_string()))
    }

    async fn decommission_if_unreferenced(
        &self,
        _id: Uuid,
        _expected_hostname: &str,
    ) -> Result<VmDecommissionResult, RepoError> {
        Err(RepoError::Other("not used".to_string()))
    }

    async fn find_by_hostname(&self, hostname: &str) -> Result<Option<VmInventory>, RepoError> {
        Ok(self
            .rows
            .lock()
            .unwrap()
            .iter()
            .find(|row| row.hostname == hostname)
            .cloned())
    }
}

fn vm(hostname: &str, status: &str, now: DateTime<Utc>) -> VmInventory {
    VmInventory {
        id: Uuid::new_v4(),
        region: "us-east-1".to_string(),
        provider: "aws".to_string(),
        hostname: hostname.to_string(),
        flapjack_url: format!("http://{hostname}:7700"),
        capacity: json!({}),
        current_load: json!({}),
        load_scraped_at: None,
        status: status.to_string(),
        created_at: now - Duration::hours(2),
        updated_at: now - Duration::hours(2),
    }
}

fn reconciler(
    inventory: Arc<dyn VmInventoryRepo + Send + Sync>,
    dns: Arc<dyn crate::dns::DnsManager>,
    secrets: Arc<dyn crate::secrets::NodeSecretManager>,
    provisioner: Arc<dyn VmProvisioner>,
) -> VmOrphanReconciler {
    VmOrphanReconciler::new(
        VmOrphanDependencies {
            inventory,
            dns,
            secrets,
            provisioner,
        },
        "flapjack.foo".to_string(),
    )
}

fn fixed_now() -> DateTime<Utc> {
    "2026-07-22T18:00:00Z".parse().unwrap()
}

#[tokio::test]
async fn orphan_report_unsupported_default_listers_are_indeterminate_not_clean() {
    let report = reconciler(
        Arc::new(TestInventoryRepo::new(Vec::new())),
        Arc::new(UnconfiguredDnsManager),
        Arc::new(UnconfiguredNodeSecretManager),
        Arc::new(MockVmProvisioner::new()),
    )
    .reconcile_at(fixed_now())
    .await;

    assert_eq!(report.status, OrphanReportStatus::Indeterminate);
    assert_eq!(report.sources.dns.status, SourceStatus::Unsupported);
    assert!(report.sources.dns.enumeration_incomplete);
    assert_eq!(report.sources.ssm.status, SourceStatus::Unsupported);
    assert!(report.sources.ssm.enumeration_incomplete);
    assert_eq!(report.orphans_found, 0);
}

#[tokio::test]
async fn orphan_report_inventory_listing_failure_is_indeterminate_not_clean() {
    let inventory = Arc::new(TestInventoryRepo {
        rows: Mutex::new(Vec::new()),
        fail_listing: true,
    });
    let report = reconciler(
        inventory,
        Arc::new(MockDnsManager::new()),
        Arc::new(MockNodeSecretManager::new()),
        Arc::new(MockVmProvisioner::new()),
    )
    .reconcile_at(fixed_now())
    .await;

    assert_eq!(report.status, OrphanReportStatus::Indeterminate);
    assert_eq!(report.sources.inventory.status, SourceStatus::Error);
    assert!(report.sources.inventory.enumeration_incomplete);
    assert_eq!(report.sources.inventory.inventory_scanned, 0);
    assert_eq!(report.orphans_found, 0);
}

#[tokio::test]
async fn orphan_report_one_hour_grace_suppresses_recent_resources_but_counts_them() {
    let now = fixed_now();
    let dns = Arc::new(MockDnsManager::new());
    dns.seed_a_record_at(
        "vm-shared-recent.flapjack.foo",
        "203.0.113.10",
        now - Duration::minutes(30),
    );
    let secrets = Arc::new(MockNodeSecretManager::new());
    secrets.seed_listed_key_at(
        "vm-shared-recent.flapjack.foo",
        false,
        now - Duration::minutes(30),
    );

    let report = reconciler(
        Arc::new(TestInventoryRepo::new(Vec::new())),
        dns,
        secrets,
        Arc::new(MockVmProvisioner::new()),
    )
    .reconcile_at(now)
    .await;

    assert_eq!(report.sources.dns.records_scanned, 1);
    assert_eq!(report.sources.ssm.keys_scanned, 1);
    assert_eq!(report.orphans_found, 0);
    assert!(report.dns_orphans.is_empty());
    assert!(report.ssm_key_orphans.is_empty());
}

#[tokio::test]
async fn orphan_report_detects_old_dns_and_ssm_orphans() {
    let now = fixed_now();
    let hostname = "vm-shared-orphan.flapjack.foo";
    let dns = Arc::new(MockDnsManager::new());
    dns.seed_a_record_at(hostname, "203.0.113.11", now - Duration::hours(2));
    let secrets = Arc::new(MockNodeSecretManager::new());
    secrets.seed_listed_key_at(hostname, false, now - Duration::hours(2));
    secrets.seed_listed_key_at(hostname, true, now - Duration::hours(2));

    let report = reconciler(
        Arc::new(TestInventoryRepo::new(Vec::new())),
        dns,
        secrets,
        Arc::new(MockVmProvisioner::new()),
    )
    .reconcile_at(now)
    .await;

    assert_eq!(report.status, OrphanReportStatus::OrphansFound);
    assert_eq!(report.orphans_found, 3);
    assert_eq!(report.dns_orphans[0].hostname, hostname);
    assert_eq!(report.ssm_key_orphans.len(), 2);
}

#[tokio::test]
async fn orphan_report_draining_row_is_live_while_decommissioned_row_is_not() {
    let now = fixed_now();
    let draining = "vm-shared-draining.flapjack.foo";
    let retired = "vm-shared-retired.flapjack.foo";
    let inventory = Arc::new(TestInventoryRepo::new(vec![
        vm(draining, "draining", now),
        vm(retired, "decommissioned", now),
    ]));
    let dns = Arc::new(MockDnsManager::new());
    dns.seed_a_record_at(draining, "203.0.113.12", now - Duration::hours(2));
    dns.seed_a_record_at(retired, "203.0.113.13", now - Duration::hours(2));
    let provisioner = Arc::new(MockVmProvisioner::new());
    provisioner.seed_vm_for_hostname(draining, "i-draining", VmStatus::Stopped, "us-east-1");

    let report = reconciler(
        inventory,
        dns,
        Arc::new(MockNodeSecretManager::new()),
        provisioner,
    )
    .reconcile_at(now)
    .await;

    assert!(report
        .non_orphans
        .iter()
        .any(|matched| matched.hostname == draining));
    assert_eq!(report.dns_orphans.len(), 1);
    assert_eq!(report.dns_orphans[0].hostname, retired);
    assert_eq!(
        report.dns_orphans[0]
            .retired_inventory
            .as_ref()
            .map(|row| row.status.as_str()),
        Some("decommissioned")
    );
}

#[tokio::test]
async fn orphan_report_state_agnostic_oracle_keeps_stopped_managed_vm_non_orphan() {
    let now = fixed_now();
    let hostname = "vm-shared-stopped.flapjack.foo";
    let inventory = Arc::new(TestInventoryRepo::new(vec![vm(hostname, "active", now)]));
    let dns = Arc::new(MockDnsManager::new());
    dns.seed_a_record_at(hostname, "203.0.113.14", now - Duration::hours(2));
    let secrets = Arc::new(MockNodeSecretManager::new());
    secrets.seed_listed_key_at(hostname, false, now - Duration::hours(2));
    let provisioner = Arc::new(MockVmProvisioner::new());
    provisioner.seed_vm_for_hostname(hostname, "i-previous-ami", VmStatus::Stopped, "us-east-1");
    assert!(provisioner
        .find_running_vm_by_hostname("aws", "us-east-1", hostname)
        .await
        .unwrap()
        .is_none());

    let report = reconciler(inventory, dns, secrets, provisioner)
        .reconcile_at(now)
        .await;

    assert_eq!(report.status, OrphanReportStatus::Clean);
    assert_eq!(report.orphans_found, 0);
    assert_eq!(report.non_orphans.len(), 1);
    assert_eq!(report.non_orphans[0].hostname, hostname);
    assert!(report.non_orphans[0].dns_record_matched);
    assert_eq!(report.non_orphans[0].ssm_paths_matched.len(), 1);
}

#[tokio::test]
async fn orphan_report_instance_lookup_error_is_indeterminate_not_orphan() {
    let now = fixed_now();
    let hostname = "vm-shared-lookup-error.flapjack.foo";
    let inventory = Arc::new(TestInventoryRepo::new(vec![vm(hostname, "active", now)]));
    let dns = Arc::new(MockDnsManager::new());
    dns.seed_a_record_at(hostname, "203.0.113.15", now - Duration::hours(2));
    let provisioner = Arc::new(MockVmProvisioner::new());
    provisioner.set_should_fail(true);

    let report = reconciler(
        inventory,
        dns,
        Arc::new(MockNodeSecretManager::new()),
        provisioner,
    )
    .reconcile_at(now)
    .await;

    assert_eq!(report.status, OrphanReportStatus::Indeterminate);
    assert_eq!(report.sources.instances.status, SourceStatus::Error);
    assert!(report.sources.instances.enumeration_incomplete);
    assert_eq!(report.orphans_found, 0);
    assert!(report.dns_orphans.is_empty());
}

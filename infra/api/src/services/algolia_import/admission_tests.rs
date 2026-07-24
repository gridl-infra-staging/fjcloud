use chrono::Utc;
use serde_json::json;
use uuid::Uuid;

use crate::models::algolia_import_job::AlgoliaImportErrorCode;
use crate::services::flapjack_proxy::{FlapjackEngineRequirements, ProxyError};

use super::reconciliation_test_support::{harness, job, response, vm, FixedVmRepo};

fn strict_requirements() -> FlapjackEngineRequirements {
    FlapjackEngineRequirements::new(
        Some("1.0.10"),
        Some("abc123"),
        Some("build-1"),
        Some("sha-1"),
        Some("preview_events_v1"),
    )
}

fn compatible_health() -> serde_json::Value {
    json!({
        "version": "1.0.10",
        "producer_revision": "abc123",
        "build_id": "build-1",
        "binary_sha256": "sha-1",
        "dirty": false,
        "capabilities": ["preview_events_v1"]
    })
}

#[tokio::test]
async fn admission_compatibility_decision_is_typed_and_exhaustive() {
    let (service, _, _) = harness(vec![response(200, compatible_health())]).await;
    assert_eq!(
        service
            .check_engine_admission_compatibility("https://node-1.example", &strict_requirements(),)
            .await,
        Ok(())
    );

    let (service, _, _) = harness(vec![Err(ProxyError::Timeout)]).await;
    assert_eq!(
        service
            .check_engine_admission_compatibility("https://node-1.example", &strict_requirements(),)
            .await,
        Err(AlgoliaImportErrorCode::BackendUnavailable)
    );

    let mut incompatible_health = compatible_health();
    incompatible_health["binary_sha256"] = json!("different-sha");
    let (service, _, _) = harness(vec![response(200, incompatible_health)]).await;
    assert_eq!(
        service
            .check_engine_admission_compatibility("https://node-1.example", &strict_requirements(),)
            .await,
        Err(AlgoliaImportErrorCode::EngineUpgradeRequired)
    );
}

#[tokio::test]
async fn persisted_destination_is_reresolved_without_using_physical_uid() {
    let now = Utc::now();
    let vm_id = Uuid::new_v4();
    let persisted_job = job(now, vm_id);
    let inventory_vm = vm(now, vm_id);
    let repo = FixedVmRepo {
        vm: Some(inventory_vm.clone()),
    };
    let (service, _, _) = harness(Vec::new()).await;

    let target = service
        .resolve_engine_target(&persisted_job, &repo)
        .await
        .expect("persisted target must resolve");
    assert_eq!(target.flapjack_url, inventory_vm.flapjack_url);
    assert_eq!(target.node_id, inventory_vm.hostname);
    assert_eq!(target.region, inventory_vm.region);
    assert_ne!(
        target.node_id,
        persisted_job.physical_uid.as_deref().unwrap()
    );

    let mut region_drift = inventory_vm.clone();
    region_drift.region = "us-west-2".to_string();
    assert_eq!(
        service
            .resolve_engine_target(
                &persisted_job,
                &FixedVmRepo {
                    vm: Some(region_drift)
                },
            )
            .await,
        Err(AlgoliaImportErrorCode::DestinationChanged)
    );

    let mut unavailable = inventory_vm;
    unavailable.status = "draining".to_string();
    assert_eq!(
        service
            .resolve_engine_target(
                &persisted_job,
                &FixedVmRepo {
                    vm: Some(unavailable)
                },
            )
            .await,
        Err(AlgoliaImportErrorCode::BackendUnavailable)
    );
    assert_eq!(
        service
            .resolve_engine_target(&persisted_job, &FixedVmRepo { vm: None })
            .await,
        Err(AlgoliaImportErrorCode::DestinationChanged)
    );
}

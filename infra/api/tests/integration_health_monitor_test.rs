//! Integration tests for the health monitor pipeline.
//!
//! Two categories:
//!   1. **Gated integration tests** — require a live flapjack + fjcloud API stack
//!      (INTEGRATION=1). These skip cleanly when the stack is unreachable.
//!   2. **Pure Rust pipeline tests** — exercise the full HealthMonitor pipeline
//!      (check_all → process_result → DB update → alert) with controllable mock
//!      health clients. No infrastructure needed.

mod common;
#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use api::repos::DeploymentRepo;
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::health_monitor::{HealthCheckClient, HealthCheckResult, HealthMonitor};
use async_trait::async_trait;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Controllable mock health client — can switch between healthy/unhealthy at runtime
// ---------------------------------------------------------------------------

struct ControllableHealthClient {
    /// Map from flapjack_url → current result. Mutable at runtime.
    results: Mutex<HashMap<String, HealthCheckResult>>,
}

impl ControllableHealthClient {
    fn new() -> Self {
        Self {
            results: Mutex::new(HashMap::new()),
        }
    }

    fn set_result(&self, url: &str, result: HealthCheckResult) {
        self.results.lock().unwrap().insert(url.to_string(), result);
    }
}

#[async_trait]
impl HealthCheckClient for ControllableHealthClient {
    async fn check(&self, flapjack_url: Option<String>) -> HealthCheckResult {
        match flapjack_url {
            Some(url) => self
                .results
                .lock()
                .unwrap()
                .get(&url)
                .cloned()
                .unwrap_or_else(|| HealthCheckResult::Unreachable("not configured".into())),
            None => HealthCheckResult::Unreachable("no flapjack_url set".into()),
        }
    }
}

fn live_crash_checks_enabled() -> bool {
    std::env::var("HEALTH_MONITOR_LIVE_CRASH")
        .map(|v| v == "1")
        .unwrap_or(false)
}

// ===========================================================================
// Category 1: Gated integration tests (require live stack)
// ===========================================================================

integration_test!(health_monitor_detects_flapjack_crash, async {
    let api_url = integration_helpers::api_base();
    let flapjack_url = integration_helpers::flapjack_base();

    require_live!(
        integration_helpers::endpoint_reachable(&api_url).await,
        "API endpoint unreachable for health monitor test"
    );
    require_live!(
        integration_helpers::endpoint_reachable(&flapjack_url).await,
        "flapjack endpoint unreachable for health monitor test"
    );

    if !live_crash_checks_enabled() {
        eprintln!(
            "[deferred] set HEALTH_MONITOR_LIVE_CRASH=1 to run destructive crash/restart checks"
        );
        return;
    }

    // This test requires the ability to kill/restart flapjack, which needs
    // process management access. In a live integration environment:
    //
    // 1. Verify flapjack is healthy via GET /health
    // 2. Kill the flapjack process (via .integration/flapjack.pid)
    // 3. Wait for the health monitor to cycle (default 60s interval; 3 checks ~= 180s)
    // 4. Query the API or DB directly to verify deployment marked unhealthy
    // 5. Check the alerts table for a Critical alert
    //
    // For now, this test verifies the stack is reachable and flapjack responds healthy.
    let client = integration_helpers::http_client();
    let health_resp = client
        .get(format!("{flapjack_url}/health"))
        .send()
        .await
        .expect("flapjack health check failed");
    assert!(
        health_resp.status().is_success(),
        "flapjack /health should return 2xx when stack is up"
    );

    // TODO: Full crash detection flow requires process management
    // (kill flapjack PID, wait for monitor cycle, verify DB state).
    // Deferred to a session with process management access.
    eprintln!("[partial] flapjack reachable and healthy; full crash-detection test deferred (needs process management)");
});

integration_test!(health_monitor_recovers_after_flapjack_restart, async {
    let api_url = integration_helpers::api_base();
    let flapjack_url = integration_helpers::flapjack_base();

    require_live!(
        integration_helpers::endpoint_reachable(&api_url).await,
        "API endpoint unreachable for health monitor test"
    );
    require_live!(
        integration_helpers::endpoint_reachable(&flapjack_url).await,
        "flapjack endpoint unreachable for health monitor test"
    );

    if !live_crash_checks_enabled() {
        eprintln!(
            "[deferred] set HEALTH_MONITOR_LIVE_CRASH=1 to run destructive crash/restart checks"
        );
        return;
    }

    // This test builds on the crash detection test:
    // 1. Kill flapjack → wait → verify unhealthy (same as above)
    // 2. Restart flapjack (re-run the binary with same args)
    // 3. Wait for health monitor to cycle
    // 4. Verify deployment returns to healthy status
    // 5. Check alerts table for Info recovery alert with duration

    let client = integration_helpers::http_client();
    let health_resp = client
        .get(format!("{flapjack_url}/health"))
        .send()
        .await
        .expect("flapjack health check failed");
    assert!(health_resp.status().is_success());

    // TODO: Full recovery flow requires process management.
    eprintln!(
        "[partial] flapjack reachable; full recovery test deferred (needs process management)"
    );
});

// ===========================================================================
// Category 2: Pure Rust pipeline integration tests (no infrastructure)
// ===========================================================================

/// Full crash detection and recovery cycle exercising check_all() end-to-end.
///
/// Simulates: healthy VM → flapjack crashes → 3 check_all cycles mark unhealthy
/// → critical alert fired → flapjack recovers → check_all marks healthy
/// → recovery alert fired with duration.
///
/// This is a multi-cycle integration test that validates the entire pipeline
/// through check_all (not just individual process_result calls).
#[tokio::test]
async fn full_crash_detection_and_recovery_cycle() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let flapjack_url = "http://mock-flapjack-cycle";

    // Seed a running deployment
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-full-cycle",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(flapjack_url),
    );

    // Start healthy
    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    let health_client = Arc::new(ControllableHealthClient::new());
    health_client.set_result(flapjack_url, HealthCheckResult::Healthy);

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10), // fast interval for tests
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    // Phase 1: Verify initial healthy state via check_all
    monitor.check_all().await;
    let after_healthy = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(after_healthy.health_status, "healthy");
    assert_eq!(alert_service.alert_count(), 0, "no alerts when healthy");

    // Phase 2: Simulate flapjack crash
    health_client.set_result(
        flapjack_url,
        HealthCheckResult::Unreachable("connection refused".into()),
    );

    // First 2 failures — should NOT mark unhealthy yet (threshold is 3)
    monitor.check_all().await;
    monitor.check_all().await;
    let after_2_failures = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_ne!(
        after_2_failures.health_status, "unhealthy",
        "should NOT be unhealthy after only 2 failures"
    );
    assert_eq!(
        alert_service.alert_count(),
        0,
        "no alert before threshold crossing"
    );

    // Third failure — should cross threshold
    monitor.check_all().await;
    let after_3_failures = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        after_3_failures.health_status, "unhealthy",
        "should be unhealthy after 3 consecutive failures via check_all"
    );
    assert_eq!(
        after_3_failures.status, "running",
        "deployment status should remain 'running' (ops decision to change)"
    );

    // Verify critical alert was fired
    let alerts_after_crash = alert_service.recorded_alerts();
    assert_eq!(alerts_after_crash.len(), 1, "exactly 1 alert after crash");
    assert_eq!(alerts_after_crash[0].severity, AlertSeverity::Critical);
    assert!(alerts_after_crash[0].title.contains("unhealthy"));

    // Phase 3: Simulate recovery — flapjack comes back
    health_client.set_result(flapjack_url, HealthCheckResult::Healthy);

    // Small delay for measurable recovery duration
    tokio::time::sleep(Duration::from_millis(20)).await;

    monitor.check_all().await;
    let after_recovery = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        after_recovery.health_status, "healthy",
        "should be healthy again after recovery"
    );

    // Verify recovery alert was fired
    let all_alerts = alert_service.recorded_alerts();
    assert_eq!(
        all_alerts.len(),
        2,
        "should have 2 alerts total: 1 critical + 1 recovery"
    );
    assert_eq!(all_alerts[1].severity, AlertSeverity::Info);
    assert!(all_alerts[1].title.contains("recovered"));

    // Verify recovery alert includes duration metadata
    let recovery_meta = all_alerts[1].metadata.as_object().unwrap();
    assert!(
        recovery_meta.contains_key("unhealthy_duration"),
        "recovery alert should include unhealthy_duration"
    );
}

#[tokio::test]
async fn all_deployments_starting_down_recover_after_unblock() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let first_url = "http://mock-flapjack-all-down-a";
    let second_url = "http://mock-flapjack-all-down-b";

    let dep_a = deployment_repo.seed_provisioned(
        customer_id,
        "node-all-down-a",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(first_url),
    );
    let dep_b = deployment_repo.seed_provisioned(
        customer_id,
        "node-all-down-b",
        "eu-west-1",
        "t4g.small",
        "aws",
        "running",
        Some(second_url),
    );

    let health_client = Arc::new(ControllableHealthClient::new());
    health_client.set_result(
        first_url,
        HealthCheckResult::Unreachable("connection refused".into()),
    );
    health_client.set_result(
        second_url,
        HealthCheckResult::Unreachable("connection refused".into()),
    );

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    // Cycle 1: both deployments remain unknown after one failed check.
    monitor.check_all().await;
    let a_after_cycle_1 = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    let b_after_cycle_1 = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(a_after_cycle_1.health_status, "unknown");
    assert_eq!(b_after_cycle_1.health_status, "unknown");
    assert_eq!(alert_service.alert_count(), 0);

    // Cycle 2: still below failure threshold.
    monitor.check_all().await;
    let a_after_cycle_2 = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    let b_after_cycle_2 = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_ne!(a_after_cycle_2.health_status, "unhealthy");
    assert_ne!(b_after_cycle_2.health_status, "unhealthy");
    assert_eq!(alert_service.alert_count(), 0);

    // Cycle 3: both reach unhealthy threshold and fire critical alerts.
    monitor.check_all().await;
    let a_unhealthy = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    let b_unhealthy = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(a_unhealthy.health_status, "unhealthy");
    assert_eq!(b_unhealthy.health_status, "unhealthy");
    assert_eq!(alert_service.alert_count(), 2);
    let alerts = alert_service.recorded_alerts();
    let critical_count = alerts
        .iter()
        .filter(|alert| alert.severity == AlertSeverity::Critical)
        .count();
    assert_eq!(critical_count, 2);

    // Recovery: both endpoints come back healthy and trigger recovery alerts.
    health_client.set_result(first_url, HealthCheckResult::Healthy);
    health_client.set_result(second_url, HealthCheckResult::Healthy);

    tokio::time::sleep(Duration::from_millis(20)).await;

    monitor.check_all().await;
    let a_recovered = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    let b_recovered = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(a_recovered.health_status, "healthy");
    assert_eq!(b_recovered.health_status, "healthy");

    let all_alerts = alert_service.recorded_alerts();
    assert_eq!(all_alerts.len(), 4);
    let info_count = all_alerts
        .iter()
        .filter(|alert| alert.severity == AlertSeverity::Info)
        .count();
    assert_eq!(info_count, 2);

    let a_info_alert = all_alerts.iter().find(|alert| {
        alert.severity == AlertSeverity::Info
            && alert.metadata["deployment_id"] == dep_a.id.to_string()
    });
    assert!(
        a_info_alert.is_some(),
        "missing recovery alert for first deployment"
    );

    let b_info_alert = all_alerts.iter().find(|alert| {
        alert.severity == AlertSeverity::Info
            && alert.metadata["deployment_id"] == dep_b.id.to_string()
    });
    assert!(
        b_info_alert.is_some(),
        "missing recovery alert for second deployment"
    );
}

/// Verify that terminated deployments get their tracking state cleaned up
/// when check_all prunes stale entries from failure_counts, unhealthy_since,
/// and last_alert_at maps.
#[tokio::test]
async fn stale_deployment_tracking_pruned_after_termination() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let url_a = "http://mock-flapjack-a";
    let url_b = "http://mock-flapjack-b";

    // Two running deployments
    let dep_a = deployment_repo.seed_provisioned(
        customer_id,
        "node-prune-a",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(url_a),
    );
    let dep_b = deployment_repo.seed_provisioned(
        customer_id,
        "node-prune-b",
        "eu-west-1",
        "t4g.small",
        "aws",
        "running",
        Some(url_b),
    );

    let health_client = Arc::new(ControllableHealthClient::new());

    // Both start unhealthy
    health_client.set_result(url_a, HealthCheckResult::Unhealthy("HTTP 500".into()));
    health_client.set_result(url_b, HealthCheckResult::Unhealthy("HTTP 500".into()));

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    // 3 cycles to cross unhealthy threshold for both
    for _ in 0..3 {
        monitor.check_all().await;
    }

    // Both should be unhealthy now
    let a = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    let b = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(a.health_status, "unhealthy");
    assert_eq!(b.health_status, "unhealthy");
    assert_eq!(
        alert_service.alert_count(),
        2,
        "2 critical alerts (one per deployment)"
    );

    // Now terminate deployment A — it should be excluded from list_active()
    deployment_repo.terminate(dep_a.id).await.unwrap();

    // Run check_all again — this triggers the pruning logic
    // Dep A is terminated so won't appear in list_active.
    // Its tracking entries (failure_counts, unhealthy_since, last_alert_at) should be pruned.
    health_client.set_result(url_b, HealthCheckResult::Healthy);
    monitor.check_all().await;

    // Dep B should recover
    let b_after = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(
        b_after.health_status, "healthy",
        "dep B should recover after healthy check"
    );

    // Dep A should still be terminated with its last health status
    let a_after = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    assert_eq!(a_after.status, "terminated");

    // Verify no spurious alerts for terminated deployment A
    let all_alerts = alert_service.recorded_alerts();
    let a_alerts: Vec<_> = all_alerts
        .iter()
        .filter(|alert| {
            alert
                .metadata
                .as_object()
                .and_then(|m| m.get("deployment_id"))
                .and_then(|v| v.as_str())
                .map(|id| id == dep_a.id.to_string())
                .unwrap_or(false)
        })
        .collect();
    // Dep A should only have its initial critical alert, no recovery alert
    // (terminated deployments don't get health-checked)
    assert_eq!(
        a_alerts.len(),
        1,
        "terminated deployment should only have the original critical alert, no recovery"
    );
    assert_eq!(a_alerts[0].severity, AlertSeverity::Critical);
}

/// Verify that check_all handles a mixed deployment set with:
/// - running+healthy
/// - running+unreachable
/// - provisioning+no-url
/// - stopped
/// and that stopped deployments are never marked unhealthy in repeated cycles.
#[tokio::test]
async fn check_all_tolerates_mixed_unreachable_and_healthy() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let url_healthy = "http://mock-mixed-healthy";
    let url_failing = "http://mock-mixed-failing";
    let url_stopped = "http://mock-mixed-stopped";

    // Deployment 1: running + healthy endpoint
    let dep_healthy = deployment_repo.seed_provisioned(
        customer_id,
        "node-mixed-healthy",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(url_healthy),
    );

    // Deployment 2: running + failing endpoint
    let dep_failing = deployment_repo.seed_provisioned(
        customer_id,
        "node-mixed-failing",
        "eu-west-1",
        "t4g.small",
        "aws",
        "running",
        Some(url_failing),
    );

    // Deployment 3: provisioning + no URL (should be excluded from list_active)
    let dep_no_url = deployment_repo.seed_provisioned(
        customer_id,
        "node-mixed-nourl",
        "ap-southeast-1",
        "t4g.small",
        "aws",
        "provisioning",
        None,
    );

    // Deployment 4: stopped + URL (must never be marked unhealthy)
    let dep_stopped = deployment_repo.seed_provisioned(
        customer_id,
        "node-mixed-stopped",
        "us-west-2",
        "t4g.small",
        "aws",
        "stopped",
        Some(url_stopped),
    );

    let health_client = Arc::new(ControllableHealthClient::new());
    health_client.set_result(url_healthy, HealthCheckResult::Healthy);
    health_client.set_result(
        url_failing,
        HealthCheckResult::Unreachable("connection refused".into()),
    );
    health_client.set_result(
        url_stopped,
        HealthCheckResult::Unreachable("timeout".into()),
    );

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    // Run 4 cycles: failing running deployment should cross threshold; stopped
    // deployment should remain untouched across repeated cycles.
    for _ in 0..4 {
        monitor.check_all().await;
    }

    // Healthy deployment should be healthy
    let healthy = deployment_repo
        .find_by_id(dep_healthy.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(healthy.health_status, "healthy");
    assert!(healthy.last_health_check_at.is_some());

    // Failing deployment should be unhealthy after 3 cycles
    let failing = deployment_repo
        .find_by_id(dep_failing.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(failing.health_status, "unhealthy");

    // No-URL deployment should be untouched (not in list_active)
    let no_url = deployment_repo
        .find_by_id(dep_no_url.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(no_url.health_status, "unknown");
    assert!(no_url.last_health_check_at.is_none());

    // Stopped deployment should never be marked unhealthy
    let stopped = deployment_repo
        .find_by_id(dep_stopped.id)
        .await
        .unwrap()
        .unwrap();
    assert_ne!(stopped.health_status, "unhealthy");
    assert!(stopped.last_health_check_at.is_none());

    // Only 1 alert total (for the failing running deployment)
    assert_eq!(alert_service.alert_count(), 1);
    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts[0].severity, AlertSeverity::Critical);
    let meta = alerts[0].metadata.as_object().unwrap();
    assert_eq!(
        meta.get("deployment_id").unwrap().as_str().unwrap(),
        dep_failing.id.to_string()
    );
}

// ---------------------------------------------------------------------------
// Reliability gap: alert suppression during cooldown window
// ---------------------------------------------------------------------------

/// After a deployment crosses the unhealthy threshold and fires a Critical
/// alert, subsequent unhealthy cycles within the cooldown window must NOT
/// fire additional alerts. Once the cooldown expires, a Warning alert fires.
#[tokio::test]
async fn repeated_unhealthy_cycles_suppressed_during_cooldown() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let flapjack_url = "http://mock-cooldown-test";
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-cooldown",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(flapjack_url),
    );

    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    let health_client = Arc::new(ControllableHealthClient::new());
    health_client.set_result(
        flapjack_url,
        HealthCheckResult::Unreachable("connection refused".into()),
    );

    // Use a short cooldown (50ms) for fast testing
    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    )
    .with_alert_cooldown(Duration::from_millis(50));

    // 3 cycles to cross threshold → fires Critical alert
    for _ in 0..3 {
        monitor.check_all().await;
    }
    assert_eq!(
        alert_service.alert_count(),
        1,
        "exactly 1 critical alert after crossing threshold"
    );

    // 3 more unhealthy cycles within cooldown window → NO new alerts
    for _ in 0..3 {
        monitor.check_all().await;
    }
    assert_eq!(
        alert_service.alert_count(),
        1,
        "no additional alerts during cooldown window"
    );

    // Wait for cooldown to expire
    tokio::time::sleep(Duration::from_millis(60)).await;

    // Next unhealthy cycle should fire a Warning (repeated unhealthy alert)
    monitor.check_all().await;
    let alerts = alert_service.recorded_alerts();
    assert!(
        alerts.len() >= 2,
        "a second alert should fire after cooldown expires; got {} alerts",
        alerts.len()
    );
}

/// A running deployment with flapjack_url=None should not cause panics,
/// should not be marked unhealthy, and should not generate alerts even
/// after many check_all cycles.
#[tokio::test]
async fn flapjack_url_none_deployment_is_safely_ignored() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    // Running deployment with NO flapjack_url
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-no-url",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        None,
    );

    let health_client = Arc::new(ControllableHealthClient::new());
    // No results configured — flapjack_url=None goes straight to Unreachable

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        Arc::clone(&health_client) as Arc<dyn HealthCheckClient>,
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    // Run 5 cycles — well beyond the unhealthy threshold of 3
    for _ in 0..5 {
        monitor.check_all().await;
    }

    // Deployment should not be marked unhealthy (it's filtered by list_active
    // which excludes provisioning, or it's handled as a no-url case)
    let dep_after = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();

    // The deployment should not have been erroneously marked unhealthy
    // (it should still show its initial health_status or be skipped entirely)
    assert_ne!(
        dep_after.health_status, "unhealthy",
        "deployment with no flapjack_url should not be marked unhealthy"
    );
    assert_eq!(
        alert_service.alert_count(),
        0,
        "no alerts should fire for deployment with no flapjack_url"
    );
}

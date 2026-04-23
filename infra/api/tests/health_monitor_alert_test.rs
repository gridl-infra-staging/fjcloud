mod common;

use std::sync::Arc;
use std::time::Duration;

use api::repos::DeploymentRepo;
use api::services::alerting::{AlertSeverity, MockAlertService};
use api::services::health_monitor::{HealthCheckResult, HealthMonitor};
use uuid::Uuid;

fn build_monitor_with_alerts(
    deployment_repo: Arc<common::MockDeploymentRepo>,
    alert_service: Arc<MockAlertService>,
) -> HealthMonitor {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();

    HealthMonitor::new(
        deployment_repo,
        client,
        Duration::from_millis(100),
        Some(alert_service),
    )
}

fn healthy_result() -> HealthCheckResult {
    HealthCheckResult::Healthy
}

fn unhealthy_result() -> HealthCheckResult {
    HealthCheckResult::Unhealthy("HTTP 500".into())
}

// -----------------------------------------------------------------------
// Test 1: healthy→unhealthy fires critical alert
// -----------------------------------------------------------------------
#[tokio::test]
async fn healthy_to_unhealthy_fires_critical_alert() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    // Seed a running deployment that was previously healthy
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-unhealthy",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://health-check.invalid"),
    );

    // Set initial health to "healthy" (simulating it was healthy before)
    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // Process 3 failures (UNHEALTHY_THRESHOLD) to trigger transition
    for _ in 0..3 {
        monitor.process_result(&dep, &unhealthy_result()).await;
    }

    // Should have fired exactly 1 Critical alert
    let alerts = alert_service.recorded_alerts();
    assert!(
        !alerts.is_empty(),
        "expected at least one alert when deployment transitions to unhealthy"
    );

    let critical_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == AlertSeverity::Critical)
        .collect();
    assert_eq!(
        critical_alerts.len(),
        1,
        "expected exactly 1 critical alert on healthy→unhealthy transition"
    );

    // Verify alert metadata contains deployment info
    let alert = &critical_alerts[0];
    let meta = alert.metadata.as_object().unwrap();
    assert_eq!(meta.get("deployment_id").unwrap(), &dep.id.to_string());
    assert_eq!(meta.get("region").unwrap(), "us-east-1");
    assert!(meta.contains_key("flapjack_url"));
    assert!(alert.title.contains("unhealthy"));
}

// -----------------------------------------------------------------------
// Test 2: unhealthy→healthy fires info recovery alert
// -----------------------------------------------------------------------
#[tokio::test]
async fn unhealthy_to_healthy_fires_info_alert() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-recovery",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://health-check.invalid"),
    );

    // Set health to "unhealthy" (simulating prior failures)
    deployment_repo
        .update_health(dep.id, "unhealthy", chrono::Utc::now())
        .await
        .unwrap();

    // Re-read the deployment so its health_status field reflects the update
    let dep = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // A healthy check should fire a recovery alert
    monitor.process_result(&dep, &healthy_result()).await;

    let alerts = alert_service.recorded_alerts();
    let info_alerts: Vec<_> = alerts
        .iter()
        .filter(|a| a.severity == AlertSeverity::Info)
        .collect();
    assert_eq!(
        info_alerts.len(),
        1,
        "expected exactly 1 info alert on unhealthy→healthy recovery"
    );

    let alert = &info_alerts[0];
    let meta = alert.metadata.as_object().unwrap();
    assert_eq!(meta.get("deployment_id").unwrap(), &dep.id.to_string());
    assert!(alert.title.contains("recovered"));
}

// -----------------------------------------------------------------------
// Test 3: cooldown prevents duplicate unhealthy alerts
// -----------------------------------------------------------------------
#[tokio::test]
async fn cooldown_prevents_duplicate_alerts() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-cooldown",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://health-check.invalid"),
    );

    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // Process 6 failures (well past the threshold of 3)
    for _ in 0..6 {
        monitor.process_result(&dep, &unhealthy_result()).await;
    }

    // Should have exactly 1 alert total (the Critical at threshold crossing).
    // Failures 4, 5, 6 would fire Warning alerts if cooldown was broken,
    // so checking total count catches that regression.
    assert_eq!(
        alert_service.alert_count(),
        1,
        "cooldown should prevent ALL duplicate alerts (Critical + Warning); got {}",
        alert_service.alert_count()
    );

    // And that single alert must be the Critical threshold-crossing alert
    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts[0].severity, AlertSeverity::Critical);
}

// -----------------------------------------------------------------------
// Test 4: provisioning deployment does NOT fire alert
// -----------------------------------------------------------------------
#[tokio::test]
async fn provisioning_deployment_does_not_fire_alert() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    // Provisioning deployment — health check failures are expected during startup
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-provisioning",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
        Some("http://health-check.invalid"),
    );

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // Process multiple failures
    for _ in 0..5 {
        monitor.process_result(&dep, &unhealthy_result()).await;
    }

    // No alerts should fire for provisioning deployments
    assert_eq!(
        alert_service.alert_count(),
        0,
        "provisioning deployment should NOT trigger any alerts"
    );
}

// -----------------------------------------------------------------------
// Test 5: recovery alert includes duration
//
// Simulates two check_all() cycles:
//   Cycle 1: 3 failures cross threshold → deployment marked unhealthy in DB
//   Cycle 2: re-read deployment from DB (now health_status="unhealthy"),
//            healthy check → recovery alert fires with duration
// -----------------------------------------------------------------------
#[tokio::test]
async fn recovery_alert_includes_duration() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-duration",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://health-check.invalid"),
    );

    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // Cycle 1: 3 failures cross UNHEALTHY_THRESHOLD → DB updated to "unhealthy"
    for _ in 0..3 {
        monitor.process_result(&dep, &unhealthy_result()).await;
    }

    // Small delay so duration is measurable
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Cycle 2: Re-read deployment from the store (simulates check_all re-fetching from DB).
    // The health_status is now "unhealthy" from the process_result calls above.
    let recovered_dep = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        recovered_dep.health_status, "unhealthy",
        "after 3 failures, DB should reflect unhealthy status"
    );

    monitor
        .process_result(&recovered_dep, &healthy_result())
        .await;

    // Find the recovery (Info) alert
    let info_alerts: Vec<_> = alert_service
        .recorded_alerts()
        .into_iter()
        .filter(|a| a.severity == AlertSeverity::Info)
        .collect();
    assert_eq!(info_alerts.len(), 1, "expected 1 recovery alert");

    let meta = info_alerts[0].metadata.as_object().unwrap();
    assert!(
        meta.contains_key("unhealthy_duration"),
        "recovery alert should include unhealthy_duration in metadata"
    );
}

// -----------------------------------------------------------------------
// Test 6: stopped deployment responding healthy does NOT fire recovery alert
// -----------------------------------------------------------------------
#[tokio::test]
async fn stopped_deployment_healthy_check_does_not_fire_recovery_alert() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    // Seed a stopped deployment that was previously unhealthy
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-stopped",
        "us-east-1",
        "t4g.small",
        "aws",
        "stopped",
        Some("http://health-check.invalid"),
    );

    deployment_repo
        .update_health(dep.id, "unhealthy", chrono::Utc::now())
        .await
        .unwrap();

    // Re-read so health_status reflects "unhealthy"
    let dep = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(dep.health_status, "unhealthy");
    assert_eq!(dep.status, "stopped");

    let monitor =
        build_monitor_with_alerts(Arc::clone(&deployment_repo), Arc::clone(&alert_service));

    // Process healthy check result for the stopped deployment
    monitor.process_result(&dep, &healthy_result()).await;

    // No alerts should fire — stopped deployments should be ignored
    assert_eq!(
        alert_service.alert_count(),
        0,
        "stopped deployment should NOT trigger recovery alert even if health check succeeds"
    );

    // Health status should NOT be updated to "healthy" for stopped deployments
    let dep_after = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        dep_after.health_status, "unhealthy",
        "stopped deployment health_status should remain unchanged"
    );
}

// -----------------------------------------------------------------------
// Test 7: warning alert fires after cooldown elapses
// -----------------------------------------------------------------------
#[tokio::test]
async fn warning_fires_after_cooldown_elapses() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-alert-cooldown-expiry",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://health-check.invalid"),
    );

    deployment_repo
        .update_health(dep.id, "healthy", chrono::Utc::now())
        .await
        .unwrap();

    // Build monitor with a very short cooldown (50ms) so we can test expiry
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let monitor = HealthMonitor::new(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        client,
        Duration::from_millis(100),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    )
    .with_alert_cooldown(Duration::from_millis(50));

    // Process 3 failures to cross threshold (fires Critical)
    for _ in 0..3 {
        monitor.process_result(&dep, &unhealthy_result()).await;
    }
    assert_eq!(
        alert_service.alert_count(),
        1,
        "should have 1 Critical alert at threshold"
    );

    // Failure 4 immediately — cooldown has NOT elapsed, no Warning
    monitor.process_result(&dep, &unhealthy_result()).await;
    assert_eq!(
        alert_service.alert_count(),
        1,
        "cooldown not elapsed, still 1 alert"
    );

    // Wait for cooldown to elapse
    tokio::time::sleep(Duration::from_millis(60)).await;

    // Failure 5 — cooldown HAS elapsed, should fire Warning
    monitor.process_result(&dep, &unhealthy_result()).await;
    assert_eq!(
        alert_service.alert_count(),
        2,
        "cooldown elapsed, Warning should fire"
    );

    // Verify the second alert is a Warning
    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts[1].severity, AlertSeverity::Warning);
    assert!(alerts[1].title.contains("still unhealthy"));
}

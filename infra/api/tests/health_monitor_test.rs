mod common;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use api::repos::DeploymentRepo;
use api::services::alerting::MockAlertService;
use api::services::health_monitor::{HealthCheckClient, HealthCheckResult, HealthMonitor};
use async_trait::async_trait;
use uuid::Uuid;

fn build_results_map(entries: &[(&str, HealthCheckResult)]) -> HashMap<String, HealthCheckResult> {
    let mut results = HashMap::new();
    for (url, result) in entries {
        results.insert((*url).to_string(), result.clone());
    }
    results
}

fn missing_url_result() -> HealthCheckResult {
    HealthCheckResult::Unreachable("no flapjack_url set".into())
}

fn result_for_url(
    results: &HashMap<String, HealthCheckResult>,
    flapjack_url: &str,
) -> HealthCheckResult {
    results
        .get(flapjack_url)
        .cloned()
        .unwrap_or_else(|| HealthCheckResult::Unreachable("connection refused".into()))
}

struct MockHealthClient {
    results: HashMap<String, HealthCheckResult>,
}

impl MockHealthClient {
    fn with_results(entries: &[(&str, HealthCheckResult)]) -> Arc<dyn HealthCheckClient> {
        Arc::new(Self {
            results: build_results_map(entries),
        })
    }
}

#[async_trait]
impl HealthCheckClient for MockHealthClient {
    async fn check(&self, flapjack_url: Option<String>) -> HealthCheckResult {
        match flapjack_url {
            Some(url) => result_for_url(&self.results, &url),
            None => missing_url_result(),
        }
    }
}

struct TimedHealthClient {
    results: HashMap<String, HealthCheckResult>,
    delayed_url: String,
    delay: Duration,
    started_at: Mutex<HashMap<String, Instant>>,
    completed_at: Mutex<HashMap<String, Instant>>,
}

impl TimedHealthClient {
    fn with_delay(
        entries: &[(&str, HealthCheckResult)],
        delayed_url: &str,
        delay: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            results: build_results_map(entries),
            delayed_url: delayed_url.to_string(),
            delay,
            started_at: Mutex::new(HashMap::new()),
            completed_at: Mutex::new(HashMap::new()),
        })
    }

    fn start_time(&self, url: &str) -> Option<Instant> {
        self.started_at.lock().unwrap().get(url).cloned()
    }

    fn completion_time(&self, url: &str) -> Option<Instant> {
        self.completed_at.lock().unwrap().get(url).cloned()
    }
}

#[async_trait]
impl HealthCheckClient for TimedHealthClient {
    async fn check(&self, flapjack_url: Option<String>) -> HealthCheckResult {
        match flapjack_url {
            Some(url) => {
                self.started_at
                    .lock()
                    .unwrap()
                    .insert(url.clone(), Instant::now());

                if url == self.delayed_url {
                    tokio::time::sleep(self.delay).await;
                }

                let result = result_for_url(&self.results, &url);
                self.completed_at
                    .lock()
                    .unwrap()
                    .insert(url, Instant::now());
                result
            }
            None => missing_url_result(),
        }
    }
}

fn build_monitor(
    deployment_repo: Arc<common::MockDeploymentRepo>,
    health_client: Arc<dyn HealthCheckClient>,
) -> HealthMonitor {
    HealthMonitor::new_with_health_client(
        deployment_repo,
        health_client,
        Duration::from_millis(100),
        None,
    )
}

// -----------------------------------------------------------------------
// Test 1: healthy VM updates health_status
// -----------------------------------------------------------------------
#[tokio::test]
async fn healthy_vm_updates_health_status() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    let base_url = "http://mock-healthy";

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-healthy",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(base_url),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[(base_url, HealthCheckResult::Healthy)]),
    );

    let result = monitor.check_deployment(&dep).await;
    assert_eq!(result, HealthCheckResult::Healthy);

    monitor.process_result(&dep, &result).await;

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(updated.health_status, "healthy");
    assert!(updated.last_health_check_at.is_some());
}

// -----------------------------------------------------------------------
// Test 2: provisioning→running transition on first healthy check
// -----------------------------------------------------------------------
#[tokio::test]
async fn provisioning_to_running_on_healthy_check() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    let base_url = "http://mock-healthy";

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-provisioning",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
        Some(base_url),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[(base_url, HealthCheckResult::Healthy)]),
    );

    let result = monitor.check_deployment(&dep).await;
    assert_eq!(result, HealthCheckResult::Healthy);

    monitor.process_result(&dep, &result).await;

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "running",
        "provisioning deployment should transition to running on healthy check"
    );
    assert_eq!(updated.health_status, "healthy");
}

// -----------------------------------------------------------------------
// Test 3: consecutive failures mark unhealthy only after 3
// -----------------------------------------------------------------------
#[tokio::test]
async fn consecutive_failures_mark_unhealthy_after_threshold() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    let base_url = "http://mock-unhealthy";

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-failing",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(base_url),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[(
            base_url,
            HealthCheckResult::Unhealthy("HTTP 500 Internal Server Error".into()),
        )]),
    );

    // Failures 1 and 2 should NOT mark unhealthy
    for i in 0..2 {
        let result = monitor.check_deployment(&dep).await;
        assert!(
            matches!(result, HealthCheckResult::Unhealthy(_)),
            "check {i} should return Unhealthy"
        );
        monitor.process_result(&dep, &result).await;

        let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
        assert_ne!(
            updated.health_status,
            "unhealthy",
            "should NOT be unhealthy after only {} failure(s)",
            i + 1
        );
    }

    // Failure 3 SHOULD mark unhealthy
    let result = monitor.check_deployment(&dep).await;
    monitor.process_result(&dep, &result).await;

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        updated.health_status, "unhealthy",
        "should be unhealthy after 3 consecutive failures"
    );
    // Status should remain "running" — ops decision, not auto-change
    assert_eq!(
        updated.status, "running",
        "deployment status should NOT change on unhealthy"
    );
}

// -----------------------------------------------------------------------
// Test 4: recovery resets to healthy
// -----------------------------------------------------------------------
#[tokio::test]
async fn recovery_resets_to_healthy() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    // Start with a healthy server, but we'll simulate the unhealthy state directly
    let base_url = "http://mock-healthy";

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-recovering",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(base_url),
    );

    // Manually set health_status to unhealthy (simulating prior failures)
    deployment_repo
        .update_health(dep.id, "unhealthy", chrono::Utc::now())
        .await
        .unwrap();

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[(base_url, HealthCheckResult::Healthy)]),
    );

    // A healthy check should reset to healthy
    let result = monitor.check_deployment(&dep).await;
    assert_eq!(result, HealthCheckResult::Healthy);
    monitor.process_result(&dep, &result).await;

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        updated.health_status, "healthy",
        "recovery should reset health_status to healthy"
    );
}

// -----------------------------------------------------------------------
// Test 5: unreachable counts as failure
// -----------------------------------------------------------------------
#[tokio::test]
async fn unreachable_counts_as_failure() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    // Use a URL that will fail to connect (nothing listening on this port)
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-unreachable",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:1"), // port 1 — unreachable
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[]),
    );

    let result = monitor.check_deployment(&dep).await;
    assert!(
        matches!(result, HealthCheckResult::Unreachable(_)),
        "should be Unreachable, got: {result:?}"
    );

    // Process 3 unreachable results to trigger unhealthy
    for _ in 0..3 {
        let result = monitor.check_deployment(&dep).await;
        monitor.process_result(&dep, &result).await;
    }

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(
        updated.health_status, "unhealthy",
        "3 unreachable results should mark deployment as unhealthy"
    );
}

// -----------------------------------------------------------------------
// Test 6: deployments without flapjack_url skipped
// -----------------------------------------------------------------------
#[tokio::test]
async fn deployments_without_flapjack_url_skipped() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    // Seed a deployment with flapjack_url = None (still provisioning)
    let dep_no_url = deployment_repo.seed_provisioned(
        customer_id,
        "node-no-url",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
        None,
    );

    // Also seed one with a URL that would be healthy
    let base_url = "http://mock-healthy";
    let dep_with_url = deployment_repo.seed_provisioned(
        customer_id,
        "node-has-url",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(base_url),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[(base_url, HealthCheckResult::Healthy)]),
    );

    // check_all should only process deployments returned by list_active(),
    // which filters out those without flapjack_url
    monitor.check_all().await;

    // The deployment with a URL should have been checked
    let updated = deployment_repo
        .find_by_id(dep_with_url.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        updated.health_status, "healthy",
        "deployment with URL should be health-checked"
    );
    assert!(updated.last_health_check_at.is_some());

    // The deployment without a URL should NOT have been touched
    // (list_active filters it out, so health_status stays "unknown")
    let skipped = deployment_repo
        .find_by_id(dep_no_url.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        skipped.health_status, "unknown",
        "deployment without flapjack_url should not be health-checked"
    );
    assert!(
        skipped.last_health_check_at.is_none(),
        "deployment without flapjack_url should have no health check timestamp"
    );
}

// -----------------------------------------------------------------------
// Test 7: check_all processes multiple deployments concurrently
// -----------------------------------------------------------------------
#[tokio::test]
async fn check_all_processes_multiple_deployments_concurrently() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    // Simulate two distinct healthy endpoints.
    let url_a = "http://mock-healthy-a";
    let url_b = "http://mock-healthy-b";

    // Two deployments, each with its own flapjack_url
    let dep_a = deployment_repo.seed_provisioned(
        customer_id,
        "node-concurrent-a",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(url_a),
    );
    let dep_b = deployment_repo.seed_provisioned(
        customer_id,
        "node-concurrent-b",
        "eu-west-1",
        "t4g.small",
        "aws",
        "provisioning",
        Some(url_b),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[
            (url_a, HealthCheckResult::Healthy),
            (url_b, HealthCheckResult::Healthy),
        ]),
    );

    // Single check_all should process BOTH deployments
    monitor.check_all().await;

    let updated_a = deployment_repo.find_by_id(dep_a.id).await.unwrap().unwrap();
    assert_eq!(
        updated_a.health_status, "healthy",
        "deployment A should be marked healthy after check_all"
    );
    assert!(updated_a.last_health_check_at.is_some());

    let updated_b = deployment_repo.find_by_id(dep_b.id).await.unwrap().unwrap();
    assert_eq!(
        updated_b.health_status, "healthy",
        "deployment B should be marked healthy after check_all"
    );
    // Provisioning deployment should transition to running on healthy check
    assert_eq!(
        updated_b.status, "running",
        "provisioning deployment B should transition to running"
    );
}

#[tokio::test]
async fn check_all_with_one_slow_health_check_does_not_block_others() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    let fast_healthy_url = "http://mock-fast-healthy";
    let slow_url = "http://mock-slow";
    let fast_recovery_url = "http://mock-fast-recovery";
    let slow_delay = Duration::from_millis(200);

    let dep_slow = deployment_repo.seed_provisioned(
        customer_id,
        "node-concurrent-slow",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(slow_url),
    );

    let dep_fast_healthy = deployment_repo.seed_provisioned(
        customer_id,
        "node-concurrent-fast-healthy",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(fast_healthy_url),
    );

    let dep_fast_recovery = deployment_repo.seed_provisioned(
        customer_id,
        "node-concurrent-fast-recovery",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(fast_recovery_url),
    );

    let stale_time = chrono::Utc::now() - chrono::Duration::seconds(120);
    deployment_repo
        .update_health(dep_fast_recovery.id, "unhealthy", stale_time)
        .await
        .unwrap();

    let timed_client = TimedHealthClient::with_delay(
        &[
            (fast_healthy_url, HealthCheckResult::Healthy),
            (slow_url, HealthCheckResult::Healthy),
            (fast_recovery_url, HealthCheckResult::Healthy),
        ],
        slow_url,
        slow_delay,
    );

    // Safety: we need to retrieve start times later for concurrency assertions.
    let start_probe = Arc::clone(&timed_client);
    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        timed_client as Arc<dyn HealthCheckClient>,
    );

    monitor.check_all().await;

    let slow_started_at = start_probe.start_time(slow_url).unwrap();
    let fast_recovery_started_at = start_probe
        .start_time(fast_recovery_url)
        .expect("fast recovery deployment should have been checked");
    let fast_healthy_started_at = start_probe
        .start_time(fast_healthy_url)
        .expect("fast healthy deployment should have been checked");
    let slow_finished_at = start_probe
        .completion_time(slow_url)
        .expect("slow deployment should have completed after delay");

    assert!(
        fast_recovery_started_at < slow_finished_at,
        "slow checks should not block later checks from starting"
    );
    assert!(
        fast_healthy_started_at < slow_finished_at,
        "slow checks should not block earlier peers from starting"
    );
    assert!(
        slow_started_at < slow_finished_at,
        "slow check should have measurable delayed execution"
    );

    let fast_healthy_after = deployment_repo
        .find_by_id(dep_fast_healthy.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        fast_healthy_after.health_status, "healthy",
        "fast deployment should be marked healthy despite slow peer"
    );

    let fast_recovery_after = deployment_repo
        .find_by_id(dep_fast_recovery.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        fast_recovery_after.health_status, "healthy",
        "unhealthy deployment should recover when checked promptly"
    );

    let slow_after = deployment_repo
        .find_by_id(dep_slow.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        slow_after.health_status, "healthy",
        "delayed deployment should also be processed"
    );
}

#[tokio::test]
async fn check_all_with_no_active_deployments_is_safe() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        MockHealthClient::with_results(&[]),
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    let result = tokio::time::timeout(Duration::from_millis(200), monitor.check_all()).await;
    assert!(
        result.is_ok(),
        "check_all should complete with no deployments and not block forever"
    );
    assert_eq!(
        alert_service.alert_count(),
        0,
        "no alerts should fire when there are no checked deployments"
    );
}

#[tokio::test]
async fn healthy_running_deployment_no_op_has_no_spurious_alerts() {
    let deployment_repo = common::mock_deployment_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer_id = Uuid::new_v4();

    let base_url = "http://mock-healthy-repeat";
    let dep_seed = deployment_repo.seed_provisioned(
        customer_id,
        "node-healthy-noop",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some(base_url),
    );

    let baseline_time = chrono::Utc::now() - chrono::Duration::seconds(30);
    deployment_repo
        .update_health(dep_seed.id, "healthy", baseline_time)
        .await
        .unwrap();
    let dep_seed = deployment_repo
        .find_by_id(dep_seed.id)
        .await
        .unwrap()
        .unwrap();

    let monitor = HealthMonitor::new_with_health_client(
        Arc::clone(&deployment_repo) as Arc<dyn DeploymentRepo + Send + Sync>,
        MockHealthClient::with_results(&[(base_url, HealthCheckResult::Healthy)]),
        Duration::from_millis(10),
        Some(Arc::clone(&alert_service) as Arc<dyn api::services::alerting::AlertService>),
    );

    monitor.check_all().await;
    let first_check = deployment_repo
        .find_by_id(dep_seed.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first_check.health_status, "healthy");
    assert_eq!(first_check.status, "running");
    assert!(first_check.last_health_check_at.is_some());
    assert!(
        first_check.last_health_check_at.unwrap() > baseline_time,
        "healthy check should refresh last_health_check_at"
    );

    monitor.check_all().await;
    let second_check = deployment_repo
        .find_by_id(dep_seed.id)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(second_check.health_status, "healthy");
    assert_eq!(second_check.status, "running");
    assert!(
        second_check.last_health_check_at.unwrap() > first_check.last_health_check_at.unwrap(),
        "repeated healthy checks should refresh last_health_check_at"
    );
    assert_eq!(second_check.customer_id, first_check.customer_id);
    assert_eq!(second_check.node_id, first_check.node_id);
    assert_eq!(second_check.region, first_check.region);
    assert_eq!(second_check.vm_type, first_check.vm_type);
    assert_eq!(second_check.vm_provider, first_check.vm_provider);
    assert_eq!(second_check.ip_address, first_check.ip_address);
    assert_eq!(second_check.provider_vm_id, first_check.provider_vm_id);
    assert_eq!(second_check.hostname, first_check.hostname);
    assert_eq!(second_check.flapjack_url, first_check.flapjack_url);
    assert_eq!(second_check.created_at, first_check.created_at);
    assert_eq!(second_check.terminated_at, first_check.terminated_at);
    assert_eq!(alert_service.alert_count(), 0);
}

// -----------------------------------------------------------------------
// Test 8: stopped deployment NOT marked unhealthy (failures are expected)
// -----------------------------------------------------------------------
#[tokio::test]
async fn stopped_deployment_not_marked_unhealthy() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    // Use a URL that will fail to connect (port 1 — nothing listening)
    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-stopped-vm",
        "us-east-1",
        "t4g.small",
        "aws",
        "stopped",
        Some("http://127.0.0.1:1"),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[]),
    );

    // Process 4 failures (more than the threshold of 3)
    for _ in 0..4 {
        let result = monitor.check_deployment(&dep).await;
        assert!(matches!(result, HealthCheckResult::Unreachable(_)));
        monitor.process_result(&dep, &result).await;
    }

    // Stopped deployment should NOT be marked unhealthy — failures are expected
    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_ne!(
        updated.health_status, "unhealthy",
        "stopped deployment must NOT be marked unhealthy — health check failures are expected for stopped VMs"
    );
}

// -----------------------------------------------------------------------
// Test 9: failed deployment NOT marked unhealthy (failures are expected)
// -----------------------------------------------------------------------
#[tokio::test]
async fn failed_deployment_not_marked_unhealthy() {
    let deployment_repo = common::mock_deployment_repo();
    let customer_id = Uuid::new_v4();

    let dep = deployment_repo.seed_provisioned(
        customer_id,
        "node-failed-vm",
        "us-east-1",
        "t4g.small",
        "aws",
        "failed",
        Some("http://127.0.0.1:1"),
    );

    let monitor = build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[]),
    );

    for _ in 0..4 {
        let result = monitor.check_deployment(&dep).await;
        monitor.process_result(&dep, &result).await;
    }

    let updated = deployment_repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_ne!(
        updated.health_status, "unhealthy",
        "failed deployment must NOT be marked unhealthy — health check failures are expected"
    );
}

// -----------------------------------------------------------------------
// Test 10: respects shutdown signal
// -----------------------------------------------------------------------
#[tokio::test]
async fn respects_shutdown_signal() {
    let deployment_repo = common::mock_deployment_repo();

    let monitor = Arc::new(build_monitor(
        Arc::clone(&deployment_repo),
        MockHealthClient::with_results(&[]),
    ));
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    // Start the monitor in a background task
    let monitor_clone = Arc::clone(&monitor);
    let handle = tokio::spawn(async move {
        monitor_clone.run(shutdown_rx).await;
    });

    // Give it a moment to start
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Send shutdown signal
    shutdown_tx.send(true).unwrap();

    // The monitor should exit promptly (within 1 second)
    let result = tokio::time::timeout(Duration::from_secs(1), handle).await;
    assert!(
        result.is_ok(),
        "health monitor should shut down within 1 second of shutdown signal"
    );
}

//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/health_monitor.rs.
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::Utc;
use tokio::sync::watch;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::models::Deployment;
use crate::repos::DeploymentRepo;
use crate::services::alerting::{Alert, AlertService, AlertSeverity};

/// Number of consecutive health check failures before marking a deployment as unhealthy.
const UNHEALTHY_THRESHOLD: u32 = 3;

/// Minimum interval between repeated "still unhealthy" warning alerts for the same deployment.
const ALERT_COOLDOWN: Duration = Duration::from_secs(600); // 10 minutes

/// Result of a single health check against a deployment's flapjack URL.
#[derive(Debug, Clone, PartialEq)]
pub enum HealthCheckResult {
    Healthy,
    Unhealthy(String),
    Unreachable(String),
}

#[async_trait]
pub trait HealthCheckClient: Send + Sync {
    async fn check(&self, flapjack_url: Option<String>) -> HealthCheckResult;
}

pub struct ReqwestHealthCheckClient {
    client: reqwest::Client,
}

impl ReqwestHealthCheckClient {
    pub fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl HealthCheckClient for ReqwestHealthCheckClient {
    async fn check(&self, flapjack_url: Option<String>) -> HealthCheckResult {
        check_health(self.client.clone(), flapjack_url).await
    }
}

/// Perform a single HTTP health check against a flapjack URL.
/// Standalone function (no &self) so it can be spawned as a concurrent task.
async fn check_health(client: reqwest::Client, flapjack_url: Option<String>) -> HealthCheckResult {
    let flapjack_url = match flapjack_url.as_deref() {
        Some(url) => url,
        None => return HealthCheckResult::Unreachable("no flapjack_url set".into()),
    };

    let health_url = format!("{flapjack_url}/health");

    match client.get(&health_url).send().await {
        Ok(resp) if resp.status().is_success() => HealthCheckResult::Healthy,
        Ok(resp) => HealthCheckResult::Unhealthy(format!("HTTP {}", resp.status())),
        Err(e) => HealthCheckResult::Unreachable(e.to_string()),
    }
}

/// Background health monitor that polls `/health` on all active VMs.
pub struct HealthMonitor {
    deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
    health_client: Arc<dyn HealthCheckClient>,
    check_interval: Duration,
    failure_counts: std::sync::Mutex<HashMap<Uuid, u32>>,
    alert_service: Option<Arc<dyn AlertService>>,
    /// Tracks when each deployment first became unhealthy (for recovery duration).
    unhealthy_since: std::sync::Mutex<HashMap<Uuid, Instant>>,
    /// Tracks last alert time per deployment to enforce cooldown.
    last_alert_at: std::sync::Mutex<HashMap<Uuid, Instant>>,
    /// Minimum interval between repeated "still unhealthy" warning alerts per deployment.
    alert_cooldown: Duration,
}

impl HealthMonitor {
    pub fn new(
        deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
        http_client: reqwest::Client,
        check_interval: Duration,
        alert_service: Option<Arc<dyn AlertService>>,
    ) -> Self {
        let health_client: Arc<dyn HealthCheckClient> =
            Arc::new(ReqwestHealthCheckClient::new(http_client));
        Self::new_with_health_client(
            deployment_repo,
            health_client,
            check_interval,
            alert_service,
        )
    }

    /// Constructs the health monitor with an injected [`HealthCheckClient`]
    /// (for testability), deployment repo, check interval, and optional alert
    /// service.
    ///
    /// Initializes empty failure-count, unhealthy-since, and last-alert-at
    /// tracking maps, and sets the alert cooldown to the default 10-minute
    /// interval.
    pub fn new_with_health_client(
        deployment_repo: Arc<dyn DeploymentRepo + Send + Sync>,
        health_client: Arc<dyn HealthCheckClient>,
        check_interval: Duration,
        alert_service: Option<Arc<dyn AlertService>>,
    ) -> Self {
        Self {
            deployment_repo,
            health_client,
            check_interval,
            failure_counts: std::sync::Mutex::new(HashMap::new()),
            alert_service,
            unhealthy_since: std::sync::Mutex::new(HashMap::new()),
            last_alert_at: std::sync::Mutex::new(HashMap::new()),
            alert_cooldown: ALERT_COOLDOWN,
        }
    }

    /// Override the default alert cooldown duration. Useful for testing.
    pub fn with_alert_cooldown(mut self, cooldown: Duration) -> Self {
        self.alert_cooldown = cooldown;
        self
    }

    /// Main loop: poll active deployments, update health status. Respects shutdown signal.
    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) {
        info!("health monitor started, interval={:?}", self.check_interval);

        loop {
            tokio::select! {
                _ = tokio::time::sleep(self.check_interval) => {
                    self.check_all().await;
                }
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("health monitor shutting down");
                        return;
                    }
                }
            }
        }
    }

    /// Check a single deployment's health endpoint.
    pub async fn check_deployment(&self, deployment: &Deployment) -> HealthCheckResult {
        self.health_client
            .check(deployment.flapjack_url.clone())
            .await
    }

    /// Fire an alert (if alert_service is configured). Errors are logged, never propagated.
    async fn fire_alert(
        &self,
        severity: AlertSeverity,
        title: String,
        message: String,
        metadata: HashMap<String, String>,
    ) {
        if let Some(svc) = &self.alert_service {
            let alert = Alert {
                severity,
                title,
                message,
                metadata,
            };
            if let Err(e) = svc.send_alert(alert).await {
                error!("failed to send health alert: {e}");
            }
        }
    }

    /// Process health check results: dispatches to `handle_healthy_result` or
    /// `handle_unhealthy_result` based on the check outcome.
    pub async fn process_result(&self, deployment: &Deployment, result: &HealthCheckResult) {
        match result {
            HealthCheckResult::Healthy => {
                self.handle_healthy_result(deployment).await;
            }
            HealthCheckResult::Unhealthy(reason) | HealthCheckResult::Unreachable(reason) => {
                self.handle_unhealthy_result(deployment, reason).await;
            }
        }
    }

    /// Handles a healthy check result: resets failure tracking, fires recovery
    /// alerts for previously unhealthy deployments, transitions provisioning→running,
    /// and updates health status to healthy.
    async fn handle_healthy_result(&self, deployment: &Deployment) {
        // Only process healthy results for running/provisioning deployments.
        // Stopped/failed deployments that briefly respond during shutdown
        // should not trigger recovery alerts or health status updates.
        if deployment.status != "running" && deployment.status != "provisioning" {
            return;
        }

        let now = Utc::now();

        // Reset failure count
        {
            let mut counts = self.failure_counts.lock().unwrap();
            counts.remove(&deployment.id);
        }

        // Fire recovery alert if deployment was previously unhealthy
        if deployment.health_status == "unhealthy" {
            let duration_str = {
                let mut unhealthy_since = self.unhealthy_since.lock().unwrap();
                unhealthy_since
                    .remove(&deployment.id)
                    .map(|since| {
                        let secs = since.elapsed().as_secs();
                        if secs < 60 {
                            format!("{secs}s")
                        } else {
                            format!("{}m {}s", secs / 60, secs % 60)
                        }
                    })
                    .unwrap_or_else(|| "unknown".to_string())
            };

            // Clean up cooldown tracking
            {
                let mut last_alert = self.last_alert_at.lock().unwrap();
                last_alert.remove(&deployment.id);
            }

            let mut metadata = HashMap::new();
            metadata.insert("deployment_id".to_string(), deployment.id.to_string());
            metadata.insert("region".to_string(), deployment.region.clone());
            metadata.insert("unhealthy_duration".to_string(), duration_str.clone());

            self.fire_alert(
                AlertSeverity::Info,
                format!("Deployment recovered — {}", deployment.id),
                format!(
                    "Deployment {} in {} recovered after being unhealthy for {duration_str}",
                    deployment.id, deployment.region
                ),
                metadata,
            )
            .await;
        }

        // Transition provisioning→running on first healthy check
        if deployment.status == "provisioning" {
            if let Err(e) = self
                .deployment_repo
                .update(deployment.id, None, Some("running"))
                .await
            {
                error!(
                    "failed to transition deployment {} to running: {e}",
                    deployment.id
                );
            } else {
                info!(
                    "deployment {} transitioned from provisioning to running",
                    deployment.id
                );
            }
        }

        // Update health status to healthy
        if let Err(e) = self
            .deployment_repo
            .update_health(deployment.id, "healthy", now)
            .await
        {
            error!(
                "failed to update health status for deployment {}: {e}",
                deployment.id
            );
        }
    }

    /// Handles an unhealthy/unreachable check result: increments failure count,
    /// marks deployment unhealthy after threshold, fires threshold-crossing and
    /// cooldown-gated repeated alerts.
    async fn handle_unhealthy_result(&self, deployment: &Deployment, reason: &str) {
        // Only track failures and mark unhealthy for `running` deployments.
        // Stopped/failed deployments failing health checks is expected.
        if deployment.status != "running" {
            return;
        }

        let now = Utc::now();

        let count = {
            let mut counts = self.failure_counts.lock().unwrap();
            let count = counts.entry(deployment.id).or_insert(0);
            *count += 1;
            *count
        };

        if count < UNHEALTHY_THRESHOLD {
            return;
        }

        // Mark as unhealthy (but do NOT change deployment status)
        if let Err(e) = self
            .deployment_repo
            .update_health(deployment.id, "unhealthy", now)
            .await
        {
            error!(
                "failed to update health status for deployment {}: {e}",
                deployment.id
            );
        }

        if count == UNHEALTHY_THRESHOLD {
            self.fire_initial_unhealthy_alert(deployment, reason, count)
                .await;
        } else {
            self.fire_repeated_unhealthy_alert(deployment, count).await;
        }
    }

    /// Fires the initial critical alert when a deployment first crosses the
    /// unhealthy threshold, and records the unhealthy-since timestamp.
    async fn fire_initial_unhealthy_alert(
        &self,
        deployment: &Deployment,
        reason: &str,
        count: u32,
    ) {
        warn!(
            "deployment {} marked unhealthy after {count} consecutive failures: {reason}",
            deployment.id
        );

        {
            let mut unhealthy_since = self.unhealthy_since.lock().unwrap();
            unhealthy_since.insert(deployment.id, Instant::now());
        }

        let mut metadata = HashMap::new();
        metadata.insert("deployment_id".to_string(), deployment.id.to_string());
        metadata.insert("region".to_string(), deployment.region.clone());
        metadata.insert(
            "flapjack_url".to_string(),
            deployment.flapjack_url.clone().unwrap_or_default(),
        );
        metadata.insert("failure_reason".to_string(), reason.to_string());
        metadata.insert("failure_count".to_string(), count.to_string());

        self.fire_alert(
            AlertSeverity::Critical,
            format!("Deployment unhealthy — {}", deployment.id),
            format!(
                "Deployment {} in {} marked unhealthy after {count} consecutive failures: {reason}",
                deployment.id, deployment.region
            ),
            metadata,
        )
        .await;

        {
            let mut last_alert = self.last_alert_at.lock().unwrap();
            last_alert.insert(deployment.id, Instant::now());
        }
    }

    /// Fires a repeated "still unhealthy" warning if the alert cooldown has elapsed.
    async fn fire_repeated_unhealthy_alert(&self, deployment: &Deployment, count: u32) {
        let should_alert = {
            let last_alert = self.last_alert_at.lock().unwrap();
            match last_alert.get(&deployment.id) {
                Some(last) => last.elapsed() >= self.alert_cooldown,
                None => true,
            }
        };

        if !should_alert {
            return;
        }

        let mut metadata = HashMap::new();
        metadata.insert("deployment_id".to_string(), deployment.id.to_string());
        metadata.insert("region".to_string(), deployment.region.clone());
        metadata.insert("failure_count".to_string(), count.to_string());

        self.fire_alert(
            AlertSeverity::Warning,
            format!("Deployment still unhealthy — {}", deployment.id),
            format!(
                "Deployment {} in {} still unhealthy ({count} consecutive failures)",
                deployment.id, deployment.region
            ),
            metadata,
        )
        .await;

        let mut last_alert = self.last_alert_at.lock().unwrap();
        last_alert.insert(deployment.id, Instant::now());
    }

    /// Run a single health check cycle across all active deployments.
    /// Health checks are performed concurrently using `JoinSet` to avoid
    /// O(n * timeout) latency with many VMs.
    pub async fn check_all(&self) {
        let deployments = match self.deployment_repo.list_active().await {
            Ok(deps) => deps,
            Err(e) => {
                error!("failed to list active deployments: {e}");
                return;
            }
        };

        // Spawn all health checks concurrently
        let mut set = tokio::task::JoinSet::new();
        for deployment in &deployments {
            let health_client = Arc::clone(&self.health_client);
            let flapjack_url = deployment.flapjack_url.clone();
            let deployment_id = deployment.id;
            set.spawn(async move { (deployment_id, health_client.check(flapjack_url).await) });
        }

        // Collect results
        let mut results: Vec<(Uuid, HealthCheckResult)> = Vec::new();
        while let Some(res) = set.join_next().await {
            match res {
                Ok(pair) => results.push(pair),
                Err(e) => error!("health check task panicked: {e}"),
            }
        }

        // Process results sequentially (updates failure_counts and DB)
        for (deployment_id, result) in &results {
            if let Some(deployment) = deployments.iter().find(|d| d.id == *deployment_id) {
                self.process_result(deployment, result).await;
            }
        }

        // Prune tracking state for deployments no longer in the active list.
        // Without this, terminated/deleted deployments leak entries indefinitely.
        {
            let active_ids: std::collections::HashSet<Uuid> =
                deployments.iter().map(|d| d.id).collect();
            self.failure_counts
                .lock()
                .unwrap()
                .retain(|id, _| active_ids.contains(id));
            self.unhealthy_since
                .lock()
                .unwrap()
                .retain(|id, _| active_ids.contains(id));
            self.last_alert_at
                .lock()
                .unwrap()
                .retain(|id, _| active_ids.contains(id));
        }
    }
}

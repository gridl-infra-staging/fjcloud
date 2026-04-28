mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use api::provisioner::mock::MockVmProvisioner;
use api::repos::error::RepoError;
use api::repos::index_replica_repo::IndexReplicaRepo;
use api::repos::usage_repo::{UsageRepo, UsageSummary};
use api::repos::DeploymentRepo;
use api::secrets::mock::MockNodeSecretManager;
use api::services::migration::{MigrationHttpClientError, MigrationHttpResponse};
use api::services::provisioning::{ProvisioningError, ProvisioningService, DEFAULT_DNS_DOMAIN};
use api::services::replication::ReplicationConfig;
use api::{models::UsageDaily, router::build_router};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Duration, NaiveDate, Utc};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

type ProvisioningFailureHarness = (
    Arc<ProvisioningService>,
    Arc<common::MockDeploymentRepo>,
    Arc<MockVmProvisioner>,
    Arc<MockNodeSecretManager>,
);

#[derive(Clone)]
struct FlakyUsageRepo {
    inner: Arc<common::MockUsageRepo>,
    disconnected: Arc<AtomicBool>,
    calls: Arc<AtomicUsize>,
}

impl FlakyUsageRepo {
    fn new() -> Self {
        Self {
            inner: Arc::new(common::MockUsageRepo::new()),
            disconnected: Arc::new(AtomicBool::new(true)),
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn set_disconnected(&self, disconnected: bool) {
        self.disconnected.store(disconnected, Ordering::SeqCst);
    }

    #[allow(clippy::too_many_arguments)]
    fn seed(
        &self,
        customer_id: Uuid,
        date: NaiveDate,
        region: &str,
        search_requests: i64,
        write_operations: i64,
        storage_bytes_avg: i64,
        documents_count_avg: i64,
    ) {
        self.inner.seed(
            customer_id,
            date,
            region,
            search_requests,
            write_operations,
            storage_bytes_avg,
            documents_count_avg,
        );
    }

    fn call_count(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl UsageRepo for FlakyUsageRepo {
    async fn get_daily_usage(
        &self,
        customer_id: Uuid,
        start_date: NaiveDate,
        end_date: NaiveDate,
    ) -> Result<Vec<UsageDaily>, RepoError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(RepoError::Other("metering db disconnected".to_string()));
        }
        self.inner
            .get_daily_usage(customer_id, start_date, end_date)
            .await
    }

    async fn get_monthly_search_count(
        &self,
        customer_id: Uuid,
        year: i32,
        month: u32,
    ) -> Result<i64, RepoError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(RepoError::Other("metering db disconnected".to_string()));
        }
        self.inner
            .get_monthly_search_count(customer_id, year, month)
            .await
    }

    async fn summary_for(&self, customer_id: Uuid, days: u32) -> Result<UsageSummary, RepoError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.disconnected.load(Ordering::SeqCst) {
            return Err(RepoError::Other("metering db disconnected".to_string()));
        }
        self.inner.summary_for(customer_id, days).await
    }
}

async fn setup_replication_failure_harness() -> common::ReplicationHarness {
    common::setup_replication_harness(ReplicationConfig::default(), true).await
}

fn setup_provisioning_failure_harness() -> ProvisioningFailureHarness {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let vm_provisioner = common::mock_vm_provisioner();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();

    let svc = Arc::new(ProvisioningService::new(
        vm_provisioner.clone(),
        dns_manager,
        node_secret_manager.clone(),
        deployment_repo.clone(),
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    ));

    (svc, deployment_repo, vm_provisioner, node_secret_manager)
}

#[tokio::test]
async fn flapjack_crash_during_replication_marks_failed_without_progressing_state() {
    let h = setup_replication_failure_harness().await;

    h.http_client
        .enqueue(Err(MigrationHttpClientError::Unreachable(
            "connection refused".to_string(),
        )));

    h.orchestrator.run_cycle().await;

    let updated = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_ne!(
        updated.status, "active",
        "replica must not transition to active after flapjack crash"
    );
    assert_eq!(
        h.http_client.recorded_requests().len(),
        1,
        "failure injection path should remain bounded to a single outbound call in one cycle"
    );
}

#[tokio::test]
async fn api_kill_during_mutation_rolls_back_without_orphaned_state() {
    let (svc, deployment_repo, vm_provisioner, node_secret_manager) =
        setup_provisioning_failure_harness();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "rollback-index",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    vm_provisioner.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(
        result,
        Err(ProvisioningError::ProvisionerFailed(_))
    ));
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "secret must be cleaned up after crash-like provisioning failure"
    );
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "no VM should remain allocated after rollback"
    );

    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");
    assert!(
        updated.provider_vm_id.is_none(),
        "failed deployment must not keep a provider VM marker"
    );
}

#[tokio::test]
async fn metering_db_disconnect_returns_500_with_bounded_attempts_then_recovers() {
    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let flaky_usage_repo = FlakyUsageRepo::new();

    let mut state = common::test_state_with_repo(customer_repo);
    state.usage_repo = Arc::new(flaky_usage_repo.clone());
    let app = build_router(state);
    let jwt = common::create_test_jwt(customer.id);

    let disconnected = app
        .clone()
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(disconnected.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        flaky_usage_repo.call_count(),
        1,
        "each request should have bounded usage-repo attempts under disconnect"
    );

    flaky_usage_repo.set_disconnected(false);
    flaky_usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        123,
        45,
        1024,
        50,
    );

    let recovered = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(recovered.status(), StatusCode::OK);
    assert_eq!(flaky_usage_repo.call_count(), 2);

    let body = recovered.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["total_search_requests"], 123);
}

#[tokio::test]
async fn usage_summary_repo_call_fails_once_on_disconnect_then_recovers() {
    let flaky_usage_repo = FlakyUsageRepo::new();
    let customer_id = Uuid::new_v4();

    let disconnected = flaky_usage_repo.summary_for(customer_id, 7).await;
    assert!(
        matches!(disconnected, Err(RepoError::Other(msg)) if msg.contains("metering db disconnected"))
    );
    assert_eq!(
        flaky_usage_repo.call_count(),
        1,
        "summary_for should attempt exactly once while disconnected"
    );

    flaky_usage_repo.set_disconnected(false);
    let today = Utc::now().date_naive();
    let bytes_per_gb = billing::types::BYTES_PER_GIB;

    flaky_usage_repo.seed(
        customer_id,
        today,
        "us-east-1",
        50,
        5,
        bytes_per_gb * 3,
        300,
    );
    flaky_usage_repo.seed(
        customer_id,
        today - Duration::days(2),
        "us-east-1",
        70,
        7,
        bytes_per_gb * 5,
        500,
    );
    flaky_usage_repo.seed(
        customer_id,
        today - Duration::days(9),
        "us-east-1",
        999,
        999,
        bytes_per_gb * 99,
        9999,
    );

    let recovered = flaky_usage_repo.summary_for(customer_id, 7).await.unwrap();
    assert_eq!(flaky_usage_repo.call_count(), 2);
    assert_eq!(recovered.total_search_requests, 120);
    assert_eq!(recovered.total_write_operations, 12);
    assert!((recovered.avg_storage_gb - 4.0).abs() < 0.0001);
    assert_eq!(recovered.avg_document_count, 400);
}

#[tokio::test]
async fn dependency_auth_revocation_trips_circuit_breaker_after_threshold() {
    let h = setup_replication_failure_harness().await;

    for cycle in 1..=5_u32 {
        h.http_client.enqueue(Ok(MigrationHttpResponse {
            status: 401,
            body: "unauthorized".to_string(),
        }));

        h.orchestrator.run_cycle().await;

        let replica = h.replica_repo.get(h.replica_id).await.unwrap().unwrap();
        if cycle < 5 {
            assert_eq!(replica.status, "provisioning");
        } else {
            assert_eq!(replica.status, "failed");
        }
    }
}

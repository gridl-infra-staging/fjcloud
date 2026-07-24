use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration as StdDuration;

use api::config::{Config, ConfigError};
use api::models::{NewVmInventory, NewVmLifecycleEvent, VmLifecycleEventType};
use api::provisioner::mock::MockVmProvisioner;
use api::provisioner::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};
use api::repos::vm_lifecycle_event_repo::{
    AutorepairGuardrailQuery, ReplacementAdmission, ReplacementAdmissionDraft,
};
use api::repos::{TenantRepo, VmInventoryRepo, VmLifecycleEventRepo};
use api::services::health_monitor::EngineHealthWaitPolicy;
use api::services::provisioning::{ProvisioningService, DEFAULT_DNS_DOMAIN};
use api::services::vm_autorepair::{
    classify_vm_liveness, decide_autorepair, AutorepairDecision, AutorepairPolicy,
    AutorepairRefusal, LivenessCheck, VmAutorepairDeps, VmAutorepairReconciler,
    VmAutorepairSettings, VmLiveness,
};
use async_trait::async_trait;
use chrono::{Duration, TimeZone, Utc};
use serde_json::json;
use std::io;
use std::sync::{Mutex, OnceLock};
use tracing_subscriber::prelude::*;
use uuid::Uuid;

use crate::common::integration_helpers::tracing_test_lock;

const VM_ID: &str = "i-autorepair-target";
const REGION: &str = "us-east-1";
const FLAPJACK_URL: &str = "https://vm-autorepair.example.test";
const DEAD_HOSTNAME: &str = "vm-dead.flapjack.foo";
const REPLACEMENT_HOSTNAME: &str = "vm-shared-recovery.flapjack.foo";

#[derive(Clone)]
struct VmAutorepairLogWriter(Arc<Mutex<Vec<u8>>>);

impl io::Write for VmAutorepairLogWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for VmAutorepairLogWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

static VM_AUTOREPAIR_LOG_CAPTURE: OnceLock<Arc<Mutex<Vec<u8>>>> = OnceLock::new();

fn install_vm_autorepair_log_capture() -> Arc<Mutex<Vec<u8>>> {
    let captured = VM_AUTOREPAIR_LOG_CAPTURE
        .get_or_init(|| {
            let captured = Arc::new(Mutex::new(Vec::new()));
            let subscriber = tracing_subscriber::registry().with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_writer(VmAutorepairLogWriter(Arc::clone(&captured))),
            );
            let _ = tracing::subscriber::set_global_default(subscriber);
            captured
        })
        .clone();
    captured.lock().unwrap().clear();
    captured
}

fn observed_at() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 7, 23, 15, 0, 0).unwrap()
}

fn liveness_check(dead_since: Option<chrono::DateTime<Utc>>) -> LivenessCheck {
    LivenessCheck {
        provider_vm_id: Some(VM_ID.to_string()),
        flapjack_url: Some(FLAPJACK_URL.to_string()),
        observed_at: observed_at(),
        dead_since,
        host_dead_after: Duration::minutes(15),
    }
}

fn check_without_vm_id() -> LivenessCheck {
    LivenessCheck {
        provider_vm_id: None,
        ..liveness_check(None)
    }
}

fn seed(status: VmStatus) -> MockVmProvisioner {
    let provisioner = MockVmProvisioner::new();
    provisioner.seed_vm(VM_ID, status, REGION);
    provisioner
}

fn assert_no_infra_mutation(provisioner: &MockVmProvisioner) {
    assert_eq!(
        provisioner.create_call_count(),
        0,
        "autorepair classification must not create VMs in Stage 1"
    );
    assert_eq!(
        provisioner.destroy_call_count(),
        0,
        "autorepair classification must not destroy VMs in Stage 1"
    );
}

fn base_policy() -> AutorepairPolicy {
    AutorepairPolicy {
        kill_switch_enabled: true,
        observed_at: observed_at(),
        replacement_cooldown_until: None,
        region_deaths_in_window: 0,
        region_death_limit: 2,
        concurrent_replacements: 0,
        concurrent_replacement_cap: 1,
        projected_spend_cents: 7_500,
        spend_ceiling_cents: 10_000,
    }
}

fn replacement_admission_draft(dead_vm_id: Uuid) -> ReplacementAdmissionDraft {
    ReplacementAdmissionDraft {
        attempt_id: Uuid::parse_str("018ff5d2-32c7-7334-8cc8-b7ef9e950001").unwrap(),
        dead_vm_id,
        dead_hostname: DEAD_HOSTNAME.to_string(),
        planned_replacement_hostname: REPLACEMENT_HOSTNAME.to_string(),
        planned_replacement_node_id: REPLACEMENT_HOSTNAME.to_string(),
        provider: "aws".to_string(),
        region: REGION.to_string(),
        planned_spend_cents: 1_000,
    }
}

struct ReconcilerHarness {
    reconciler: Arc<VmAutorepairReconciler>,
    source_vm_id: Uuid,
    provisioner: Arc<MockVmProvisioner>,
    inventory_repo: Arc<crate::common::mocks::MockVmInventoryRepo>,
    tenant_repo: Arc<crate::common::mocks::MockTenantRepo>,
    lifecycle_repo: Arc<crate::common::mocks::MockVmLifecycleEventRepo>,
}

async fn reconciler_harness(
    status: VmStatus,
    health_client: Arc<dyn api::services::health_monitor::HealthCheckClient>,
    enabled: bool,
) -> ReconcilerHarness {
    reconciler_harness_with_settings(
        status,
        health_client,
        enabled,
        VmAutorepairSettings {
            check_interval: StdDuration::from_secs(60),
            host_dead_after: Duration::minutes(15),
            spend_ceiling_cents: 10_000,
            ..VmAutorepairSettings::default()
        },
    )
    .await
}

async fn reconciler_harness_with_settings(
    status: VmStatus,
    health_client: Arc<dyn api::services::health_monitor::HealthCheckClient>,
    enabled: bool,
    settings: VmAutorepairSettings,
) -> ReconcilerHarness {
    reconciler_harness_with_identity(
        status,
        health_client,
        enabled,
        settings,
        DEAD_HOSTNAME,
        VM_ID,
    )
    .await
}

async fn reconciler_harness_with_identity(
    status: VmStatus,
    health_client: Arc<dyn api::services::health_monitor::HealthCheckClient>,
    enabled: bool,
    settings: VmAutorepairSettings,
    source_hostname: &str,
    provider_vm_id: &str,
) -> ReconcilerHarness {
    let provisioner = Arc::new(MockVmProvisioner::new());
    let inventory_repo = Arc::new(crate::common::mocks::MockVmInventoryRepo::new());
    let tenant_repo = Arc::new(crate::common::mocks::MockTenantRepo::new());
    let lifecycle_repo = Arc::new(crate::common::mocks::MockVmLifecycleEventRepo::new());
    let source_vm = inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: source_hostname.to_string(),
            flapjack_url: FLAPJACK_URL.to_string(),
            capacity: json!({}),
        })
        .await
        .expect("source VM should seed");
    provisioner.seed_vm_for_hostname(source_hostname, provider_vm_id, status, REGION);

    let provisioning_service = Arc::new(ProvisioningService::new(
        provisioner.clone(),
        Arc::new(api::dns::mock::MockDnsManager::new()),
        Arc::new(api::secrets::mock::MockNodeSecretManager::new()),
        crate::common::mock_deployment_repo(),
        crate::common::mock_repo(),
        DEFAULT_DNS_DOMAIN.to_string(),
    ))
    .with_engine_health_client_for_test(
        crate::common::engine_health::EngineHealthClient::healthy(),
        EngineHealthWaitPolicy::new(
            StdDuration::from_millis(50),
            StdDuration::from_millis(10),
            StdDuration::from_millis(1),
        ),
    );
    let deps = VmAutorepairDeps {
        vm_inventory_repo: inventory_repo.clone(),
        tenant_repo: tenant_repo.clone(),
        lifecycle_event_repo: lifecycle_repo.clone(),
        provisioning_service,
        health_client,
    };
    let enabled_reader = Arc::new(move || Ok(enabled));
    let reconciler = Arc::new(VmAutorepairReconciler::new_with_enabled_reader(
        deps,
        settings,
        enabled_reader,
    ));

    ReconcilerHarness {
        reconciler,
        source_vm_id: source_vm.id,
        provisioner,
        inventory_repo,
        tenant_repo,
        lifecycle_repo,
    }
}

async fn fleet_guardrail_reconciler(
    source_hostname: &str,
    provider_vm_id: &str,
    provisioner: Arc<MockVmProvisioner>,
    lifecycle_repo: Arc<crate::common::mocks::MockVmLifecycleEventRepo>,
) -> Arc<VmAutorepairReconciler> {
    let inventory_repo = Arc::new(crate::common::mocks::MockVmInventoryRepo::new());
    let _source_vm = inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: source_hostname.to_string(),
            flapjack_url: FLAPJACK_URL.to_string(),
            capacity: json!({}),
        })
        .await
        .expect("source VM should seed");
    provisioner.seed_vm_for_hostname(source_hostname, provider_vm_id, VmStatus::Stopped, REGION);
    let provisioning_service = Arc::new(ProvisioningService::new(
        provisioner,
        Arc::new(api::dns::mock::MockDnsManager::new()),
        Arc::new(api::secrets::mock::MockNodeSecretManager::new()),
        crate::common::mock_deployment_repo(),
        crate::common::mock_repo(),
        DEFAULT_DNS_DOMAIN.to_string(),
    ))
    .with_engine_health_client_for_test(
        crate::common::engine_health::EngineHealthClient::healthy(),
        EngineHealthWaitPolicy::new(
            StdDuration::from_millis(50),
            StdDuration::from_millis(10),
            StdDuration::from_millis(1),
        ),
    );
    Arc::new(VmAutorepairReconciler::new_with_enabled_reader(
        VmAutorepairDeps {
            vm_inventory_repo: inventory_repo,
            tenant_repo: Arc::new(crate::common::mocks::MockTenantRepo::new()),
            lifecycle_event_repo: lifecycle_repo,
            provisioning_service,
            health_client: crate::common::engine_health::EngineHealthClient::new(vec![
                crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                    "connection refused",
                );
                2
            ]),
        },
        VmAutorepairSettings {
            host_dead_after: Duration::minutes(15),
            spend_ceiling_cents: 10_000,
            ..VmAutorepairSettings::default()
        },
        Arc::new(|| Ok(true)),
    ))
}

async fn seed_admitted_replacement(
    harness: &ReconcilerHarness,
) -> (ReplacementAdmission, api::models::VmInventory) {
    let admission = harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should be admitted before the simulated restart");
    let replacement = harness
        .inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: REPLACEMENT_HOSTNAME.to_string(),
            flapjack_url: format!("http://{REPLACEMENT_HOSTNAME}:7700"),
            capacity: json!({}),
        })
        .await
        .expect("replacement inventory should persist before the simulated restart");
    (admission, replacement)
}

async fn append_replacement_phase(
    harness: &ReconcilerHarness,
    admission: &ReplacementAdmission,
    replacement_vm_id: Uuid,
    event_type: VmLifecycleEventType,
) {
    let mut detail = admission.event.detail.clone();
    detail
        .as_object_mut()
        .expect("admission detail should be an object")
        .insert(
            "replacement_vm_id".to_string(),
            json!(replacement_vm_id.to_string()),
        );
    harness
        .lifecycle_repo
        .append(NewVmLifecycleEvent {
            vm_id: harness.source_vm_id,
            event_type,
            detail,
        })
        .await
        .expect("durable replacement phase should append");
}

async fn replacement_event_types(harness: &ReconcilerHarness) -> Vec<VmLifecycleEventType> {
    harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("replacement lifecycle should remain readable")
        .into_iter()
        .map(|event| event.event_type)
        .collect()
}

enum SpyStatusReply {
    NotConfigured,
    InvalidState(&'static str),
}

struct SpyProvisioner {
    status_reply: SpyStatusReply,
    status_calls: AtomicUsize,
}

impl SpyProvisioner {
    fn with_status(status_reply: SpyStatusReply) -> Self {
        Self {
            status_reply,
            status_calls: AtomicUsize::new(0),
        }
    }

    fn status_call_count(&self) -> usize {
        self.status_calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl VmProvisioner for SpyProvisioner {
    async fn create_vm(&self, _config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        panic!("Stage 1 liveness classification must not create VMs");
    }

    async fn destroy_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        panic!("Stage 1 liveness classification must not destroy VMs");
    }

    async fn stop_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        panic!("Stage 1 liveness classification must not stop VMs");
    }

    async fn start_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        panic!("Stage 1 liveness classification must not start VMs");
    }

    async fn get_vm_status(&self, _provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        self.status_calls.fetch_add(1, Ordering::SeqCst);
        match &self.status_reply {
            SpyStatusReply::NotConfigured => Err(VmProvisionerError::NotConfigured),
            SpyStatusReply::InvalidState(reason) => {
                Err(VmProvisionerError::InvalidState((*reason).to_string()))
            }
        }
    }
}

fn config_reader(
    env_name: &'static str,
    flag: Option<&'static str>,
) -> impl Fn(&str) -> Option<String> {
    move |key| {
        HashMap::from([
            ("DATABASE_URL", "postgres://localhost/fjcloud"),
            ("JWT_SECRET", "super-secret-key-for-testing-1234"),
            ("ADMIN_KEY", "admin-bootstrap-key-for-testing"),
            ("ENVIRONMENT", env_name),
        ])
        .get(key)
        .map(|value| value.to_string())
        .or_else(|| match (key, flag) {
            ("FJCLOUD_VM_AUTOREPAIR_ENABLED", Some(value)) => Some(value.to_string()),
            _ => None,
        })
    }
}

#[tokio::test]
async fn vm_autorepair_lifecycle_admission_is_stable_until_attempt_terminal() {
    let repo = crate::common::mocks::MockVmLifecycleEventRepo::new();
    let dead_vm_id = Uuid::new_v4();
    let draft = replacement_admission_draft(dead_vm_id);

    let first = repo
        .admit_replacement(draft.clone())
        .await
        .expect("first pass must append replacement_provisioning");
    let resumed = repo
        .admit_replacement(draft.clone())
        .await
        .expect("restart must recover the active attempt");

    assert!(first.appended, "first admission should append the attempt");
    assert!(
        !resumed.appended,
        "resumed admission must not append a duplicate non-terminal attempt"
    );
    assert_eq!(resumed.attempt_id, draft.attempt_id);
    assert_eq!(
        resumed.planned_replacement_hostname,
        draft.planned_replacement_hostname
    );
    assert_eq!(
        resumed.planned_replacement_node_id,
        draft.planned_replacement_node_id
    );

    let events = repo
        .list_for_vm(dead_vm_id)
        .await
        .expect("events must remain readable after admission");
    assert_eq!(
        events.len(),
        1,
        "active admission must be append-at-most-once"
    );
    assert_eq!(
        events[0].detail,
        json!({
            "attempt_id": draft.attempt_id,
            "dead_vm_id": dead_vm_id,
            "dead_hostname": DEAD_HOSTNAME,
            "planned_replacement_hostname": REPLACEMENT_HOSTNAME,
            "planned_replacement_node_id": REPLACEMENT_HOSTNAME,
            "provider": "aws",
            "region": REGION,
            "planned_spend_cents": 1_000,
        })
    );
}

#[tokio::test]
async fn vm_autorepair_guardrail_history_summarizes_canonical_event_order() {
    let repo = crate::common::mocks::MockVmLifecycleEventRepo::new();
    let first_vm_id = Uuid::new_v4();
    let second_vm_id = Uuid::new_v4();
    let other_region_vm_id = Uuid::new_v4();
    let first_attempt = Uuid::new_v4();
    let second_attempt = Uuid::new_v4();

    repo.append(NewVmLifecycleEvent {
        vm_id: first_vm_id,
        event_type: VmLifecycleEventType::DetectedDead,
        detail: json!({"region": REGION}),
    })
    .await
    .unwrap();
    repo.append(NewVmLifecycleEvent {
        vm_id: other_region_vm_id,
        event_type: VmLifecycleEventType::DetectedDead,
        detail: json!({"region": "eu-west-1"}),
    })
    .await
    .unwrap();
    repo.append(NewVmLifecycleEvent {
        vm_id: first_vm_id,
        event_type: VmLifecycleEventType::ReplacementProvisioning,
        detail: json!({
            "attempt_id": first_attempt,
            "planned_replacement_hostname": "replacement-a.test",
            "planned_replacement_node_id": "replacement-a",
            "planned_spend_cents": 1_200,
            "region": REGION,
        }),
    })
    .await
    .unwrap();
    let first_booted = repo
        .append(NewVmLifecycleEvent {
            vm_id: first_vm_id,
            event_type: VmLifecycleEventType::ReplacementBooted,
            detail: json!({
                "attempt_id": first_attempt,
                "planned_replacement_hostname": "replacement-a.test",
                "planned_replacement_node_id": "replacement-a",
                "planned_spend_cents": 1_200,
                "replacement_vm_id": Uuid::new_v4(),
                "region": REGION,
            }),
        })
        .await
        .unwrap();
    repo.append(NewVmLifecycleEvent {
        vm_id: second_vm_id,
        event_type: VmLifecycleEventType::ReplacementProvisioning,
        detail: json!({
            "attempt_id": second_attempt,
            "planned_replacement_hostname": "replacement-b.test",
            "planned_replacement_node_id": "replacement-b",
            "planned_spend_cents": 800,
            "region": REGION,
        }),
    })
    .await
    .unwrap();

    let query = AutorepairGuardrailQuery {
        region: REGION.to_string(),
        observed_at: Utc::now() + Duration::seconds(1),
        replacement_cooldown: Duration::minutes(30),
        region_death_window: Duration::minutes(15),
        spend_window: Duration::hours(24),
    };
    let active = repo
        .guardrail_history(query.clone())
        .await
        .expect("guardrail history should summarize lifecycle events");
    assert_eq!(
        active.replacement_cooldown_until,
        Some(first_booted.created_at + Duration::minutes(30))
    );
    assert_eq!(active.region_deaths_in_window, 1);
    assert_eq!(active.concurrent_replacements, 2);
    assert_eq!(active.committed_spend_cents, 2_000);

    repo.append(NewVmLifecycleEvent {
        vm_id: first_vm_id,
        event_type: VmLifecycleEventType::TenantsReplaced,
        detail: json!({
            "attempt_id": first_attempt,
            "planned_replacement_hostname": "replacement-a.test",
            "planned_replacement_node_id": "replacement-a",
            "replacement_vm_id": Uuid::new_v4(),
            "region": REGION,
        }),
    })
    .await
    .unwrap();
    let resumed = repo
        .guardrail_history(query)
        .await
        .expect("tenant completion should update concurrent summary");
    assert_eq!(
        resumed.concurrent_replacements, 2,
        "tenants_replaced still owns unfinished retirement and teardown work"
    );
}

#[tokio::test]
async fn vm_autorepair_failed_retryable_phase_keeps_same_attempt_active() {
    let repo = crate::common::mocks::MockVmLifecycleEventRepo::new();
    let dead_vm_id = Uuid::new_v4();
    let draft = replacement_admission_draft(dead_vm_id);
    let admission = repo
        .admit_replacement(draft.clone())
        .await
        .expect("replacement should be admitted");
    let replacement_vm_id = Uuid::new_v4();
    let mut booted_detail = admission.event.detail.clone();
    booted_detail
        .as_object_mut()
        .expect("admission detail should be an object")
        .insert(
            "replacement_vm_id".to_string(),
            json!(replacement_vm_id.to_string()),
        );
    repo.append(NewVmLifecycleEvent {
        vm_id: dead_vm_id,
        event_type: VmLifecycleEventType::ReplacementBooted,
        detail: booted_detail.clone(),
    })
    .await
    .expect("replacement boot should append");
    let mut failure_detail = booted_detail;
    failure_detail
        .as_object_mut()
        .expect("boot detail should be an object")
        .insert("failure_phase".to_string(), json!("placement"));
    repo.append(NewVmLifecycleEvent {
        vm_id: dead_vm_id,
        event_type: VmLifecycleEventType::ReplacementFailed,
        detail: failure_detail,
    })
    .await
    .expect("retryable failure should append");

    let resumed = repo
        .admit_replacement(draft.clone())
        .await
        .expect("retryable failure must not admit a new attempt");
    assert!(!resumed.appended);
    assert_eq!(resumed.attempt_id, draft.attempt_id);
    assert_eq!(
        resumed.event.event_type,
        VmLifecycleEventType::ReplacementBooted
    );

    let unfinished = repo
        .unfinished_replacements()
        .await
        .expect("retryable failure should remain resumable");
    assert_eq!(unfinished.len(), 1);
    assert_eq!(
        unfinished[0].event_type,
        VmLifecycleEventType::ReplacementBooted
    );
}

#[tokio::test]
async fn vm_autorepair_tenant_replacement_placement_is_source_checked_and_idempotent() {
    let tenant_repo = crate::common::mocks::MockTenantRepo::new();
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    let source_vm_id = Uuid::new_v4();
    let replacement_vm_id = Uuid::new_v4();

    tenant_repo
        .create(customer_id, "search", deployment_id)
        .await
        .expect("tenant seed should create");
    tenant_repo
        .set_vm_id(customer_id, "search", source_vm_id)
        .await
        .expect("tenant should start on the dead source VM");

    let moved = tenant_repo
        .replace_vm_if_current(customer_id, "search", source_vm_id, replacement_vm_id)
        .await
        .expect("source-matching tenant should move");
    let retried = tenant_repo
        .replace_vm_if_current(customer_id, "search", source_vm_id, replacement_vm_id)
        .await
        .expect("already-on-replacement tenant should be idempotent");

    assert_eq!(moved.vm_id, Some(replacement_vm_id));
    assert_eq!(retried.vm_id, Some(replacement_vm_id));

    let concurrent_destination = Uuid::new_v4();
    tenant_repo
        .set_vm_id(customer_id, "search", concurrent_destination)
        .await
        .expect("simulate concurrent placement");
    let conflict = tenant_repo
        .replace_vm_if_current(customer_id, "search", source_vm_id, replacement_vm_id)
        .await
        .expect_err("source mismatch must not overwrite concurrent movement");
    assert!(matches!(conflict, api::repos::RepoError::Conflict(_)));

    let missing = tenant_repo
        .replace_vm_if_current(customer_id, "missing", source_vm_id, replacement_vm_id)
        .await
        .expect_err("missing tenant must stay explicit");
    assert!(matches!(missing, api::repos::RepoError::NotFound));
}

#[tokio::test]
async fn vm_autorepair_reconciler_non_dead_outcomes_are_observed_without_mutation() {
    for (status, health_client) in [
        (
            VmStatus::Running,
            crate::common::engine_health::EngineHealthClient::healthy(),
        ),
        (
            VmStatus::Running,
            crate::common::engine_health::EngineHealthClient::unhealthy(503),
        ),
        (
            VmStatus::Pending,
            crate::common::engine_health::EngineHealthClient::unreachable("pending"),
        ),
    ] {
        let harness = reconciler_harness(status, health_client, true).await;

        harness
            .reconciler
            .observe_once_at(observed_at())
            .await
            .expect("non-dead observation should complete");

        assert_eq!(harness.provisioner.create_call_count(), 0);
        assert_eq!(harness.provisioner.destroy_call_count(), 0);
        assert_eq!(harness.inventory_repo.status_mutation_call_count(), 0);
        assert_eq!(
            harness
                .lifecycle_repo
                .list_for_vm(harness.source_vm_id)
                .await
                .expect("lifecycle history should remain readable"),
            Vec::new(),
            "Live, EngineDown, and Indeterminate must not start replacement"
        );
    }
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn vm_autorepair_engine_down_emits_structured_observation() {
    let _tracing_guard = tracing_test_lock();
    let captured = install_vm_autorepair_log_capture();
    let provider_vm_id = "i-autorepair-engine-down-log";
    let harness = reconciler_harness_with_identity(
        VmStatus::Running,
        crate::common::engine_health::EngineHealthClient::unhealthy(503),
        false,
        VmAutorepairSettings {
            check_interval: StdDuration::from_secs(60),
            host_dead_after: Duration::minutes(15),
            spend_ceiling_cents: 10_000,
            ..VmAutorepairSettings::default()
        },
        "vm-engine-down-log.flapjack.foo",
        provider_vm_id,
    )
    .await;

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("EngineDown observation should complete");

    let output =
        String::from_utf8(captured.lock().unwrap().clone()).expect("captured logs should be UTF-8");
    let observation = output
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|event| {
            event
                .pointer("/fields/message")
                .and_then(serde_json::Value::as_str)
                == Some("VM autorepair liveness observed")
                && event
                    .pointer("/fields/provider_vm_id")
                    .and_then(serde_json::Value::as_str)
                    == Some(provider_vm_id)
        })
        .expect("EngineDown should emit a structured liveness observation");
    assert_eq!(
        observation
            .pointer("/fields/liveness")
            .and_then(serde_json::Value::as_str),
        Some("EngineDown")
    );
    assert_eq!(
        observation
            .pointer("/fields/provider_vm_id")
            .and_then(serde_json::Value::as_str),
        Some(provider_vm_id)
    );
}

#[tokio::test]
async fn vm_autorepair_terminated_host_remains_resolvable_for_dead_detection() {
    let harness = reconciler_harness(
        VmStatus::Terminated,
        crate::common::engine_health::EngineHealthClient::new([
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
        ]),
        false,
    )
    .await;

    harness
        .reconciler
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("first terminated observation should start the dead window");
    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("elapsed terminated observation should be detected");

    let events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("terminated-host lifecycle history should be readable");
    assert_eq!(
        events
            .iter()
            .map(|event| event.event_type)
            .collect::<Vec<_>>(),
        vec![
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementRefused,
        ]
    );
    assert_eq!(
        events[0]
            .detail
            .get("provider_vm_id")
            .and_then(serde_json::Value::as_str),
        Some(VM_ID)
    );
}

#[tokio::test]
async fn vm_autorepair_reconciler_disabled_host_dead_records_once_without_mutation() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::new(vec![
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            );
            3
        ]),
        false,
    )
    .await;
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    harness
        .tenant_repo
        .create(customer_id, "search", deployment_id)
        .await
        .expect("tenant should seed");
    harness
        .tenant_repo
        .set_vm_id(customer_id, "search", harness.source_vm_id)
        .await
        .expect("tenant should start on source VM");

    harness
        .reconciler
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("first dead observation should start the conservative window");
    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("elapsed dead observation should be refused");
    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(1))
        .await
        .expect("unchanged disabled observation should not flood events");

    let events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("disabled incident history should be readable");
    assert_eq!(
        events
            .iter()
            .map(|event| event.event_type)
            .collect::<Vec<_>>(),
        vec![
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementRefused,
        ]
    );
    assert_eq!(
        events[0].detail,
        json!({
            "dead_vm_id": harness.source_vm_id,
            "dead_hostname": DEAD_HOSTNAME,
            "provider": "aws",
            "provider_vm_id": VM_ID,
            "region": REGION,
        })
    );
    assert_eq!(
        events[1].detail,
        json!({
            "dead_vm_id": harness.source_vm_id,
            "dead_hostname": DEAD_HOSTNAME,
            "guardrail": "kill_switch_disabled",
            "provider": "aws",
            "provider_vm_id": VM_ID,
            "region": REGION,
        })
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 0);
    assert_eq!(harness.inventory_repo.status_mutation_call_count(), 0);
    assert_eq!(
        harness
            .tenant_repo
            .find_raw(customer_id, "search")
            .await
            .expect("tenant should remain readable")
            .expect("tenant should still exist")
            .vm_id,
        Some(harness.source_vm_id),
        "disabled autorepair must not place tenants"
    );
}

#[tokio::test]
async fn vm_autorepair_disabled_loop_preserves_unfinished_replacement_without_mutation() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        false,
    )
    .await;
    harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should be durable before the kill switch is disabled");

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("disabled reconciliation should leave recovery work paused");

    assert_eq!(
        replacement_event_types(&harness).await,
        vec![VmLifecycleEventType::ReplacementProvisioning],
        "the kill switch must preserve, not terminalize, unfinished recovery"
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 0);
    assert_eq!(harness.inventory_repo.status_mutation_call_count(), 0);
}

#[tokio::test]
async fn vm_autorepair_reconciler_records_new_disabled_incident_after_recovery() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::new([
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::Healthy2xx,
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
        ]),
        false,
    )
    .await;

    harness
        .reconciler
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("first dead observation should start the window");
    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("first elapsed incident should be refused");

    harness
        .provisioner
        .seed_vm_for_hostname(DEAD_HOSTNAME, VM_ID, VmStatus::Running, REGION);
    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(1))
        .await
        .expect("live observation should close the first dead episode");

    harness
        .provisioner
        .seed_vm_for_hostname(DEAD_HOSTNAME, VM_ID, VmStatus::Stopped, REGION);
    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(2))
        .await
        .expect("second dead observation should start a fresh window");
    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(17))
        .await
        .expect("second elapsed incident should be refused separately");

    let event_types = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("incident history should be readable")
        .into_iter()
        .map(|event| event.event_type)
        .collect::<Vec<_>>();
    assert_eq!(
        event_types,
        vec![
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementRefused,
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementRefused,
        ],
        "a recovered VM must emit a fresh incident trail when it later dies again"
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 0);
}

#[tokio::test]
async fn vm_autorepair_reconciler_dead_window_ignores_generic_indeterminate_observations() {
    let harness = reconciler_harness(
        VmStatus::Pending,
        crate::common::engine_health::EngineHealthClient::new([
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable("pending"),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            ),
        ]),
        false,
    )
    .await;

    harness
        .reconciler
        .observe_once_at(observed_at() - Duration::minutes(20))
        .await
        .expect("pending observation should remain non-mutating");

    harness
        .provisioner
        .seed_vm_for_hostname(DEAD_HOSTNAME, VM_ID, VmStatus::Stopped, REGION);
    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("first concrete dead evidence should start the window");
    assert!(
        harness
            .lifecycle_repo
            .list_for_vm(harness.source_vm_id)
            .await
            .expect("history should be readable")
            .is_empty(),
        "generic indeterminate time must not count toward the dead-host window"
    );

    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(14) + Duration::seconds(59))
        .await
        .expect("dead evidence before the full window should remain non-mutating");
    assert!(
        harness
            .lifecycle_repo
            .list_for_vm(harness.source_vm_id)
            .await
            .expect("history should be readable")
            .is_empty(),
        "replacement refusal must wait for a full window of concrete dead evidence"
    );

    harness
        .reconciler
        .observe_once_at(observed_at() + Duration::minutes(15))
        .await
        .expect("elapsed concrete dead evidence should be refused");
    let event_types = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("history should be readable")
        .into_iter()
        .map(|event| event.event_type)
        .collect::<Vec<_>>();
    assert_eq!(
        event_types,
        vec![
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementRefused,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 0);
}

#[tokio::test]
async fn vm_autorepair_reconciler_completes_admitted_replacement_in_order() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::new(vec![
            crate::common::engine_health::EngineHealthBehavior::RetryableUnreachable(
                "connection refused",
            );
            2
        ]),
        true,
    )
    .await;
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    harness
        .tenant_repo
        .create(customer_id, "search", deployment_id)
        .await
        .expect("tenant should seed");
    harness
        .tenant_repo
        .set_vm_id(customer_id, "search", harness.source_vm_id)
        .await
        .expect("tenant should start on the dead source");

    harness
        .reconciler
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("first dead observation should start the conservative window");
    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("elapsed dead observation should complete replacement");

    let events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("completed lifecycle history should be readable");
    assert_eq!(
        events
            .iter()
            .map(|event| event.event_type)
            .collect::<Vec<_>>(),
        vec![
            VmLifecycleEventType::DetectedDead,
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    let replacement_vm_id = events[2]
        .detail
        .get("replacement_vm_id")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .expect("replacement_booted should record the replacement VM");
    assert_eq!(
        harness
            .tenant_repo
            .find_raw(customer_id, "search")
            .await
            .expect("tenant should remain readable")
            .expect("tenant should still exist")
            .vm_id,
        Some(replacement_vm_id)
    );
    assert_eq!(harness.provisioner.create_call_count(), 1);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
    assert_eq!(
        harness
            .inventory_repo
            .get(harness.source_vm_id)
            .await
            .expect("source VM should remain readable")
            .expect("source VM should still exist")
            .status,
        "decommissioned"
    );
}

#[tokio::test]
async fn vm_autorepair_concurrent_passes_complete_one_exact_lifecycle() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should be admitted before concurrent passes");
    let create_gate = harness.provisioner.pause_next_create();

    let first_reconciler = Arc::clone(&harness.reconciler);
    let first = tokio::spawn(async move { first_reconciler.observe_once_at(observed_at()).await });
    tokio::time::timeout(StdDuration::from_secs(5), create_gate.wait_until_started())
        .await
        .expect("first reconciliation should reach the provider create gate");

    let second_reconciler = Arc::clone(&harness.reconciler);
    let second =
        tokio::spawn(async move { second_reconciler.observe_once_at(observed_at()).await });
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(
        harness.provisioner.create_call_count(),
        1,
        "concurrent reconciliation must not enter provider create twice"
    );
    create_gate.release();
    first
        .await
        .expect("first concurrent pass should join")
        .expect("first concurrent pass should complete");
    second
        .await
        .expect("second concurrent pass should join")
        .expect("second concurrent pass should converge idempotently");

    let event_types = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("concurrent lifecycle history should remain readable")
        .into_iter()
        .map(|event| event.event_type)
        .collect::<Vec<_>>();
    assert_eq!(
        event_types,
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 1);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_fleet_guardrails_serialize_cross_vm_admission() {
    let provisioner = Arc::new(MockVmProvisioner::new());
    let lifecycle_repo = Arc::new(crate::common::mocks::MockVmLifecycleEventRepo::new());
    let first = fleet_guardrail_reconciler(
        "vm-dead-one.flapjack.foo",
        "i-autorepair-one",
        Arc::clone(&provisioner),
        Arc::clone(&lifecycle_repo),
    )
    .await;
    let second = fleet_guardrail_reconciler(
        "vm-dead-two.flapjack.foo",
        "i-autorepair-two",
        Arc::clone(&provisioner),
        Arc::clone(&lifecycle_repo),
    )
    .await;
    first
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("first source should start its dead window");
    second
        .observe_once_at(observed_at() - Duration::minutes(15))
        .await
        .expect("second source should start its dead window");

    let admission_gate = lifecycle_repo.pause_next_admission();
    let first_pass = tokio::spawn(async move { first.observe_once_at(observed_at()).await });
    tokio::time::timeout(
        StdDuration::from_secs(5),
        admission_gate.wait_until_started(),
    )
    .await
    .expect("first replacement should pause at durable admission");
    let second_pass = tokio::spawn(async move { second.observe_once_at(observed_at()).await });
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert!(
        lifecycle_repo
            .unfinished_replacements()
            .await
            .expect("history should remain readable")
            .is_empty(),
        "the second VM must wait for the first guardrail decision and admission"
    );

    admission_gate.release();
    first_pass
        .await
        .expect("first pass should join")
        .expect("first pass should complete");
    second_pass
        .await
        .expect("second pass should join")
        .expect("second pass should be refused by updated fleet history");

    let replacement_provisioning_count = lifecycle_repo
        .guardrail_history(AutorepairGuardrailQuery {
            region: REGION.to_string(),
            observed_at: Utc::now() + Duration::minutes(1),
            replacement_cooldown: Duration::minutes(30),
            region_death_window: Duration::minutes(30),
            spend_window: Duration::hours(24),
        })
        .await
        .expect("guardrail history should remain readable")
        .committed_spend_cents;
    assert_eq!(
        replacement_provisioning_count, 1_000,
        "only one replacement may consume spend under the fleet admission lock"
    );
    assert_eq!(provisioner.create_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_restart_from_replacement_provisioning_completes_once() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement provisioning should persist before the restart");

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("restart should resume from replacement provisioning");

    assert_eq!(
        replacement_event_types(&harness).await,
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 1);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_restart_after_provider_create_recovers_durable_hostname() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement provisioning should persist before provider create");
    harness.provisioner.seed_vm_for_hostname(
        REPLACEMENT_HOSTNAME,
        "provider-created-before-restart",
        VmStatus::Running,
        REGION,
    );

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("restart should recover the provider-created replacement");

    assert_eq!(
        replacement_event_types(&harness).await,
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_restart_after_partial_placement_moves_only_source_tenants() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    let first_customer = Uuid::new_v4();
    let second_customer = Uuid::new_v4();
    for (customer_id, tenant_id) in [(first_customer, "first"), (second_customer, "second")] {
        harness
            .tenant_repo
            .create(customer_id, tenant_id, Uuid::new_v4())
            .await
            .expect("tenant should seed");
        harness
            .tenant_repo
            .set_vm_id(customer_id, tenant_id, harness.source_vm_id)
            .await
            .expect("tenant should start on the source VM");
    }
    let (admission, replacement) = seed_admitted_replacement(&harness).await;
    append_replacement_phase(
        &harness,
        &admission,
        replacement.id,
        VmLifecycleEventType::ReplacementBooted,
    )
    .await;
    harness
        .tenant_repo
        .replace_vm_if_current(
            first_customer,
            "first",
            harness.source_vm_id,
            replacement.id,
        )
        .await
        .expect("first tenant move should persist before the restart");

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("restart should idempotently finish partial placement");

    for (customer_id, tenant_id) in [(first_customer, "first"), (second_customer, "second")] {
        assert_eq!(
            harness
                .tenant_repo
                .find_raw(customer_id, tenant_id)
                .await
                .unwrap()
                .unwrap()
                .vm_id,
            Some(replacement.id)
        );
    }
    assert_eq!(
        replacement_event_types(&harness).await,
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_restart_from_tenants_replaced_retires_then_tears_down() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    let (admission, replacement) = seed_admitted_replacement(&harness).await;
    for event_type in [
        VmLifecycleEventType::ReplacementBooted,
        VmLifecycleEventType::TenantsReplaced,
    ] {
        append_replacement_phase(&harness, &admission, replacement.id, event_type).await;
    }

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("restart should retire and tear down after tenant completion");

    assert_eq!(
        replacement_event_types(&harness).await,
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(
        harness
            .inventory_repo
            .get(harness.source_vm_id)
            .await
            .unwrap()
            .unwrap()
            .status,
        "decommissioned"
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_retirement_refusal_blocks_teardown() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    let (admission, replacement) = seed_admitted_replacement(&harness).await;
    for event_type in [
        VmLifecycleEventType::ReplacementBooted,
        VmLifecycleEventType::TenantsReplaced,
    ] {
        append_replacement_phase(&harness, &admission, replacement.id, event_type).await;
    }
    harness.inventory_repo.fail_next_decommission();

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect_err("retirement failure should fail this pass");

    let events = replacement_event_types(&harness).await;
    let failed = events.last().expect("replacement failure should append");
    assert_eq!(*failed, VmLifecycleEventType::ReplacementFailed);
    let all_events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("failed lifecycle should remain readable");
    let failed_event = all_events.last().unwrap();
    assert_eq!(
        failed_event
            .detail
            .get("failure_phase")
            .and_then(serde_json::Value::as_str),
        Some("retirement")
    );
    assert_eq!(
        harness
            .inventory_repo
            .get(harness.source_vm_id)
            .await
            .unwrap()
            .unwrap()
            .status,
        "active",
        "source VM must not be decommissioned when decommission fails"
    );
    assert_eq!(
        harness.provisioner.destroy_call_count(),
        0,
        "teardown must not run when retirement is refused"
    );
}

#[tokio::test]
async fn vm_autorepair_restart_resumes_teardown_after_source_decommission() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    let admission = harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should already be admitted before the crash");
    let replacement = harness
        .inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: REPLACEMENT_HOSTNAME.to_string(),
            flapjack_url: format!("http://{REPLACEMENT_HOSTNAME}:7700"),
            capacity: json!({}),
        })
        .await
        .expect("replacement inventory should already exist before the crash");
    let mut detail = admission.event.detail.clone();
    detail
        .as_object_mut()
        .expect("admission detail should be an object")
        .insert(
            "replacement_vm_id".to_string(),
            json!(replacement.id.to_string()),
        );
    for event_type in [
        VmLifecycleEventType::ReplacementBooted,
        VmLifecycleEventType::TenantsReplaced,
    ] {
        harness
            .lifecycle_repo
            .append(NewVmLifecycleEvent {
                vm_id: harness.source_vm_id,
                event_type,
                detail: detail.clone(),
            })
            .await
            .expect("durable pre-crash phase should append");
    }
    assert_eq!(
        harness
            .inventory_repo
            .decommission_if_unreferenced(harness.source_vm_id, DEAD_HOSTNAME)
            .await
            .expect("source decommission should persist before the crash"),
        api::repos::VmDecommissionResult::Decommissioned
    );

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect("restart should resume external teardown");

    let events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("resumed lifecycle should remain readable");
    assert_eq!(
        events
            .into_iter()
            .map(|event| event.event_type)
            .collect::<Vec<_>>(),
        vec![
            VmLifecycleEventType::ReplacementProvisioning,
            VmLifecycleEventType::ReplacementBooted,
            VmLifecycleEventType::TenantsReplaced,
            VmLifecycleEventType::ReplacementCompleted,
        ]
    );
    assert_eq!(harness.provisioner.create_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_run_loop_resumes_work_and_obeys_shutdown() {
    let harness = reconciler_harness_with_settings(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
        VmAutorepairSettings {
            check_interval: StdDuration::from_millis(5),
            host_dead_after: Duration::minutes(15),
            spend_ceiling_cents: 10_000,
            ..VmAutorepairSettings::default()
        },
    )
    .await;
    let admission = harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should already be admitted before loop start");
    let replacement = harness
        .inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: REPLACEMENT_HOSTNAME.to_string(),
            flapjack_url: format!("http://{REPLACEMENT_HOSTNAME}:7700"),
            capacity: json!({}),
        })
        .await
        .expect("replacement inventory should already exist before loop start");
    let mut detail = admission.event.detail.clone();
    detail
        .as_object_mut()
        .expect("admission detail should be an object")
        .insert(
            "replacement_vm_id".to_string(),
            json!(replacement.id.to_string()),
        );
    for event_type in [
        VmLifecycleEventType::ReplacementBooted,
        VmLifecycleEventType::TenantsReplaced,
    ] {
        harness
            .lifecycle_repo
            .append(NewVmLifecycleEvent {
                vm_id: harness.source_vm_id,
                event_type,
                detail: detail.clone(),
            })
            .await
            .expect("durable pre-loop phase should append");
    }
    harness
        .inventory_repo
        .decommission_if_unreferenced(harness.source_vm_id, DEAD_HOSTNAME)
        .await
        .expect("source decommission should persist before loop start");

    let lifecycle_repo = harness.lifecycle_repo.clone();
    let provisioner = harness.provisioner.clone();
    let source_vm_id = harness.source_vm_id;
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let handle = tokio::spawn(async move {
        harness.reconciler.run(shutdown_rx).await;
    });

    tokio::time::timeout(StdDuration::from_secs(1), async {
        loop {
            let events = lifecycle_repo
                .list_for_vm(source_vm_id)
                .await
                .expect("lifecycle history should remain readable");
            if events
                .last()
                .is_some_and(|event| event.event_type == VmLifecycleEventType::ReplacementCompleted)
            {
                break;
            }
            tokio::time::sleep(StdDuration::from_millis(5)).await;
        }
    })
    .await
    .expect("run loop should resume unfinished replacement");
    shutdown_tx.send(true).expect("shutdown signal should send");
    tokio::time::timeout(StdDuration::from_secs(1), handle)
        .await
        .expect("run loop should stop after shutdown")
        .expect("run task should join cleanly");
    assert_eq!(provisioner.create_call_count(), 0);
    assert_eq!(provisioner.destroy_call_count(), 1);
}

#[tokio::test]
async fn vm_autorepair_placement_failure_is_durable_and_stops_retirement() {
    let harness = reconciler_harness(
        VmStatus::Stopped,
        crate::common::engine_health::EngineHealthClient::unreachable("not consulted"),
        true,
    )
    .await;
    let customer_id = Uuid::new_v4();
    let deployment_id = Uuid::new_v4();
    harness
        .tenant_repo
        .create(customer_id, "search", deployment_id)
        .await
        .expect("tenant should seed");
    harness
        .tenant_repo
        .set_vm_id(customer_id, "search", harness.source_vm_id)
        .await
        .expect("tenant should start on the source");
    let admission = harness
        .lifecycle_repo
        .admit_replacement(replacement_admission_draft(harness.source_vm_id))
        .await
        .expect("replacement should already be admitted");
    let replacement = harness
        .inventory_repo
        .create(NewVmInventory {
            region: REGION.to_string(),
            provider: "aws".to_string(),
            hostname: REPLACEMENT_HOSTNAME.to_string(),
            flapjack_url: format!("http://{REPLACEMENT_HOSTNAME}:7700"),
            capacity: json!({}),
        })
        .await
        .expect("replacement inventory should seed");
    let mut booted_detail = admission.event.detail.clone();
    booted_detail
        .as_object_mut()
        .expect("admission detail should be an object")
        .insert(
            "replacement_vm_id".to_string(),
            json!(replacement.id.to_string()),
        );
    harness
        .lifecycle_repo
        .append(NewVmLifecycleEvent {
            vm_id: harness.source_vm_id,
            event_type: VmLifecycleEventType::ReplacementBooted,
            detail: booted_detail,
        })
        .await
        .expect("replacement boot should persist before placement");
    harness.tenant_repo.fail_next_set_vm_id();

    harness
        .reconciler
        .observe_once_at(observed_at())
        .await
        .expect_err("placement owner failure should fail this pass");

    let events = harness
        .lifecycle_repo
        .list_for_vm(harness.source_vm_id)
        .await
        .expect("failed lifecycle should remain readable");
    let failed = events.last().expect("replacement failure should append");
    assert_eq!(failed.event_type, VmLifecycleEventType::ReplacementFailed);
    assert_eq!(
        failed
            .detail
            .get("failure_phase")
            .and_then(serde_json::Value::as_str),
        Some("placement")
    );
    assert_eq!(
        harness
            .inventory_repo
            .get(harness.source_vm_id)
            .await
            .unwrap()
            .unwrap()
            .status,
        "active"
    );
    assert_eq!(harness.inventory_repo.status_mutation_call_count(), 0);
    assert_eq!(harness.provisioner.destroy_call_count(), 0);
}

#[tokio::test]
async fn vm_autorepair_running_healthy_is_live_and_non_mutating() {
    let provisioner = seed(VmStatus::Running);
    let engine = crate::common::engine_health::EngineHealthClient::healthy();

    let result = classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;

    assert_eq!(engine.attempts(), 1, "engine health seam must be consulted");
    assert_no_infra_mutation(&provisioner);
    assert_eq!(result, VmLiveness::Live);
}

#[tokio::test]
async fn vm_autorepair_running_unhealthy_or_unreachable_is_engine_down_not_host_dead() {
    for (engine, expected_attempts) in [
        (
            crate::common::engine_health::EngineHealthClient::unhealthy(503),
            1,
        ),
        (
            crate::common::engine_health::EngineHealthClient::unreachable("connection refused"),
            1,
        ),
    ] {
        let provisioner = seed(VmStatus::Running);

        let result =
            classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;

        assert_eq!(engine.attempts(), expected_attempts);
        assert_no_infra_mutation(&provisioner);
        assert_ne!(
            result,
            VmLiveness::HostDead,
            "engine HTTP health alone cannot classify host death"
        );
        assert_eq!(result, VmLiveness::EngineDown);
    }
}

#[tokio::test]
async fn vm_autorepair_dead_states_wait_full_window_before_host_dead() {
    let too_recent = observed_at() - Duration::minutes(14) - Duration::seconds(59);
    for status in [VmStatus::Stopped, VmStatus::Terminated] {
        let provisioner = seed(status);
        let engine = crate::common::engine_health::EngineHealthClient::unreachable("timeout");

        let result = classify_vm_liveness(
            &provisioner,
            engine.as_ref(),
            liveness_check(Some(too_recent)),
        )
        .await;

        assert_eq!(engine.attempts(), 1);
        assert_no_infra_mutation(&provisioner);
        assert_eq!(result, VmLiveness::Indeterminate);
    }

    let provisioner = MockVmProvisioner::new();
    let engine = crate::common::engine_health::EngineHealthClient::unreachable("not found");
    let result = classify_vm_liveness(
        &provisioner,
        engine.as_ref(),
        liveness_check(Some(too_recent)),
    )
    .await;
    assert_eq!(engine.attempts(), 1);
    assert_no_infra_mutation(&provisioner);
    assert_eq!(result, VmLiveness::Indeterminate);
}

#[tokio::test]
async fn vm_autorepair_dead_states_become_host_dead_only_at_window() {
    let at_boundary = observed_at() - Duration::minutes(15);
    for status in [VmStatus::Stopped, VmStatus::Terminated] {
        let provisioner = seed(status);
        let engine = crate::common::engine_health::EngineHealthClient::unreachable("timeout");

        let result = classify_vm_liveness(
            &provisioner,
            engine.as_ref(),
            liveness_check(Some(at_boundary)),
        )
        .await;

        assert_eq!(engine.attempts(), 1);
        assert_no_infra_mutation(&provisioner);
        assert_eq!(result, VmLiveness::HostDead);
    }

    let provisioner = MockVmProvisioner::new();
    let engine = crate::common::engine_health::EngineHealthClient::unreachable("not found");
    let result = classify_vm_liveness(
        &provisioner,
        engine.as_ref(),
        liveness_check(Some(at_boundary)),
    )
    .await;
    assert_eq!(engine.attempts(), 1);
    assert_no_infra_mutation(&provisioner);
    assert_eq!(result, VmLiveness::HostDead);
}

#[tokio::test]
async fn vm_autorepair_uncertain_instance_statuses_fail_closed() {
    for status in [VmStatus::Pending, VmStatus::Unknown] {
        let provisioner = seed(status);
        let engine = crate::common::engine_health::EngineHealthClient::unreachable("timeout");

        let result =
            classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;

        assert_eq!(engine.attempts(), 1);
        assert_no_infra_mutation(&provisioner);
        assert_eq!(result, VmLiveness::Indeterminate);
    }
}

#[tokio::test]
async fn vm_autorepair_provider_errors_and_missing_evidence_are_indeterminate() {
    let provisioner = seed(VmStatus::Running);
    provisioner.set_should_fail(true);
    let engine = crate::common::engine_health::EngineHealthClient::healthy();

    let provider_error =
        classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;
    assert_eq!(engine.attempts(), 1);
    assert_no_infra_mutation(&provisioner);
    assert_eq!(provider_error, VmLiveness::Indeterminate);

    provisioner.set_should_fail(false);
    let missing_id =
        classify_vm_liveness(&provisioner, engine.as_ref(), check_without_vm_id()).await;
    assert_eq!(engine.attempts(), 2);
    assert_no_infra_mutation(&provisioner);
    assert_eq!(missing_id, VmLiveness::Indeterminate);
}

#[tokio::test]
async fn vm_autorepair_not_configured_provider_is_indeterminate_and_consults_status_seam() {
    let provisioner = SpyProvisioner::with_status(SpyStatusReply::NotConfigured);
    let engine = crate::common::engine_health::EngineHealthClient::healthy();

    let result = classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;

    assert_eq!(engine.attempts(), 1);
    assert_eq!(provisioner.status_call_count(), 1);
    assert_eq!(result, VmLiveness::Indeterminate);
}

#[tokio::test]
async fn vm_autorepair_invalid_state_provider_error_is_indeterminate() {
    let provisioner = SpyProvisioner::with_status(SpyStatusReply::InvalidState("rebooting"));
    let engine = crate::common::engine_health::EngineHealthClient::unreachable("timeout");

    let result = classify_vm_liveness(&provisioner, engine.as_ref(), liveness_check(None)).await;

    assert_eq!(engine.attempts(), 1);
    assert_eq!(provisioner.status_call_count(), 1);
    assert_eq!(result, VmLiveness::Indeterminate);
}

#[tokio::test]
async fn vm_autorepair_contradictory_healthy_engine_on_dead_host_is_indeterminate() {
    let provisioner = seed(VmStatus::Stopped);
    let engine = crate::common::engine_health::EngineHealthClient::healthy();
    let dead_since = observed_at() - Duration::hours(1);

    let result = classify_vm_liveness(
        &provisioner,
        engine.as_ref(),
        liveness_check(Some(dead_since)),
    )
    .await;

    assert_eq!(engine.attempts(), 1);
    assert_no_infra_mutation(&provisioner);
    assert_eq!(result, VmLiveness::Indeterminate);
}

#[test]
fn vm_autorepair_kill_switch_defaults_disabled_for_all_environments() {
    for env_name in ["local", "staging", "prod"] {
        let cfg = Config::from_reader(config_reader(env_name, None))
            .expect("config without autorepair flag should parse");
        assert!(
            !cfg.vm_autorepair_enabled,
            "autorepair must default disabled in {env_name}"
        );
    }
}

#[test]
fn vm_autorepair_kill_switch_parses_explicit_true_false() {
    let enabled = Config::from_reader(config_reader("staging", Some("  TRUE  ")))
        .expect("true flag should parse through shared bool parser");
    assert!(enabled.vm_autorepair_enabled);

    let disabled = Config::from_reader(config_reader("prod", Some("false")))
        .expect("false flag should parse through shared bool parser");
    assert!(!disabled.vm_autorepair_enabled);
}

#[test]
fn vm_autorepair_kill_switch_rejects_malformed_values() {
    let err = Config::from_reader(config_reader("prod", Some("yes"))).unwrap_err();
    assert!(matches!(
        err,
        ConfigError::Invalid(ref key) if key == "FJCLOUD_VM_AUTOREPAIR_ENABLED"
    ));
}

#[test]
fn vm_autorepair_settings_parse_typed_env_overrides() {
    let settings = VmAutorepairSettings::from_reader(|key| {
        HashMap::from([
            ("FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS", "7"),
            ("FJCLOUD_VM_AUTOREPAIR_HOST_DEAD_AFTER_SECONDS", "11"),
            ("FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COOLDOWN_SECONDS", "13"),
            ("FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_WINDOW_SECONDS", "17"),
            ("FJCLOUD_VM_AUTOREPAIR_REGION_DEATH_LIMIT", "3"),
            ("FJCLOUD_VM_AUTOREPAIR_CONCURRENT_REPLACEMENT_CAP", "2"),
            ("FJCLOUD_VM_AUTOREPAIR_SPEND_WINDOW_SECONDS", "19"),
            ("FJCLOUD_VM_AUTOREPAIR_REPLACEMENT_COST_CENTS", "500"),
            ("FJCLOUD_VM_AUTOREPAIR_SPEND_CEILING_CENTS", "1500"),
        ])
        .get(key)
        .map(|value| value.to_string())
    })
    .expect("typed autorepair settings should parse");

    assert_eq!(settings.check_interval, StdDuration::from_secs(7));
    assert_eq!(settings.host_dead_after, Duration::seconds(11));
    assert_eq!(settings.replacement_cooldown, Duration::seconds(13));
    assert_eq!(settings.region_death_window, Duration::seconds(17));
    assert_eq!(settings.region_death_limit, 3);
    assert_eq!(settings.concurrent_replacement_cap, 2);
    assert_eq!(settings.spend_window, Duration::seconds(19));
    assert_eq!(settings.replacement_cost_cents, 500);
    assert_eq!(settings.spend_ceiling_cents, 1500);
}

#[test]
fn vm_autorepair_settings_reject_invalid_timing_values() {
    let error = VmAutorepairSettings::from_reader(|key| match key {
        "FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS" => Some("0".to_string()),
        _ => None,
    })
    .expect_err("zero check interval must fail closed");

    assert!(matches!(
        error,
        ConfigError::Invalid(ref key)
            if key == "FJCLOUD_VM_AUTOREPAIR_CHECK_INTERVAL_SECONDS"
    ));
}

#[test]
fn vm_autorepair_guardrail_boundaries_are_exact() {
    let cooldown_before = AutorepairPolicy {
        replacement_cooldown_until: Some(observed_at() + Duration::seconds(1)),
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &cooldown_before),
        AutorepairDecision::Refused(AutorepairRefusal::ReplacementCooldown)
    );

    let cooldown_at_expiry = AutorepairPolicy {
        replacement_cooldown_until: Some(observed_at()),
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &cooldown_at_expiry),
        AutorepairDecision::ReplacementAllowed
    );

    let region_at_limit = AutorepairPolicy {
        region_deaths_in_window: 2,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &region_at_limit),
        AutorepairDecision::ReplacementAllowed
    );

    let region_over_limit = AutorepairPolicy {
        region_deaths_in_window: 3,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &region_over_limit),
        AutorepairDecision::Refused(AutorepairRefusal::RegionDampening)
    );

    let concurrent_at_cap = AutorepairPolicy {
        concurrent_replacements: 1,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &concurrent_at_cap),
        AutorepairDecision::Refused(AutorepairRefusal::ConcurrentReplacementCap)
    );

    let spend_equal_ceiling = AutorepairPolicy {
        projected_spend_cents: 10_000,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &spend_equal_ceiling),
        AutorepairDecision::ReplacementAllowed
    );

    let spend_over_ceiling = AutorepairPolicy {
        projected_spend_cents: 10_001,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &spend_over_ceiling),
        AutorepairDecision::Refused(AutorepairRefusal::SpendCeiling)
    );
}

#[test]
fn vm_autorepair_closed_rule_set_covers_liveness_and_isolated_refusals() {
    for (liveness, expected) in [
        (
            VmLiveness::Live,
            AutorepairDecision::NoReplacement(VmLiveness::Live),
        ),
        (
            VmLiveness::EngineDown,
            AutorepairDecision::NoReplacement(VmLiveness::EngineDown),
        ),
        (
            VmLiveness::Indeterminate,
            AutorepairDecision::NoReplacement(VmLiveness::Indeterminate),
        ),
        (VmLiveness::HostDead, AutorepairDecision::ReplacementAllowed),
    ] {
        assert_eq!(decide_autorepair(liveness, &base_policy()), expected);
    }

    for (policy, refusal) in [
        (
            AutorepairPolicy {
                kill_switch_enabled: false,
                ..base_policy()
            },
            AutorepairRefusal::KillSwitchDisabled,
        ),
        (
            AutorepairPolicy {
                region_deaths_in_window: 3,
                ..base_policy()
            },
            AutorepairRefusal::RegionDampening,
        ),
        (
            AutorepairPolicy {
                concurrent_replacements: 1,
                ..base_policy()
            },
            AutorepairRefusal::ConcurrentReplacementCap,
        ),
        (
            AutorepairPolicy {
                projected_spend_cents: 10_001,
                ..base_policy()
            },
            AutorepairRefusal::SpendCeiling,
        ),
        (
            AutorepairPolicy {
                replacement_cooldown_until: Some(observed_at() + Duration::seconds(1)),
                ..base_policy()
            },
            AutorepairRefusal::ReplacementCooldown,
        ),
    ] {
        assert_eq!(
            decide_autorepair(VmLiveness::HostDead, &policy),
            AutorepairDecision::Refused(refusal)
        );
    }
}

#[test]
fn vm_autorepair_multi_violation_precedence_is_stable() {
    let all_violations = AutorepairPolicy {
        kill_switch_enabled: false,
        replacement_cooldown_until: Some(observed_at() + Duration::hours(1)),
        region_deaths_in_window: 3,
        concurrent_replacements: 1,
        projected_spend_cents: 10_001,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &all_violations),
        AutorepairDecision::Refused(AutorepairRefusal::KillSwitchDisabled)
    );

    let after_kill_switch = AutorepairPolicy {
        kill_switch_enabled: true,
        ..all_violations
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &after_kill_switch),
        AutorepairDecision::Refused(AutorepairRefusal::RegionDampening)
    );

    let after_region = AutorepairPolicy {
        region_deaths_in_window: 0,
        ..after_kill_switch
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &after_region),
        AutorepairDecision::Refused(AutorepairRefusal::ConcurrentReplacementCap)
    );

    let after_concurrent = AutorepairPolicy {
        concurrent_replacements: 0,
        ..after_region
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &after_concurrent),
        AutorepairDecision::Refused(AutorepairRefusal::SpendCeiling)
    );

    let after_spend = AutorepairPolicy {
        projected_spend_cents: 1,
        ..after_concurrent
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &after_spend),
        AutorepairDecision::Refused(AutorepairRefusal::ReplacementCooldown)
    );
}

#[test]
fn vm_autorepair_indeterminate_and_region_fanout_regressions_do_not_replace() {
    let permissive = base_policy();
    assert_eq!(
        decide_autorepair(VmLiveness::Indeterminate, &permissive),
        AutorepairDecision::NoReplacement(VmLiveness::Indeterminate)
    );

    let region_over_limit = AutorepairPolicy {
        region_deaths_in_window: 3,
        ..base_policy()
    };
    assert_eq!(
        decide_autorepair(VmLiveness::HostDead, &region_over_limit),
        AutorepairDecision::Refused(AutorepairRefusal::RegionDampening)
    );
}

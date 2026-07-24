use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use api::models::algolia_import_job::{
    AlgoliaImportCreateDestination, AlgoliaImportErrorCode, AlgoliaImportJob, AlgoliaImportSource,
    AlgoliaImportSourceMetadata, AlgoliaReplaceTargetFacts, NewAlgoliaImportJob,
    NewAlgoliaReplaceImportJob,
};
use api::models::cold_snapshot::{ColdSnapshot, NewColdSnapshot};
use api::models::restore_job::RestoreJob;
use api::models::vm_inventory::NewVmInventory;
use api::provisioner::region_map::RegionConfig;
use api::repos::{
    AlgoliaImportJobAdmissionError, AlgoliaImportJobRepo, CatalogLifecycleTargetIdentity,
    ColdSnapshotRepo, CustomerRepo, DeploymentRepo, DestinationEligibilityError,
    IndexMigrationRepo, IndexReplicaRepo, PgAlgoliaImportJobRepo, PgColdSnapshotRepo,
    PgCustomerRepo, PgDeploymentRepo, PgIndexMigrationRepo, PgIndexReplicaRepo, PgRestoreJobRepo,
    PgTenantRepo, PgVmInventoryRepo, RepoError, RestoreJobRepo, TenantRepo, VmInventoryRepo,
};
use api::router::build_router;
use api::secrets::{NodeSecretError, NodeSecretManager};
use api::services::alerting::MockAlertService;
use api::services::cold_tier::{
    ColdTierCandidate, ColdTierConfig, ColdTierDependencies, ColdTierError, ColdTierService,
    FlapjackNodeClient,
};
use api::services::discovery::{DiscoveryError, DiscoveryService};
use api::services::flapjack_node::flapjack_index_uid;
use api::services::flapjack_proxy::{FlapjackProxy, ProxyError};
use api::services::index_lifecycle_lease::{IndexLifecycleLease, LifecycleGuardPauseHook};
use api::services::migration::{
    MigrationConfig, MigrationError, MigrationHttpClient, MigrationHttpClientError,
    MigrationHttpRequest, MigrationHttpResponse, MigrationRequest, MigrationService,
};
use api::services::object_store::{InMemoryObjectStore, ObjectStore, RegionObjectStoreResolver};
use api::services::region_failover::{RegionFailoverConfig, RegionFailoverMonitor};
use api::services::replica::{ReplicaError, ReplicaService};
use api::services::restore::{RestoreConfig, RestoreError, RestoreService};
use api::state::AppState;
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Duration, Utc};
use reqwest::Method;
use serde::Deserialize;
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tokio::sync::oneshot;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::algolia_import_reservation_lifetime::{
    force_reservation_lifetime_case, reservation_lifetime_denominator, ReservationExpectation,
    ReservationLifetimeCase,
};
use crate::common::catalog_live_binding::CatalogLiveBinding;
use crate::common::engine_index_identity_test_support::{
    assert_migration_request_sequence, ExpectedMigrationRequest,
};
use crate::common::flapjack_proxy_test_support::MockFlapjackHttpClient;
use crate::common::support::pg_schema_harness::{connect_and_migrate, insert_active_customer};
use crate::common::{
    create_test_jwt, mock_alert_service, mock_deployment_repo, mock_node_secret_manager, mock_repo,
    mock_tenant_repo, mock_vm_inventory_repo, FailableObjectStore, TestStateBuilder,
    TEST_ADMIN_KEY,
};

const CATALOG_LIFECYCLE_WRITERS_JSON: &str =
    include_str!("../../../../scripts/tests/fixtures/catalog_lifecycle_writers.json");
const CATALOG_LIFECYCLE_ACCEPTANCE_ORACLES_JSON: &str =
    include_str!("../../../../scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json");

#[path = "catalog_lifecycle_lease_invariants.rs"]
mod catalog_lifecycle_lease_invariants;
#[path = "catalog_lifecycle_lease_race_matrix.rs"]
mod catalog_lifecycle_lease_race_matrix;
#[path = "catalog_lifecycle_lease_remote_races.rs"]
mod catalog_lifecycle_lease_remote_races;
#[path = "catalog_live_caller_admission.rs"]
mod catalog_live_caller_admission;

#[derive(Debug, Clone, Deserialize)]
struct CatalogLifecycleInventory {
    total_writer_count: usize,
    writers: Vec<CatalogLifecycleWriter>,
}

#[derive(Debug, Clone, Deserialize)]
struct CatalogLifecycleWriter {
    id: String,
    owner_path: String,
    source_anchor: String,
    disposition: String,
    live_caller_key: String,
    live_caller_command: String,
    live_scenario_key: String,
    live_phase: String,
}

/// Hand-calculated lifecycle acceptance oracle set.
///
/// This model is class-keyed only: it deliberately carries no writer IDs,
/// `owner_path`, `source_anchor`, function names, source-discovery rules, or
/// writer-to-class mappings. The writer denominator stays owned solely by
/// `scripts/tests/fixtures/catalog_lifecycle_writers.json`; this fixture owns
/// only the behavior expectation for each lifecycle class.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct AcceptanceOracles {
    version: u32,
    oracle_kind: String,
    lane_composition: LaneComposition,
    #[allow(dead_code)]
    privacy_erasure_dependencies: Vec<PrivacyErasureDependency>,
    oracles: BTreeMap<String, ClassOracle>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct PrivacyErasureDependency {
    id: String,
    owner: String,
    required_contract: String,
    minimum_unblock: String,
    status: String,
    reason: String,
}

/// Downstream composition contract: after Lanes 11 and 20 are composed, Lane 20
/// must execute every inventoried real caller with its resolved oracle before
/// route activation, and a missing dependency is a failure rather than a skip.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct LaneComposition {
    execute_every_inventoried_caller_before_route_activation: bool,
    missing_dependency_disposition: String,
}

/// Per-class behavior expectation. Only the fields for the keyed class are
/// populated; the other class's fields stay `None`.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClassOracle {
    #[allow(dead_code)]
    summary: String,
    // block_without_change acceptance fields.
    leased_behavior: Option<String>,
    release_trigger: Option<String>,
    // privacy_transition acceptance fields.
    soft_delete: Option<String>,
    hard_delete: Option<String>,
    reaper_scrub: Option<String>,
}

#[derive(Debug, Clone, Eq, Ord, PartialEq, PartialOrd)]
struct WriterObservation {
    id: String,
    owner_path: String,
    source_anchor: String,
    disposition: &'static str,
}

#[derive(Clone, Copy)]
struct CoverageRegistration {
    scenario: &'static str,
    owner_path: &'static str,
    function_name: &'static str,
    source_anchor: &'static str,
}

#[derive(Clone, Copy)]
struct ExecutableScenarioSource<'a> {
    scenario: &'static str,
    coverage_registration_index: usize,
    test_source: &'a str,
    test_module: &'static str,
    harness_source: &'a str,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct CoverageValidation {
    missing: BTreeSet<String>,
    duplicates: BTreeSet<String>,
    duplicate_scenarios: BTreeSet<&'static str>,
    unknown: BTreeSet<String>,
    wrong_disposition: BTreeSet<String>,
    wrong_scenarios: BTreeSet<String>,
    extra: BTreeSet<String>,
    empty_scenarios: BTreeSet<String>,
    stale_scenarios: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TenantRowSnapshot {
    tenant_id: String,
    deployment_id: Uuid,
    vm_id: Option<Uuid>,
    tier: String,
    cold_snapshot_id: Option<Uuid>,
    service_type: String,
    complete_row: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DeploymentRowSnapshot {
    id: Uuid,
    node_id: String,
    region: String,
    vm_provider: String,
    status: String,
    flapjack_url: Option<String>,
    complete_row: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ReplicaRowSnapshot {
    id: Uuid,
    customer_id: Uuid,
    tenant_id: String,
    primary_vm_id: Uuid,
    replica_vm_id: Uuid,
    replica_region: String,
    status: String,
    lag_ops: i64,
    complete_row: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ImportOperationRowSnapshot {
    id: Uuid,
    destination_kind: String,
    destination_deployment_id: Option<Uuid>,
    destination_vm_id: Option<Uuid>,
    physical_uid: Option<String>,
    dispatch_intent_state: String,
    lifecycle_generation: i64,
    status: String,
    publication_disposition: String,
    engine_ack_state: String,
    complete_row: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RetainedTargetSnapshot {
    target: String,
    tenants: Vec<TenantRowSnapshot>,
    deployments: Vec<DeploymentRowSnapshot>,
    operations: Vec<ImportOperationRowSnapshot>,
}

impl RetainedTargetSnapshot {
    async fn load(pool: &PgPool, customer_id: Uuid, target: &str) -> Self {
        Self {
            target: target.to_string(),
            tenants: tenant_rows(pool, customer_id).await,
            deployments: deployment_rows(pool, customer_id).await,
            operations: import_operation_rows(pool, customer_id, target).await,
        }
    }

    async fn assert_unchanged_after(&self, pool: &PgPool, customer_id: Uuid, attempt: &str) {
        let after = Self::load(pool, customer_id, &self.target).await;
        assert_eq!(
            after.tenants, self.tenants,
            "{attempt} must not mutate catalog placement rows"
        );
        assert_eq!(
            after.deployments, self.deployments,
            "{attempt} must not mutate deployment/routing rows"
        );
        assert_eq!(
            after.operations, self.operations,
            "{attempt} must not mutate the retained active reservation"
        );
    }
}

#[derive(Clone, Copy)]
enum ActiveReservationKind {
    Import,
    Replacement,
}

impl ActiveReservationKind {
    fn label(self) -> &'static str {
        match self {
            Self::Import => "import",
            Self::Replacement => "replacement",
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum RestoreIdentityDrift {
    Tier,
    VmId,
    ColdSnapshotId,
    DeploymentId,
    ServiceType,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct IdentityDriftDenominatorValidation {
    missing_labels: BTreeSet<&'static str>,
    duplicate_labels: BTreeSet<&'static str>,
    unexpected_labels: BTreeSet<&'static str>,
}

const RESTORE_IDENTITY_DRIFT_DENOMINATOR: [RestoreIdentityDrift; 5] = [
    RestoreIdentityDrift::Tier,
    RestoreIdentityDrift::VmId,
    RestoreIdentityDrift::ColdSnapshotId,
    RestoreIdentityDrift::DeploymentId,
    RestoreIdentityDrift::ServiceType,
];

impl RestoreIdentityDrift {
    fn label(self) -> &'static str {
        match self {
            Self::Tier => "tier",
            Self::VmId => "vm_id",
            Self::ColdSnapshotId => "cold_snapshot_id",
            Self::DeploymentId => "deployment_id",
            Self::ServiceType => "service_type",
        }
    }
}

fn identity_drift_denominator() -> &'static [RestoreIdentityDrift] {
    assert_closed_identity_drift_denominator();
    &RESTORE_IDENTITY_DRIFT_DENOMINATOR
}

fn assert_closed_identity_drift_denominator() {
    let expected = BTreeSet::from([
        "deployment_id",
        "vm_id",
        "tier",
        "cold_snapshot_id",
        "service_type",
    ]);
    assert_eq!(
        validate_identity_drift_labels(identity_drift_labels(), &expected),
        IdentityDriftDenominatorValidation::default(),
        "identity drift denominator must cover exactly the catalog target identity fields"
    );
}

#[test]
fn identity_drift_denominator_validator_rejects_malformed_labels() {
    let expected = identity_drift_labels().into_iter().collect::<BTreeSet<_>>();
    let mut malformed = identity_drift_labels();
    let missing = malformed.remove(0);
    malformed.push(malformed[0]);
    malformed.push("unexpected_identity_field");
    let mut expected_validation = IdentityDriftDenominatorValidation::default();
    expected_validation.missing_labels.insert(missing);
    expected_validation.duplicate_labels.insert(malformed[0]);
    expected_validation
        .unexpected_labels
        .insert("unexpected_identity_field");

    assert_eq!(
        validate_identity_drift_labels(malformed, &expected),
        expected_validation,
        "identity drift label validator must classify missing, duplicate, and unexpected labels"
    );
}

fn identity_drift_labels() -> Vec<&'static str> {
    RESTORE_IDENTITY_DRIFT_DENOMINATOR
        .iter()
        .map(|drift| drift.label())
        .collect()
}

fn validate_identity_drift_labels(
    labels: Vec<&'static str>,
    expected: &BTreeSet<&'static str>,
) -> IdentityDriftDenominatorValidation {
    let mut seen = BTreeSet::new();
    let mut duplicates = BTreeSet::new();
    for label in labels {
        if !seen.insert(label) {
            duplicates.insert(label);
        }
    }
    IdentityDriftDenominatorValidation {
        missing_labels: expected.difference(&seen).copied().collect(),
        duplicate_labels: duplicates,
        unexpected_labels: seen.difference(expected).copied().collect(),
    }
}

fn assert_identity_drift_applied(
    before: &CatalogLifecycleTargetIdentity,
    after: &CatalogLifecycleTargetIdentity,
    drift: RestoreIdentityDrift,
    context: &str,
) {
    let changed_fields: BTreeSet<&str> = [
        ("deployment_id", before.deployment_id != after.deployment_id),
        ("vm_id", before.vm_id != after.vm_id),
        ("tier", before.tier != after.tier),
        (
            "cold_snapshot_id",
            before.cold_snapshot_id != after.cold_snapshot_id,
        ),
        ("service_type", before.service_type != after.service_type),
    ]
    .into_iter()
    .filter_map(|(field, changed)| changed.then_some(field))
    .collect();
    assert_eq!(
        changed_fields,
        BTreeSet::from([drift.label()]),
        "{context} must drift exactly the selected identity field"
    );
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ColdSnapshotRowSnapshot {
    id: Uuid,
    customer_id: Uuid,
    tenant_id: String,
    source_vm_id: Uuid,
    object_key: String,
    size_bytes: i64,
    checksum: Option<String>,
    status: String,
    error: Option<String>,
}

struct NoopRestoreNodeClient;

#[async_trait]
impl FlapjackNodeClient for NoopRestoreNodeClient {
    async fn export_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        Ok(Vec::new())
    }

    async fn delete_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn import_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _data: &[u8],
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn verify_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }
}

#[derive(Default)]
struct CountingRestoreNodeClient {
    import_calls: AtomicUsize,
    verify_calls: AtomicUsize,
    identity_drift_during_import: Mutex<Option<(PgPool, Uuid, String, RestoreIdentityDrift)>>,
    drifted_identity: Mutex<Option<CatalogLifecycleTargetIdentity>>,
}

impl CountingRestoreNodeClient {
    fn remote_call_count(&self) -> usize {
        self.import_calls.load(Ordering::SeqCst) + self.verify_calls.load(Ordering::SeqCst)
    }

    fn drift_identity_during_import(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        drift: RestoreIdentityDrift,
    ) {
        *self.identity_drift_during_import.lock().unwrap() =
            Some((pool, customer_id, target.to_string(), drift));
    }

    fn take_drifted_identity(&self) -> CatalogLifecycleTargetIdentity {
        self.drifted_identity
            .lock()
            .unwrap()
            .take()
            .expect("restore identity drift hook must record final drifted identity")
    }
}

#[async_trait]
impl FlapjackNodeClient for CountingRestoreNodeClient {
    async fn export_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        Ok(Vec::new())
    }

    async fn delete_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn import_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _data: &[u8],
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.import_calls.fetch_add(1, Ordering::SeqCst);
        let drift = self.identity_drift_during_import.lock().unwrap().take();
        if let Some((pool, customer_id, target, drift)) = drift {
            let identity = apply_restore_identity_drift(&pool, customer_id, &target, drift).await;
            *self.drifted_identity.lock().unwrap() = Some(identity);
        }
        Ok(())
    }

    async fn verify_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.verify_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

struct RestoreIntentBoundarySecretManager {
    pool: PgPool,
    customer_id: Uuid,
    tenant_id: String,
    node_client: Arc<CountingRestoreNodeClient>,
    boundary_calls: AtomicUsize,
}

impl RestoreIntentBoundarySecretManager {
    fn new(
        pool: PgPool,
        customer_id: Uuid,
        tenant_id: &str,
        node_client: Arc<CountingRestoreNodeClient>,
    ) -> Self {
        Self {
            pool,
            customer_id,
            tenant_id: tenant_id.to_string(),
            node_client,
            boundary_calls: AtomicUsize::new(0),
        }
    }

    fn boundary_call_count(&self) -> usize {
        self.boundary_calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl NodeSecretManager for RestoreIntentBoundarySecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        Ok(format!("fj_live_restore_{node_id}"))
    }

    async fn delete_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        assert_eq!(
            self.node_client.remote_call_count(),
            0,
            "restore execute admission proof must run before node import or verify"
        );
        assert_restore_intent_blocks_admission(
            &self.pool,
            self.customer_id,
            &self.tenant_id,
            "restore-execute-intent",
        )
        .await;
        self.boundary_calls.fetch_add(1, Ordering::SeqCst);
        Ok(format!("fj_live_restore_{node_id}"))
    }

    async fn rotate_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        Err(NodeSecretError::Api(
            "rotation not supported in this test".into(),
        ))
    }

    async fn commit_rotation(
        &self,
        _node_id: &str,
        _region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }
}

/// Committed catalog state observed from a separate connection at the moment
/// the first index export begins — i.e. after `begin_snapshot_record` has
/// committed the snapshot intent but before any hot-to-cold publication. Used
/// to prove the guarded snapshot intent is durably visible before remote export
/// work starts.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ColdTierExportObservation {
    tier: String,
    vm_id: Option<Uuid>,
    cold_snapshot_id: Option<Uuid>,
    snapshot_status: Option<String>,
    delete_calls_before_first_export: usize,
}

#[derive(Default)]
struct CountingColdTierNodeClient {
    export_calls: AtomicUsize,
    delete_calls: AtomicUsize,
    replace_reservation_during_export: Mutex<Option<(PgPool, Uuid, String, String)>>,
    replace_reservation_result:
        Mutex<Option<Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>>>,
    service_type_drift_during_export: Mutex<Option<(PgPool, Uuid, String)>>,
    export_failure: Mutex<Option<String>>,
    delete_failure: Mutex<Option<String>>,
    observe_at_first_export: Mutex<Option<(PgPool, Uuid, String)>>,
    export_observation: Mutex<Option<ColdTierExportObservation>>,
}

struct ObservingSeedSecretManager {
    pool: PgPool,
    customer_id: Uuid,
    tenant_id: String,
    observed_tiers: Mutex<Vec<Option<String>>>,
    boundary_hook: Option<LifecycleGuardPauseHook>,
}

impl ObservingSeedSecretManager {
    fn new(pool: PgPool, customer_id: Uuid, tenant_id: &str) -> Self {
        Self {
            pool,
            customer_id,
            tenant_id: tenant_id.to_string(),
            observed_tiers: Mutex::new(Vec::new()),
            boundary_hook: None,
        }
    }

    /// Variant used by the admin-seed race test: `boundary_hook` fires inside
    /// `create_node_api_key` — the seed's remote-secret-work boundary, after the
    /// provisioning intent is committed but before any remote work — so a
    /// competing reservation can race the persisted seed intent.
    fn new_with_boundary_hook(
        pool: PgPool,
        customer_id: Uuid,
        tenant_id: &str,
        boundary_hook: LifecycleGuardPauseHook,
    ) -> Self {
        Self {
            pool,
            customer_id,
            tenant_id: tenant_id.to_string(),
            observed_tiers: Mutex::new(Vec::new()),
            boundary_hook: Some(boundary_hook),
        }
    }

    fn observed_tiers(&self) -> Vec<Option<String>> {
        self.observed_tiers.lock().unwrap().clone()
    }
}

#[async_trait]
impl NodeSecretManager for ObservingSeedSecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        let observed_tier = sqlx::query_scalar::<_, String>(
            "SELECT tier
             FROM customer_tenants
             WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(self.customer_id)
        .bind(&self.tenant_id)
        .fetch_optional(&self.pool)
        .await
        .expect("seed intent lookup should not fail");
        self.observed_tiers.lock().unwrap().push(observed_tier);
        if let Some(hook) = &self.boundary_hook {
            hook().await;
        }
        Ok(format!("fj_live_seed_{node_id}"))
    }

    async fn delete_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        if !self.observed_tiers.lock().unwrap().is_empty() {
            return Ok(format!("fj_live_seed_{node_id}"));
        }
        Err(NodeSecretError::Api(format!(
            "no key found for node {node_id}"
        )))
    }

    async fn rotate_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        Err(NodeSecretError::Api(
            "rotation not supported in this test".into(),
        ))
    }

    async fn commit_rotation(
        &self,
        _node_id: &str,
        _region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        Ok(())
    }
}

impl CountingColdTierNodeClient {
    fn remote_call_count(&self) -> usize {
        self.export_calls.load(Ordering::SeqCst) + self.delete_calls.load(Ordering::SeqCst)
    }

    fn export_call_count(&self) -> usize {
        self.export_calls.load(Ordering::SeqCst)
    }

    fn delete_call_count(&self) -> usize {
        self.delete_calls.load(Ordering::SeqCst)
    }

    /// Make the next index export fail with the given message, without mutating
    /// any catalog state — models a remote export outage after the snapshot
    /// intent committed but before upload.
    fn fail_export(&self, message: &str) {
        *self.export_failure.lock().unwrap() = Some(message.to_string());
    }

    /// Make source eviction fail with the given message after the hot-to-cold
    /// publication has already committed — models a remote delete outage on the
    /// published-cold rollback boundary.
    fn fail_delete(&self, message: &str) {
        *self.delete_failure.lock().unwrap() = Some(message.to_string());
    }

    /// Record the committed catalog state (from a separate connection) the first
    /// time an export runs, so a test can prove the guarded snapshot intent is
    /// durably visible before remote export work begins.
    fn observe_committed_state_at_first_export(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
    ) {
        *self.observe_at_first_export.lock().unwrap() =
            Some((pool, customer_id, target.to_string()));
    }

    fn take_export_observation(&self) -> ColdTierExportObservation {
        self.export_observation
            .lock()
            .unwrap()
            .take()
            .expect("export observation hook must run during the first export")
    }

    fn attempt_replace_reservation_during_export(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        idempotency_key: &str,
    ) {
        *self.replace_reservation_during_export.lock().unwrap() = Some((
            pool,
            customer_id,
            target.to_string(),
            idempotency_key.to_string(),
        ));
    }

    fn take_replace_reservation_result(
        &self,
    ) -> Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError> {
        self.replace_reservation_result
            .lock()
            .unwrap()
            .take()
            .expect("replace reservation hook must run during export")
    }

    fn drift_service_type_during_export(&self, pool: PgPool, customer_id: Uuid, target: &str) {
        *self.service_type_drift_during_export.lock().unwrap() =
            Some((pool, customer_id, target.to_string()));
    }
}

#[async_trait]
impl FlapjackNodeClient for CountingColdTierNodeClient {
    async fn export_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<Vec<u8>, ColdTierError> {
        let export_seq = self.export_calls.fetch_add(1, Ordering::SeqCst);
        if export_seq == 0 {
            let observe = self.observe_at_first_export.lock().unwrap().take();
            if let Some((pool, customer_id, target)) = observe {
                let observation = observe_cold_export_state(
                    &pool,
                    customer_id,
                    &target,
                    self.delete_calls.load(Ordering::SeqCst),
                )
                .await;
                *self.export_observation.lock().unwrap() = Some(observation);
            }
        }
        let reservation = self
            .replace_reservation_during_export
            .lock()
            .unwrap()
            .take();
        if let Some((pool, customer_id, target, idempotency_key)) = reservation {
            let result = PgAlgoliaImportJobRepo::new(pool)
                .create_replace(replace_job(customer_id, &target, &idempotency_key))
                .await;
            *self.replace_reservation_result.lock().unwrap() = Some(result);
        }
        if let Some(message) = self.export_failure.lock().unwrap().take() {
            return Err(ColdTierError::Export(message));
        }
        let service_type_drift = self.service_type_drift_during_export.lock().unwrap().take();
        if let Some((pool, customer_id, target)) = service_type_drift {
            sqlx::query(
                "UPDATE customer_tenants
                 SET service_type = 'shared'
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(target)
            .execute(&pool)
            .await
            .expect("drift service type during remote export");
            return Err(ColdTierError::Export(
                "injected export failure after identity drift".to_string(),
            ));
        }
        Ok(b"snapshot".to_vec())
    }

    async fn delete_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        self.delete_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(message) = self.delete_failure.lock().unwrap().take() {
            return Err(ColdTierError::Evict(message));
        }
        Ok(())
    }

    async fn import_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _data: &[u8],
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }

    async fn verify_index(
        &self,
        _flapjack_url: &str,
        _index_name: &str,
        _api_key: &str,
    ) -> Result<(), ColdTierError> {
        Ok(())
    }
}

#[derive(Default)]
struct CountingMigrationHttpClient {
    requests: Mutex<Vec<MigrationHttpRequest>>,
    responses: Mutex<VecDeque<Result<MigrationHttpResponse, MigrationHttpClientError>>>,
    drift_after_source_pause: Mutex<Option<(PgPool, Uuid, String, RestoreIdentityDrift)>>,
    drift_during_source_ops: Mutex<Option<(PgPool, Uuid, String, RestoreIdentityDrift)>>,
    drift_after_resume: Mutex<Option<(PgPool, Uuid, String, Uuid)>>,
    identity_drift_after_source_resume: Mutex<Option<(PgPool, Uuid, String, RestoreIdentityDrift)>>,
    drifted_identity: Mutex<Option<CatalogLifecycleTargetIdentity>>,
}

impl CountingMigrationHttpClient {
    fn enqueue_response(&self, response: Result<MigrationHttpResponse, MigrationHttpClientError>) {
        self.responses.lock().unwrap().push_back(response);
    }

    fn request_count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    fn recorded_requests(&self) -> Vec<MigrationHttpRequest> {
        self.requests.lock().unwrap().clone()
    }

    fn drift_identity_after_source_pause(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        drift: RestoreIdentityDrift,
    ) {
        *self.drift_after_source_pause.lock().unwrap() =
            Some((pool, customer_id, target.to_string(), drift));
    }

    fn drift_identity_during_source_ops(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        drift: RestoreIdentityDrift,
    ) {
        *self.drift_during_source_ops.lock().unwrap() =
            Some((pool, customer_id, target.to_string(), drift));
    }

    fn take_drifted_identity(&self) -> CatalogLifecycleTargetIdentity {
        self.drifted_identity
            .lock()
            .unwrap()
            .take()
            .expect("migration identity drift hook must record final drifted identity")
    }

    fn drift_identity_after_source_resume(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        drift: RestoreIdentityDrift,
    ) {
        *self.identity_drift_after_source_resume.lock().unwrap() =
            Some((pool, customer_id, target.to_string(), drift));
    }

    fn drift_identity_after_resume(
        &self,
        pool: PgPool,
        customer_id: Uuid,
        target: &str,
        vm_id: Uuid,
    ) {
        *self.drift_after_resume.lock().unwrap() =
            Some((pool, customer_id, target.to_string(), vm_id));
    }
}

#[async_trait]
impl MigrationHttpClient for CountingMigrationHttpClient {
    async fn send(
        &self,
        request: MigrationHttpRequest,
    ) -> Result<MigrationHttpResponse, MigrationHttpClientError> {
        let should_drift = request.url.contains("/internal/pause/");
        let should_drift_source_ops = request.url.contains("/internal/ops?");
        let should_drift_tier = request.url.contains("/internal/resume/");
        self.requests.lock().unwrap().push(request);
        let drift = should_drift
            .then(|| self.drift_after_source_pause.lock().unwrap().take())
            .flatten();
        let source_ops_drift = should_drift_source_ops
            .then(|| self.drift_during_source_ops.lock().unwrap().take())
            .flatten();
        let identity_drift = should_drift_tier
            .then(|| self.drift_after_resume.lock().unwrap().take())
            .flatten();
        let source_resume_drift = should_drift_tier
            .then(|| {
                self.identity_drift_after_source_resume
                    .lock()
                    .unwrap()
                    .take()
            })
            .flatten();
        if let Some((pool, customer_id, target, drift)) = drift {
            let identity = apply_migration_identity_drift(&pool, customer_id, &target, drift).await;
            *self.drifted_identity.lock().unwrap() = Some(identity);
        }
        if let Some((pool, customer_id, target, drift)) = source_ops_drift {
            let identity = apply_migration_identity_drift(&pool, customer_id, &target, drift).await;
            *self.drifted_identity.lock().unwrap() = Some(identity);
        }
        if let Some((pool, customer_id, target, vm_id)) = identity_drift {
            sqlx::query(
                "UPDATE customer_tenants
                 SET vm_id = $3, tier = 'pinned'
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(&target)
            .bind(vm_id)
            .execute(&pool)
            .await
            .expect("drift tenant identity after resume");
        }
        if let Some((pool, customer_id, target, drift)) = source_resume_drift {
            let identity = apply_migration_identity_drift(&pool, customer_id, &target, drift).await;
            *self.drifted_identity.lock().unwrap() = Some(identity);
        }
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("migration lease refusal must happen before HTTP dispatch")
    }
}

fn enqueue_source_ops(
    http_client: &CountingMigrationHttpClient,
    index_name: &str,
    current_seq: i64,
) {
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: serde_json::json!({
            "tenant_id": index_name,
            "ops": [],
            "current_seq": current_seq
        })
        .to_string(),
    }));
}

fn oplog_metric(index_name: &str, seq: i64) -> String {
    format!(r#"flapjack_oplog_current_seq{{index="{index_name}"}} {seq}"#)
}

fn queue_successful_migration_http(
    http_client: &CountingMigrationHttpClient,
    index_name: &str,
    source_seq: i64,
    near_zero_dest_seq: i64,
) {
    enqueue_source_ops(http_client, index_name, source_seq);
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, near_zero_dest_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(index_name, source_seq),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
}

const ROUTE_SPRINT_SCOPES: &[(&str, &str)] = &[
    (
        "infra/api/src/routes/indexes/shared_vm.rs",
        "create_index_on_shared_vm",
    ),
    ("infra/api/src/routes/indexes/lifecycle.rs", "delete_index"),
    (
        "infra/api/src/routes/indexes/lifecycle.rs",
        "rollback_shared_vm_delete_intent",
    ),
    ("infra/api/src/routes/admin/indexes.rs", "seed_index"),
    (
        "infra/api/src/routes/admin/indexes.rs",
        "publish_seed_intent",
    ),
    (
        "infra/api/src/routes/admin/indexes.rs",
        "rollback_seed_intent",
    ),
    (
        "infra/api/src/routes/admin/indexes.rs",
        "resolve_existing_seed_index",
    ),
    ("infra/api/src/repos/pg_tenant_repo.rs", "create"),
    (
        "infra/api/src/repos/pg_tenant_repo.rs",
        "create_lifecycle_intent_tx",
    ),
    (
        "infra/api/src/repos/pg_tenant_repo.rs",
        "publish_lifecycle_placement_tx",
    ),
    (
        "infra/api/src/repos/pg_tenant_repo.rs",
        "publish_delete_lifecycle_intent",
    ),
    ("infra/api/src/repos/pg_tenant_repo.rs", "set_vm_id"),
    ("infra/api/src/repos/pg_tenant_repo.rs", "delete"),
];

const F5P1_EXECUTABLE_SCENARIO_SOURCES: &[ExecutableScenarioSource<'static>] = &[
    ExecutableScenarioSource {
        scenario: "soft_delete_increments_lifecycle_generation_exactly_once",
        coverage_registration_index: 0,
        test_source: include_str!("pg_customer_repo_test.rs"),
        test_module: "pg_customer_repo_test",
        harness_source: include_str!("../platform.rs"),
    },
    ExecutableScenarioSource {
        scenario: "delete_account_soft_delete_retains_row_for_audit_visibility",
        coverage_registration_index: 1,
        test_source: include_str!("account_test.rs"),
        test_module: "account_test",
        harness_source: include_str!("../platform.rs"),
    },
    ExecutableScenarioSource {
        scenario: "delete_admin_tenants_id_writes_tenant_deleted_audit_row",
        coverage_registration_index: 2,
        test_source: include_str!("admin_audit_view_test.rs"),
        test_module: "admin_audit_view_test",
        harness_source: include_str!("../auth_admin.rs"),
    },
];

const F5P2_EXECUTABLE_SCENARIO_SOURCES: &[ExecutableScenarioSource<'static>] = &[
    ExecutableScenarioSource {
        scenario: "hard_delete_removes_customer_and_dependents_then_404s_on_repeat",
        coverage_registration_index: 0,
        test_source: include_str!("pg_customer_repo_test.rs"),
        test_module: "pg_customer_repo_test",
        harness_source: include_str!("../platform.rs"),
    },
    ExecutableScenarioSource {
        scenario: "hard_delete_removes_customer_and_dependents_then_404s_on_repeat",
        coverage_registration_index: 1,
        test_source: include_str!("pg_customer_repo_test.rs"),
        test_module: "pg_customer_repo_test",
        harness_source: include_str!("../platform.rs"),
    },
    ExecutableScenarioSource {
        scenario: "hard_delete_removes_customer_and_dependents_then_404s_on_repeat",
        coverage_registration_index: 2,
        test_source: include_str!("pg_customer_repo_test.rs"),
        test_module: "pg_customer_repo_test",
        harness_source: include_str!("../platform.rs"),
    },
    ExecutableScenarioSource {
        scenario: "retention_job_erases_only_api_selected_eligible_customer",
        coverage_registration_index: 3,
        test_source: include_str!("retention_job_test.rs"),
        test_module: "retention_job_test",
        harness_source: include_str!("../platform.rs"),
    },
];

#[test]
fn catalog_lifecycle_inventory_matches_source_discovery() {
    let inventory: CatalogLifecycleInventory = serde_json::from_str(CATALOG_LIFECYCLE_WRITERS_JSON)
        .expect("catalog lifecycle writer inventory must be valid JSON");
    let observed = discover_catalog_lifecycle_writers();

    assert_catalog_lifecycle_inventory_valid(&inventory, &observed);
}

#[test]
fn catalog_lifecycle_inventory_shape_mutations_fail_closed() {
    let inventory = canonical_catalog_lifecycle_inventory();
    let observed = discover_catalog_lifecycle_writers();
    let block_id = writer_id_for_disposition(&inventory, "block_without_change");
    let privacy_id = writer_id_for_disposition(&inventory, "privacy_transition");
    let duplicate_id = inventory.writers[0].id.clone();

    let cases = [
        (
            "empty_writers",
            {
                let mut inventory = inventory.clone();
                inventory.writers.clear();
                inventory
            },
            "writers must not be empty".to_string(),
        ),
        (
            "zero_total_writer_count",
            {
                let mut inventory = inventory.clone();
                inventory.total_writer_count = 0;
                inventory
            },
            "total_writer_count must be greater than zero".to_string(),
        ),
        (
            "empty_block_without_change_class",
            {
                let mut inventory = inventory.clone();
                inventory
                    .writers
                    .retain(|writer| writer.disposition != "block_without_change");
                inventory.total_writer_count = inventory.writers.len();
                inventory
            },
            "inventory must include block_without_change writers".to_string(),
        ),
        (
            "empty_privacy_transition_class",
            {
                let mut inventory = inventory.clone();
                inventory
                    .writers
                    .retain(|writer| writer.disposition != "privacy_transition");
                inventory.total_writer_count = inventory.writers.len();
                inventory
            },
            "inventory must include privacy_transition writers".to_string(),
        ),
        (
            "duplicate_writer_ids",
            {
                let mut inventory = inventory.clone();
                inventory.writers.push(inventory.writers[0].clone());
                inventory.total_writer_count = inventory.writers.len();
                inventory
            },
            format!("duplicate catalog lifecycle writer ID: {duplicate_id}"),
        ),
        (
            "declared_total_writer_length_mismatch",
            {
                let mut inventory = inventory.clone();
                inventory.total_writer_count += 1;
                inventory
            },
            format!(
                "total_writer_count must match the number of fixture writers: declared={} actual={}",
                inventory.total_writer_count + 1,
                inventory.writers.len()
            ),
        ),
        (
            "disposition_count_sum_mismatch",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).disposition = "drifted".to_string();
                inventory
            },
            format!(
                "disposition class counts must sum to total_writer_count: disposition_sum={} total={}",
                inventory.total_writer_count - 1,
                inventory.total_writer_count
            ),
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        assert_inventory_finding(case_name, &mutated, &observed, &expected_finding);
    }

    let mut privacy_as_block = inventory.clone();
    writer_mut(&mut privacy_as_block, &privacy_id).disposition = "block_without_change".to_string();
    assert_inventory_finding(
        "privacy_transition_class_drift",
        &privacy_as_block,
        &observed,
        &format!(
            "disposition mismatch for {privacy_id}: fixture=block_without_change observed=privacy_transition"
        ),
    );
}

#[test]
fn catalog_lifecycle_inventory_metadata_mutations_fail_closed() {
    let inventory = canonical_catalog_lifecycle_inventory();
    let observed = discover_catalog_lifecycle_writers();
    let block_id = writer_id_for_disposition(&inventory, "block_without_change");
    let privacy_id = writer_id_for_disposition(&inventory, "privacy_transition");
    let block_source_anchor = writer(&inventory, &block_id).source_anchor.clone();
    let privacy_source_anchor = writer(&inventory, &privacy_id).source_anchor.clone();

    let cases = [
        (
            "empty_disposition",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).disposition.clear();
                inventory
            },
            format!("disposition is required for {block_id}"),
        ),
        (
            "unknown_disposition",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).disposition = "unknown".to_string();
                inventory
            },
            format!("unknown catalog lifecycle writer disposition for {block_id}: unknown"),
        ),
        (
            "drifted_owner_path",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).owner_path =
                    "infra/api/src/routes/indexes/drifted.rs".to_string();
                inventory
            },
            format!(
                "owner_path mismatch for {block_id}: fixture=infra/api/src/routes/indexes/drifted.rs observed={}",
                writer(&inventory, &block_id).owner_path
            ),
        ),
        (
            "drifted_source_anchor",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).source_anchor =
                    "tenant_repo.drifted".to_string();
                inventory
            },
            format!(
                "source_anchor mismatch for {block_id}: fixture=tenant_repo.drifted observed={block_source_anchor}"
            ),
        ),
        (
            "missing_live_caller_key",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).live_caller_key.clear();
                inventory
            },
            format!("live_caller_key is required for {block_id}"),
        ),
        (
            "missing_live_scenario_key",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id)
                    .live_scenario_key
                    .clear();
                inventory
            },
            format!("live_scenario_key is required for {block_id}"),
        ),
        (
            "unknown_live_phase",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).live_phase = "probe_only".to_string();
                inventory
            },
            format!("unknown live_phase for {block_id}: probe_only"),
        ),
        (
            "drifted_block_without_change_class",
            {
                let mut inventory = inventory.clone();
                writer_mut(&mut inventory, &block_id).disposition = "privacy_transition".to_string();
                inventory
            },
            format!(
                "disposition mismatch for {block_id}: fixture=privacy_transition observed=block_without_change"
            ),
        ),
        (
            "omitted_source_discovered_writer",
            {
                let mut inventory = inventory.clone();
                inventory.writers.retain(|writer| writer.id != block_id);
                inventory.total_writer_count = inventory.writers.len();
                inventory
            },
            format!("missing source-discovered writer: {block_id}"),
        ),
        (
            "fixture_only_writer",
            {
                let mut inventory = inventory.clone();
                let mut fixture_only = inventory.writers[0].clone();
                fixture_only.id = writer_id(
                    "infra/api/src/routes/indexes/fixture_only.rs",
                    "fixture_only_writer",
                    "tenant_repo.set_vm_id",
                );
                fixture_only.owner_path = "infra/api/src/routes/indexes/fixture_only.rs".to_string();
                fixture_only.source_anchor = "tenant_repo.set_vm_id".to_string();
                fixture_only.disposition = "block_without_change".to_string();
                inventory.writers.push(fixture_only.clone());
                inventory.total_writer_count = inventory.writers.len();
                inventory
            },
            "fixture-only writer absent from source discovery: catalog_writer__infra_api_src_routes_indexes_fixture_only__fixture_only_writer__tenant_repo_set_vm_id".to_string(),
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        assert_inventory_finding(case_name, &mutated, &observed, &expected_finding);
    }

    let mut privacy_source_drift = inventory.clone();
    writer_mut(&mut privacy_source_drift, &privacy_id).source_anchor =
        "customer_repo.drifted".to_string();
    assert_inventory_finding(
        "privacy_transition_source_anchor_drift",
        &privacy_source_drift,
        &observed,
        &format!(
            "source_anchor mismatch for {privacy_id}: fixture=customer_repo.drifted observed={privacy_source_anchor}"
        ),
    );
}

/// The canonical acceptance oracle validates in isolation and joins cleanly onto
/// every writer disposition in the canonical inventory.
#[test]
fn catalog_lifecycle_acceptance_oracle_matches_inventory_dispositions() {
    let inventory = canonical_catalog_lifecycle_inventory();
    let oracles = canonical_acceptance_oracles();

    let mut findings = validate_oracles(&oracles);
    findings.append(&mut validate_oracle_inventory_join(&inventory, &oracles));

    assert!(
        findings.is_empty(),
        "canonical acceptance oracle must validate and join cleanly onto the writer inventory: {findings:#?}"
    );
}

/// Schema-shape mutations of the oracle set must fail closed with the exact
/// finding for a missing payload, empty map, missing class key, and unknown
/// class key.
#[test]
fn catalog_lifecycle_oracle_schema_mutations_fail_closed() {
    let oracles = canonical_acceptance_oracles();

    // Missing oracle payload: an empty document cannot parse and must be
    // reported rather than panicking.
    let missing_payload = validate_oracles_json("");
    assert!(
        missing_payload
            .iter()
            .any(|finding| finding.starts_with("acceptance oracle payload must be valid JSON")),
        "missing oracle payload must report a parse finding; actual findings={missing_payload:#?}"
    );

    let block = oracles
        .oracles
        .get("block_without_change")
        .expect("canonical oracle must include block_without_change")
        .clone();

    let cases = [
        (
            "wrong_oracle_version",
            {
                let mut oracles = oracles.clone();
                oracles.version = 2;
                oracles
            },
            "acceptance oracle version must be 1, got 2".to_string(),
        ),
        (
            "wrong_oracle_kind",
            {
                let mut oracles = oracles.clone();
                oracles.oracle_kind = "catalog_lifecycle_inventory".to_string();
                oracles
            },
            "acceptance oracle kind must be catalog_lifecycle_acceptance, got catalog_lifecycle_inventory"
                .to_string(),
        ),
        (
            "empty_oracle_map",
            {
                let mut oracles = oracles.clone();
                oracles.oracles.clear();
                oracles
            },
            "acceptance oracle map must not be empty".to_string(),
        ),
        (
            "missing_block_without_change",
            {
                let mut oracles = oracles.clone();
                oracles.oracles.remove("block_without_change");
                oracles
            },
            "acceptance oracle map must include the block_without_change class".to_string(),
        ),
        (
            "missing_privacy_transition",
            {
                let mut oracles = oracles.clone();
                oracles.oracles.remove("privacy_transition");
                oracles
            },
            "acceptance oracle map must include the privacy_transition class".to_string(),
        ),
        (
            "unknown_oracle_class",
            {
                let mut oracles = oracles.clone();
                oracles.oracles.insert("reactivate".to_string(), block.clone());
                oracles
            },
            "unknown acceptance oracle class: reactivate".to_string(),
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        let findings = validate_oracles(&mutated);
        assert!(
            findings.contains(&expected_finding),
            "{case_name} must report {expected_finding:?}; actual findings={findings:#?}"
        );
    }
}

/// Unknown fields at every schema layer must fail during deserialization rather
/// than being silently ignored as non-contract metadata.
#[test]
fn catalog_lifecycle_oracle_rejects_unknown_fields() {
    let canonical: serde_json::Value =
        serde_json::from_str(CATALOG_LIFECYCLE_ACCEPTANCE_ORACLES_JSON)
            .expect("canonical acceptance oracle must be valid JSON");

    let cases = [
        (
            "unknown_top_level_field",
            {
                let mut value = canonical.clone();
                value
                    .as_object_mut()
                    .expect("acceptance oracle must be an object")
                    .insert("generated_at".to_string(), json!("2026-07-19T00:00:00Z"));
                value
            },
            "unknown field `generated_at`",
        ),
        (
            "unknown_lane_composition_field",
            {
                let mut value = canonical.clone();
                value["lane_composition"]
                    .as_object_mut()
                    .expect("lane_composition must be an object")
                    .insert("skip_missing_dependency".to_string(), json!(true));
                value
            },
            "unknown field `skip_missing_dependency`",
        ),
        (
            "unknown_class_field",
            {
                let mut value = canonical.clone();
                value["oracles"]["block_without_change"]
                    .as_object_mut()
                    .expect("block_without_change oracle must be an object")
                    .insert("retry_behavior".to_string(), json!("retry_once"));
                value
            },
            "unknown field `retry_behavior`",
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        let json = serde_json::to_string(&mutated).expect("mutated oracle must serialize");
        let findings = validate_oracles_json(&json);
        assert!(
            findings
                .iter()
                .any(|finding| finding.contains(expected_finding)),
            "{case_name} must report {expected_finding:?}; actual findings={findings:#?}"
        );
    }
}

/// Each class payload may carry only its own behavior fields. This prevents a
/// class from accidentally accumulating a second, contradictory contract.
#[test]
fn catalog_lifecycle_oracle_rejects_cross_class_fields() {
    let oracles = canonical_acceptance_oracles();

    let cases = [
        (
            "block_carries_soft_delete",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("block_without_change")
                    .expect("block_without_change oracle")
                    .soft_delete =
                    Some("mark_deleted_bump_generation_fence_future_writes".to_string());
                oracles
            },
            "block_without_change oracle must not contain privacy-transition field soft_delete"
                .to_string(),
        ),
        (
            "block_carries_hard_delete",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("block_without_change")
                    .expect("block_without_change oracle")
                    .hard_delete = Some("purge_dependents_then_target".to_string());
                oracles
            },
            "block_without_change oracle must not contain privacy-transition field hard_delete"
                .to_string(),
        ),
        (
            "block_carries_reaper_scrub",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("block_without_change")
                    .expect("block_without_change oracle")
                    .reaper_scrub =
                    Some("reaper_scrubs_catalog_target_after_hard_delete".to_string());
                oracles
            },
            "block_without_change oracle must not contain privacy-transition field reaper_scrub"
                .to_string(),
        ),
        (
            "privacy_carries_leased_behavior",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("privacy_transition")
                    .expect("privacy_transition oracle")
                    .leased_behavior = Some("refuse_without_mutation".to_string());
                oracles
            },
            "privacy_transition oracle must not contain block-only field leased_behavior"
                .to_string(),
        ),
        (
            "privacy_carries_release_trigger",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("privacy_transition")
                    .expect("privacy_transition oracle")
                    .release_trigger = Some("engine_ack".to_string());
                oracles
            },
            "privacy_transition oracle must not contain block-only field release_trigger"
                .to_string(),
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        let findings = validate_oracles(&mutated);
        assert!(
            findings.contains(&expected_finding),
            "{case_name} must report {expected_finding:?}; actual findings={findings:#?}"
        );
    }
}

/// Duplicate raw JSON object keys must fail closed before typed deserialization
/// collapses them last-write-wins. serde_json keeps only the final value for a
/// duplicated map key and rejects duplicated struct fields as an opaque parse
/// error, both of which erase the evidence that the fixture carried conflicting
/// entries; the duplicate-key pre-pass reports each repeated key by name.
#[test]
fn catalog_lifecycle_oracle_rejects_duplicate_json_keys() {
    // Guard-can-pass: the canonical fixture has no duplicate keys, so the
    // duplicate-key pre-pass adds no findings on clean data.
    assert!(
        validate_oracles_json(CATALOG_LIFECYCLE_ACCEPTANCE_ORACLES_JSON).is_empty(),
        "canonical oracle payload must validate cleanly through the duplicate-key pre-pass"
    );

    // Duplicate class entry in the oracles map: serde_json would keep only the
    // second block_without_change object and validate as if the first never
    // existed.
    let duplicate_class = r#"{
        "version": 1,
        "oracle_kind": "catalog_lifecycle_acceptance",
        "lane_composition": {
            "execute_every_inventoried_caller_before_route_activation": true,
            "missing_dependency_disposition": "failure"
        },
        "oracles": {
            "block_without_change": {
                "summary": "first",
                "leased_behavior": "refuse_without_mutation",
                "release_trigger": "engine_ack"
            },
            "block_without_change": {
                "summary": "second",
                "leased_behavior": "mutate_anyway",
                "release_trigger": "immediate"
            },
            "privacy_transition": {
                "summary": "privacy",
                "soft_delete": "mark_deleted_bump_generation_fence_future_writes",
                "hard_delete": "purge_dependents_then_target",
                "reaper_scrub": "reaper_scrubs_catalog_target_after_hard_delete"
            }
        }
    }"#;
    let class_findings = validate_oracles_json(duplicate_class);
    assert!(
        class_findings
            .contains("acceptance oracle payload must not repeat object key block_without_change"),
        "duplicate class entry must fail closed; actual findings={class_findings:#?}"
    );

    // Duplicate behavior field inside a class payload: last-write-wins would keep
    // only the second soft_delete value and hide the conflicting first one.
    let duplicate_field = r#"{
        "version": 1,
        "oracle_kind": "catalog_lifecycle_acceptance",
        "lane_composition": {
            "execute_every_inventoried_caller_before_route_activation": true,
            "missing_dependency_disposition": "failure"
        },
        "oracles": {
            "block_without_change": {
                "summary": "block",
                "leased_behavior": "refuse_without_mutation",
                "release_trigger": "engine_ack"
            },
            "privacy_transition": {
                "summary": "privacy",
                "soft_delete": "mark_deleted_bump_generation_fence_future_writes",
                "soft_delete": "purge_now",
                "hard_delete": "purge_dependents_then_target",
                "reaper_scrub": "reaper_scrubs_catalog_target_after_hard_delete"
            }
        }
    }"#;
    let field_findings = validate_oracles_json(duplicate_field);
    assert!(
        field_findings.contains("acceptance oracle payload must not repeat object key soft_delete"),
        "duplicate behavior field must fail closed; actual findings={field_findings:#?}"
    );
}

/// Join mutations between the inventory and the oracle set must fail closed:
/// an inventory disposition without an oracle, and an oracle class the inventory
/// never uses.
#[test]
fn catalog_lifecycle_oracle_inventory_join_mutations_fail_closed() {
    let inventory = canonical_catalog_lifecycle_inventory();
    let oracles = canonical_acceptance_oracles();

    assert!(
        validate_oracle_inventory_join(&inventory, &oracles).is_empty(),
        "canonical inventory/oracle join must be clean before mutation"
    );

    let block = oracles
        .oracles
        .get("block_without_change")
        .expect("canonical oracle must include block_without_change")
        .clone();

    // An inventory disposition with no oracle: drop block_without_change from the
    // oracle set while the inventory still assigns writers to it.
    let mut missing_oracle = oracles.clone();
    missing_oracle.oracles.remove("block_without_change");
    let missing_findings = validate_oracle_inventory_join(&inventory, &missing_oracle);
    assert!(
        missing_findings
            .contains("inventory disposition block_without_change has no acceptance oracle"),
        "dropping the block_without_change oracle must fail closed; actual findings={missing_findings:#?}"
    );

    // An oracle disposition unused by the inventory: add a class no writer uses.
    let mut extra_class = oracles.clone();
    extra_class.oracles.insert("reactivate".to_string(), block);
    let extra_findings = validate_oracle_inventory_join(&inventory, &extra_class);
    assert!(
        extra_findings.contains("acceptance oracle class reactivate is unused by the inventory"),
        "an oracle class unused by the inventory must fail closed; actual findings={extra_findings:#?}"
    );
}

/// Behavior-expectation mutations must fail closed with the exact finding text:
/// `block_without_change` refuses while leased and releases only after ACK,
/// while `privacy_transition` encodes the soft-delete, hard-delete, and reaper
/// scrub state machine. The lane-composition contract must also fail closed.
#[test]
fn catalog_lifecycle_oracle_behavior_mutations_fail_closed() {
    let oracles = canonical_acceptance_oracles();

    let cases = [
        (
            "block_allows_mutation_while_leased",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("block_without_change")
                    .expect("block_without_change oracle")
                    .leased_behavior = Some("allow_mutation".to_string());
                oracles
            },
            "block_without_change oracle must refuse while leased without mutation: leased_behavior=allow_mutation".to_string(),
        ),
        (
            "block_releases_before_ack",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("block_without_change")
                    .expect("block_without_change oracle")
                    .release_trigger = Some("immediate".to_string());
                oracles
            },
            "block_without_change oracle must release only after engine ACK: release_trigger=immediate".to_string(),
        ),
        (
            "privacy_wrong_soft_delete",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("privacy_transition")
                    .expect("privacy_transition oracle")
                    .soft_delete = Some("purge_immediately".to_string());
                oracles
            },
            "privacy_transition oracle must encode the soft-delete state machine: soft_delete=purge_immediately".to_string(),
        ),
        (
            "privacy_wrong_hard_delete",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("privacy_transition")
                    .expect("privacy_transition oracle")
                    .hard_delete = Some("keep_dependents".to_string());
                oracles
            },
            "privacy_transition oracle must encode the hard-delete state machine: hard_delete=keep_dependents".to_string(),
        ),
        (
            "privacy_wrong_reaper_scrub",
            {
                let mut oracles = oracles.clone();
                oracles
                    .oracles
                    .get_mut("privacy_transition")
                    .expect("privacy_transition oracle")
                    .reaper_scrub = Some("never_scrub".to_string());
                oracles
            },
            "privacy_transition oracle must encode the reaper scrub state machine: reaper_scrub=never_scrub".to_string(),
        ),
        (
            "lane_composition_skips_missing_dependency",
            {
                let mut oracles = oracles.clone();
                oracles.lane_composition.missing_dependency_disposition = "skip".to_string();
                oracles
            },
            "lane composition must treat a missing dependency as failure, not skip".to_string(),
        ),
        (
            "lane_composition_skips_caller_execution",
            {
                let mut oracles = oracles.clone();
                oracles
                    .lane_composition
                    .execute_every_inventoried_caller_before_route_activation = false;
                oracles
            },
            "lane composition must execute every inventoried caller before route activation".to_string(),
        ),
    ];

    for (case_name, mutated, expected_finding) in cases {
        let findings = validate_oracles(&mutated);
        assert!(
            findings.contains(&expected_finding),
            "{case_name} must report {expected_finding:?}; actual findings={findings:#?}"
        );
    }
}

/// The oracle fixture must not duplicate the writer denominator: it carries no
/// writer list and none of the writer-owned fields, so the join can only be
/// satisfied through `scripts/tests/fixtures/catalog_lifecycle_writers.json`.
#[test]
fn catalog_lifecycle_acceptance_oracle_does_not_duplicate_writer_denominator() {
    let value: serde_json::Value = serde_json::from_str(CATALOG_LIFECYCLE_ACCEPTANCE_ORACLES_JSON)
        .expect("acceptance oracle fixture must be valid JSON");
    let object = value
        .as_object()
        .expect("acceptance oracle fixture must be a JSON object");

    let mut keys = BTreeSet::new();
    collect_json_object_keys(
        object
            .get("oracles")
            .expect("acceptance oracle fixture must contain oracles"),
        &mut keys,
    );

    let forbidden = [
        "writer_id",
        "writer_ids",
        "writer_disposition",
        "id",
        "owner_path",
        "source_anchor",
        "disposition",
        "total_writer_count",
    ];
    let copied = forbidden
        .iter()
        .filter(|field| keys.contains(**field))
        .collect::<Vec<_>>();
    assert!(
        copied.is_empty(),
        "acceptance oracle must not copy writer-owned denominator fields: {copied:?}"
    );

    for field in ["writers", "writer", "writer_ids", "total_writer_count"] {
        assert!(
            !object.contains_key(field),
            "acceptance oracle must not carry top-level writer denominator field {field:?}"
        );
    }
}

#[test]
fn soft_delete_privacy_transition_denominator_rejects_missing_duplicate_new_and_unexercised_writers(
) {
    let inventory = inventory_by_key();
    let baseline = lifecycle_exclusion_coverage_registrations(&inventory);
    let missing_registration = baseline[0];
    let missing_id = registration_id(&missing_registration);
    let duplicate_registration = baseline[1];
    let duplicate_id = registration_id(&duplicate_registration);
    let synthetic_registration = CoverageRegistration {
        scenario: "synthetic_new_soft_delete_writer",
        owner_path: "infra/api/src/routes/admin/tenants.rs",
        function_name: "synthetic_soft_delete_privacy_transition",
        source_anchor: "customer_repo.soft_delete",
    };
    let synthetic_id = registration_id(&synthetic_registration);
    let unexercised_registration = CoverageRegistration {
        scenario: "",
        ..baseline[2]
    };
    let unexercised_id = registration_id(&unexercised_registration);
    let stale_scenario_registration = CoverageRegistration {
        scenario: "stale_soft_delete_scenario_name",
        ..baseline[0]
    };
    let stale_scenario_id = registration_id(&stale_scenario_registration);
    let mut swapped_registrations = baseline.clone();
    swapped_registrations[0].scenario = baseline[1].scenario;
    swapped_registrations[1].scenario = baseline[0].scenario;
    let swapped_ids = BTreeSet::from([
        registration_id(&swapped_registrations[0]),
        registration_id(&swapped_registrations[1]),
    ]);
    let mut reused_scenario_registrations = baseline.clone();
    reused_scenario_registrations[0].scenario = duplicate_registration.scenario;
    let reused_scenario_id = registration_id(&reused_scenario_registrations[0]);

    let cases = [
        (
            "missing",
            {
                let mut registrations = baseline.clone();
                registrations.remove(0);
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "duplicate",
            {
                let mut registrations = baseline.clone();
                registrations.push(duplicate_registration);
                registrations
            },
            CoverageValidation {
                duplicates: BTreeSet::from([duplicate_id]),
                duplicate_scenarios: BTreeSet::from([duplicate_registration.scenario]),
                ..CoverageValidation::default()
            },
        ),
        (
            "synthetic",
            {
                let mut registrations = baseline.clone();
                registrations[0] = synthetic_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([registration_id(&baseline[0])]),
                unknown: BTreeSet::from([synthetic_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "unexercised",
            {
                let mut registrations = baseline.clone();
                registrations[2] = unexercised_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([unexercised_id.clone()]),
                empty_scenarios: BTreeSet::from([unexercised_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "stale_scenario",
            {
                let mut registrations = baseline.clone();
                registrations[0] = stale_scenario_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([stale_scenario_id.clone()]),
                stale_scenarios: BTreeSet::from([stale_scenario_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "swapped_scenarios",
            swapped_registrations,
            CoverageValidation {
                missing: swapped_ids.clone(),
                wrong_scenarios: swapped_ids,
                ..CoverageValidation::default()
            },
        ),
        (
            "reused_scenario",
            reused_scenario_registrations,
            CoverageValidation {
                missing: BTreeSet::from([reused_scenario_id.clone()]),
                duplicate_scenarios: BTreeSet::from([duplicate_registration.scenario]),
                wrong_scenarios: BTreeSet::from([reused_scenario_id]),
                ..CoverageValidation::default()
            },
        ),
    ];

    for (case_name, registrations, expected) in cases {
        assert_eq!(
            validate_soft_delete_privacy_transition_exercises(&registrations, &inventory),
            expected,
            "{case_name} soft-delete privacy denominator defect must be classified exactly"
        );
    }
}

#[test]
fn soft_delete_privacy_transition_exercises_match_f5p1_inventory_once() {
    let inventory = inventory_by_key();
    let registrations = lifecycle_exclusion_coverage_registrations(&inventory);
    assert_eq!(
        validate_soft_delete_privacy_transition_exercises(&registrations, &inventory),
        CoverageValidation::default(),
        "F5P1 soft-delete privacy coverage must exercise each canonical inventory writer exactly once"
    );
}

#[test]
fn soft_delete_privacy_transition_denominator_rejects_unregistered_test_scenarios() {
    let inventory = inventory_by_key();
    let registrations = lifecycle_exclusion_coverage_registrations(&inventory);
    let registration = registrations[0];
    let registration_id = registration_id(&registration);
    let scenario_source = F5P1_EXECUTABLE_SCENARIO_SOURCES[0];
    let test_attribute = format!("#[tokio::test]\nasync fn {}", scenario_source.scenario);
    let source_without_test_attribute = scenario_source.test_source.replacen(
        &test_attribute,
        &format!("async fn {}", scenario_source.scenario),
        1,
    );
    assert_ne!(
        source_without_test_attribute, scenario_source.test_source,
        "negative case must remove the canonical scenario test attribute"
    );
    let mut sources_without_test_attribute = F5P1_EXECUTABLE_SCENARIO_SOURCES.to_vec();
    sources_without_test_attribute[0].test_source = &source_without_test_attribute;

    let module_route = format!(
        "#[path = \"integration/{}.rs\"]\nmod {};",
        scenario_source.test_module, scenario_source.test_module
    );
    let harness_without_module_route =
        scenario_source
            .harness_source
            .replacen(&module_route, "", 1);
    assert_ne!(
        harness_without_module_route, scenario_source.harness_source,
        "negative case must remove the canonical scenario module route"
    );
    let mut sources_without_module_route = F5P1_EXECUTABLE_SCENARIO_SOURCES.to_vec();
    sources_without_module_route[0].harness_source = &harness_without_module_route;

    let expected = CoverageValidation {
        missing: BTreeSet::from([registration_id.clone()]),
        stale_scenarios: BTreeSet::from([registration_id]),
        ..CoverageValidation::default()
    };
    for (case_name, sources) in [
        ("missing_test_attribute", sources_without_test_attribute),
        ("missing_module_route", sources_without_module_route),
    ] {
        let executable_scenarios =
            executable_registration_scenarios_from_sources(&sources, &registrations);
        assert_eq!(
            validate_soft_delete_privacy_transition_exercises_with_scenarios(
                &registrations,
                &inventory,
                &registrations,
                &executable_scenarios,
            ),
            expected,
            "{case_name} must make the affected writer unexercised"
        );
    }
}

#[test]
fn privacy_transition_partition_assigns_hard_delete_writers_to_f5p2_and_excludes_reactivate() {
    let inventory = inventory_by_key();
    let privacy_ids = privacy_transition_inventory_ids(&inventory);
    let f5p1_ids = f5p1_soft_delete_privacy_inventory_ids(&inventory);
    let f5p2_registrations = privacy_erasure_coverage_registrations(&inventory);
    let f5p2_ids = f5p2_registrations
        .iter()
        .map(registration_id)
        .collect::<BTreeSet<_>>();

    assert_eq!(privacy_ids.len(), 7);
    assert_eq!(f5p1_ids.len(), 3);
    assert_eq!(f5p2_ids.len(), 4);
    assert!(
        f5p1_ids.is_disjoint(&f5p2_ids),
        "F5P1 soft-delete and F5P2 hard-delete privacy partitions must not overlap"
    );
    assert_eq!(
        f5p1_ids.union(&f5p2_ids).cloned().collect::<BTreeSet<_>>(),
        privacy_ids,
        "privacy_transition writers must partition exactly into F5P1 soft-delete and F5P2 hard-delete sets"
    );

    for registration in &f5p2_registrations {
        let key = inventory_key(
            registration.owner_path,
            registration.function_name,
            registration.source_anchor,
        );
        let writer = inventory
            .get(&key)
            .expect("F5P2 hard-delete writer must exist in the canonical inventory");
        assert_eq!(writer.disposition, "privacy_transition");
        assert_eq!(
            fixture_function_name(&writer.id),
            Some(registration.function_name)
        );
        assert_eq!(writer.owner_path, registration.owner_path);
        assert_eq!(writer.source_anchor, registration.source_anchor);
    }

    let reactivate_privacy_writers = inventory
        .values()
        .filter(|writer| {
            writer.owner_path == "infra/api/src/repos/pg_customer_repo/billing.rs"
                && fixture_function_name(&writer.id) == Some("reactivate")
                && writer.disposition == "privacy_transition"
        })
        .collect::<Vec<_>>();
    assert!(
        reactivate_privacy_writers.is_empty(),
        "pg_customer_repo billing::reactivate is suspended-only recovery and must not enter privacy_transition"
    );
}

#[test]
fn hard_delete_privacy_transition_exercises_match_f5p2_inventory_once() {
    let inventory = inventory_by_key();
    let privacy_ids = privacy_transition_inventory_ids(&inventory);
    let f5p1_ids = f5p1_soft_delete_privacy_inventory_ids(&inventory);
    let registrations = privacy_erasure_coverage_registrations(&inventory);
    let expected_f5p2_ids = privacy_ids
        .difference(&f5p1_ids)
        .cloned()
        .collect::<BTreeSet<_>>();
    let registered_f5p2_ids = registrations
        .iter()
        .map(registration_id)
        .collect::<BTreeSet<_>>();
    let missing = expected_f5p2_ids
        .difference(&registered_f5p2_ids)
        .cloned()
        .collect::<BTreeSet<_>>();
    let extra = registered_f5p2_ids
        .difference(&expected_f5p2_ids)
        .cloned()
        .collect::<BTreeSet<_>>();

    assert!(
        missing.is_empty() && extra.is_empty(),
        "F5P2 registrations must match the fixture-derived hard-delete privacy denominator; missing={missing:?}; extra={extra:?}"
    );
    assert!(
        f5p1_ids.is_disjoint(&registered_f5p2_ids),
        "F5P1 and F5P2 privacy-transition writer sets must be disjoint"
    );
    assert_eq!(
        f5p1_ids
            .union(&registered_f5p2_ids)
            .cloned()
            .collect::<BTreeSet<_>>(),
        privacy_ids,
        "F5P1 and F5P2 writer sets must cover the full canonical privacy-transition inventory"
    );
    assert_eq!(
        validate_hard_delete_privacy_transition_exercises(&registrations, &inventory),
        CoverageValidation::default(),
        "F5P2 hard-delete privacy coverage must link every canonical writer to its expected executable scenario"
    );
    assert!(
        inventory.values().all(|writer| {
            !(writer.owner_path == "infra/api/src/repos/pg_customer_repo/billing.rs"
                && fixture_function_name(&writer.id) == Some("reactivate")
                && writer.disposition == "privacy_transition")
        }),
        "billing::reactivate must remain excluded from privacy-transition coverage"
    );
}

#[test]
fn hard_delete_privacy_transition_denominator_rejects_malformed_registrations() {
    let inventory = inventory_by_key();
    let baseline = privacy_erasure_coverage_registrations(&inventory);

    let missing_registration = baseline[0];
    let missing_id = registration_id(&missing_registration);
    let duplicate_registration = baseline[3];
    let duplicate_id = registration_id(&duplicate_registration);
    let synthetic_registration = CoverageRegistration {
        scenario: baseline[0].scenario,
        owner_path: "infra/api/src/routes/admin/tenants.rs",
        function_name: "synthetic_hard_delete_privacy_transition",
        source_anchor: "customer_repo.hard_delete",
    };
    let synthetic_id = registration_id(&synthetic_registration);
    let empty_registration = CoverageRegistration {
        scenario: "",
        ..baseline[0]
    };
    let stale_registration = CoverageRegistration {
        scenario: "stale_hard_delete_scenario_name",
        ..baseline[0]
    };
    let f5p1_registration = lifecycle_exclusion_coverage_registrations(&inventory)[0];
    let f5p1_id = registration_id(&f5p1_registration);
    let wrong_disposition_registration = CoverageRegistration {
        scenario: baseline[0].scenario,
        owner_path: "infra/api/src/repos/pg_index_replica_repo.rs",
        function_name: "delete",
        source_anchor: "pg_index_replica_repo.delete",
    };
    let wrong_disposition_id = registration_id(&wrong_disposition_registration);
    let wrong_owner_registration = CoverageRegistration {
        owner_path: "infra/api/src/repos/pg_customer_repo/lifecycle.rs",
        ..baseline[0]
    };
    let wrong_owner_id = registration_id(&wrong_owner_registration);
    let wrong_source_anchor_registration = CoverageRegistration {
        source_anchor: "pg_index_replica_repo.create",
        ..baseline[0]
    };
    let wrong_source_anchor_id = registration_id(&wrong_source_anchor_registration);

    let cases = [
        (
            "missing_registration",
            {
                let mut registrations = baseline.clone();
                registrations.remove(0);
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                ..CoverageValidation::default()
            },
        ),
        (
            "duplicate_registration",
            {
                let mut registrations = baseline.clone();
                registrations.push(duplicate_registration);
                registrations
            },
            CoverageValidation {
                duplicates: BTreeSet::from([duplicate_id]),
                duplicate_scenarios: BTreeSet::from([duplicate_registration.scenario]),
                ..CoverageValidation::default()
            },
        ),
        (
            "synthetic_unknown_registration",
            {
                let mut registrations = baseline.clone();
                registrations[0] = synthetic_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                unknown: BTreeSet::from([synthetic_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "empty_scenario",
            {
                let mut registrations = baseline.clone();
                registrations[0] = empty_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                empty_scenarios: BTreeSet::from([missing_id.clone()]),
                ..CoverageValidation::default()
            },
        ),
        (
            "stale_non_executable_scenario",
            {
                let mut registrations = baseline.clone();
                registrations[0] = stale_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                stale_scenarios: BTreeSet::from([missing_id.clone()]),
                ..CoverageValidation::default()
            },
        ),
        (
            "f5p1_writer_in_f5p2_set",
            {
                let mut registrations = baseline.clone();
                registrations[0] = f5p1_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                extra: BTreeSet::from([f5p1_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "wrong_disposition",
            {
                let mut registrations = baseline.clone();
                registrations[0] = wrong_disposition_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                wrong_disposition: BTreeSet::from([wrong_disposition_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "wrong_owner",
            {
                let mut registrations = baseline.clone();
                registrations[0] = wrong_owner_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                unknown: BTreeSet::from([wrong_owner_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "wrong_source_anchor",
            {
                let mut registrations = baseline.clone();
                registrations[0] = wrong_source_anchor_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id]),
                unknown: BTreeSet::from([wrong_source_anchor_id]),
                ..CoverageValidation::default()
            },
        ),
    ];

    for (case_name, registrations, expected) in cases {
        assert_eq!(
            validate_hard_delete_privacy_transition_exercises(&registrations, &inventory),
            expected,
            "{case_name} F5P2 registration defect must be classified exactly"
        );
    }
}

#[test]
fn route_owner_coverage_registrations_match_blocking_inventory_ids_once() {
    let inventory = inventory_by_key();
    let expected_ids = route_inventory_ids(&blocking_inventory_by_key());
    let registrations = route_owner_coverage_registrations(&inventory);
    let validation = validate_coverage_registrations(&registrations, &expected_ids, &inventory);
    assert_eq!(
        validation,
        CoverageValidation::default(),
        "route sprint coverage must register each current route/repository block_without_change writer exactly once"
    );
}

#[test]
fn service_owner_coverage_validator_rejects_bad_registrations() {
    let inventory = inventory_by_key();
    let expected_ids = service_inventory_ids(&blocking_inventory_by_key());
    let baseline = service_owner_coverage_registrations(&inventory);

    let missing_registration = baseline[0];
    let missing_id = registration_id(&missing_registration);
    let duplicate_id = registration_id(&baseline[1]);
    let unknown_registration = CoverageRegistration {
        scenario: "unknown_writer_negative_case",
        owner_path: "infra/api/src/services/restore.rs",
        function_name: "unknown_lifecycle_writer",
        source_anchor: "tenant_repo.set_tier",
    };
    let unknown_id = registration_id(&unknown_registration);
    let non_blocking_registration = CoverageRegistration {
        scenario: "non_blocking_writer_negative_case",
        owner_path: "infra/api/src/routes/account.rs",
        function_name: "delete_account",
        source_anchor: "customer_repo.soft_delete",
    };
    let non_blocking_id = registration_id(&non_blocking_registration);
    let extra_registration = CoverageRegistration {
        scenario: "extra_blocking_writer_negative_case",
        owner_path: "infra/api/src/repos/pg_tenant_repo.rs",
        function_name: "create",
        source_anchor: "pg_tenant_repo.create",
    };
    let extra_id = registration_id(&extra_registration);

    let cases = [
        (
            "missing",
            {
                let mut registrations = baseline.clone();
                registrations.remove(0);
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                ..CoverageValidation::default()
            },
        ),
        (
            "duplicate",
            {
                let mut registrations = baseline.clone();
                registrations.push(baseline[1]);
                registrations
            },
            CoverageValidation {
                duplicates: BTreeSet::from([duplicate_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "unknown",
            {
                let mut registrations = baseline.clone();
                registrations[0] = unknown_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                unknown: BTreeSet::from([unknown_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "wrong_disposition",
            {
                let mut registrations = baseline.clone();
                registrations[0] = non_blocking_registration;
                registrations
            },
            CoverageValidation {
                missing: BTreeSet::from([missing_id.clone()]),
                wrong_disposition: BTreeSet::from([non_blocking_id]),
                ..CoverageValidation::default()
            },
        ),
        (
            "extra",
            {
                let mut registrations = baseline.clone();
                registrations.push(extra_registration);
                registrations
            },
            CoverageValidation {
                extra: BTreeSet::from([extra_id]),
                ..CoverageValidation::default()
            },
        ),
    ];

    for (case_name, registrations, expected) in cases {
        assert_eq!(
            validate_coverage_registrations(&registrations, &expected_ids, &inventory),
            expected,
            "{case_name} registration defect must be classified exactly"
        );
    }
}

#[test]
fn service_owner_coverage_registrations_match_blocking_inventory_ids_once() {
    let inventory = inventory_by_key();
    let expected_ids = service_inventory_ids(&blocking_inventory_by_key());
    let registrations = service_owner_coverage_registrations(&inventory);
    let validation = validate_coverage_registrations(&registrations, &expected_ids, &inventory);
    assert_eq!(
        validation,
        CoverageValidation::default(),
        "service sprint coverage must register each current service block_without_change writer exactly once"
    );
}

#[test]
fn coverage_registrations_are_derived_from_live_fixture_metadata() {
    let inventory = inventory_by_key();
    let catalog_registrations = catalog_phase_coverage_registrations(&inventory);
    let lifecycle_registrations = lifecycle_exclusion_coverage_registrations(&inventory);
    let privacy_registrations = privacy_erasure_coverage_registrations(&inventory);

    assert_eq!(
        catalog_registrations.len(),
        41,
        "catalog phase registrations must come from the 41 fixture live-phase rows"
    );
    assert_eq!(
        lifecycle_registrations.len(),
        3,
        "lifecycle phase registrations must come from the 3 fixture live-phase rows"
    );
    assert_eq!(
        privacy_registrations.len(),
        4,
        "privacy-erasure registrations must come from the 4 fixture live-phase rows"
    );
}

fn validate_soft_delete_privacy_transition_exercises(
    registrations: &[CoverageRegistration],
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> CoverageValidation {
    let canonical_registrations = lifecycle_exclusion_coverage_registrations(inventory);
    let executable_scenarios = executable_registration_scenarios_from_sources(
        F5P1_EXECUTABLE_SCENARIO_SOURCES,
        &canonical_registrations,
    );
    validate_soft_delete_privacy_transition_exercises_with_scenarios(
        registrations,
        inventory,
        &canonical_registrations,
        &executable_scenarios,
    )
}

fn validate_soft_delete_privacy_transition_exercises_with_scenarios(
    registrations: &[CoverageRegistration],
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
    canonical_registrations: &[CoverageRegistration],
    executable_scenarios: &BTreeSet<&'static str>,
) -> CoverageValidation {
    let expected_ids = f5p1_soft_delete_privacy_inventory_ids(inventory);
    let expected_scenarios = F5P1_EXECUTABLE_SCENARIO_SOURCES
        .iter()
        .map(|source| {
            let registration = canonical_registrations
                .get(source.coverage_registration_index)
                .expect("F5P1 executable scenario must reference a coverage registration");
            (registration_id(registration), registration.scenario)
        })
        .collect::<BTreeMap<_, _>>();
    validate_coverage_registrations_for_disposition(
        registrations,
        &expected_ids,
        inventory,
        "privacy_transition",
        false,
        Some(executable_scenarios),
        Some(&expected_scenarios),
    )
}

fn validate_hard_delete_privacy_transition_exercises(
    registrations: &[CoverageRegistration],
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> CoverageValidation {
    let expected_ids = privacy_transition_inventory_ids(inventory)
        .difference(&f5p1_soft_delete_privacy_inventory_ids(inventory))
        .cloned()
        .collect::<BTreeSet<_>>();
    let canonical_registrations = privacy_erasure_coverage_registrations(inventory);
    let executable_scenarios = executable_registration_scenarios_from_sources(
        F5P2_EXECUTABLE_SCENARIO_SOURCES,
        &canonical_registrations,
    );
    let expected_scenarios = F5P2_EXECUTABLE_SCENARIO_SOURCES
        .iter()
        .map(|source| {
            let registration = canonical_registrations
                .get(source.coverage_registration_index)
                .expect("F5P2 executable scenario must reference a coverage registration");
            (registration_id(registration), registration.scenario)
        })
        .collect::<BTreeMap<_, _>>();

    validate_coverage_registrations_for_disposition(
        registrations,
        &expected_ids,
        inventory,
        "privacy_transition",
        false,
        Some(&executable_scenarios),
        Some(&expected_scenarios),
    )
}

fn executable_registration_scenarios_from_sources(
    scenario_sources: &[ExecutableScenarioSource<'_>],
    registrations: &[CoverageRegistration],
) -> BTreeSet<&'static str> {
    scenario_sources
        .iter()
        .filter(|source| {
            source_has_test_attribute(source.test_source, source.scenario)
                && harness_routes_test_module(source.harness_source, source.test_module)
        })
        .map(|source| {
            registrations
                .get(source.coverage_registration_index)
                .expect("executable scenario must reference a coverage registration")
                .scenario
        })
        .collect()
}

fn source_has_test_attribute(source: &str, scenario: &str) -> bool {
    let signatures = [format!("async fn {scenario}("), format!("fn {scenario}(")];
    signatures.iter().any(|signature| {
        let Some(signature_start) = source.find(signature) else {
            return false;
        };
        source[..signature_start]
            .lines()
            .rev()
            .skip_while(|line| line.trim().is_empty())
            .take_while(|line| line.trim().starts_with("#["))
            .any(|line| matches!(line.trim(), "#[test]" | "#[tokio::test]"))
    })
}

fn harness_routes_test_module(harness_source: &str, test_module: &str) -> bool {
    let route = format!("#[path = \"integration/{test_module}.rs\"]\nmod {test_module};");
    harness_source.replace("\r\n", "\n").contains(&route)
}

fn privacy_transition_inventory_ids(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> BTreeSet<String> {
    inventory
        .values()
        .filter(|writer| writer.disposition == "privacy_transition")
        .map(|writer| writer.id.clone())
        .collect()
}

fn f5p1_soft_delete_privacy_inventory_ids(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> BTreeSet<String> {
    inventory
        .values()
        .filter(|writer| {
            writer.disposition == "privacy_transition"
                && matches!(
                    writer.source_anchor.as_str(),
                    "pg_customer_repo.soft_delete" | "customer_repo.soft_delete"
                )
        })
        .map(|writer| writer.id.clone())
        .collect()
}

fn validate_coverage_registrations(
    registrations: &[CoverageRegistration],
    expected_ids: &BTreeSet<String>,
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> CoverageValidation {
    validate_coverage_registrations_for_disposition(
        registrations,
        expected_ids,
        inventory,
        "block_without_change",
        true,
        None,
        None,
    )
}

fn validate_coverage_registrations_for_disposition(
    registrations: &[CoverageRegistration],
    expected_ids: &BTreeSet<String>,
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
    expected_disposition: &str,
    count_empty_scenario_as_seen: bool,
    executable_scenarios: Option<&BTreeSet<&'static str>>,
    expected_scenarios: Option<&BTreeMap<String, &'static str>>,
) -> CoverageValidation {
    let mut validation = CoverageValidation::default();
    let mut seen_ids = BTreeSet::<String>::new();
    let mut seen_scenario_counts = BTreeMap::<&'static str, usize>::new();
    let expected_scenario_counts = expected_scenarios
        .map(|scenarios| {
            let mut counts = BTreeMap::<&'static str, usize>::new();
            for scenario in scenarios.values() {
                *counts.entry(*scenario).or_default() += 1;
            }
            counts
        })
        .unwrap_or_default();

    for registration in registrations {
        let id = registration_id(registration);
        let key = inventory_key(
            registration.owner_path,
            registration.function_name,
            registration.source_anchor,
        );
        let is_expected_registration = inventory
            .get(&key)
            .is_some_and(|writer| writer.disposition == expected_disposition)
            && expected_ids.contains(&id);
        let has_scenario = !registration.scenario.trim().is_empty();
        if !has_scenario {
            validation.empty_scenarios.insert(id.clone());
        }
        if expected_scenarios.is_some() && has_scenario {
            let seen_count = seen_scenario_counts
                .entry(registration.scenario)
                .or_default();
            *seen_count += 1;
            let allowed_count = expected_scenario_counts
                .get(registration.scenario)
                .copied()
                .unwrap_or(1);
            if *seen_count > allowed_count {
                validation.duplicate_scenarios.insert(registration.scenario);
            }
        }
        let has_executable_scenario = match executable_scenarios {
            Some(scenarios)
                if is_expected_registration
                    && has_scenario
                    && !scenarios.contains(registration.scenario) =>
            {
                validation.stale_scenarios.insert(id.clone());
                false
            }
            Some(_) => has_scenario,
            None => has_scenario,
        };
        let has_expected_scenario = match expected_scenarios {
            Some(scenarios)
                if is_expected_registration
                    && has_executable_scenario
                    && scenarios.get(&id).copied() != Some(registration.scenario) =>
            {
                validation.wrong_scenarios.insert(id.clone());
                false
            }
            Some(_) => has_executable_scenario,
            None => has_executable_scenario,
        };
        if (has_expected_scenario || count_empty_scenario_as_seen) && !seen_ids.insert(id.clone()) {
            validation.duplicates.insert(id.clone());
        }

        match inventory.get(&key) {
            Some(writer) if writer.disposition != expected_disposition => {
                validation.wrong_disposition.insert(id);
            }
            Some(_) if !expected_ids.contains(&id) => {
                validation.extra.insert(id);
            }
            Some(_) => {}
            None => {
                validation.unknown.insert(id);
            }
        }
    }

    validation.missing = expected_ids.difference(&seen_ids).cloned().collect();
    validation
}

fn route_inventory_ids(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> BTreeSet<String> {
    inventory
        .values()
        .filter(|writer| route_sprint_scope_contains(writer))
        .map(|writer| writer.id.clone())
        .collect::<BTreeSet<_>>()
}

fn service_inventory_ids(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> BTreeSet<String> {
    inventory
        .values()
        .filter(|writer| writer.owner_path.starts_with("infra/api/src/services/"))
        .map(|writer| writer.id.clone())
        .collect()
}

fn route_owner_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> Vec<CoverageRegistration> {
    inventory
        .values()
        .filter(|writer| writer.live_phase == "catalog" && route_sprint_scope_contains(writer))
        .map(coverage_registration_from_writer)
        .collect()
}

fn service_owner_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> Vec<CoverageRegistration> {
    inventory
        .values()
        .filter(|writer| {
            writer.live_phase == "catalog"
                && writer.owner_path.starts_with("infra/api/src/services/")
        })
        .map(coverage_registration_from_writer)
        .collect()
}

fn catalog_phase_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> Vec<CoverageRegistration> {
    live_phase_coverage_registrations(inventory, "catalog")
}

fn lifecycle_exclusion_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> Vec<CoverageRegistration> {
    live_phase_coverage_registrations(inventory, "lifecycle_exclusion")
}

fn privacy_erasure_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
) -> Vec<CoverageRegistration> {
    live_phase_coverage_registrations(inventory, "privacy_erasure")
}

fn live_phase_coverage_registrations(
    inventory: &BTreeMap<(String, String), CatalogLifecycleWriter>,
    live_phase: &str,
) -> Vec<CoverageRegistration> {
    inventory
        .values()
        .filter(|writer| writer.live_phase == live_phase)
        .map(coverage_registration_from_writer)
        .collect()
}

fn coverage_registration_from_writer(writer: &CatalogLifecycleWriter) -> CoverageRegistration {
    let function_name = fixture_function_name(&writer.id)
        .expect("fixture ID must include function slug for coverage registration");
    CoverageRegistration {
        scenario: leak_test_str(&writer.live_scenario_key),
        owner_path: leak_test_str(&writer.owner_path),
        function_name: leak_test_str(function_name),
        source_anchor: leak_test_str(&writer.source_anchor),
    }
}

fn leak_test_str(value: &str) -> &'static str {
    Box::leak(value.to_string().into_boxed_str())
}

fn registration_id(registration: &CoverageRegistration) -> String {
    writer_id(
        registration.owner_path,
        registration.function_name,
        registration.source_anchor,
    )
}

fn route_sprint_scope_contains(writer: &CatalogLifecycleWriter) -> bool {
    let Some(function_name) = fixture_function_name(&writer.id) else {
        return false;
    };
    ROUTE_SPRINT_SCOPES.iter().any(|(owner_path, scoped_fn)| {
        writer.owner_path == *owner_path && function_name == *scoped_fn
    })
}

fn blocking_inventory_by_key() -> BTreeMap<(String, String), CatalogLifecycleWriter> {
    inventory_by_key()
        .into_iter()
        .filter(|(_, writer)| writer.disposition == "block_without_change")
        .collect()
}

fn inventory_by_key() -> BTreeMap<(String, String), CatalogLifecycleWriter> {
    let inventory: CatalogLifecycleInventory = serde_json::from_str(CATALOG_LIFECYCLE_WRITERS_JSON)
        .expect("catalog lifecycle writer inventory must be valid JSON");
    inventory
        .writers
        .into_iter()
        .map(|writer| {
            let function_name = fixture_function_name(&writer.id)
                .expect("fixture ID must include function slug")
                .to_string();
            (
                inventory_key(&writer.owner_path, &function_name, &writer.source_anchor),
                writer,
            )
        })
        .collect()
}

fn inventory_key(owner_path: &str, function_name: &str, source_anchor: &str) -> (String, String) {
    (
        owner_path.to_string(),
        writer_id(owner_path, function_name, source_anchor),
    )
}

fn fixture_function_name(id: &str) -> Option<&str> {
    id.split("__").nth(2)
}

struct FixtureShape {
    ids: BTreeSet<String>,
    findings: BTreeSet<String>,
}

fn validate_fixture(inventory: &CatalogLifecycleInventory) -> FixtureShape {
    let mut ids = BTreeSet::new();
    let mut dispositions = BTreeMap::new();
    let mut findings = BTreeSet::new();
    if inventory.writers.is_empty() {
        findings.insert("writers must not be empty".to_string());
    }
    if inventory.total_writer_count == 0 {
        findings.insert("total_writer_count must be greater than zero".to_string());
    }
    if inventory.total_writer_count != inventory.writers.len() {
        findings.insert(format!(
            "total_writer_count must match the number of fixture writers: declared={} actual={}",
            inventory.total_writer_count,
            inventory.writers.len()
        ));
    }
    for writer in &inventory.writers {
        if !ids.insert(writer.id.clone()) {
            findings.insert(format!(
                "duplicate catalog lifecycle writer ID: {}",
                writer.id
            ));
        }
        let disposition = match writer.disposition.as_str() {
            "" => {
                findings.insert(format!("disposition is required for {}", writer.id));
                None
            }
            "block_without_change" => Some("block_without_change"),
            "privacy_transition" => Some("privacy_transition"),
            other => {
                findings.insert(format!(
                    "unknown catalog lifecycle writer disposition for {}: {other}",
                    writer.id
                ));
                None
            }
        };
        if let Some(disposition) = disposition {
            *dispositions.entry(disposition).or_insert(0) += 1;
        }
        if writer.owner_path.trim().is_empty() {
            findings.insert(format!("owner_path is required for {}", writer.id));
        }
        if writer.source_anchor.trim().is_empty() {
            findings.insert(format!("source_anchor is required for {}", writer.id));
        }
        if writer.live_caller_key.trim().is_empty() {
            findings.insert(format!("live_caller_key is required for {}", writer.id));
        }
        if !matches!(
            writer.live_caller_command.as_str(),
            "invoke_catalog_blocking_writer"
                | "invoke_lifecycle_soft_delete_writer"
                | "invoke_privacy_erasure_dependency_gate"
        ) {
            findings.insert(format!("live_caller_command is required for {}", writer.id));
        }
        if writer.live_scenario_key.trim().is_empty() {
            findings.insert(format!("live_scenario_key is required for {}", writer.id));
        }
        if !matches!(
            writer.live_phase.as_str(),
            "catalog" | "lifecycle_exclusion" | "privacy_erasure"
        ) {
            findings.insert(format!(
                "unknown live_phase for {}: {}",
                writer.id, writer.live_phase
            ));
        }
        if let Some(function_name) = fixture_function_name(&writer.id) {
            let expected_id = writer_id(&writer.owner_path, function_name, &writer.source_anchor);
            if expected_id != writer.id {
                findings.insert(format!(
                    "writer ID metadata does not match row fields for {}: expected_id={expected_id}",
                    writer.id
                ));
            }
        } else {
            findings.insert(format!(
                "writer ID must include an owner path, function name, and source anchor: {}",
                writer.id
            ));
        }
    }
    for required_disposition in ["block_without_change", "privacy_transition"] {
        if !dispositions.contains_key(required_disposition) {
            findings.insert(format!(
                "inventory must include {required_disposition} writers"
            ));
        }
    }
    let disposition_sum = dispositions.values().sum::<usize>();
    if disposition_sum != inventory.total_writer_count {
        findings.insert(format!(
            "disposition class counts must sum to total_writer_count: disposition_sum={disposition_sum} total={}",
            inventory.total_writer_count
        ));
    }
    FixtureShape { ids, findings }
}

fn validate_catalog_lifecycle_inventory(
    inventory: &CatalogLifecycleInventory,
    observed: &BTreeSet<WriterObservation>,
) -> BTreeSet<String> {
    let fixture = validate_fixture(inventory);
    let mut findings = fixture.findings;
    let observed_ids = observed
        .iter()
        .map(|writer| writer.id.clone())
        .collect::<BTreeSet<_>>();
    for missing in observed_ids.difference(&fixture.ids) {
        findings.insert(format!("missing source-discovered writer: {missing}"));
    }
    for extra in fixture.ids.difference(&observed_ids) {
        findings.insert(format!(
            "fixture-only writer absent from source discovery: {extra}"
        ));
    }

    let observed_by_id = observed
        .iter()
        .map(|writer| (writer.id.clone(), writer))
        .collect::<BTreeMap<_, _>>();
    for writer in &inventory.writers {
        let Some(observed) = observed_by_id.get(&writer.id) else {
            continue;
        };
        if observed.owner_path != writer.owner_path {
            findings.insert(format!(
                "owner_path mismatch for {}: fixture={} observed={}",
                writer.id, writer.owner_path, observed.owner_path
            ));
        }
        if observed.source_anchor != writer.source_anchor {
            findings.insert(format!(
                "source_anchor mismatch for {}: fixture={} observed={}",
                writer.id, writer.source_anchor, observed.source_anchor
            ));
        }
        if matches!(
            writer.disposition.as_str(),
            "block_without_change" | "privacy_transition"
        ) && observed.disposition != writer.disposition
        {
            findings.insert(format!(
                "disposition mismatch for {}: fixture={} observed={}",
                writer.id, writer.disposition, observed.disposition
            ));
        }
    }

    findings
}

fn assert_catalog_lifecycle_inventory_valid(
    inventory: &CatalogLifecycleInventory,
    observed: &BTreeSet<WriterObservation>,
) {
    let findings = validate_catalog_lifecycle_inventory(inventory, observed);
    assert!(
        findings.is_empty(),
        "catalog lifecycle writer inventory must match source discovery: {findings:#?}"
    );
}

fn assert_inventory_finding(
    case_name: &str,
    inventory: &CatalogLifecycleInventory,
    observed: &BTreeSet<WriterObservation>,
    expected_finding: &str,
) {
    let findings = validate_catalog_lifecycle_inventory(inventory, observed);
    assert!(
        findings.contains(expected_finding),
        "{case_name} must report {expected_finding:?}; actual findings={findings:#?}"
    );
}

fn canonical_catalog_lifecycle_inventory() -> CatalogLifecycleInventory {
    serde_json::from_str(CATALOG_LIFECYCLE_WRITERS_JSON)
        .expect("catalog lifecycle writer inventory must be valid JSON")
}

fn canonical_acceptance_oracles() -> AcceptanceOracles {
    serde_json::from_str(CATALOG_LIFECYCLE_ACCEPTANCE_ORACLES_JSON)
        .expect("catalog lifecycle acceptance oracles must be valid JSON")
}

/// Parse and validate the raw oracle payload, capturing a parse failure as a
/// finding rather than panicking so a missing/empty payload fails closed.
///
/// The duplicate-key pre-pass runs independently of the typed parse because
/// `serde_json::from_str::<AcceptanceOracles>` resolves duplicate object keys
/// last-write-wins (for the `oracles` map) or as a bare parse error (for struct
/// fields), both of which lose the evidence that the fixture carried conflicting
/// duplicate entries. Its findings are merged into either parse branch so a
/// duplicated class entry or duplicated behavior field always fails closed.
fn validate_oracles_json(json: &str) -> BTreeSet<String> {
    let mut duplicate_findings = detect_duplicate_json_keys(json);
    match serde_json::from_str::<AcceptanceOracles>(json) {
        Ok(oracles) => {
            let mut findings = validate_oracles(&oracles);
            findings.append(&mut duplicate_findings);
            findings
        }
        Err(error) => {
            let mut findings = BTreeSet::new();
            findings.insert(format!(
                "acceptance oracle payload must be valid JSON: {error}"
            ));
            findings.append(&mut duplicate_findings);
            findings
        }
    }
}

/// A structural JSON parse that preserves every object entry in declaration
/// order, including duplicate keys. serde_json's default map handling is
/// last-write-wins, so deserializing into `Value`/`BTreeMap` would collapse
/// duplicate keys before they can be detected; streaming each entry into a `Vec`
/// keeps them so a duplicate-key pre-pass can reject the fixture.
enum RawJsonNode {
    Object(Vec<(String, RawJsonNode)>),
    Array(Vec<RawJsonNode>),
    Scalar,
}

impl<'de> Deserialize<'de> for RawJsonNode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct RawJsonVisitor;

        impl<'de> serde::de::Visitor<'de> for RawJsonVisitor {
            type Value = RawJsonNode;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("any JSON value")
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::MapAccess<'de>,
            {
                let mut entries = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, RawJsonNode>()? {
                    entries.push((key, value));
                }
                Ok(RawJsonNode::Object(entries))
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::SeqAccess<'de>,
            {
                let mut items = Vec::new();
                while let Some(item) = seq.next_element::<RawJsonNode>()? {
                    items.push(item);
                }
                Ok(RawJsonNode::Array(items))
            }

            fn visit_bool<E>(self, _value: bool) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_i64<E>(self, _value: i64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_u64<E>(self, _value: u64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_f64<E>(self, _value: f64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_str<E>(self, _value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_none<E>(self) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_unit<E>(self) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(RawJsonNode::Scalar)
            }

            fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
            where
                D: serde::Deserializer<'de>,
            {
                deserializer.deserialize_any(self)
            }
        }

        deserializer.deserialize_any(RawJsonVisitor)
    }
}

/// Walk a preserved-duplicate JSON tree and record every object key that appears
/// more than once within the same object, anywhere in the tree.
fn collect_duplicate_json_keys(node: &RawJsonNode, duplicates: &mut BTreeSet<String>) {
    match node {
        RawJsonNode::Object(entries) => {
            let mut seen = BTreeSet::new();
            for (key, value) in entries {
                if !seen.insert(key.clone()) {
                    duplicates.insert(key.clone());
                }
                collect_duplicate_json_keys(value, duplicates);
            }
        }
        RawJsonNode::Array(items) => {
            for item in items {
                collect_duplicate_json_keys(item, duplicates);
            }
        }
        RawJsonNode::Scalar => {}
    }
}

/// Detect duplicate raw JSON object keys before typed deserialization collapses
/// them. Returns one finding per duplicated key. A structural parse failure is
/// left to `validate_oracles_json`'s typed parse, which reports it.
fn detect_duplicate_json_keys(json: &str) -> BTreeSet<String> {
    let mut findings = BTreeSet::new();
    if let Ok(node) = serde_json::from_str::<RawJsonNode>(json) {
        let mut duplicates = BTreeSet::new();
        collect_duplicate_json_keys(&node, &mut duplicates);
        for key in duplicates {
            findings.insert(format!(
                "acceptance oracle payload must not repeat object key {key}"
            ));
        }
    }
    findings
}

/// Validate the oracle set in isolation: class-key completeness, unknown
/// classes, the lane-composition contract, and each class's behavior
/// expectation. Returns the set of findings (empty when valid).
fn validate_oracles(oracles: &AcceptanceOracles) -> BTreeSet<String> {
    let mut findings = BTreeSet::new();
    if oracles.version != 1 {
        findings.insert(format!(
            "acceptance oracle version must be 1, got {}",
            oracles.version
        ));
    }
    if oracles.oracle_kind != "catalog_lifecycle_acceptance" {
        findings.insert(format!(
            "acceptance oracle kind must be catalog_lifecycle_acceptance, got {}",
            oracles.oracle_kind
        ));
    }
    if oracles.oracles.is_empty() {
        findings.insert("acceptance oracle map must not be empty".to_string());
    }
    for required in ["block_without_change", "privacy_transition"] {
        if !oracles.oracles.contains_key(required) {
            findings.insert(format!(
                "acceptance oracle map must include the {required} class"
            ));
        }
    }
    for class in oracles.oracles.keys() {
        if class != "block_without_change" && class != "privacy_transition" {
            findings.insert(format!("unknown acceptance oracle class: {class}"));
        }
    }
    if !oracles
        .lane_composition
        .execute_every_inventoried_caller_before_route_activation
    {
        findings.insert(
            "lane composition must execute every inventoried caller before route activation"
                .to_string(),
        );
    }
    if oracles.lane_composition.missing_dependency_disposition != "failure" {
        findings.insert(format!(
            "lane composition must treat a missing dependency as failure, not {}",
            oracles.lane_composition.missing_dependency_disposition
        ));
    }
    for (class, oracle) in &oracles.oracles {
        findings.append(&mut validate_class_behavior(class, oracle));
    }
    findings
}

/// Assert the exact hand-calculated behavior expectation for a lifecycle class.
fn validate_class_behavior(class: &str, oracle: &ClassOracle) -> BTreeSet<String> {
    let mut findings = BTreeSet::new();
    match class {
        "block_without_change" => {
            for (field, value) in [
                ("soft_delete", oracle.soft_delete.as_ref()),
                ("hard_delete", oracle.hard_delete.as_ref()),
                ("reaper_scrub", oracle.reaper_scrub.as_ref()),
            ] {
                if value.is_some() {
                    findings.insert(format!(
                        "block_without_change oracle must not contain privacy-transition field {field}"
                    ));
                }
            }
            if oracle.leased_behavior.as_deref() != Some("refuse_without_mutation") {
                findings.insert(format!(
                    "block_without_change oracle must refuse while leased without mutation: leased_behavior={}",
                    oracle.leased_behavior.as_deref().unwrap_or("<missing>")
                ));
            }
            if oracle.release_trigger.as_deref() != Some("engine_ack") {
                findings.insert(format!(
                    "block_without_change oracle must release only after engine ACK: release_trigger={}",
                    oracle.release_trigger.as_deref().unwrap_or("<missing>")
                ));
            }
        }
        "privacy_transition" => {
            for (field, value) in [
                ("leased_behavior", oracle.leased_behavior.as_ref()),
                ("release_trigger", oracle.release_trigger.as_ref()),
            ] {
                if value.is_some() {
                    findings.insert(format!(
                        "privacy_transition oracle must not contain block-only field {field}"
                    ));
                }
            }
            if oracle.soft_delete.as_deref()
                != Some("mark_deleted_bump_generation_fence_future_writes")
            {
                findings.insert(format!(
                    "privacy_transition oracle must encode the soft-delete state machine: soft_delete={}",
                    oracle.soft_delete.as_deref().unwrap_or("<missing>")
                ));
            }
            if oracle.hard_delete.as_deref() != Some("purge_dependents_then_target") {
                findings.insert(format!(
                    "privacy_transition oracle must encode the hard-delete state machine: hard_delete={}",
                    oracle.hard_delete.as_deref().unwrap_or("<missing>")
                ));
            }
            if oracle.reaper_scrub.as_deref()
                != Some("reaper_scrubs_catalog_target_after_hard_delete")
            {
                findings.insert(format!(
                    "privacy_transition oracle must encode the reaper scrub state machine: reaper_scrub={}",
                    oracle.reaper_scrub.as_deref().unwrap_or("<missing>")
                ));
            }
        }
        _ => {}
    }
    findings
}

/// Join the writer denominator to the oracle set through each writer's
/// inventory-owned `disposition`. Fails closed when an inventory disposition has
/// no oracle or when the oracle carries a class the inventory never uses, so the
/// join always depends on the writer fixture as the sole denominator.
fn validate_oracle_inventory_join(
    inventory: &CatalogLifecycleInventory,
    oracles: &AcceptanceOracles,
) -> BTreeSet<String> {
    let mut findings = BTreeSet::new();
    let inventory_dispositions = inventory
        .writers
        .iter()
        .map(|writer| writer.disposition.clone())
        .collect::<BTreeSet<_>>();

    for writer in &inventory.writers {
        let resolved = oracles
            .oracles
            .keys()
            .filter(|class| **class == writer.disposition)
            .count();
        if resolved != 1 {
            findings.insert(format!(
                "inventory writer {} disposition {} must resolve to exactly one acceptance oracle, found {resolved}",
                writer.id, writer.disposition
            ));
        }
    }
    for disposition in &inventory_dispositions {
        if !oracles.oracles.contains_key(disposition) {
            findings.insert(format!(
                "inventory disposition {disposition} has no acceptance oracle"
            ));
        }
    }
    for class in oracles.oracles.keys() {
        if !inventory_dispositions.contains(class) {
            findings.insert(format!(
                "acceptance oracle class {class} is unused by the inventory"
            ));
        }
    }
    findings
}

/// Recursively collect every object key in a JSON value, used to prove the
/// oracle fixture does not copy any writer-owned field.
fn collect_json_object_keys(value: &serde_json::Value, keys: &mut BTreeSet<String>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, child) in map {
                keys.insert(key.clone());
                collect_json_object_keys(child, keys);
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                collect_json_object_keys(item, keys);
            }
        }
        _ => {}
    }
}

fn writer_id_for_disposition(inventory: &CatalogLifecycleInventory, disposition: &str) -> String {
    inventory
        .writers
        .iter()
        .find(|writer| writer.disposition == disposition)
        .unwrap_or_else(|| panic!("canonical inventory must include {disposition} writer"))
        .id
        .clone()
}

fn writer<'a>(inventory: &'a CatalogLifecycleInventory, id: &str) -> &'a CatalogLifecycleWriter {
    inventory
        .writers
        .iter()
        .find(|writer| writer.id == id)
        .unwrap_or_else(|| panic!("canonical inventory must include writer {id}"))
}

fn writer_mut<'a>(
    inventory: &'a mut CatalogLifecycleInventory,
    id: &str,
) -> &'a mut CatalogLifecycleWriter {
    inventory
        .writers
        .iter_mut()
        .find(|writer| writer.id == id)
        .unwrap_or_else(|| panic!("canonical inventory must include writer {id}"))
}

fn discover_catalog_lifecycle_writers() -> BTreeSet<WriterObservation> {
    let repo_root = repo_root();
    scoped_source_files(&repo_root)
        .into_iter()
        .flat_map(|path| observe_file(&repo_root, &path))
        .collect()
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("infra/api must have an infra parent and repo root")
        .to_path_buf()
}

fn scoped_source_files(repo_root: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    collect_rs_files(repo_root, "infra/api/src/routes/indexes", &mut paths);
    collect_rs_files(repo_root, "infra/api/src/services/migration", &mut paths);
    collect_rs_files(repo_root, "infra/api/src/services/cold_tier", &mut paths);
    for path in [
        "infra/api/src/routes/account.rs",
        "infra/api/src/routes/admin/indexes.rs",
        "infra/api/src/routes/admin/migrations.rs",
        "infra/api/src/routes/admin/tenants.rs",
        "infra/api/src/services/restore.rs",
        "infra/api/src/services/replica.rs",
        "infra/api/src/services/region_failover.rs",
        "infra/api/src/repos/pg_customer_repo/hard_delete.rs",
        "infra/api/src/repos/pg_customer_repo/lifecycle.rs",
        "infra/api/src/repos/pg_tenant_repo.rs",
        "infra/api/src/repos/pg_index_replica_repo.rs",
    ] {
        paths.push(repo_root.join(path));
    }
    paths.sort();
    paths.dedup();
    paths
}

fn collect_rs_files(repo_root: &Path, relative_dir: &str, paths: &mut Vec<PathBuf>) {
    let dir = repo_root.join(relative_dir);
    for entry in fs::read_dir(&dir).unwrap_or_else(|error| {
        panic!("failed to read source directory {}: {error}", dir.display())
    }) {
        let path = entry.expect("directory entry must be readable").path();
        if path.is_dir() {
            let relative_child = path.strip_prefix(repo_root).expect("path under repo root");
            collect_rs_files(repo_root, &relative_child.to_string_lossy(), paths);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            paths.push(path);
        }
    }
}

fn observe_file(repo_root: &Path, path: &Path) -> BTreeSet<WriterObservation> {
    let source = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read source file {}: {error}", path.display()));
    let owner_path = path
        .strip_prefix(repo_root)
        .expect("source file under repo root")
        .to_string_lossy()
        .replace('\\', "/");
    let mut observations = BTreeSet::new();
    let mut current_fn = String::from("module");
    let mut pending_receiver = None;

    for line in source.lines() {
        if let Some(name) = function_name(line) {
            current_fn = name.to_string();
        }
        for source_anchor in source_anchors(line, pending_receiver) {
            observations.insert(WriterObservation {
                id: writer_id(&owner_path, &current_fn, source_anchor),
                owner_path: owner_path.clone(),
                source_anchor: source_anchor.to_string(),
                disposition: discovered_writer_disposition(&owner_path, source_anchor),
            });
        }
        pending_receiver = next_pending_receiver(line, pending_receiver);
    }

    observations
}

fn discovered_writer_disposition(owner_path: &str, source_anchor: &str) -> &'static str {
    if owner_path == "infra/api/src/repos/pg_customer_repo/hard_delete.rs"
        || matches!(
            source_anchor,
            "pg_customer_repo.soft_delete"
                | "pg_customer_repo.hard_delete"
                | "customer_repo.soft_delete"
                | "customer_repo.hard_delete"
        )
    {
        "privacy_transition"
    } else {
        "block_without_change"
    }
}

fn function_name(line: &str) -> Option<&str> {
    let after_fn = line.split_once("fn ")?.1;
    let name = after_fn
        .split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '_'))
        .next()
        .unwrap_or_default();
    (!name.is_empty()).then_some(name)
}

fn source_anchors(line: &str, pending_receiver: Option<&'static str>) -> Vec<&'static str> {
    if line.contains("UPDATE customer_tenants SET vm_id = NULL") {
        return vec!["pg_tenant_repo.clear_vm_id"];
    }
    let mut anchors = Vec::new();
    if let Some(anchor) = receiver_source_anchor(line, pending_receiver) {
        anchors.push(anchor);
    }
    anchors.extend(
        [
            (".set_vm_id(", "tenant_repo.set_vm_id"),
            (".set_tier(", "tenant_repo.set_tier"),
            (
                ".create_lifecycle_intent(",
                "tenant_repo.create_lifecycle_intent",
            ),
            (
                ".publish_lifecycle_placement(",
                "tenant_repo.publish_lifecycle_placement",
            ),
            (".clear_vm_id(", "tenant_repo.clear_vm_id"),
            (".set_cold_snapshot_id(", "tenant_repo.set_cold_snapshot_id"),
            (".tenant_repo.delete(", "tenant_repo.delete"),
            (".customer_repo.soft_delete(", "customer_repo.soft_delete"),
            (".customer_repo.hard_delete(", "customer_repo.hard_delete"),
            (".hard_delete(", "customer_repo.hard_delete"),
            (".create_replica(", "replica_service.create_replica"),
            (".remove_replica(", "replica_service.remove_replica"),
            (".replica_repo.create(", "replica_repo.create"),
            (".replica_repo.delete(", "replica_repo.delete"),
            (
                ".delete_index_with_auth_observation(",
                "flapjack_proxy.delete_index",
            ),
            (
                "UPDATE customer_tenants SET vm_id",
                "pg_tenant_repo.set_vm_id",
            ),
            (
                "UPDATE customer_tenants SET tier",
                "pg_tenant_repo.set_tier",
            ),
            (
                "UPDATE customer_tenants SET cold_snapshot_id",
                "pg_tenant_repo.set_cold_snapshot_id",
            ),
            ("INSERT INTO customer_tenants", "pg_tenant_repo.create"),
            ("DELETE FROM customer_tenants", "pg_tenant_repo.delete"),
            ("INSERT INTO index_replicas", "pg_index_replica_repo.create"),
            ("DELETE FROM index_replicas", "pg_index_replica_repo.delete"),
            (
                "UPDATE customers SET status = 'deleted'",
                "pg_customer_repo.soft_delete",
            ),
            ("DELETE FROM customers", "pg_customer_repo.hard_delete"),
        ]
        .into_iter()
        .filter_map(|(needle, anchor)| line.contains(needle).then_some(anchor)),
    );
    anchors
}

fn receiver_source_anchor(
    line: &str,
    pending_receiver: Option<&'static str>,
) -> Option<&'static str> {
    match pending_receiver {
        Some("tenant_repo") if line.contains(".create(") => Some("tenant_repo.create"),
        Some("tenant_repo") if line.contains(".delete(") => Some("tenant_repo.delete"),
        Some("replica_repo") if line.contains(".create(") => Some("replica_repo.create"),
        Some("replica_repo") if line.contains(".delete(") => Some("replica_repo.delete"),
        _ => None,
    }
}

fn next_pending_receiver(
    line: &str,
    pending_receiver: Option<&'static str>,
) -> Option<&'static str> {
    let receiver = if line.contains(".tenant_repo") {
        Some("tenant_repo")
    } else if line.contains(".replica_repo") {
        Some("replica_repo")
    } else {
        pending_receiver
    };
    if line.contains(';') {
        None
    } else {
        receiver
    }
}

fn import_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaImportJob {
    import_job_with_source_size(customer_id, target, key, 12_345)
}

fn import_job_with_source_size(
    customer_id: Uuid,
    target: &str,
    key: &str,
    source_size_bytes: i64,
) -> NewAlgoliaImportJob {
    NewAlgoliaImportJob::create(
        customer_id,
        AlgoliaImportCreateDestination::new(target, "us-east-1"),
        source_with_size(key, source_size_bytes),
        key,
    )
}

fn replace_job(customer_id: Uuid, target: &str, key: &str) -> NewAlgoliaReplaceImportJob {
    NewAlgoliaReplaceImportJob::new(customer_id, target, source(key), key)
}

fn source(key: &str) -> AlgoliaImportSource {
    source_with_size(key, 12_345)
}

fn source_with_size(key: &str, source_size_bytes: i64) -> AlgoliaImportSource {
    AlgoliaImportSource::from_final_key_metadata(
        "AB12CD34EF",
        "Products",
        AlgoliaImportSourceMetadata::new(
            Some(source_size_bytes),
            Some(1_000),
            format!("revision-{key}"),
        ),
    )
}

fn eligible_replace_facts() -> AlgoliaReplaceTargetFacts {
    AlgoliaReplaceTargetFacts {
        provider: "aws".into(),
        vm_status: "active".into(),
        deployment_status: "active".into(),
        health_status: "healthy".into(),
        service_type: "flapjack".into(),
        has_active_lifecycle_operation: false,
        has_active_import_lease: false,
        has_flapjack_url: true,
    }
}

async fn insert_replace_target(pool: &PgPool, customer_id: Uuid, target: &str) {
    insert_active_customer(pool, customer_id, 1).await;
    insert_authenticated_target_row(pool, customer_id, target).await;
}

async fn insert_authenticated_target_row(pool: &PgPool, customer_id: Uuid, target: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://private.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(vm_id)
    .bind(format!("vm-{vm_id}"))
    .bind(json!({ "disk_bytes": 1_000_000_000 }))
    .bind(json!({ "disk_bytes": 0 }))
    .execute(pool)
    .await
    .expect("insert VM");

    let deployment_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://private.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("insert deployment");

    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(vm_id)
    .execute(pool)
    .await
    .expect("insert tenant");
    vm_id
}

async fn insert_replica_service_target(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> (Uuid, Uuid) {
    insert_active_customer(pool, customer_id, 1).await;
    insert_replica_service_target_without_customer(pool, customer_id, target).await
}

/// Insert the VMs, deployment, and active tenant for a replica-service target,
/// assuming the customer row already exists. Split out so that an active
/// create-import reservation can be seeded before the tenant exists (import
/// admission is only accepted while the logical target is unowned).
async fn insert_replica_service_target_without_customer(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> (Uuid, Uuid) {
    let primary_vm_id = Uuid::new_v4();
    let replica_vm_id = Uuid::new_v4();
    insert_vm_in_region(pool, primary_vm_id, "us-east-1").await;
    insert_vm_in_region(pool, replica_vm_id, "eu-central-1").await;
    let deployment_id = Uuid::new_v4();
    insert_running_deployment(pool, customer_id, deployment_id).await;
    sqlx::query(
        "INSERT INTO customer_tenants
         (customer_id, tenant_id, deployment_id, vm_id, tier, service_type)
         VALUES ($1, $2, $3, $4, 'active', 'flapjack')",
    )
    .bind(customer_id)
    .bind(target)
    .bind(deployment_id)
    .bind(primary_vm_id)
    .execute(pool)
    .await
    .expect("insert replica service tenant");
    (primary_vm_id, replica_vm_id)
}

async fn insert_region_failover_target(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> (Uuid, Uuid, Uuid) {
    insert_active_customer(pool, customer_id, 1).await;
    insert_region_failover_target_without_customer(pool, customer_id, target).await
}

/// Failover-target setup that assumes the customer row already exists, so an
/// active create-import reservation can be seeded first. See
/// [`insert_replica_service_target_without_customer`].
async fn insert_region_failover_target_without_customer(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> (Uuid, Uuid, Uuid) {
    let (primary_vm_id, replica_vm_id) =
        insert_replica_service_target_without_customer(pool, customer_id, target).await;
    let replica = PgIndexReplicaRepo::new(pool.clone())
        .create(
            customer_id,
            target,
            primary_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("insert failover replica");
    PgIndexReplicaRepo::new(pool.clone())
        .set_status(replica.id, "active")
        .await
        .expect("activate failover replica");
    (primary_vm_id, replica_vm_id, replica.id)
}

async fn insert_restore_service_target(pool: &PgPool, customer_id: Uuid, target: &str) {
    let source_vm_id = Uuid::new_v4();
    insert_vm(pool, source_vm_id).await;
    let snapshot = PgColdSnapshotRepo::new(pool.clone())
        .create(NewColdSnapshot {
            customer_id,
            tenant_id: target.to_string(),
            source_vm_id,
            object_key: format!("cold/{customer_id}/{target}/snapshot.fj"),
        })
        .await
        .expect("insert restore snapshot");
    PgColdSnapshotRepo::new(pool.clone())
        .set_exporting(snapshot.id)
        .await
        .expect("mark snapshot exporting");
    PgColdSnapshotRepo::new(pool.clone())
        .set_completed(snapshot.id, 1024, "restore-checksum")
        .await
        .expect("mark snapshot completed");
    let tenant_repo = PgTenantRepo::new(pool.clone());
    tenant_repo
        .set_tier(customer_id, target, "cold")
        .await
        .expect("mark restore target cold");
    tenant_repo
        .set_cold_snapshot_id(customer_id, target, Some(snapshot.id))
        .await
        .expect("attach restore snapshot");
    tenant_repo
        .clear_vm_id(customer_id, target)
        .await
        .expect("clear cold target vm");
}

async fn apply_restore_identity_drift(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    drift: RestoreIdentityDrift,
) -> CatalogLifecycleTargetIdentity {
    let before = load_target_identity(pool, customer_id, target).await;
    match drift {
        RestoreIdentityDrift::Tier => {
            sqlx::query(
                "UPDATE customer_tenants
                 SET tier = 'migrating'
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(target)
            .execute(pool)
            .await
            .expect("drift restore tier");
        }
        RestoreIdentityDrift::VmId => {
            let vm_id = Uuid::new_v4();
            insert_vm(pool, vm_id).await;
            sqlx::query(
                "UPDATE customer_tenants
                 SET vm_id = $3
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(target)
            .bind(vm_id)
            .execute(pool)
            .await
            .expect("drift restore vm");
        }
        RestoreIdentityDrift::ColdSnapshotId => {
            let source_vm_id = Uuid::new_v4();
            insert_vm(pool, source_vm_id).await;
            let snapshot_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO cold_snapshots
                 (id, customer_id, tenant_id, source_vm_id, object_key, size_bytes,
                  checksum, status, completed_at)
                 VALUES ($1, $2, $3, $4, $5, 2048, 'newer-restore-checksum',
                         'expired', NOW())",
            )
            .bind(snapshot_id)
            .bind(customer_id)
            .bind(target)
            .bind(source_vm_id)
            .bind(format!("cold/{customer_id}/{target}/newer-snapshot.fj"))
            .execute(pool)
            .await
            .expect("insert newer restore snapshot identity");
            PgTenantRepo::new(pool.clone())
                .set_cold_snapshot_id(customer_id, target, Some(snapshot_id))
                .await
                .expect("drift restore snapshot");
        }
        RestoreIdentityDrift::DeploymentId => {
            let deployment_id = Uuid::new_v4();
            insert_running_deployment(pool, customer_id, deployment_id).await;
            sqlx::query(
                "UPDATE customer_tenants
                 SET deployment_id = $3
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(target)
            .bind(deployment_id)
            .execute(pool)
            .await
            .expect("drift restore deployment");
        }
        RestoreIdentityDrift::ServiceType => {
            sqlx::query(
                "UPDATE customer_tenants
                 SET service_type = 'shared'
                 WHERE customer_id = $1 AND tenant_id = $2",
            )
            .bind(customer_id)
            .bind(target)
            .execute(pool)
            .await
            .expect("drift restore service type");
        }
    }
    let after = load_target_identity(pool, customer_id, target).await;
    assert_identity_drift_applied(&before, &after, drift, "restore identity drift helper");
    after
}

async fn apply_migration_identity_drift(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    drift: RestoreIdentityDrift,
) -> CatalogLifecycleTargetIdentity {
    if matches!(drift, RestoreIdentityDrift::Tier) {
        let before = load_target_identity(pool, customer_id, target).await;
        sqlx::query(
            "UPDATE customer_tenants
             SET tier = 'pinned'
             WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer_id)
        .bind(target)
        .execute(pool)
        .await
        .expect("drift migration tier");
        let after = load_target_identity(pool, customer_id, target).await;
        assert_identity_drift_applied(&before, &after, drift, "migration identity drift helper");
        return after;
    }

    apply_restore_identity_drift(pool, customer_id, target, drift).await
}

async fn insert_vm(pool: &PgPool, vm_id: Uuid) {
    insert_vm_in_region(pool, vm_id, "us-east-1").await;
}

async fn insert_vm_in_region(pool: &PgPool, vm_id: Uuid, region: &str) {
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load, load_scraped_at)
         VALUES ($1, $2, 'aws', $3, 'https://private.invalid', 'active',
                 $4::jsonb, $5::jsonb, NOW())",
    )
    .bind(vm_id)
    .bind(region)
    .bind(format!("vm-{region}-{vm_id}"))
    .bind(json!({
        "cpu_weight": 100.0,
        "mem_rss_bytes": 1_000_000_000_u64,
        "disk_bytes": 10_000_000_000_u64,
        "query_rps": 10_000.0,
        "indexing_rps": 10_000.0
    }))
    .bind(json!({
        "cpu_weight": 0.0,
        "mem_rss_bytes": 0_u64,
        "disk_bytes": 0_u64,
        "query_rps": 0.0,
        "indexing_rps": 0.0
    }))
    .execute(pool)
    .await
    .expect("insert VM");
}

async fn replica_rows(pool: &PgPool, customer_id: Uuid, target: &str) -> Vec<ReplicaRowSnapshot> {
    sqlx::query_as::<
        _,
        (
            Uuid,
            Uuid,
            String,
            Uuid,
            Uuid,
            String,
            String,
            i64,
            serde_json::Value,
        ),
    >(
        "SELECT id, customer_id, tenant_id, primary_vm_id, replica_vm_id,
                replica_region, status, lag_ops, to_jsonb(r)
         FROM index_replicas AS r
         WHERE customer_id = $1 AND tenant_id = $2
         ORDER BY created_at, id",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("load replica rows")
    .into_iter()
    .map(|row| ReplicaRowSnapshot {
        id: row.0,
        customer_id: row.1,
        tenant_id: row.2,
        primary_vm_id: row.3,
        replica_vm_id: row.4,
        replica_region: row.5,
        status: row.6,
        lag_ops: row.7,
        complete_row: row.8,
    })
    .collect()
}

async fn import_operation_rows(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> Vec<ImportOperationRowSnapshot> {
    sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            Option<Uuid>,
            Option<Uuid>,
            Option<String>,
            String,
            i64,
            String,
            String,
            String,
            serde_json::Value,
        ),
    >(
        "SELECT id, destination_kind, destination_deployment_id, destination_vm_id,
                physical_uid, dispatch_intent_state, lifecycle_generation, status,
                publication_disposition, engine_ack_state, to_jsonb(j)
         FROM algolia_import_jobs AS j
         WHERE customer_id = $1 AND logical_target = $2
         ORDER BY created_at, id",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("load import operation rows")
    .into_iter()
    .map(|row| ImportOperationRowSnapshot {
        id: row.0,
        destination_kind: row.1,
        destination_deployment_id: row.2,
        destination_vm_id: row.3,
        physical_uid: row.4,
        dispatch_intent_state: row.5,
        lifecycle_generation: row.6,
        status: row.7,
        publication_disposition: row.8,
        engine_ack_state: row.9,
        complete_row: row.10,
    })
    .collect()
}

async fn cold_snapshot_rows(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> Vec<ColdSnapshotRowSnapshot> {
    sqlx::query_as::<_, ColdSnapshot>(
        "SELECT *
         FROM cold_snapshots
         WHERE customer_id = $1 AND tenant_id = $2
         ORDER BY created_at, id",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("load cold snapshot rows")
    .into_iter()
    .map(|snapshot| ColdSnapshotRowSnapshot {
        id: snapshot.id,
        customer_id: snapshot.customer_id,
        tenant_id: snapshot.tenant_id,
        source_vm_id: snapshot.source_vm_id,
        object_key: snapshot.object_key,
        size_bytes: snapshot.size_bytes,
        checksum: snapshot.checksum,
        status: snapshot.status,
        error: snapshot.error,
    })
    .collect()
}

/// Read the committed tenant/snapshot state for a cold-tier target from a
/// caller-provided connection. Used inside the export observation hook to prove
/// the snapshot intent is durably visible before remote export begins.
async fn observe_cold_export_state(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    delete_calls_before_first_export: usize,
) -> ColdTierExportObservation {
    let tenant = sqlx::query_as::<_, (String, Option<Uuid>, Option<Uuid>)>(
        "SELECT tier, vm_id, cold_snapshot_id
         FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("load tenant state at export");
    let snapshot_status = sqlx::query_scalar::<_, String>(
        "SELECT status
         FROM cold_snapshots
         WHERE customer_id = $1 AND tenant_id = $2
         ORDER BY created_at DESC, id DESC
         LIMIT 1",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_optional(pool)
    .await
    .expect("load snapshot status at export");
    ColdTierExportObservation {
        tier: tenant.0,
        vm_id: tenant.1,
        cold_snapshot_id: tenant.2,
        snapshot_status,
        delete_calls_before_first_export,
    }
}

/// Read a single cold snapshot's status by ID, so drift/compensation tests can
/// assert whether a specific snapshot intent was left untouched or marked failed.
async fn cold_snapshot_status(pool: &PgPool, snapshot_id: Uuid) -> Option<String> {
    sqlx::query_scalar::<_, String>("SELECT status FROM cold_snapshots WHERE id = $1")
        .bind(snapshot_id)
        .fetch_optional(pool)
        .await
        .expect("load cold snapshot status by id")
}

async fn restore_job_rows(pool: &PgPool, customer_id: Uuid, target: &str) -> Vec<RestoreJob> {
    sqlx::query_as::<_, RestoreJob>(
        "SELECT *
         FROM restore_jobs
         WHERE customer_id = $1 AND tenant_id = $2
         ORDER BY created_at, id",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("load restore job rows")
}

fn restore_service(
    pool: &PgPool,
    node_client: Arc<dyn FlapjackNodeClient>,
    guard_pause_hook: Option<LifecycleGuardPauseHook>,
) -> (RestoreService, Arc<PgRestoreJobRepo>) {
    restore_service_with_dependencies(
        pool,
        node_client,
        mock_node_secret_manager(),
        Arc::new(InMemoryObjectStore::new()),
        guard_pause_hook,
    )
}

fn restore_service_with_dependencies(
    pool: &PgPool,
    node_client: Arc<dyn FlapjackNodeClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    object_store: Arc<InMemoryObjectStore>,
    guard_pause_hook: Option<LifecycleGuardPauseHook>,
) -> (RestoreService, Arc<PgRestoreJobRepo>) {
    let tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    let restore_job_repo = Arc::new(PgRestoreJobRepo::new(pool.clone()));
    let mut service = RestoreService::new(
        RestoreConfig::default(),
        tenant_repo.clone(),
        Arc::new(PgColdSnapshotRepo::new(pool.clone())),
        restore_job_repo.clone(),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(RegionObjectStoreResolver::single(object_store)),
        Arc::new(MockAlertService::new()),
        Arc::new(DiscoveryService::with_ttl(
            tenant_repo,
            Arc::new(PgVmInventoryRepo::new(pool.clone())),
            3600,
        )),
        node_client,
        node_secret_manager,
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
    );
    if let Some(hook) = guard_pause_hook {
        service = service.with_guard_pause_hook_for_tests(hook);
    }
    (service, restore_job_repo)
}

fn cold_tier_service(pool: &PgPool, node_client: Arc<dyn FlapjackNodeClient>) -> ColdTierService {
    observable_cold_tier_service(pool, node_client).0
}

fn observable_cold_tier_service(
    pool: &PgPool,
    node_client: Arc<dyn FlapjackNodeClient>,
) -> (ColdTierService, Arc<FailableObjectStore>) {
    let object_store = observable_object_store();
    let service = cold_tier_service_with_object_store(pool, node_client, object_store.clone());
    (service, object_store)
}

fn observable_object_store() -> Arc<FailableObjectStore> {
    Arc::new(FailableObjectStore::new(
        Arc::new(InMemoryObjectStore::new()),
        Arc::new(AtomicBool::new(false)),
    ))
}

fn cold_tier_service_with_object_store(
    pool: &PgPool,
    node_client: Arc<dyn FlapjackNodeClient>,
    object_store: Arc<FailableObjectStore>,
) -> ColdTierService {
    let tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    ColdTierService::new(
        ColdTierConfig::default(),
        ColdTierDependencies {
            tenant_repo: tenant_repo.clone(),
            index_migration_repo: Arc::new(api::repos::PgIndexMigrationRepo::new(pool.clone())),
            cold_snapshot_repo: Arc::new(PgColdSnapshotRepo::new(pool.clone())),
            vm_inventory_repo: Arc::new(PgVmInventoryRepo::new(pool.clone())),
            object_store_resolver: Arc::new(RegionObjectStoreResolver::single(object_store)),
            alert_service: Arc::new(MockAlertService::new()),
            discovery_service: Arc::new(DiscoveryService::with_ttl(
                tenant_repo,
                Arc::new(PgVmInventoryRepo::new(pool.clone())),
                3600,
            )),
            node_client,
            node_secret_manager: mock_node_secret_manager(),
            lifecycle_lease: Some(Arc::new(IndexLifecycleLease::new(
                PgAlgoliaImportJobRepo::new(pool.clone()),
            ))),
        },
    )
}

async fn cold_tier_candidate(
    pool: &PgPool,
    customer_id: Uuid,
    tenant_id: &str,
    expected_vm_id: Uuid,
) -> ColdTierCandidate {
    let tenant = PgTenantRepo::new(pool.clone())
        .find_raw(customer_id, tenant_id)
        .await
        .expect("load cold-tier candidate")
        .expect("cold-tier candidate exists");
    let candidate = ColdTierCandidate::from_tenant(&tenant).expect("candidate has source VM");
    assert_eq!(candidate.source_vm_id, expected_vm_id);
    candidate
}

async fn seed_cold_tier_refusal_controls(pool: &PgPool, customer_id: Uuid, source_vm_id: Uuid) {
    insert_authenticated_target_row(pool, customer_id, "orders").await;
    let replica_vm_id = Uuid::new_v4();
    insert_vm_in_region(pool, replica_vm_id, "eu-central-1").await;
    PgIndexReplicaRepo::new(pool.clone())
        .create(
            customer_id,
            "products",
            source_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("seed cold-tier refusal routing control");
}

fn migration_service(
    pool: &PgPool,
    http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
) -> MigrationService {
    migration_service_with_secrets(pool, http_client, mock_node_secret_manager())
}

fn migration_service_with_secrets(
    pool: &PgPool,
    http_client: Arc<dyn MigrationHttpClient + Send + Sync>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
) -> MigrationService {
    let tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    MigrationService::with_http_client_config_and_lifecycle(
        tenant_repo.clone(),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(PgIndexMigrationRepo::new(pool.clone())),
        Arc::new(MockAlertService::new()),
        Arc::new(DiscoveryService::with_ttl(
            tenant_repo,
            Arc::new(PgVmInventoryRepo::new(pool.clone())),
            3600,
        )),
        node_secret_manager,
        http_client,
        MigrationConfig {
            max_concurrent: 3,
            rollback_window: Duration::seconds(300),
            replication_timeout: std::time::Duration::from_millis(50),
            replication_poll_interval: std::time::Duration::from_millis(10),
            replication_near_zero_lag_ops: 10,
            long_running_warning_threshold: std::time::Duration::from_secs(600),
        },
        Some(Arc::new(IndexLifecycleLease::new(
            PgAlgoliaImportJobRepo::new(pool.clone()),
        ))),
    )
}

async fn insert_running_deployment(pool: &PgPool, customer_id: Uuid, deployment_id: Uuid) {
    sqlx::query(
        "INSERT INTO customer_deployments
         (id, customer_id, node_id, region, vm_type, vm_provider, status,
          flapjack_url, health_status)
         VALUES ($1, $2, $3, 'us-east-1', 't4g.small', 'aws', 'running',
                 'https://private.invalid', 'healthy')",
    )
    .bind(deployment_id)
    .bind(customer_id)
    .bind(format!("node-{deployment_id}"))
    .execute(pool)
    .await
    .expect("insert deployment");
}

async fn load_target_identity(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> CatalogLifecycleTargetIdentity {
    let row = sqlx::query_as::<_, (Uuid, Option<Uuid>, String, Option<Uuid>, String)>(
        "SELECT deployment_id, vm_id, tier, cold_snapshot_id, service_type
         FROM customer_tenants
         WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer_id)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("load target identity");
    CatalogLifecycleTargetIdentity {
        deployment_id: row.0,
        vm_id: row.1,
        tier: row.2,
        cold_snapshot_id: row.3,
        service_type: row.4,
    }
}

async fn update_replace_target_column(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    table: &str,
    column: &str,
    value: &str,
) {
    let statement = match (table, column) {
        ("vm_inventory", "provider") => {
            "UPDATE vm_inventory vm
             SET provider = $3
             FROM customer_tenants tenant
             WHERE tenant.vm_id = vm.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("vm_inventory", "status") => {
            "UPDATE vm_inventory vm
             SET status = $3
             FROM customer_tenants tenant
             WHERE tenant.vm_id = vm.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("vm_inventory", "flapjack_url") => {
            "UPDATE vm_inventory vm
             SET flapjack_url = $3
             FROM customer_tenants tenant
             WHERE tenant.vm_id = vm.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("customer_deployments", "status") => {
            "UPDATE customer_deployments deployment
             SET status = $3
             FROM customer_tenants tenant
             WHERE tenant.deployment_id = deployment.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("customer_deployments", "health_status") => {
            "UPDATE customer_deployments deployment
             SET health_status = $3
             FROM customer_tenants tenant
             WHERE tenant.deployment_id = deployment.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("customer_deployments", "flapjack_url") => {
            "UPDATE customer_deployments deployment
             SET flapjack_url = $3
             FROM customer_tenants tenant
             WHERE tenant.deployment_id = deployment.id
               AND tenant.customer_id = $1
               AND tenant.tenant_id = $2"
        }
        ("customer_tenants", "tier") => {
            "UPDATE customer_tenants
             SET tier = $3
             WHERE customer_id = $1 AND tenant_id = $2"
        }
        ("customer_tenants", "service_type") => {
            "UPDATE customer_tenants
             SET service_type = $3
             WHERE customer_id = $1 AND tenant_id = $2"
        }
        _ => panic!("unsupported replacement target fixture column {table}.{column}"),
    };
    sqlx::query(statement)
        .bind(customer_id)
        .bind(target)
        .bind(value)
        .execute(pool)
        .await
        .expect("update replacement target fixture");
}

async fn insert_active_migration(pool: &PgPool, customer_id: Uuid, target: &str) -> Uuid {
    let mut captured_identity = load_target_identity(pool, customer_id, target).await;
    captured_identity.tier = "migrating".to_string();
    let source_vm_id = captured_identity
        .vm_id
        .expect("replacement target source VM");
    let dest_vm_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO vm_inventory
         (id, region, provider, hostname, flapjack_url, status, capacity, current_load)
         VALUES ($1, 'us-east-1', 'aws', $2, 'https://dest.invalid', 'active',
                 $3::jsonb, $4::jsonb)",
    )
    .bind(dest_vm_id)
    .bind(format!("migration-vm-{dest_vm_id}"))
    .bind(json!({ "disk_bytes": 1_000_000_000 }))
    .bind(json!({ "disk_bytes": 0 }))
    .execute(pool)
    .await
    .expect("insert migration destination VM");
    let migration_id = Uuid::new_v4();
    let metadata =
        api::models::index_migration::IndexMigration::metadata_with_intent_target_identity_from(
            &json!({}),
            &captured_identity,
        );
    sqlx::query(
        "INSERT INTO index_migrations
         (id, index_name, customer_id, source_vm_id, dest_vm_id, status, requested_by, metadata)
         VALUES ($1, $2, $3, $4, $5, 'cutting_over', 'test', $6)",
    )
    .bind(migration_id)
    .bind(target)
    .bind(customer_id)
    .bind(source_vm_id)
    .bind(dest_vm_id)
    .bind(metadata)
    .execute(pool)
    .await
    .expect("insert active migration");
    migration_id
}

async fn force_resumable_credential_failure(
    pool: &PgPool,
    job_id: Uuid,
    observed_at: DateTime<Utc>,
    resume_deadline: DateTime<Utc>,
) {
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET status = 'failed', publication_disposition = 'unchanged',
             engine_ack_state = 'pending', dispatch_intent_state = 'committed',
             engine_job_id = gen_random_uuid(), error_code = 'invalid_credentials',
             retryable = TRUE, resumable = TRUE, resume_checkpoint = 'checkpoint-data',
             resume_status_observed_at = $2, resume_deadline = $3,
             updated_at = NOW()
         WHERE id = $1",
    )
    .bind(job_id)
    .bind(observed_at)
    .bind(resume_deadline)
    .execute(pool)
    .await
    .expect("force resumable credential failure");
}

async fn expire_worker_lease(pool: &PgPool, job_id: Uuid, case: &ReservationLifetimeCase) {
    force_reservation_lifetime_case(pool, job_id, case).await;
    sqlx::query(
        "UPDATE algolia_import_jobs
         SET worker_claimed_at = NOW() - INTERVAL '20 minutes',
             worker_lease_expires_at = NOW() - INTERVAL '10 minutes',
             updated_at = NOW()
         WHERE id = $1 AND worker_lease_expires_at IS NULL",
    )
    .bind(job_id)
    .execute(pool)
    .await
    .unwrap_or_else(|error| panic!("expire import worker lease for {}: {error}", case.label));

    let persisted_is_expired = sqlx::query_scalar::<_, bool>(
        "SELECT worker_lease_expires_at < NOW()
         FROM algolia_import_jobs
         WHERE id = $1",
    )
    .bind(job_id)
    .fetch_one(pool)
    .await
    .unwrap_or_else(|error| panic!("verify expired worker lease for {}: {error}", case.label));
    assert!(
        persisted_is_expired,
        "persisted worker lease must be expired before writer invocation for {}",
        case.label
    );
}

async fn create_expired_import_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    case: &ReservationLifetimeCase,
) {
    let job = PgAlgoliaImportJobRepo::new(pool.clone())
        .create(import_job(customer_id, target, key))
        .await
        .expect("active import reservation");
    expire_worker_lease(pool, job.id, case).await;
}

async fn create_expired_replace_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key: &str,
    case: &ReservationLifetimeCase,
) {
    let job = PgAlgoliaImportJobRepo::new(pool.clone())
        .create_replace(replace_job(customer_id, target, key))
        .await
        .expect("active replace reservation");
    expire_worker_lease(pool, job.id, case).await;
}

fn admission_refusal_code(
    result: &Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>,
) -> Option<&'static str> {
    match result {
        Err(AlgoliaImportJobAdmissionError::Refused(code)) => Some(code.as_str()),
        _ => None,
    }
}

fn assert_conflict_code(
    result: Result<AlgoliaImportJob, AlgoliaImportJobAdmissionError>,
    code: &str,
) {
    assert!(
        admission_refusal_code(&result) == Some(code),
        "expected conflict code {code}, got {result:?}"
    );
}

async fn pool_in_schema(schema: &str) -> PgPool {
    pool_in_schema_with_options(schema, None, 1).await
}

async fn pool_in_schema_with_application_name(
    schema: &str,
    application_name: Option<String>,
) -> PgPool {
    pool_in_schema_with_options(schema, application_name, 1).await
}

async fn pooled_repo_connections_in_schema(schema: &str) -> PgPool {
    pool_in_schema_with_options(schema, None, 5).await
}

async fn pool_in_schema_with_options(
    schema: &str,
    application_name: Option<String>,
    max_connections: u32,
) -> PgPool {
    let url = crate::common::support::pg_schema_harness::require_database_url(std::env::var(
        "DATABASE_URL",
    ));
    let pool = PgPoolOptions::new()
        .max_connections(max_connections)
        .after_connect({
            let schema = schema.to_string();
            let application_name = application_name.clone();
            move |conn, _meta| {
                let schema = schema.clone();
                let application_name = application_name.clone();
                Box::pin(async move {
                    if let Some(application_name) = application_name {
                        sqlx::query("SELECT set_config('application_name', $1, false)")
                            .bind(application_name)
                            .execute(&mut *conn)
                            .await?;
                    }
                    sqlx::query(&format!("SET search_path TO {schema}"))
                        .execute(conn)
                        .await?;
                    Ok(())
                })
            }
        })
        .connect(&url)
        .await
        .expect("connect to isolated schema");
    pool
}

async fn begin_lifecycle_guard_with_retry(
    service: &IndexLifecycleLease,
    customer_id: Uuid,
    target: &str,
) -> Result<api::repos::CatalogLifecycleTargetGuard, RepoError> {
    let mut last_result = service.begin(customer_id, target).await;
    for _ in 0..20 {
        match last_result {
            Ok(guard) => return Ok(guard),
            Err(RepoError::Conflict(ref message)) if message == "destination_conflict" => {
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                last_result = service.begin(customer_id, target).await;
            }
            Err(_) => return last_result,
        }
    }
    last_result
}

fn route_test_app(
    pool: PgPool,
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
) -> axum::Router {
    build_router(route_test_state_with_node_secret_manager(
        pool,
        customer_repo,
        http_client,
        mock_node_secret_manager(),
    ))
}

fn route_test_app_with_node_secret_manager(
    pool: PgPool,
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
) -> axum::Router {
    build_router(route_test_state_with_node_secret_manager(
        pool,
        customer_repo,
        http_client,
        node_secret_manager,
    ))
}

fn route_test_state_with_node_secret_manager(
    pool: PgPool,
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    http_client: Arc<MockFlapjackHttpClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
) -> AppState {
    let flapjack_proxy = Arc::new(FlapjackProxy::with_http_client(
        http_client,
        node_secret_manager.clone(),
    ));
    let tenant_repo: Arc<dyn TenantRepo + Send + Sync> = Arc::new(PgTenantRepo::new(pool.clone()));
    let deployment_repo: Arc<dyn DeploymentRepo + Send + Sync> =
        Arc::new(PgDeploymentRepo::new(pool.clone()));
    let vm_inventory_repo: Arc<dyn VmInventoryRepo + Send + Sync> =
        Arc::new(PgVmInventoryRepo::new(pool.clone()));

    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_deployment_repo(mock_deployment_repo())
        .with_tenant_repo(mock_tenant_repo())
        .with_vm_inventory_repo(mock_vm_inventory_repo())
        .with_flapjack_proxy(flapjack_proxy)
        .build();
    state.pool = pool.clone();
    state.tenant_repo = tenant_repo.clone();
    state.deployment_repo = deployment_repo.clone();
    state.vm_inventory_repo = vm_inventory_repo.clone();
    state.discovery_service = Arc::new(DiscoveryService::new(tenant_repo, vm_inventory_repo));
    state.index_lifecycle_lease = Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
        pool.clone(),
    )));
    state.provisioning_service = Arc::new(api::services::provisioning::ProvisioningService::new(
        state.vm_provisioner.clone(),
        state.dns_manager.clone(),
        node_secret_manager,
        deployment_repo,
        state.customer_repo.clone(),
        "flapjack.foo".to_string(),
    ));
    state
}

async fn insert_route_test_vm(pool: &PgPool, region: &str, flapjack_url: &str) -> Uuid {
    let vm_id = Uuid::new_v4();
    let vm = PgVmInventoryRepo::new(pool.clone())
        .create(NewVmInventory {
            region: region.to_string(),
            provider: "aws".to_string(),
            hostname: format!("route-test-shared-vm-{vm_id}"),
            flapjack_url: flapjack_url.to_string(),
            capacity: json!({
                "cpu_weight": 100.0,
                "mem_rss_bytes": 10_000_000_000_u64,
                "disk_bytes": 10_000_000_000_u64,
                "query_rps": 10_000.0,
                "indexing_rps": 10_000.0
            }),
        })
        .await
        .expect("insert route test VM");
    vm.id
}

async fn tenant_rows(pool: &PgPool, customer_id: Uuid) -> Vec<TenantRowSnapshot> {
    sqlx::query_as::<
        _,
        (
            String,
            Uuid,
            Option<Uuid>,
            String,
            Option<Uuid>,
            String,
            serde_json::Value,
        ),
    >(
        "SELECT tenant_id, deployment_id, vm_id, tier, cold_snapshot_id, service_type,
                to_jsonb(t)
         FROM customer_tenants AS t
         WHERE customer_id = $1
         ORDER BY tenant_id",
    )
    .bind(customer_id)
    .fetch_all(pool)
    .await
    .expect("load tenant snapshot")
    .into_iter()
    .map(|row| TenantRowSnapshot {
        tenant_id: row.0,
        deployment_id: row.1,
        vm_id: row.2,
        tier: row.3,
        cold_snapshot_id: row.4,
        service_type: row.5,
        complete_row: row.6,
    })
    .collect()
}

async fn deployment_rows(pool: &PgPool, customer_id: Uuid) -> Vec<DeploymentRowSnapshot> {
    sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            String,
            String,
            String,
            Option<String>,
            serde_json::Value,
        ),
    >(
        "SELECT id, node_id, region, vm_provider, status, flapjack_url, to_jsonb(d)
         FROM customer_deployments AS d
         WHERE customer_id = $1
         ORDER BY node_id",
    )
    .bind(customer_id)
    .fetch_all(pool)
    .await
    .expect("load deployment snapshot")
    .into_iter()
    .map(|row| DeploymentRowSnapshot {
        id: row.0,
        node_id: row.1,
        region: row.2,
        vm_provider: row.3,
        status: row.4,
        flapjack_url: row.5,
        complete_row: row.6,
    })
    .collect()
}

#[tokio::test]
async fn route_row_snapshots_detect_business_field_mutations() {
    let Some(db) = connect_and_migrate("catalog_route_complete_row_snapshots").await else {
        return;
    };
    let customer_id = Uuid::new_v4();
    let (_, _, replica_id) = insert_region_failover_target(&db.pool, customer_id, "products").await;
    let operation = PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create_replace(replace_job(
            customer_id,
            "products",
            "complete-row-snapshot-operation",
        ))
        .await
        .expect("seed operation snapshot row");
    let before_tenants = tenant_rows(&db.pool, customer_id).await;
    let before_deployments = deployment_rows(&db.pool, customer_id).await;
    let before_replicas = replica_rows(&db.pool, customer_id, "products").await;
    let before_operations = import_operation_rows(&db.pool, customer_id, "products").await;

    sqlx::query(
        "UPDATE customer_tenants
         SET resource_quota = '{\"disk_bytes\": 4096}'::jsonb
         WHERE customer_id = $1 AND tenant_id = 'products'",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("mutate tenant business field");
    sqlx::query(
        "UPDATE customer_deployments
         SET health_status = 'unhealthy'
         WHERE customer_id = $1",
    )
    .bind(customer_id)
    .execute(&db.pool)
    .await
    .expect("mutate deployment business field");
    sqlx::query(
        "UPDATE index_replicas SET updated_at = updated_at + INTERVAL '1 second' WHERE id = $1",
    )
    .bind(replica_id)
    .execute(&db.pool)
    .await
    .expect("mutate replica business field");
    sqlx::query("UPDATE algolia_import_jobs SET error_message = 'snapshot sentinel' WHERE id = $1")
        .bind(operation.id)
        .execute(&db.pool)
        .await
        .expect("mutate operation business field");

    assert_ne!(tenant_rows(&db.pool, customer_id).await, before_tenants);
    assert_ne!(
        deployment_rows(&db.pool, customer_id).await,
        before_deployments
    );
    assert_ne!(
        replica_rows(&db.pool, customer_id, "products").await,
        before_replicas
    );
    assert_ne!(
        import_operation_rows(&db.pool, customer_id, "products").await,
        before_operations
    );
}

fn create_index_request(index_name: &str, jwt: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/indexes")
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(
            json!({"name": index_name, "region": "us-east-1"}).to_string(),
        ))
        .unwrap()
}

fn delete_index_request(index_name: &str, jwt: &str) -> Request<Body> {
    Request::builder()
        .method("DELETE")
        .uri(format!("/indexes/{index_name}"))
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {jwt}"))
        .body(Body::from(json!({"confirm": true}).to_string()))
        .unwrap()
}

fn seed_index_request(
    customer_id: Uuid,
    index_name: &str,
    flapjack_url: Option<&str>,
) -> Request<Body> {
    let mut body = json!({"name": index_name, "region": "us-east-1"});
    if let Some(flapjack_url) = flapjack_url {
        body["flapjack_url"] = json!(flapjack_url);
    }
    Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{customer_id}/indexes"))
        .header("content-type", "application/json")
        .header("x-admin-key", TEST_ADMIN_KEY)
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn assert_conflict_response(response: axum::response::Response, expected: &str) {
    let status = response.status();
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read response body");
    let json: serde_json::Value = serde_json::from_slice(&body).expect("JSON error response");
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "expected conflict response, got status={status} body={json}"
    );
    assert_eq!(json["error"], expected);
}

async fn seed_create_route_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    reservation: ActiveReservationKind,
) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    match reservation {
        ActiveReservationKind::Import => {
            insert_active_customer(pool, customer_id, 1).await;
            repo.create(import_job(customer_id, "products", "route-create-import"))
                .await
                .expect("active import reservation");
        }
        ActiveReservationKind::Replacement => {
            insert_replace_target(pool, customer_id, "products").await;
            repo.create_replace(replace_job(
                customer_id,
                "products",
                "route-create-replacement",
            ))
            .await
            .expect("active replacement reservation");
        }
    }
}

async fn seed_delete_route_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    reservation: ActiveReservationKind,
) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    match reservation {
        ActiveReservationKind::Import => {
            insert_active_customer(pool, customer_id, 1).await;
            repo.create(import_job(customer_id, "products", "route-delete-import"))
                .await
                .expect("active import reservation");
            insert_authenticated_target_row(pool, customer_id, "products").await;
        }
        ActiveReservationKind::Replacement => {
            insert_replace_target(pool, customer_id, "products").await;
            repo.create_replace(replace_job(
                customer_id,
                "products",
                "route-delete-replacement",
            ))
            .await
            .expect("active replacement reservation");
        }
    }
}

async fn assert_create_route_refuses_reservation(schema: &str, reservation: ActiveReservationKind) {
    let Some(db) = connect_and_migrate(schema).await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer(
        &format!("Route Create {}", reservation.label()),
        &format!("create-{}@test.com", reservation.label()),
    );
    seed_create_route_reservation(&db.pool, customer.id, reservation).await;
    insert_route_test_vm(&db.pool, "us-east-1", "https://route-create.invalid").await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app(route_pool, customer_repo, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer.id).await;
    let before_deployments = deployment_rows(&db.pool, customer.id).await;
    let before_replicas = replica_rows(&db.pool, customer.id, "products").await;
    let before_operations = import_operation_rows(&db.pool, customer.id, "products").await;

    let response = app
        .oneshot(create_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("create index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(
        http_client.request_count(),
        0,
        "route create must refuse before remote engine create"
    );
    assert_eq!(tenant_rows(&db.pool, customer.id).await, before_tenants);
    assert_eq!(
        deployment_rows(&db.pool, customer.id).await,
        before_deployments,
        "route create refusal must not leave an orphan deployment intent"
    );
    assert_eq!(
        replica_rows(&db.pool, customer.id, "products").await,
        before_replicas,
        "route create refusal must not mutate replica routing"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer.id, "products").await,
        before_operations,
        "route create refusal must not mutate the winning operation intent"
    );
}

async fn assert_delete_route_refuses_reservation(schema: &str, reservation: ActiveReservationKind) {
    let Some(db) = connect_and_migrate(schema).await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer(
        &format!("Route Delete {}", reservation.label()),
        &format!("delete-{}@test.com", reservation.label()),
    );
    seed_delete_route_reservation(&db.pool, customer.id, reservation).await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app(route_pool, customer_repo, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer.id).await;
    let before_deployments = deployment_rows(&db.pool, customer.id).await;
    let before_replicas = replica_rows(&db.pool, customer.id, "products").await;
    let before_operations = import_operation_rows(&db.pool, customer.id, "products").await;

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(
        http_client.request_count(),
        0,
        "route delete must refuse before remote engine delete"
    );
    assert_eq!(tenant_rows(&db.pool, customer.id).await, before_tenants);
    assert_eq!(
        deployment_rows(&db.pool, customer.id).await,
        before_deployments
    );
    assert_eq!(
        replica_rows(&db.pool, customer.id, "products").await,
        before_replicas,
        "route delete refusal must not mutate replica routing"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer.id, "products").await,
        before_operations,
        "route delete refusal must not mutate the winning operation intent"
    );
}

fn shared_vm_node_secret_id(vm_id: Uuid) -> String {
    format!("vm-{vm_id}")
}

#[derive(Debug, PartialEq, Eq)]
struct RouteDeleteSnapshot {
    tenants: Vec<TenantRowSnapshot>,
    deployments: Vec<DeploymentRowSnapshot>,
    replicas: Vec<ReplicaRowSnapshot>,
    operations: Vec<ImportOperationRowSnapshot>,
}

async fn route_delete_snapshot(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> RouteDeleteSnapshot {
    RouteDeleteSnapshot {
        tenants: tenant_rows(pool, customer_id).await,
        deployments: deployment_rows(pool, customer_id).await,
        replicas: replica_rows(pool, customer_id, target).await,
        operations: import_operation_rows(pool, customer_id, target).await,
    }
}

async fn seed_delete_route_target(pool: &PgPool, customer_id: Uuid, target: &str) -> Uuid {
    insert_active_customer(pool, customer_id, 1).await;
    insert_authenticated_target_row(pool, customer_id, target).await
}

#[tokio::test]
async fn delete_index_publishes_deleting_and_invalidates_discovery_before_remote_delete() {
    let Some(db) = connect_and_migrate("catalog_route_delete_publish_invalidate").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Delete Publish", "delete-publish@test.com");
    let vm_id = seed_delete_route_target(&db.pool, customer.id, "products").await;
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&shared_vm_node_secret_id(vm_id), "us-east-1")
        .await
        .expect("seed shared VM node secret");
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let state = route_test_state_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager,
    );
    let cached = state
        .discovery_service
        .discover(customer.id, "products")
        .await
        .expect("prime active discovery cache");
    assert_eq!(cached.flapjack_url, "https://private.invalid");
    let discovery_service = state.discovery_service.clone();
    let hook_pool = pool_in_schema(&db.schema).await;
    http_client.before_next_send(move || async move {
        let rows = tenant_rows(&hook_pool, customer.id).await;
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].tier, "deleting",
            "delete route must publish deleting before the first remote delete"
        );
        let discovered = discovery_service.discover(customer.id, "products").await;
        assert!(
            matches!(discovered, Err(DiscoveryError::NotFound)),
            "active discovery cache must be invalidated before remote delete, got {discovered:?}"
        );
    });
    let app = build_router(state);

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index response");

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let requests = http_client.take_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, Method::DELETE);
    assert_eq!(
        requests[0].url,
        format!(
            "https://private.invalid/1/indexes/{}",
            flapjack_index_uid(customer.id, "products")
        )
    );
    assert!(
        tenant_rows(&db.pool, customer.id).await.is_empty(),
        "successful delete must finalize by removing the deleting row"
    );
    assert!(
        matches!(
            state_discovery_after_success(&db.pool, customer.id, "products").await,
            Err(DiscoveryError::NotFound)
        ),
        "successful delete must not leave a discoverable catalog route"
    );
}

async fn state_discovery_after_success(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> Result<api::services::discovery::DiscoveryResult, DiscoveryError> {
    Arc::new(DiscoveryService::new(
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
    ))
    .discover(customer_id, target)
    .await
}

#[tokio::test]
async fn delete_index_resumes_compatible_deleting_intent_without_duplicate_rows() {
    let Some(db) = connect_and_migrate("catalog_route_delete_resume_deleting").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Delete Resume", "delete-resume@test.com");
    let vm_id = seed_delete_route_target(&db.pool, customer.id, "products").await;
    PgTenantRepo::new(db.pool.clone())
        .set_tier(customer.id, "products", "deleting")
        .await
        .expect("seed resumable deleting row");
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&shared_vm_node_secret_id(vm_id), "us-east-1")
        .await
        .expect("seed shared VM node secret");
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager,
    );
    let before = route_delete_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(before.tenants.len(), 1);
    assert_eq!(before.tenants[0].tier, "deleting");

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index response");

    assert_eq!(
        response.status(),
        StatusCode::NO_CONTENT,
        "compatible deleting row must resume to successful deletion"
    );
    assert_eq!(http_client.request_count(), 1);
    let after = route_delete_snapshot(&db.pool, customer.id, "products").await;
    assert!(
        after.tenants.is_empty(),
        "resume must finalize the existing deleting row"
    );
    assert_eq!(after.deployments, before.deployments);
    assert_eq!(after.replicas, before.replicas);
    assert_eq!(after.operations, before.operations);
}

#[tokio::test]
async fn delete_index_remote_failure_rolls_back_deleting_intent() {
    let Some(db) = connect_and_migrate("catalog_route_delete_remote_failure").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Delete Failure", "delete-failure@test.com");
    let vm_id = seed_delete_route_target(&db.pool, customer.id, "products").await;
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&shared_vm_node_secret_id(vm_id), "us-east-1")
        .await
        .expect("seed shared VM node secret");
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    http_client.push_error(ProxyError::FlapjackError {
        status: 500,
        message: "injected delete failure".to_string(),
    });
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let app = route_test_app_with_node_secret_manager(
        route_pool,
        customer_repo,
        http_client.clone(),
        node_secret_manager,
    );
    let before = route_delete_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(before.tenants.len(), 1);
    let before_identity = load_target_identity(&db.pool, customer.id, "products").await;

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index response");

    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(http_client.request_count(), 1);
    assert_eq!(
        load_target_identity(&db.pool, customer.id, "products").await,
        before_identity,
        "remote failure must restore the original tenant identity"
    );
    let after = route_delete_snapshot(&db.pool, customer.id, "products").await;
    assert_eq!(after.tenants, before.tenants);
    assert_eq!(after.deployments, before.deployments);
    assert_eq!(after.replicas, before.replicas);
    assert_eq!(after.operations, before.operations);
}

#[tokio::test]
async fn create_index_on_shared_vm_rejects_active_import_reservation() {
    assert_create_route_refuses_reservation(
        "catalog_lifecycle_route_create_import_blocks",
        ActiveReservationKind::Import,
    )
    .await;
}

#[tokio::test]
async fn create_index_on_shared_vm_rejects_active_replace_reservation() {
    assert_create_route_refuses_reservation(
        "catalog_lifecycle_route_create_replace_blocks",
        ActiveReservationKind::Replacement,
    )
    .await;
}

#[tokio::test]
async fn delete_index_rejects_active_import_reservation() {
    assert_delete_route_refuses_reservation(
        "catalog_lifecycle_route_delete_import_blocks",
        ActiveReservationKind::Import,
    )
    .await;
}

#[tokio::test]
async fn delete_index_rejects_active_replace_reservation() {
    assert_delete_route_refuses_reservation(
        "catalog_lifecycle_route_delete_replace_blocks",
        ActiveReservationKind::Replacement,
    )
    .await;
}

#[tokio::test]
async fn seed_index_rejects_active_import_reservation() {
    assert_seed_index_rejects_active_import_reservation().await;
}

async fn assert_seed_index_rejects_active_import_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_admin_seed_blocks").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer("Admin Seed", "seed@test.com");
    insert_active_customer(&db.pool, customer.id, 1).await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create(import_job(customer.id, "products", "admin-seed-import"))
        .await
        .expect("active import reservation");
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(db.pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer.id).await;
    let before_deployments = deployment_rows(&db.pool, customer.id).await;

    let response = app
        .oneshot(seed_index_request(customer.id, "products", None))
        .await
        .expect("seed index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0);
    assert_eq!(tenant_rows(&db.pool, customer.id).await, before_tenants);
    assert_eq!(
        deployment_rows(&db.pool, customer.id).await,
        before_deployments
    );
}

#[tokio::test]
async fn seed_index_publishes_provisioning_intent_before_remote_secret_work() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_admin_seed_intent_before_remote").await
    else {
        return;
    };
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Admin Seed", "seed-intent@test.com");
    insert_active_customer(&db.pool, customer.id, 1).await;
    let route_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let node_secret_manager = Arc::new(ObservingSeedSecretManager::new(
        route_pool.clone(),
        customer.id,
        "products",
    ));
    let app = route_test_app_with_node_secret_manager(
        route_pool.clone(),
        customer_repo,
        http_client.clone(),
        node_secret_manager.clone(),
    );

    let response = app
        .oneshot(seed_index_request(
            customer.id,
            "products",
            Some("https://seed-intent.invalid"),
        ))
        .await
        .expect("seed index response");

    let status = response.status();
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("read seed response");
    assert_eq!(
        status,
        StatusCode::CREATED,
        "seed response body: {}",
        String::from_utf8_lossy(&body)
    );
    assert_eq!(
        node_secret_manager.observed_tiers().first(),
        Some(&Some("provisioning".to_string())),
        "admin seed must publish its operation-owned provisioning intent before remote secret work"
    );
    assert_eq!(http_client.request_count(), 0);
    let tenant = PgTenantRepo::new(db.pool.clone())
        .find_raw(customer.id, "products")
        .await
        .expect("load seeded tenant")
        .expect("seeded tenant exists");
    assert_eq!(tenant.tier, "active");
    assert!(
        tenant.vm_id.is_some(),
        "flapjack-backed seed should publish the prepared VM placement"
    );
}

#[tokio::test]
async fn resolve_existing_seed_index_rejects_active_replace_reservation() {
    assert_resolve_existing_seed_index_rejects_active_replace_reservation().await;
}

async fn assert_resolve_existing_seed_index_rejects_active_replace_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_admin_resolve_blocks").await else {
        return;
    };
    let customer_repo = mock_repo();
    let customer = customer_repo.seed_verified_shared_customer("Admin Resolve", "resolve@test.com");
    insert_replace_target(&db.pool, customer.id, "products").await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create_replace(replace_job(
            customer.id,
            "products",
            "admin-resolve-replace",
        ))
        .await
        .expect("active replace reservation");
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(db.pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer.id).await;
    let before_deployments = deployment_rows(&db.pool, customer.id).await;

    let response = app
        .oneshot(seed_index_request(
            customer.id,
            "products",
            Some("https://route-resolve.invalid"),
        ))
        .await
        .expect("resolve existing seed response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0);
    assert_eq!(tenant_rows(&db.pool, customer.id).await, before_tenants);
    assert_eq!(
        deployment_rows(&db.pool, customer.id).await,
        before_deployments
    );
}

// ---------------------------------------------------------------------------
// Stage 2 service-window race harness
//
// Both replica routing and region-failover promotion run their durable
// mutations behind an `IndexLifecycleLease` guard. While that guard is held it
// takes the catalog-target advisory lock, so any competing import/replacement
// admission from another connection fails fast with
// `destination_conflict` (pg_try_advisory_xact_lock returns false). The
// helpers below drive that window deterministically: a pause hook fires inside
// the held guard, snapshots the not-yet-committed state, and proves both
// admission paths are excluded before the service mutation completes.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
struct ServiceWindowSnapshot {
    tenants: Vec<TenantRowSnapshot>,
    replicas: Vec<ReplicaRowSnapshot>,
    operations: Vec<ImportOperationRowSnapshot>,
}

async fn service_window_snapshot(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
) -> ServiceWindowSnapshot {
    ServiceWindowSnapshot {
        tenants: tenant_rows(pool, customer_id).await,
        replicas: replica_rows(pool, customer_id, target).await,
        operations: import_operation_rows(pool, customer_id, target).await,
    }
}

/// Attempt both catalog admission paths (create-import and replace) against a
/// target whose service-owned lifecycle guard is currently held, and assert
/// each is refused with the exact stable `destination_conflict` code.
async fn assert_service_window_blocks_admission(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key_prefix: &str,
) {
    assert_service_window_blocks_admission_with_code(
        pool,
        customer_id,
        target,
        key_prefix,
        "destination_conflict",
    )
    .await;
}

async fn assert_service_window_blocks_admission_with_code(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key_prefix: &str,
    expected_code: &str,
) {
    assert_service_window_blocks_admission_with_codes(
        pool,
        customer_id,
        target,
        key_prefix,
        expected_code,
        expected_code,
    )
    .await;
}

async fn assert_service_window_blocks_admission_with_codes(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key_prefix: &str,
    expected_import_code: &str,
    expected_replace_code: &str,
) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    let import = repo
        .create(import_job(
            customer_id,
            target,
            &format!("{key_prefix}-import"),
        ))
        .await;
    assert!(
        admission_refusal_code(&import) == Some(expected_import_code),
        "open service window must block competing import admission with {expected_import_code}, got {import:?}"
    );
    let replace = repo
        .create_replace(replace_job(
            customer_id,
            target,
            &format!("{key_prefix}-replace"),
        ))
        .await;
    assert!(
        admission_refusal_code(&replace) == Some(expected_replace_code),
        "open service window must block competing replacement admission with {expected_replace_code}, got {replace:?}"
    );
}

async fn assert_restore_intent_blocks_admission(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key_prefix: &str,
) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    let import = repo
        .create(import_job(
            customer_id,
            target,
            &format!("{key_prefix}-import"),
        ))
        .await;
    assert!(
        admission_refusal_code(&import) == Some("destination_changed"),
        "persisted restore intent must block competing import admission with destination_changed, got {import:?}"
    );
    let replace = repo
        .create_replace(replace_job(
            customer_id,
            target,
            &format!("{key_prefix}-replace"),
        ))
        .await;
    assert!(
        admission_refusal_code(&replace) == Some("destination_changed"),
        "persisted restore intent must block competing replacement admission with destination_changed, got {replace:?}"
    );
}

/// Pause-hook body: snapshot the paused (uncommitted) service-window state, then
/// prove both admission paths are excluded while the guard is held.
async fn capture_pause_and_assert_admission_blocked(
    probe_pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    key_prefix: &str,
    paused_slot: &Arc<Mutex<Option<ServiceWindowSnapshot>>>,
) {
    let snapshot = service_window_snapshot(probe_pool, customer_id, target).await;
    *paused_slot.lock().unwrap() = Some(snapshot);
    assert_service_window_blocks_admission(probe_pool, customer_id, target, key_prefix).await;
}

/// Build the deterministic `LifecycleGuardPauseHook` shared by the
/// service-window race tests. While the service-owned lifecycle guard is
/// paused, it snapshots the service window into the returned slot (so the
/// caller can prove nothing committed before the guard released) and asserts
/// competing import/replacement admission is blocked from a separate schema
/// pool. `extra` runs an additional in-window assertion (e.g. no premature
/// failover-success alert) after the admission check; pass `None` when the test
/// needs no service-specific follow-up.
async fn admission_block_pause_hook(
    schema: &str,
    customer_id: Uuid,
    target: &'static str,
    key_prefix: &'static str,
    extra: Option<LifecycleGuardPauseHook>,
) -> (
    LifecycleGuardPauseHook,
    Arc<Mutex<Option<ServiceWindowSnapshot>>>,
) {
    let paused_slot: Arc<Mutex<Option<ServiceWindowSnapshot>>> = Arc::new(Mutex::new(None));
    let probe_pool = pool_in_schema(schema).await;
    let slot = Arc::clone(&paused_slot);
    let hook: LifecycleGuardPauseHook = Arc::new(move || {
        let probe_pool = probe_pool.clone();
        let paused_slot = Arc::clone(&slot);
        let extra = extra.clone();
        Box::pin(async move {
            capture_pause_and_assert_admission_blocked(
                &probe_pool,
                customer_id,
                target,
                key_prefix,
                &paused_slot,
            )
            .await;
            if let Some(extra) = extra {
                extra().await;
            }
        })
    });
    (hook, paused_slot)
}

/// Set up a replica-service target that already carries an active catalog
/// reservation of the given kind. Import (create) admission is only accepted
/// while the logical target is unowned, so the two kinds seed in opposite order:
/// the import reservation is taken before the tenant exists, the replacement
/// reservation after.
async fn setup_replica_target_with_active_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    kind: ActiveReservationKind,
    key: &str,
) -> (Uuid, Uuid) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    match kind {
        ActiveReservationKind::Import => {
            insert_active_customer(pool, customer_id, 1).await;
            repo.create(import_job(customer_id, target, key))
                .await
                .expect("seed active import reservation");
            insert_replica_service_target_without_customer(pool, customer_id, target).await
        }
        ActiveReservationKind::Replacement => {
            let vms = insert_replica_service_target(pool, customer_id, target).await;
            repo.create_replace(replace_job(customer_id, target, key))
                .await
                .expect("seed active replacement reservation");
            vms
        }
    }
}

/// Failover-target variant of [`setup_replica_target_with_active_reservation`].
async fn setup_failover_target_with_active_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    kind: ActiveReservationKind,
    key: &str,
) -> (Uuid, Uuid, Uuid) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    match kind {
        ActiveReservationKind::Import => {
            insert_active_customer(pool, customer_id, 1).await;
            repo.create(import_job(customer_id, target, key))
                .await
                .expect("seed active import reservation");
            insert_region_failover_target_without_customer(pool, customer_id, target).await
        }
        ActiveReservationKind::Replacement => {
            let ids = insert_region_failover_target(pool, customer_id, target).await;
            repo.create_replace(replace_job(customer_id, target, key))
                .await
                .expect("seed active replacement reservation");
            ids
        }
    }
}

/// Build a `ReplicaService` wired to the canonical lifecycle guard over `pool`.
fn guarded_replica_service(pool: &PgPool) -> ReplicaService {
    ReplicaService::new(
        Arc::new(PgIndexReplicaRepo::new(pool.clone())),
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
        RegionConfig::defaults(),
    )
}

/// Build a `RegionFailoverMonitor` wired to the canonical lifecycle guard over
/// `pool`, with a single-cycle failover threshold for deterministic tests.
fn guarded_region_failover_monitor(
    pool: &PgPool,
    alert_service: Arc<MockAlertService>,
) -> RegionFailoverMonitor {
    RegionFailoverMonitor::new(
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgIndexReplicaRepo::new(pool.clone())),
        alert_service,
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
        RegionFailoverConfig {
            cycle_interval_secs: 30,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    )
}

/// Repoint a VM's health-probe URL so the failover health function can single it
/// out as down. `insert_vm_in_region` gives every VM the same placeholder URL,
/// which cannot distinguish source from replica for a real promotion.
async fn set_vm_flapjack_url(pool: &PgPool, vm_id: Uuid, url: &str) {
    sqlx::query("UPDATE vm_inventory SET flapjack_url = $2 WHERE id = $1")
        .bind(vm_id)
        .bind(url)
        .execute(pool)
        .await
        .expect("repoint vm flapjack url");
}

#[tokio::test]
async fn replica_service_create_replica_rejects_active_replace_reservation() {
    assert_replica_service_create_replica_rejects_active_reservation().await;
}

async fn assert_replica_service_create_replica_rejects_active_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_replica_create_blocks").await else {
        return;
    };
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        let customer = Uuid::new_v4();
        setup_replica_target_with_active_reservation(
            &db.pool,
            customer,
            "products",
            kind,
            &format!("replica-create-{}", kind.label()),
        )
        .await;
        let service = guarded_replica_service(&db.pool);

        let before = service_window_snapshot(&db.pool, customer, "products").await;
        let result = service
            .create_replica(customer, "products", "eu-central-1")
            .await;

        assert!(
            matches!(result, Err(ReplicaError::DestinationConflict)),
            "active {} reservation must block replica creation, got {result:?}",
            kind.label()
        );
        assert_eq!(
            service_window_snapshot(&db.pool, customer, "products").await,
            before,
            "refused replica creation ({}) must not mutate tenant, replica, or import-operation state",
            kind.label()
        );
    }
}

/// Create-replica opens a service window: while the lifecycle guard is held,
/// both import and replacement admission are excluded before the replica row is
/// committed; on success exactly one provisioning replica exists and no import
/// operation was admitted. Driven under the canonical
/// `replica_create_remove_races_after_intent_before_remote_work` selection in
/// `catalog_lifecycle_lease_remote_races`.
async fn assert_replica_create_race_after_intent() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_replica_create_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replica_service_target(&db.pool, customer, "products").await;

    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "replica-create-race",
        None,
    )
    .await;

    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = guarded_replica_service(&service_pool).with_guard_pause_hook_for_tests(hook);

    let before = service_window_snapshot(&db.pool, customer, "products").await;
    assert!(
        before.replicas.is_empty(),
        "fixture starts with no replica rows"
    );
    assert!(
        before.operations.is_empty(),
        "fixture starts with no import operation rows"
    );

    let replica = service
        .create_replica(customer, "products", "eu-central-1")
        .await
        .expect("service-window owner creates the replica after excluding admission");

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("pause hook recorded a paused snapshot");
    assert_eq!(
        paused.replicas, before.replicas,
        "guarded window must not commit the replica row before it completes"
    );
    assert_eq!(
        paused.operations, before.operations,
        "guarded window must not admit an import operation"
    );
    assert_eq!(
        paused.tenants, before.tenants,
        "guarded create must not mutate the primary tenant before completion"
    );

    let after = service_window_snapshot(&db.pool, customer, "products").await;
    assert_eq!(
        after.tenants, before.tenants,
        "create replica must not mutate the primary tenant"
    );
    assert_eq!(
        after.operations, before.operations,
        "create replica must not admit an import operation"
    );
    assert_eq!(
        after.replicas.len(),
        1,
        "exactly one new replica exists after success"
    );
    let row = &after.replicas[0];
    assert_eq!(row.id, replica.id);
    assert_eq!(row.customer_id, customer);
    assert_eq!(row.tenant_id, "products");
    assert_eq!(row.replica_region, "eu-central-1");
    assert_eq!(
        row.status, "provisioning",
        "a freshly created replica starts in provisioning status"
    );
}

#[tokio::test]
async fn replica_service_remove_replica_rejects_active_replace_reservation() {
    assert_replica_service_remove_replica_rejects_active_reservation().await;
}

async fn assert_replica_service_remove_replica_rejects_active_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_replica_remove_blocks").await else {
        return;
    };
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        let customer = Uuid::new_v4();
        let (primary_vm_id, replica_vm_id) = setup_replica_target_with_active_reservation(
            &db.pool,
            customer,
            "products",
            kind,
            &format!("replica-remove-{}", kind.label()),
        )
        .await;
        let replica = PgIndexReplicaRepo::new(db.pool.clone())
            .create(
                customer,
                "products",
                primary_vm_id,
                replica_vm_id,
                "eu-central-1",
            )
            .await
            .expect("seed replica");
        let service = guarded_replica_service(&db.pool);

        let before = service_window_snapshot(&db.pool, customer, "products").await;
        let result = service
            .remove_replica(customer, "products", replica.id)
            .await;

        assert!(
            matches!(result, Err(ReplicaError::DestinationConflict)),
            "active {} reservation must block replica removal, got {result:?}",
            kind.label()
        );
        assert_eq!(
            service_window_snapshot(&db.pool, customer, "products").await,
            before,
            "refused replica removal ({}) must not mutate tenant, replica, or import-operation state",
            kind.label()
        );
    }
}

/// Remove-replica opens a service window: while the lifecycle guard is held,
/// both import and replacement admission are excluded before the replica row is
/// deleted; on success only the targeted replica is removed and unrelated
/// replica rows are untouched. Driven under the canonical
/// `replica_create_remove_races_after_intent_before_remote_work` selection in
/// `catalog_lifecycle_lease_remote_races`.
async fn assert_replica_remove_race_after_intent() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_replica_remove_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    let (primary_vm_id, replica_vm_id) =
        insert_replica_service_target(&db.pool, customer, "products").await;
    let replica_repo = PgIndexReplicaRepo::new(db.pool.clone());
    let target_replica = replica_repo
        .create(
            customer,
            "products",
            primary_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("seed replica to remove");
    // A second, unrelated replica on a different VM/region that must survive.
    let other_vm_id = Uuid::new_v4();
    insert_vm_in_region(&db.pool, other_vm_id, "us-west-1").await;
    let other_replica = replica_repo
        .create(
            customer,
            "products",
            primary_vm_id,
            other_vm_id,
            "us-west-1",
        )
        .await
        .expect("seed unrelated replica");

    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "replica-remove-race",
        None,
    )
    .await;

    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = guarded_replica_service(&service_pool).with_guard_pause_hook_for_tests(hook);

    let before = service_window_snapshot(&db.pool, customer, "products").await;
    assert_eq!(
        before.replicas.len(),
        2,
        "fixture seeds the target replica plus one unrelated replica"
    );

    service
        .remove_replica(customer, "products", target_replica.id)
        .await
        .expect("service-window owner removes the replica after excluding admission");

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("pause hook recorded a paused snapshot");
    assert_eq!(
        paused.replicas, before.replicas,
        "guarded window must not delete or restatus the replica before it completes"
    );
    assert_eq!(
        paused.operations, before.operations,
        "guarded window must not admit an import operation"
    );
    assert_eq!(
        paused.tenants, before.tenants,
        "guarded remove must not mutate the primary tenant before completion"
    );

    let after = service_window_snapshot(&db.pool, customer, "products").await;
    assert_eq!(
        after.tenants, before.tenants,
        "remove replica must not mutate the primary tenant"
    );
    assert_eq!(
        after.operations, before.operations,
        "remove replica must not admit an import operation"
    );
    assert_eq!(
        after.replicas.len(),
        1,
        "only the targeted replica is removed on success"
    );
    let surviving = &after.replicas[0];
    assert_eq!(
        surviving.id, other_replica.id,
        "the unrelated replica must survive removal"
    );
    let before_other = before
        .replicas
        .iter()
        .find(|r| r.id == other_replica.id)
        .expect("unrelated replica present before removal");
    assert_eq!(
        surviving, before_other,
        "removal must not mutate any field of the unrelated replica row"
    );
}

#[tokio::test]
async fn region_failover_rejects_active_replace_reservation() {
    assert_region_failover_rejects_active_reservation().await;
}

async fn assert_region_failover_rejects_active_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_failover_blocks").await else {
        return;
    };
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        let customer = Uuid::new_v4();
        let (primary_vm_id, _replica_vm_id, _replica_id) =
            setup_failover_target_with_active_reservation(
                &db.pool,
                customer,
                "products",
                kind,
                &format!("failover-{}", kind.label()),
            )
            .await;
        // Mark the source VM's health URL so the health function can single it
        // out; without this every VM shares one placeholder URL and failover
        // would never fire, making the guard-skip path untested.
        set_vm_flapjack_url(&db.pool, primary_vm_id, "https://source-down.invalid").await;
        let alert_service = mock_alert_service();
        let monitor = guarded_region_failover_monitor(&db.pool, Arc::clone(&alert_service));

        let before = service_window_snapshot(&db.pool, customer, "products").await;

        monitor
            .run_cycle_with_health(|url| !url.contains("source-down"))
            .await;

        assert_eq!(
            service_window_snapshot(&db.pool, customer, "products").await,
            before,
            "active {} reservation must make guarded promotion log-and-skip without mutating tenant, replica, or import-operation state",
            kind.label()
        );
        assert!(
            alert_service
                .recorded_alerts()
                .iter()
                .all(|alert| !alert.title.starts_with("Index failed over")),
            "a reservation-blocked promotion must not emit a failover-success alert"
        );
    }
}

/// Failover promotion opens a service window: while the lifecycle guard is held,
/// both import and replacement admission are excluded before the tenant is
/// repointed and the replica suspended; on success the tenant is promoted onto
/// the replica VM and the promoted replica is suspended. Driven under the
/// canonical `region_failover_races_after_intent_before_remote_work` selection
/// in `catalog_lifecycle_lease_remote_races`.
async fn assert_region_failover_promotion_race_after_intent() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_failover_promotion_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    let (primary_vm_id, replica_vm_id, replica_id) =
        insert_region_failover_target(&db.pool, customer, "products").await;
    set_vm_flapjack_url(&db.pool, primary_vm_id, "https://source-down.invalid").await;
    // An unrelated replica of the same index that is NOT a failover candidate
    // (still provisioning, so `try_failover_tenant` filters it out before
    // picking the promotion target). It must survive the promotion untouched.
    let unrelated_vm_id = Uuid::new_v4();
    insert_vm_in_region(&db.pool, unrelated_vm_id, "us-west-1").await;
    let unrelated_replica = PgIndexReplicaRepo::new(db.pool.clone())
        .create(
            customer,
            "products",
            primary_vm_id,
            unrelated_vm_id,
            "us-west-1",
        )
        .await
        .expect("seed unrelated non-candidate replica");

    let alert_service = mock_alert_service();
    // Failover-specific in-window assertion: the success alert must not fire
    // until the guarded promotion completes.
    let no_premature_alert: LifecycleGuardPauseHook = {
        let alert_service = Arc::clone(&alert_service);
        Arc::new(move || {
            let alert_service = Arc::clone(&alert_service);
            Box::pin(async move {
                assert!(
                    alert_service
                        .recorded_alerts()
                        .iter()
                        .all(|alert| !alert.title.starts_with("Index failed over")),
                    "guarded promotion must not emit a failover-success alert before it completes"
                );
            })
        })
    };
    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "failover-promotion-race",
        Some(no_premature_alert),
    )
    .await;

    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let monitor = guarded_region_failover_monitor(&service_pool, Arc::clone(&alert_service))
        .with_guard_pause_hook_for_tests(hook);

    let before = service_window_snapshot(&db.pool, customer, "products").await;
    let before_deployments = deployment_rows(&db.pool, customer).await;
    assert_eq!(before.tenants.len(), 1, "fixture seeds one tenant");
    assert_eq!(
        before.tenants[0].vm_id,
        Some(primary_vm_id),
        "tenant starts on the source VM"
    );
    assert_eq!(
        before.replicas.len(),
        2,
        "fixture seeds the active promotion target plus one unrelated replica"
    );
    let before_target = before
        .replicas
        .iter()
        .find(|r| r.id == replica_id)
        .expect("promotion target present before failover");
    assert_eq!(
        before_target.status, "active",
        "the failover promotion target starts active"
    );

    monitor
        .run_cycle_with_health(|url| !url.contains("source-down"))
        .await;

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("promotion pause hook recorded a paused snapshot");
    assert_eq!(
        paused.tenants, before.tenants,
        "guarded promotion must not repoint the tenant vm_id before completion"
    );
    assert_eq!(
        paused.replicas, before.replicas,
        "guarded promotion must not suspend the replica before completion"
    );
    assert_eq!(
        paused.operations, before.operations,
        "guarded promotion must not admit an import operation"
    );

    let after = service_window_snapshot(&db.pool, customer, "products").await;
    assert_eq!(after.tenants.len(), 1);
    let tenant = &after.tenants[0];
    assert_eq!(
        tenant.vm_id,
        Some(replica_vm_id),
        "tenant is promoted onto the replica VM"
    );
    assert_eq!(
        tenant.tier, before.tenants[0].tier,
        "promotion must not change the tenant tier"
    );
    assert_eq!(
        tenant.service_type, before.tenants[0].service_type,
        "promotion must not change the tenant service_type"
    );
    assert_eq!(
        tenant.deployment_id, before.tenants[0].deployment_id,
        "promotion must not change the tenant deployment identity"
    );
    assert_eq!(
        after.replicas.len(),
        2,
        "promotion suspends the target but leaves the unrelated replica in place"
    );
    let after_target = after
        .replicas
        .iter()
        .find(|r| r.id == replica_id)
        .expect("promotion target present after failover");
    assert_eq!(
        after_target.status, "suspended",
        "the promoted replica is suspended"
    );
    let after_unrelated = after
        .replicas
        .iter()
        .find(|r| r.id == unrelated_replica.id)
        .expect("unrelated replica present after failover");
    let before_unrelated = before
        .replicas
        .iter()
        .find(|r| r.id == unrelated_replica.id)
        .expect("unrelated replica present before failover");
    assert_eq!(
        after_unrelated, before_unrelated,
        "promotion must not mutate any field of the unrelated replica row"
    );
    assert_eq!(
        after.operations, before.operations,
        "promotion must not admit an import operation"
    );
    assert_eq!(
        deployment_rows(&db.pool, customer).await,
        before_deployments,
        "promotion must not mutate any customer deployment row"
    );
}

#[tokio::test]
async fn restore_service_initiate_restore_rejects_active_replace_reservation() {
    assert_restore_service_initiate_restore_rejects_active_reservation().await;
}

async fn assert_restore_service_initiate_restore_rejects_active_reservation() {
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        assert_restore_initiation_rejects_active_reservation(kind).await;
    }
}

async fn assert_restore_initiation_rejects_active_reservation(kind: ActiveReservationKind) {
    let schema = format!("catalog_lifecycle_restore_initiate_blocks_{}", kind.label());
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    match kind {
        ActiveReservationKind::Import => {
            insert_active_customer(&db.pool, customer, 1).await;
            PgAlgoliaImportJobRepo::new(db.pool.clone())
                .create(import_job(customer, "products", "restore-import"))
                .await
                .expect("active import reservation");
            insert_authenticated_target_row(&db.pool, customer, "products").await;
        }
        ActiveReservationKind::Replacement => {
            insert_replace_target(&db.pool, customer, "products").await;
            PgAlgoliaImportJobRepo::new(db.pool.clone())
                .create_replace(replace_job(customer, "products", "restore-replace"))
                .await
                .expect("active replace reservation");
        }
    }
    insert_restore_service_target(&db.pool, customer, "products").await;
    let (service, _restore_job_repo) =
        restore_service(&db.pool, Arc::new(NoopRestoreNodeClient), None);
    let before_tenants = tenant_rows(&db.pool, customer).await;
    let before_snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    let before_restore_job_count = restore_job_rows(&db.pool, customer, "products").await.len();
    let before_operations = import_operation_rows(&db.pool, customer, "products").await;

    let result = service.initiate_restore(customer, "products").await;

    assert!(
        matches!(result, Err(RestoreError::DestinationConflict)),
        "active {} reservation must block restore initiation, got {result:?}",
        kind.label()
    );
    assert_eq!(
        tenant_rows(&db.pool, customer).await,
        before_tenants,
        "restore initiation must not mutate tenant state after reservation refusal"
    );
    assert_eq!(
        cold_snapshot_rows(&db.pool, customer, "products").await,
        before_snapshots,
        "restore initiation refusal must not mutate cold snapshot rows"
    );
    assert_eq!(
        restore_job_rows(&db.pool, customer, "products").await.len(),
        before_restore_job_count,
        "restore initiation must not create a restore job after reservation refusal"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer, "products").await,
        before_operations,
        "losing restore admission must not create import operation rows"
    );
}

/// Owner-wins restore-initiate race body: while the initiation guard is open the
/// restore intent is not externally visible and competing admission is excluded.
/// Driven under the canonical
/// `restore_lifecycle_races_after_intent_before_remote_work_initiate` selection
/// in `catalog_lifecycle_lease_remote_races`.
async fn assert_restore_initiate_race_after_intent() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_restore_initiate_window").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_restore_service_target(&db.pool, customer, "products").await;
    let before = service_window_snapshot(&db.pool, customer, "products").await;
    let before_snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "restore-init-window",
        None,
    )
    .await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let (service, _restore_job_repo) =
        restore_service(&service_pool, Arc::new(NoopRestoreNodeClient), Some(hook));

    let response = service
        .initiate_restore(customer, "products")
        .await
        .expect("restore initiation succeeds after guard release");

    assert!(response.created_new_job);
    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("restore initiation guard hook must run");
    assert_eq!(
        paused, before,
        "restore intent must not be externally visible before guard release"
    );
    let jobs = restore_job_rows(&db.pool, customer, "products").await;
    assert_eq!(jobs.len(), 1, "restore initiation must create one job");
    assert_eq!(jobs[0].id, response.job_id);
    assert_eq!(jobs[0].status, "queued");
    assert_eq!(jobs[0].idempotency_key, format!("{customer}:products"));
    let after_tenants = tenant_rows(&db.pool, customer).await;
    assert_eq!(after_tenants.len(), 1);
    assert_eq!(after_tenants[0].tier, "restoring");
    assert_eq!(
        after_tenants[0].deployment_id,
        before.tenants[0].deployment_id
    );
    assert_eq!(
        after_tenants[0].service_type,
        before.tenants[0].service_type
    );
    assert_eq!(
        after_tenants[0].cold_snapshot_id,
        before.tenants[0].cold_snapshot_id
    );
    assert_eq!(after_tenants[0].vm_id, None);
    assert_eq!(
        cold_snapshot_rows(&db.pool, customer, "products").await,
        before_snapshots
    );
    assert!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "restore initiation must not admit import operation rows"
    );
}

/// Owner-wins restore-execute race body: the persisted restore intent excludes
/// competing admission at the pre-remote boundary before any remote import.
/// Driven under the canonical
/// `restore_lifecycle_races_after_intent_before_remote_work` selection in
/// `catalog_lifecycle_lease_remote_races`.
async fn assert_restore_execute_race_after_intent() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_restore_execute_intent").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_restore_service_target(&db.pool, customer, "products").await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let (init_service, _restore_job_repo) =
        restore_service(&service_pool, Arc::new(NoopRestoreNodeClient), None);
    let response = init_service
        .initiate_restore(customer, "products")
        .await
        .expect("create restore intent");
    let snapshot = cold_snapshot_rows(&db.pool, customer, "products")
        .await
        .into_iter()
        .next()
        .expect("restore snapshot exists");
    let object_store = Arc::new(InMemoryObjectStore::new());
    object_store
        .put(&snapshot.object_key, b"restore payload")
        .await
        .expect("seed restore object");
    let node_client = Arc::new(CountingRestoreNodeClient::default());
    let secret_manager = Arc::new(RestoreIntentBoundarySecretManager::new(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        node_client.clone(),
    ));
    let (execute_service, _restore_job_repo) = restore_service_with_dependencies(
        &service_pool,
        node_client.clone(),
        secret_manager.clone(),
        object_store,
        None,
    );

    execute_service.execute_restore(response.job_id).await;

    assert_eq!(
        secret_manager.boundary_call_count(),
        1,
        "execute must prove admission exclusion at the pre-remote boundary"
    );
    assert_eq!(
        node_client.remote_call_count(),
        2,
        "successful restore should import and verify after the boundary proof"
    );
    assert!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "boundary admission probes must not leave losing import-operation rows"
    );
    let job = restore_job_rows(&db.pool, customer, "products")
        .await
        .into_iter()
        .next()
        .expect("restore job remains");
    assert_eq!(job.status, "completed");
}

#[tokio::test]
async fn restore_execute_restore_inner_rejects_identity_drift() {
    for drift in identity_drift_denominator().iter().copied() {
        assert_restore_execute_rejects_identity_drift(drift).await;
    }
}

async fn assert_restore_execute_rejects_identity_drift(drift: RestoreIdentityDrift) {
    let schema = format!("catalog_lifecycle_restore_execute_drift_{}", drift.label());
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_restore_service_target(&db.pool, customer, "products").await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let (init_service, _restore_job_repo) =
        restore_service(&service_pool, Arc::new(NoopRestoreNodeClient), None);
    let response = init_service
        .initiate_restore(customer, "products")
        .await
        .expect("create restore intent");
    let snapshot = cold_snapshot_rows(&db.pool, customer, "products")
        .await
        .into_iter()
        .next()
        .expect("restore snapshot exists");
    let object_store = Arc::new(InMemoryObjectStore::new());
    object_store
        .put(&snapshot.object_key, b"restore payload")
        .await
        .expect("seed restore object");
    let node_client = Arc::new(CountingRestoreNodeClient::default());
    node_client.drift_identity_during_import(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        drift,
    );
    let (execute_service, _restore_job_repo) = restore_service_with_dependencies(
        &service_pool,
        node_client.clone(),
        mock_node_secret_manager(),
        object_store,
        None,
    );

    let result = execute_service.execute_restore_inner(response.job_id).await;

    assert!(
        matches!(result, Err(RestoreError::DestinationChanged)),
        "restore execute stale {drift:?} finalizer must return destination_changed, got {result:?}"
    );
    assert_eq!(
        node_client.remote_call_count(),
        2,
        "identity drift is injected after import and before final publication"
    );
    let drifted_identity = load_target_identity(&db.pool, customer, "products").await;
    let expected_identity = node_client.take_drifted_identity();
    assert_eq!(
        drifted_identity, expected_identity,
        "stale restore finalizer must preserve newer {drift:?} ownership"
    );
    let job = restore_job_rows(&db.pool, customer, "products")
        .await
        .into_iter()
        .next()
        .expect("restore job remains after stale execute");
    assert_eq!(
        job.status, "importing",
        "stale execute finalizer must not mark the restore job completed"
    );
    assert!(job.completed_at.is_none());
    assert!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "stale restore finalizer must not leave import-operation rows"
    );
}

#[tokio::test]
async fn restore_handle_restore_failure_rejects_identity_drift() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_restore_failure_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_restore_service_target(&db.pool, customer, "products").await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let (service, _restore_job_repo) =
        restore_service(&service_pool, Arc::new(NoopRestoreNodeClient), None);
    let response = service
        .initiate_restore(customer, "products")
        .await
        .expect("create restore intent");
    let expected_identity =
        apply_restore_identity_drift(&db.pool, customer, "products", RestoreIdentityDrift::Tier)
            .await;

    service
        .handle_restore_failure(response.job_id, "injected restore failure")
        .await;

    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(
        identity_after, expected_identity,
        "stale restore rollback must preserve newer tenant identity"
    );
    let job = restore_job_rows(&db.pool, customer, "products")
        .await
        .into_iter()
        .next()
        .expect("restore job remains after failure");
    assert_eq!(
        job.status, "failed",
        "restore failure must still record the job failure"
    );
    assert_eq!(job.error.as_deref(), Some("injected restore failure"));
}

#[tokio::test]
async fn cold_tier_snapshot_rejects_active_replace_reservation() {
    assert_cold_tier_snapshot_rejects_active_replace_reservation().await;
}

async fn assert_cold_tier_snapshot_rejects_active_replace_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_blocks").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create_replace(replace_job(customer, "products", "cold-tier-replace"))
        .await
        .expect("active replace reservation");
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    seed_cold_tier_refusal_controls(&db.pool, customer, source_vm_id).await;
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let (service, object_store) = observable_cold_tier_service(&db.pool, node_client.clone());
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;
    let before = service_window_snapshot(&db.pool, customer, "products").await;
    let before_snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(
        before.tenants.len(),
        2,
        "fixture includes unrelated tenant control"
    );
    assert_eq!(before.replicas.len(), 1, "fixture includes routing control");
    assert_eq!(
        before.operations.len(),
        1,
        "fixture includes winning reservation"
    );

    let result = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;

    assert!(
        matches!(result, Err(ColdTierError::DestinationConflict)),
        "active replacement reservation must block cold-tier snapshot intent, got {result:?}"
    );
    assert_eq!(
        node_client.remote_call_count(),
        0,
        "cold-tier refusal must happen before export or source eviction"
    );
    assert_eq!(
        object_store.put_call_count(),
        0,
        "cold-tier refusal must happen before upload"
    );
    assert_eq!(
        cold_snapshot_rows(&db.pool, customer, "products").await,
        before_snapshots,
        "cold-tier refusal must not create snapshot intent rows"
    );
    assert_eq!(
        service_window_snapshot(&db.pool, customer, "products").await,
        before,
        "cold-tier refusal must preserve tenant, routing, reservation, and unrelated control rows byte-for-byte"
    );
}

/// An active create-import reservation must block the cold-tier snapshot intent
/// before any export, upload, or eviction — the import-reservation twin of
/// [`cold_tier_snapshot_rejects_active_replace_reservation`].
#[tokio::test]
async fn cold_tier_snapshot_rejects_active_import_reservation() {
    assert_cold_tier_snapshot_rejects_active_import_reservation().await;
}

async fn assert_cold_tier_snapshot_rejects_active_import_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_import_blocks").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    PgAlgoliaImportJobRepo::new(db.pool.clone())
        .create(import_job(customer, "products", "cold-tier-import"))
        .await
        .expect("active import reservation");
    let source_vm_id = insert_authenticated_target_row(&db.pool, customer, "products").await;
    seed_cold_tier_refusal_controls(&db.pool, customer, source_vm_id).await;
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let (service, object_store) = observable_cold_tier_service(&db.pool, node_client.clone());
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;
    let before = service_window_snapshot(&db.pool, customer, "products").await;
    let before_snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(
        before.tenants.len(),
        2,
        "fixture includes unrelated tenant control"
    );
    assert_eq!(before.replicas.len(), 1, "fixture includes routing control");
    assert_eq!(
        before.operations.len(),
        1,
        "fixture includes winning reservation"
    );

    let result = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;

    assert!(
        matches!(result, Err(ColdTierError::DestinationConflict)),
        "active import reservation must block cold-tier snapshot intent, got {result:?}"
    );
    assert_eq!(
        node_client.remote_call_count(),
        0,
        "cold-tier refusal must happen before export or source eviction"
    );
    assert_eq!(
        object_store.put_call_count(),
        0,
        "cold-tier refusal must happen before upload"
    );
    assert_eq!(
        cold_snapshot_rows(&db.pool, customer, "products").await,
        before_snapshots,
        "cold-tier refusal must not create snapshot intent rows"
    );
    assert_eq!(
        service_window_snapshot(&db.pool, customer, "products").await,
        before,
        "cold-tier refusal must preserve tenant, routing, reservation, and unrelated control rows byte-for-byte"
    );
}

/// Opening the `begin_snapshot_record` window holds the lifecycle guard: while
/// paused inside it, competing import/replacement admission is excluded and the
/// snapshot intent is not yet externally visible. After release, the committed
/// `tier = 'cold'` plus an `exporting` snapshot intent are durably visible
/// before the first remote export runs.
#[tokio::test]
async fn cold_tier_snapshot_blocks_admission_before_export() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_begin_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");

    let (hook, paused_slot) =
        admission_block_pause_hook(&db.schema, customer, "products", "cold-begin-race", None).await;
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    node_client.observe_committed_state_at_first_export(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
    );
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = cold_tier_service(&service_pool, node_client.clone())
        .with_begin_snapshot_pause_hook_for_tests(hook);
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;

    let before = service_window_snapshot(&db.pool, customer, "products").await;
    assert!(
        cold_snapshot_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "fixture starts with no cold snapshot rows"
    );

    let snapshot_id = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await
        .expect("snapshot completes after the begin window excludes admission");

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("begin pause hook recorded a snapshot");
    assert_eq!(
        paused.tenants, before.tenants,
        "begin guard must not make the tier=cold intent externally visible before it commits"
    );
    assert_eq!(
        paused.operations, before.operations,
        "begin guard must not admit an import operation"
    );

    let observed = node_client.take_export_observation();
    assert_eq!(
        observed.tier, "cold",
        "committed cold intent must be visible before the first export"
    );
    assert_eq!(
        observed.vm_id,
        Some(source_vm_id),
        "source VM remains assigned during the snapshot intent"
    );
    assert_eq!(
        observed.cold_snapshot_id, None,
        "hot-to-cold publication has not happened at export time"
    );
    assert_eq!(
        observed.snapshot_status.as_deref(),
        Some("exporting"),
        "snapshot intent is durably in the exporting state before export"
    );
    assert_eq!(
        observed.delete_calls_before_first_export, 0,
        "no source eviction can precede the first export"
    );

    assert_eq!(node_client.export_call_count(), 1);
    assert_eq!(node_client.delete_call_count(), 1);

    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(snapshots.len(), 1, "exactly one committed snapshot");
    assert_eq!(snapshots[0].id, snapshot_id);
    assert_eq!(snapshots[0].status, "completed");
}

/// Opening the `transition_tenant_to_cold_storage` window holds the lifecycle
/// guard after export/upload/finalization completed and before source eviction:
/// competing admission is excluded, the publication is not yet externally
/// visible, and eviction has not started. The success path lands the exact
/// hand-calculated final tenant/snapshot state and leaves unrelated rows intact.
#[tokio::test]
async fn cold_tier_transition_blocks_admission_before_eviction() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_transition_race").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    insert_authenticated_target_row(&db.pool, customer, "orders").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    let original_identity = load_target_identity(&db.pool, customer, "products").await;

    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let object_store = observable_object_store();
    let extra_pool = pool_in_schema(&db.schema).await;
    let extra_node = node_client.clone();
    let extra_object_store = object_store.clone();
    let extra: LifecycleGuardPauseHook = Arc::new(move || {
        let extra_pool = extra_pool.clone();
        let extra_node = extra_node.clone();
        let extra_object_store = extra_object_store.clone();
        Box::pin(async move {
            assert_eq!(
                extra_node.export_call_count(),
                1,
                "export must complete before the cold publication guard is acquired"
            );
            assert_eq!(
                extra_node.delete_call_count(),
                0,
                "source eviction must not start until the publication commits"
            );
            let snapshots = cold_snapshot_rows(&extra_pool, customer, "products").await;
            assert_eq!(snapshots.len(), 1);
            assert_eq!(
                snapshots[0].status, "completed",
                "snapshot must be finalized before the publication guard"
            );
            assert_eq!(
                extra_object_store.put_call_count(),
                1,
                "exactly one upload must finish before the publication guard"
            );
            assert_eq!(
                extra_object_store
                    .get(&snapshots[0].object_key)
                    .await
                    .expect("uploaded snapshot is present during publication pause"),
                b"snapshot",
                "the exact exported payload must already be stored before publication"
            );
        })
    });
    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "cold-transition-race",
        Some(extra),
    )
    .await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service =
        cold_tier_service_with_object_store(&service_pool, node_client.clone(), object_store)
            .with_cold_publication_pause_hook_for_tests(hook);
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;

    let before = service_window_snapshot(&db.pool, customer, "products").await;

    let snapshot_id = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await
        .expect("snapshot completes after the publication window excludes admission");

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("publication pause hook recorded a snapshot");
    let paused_products = paused
        .tenants
        .iter()
        .find(|row| row.tenant_id == "products")
        .expect("paused snapshot has the products tenant");
    assert_eq!(
        paused_products.tier, "cold",
        "begin intent is committed while the publication guard is held"
    );
    assert_eq!(
        paused_products.vm_id,
        Some(source_vm_id),
        "publication must not clear the source VM before it commits"
    );
    assert_eq!(
        paused_products.cold_snapshot_id, None,
        "publication must not attach the cold snapshot before it commits"
    );
    assert_eq!(
        paused.operations, before.operations,
        "publication guard must not admit an import operation"
    );

    let final_identity = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(final_identity.tier, "cold");
    assert_eq!(
        final_identity.vm_id, None,
        "source VM cleared after publication"
    );
    assert_eq!(final_identity.cold_snapshot_id, Some(snapshot_id));
    assert_eq!(
        final_identity.deployment_id, original_identity.deployment_id,
        "deployment is retained"
    );
    assert_eq!(
        final_identity.service_type, original_identity.service_type,
        "service type is retained"
    );

    assert_eq!(node_client.export_call_count(), 1, "exactly one export");
    assert_eq!(
        node_client.delete_call_count(),
        1,
        "exactly one source eviction"
    );
    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(snapshots.len(), 1);
    let snapshot = &snapshots[0];
    assert_eq!(snapshot.id, snapshot_id);
    assert_eq!(snapshot.customer_id, customer);
    assert_eq!(snapshot.tenant_id, "products");
    assert_eq!(snapshot.source_vm_id, source_vm_id);
    assert_eq!(snapshot.status, "completed");
    assert_eq!(
        snapshot.size_bytes, 8,
        "hand-calculated payload size for b\"snapshot\""
    );
    assert_eq!(
        snapshot.checksum.as_deref(),
        Some("16a0eeb0791b6c92451fd284dd9f599e0a7dbe7f6ebea6e2d2d06c7f74aec112"),
        "hand-calculated SHA-256 of the payload b\"snapshot\""
    );
    assert_eq!(snapshot.error, None);

    let unrelated_before = before
        .tenants
        .iter()
        .find(|row| row.tenant_id == "orders")
        .expect("unrelated tenant seeded");
    let after_tenants = tenant_rows(&db.pool, customer).await;
    let unrelated_after = after_tenants
        .iter()
        .find(|row| row.tenant_id == "orders")
        .expect("unrelated tenant still present");
    assert_eq!(
        unrelated_after, unrelated_before,
        "cold-tier publication must leave unrelated tenant rows byte-for-byte unchanged"
    );
}

/// Once `begin_snapshot_record` commits the `tier = 'cold'` intent, that
/// persisted intent excludes competing replacement admission throughout the
/// otherwise-unguarded export window: a replacement reservation attempted mid
/// export is refused with `destination_conflict`, so the cold-tier snapshot
/// still publishes and evicts cleanly with exactly one export and one delete.
#[tokio::test]
async fn cold_tier_snapshot_intent_refuses_replacement_admission_during_export() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_transition_replace").await
    else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    node_client.attempt_replace_reservation_during_export(
        db.pool.clone(),
        customer,
        "products",
        "cold-transition-replace",
    );
    // The guarded snapshot/publication closures acquire a second connection
    // while their transaction is open, so the service needs a multi-connection
    // pool (the single-connection `db.pool` would deadlock past `begin`).
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = cold_tier_service(&service_pool, node_client.clone());
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;

    let snapshot_id = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await
        .expect("snapshot completes; the competing replacement never takes hold");

    let reservation = node_client.take_replace_reservation_result();
    assert!(
        admission_refusal_code(&reservation) == Some("destination_conflict"),
        "committed cold intent must refuse replacement admission during export, got {reservation:?}"
    );
    assert_eq!(node_client.export_call_count(), 1);
    assert_eq!(node_client.delete_call_count(), 1);

    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    assert_eq!(snapshots.len(), 1);
    assert_eq!(snapshots[0].id, snapshot_id);
    assert_eq!(snapshots[0].status, "completed");
    let identity = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(identity.tier, "cold");
    assert_eq!(
        identity.vm_id, None,
        "publication clears the source VM after the export window"
    );
    assert_eq!(identity.cold_snapshot_id, Some(snapshot_id));
}

#[derive(Clone, Copy)]
enum ColdRollbackShape {
    BeginIntent,
    PublishedCold,
}

impl ColdRollbackShape {
    fn label(self) -> &'static str {
        match self {
            Self::BeginIntent => "begin_intent",
            Self::PublishedCold => "published_cold",
        }
    }
}

/// Stale-worker rollback safety: when any identity field drifts after the
/// operation captured its cold intent, `rollback_tenant_snapshot_state` refuses
/// to compensate (its captured identity no longer owns the row), preserving the
/// newer ownership. Covers both the begin-intent and published-cold rollback
/// shapes for every drifted field.
#[tokio::test]
async fn cold_tier_rollback_rejects_identity_drift_for_snapshot_state() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_rollback_drift").await else {
        return;
    };
    // The guarded snapshot closures acquire a second connection while their
    // transaction is open, so drive them through a multi-connection pool.
    let pool = pooled_repo_connections_in_schema(&db.schema).await;
    for shape in [
        ColdRollbackShape::BeginIntent,
        ColdRollbackShape::PublishedCold,
    ] {
        for drift in identity_drift_denominator().iter().copied() {
            assert_cold_tier_rollback_skips_on_drift(&pool, shape, drift).await;
        }
    }
}

async fn assert_cold_tier_rollback_skips_on_drift(
    pool: &PgPool,
    shape: ColdRollbackShape,
    drift: RestoreIdentityDrift,
) {
    let customer = Uuid::new_v4();
    let target = format!("idx-{}-{}", shape.label(), drift.label());
    insert_active_customer(pool, customer, 1).await;
    let source_vm_id = insert_authenticated_target_row(pool, customer, &target).await;
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let (expected_status, expected_delete_calls) = match shape {
        ColdRollbackShape::BeginIntent => {
            node_client.fail_export("stale-worker export outage");
            ("exporting", 0)
        }
        ColdRollbackShape::PublishedCold => {
            node_client.fail_delete("stale-worker eviction outage");
            ("completed", 1)
        }
    };
    let service = cold_tier_service(pool, node_client.clone());
    let candidate = cold_tier_candidate(pool, customer, &target, source_vm_id).await;

    let result = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;
    assert!(
        result.is_err(),
        "[{}/{}] snapshot attempt must fail at its injected boundary",
        shape.label(),
        drift.label()
    );

    let snapshots = cold_snapshot_rows(pool, customer, &target).await;
    assert_eq!(snapshots.len(), 1);
    let snapshot_id = snapshots[0].id;
    assert_eq!(snapshots[0].status, expected_status);

    let drifted_identity = apply_restore_identity_drift(pool, customer, &target, drift).await;

    service
        .handle_snapshot_failure(&candidate, Some(snapshot_id), "stale-worker failure")
        .await;

    assert_eq!(
        load_target_identity(pool, customer, &target).await,
        drifted_identity,
        "[{}/{}] identity-mismatched rollback must preserve every newer field",
        shape.label(),
        drift.label()
    );
    assert_eq!(
        cold_snapshot_status(pool, snapshot_id).await.as_deref(),
        Some(expected_status),
        "[{}/{}] skipped rollback must not touch the drifted snapshot",
        shape.label(),
        drift.label()
    );
    assert_eq!(
        node_client.export_call_count(),
        1,
        "[{}/{}] rollback must not dispatch remote export work",
        shape.label(),
        drift.label()
    );
    assert_eq!(
        node_client.delete_call_count(),
        expected_delete_calls,
        "[{}/{}] rollback must not dispatch stale remote delete work",
        shape.label(),
        drift.label()
    );
}

/// The operation-owned compensation path performs exactly one identity-checked,
/// database-only rollback under the lifecycle guard. While that compensation
/// guard is held, competing admission is refused; afterwards the source VM and
/// active tier are restored and the snapshot is marked failed, with no remote
/// retry or eviction dispatched by rollback.
#[tokio::test]
async fn cold_tier_rollback_blocks_admission_during_compensation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cold_tier_compensation").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    let original_identity = load_target_identity(&db.pool, customer, "products").await;

    let node_client = Arc::new(CountingColdTierNodeClient::default());
    node_client.fail_export("compensation export outage");
    let (hook, paused_slot) = admission_block_pause_hook(
        &db.schema,
        customer,
        "products",
        "cold-compensation-race",
        None,
    )
    .await;
    let service_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service = cold_tier_service(&service_pool, node_client.clone())
        .with_rollback_pause_hook_for_tests(hook);
    let candidate = cold_tier_candidate(&db.pool, customer, "products", source_vm_id).await;

    let result = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;
    assert!(
        matches!(result, Err(ColdTierError::Export(_))),
        "got {result:?}"
    );

    let snapshots = cold_snapshot_rows(&db.pool, customer, "products").await;
    let snapshot_id = snapshots[0].id;
    let before_compensation = service_window_snapshot(&db.pool, customer, "products").await;

    service
        .handle_snapshot_failure(&candidate, Some(snapshot_id), "compensation export outage")
        .await;

    let paused = paused_slot
        .lock()
        .unwrap()
        .take()
        .expect("rollback pause hook recorded a snapshot");
    assert_eq!(
        paused.tenants, before_compensation.tenants,
        "compensation guard must not make the restored state visible before it commits"
    );

    let restored = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(restored.tier, "active", "rollback restores the active tier");
    assert_eq!(
        restored.vm_id,
        Some(source_vm_id),
        "rollback restores the captured source VM"
    );
    assert_eq!(restored.cold_snapshot_id, None);
    assert_eq!(restored.service_type, original_identity.service_type);
    assert_eq!(restored.deployment_id, original_identity.deployment_id);

    assert_eq!(
        cold_snapshot_status(&db.pool, snapshot_id).await.as_deref(),
        Some("failed"),
        "rollback marks the operation-owned snapshot failed"
    );
    assert_eq!(
        node_client.export_call_count(),
        1,
        "compensation must not dispatch a remote export retry"
    );
    assert_eq!(
        node_client.delete_call_count(),
        0,
        "compensation must not dispatch a remote eviction"
    );
}

#[tokio::test]
async fn migration_begin_rejects_active_replace_reservation() {
    assert_migration_begin_rejects_all_active_reservations().await;
}

async fn assert_migration_begin_rejects_all_active_reservations() {
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        assert_migration_begin_rejects_active_reservation(kind).await;
    }
}

async fn assert_migration_begin_rejects_active_reservation(kind: ActiveReservationKind) {
    let schema = format!("catalog_lifecycle_migration_begin_blocks_{}", kind.label());
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    seed_migration_target_with_active_reservation(&db.pool, customer, "products", kind).await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    insert_vm(&db.pool, dest_vm_id).await;
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let service = migration_service(&db.pool, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer).await;
    let before_operations = import_operation_rows(&db.pool, customer, "products").await;
    let migration_repo = PgIndexMigrationRepo::new(db.pool.clone());
    let before_migration_count = migration_repo
        .count_active()
        .await
        .expect("count migrations before refusal");

    let result = service
        .execute(MigrationRequest {
            index_name: "products".to_string(),
            customer_id: customer,
            source_vm_id,
            dest_vm_id,
            requested_by: "catalog-lifecycle-test".to_string(),
        })
        .await;

    assert!(
        matches!(result, Err(MigrationError::DestinationConflict)),
        "active {} reservation must block migration begin intent, got {result:?}",
        kind.label()
    );
    assert_eq!(
        http_client.request_count(),
        0,
        "migration refusal must happen before replication HTTP dispatch"
    );
    assert_eq!(
        migration_repo
            .count_active()
            .await
            .expect("count migrations after refusal"),
        before_migration_count,
        "migration refusal must not create an operation intent row"
    );
    assert_eq!(
        tenant_rows(&db.pool, customer).await,
        before_tenants,
        "migration refusal must not mutate tenant routing state"
    );
    assert_eq!(
        import_operation_rows(&db.pool, customer, "products").await,
        before_operations,
        "migration refusal must not mutate import operation rows"
    );
}

async fn seed_migration_target_with_active_reservation(
    pool: &PgPool,
    customer_id: Uuid,
    target: &str,
    kind: ActiveReservationKind,
) {
    let repo = PgAlgoliaImportJobRepo::new(pool.clone());
    match kind {
        ActiveReservationKind::Import => {
            insert_active_customer(pool, customer_id, 1).await;
            repo.create(import_job(customer_id, target, "migration-begin-import"))
                .await
                .expect("active import reservation");
            insert_authenticated_target_row(pool, customer_id, target).await;
        }
        ActiveReservationKind::Replacement => {
            insert_replace_target(pool, customer_id, target).await;
            repo.create_replace(replace_job(customer_id, target, "migration-begin-replace"))
                .await
                .expect("active replace reservation");
        }
    }
}

#[derive(Clone, Copy)]
enum MigrationIntentPath {
    Execute,
    ProbeRollback,
    ProbeFailure,
}

impl MigrationIntentPath {
    fn label(self) -> &'static str {
        match self {
            Self::Execute => "execute",
            Self::ProbeRollback => "probe_rollback",
            Self::ProbeFailure => "probe_failure",
        }
    }

    fn expected_final_migration_status(self) -> &'static str {
        match self {
            Self::Execute => "completed",
            Self::ProbeRollback => "rolled_back",
            Self::ProbeFailure => "failed",
        }
    }

    fn expected_final_vm_id(
        self,
        original_identity: &CatalogLifecycleTargetIdentity,
        dest_vm_id: Uuid,
    ) -> Option<Uuid> {
        match self {
            Self::Execute => Some(dest_vm_id),
            Self::ProbeRollback | Self::ProbeFailure => original_identity.vm_id,
        }
    }

    fn expected_source_restore_allowed(self) -> bool {
        match self {
            Self::Execute => false,
            Self::ProbeRollback | Self::ProbeFailure => true,
        }
    }

    fn assert_final_migration_error(self, error: Option<&str>) {
        match self {
            Self::Execute | Self::ProbeRollback => assert_eq!(error, None),
            Self::ProbeFailure => assert!(
                error.unwrap_or_default().contains(
                    "engine index identity probe injected failure after replication start"
                ),
                "probe failure must persist the injected failure, got {error:?}"
            ),
        }
    }

    fn assert_final_completed_at(self, completed_at: Option<DateTime<Utc>>) {
        match self {
            Self::Execute => assert!(completed_at.is_some()),
            Self::ProbeRollback | Self::ProbeFailure => assert_eq!(completed_at, None),
        }
    }
}

struct MigrationIntentFinalState<'a> {
    pool: &'a PgPool,
    customer: Uuid,
    target: &'static str,
    migration_id: Uuid,
    original_identity: &'a CatalogLifecycleTargetIdentity,
    dest_vm_id: Uuid,
}

// The migration intent-window owner-wins races now live under the canonical
// `migration_lifecycle_races_after_intent_before_remote_work` selection in
// `catalog_lifecycle_lease_remote_races`; every `MigrationIntentPath` is
// exercised there through `assert_migration_intent_window_blocks_admission`.

async fn assert_migration_intent_window_blocks_admission(path: MigrationIntentPath) {
    let schema = format!("catalog_lifecycle_migration_intent_window_{}", path.label());
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let original_identity = load_target_identity(&db.pool, customer, "products").await;
    let source_vm_id = original_identity
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    insert_vm(&db.pool, dest_vm_id).await;
    let node_secret_manager = mock_node_secret_manager();
    let source_key = node_secret_manager
        .create_node_api_key(&format!("vm-{source_vm_id}"), "us-east-1")
        .await
        .expect("seed source VM API key");
    let dest_key = node_secret_manager
        .create_node_api_key(&format!("vm-us-east-1-{dest_vm_id}"), "us-east-1")
        .await
        .expect("seed destination VM API key");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let index_uid = flapjack_index_uid(customer, "products");
    queue_migration_intent_window_http(&http_client, path, &index_uid);

    let hook = migration_intent_pause_hook(
        &db.schema,
        customer,
        "products",
        path.label(),
        original_identity.clone(),
        http_client.clone(),
    )
    .await;
    let repo_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service =
        migration_service_with_secrets(&repo_pool, http_client.clone(), node_secret_manager)
            .with_post_intent_pause_hook_for_tests(hook);
    let request = MigrationRequest {
        index_name: "products".to_string(),
        customer_id: customer,
        source_vm_id,
        dest_vm_id,
        requested_by: "catalog-lifecycle-test".to_string(),
    };

    let migration_id = match path {
        MigrationIntentPath::Execute => service.execute(request).await,
        MigrationIntentPath::ProbeRollback => {
            service.probe_rollback_after_replication(request).await
        }
        MigrationIntentPath::ProbeFailure => service.probe_failure_after_replication(request).await,
    }
    .unwrap_or_else(|err| {
        panic!(
            "{} must complete after the intent-window assertions release, got {err:?}",
            path.label()
        )
    });
    let requests = http_client.recorded_requests();
    assert_migration_request_sequence(
        &requests,
        &expected_migration_intent_requests(path, &index_uid, &source_key, &dest_key),
    );
    assert_migration_final_state(
        path,
        MigrationIntentFinalState {
            pool: &db.pool,
            customer,
            target: "products",
            migration_id,
            original_identity: &original_identity,
            dest_vm_id,
        },
    )
    .await;
}

fn expected_migration_intent_requests(
    path: MigrationIntentPath,
    index_uid: &str,
    source_key: &str,
    dest_key: &str,
) -> Vec<ExpectedMigrationRequest> {
    let source_ops = ExpectedMigrationRequest::get(
        format!(
            "https://private.invalid/internal/ops?tenant_id={}&since_seq=0",
            urlencoding::encode(index_uid)
        ),
        source_key,
    );
    let replicate = ExpectedMigrationRequest::post(
        "https://private.invalid/internal/replicate".to_string(),
        Some(json!({
            "tenant_id": index_uid,
            "ops": []
        })),
        dest_key,
    );
    match path {
        MigrationIntentPath::Execute => vec![
            source_ops,
            replicate,
            ExpectedMigrationRequest::get(
                "https://private.invalid/metrics".to_string(),
                source_key,
            ),
            ExpectedMigrationRequest::get("https://private.invalid/metrics".to_string(), dest_key),
            ExpectedMigrationRequest::post(
                format!("https://private.invalid/internal/pause/{index_uid}"),
                None,
                source_key,
            ),
            ExpectedMigrationRequest::get(
                "https://private.invalid/metrics".to_string(),
                source_key,
            ),
            ExpectedMigrationRequest::get("https://private.invalid/metrics".to_string(), dest_key),
            ExpectedMigrationRequest::post(
                format!("https://private.invalid/internal/resume/{index_uid}"),
                None,
                dest_key,
            ),
        ],
        MigrationIntentPath::ProbeRollback => vec![
            source_ops,
            replicate,
            ExpectedMigrationRequest::delete(
                format!("https://private.invalid/1/indexes/{index_uid}"),
                dest_key,
            ),
        ],
        MigrationIntentPath::ProbeFailure => vec![
            source_ops,
            replicate,
            ExpectedMigrationRequest::post(
                format!("https://private.invalid/internal/resume/{index_uid}"),
                None,
                source_key,
            ),
            ExpectedMigrationRequest::delete(
                format!("https://private.invalid/1/indexes/{index_uid}"),
                dest_key,
            ),
        ],
    }
}

async fn assert_migration_final_state(
    path: MigrationIntentPath,
    state: MigrationIntentFinalState<'_>,
) {
    let tenants = tenant_rows(state.pool, state.customer).await;
    assert_eq!(tenants.len(), 1);
    let tenant = &tenants[0];
    assert_eq!(tenant.tenant_id, state.target);
    assert_eq!(tenant.deployment_id, state.original_identity.deployment_id);
    assert_eq!(
        tenant.cold_snapshot_id,
        state.original_identity.cold_snapshot_id
    );
    assert_eq!(tenant.service_type, state.original_identity.service_type);
    assert_eq!(tenant.tier, "active");
    assert_eq!(
        tenant.vm_id,
        path.expected_final_vm_id(state.original_identity, state.dest_vm_id)
    );

    let migration = PgIndexMigrationRepo::new(state.pool.clone())
        .get(state.migration_id)
        .await
        .expect("load migration after intent-window path")
        .expect("migration row remains after intent-window path");
    assert_eq!(migration.index_name, state.target);
    assert_eq!(migration.customer_id, state.customer);
    assert_eq!(
        migration.source_vm_id,
        state.original_identity.vm_id.expect("source VM id")
    );
    assert_eq!(migration.dest_vm_id, state.dest_vm_id);
    assert_eq!(migration.status, path.expected_final_migration_status());
    path.assert_final_migration_error(migration.error.as_deref());
    path.assert_final_completed_at(migration.completed_at);
    let mut intent_identity = state.original_identity.clone();
    intent_identity.tier = "migrating".to_string();
    assert_eq!(
        migration
            .intent_target_identity()
            .expect("migration metadata preserves intent identity"),
        intent_identity
    );
    assert_eq!(
        migration.source_restore_allowed(),
        path.expected_source_restore_allowed()
    );
    assert!(
        replica_rows(state.pool, state.customer, state.target)
            .await
            .is_empty(),
        "migration intent path must not create replica rows"
    );
    assert!(
        import_operation_rows(state.pool, state.customer, state.target)
            .await
            .is_empty(),
        "losing import admission attempts inside {} intent window must not create rows",
        path.label()
    );
}

async fn migration_intent_pause_hook(
    schema: &str,
    customer_id: Uuid,
    target: &'static str,
    key_prefix: &'static str,
    original_identity: CatalogLifecycleTargetIdentity,
    http_client: Arc<CountingMigrationHttpClient>,
) -> LifecycleGuardPauseHook {
    let probe_pool = pool_in_schema(schema).await;
    Arc::new(move || {
        let probe_pool = probe_pool.clone();
        let original_identity = original_identity.clone();
        let http_client = http_client.clone();
        Box::pin(async move {
            let snapshot = service_window_snapshot(&probe_pool, customer_id, target).await;
            assert_eq!(snapshot.tenants.len(), 1);
            let tenant = &snapshot.tenants[0];
            assert_eq!(tenant.tenant_id, target);
            assert_eq!(tenant.deployment_id, original_identity.deployment_id);
            assert_eq!(tenant.vm_id, original_identity.vm_id);
            assert_eq!(tenant.tier, "migrating");
            assert_eq!(tenant.cold_snapshot_id, original_identity.cold_snapshot_id);
            assert_eq!(tenant.service_type, original_identity.service_type);
            assert!(
                snapshot.operations.is_empty(),
                "migration intent window must start with no import operation rows"
            );
            let migration_rows = sqlx::query_as::<_, (String,)>(
                "SELECT status
                 FROM index_migrations
                 WHERE customer_id = $1 AND index_name = $2
                 ORDER BY started_at, id",
            )
            .bind(customer_id)
            .bind(target)
            .fetch_all(&probe_pool)
            .await
            .expect("load migration rows in intent window");
            assert_eq!(migration_rows, vec![("replicating".to_string(),)]);
            assert_eq!(
                http_client.request_count(),
                0,
                "intent pause must fire before the first migration HTTP call"
            );
            assert_service_window_blocks_admission_with_codes(
                &probe_pool,
                customer_id,
                target,
                key_prefix,
                "destination_changed",
                "destination_conflict",
            )
            .await;
        })
    })
}

fn queue_migration_intent_window_http(
    http_client: &CountingMigrationHttpClient,
    path: MigrationIntentPath,
    index_uid: &str,
) {
    match path {
        MigrationIntentPath::Execute => {
            queue_successful_migration_http(http_client, index_uid, 100, 95);
        }
        MigrationIntentPath::ProbeRollback => {
            enqueue_source_ops(http_client, index_uid, 100);
            http_client.enqueue_response(Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            }));
            http_client.enqueue_response(Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            }));
        }
        MigrationIntentPath::ProbeFailure => {
            enqueue_source_ops(http_client, index_uid, 100);
            http_client.enqueue_response(Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            }));
            http_client.enqueue_response(Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            }));
            http_client.enqueue_response(Ok(MigrationHttpResponse {
                status: 200,
                body: "{}".to_string(),
            }));
        }
    }
}

#[tokio::test]
async fn migration_rollback_rejects_active_replace_reservation_before_remote_work() {
    assert_migration_rollback_rejects_active_reservation_before_remote_work().await;
}

async fn assert_migration_rollback_rejects_active_reservation_before_remote_work() {
    for kind in [
        ActiveReservationKind::Import,
        ActiveReservationKind::Replacement,
    ] {
        assert_migration_rollback_rejects_active_reservation(kind).await;
    }
}

async fn assert_migration_rollback_rejects_active_reservation(kind: ActiveReservationKind) {
    let schema = format!(
        "catalog_lifecycle_migration_rollback_blocks_{}",
        kind.label()
    );
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    seed_migration_target_with_active_reservation(&db.pool, customer, "products", kind).await;
    let migration_id = insert_active_migration(&db.pool, customer, "products").await;
    PgTenantRepo::new(db.pool.clone())
        .set_tier(customer, "products", "migrating")
        .await
        .expect("seed migration intent tier");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    let service = migration_service(&db.pool, http_client.clone());
    let before_tenants = tenant_rows(&db.pool, customer).await;
    let before_migration = PgIndexMigrationRepo::new(db.pool.clone())
        .get(migration_id)
        .await
        .expect("load migration before refusal")
        .expect("migration intent exists before refusal");

    let result = service.rollback(migration_id).await;

    assert!(
        matches!(result, Err(MigrationError::DestinationConflict)),
        "active {} reservation must block migration rollback, got {result:?}",
        kind.label()
    );
    assert_eq!(
        http_client.request_count(),
        0,
        "migration rollback refusal must happen before remote source resume/delete"
    );
    assert_eq!(
        tenant_rows(&db.pool, customer).await,
        before_tenants,
        "migration rollback refusal for active {} reservation must preserve tenant routing state",
        kind.label()
    );
    let after_migration = PgIndexMigrationRepo::new(db.pool.clone())
        .get(migration_id)
        .await
        .expect("load migration after refusal")
        .expect("migration intent remains after refusal");
    assert_eq!(after_migration.status, before_migration.status);
    assert_eq!(after_migration.error, before_migration.error);
    assert_eq!(after_migration.metadata, before_migration.metadata);
    assert_eq!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .len(),
        1,
        "migration rollback refusal must preserve the competing {} operation row",
        kind.label()
    );
}

fn retained_reservation_cases() -> Vec<ReservationLifetimeCase> {
    reservation_lifetime_denominator()
        .into_iter()
        .filter(|case| case.expectation == ReservationExpectation::Retain)
        .collect()
}

fn assert_retained_reservation_cases_present(family: &str, cases: &[ReservationLifetimeCase]) {
    assert!(
        !cases.is_empty(),
        "{family} expired-claim proof must have retained denominator cases"
    );
}

fn log_expired_worker_lease_cell(family: &str, case: &ReservationLifetimeCase) {
    eprintln!(
        "expired worker lease retained cell passed: {family} / {}",
        case.label
    );
}

#[tokio::test]
async fn expired_worker_lease_blocks_create_shared_vm_route_family() {
    let Some(db) = connect_and_migrate("expired_create_shared_vm_route_family").await else {
        return;
    };
    let family = "CreateSharedVmRoute";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_import_blocks_create_route(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_import_finalization_delete_family() {
    let Some(db) = connect_and_migrate("expired_import_finalization_delete_family").await else {
        return;
    };
    let family = "ImportReservationFinalizationVersusDelete";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_replace_blocks_delete_route(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_admin_seed_create_family() {
    let Some(db) = connect_and_migrate("expired_admin_seed_create_family").await else {
        return;
    };
    let family = "AdminSeedCreate";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_import_blocks_seed_route(&db.pool, &case).await;
        assert_expired_replace_blocks_seed_resolve_route(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_replica_create_remove_family() {
    let Some(db) = connect_and_migrate("expired_replica_create_remove_family").await else {
        return;
    };
    let family = "ReplicaCreateRemove";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_replace_blocks_replica_create(&db.pool, &case).await;
        assert_expired_replace_blocks_replica_remove(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_region_failover_family() {
    let Some(db) = connect_and_migrate("expired_region_failover_family").await else {
        return;
    };
    let family = "RegionFailover";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_replace_blocks_failover(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_restore_family() {
    let Some(db) = connect_and_migrate("expired_restore_family").await else {
        return;
    };
    let family = "Restore";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_replace_blocks_restore(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_cold_transition_rollback_family() {
    let Some(db) = connect_and_migrate("expired_cold_transition_rollback_family").await else {
        return;
    };
    let family = "ColdTransitionRollback";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        assert_expired_replace_blocks_cold_tier(&db.pool, &case).await;
        log_expired_worker_lease_cell(family, &case);
    }
}

#[tokio::test]
async fn expired_worker_lease_blocks_migration_begin_rollback_family() {
    let Some(db) = connect_and_migrate("expired_migration_begin_rollback_family").await else {
        return;
    };
    let family = "MigrationBeginFinalizeRollbackRecovery";
    let cases = retained_reservation_cases();
    assert_retained_reservation_cases_present(family, &cases);
    for case in cases {
        let label = case.label.clone();
        assert_expired_replace_blocks_migration_begin(&db.pool, &case).await;
        assert_expired_replace_blocks_migration_rollback(&db.pool, &case).await;
        eprintln!("expired worker lease retained cell passed: {family} / {label}");
    }
}

async fn assert_expired_import_blocks_create_route(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Expired Create", "expired-create@test.com");
    insert_active_customer(pool, customer.id, 1).await;
    insert_route_test_vm(pool, "us-east-1", "https://route-create.invalid").await;
    create_expired_import_reservation(pool, customer.id, "products", "expired-route-create", case)
        .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(pool, customer.id).await;
    let before_deployments = deployment_rows(pool, customer.id).await;

    let response = app
        .oneshot(create_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("create index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(
        tenant_rows(pool, customer.id).await,
        before_tenants,
        "{}",
        case.label
    );
    assert_eq!(deployment_rows(pool, customer.id).await, before_deployments);
}

async fn assert_expired_replace_blocks_delete_route(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Expired Delete", "expired-delete@test.com");
    insert_replace_target(pool, customer.id, "products").await;
    create_expired_replace_reservation(pool, customer.id, "products", "expired-route-delete", case)
        .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(pool, customer.id).await;
    let before_deployments = deployment_rows(pool, customer.id).await;

    let response = app
        .oneshot(delete_index_request(
            "products",
            &create_test_jwt(customer.id),
        ))
        .await
        .expect("delete index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer.id).await, before_tenants);
    assert_eq!(deployment_rows(pool, customer.id).await, before_deployments);
}

async fn assert_expired_import_blocks_seed_route(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Expired Seed", "expired-seed@test.com");
    insert_active_customer(pool, customer.id, 1).await;
    create_expired_import_reservation(pool, customer.id, "products", "expired-admin-seed", case)
        .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(pool, customer.id).await;
    let before_deployments = deployment_rows(pool, customer.id).await;

    let response = app
        .oneshot(seed_index_request(customer.id, "products", None))
        .await
        .expect("seed index response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer.id).await, before_tenants);
    assert_eq!(deployment_rows(pool, customer.id).await, before_deployments);
}

async fn assert_expired_replace_blocks_seed_resolve_route(
    pool: &PgPool,
    case: &ReservationLifetimeCase,
) {
    let customer_repo = mock_repo();
    let customer =
        customer_repo.seed_verified_shared_customer("Expired Resolve", "expired-resolve@test.com");
    insert_replace_target(pool, customer.id, "products").await;
    create_expired_replace_reservation(
        pool,
        customer.id,
        "products",
        "expired-admin-resolve",
        case,
    )
    .await;
    let http_client = Arc::new(MockFlapjackHttpClient::default());
    let app = route_test_app(pool.clone(), customer_repo, http_client.clone());
    let before_tenants = tenant_rows(pool, customer.id).await;
    let before_deployments = deployment_rows(pool, customer.id).await;

    let response = app
        .oneshot(seed_index_request(
            customer.id,
            "products",
            Some("https://route-resolve.invalid"),
        ))
        .await
        .expect("resolve existing seed response");

    assert_conflict_response(response, "destination_conflict").await;
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer.id).await, before_tenants);
    assert_eq!(deployment_rows(pool, customer.id).await, before_deployments);
}

async fn assert_expired_replace_blocks_replica_create(
    pool: &PgPool,
    case: &ReservationLifetimeCase,
) {
    let customer = Uuid::new_v4();
    insert_replica_service_target(pool, customer, "products").await;
    create_expired_replace_reservation(pool, customer, "products", "expired-replica-create", case)
        .await;
    let service = ReplicaService::new(
        Arc::new(PgIndexReplicaRepo::new(pool.clone())),
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
        RegionConfig::defaults(),
    );
    let before_replicas = replica_rows(pool, customer, "products").await;

    let result = service
        .create_replica(customer, "products", "eu-central-1")
        .await;

    assert!(matches!(result, Err(ReplicaError::DestinationConflict)));
    assert_eq!(
        replica_rows(pool, customer, "products").await,
        before_replicas
    );
}

async fn assert_expired_replace_blocks_replica_remove(
    pool: &PgPool,
    case: &ReservationLifetimeCase,
) {
    let customer = Uuid::new_v4();
    let (primary_vm_id, replica_vm_id) =
        insert_replica_service_target(pool, customer, "products").await;
    let replica_repo = Arc::new(PgIndexReplicaRepo::new(pool.clone()));
    let replica = replica_repo
        .create(
            customer,
            "products",
            primary_vm_id,
            replica_vm_id,
            "eu-central-1",
        )
        .await
        .expect("seed replica");
    create_expired_replace_reservation(pool, customer, "products", "expired-replica-remove", case)
        .await;
    let service = ReplicaService::new(
        replica_repo,
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
        RegionConfig::defaults(),
    );
    let before_replicas = replica_rows(pool, customer, "products").await;

    let result = service
        .remove_replica(customer, "products", replica.id)
        .await;

    assert!(matches!(result, Err(ReplicaError::DestinationConflict)));
    assert_eq!(
        replica_rows(pool, customer, "products").await,
        before_replicas
    );
}

async fn assert_expired_replace_blocks_failover(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer = Uuid::new_v4();
    insert_region_failover_target(pool, customer, "products").await;
    create_expired_replace_reservation(pool, customer, "products", "expired-failover", case).await;
    let monitor = RegionFailoverMonitor::new(
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(PgTenantRepo::new(pool.clone())),
        Arc::new(PgIndexReplicaRepo::new(pool.clone())),
        crate::common::mock_alert_service(),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
        RegionFailoverConfig {
            cycle_interval_secs: 30,
            unhealthy_threshold: 1,
            recovery_threshold: 1,
        },
    );
    let before_tenants = tenant_rows(pool, customer).await;
    let before_replicas = replica_rows(pool, customer, "products").await;

    monitor
        .run_cycle_with_health(|url| !url.contains("us-east-1"))
        .await;

    assert_eq!(tenant_rows(pool, customer).await, before_tenants);
    assert_eq!(
        replica_rows(pool, customer, "products").await,
        before_replicas
    );
}

async fn assert_expired_replace_blocks_restore(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer = Uuid::new_v4();
    insert_replace_target(pool, customer, "products").await;
    create_expired_replace_reservation(pool, customer, "products", "expired-restore", case).await;
    insert_restore_service_target(pool, customer, "products").await;
    let tenant_repo = Arc::new(PgTenantRepo::new(pool.clone()));
    let restore_job_repo = Arc::new(PgRestoreJobRepo::new(pool.clone()));
    let node_client = Arc::new(CountingRestoreNodeClient::default());
    let service = RestoreService::new(
        RestoreConfig::default(),
        tenant_repo.clone(),
        Arc::new(PgColdSnapshotRepo::new(pool.clone())),
        restore_job_repo.clone(),
        Arc::new(PgVmInventoryRepo::new(pool.clone())),
        Arc::new(RegionObjectStoreResolver::single(Arc::new(
            InMemoryObjectStore::new(),
        ))),
        Arc::new(MockAlertService::new()),
        Arc::new(DiscoveryService::with_ttl(
            tenant_repo,
            Arc::new(PgVmInventoryRepo::new(pool.clone())),
            3600,
        )),
        node_client.clone(),
        mock_node_secret_manager(),
        Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
            pool.clone(),
        ))),
    );
    let before_tenants = tenant_rows(pool, customer).await;
    let before_restore_jobs =
        serde_json::to_value(restore_job_rows(pool, customer, "products").await)
            .expect("serialize restore jobs before expired-claim refusal");

    let result = service.initiate_restore(customer, "products").await;

    assert!(matches!(result, Err(RestoreError::DestinationConflict)));
    assert_eq!(node_client.remote_call_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer).await, before_tenants);
    assert_eq!(
        serde_json::to_value(restore_job_rows(pool, customer, "products").await)
            .expect("serialize restore jobs after expired-claim refusal"),
        before_restore_jobs
    );
    assert_eq!(
        restore_job_repo.list_active().await.unwrap().len(),
        before_restore_jobs
            .as_array()
            .expect("restore jobs serialize as array")
            .len()
    );
}

async fn assert_expired_replace_blocks_cold_tier(pool: &PgPool, case: &ReservationLifetimeCase) {
    let customer = Uuid::new_v4();
    insert_replace_target(pool, customer, "products").await;
    create_expired_replace_reservation(pool, customer, "products", "expired-cold", case).await;
    let source_vm_id = load_target_identity(pool, customer, "products")
        .await
        .vm_id
        .expect("cold-tier target has source VM");
    let node_client = Arc::new(CountingColdTierNodeClient::default());
    let service = cold_tier_service(pool, node_client.clone());
    let candidate = cold_tier_candidate(pool, customer, "products", source_vm_id).await;
    let before_tenants = tenant_rows(pool, customer).await;
    let before_snapshots = cold_snapshot_rows(pool, customer, "products").await;

    let result = service
        .snapshot_candidate(&candidate, "https://private.invalid", "us-east-1")
        .await;

    assert!(matches!(result, Err(ColdTierError::DestinationConflict)));
    assert_eq!(node_client.remote_call_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer).await, before_tenants);
    assert_eq!(
        cold_snapshot_rows(pool, customer, "products").await,
        before_snapshots
    );
}

async fn assert_expired_replace_blocks_migration_begin(
    pool: &PgPool,
    case: &ReservationLifetimeCase,
) {
    let customer = Uuid::new_v4();
    insert_replace_target(pool, customer, "products").await;
    let source_vm_id = load_target_identity(pool, customer, "products")
        .await
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    insert_vm(pool, dest_vm_id).await;
    create_expired_replace_reservation(pool, customer, "products", "expired-migration-begin", case)
        .await;
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let service = migration_service(pool, http_client.clone());
    let before_tenants = tenant_rows(pool, customer).await;
    let migration_repo = PgIndexMigrationRepo::new(pool.clone());
    let before_migration_count = migration_repo.count_active().await.unwrap();

    let result = service
        .execute(MigrationRequest {
            index_name: "products".to_string(),
            customer_id: customer,
            source_vm_id,
            dest_vm_id,
            requested_by: "catalog-lifecycle-test".to_string(),
        })
        .await;

    assert!(
        matches!(result, Err(MigrationError::DestinationConflict)),
        "expired retained reservation case {} must block migration begin before mutation, got {result:?}",
        case.label
    );
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(
        migration_repo.count_active().await.unwrap(),
        before_migration_count
    );
    assert_eq!(tenant_rows(pool, customer).await, before_tenants);
}

async fn assert_expired_replace_blocks_migration_rollback(
    pool: &PgPool,
    case: &ReservationLifetimeCase,
) {
    let customer = Uuid::new_v4();
    insert_replace_target(pool, customer, "products").await;
    create_expired_replace_reservation(
        pool,
        customer,
        "products",
        "expired-migration-rollback",
        case,
    )
    .await;
    let migration_id = insert_active_migration(pool, customer, "products").await;
    PgTenantRepo::new(pool.clone())
        .set_tier(customer, "products", "migrating")
        .await
        .expect("seed migration intent tier");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    let service = migration_service(pool, http_client.clone());
    let before_tenants = tenant_rows(pool, customer).await;
    let before_migration = PgIndexMigrationRepo::new(pool.clone())
        .get(migration_id)
        .await
        .unwrap()
        .expect("migration intent exists before refusal");

    let result = service.rollback(migration_id).await;

    assert!(matches!(result, Err(MigrationError::DestinationConflict)));
    assert_eq!(http_client.request_count(), 0, "{}", case.label);
    assert_eq!(tenant_rows(pool, customer).await, before_tenants);
    let after_migration = PgIndexMigrationRepo::new(pool.clone())
        .get(migration_id)
        .await
        .unwrap()
        .expect("migration intent remains after refusal");
    assert_eq!(after_migration.status, before_migration.status);
    assert_eq!(after_migration.error, before_migration.error);
    assert_eq!(after_migration.metadata, before_migration.metadata);
    PgIndexMigrationRepo::new(pool.clone())
        .update_status(migration_id, "failed", Some("expired-claim test cleanup"))
        .await
        .expect("cleanup active migration fixture after expired-claim assertion");
}

#[tokio::test]
async fn migration_rollback_rejects_tier_drift_after_remote_work() {
    for drift in identity_drift_denominator().iter().copied() {
        assert_migration_rollback_rejects_identity_drift(drift).await;
    }
}

async fn assert_migration_rollback_rejects_identity_drift(drift: RestoreIdentityDrift) {
    let schema = format!(
        "catalog_lifecycle_migration_rollback_drift_{}",
        drift.label()
    );
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let migration_id = insert_active_migration(&db.pool, customer, "products").await;
    PgTenantRepo::new(db.pool.clone())
        .set_tier(customer, "products", "migrating")
        .await
        .expect("seed migration intent tier");
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("migration rollback target has source VM");
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&format!("vm-{source_vm_id}"), "us-east-1")
        .await
        .expect("seed source VM API key");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.drift_identity_after_source_resume(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        drift,
    );
    let service =
        migration_service_with_secrets(&db.pool, http_client.clone(), node_secret_manager);
    let before_migration = PgIndexMigrationRepo::new(db.pool.clone())
        .get(migration_id)
        .await
        .expect("load migration before stale rollback")
        .expect("migration intent exists before stale rollback");

    let result = service.rollback(migration_id).await;

    assert!(
        matches!(result, Err(MigrationError::DestinationChanged)),
        "stale {drift:?} during migration rollback must reject stale publication, got {result:?}"
    );
    assert_eq!(
        http_client.request_count(),
        1,
        "rollback remote resume must remain outside the publication guard"
    );
    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(
        identity_after,
        http_client.take_drifted_identity(),
        "stale {drift:?} rollback must preserve every newer owner field"
    );
    let migration_after = PgIndexMigrationRepo::new(db.pool.clone())
        .get(migration_id)
        .await
        .expect("load migration after drift")
        .expect("migration intent remains after drift");
    assert_eq!(
        migration_after.status, "cutting_over",
        "stale rollback must not mark the migration rolled back"
    );
    assert_eq!(migration_after.error, before_migration.error);
    assert_eq!(migration_after.metadata, before_migration.metadata);
    assert!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "stale migration rollback must not create import-operation rows"
    );
}

#[tokio::test]
async fn migration_finalize_rejects_identity_drift_without_resuming_destination() {
    for drift in identity_drift_denominator().iter().copied() {
        assert_migration_finalize_rejects_identity_drift(drift).await;
    }
}

async fn assert_migration_finalize_rejects_identity_drift(drift: RestoreIdentityDrift) {
    let schema = format!(
        "catalog_lifecycle_migration_finalize_drift_{}",
        drift.label()
    );
    let Some(db) = connect_and_migrate(&schema).await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    insert_vm(&db.pool, dest_vm_id).await;
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&format!("vm-{source_vm_id}"), "us-east-1")
        .await
        .expect("seed source VM API key");
    node_secret_manager
        .create_node_api_key(&format!("vm-us-east-1-{dest_vm_id}"), "us-east-1")
        .await
        .expect("seed destination VM API key");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let index_uid = flapjack_index_uid(customer, "products");
    queue_successful_migration_http(&http_client, &index_uid, 100, 95);
    let drift_pool = pool_in_schema(&db.schema).await;
    http_client.drift_identity_after_source_pause(drift_pool, customer, "products", drift);
    let repo_pool = pool_in_schema(&db.schema).await;
    let tenant_repo = Arc::new(PgTenantRepo::new(repo_pool.clone()));
    let service = MigrationService::with_http_client_config_and_lifecycle(
        tenant_repo.clone(),
        Arc::new(PgVmInventoryRepo::new(repo_pool.clone())),
        Arc::new(PgIndexMigrationRepo::new(repo_pool)),
        Arc::new(MockAlertService::new()),
        Arc::new(DiscoveryService::with_ttl(
            tenant_repo,
            Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
            3600,
        )),
        node_secret_manager,
        http_client.clone(),
        MigrationConfig {
            max_concurrent: 3,
            rollback_window: Duration::seconds(300),
            replication_timeout: std::time::Duration::from_millis(50),
            replication_poll_interval: std::time::Duration::from_millis(10),
            replication_near_zero_lag_ops: 10,
            long_running_warning_threshold: std::time::Duration::from_secs(600),
        },
        Some(Arc::new(IndexLifecycleLease::new(
            PgAlgoliaImportJobRepo::new(db.pool.clone()),
        ))),
    );

    let result = service
        .execute(MigrationRequest {
            index_name: "products".to_string(),
            customer_id: customer,
            source_vm_id,
            dest_vm_id,
            requested_by: "catalog-lifecycle-test".to_string(),
        })
        .await;

    assert!(
        matches!(result, Err(MigrationError::DestinationChanged)),
        "stale {drift:?} before migration finalization must reject stale publication, got {result:?}"
    );
    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    let drifted_identity = http_client.take_drifted_identity();
    assert_eq!(identity_after, drifted_identity);
    let migration_rows = sqlx::query_as::<_, (String, Option<String>, Option<DateTime<Utc>>)>(
        "SELECT status, error, completed_at
         FROM index_migrations
         WHERE customer_id = $1 AND index_name = $2
         ORDER BY started_at, id",
    )
    .bind(customer)
    .bind("products")
    .fetch_all(&db.pool)
    .await
    .expect("load migration rows after stale finalization");
    assert_eq!(
        migration_rows,
        vec![("cutting_over".to_string(), None, None)],
        "stale migration finalizer must leave the migration at the pre-publication boundary"
    );
    assert!(
        import_operation_rows(&db.pool, customer, "products")
            .await
            .is_empty(),
        "stale migration finalizer must not create import-operation rows"
    );
    assert!(
        http_client.recorded_requests().iter().all(|request| {
            !request.url.contains(&format!(
                "/internal/resume/{}",
                urlencoding::encode(&index_uid)
            )) && !request
                .url
                .contains(&format!("/1/indexes/{}", urlencoding::encode(&index_uid)))
        }),
        "stale {drift:?} finalizer must not resume or delete the newer owner's destination target"
    );
}

#[tokio::test]
async fn migration_execute_failure_reset_rejects_identity_drift() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_migration_reset_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    insert_vm(&db.pool, dest_vm_id).await;
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&format!("vm-{source_vm_id}"), "us-east-1")
        .await
        .expect("seed source VM API key");
    node_secret_manager
        .create_node_api_key(&format!("vm-us-east-1-{dest_vm_id}"), "us-east-1")
        .await
        .expect("seed destination VM API key");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 503,
        body: "source ops failed".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.drift_identity_during_source_ops(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        RestoreIdentityDrift::Tier,
    );
    let repo_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let service =
        migration_service_with_secrets(&repo_pool, http_client.clone(), node_secret_manager);

    let result = service
        .execute(MigrationRequest {
            index_name: "products".to_string(),
            customer_id: customer,
            source_vm_id,
            dest_vm_id,
            requested_by: "catalog-lifecycle-test".to_string(),
        })
        .await;

    assert!(
        matches!(result, Err(MigrationError::Http(_))),
        "source ops failure remains the public execute error, got {result:?}"
    );
    let public_error = result.expect_err("execute must fail").to_string();
    let drifted_identity = http_client.take_drifted_identity();
    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(
        identity_after, drifted_identity,
        "stale execute-failure reset must preserve the newer owner"
    );
    assert_eq!(
        identity_after.tier, "pinned",
        "reset_tenant_tier_after_execute_failure must not set a newer owner active"
    );
    let rows = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT status, error
         FROM index_migrations
         WHERE customer_id = $1 AND index_name = $2",
    )
    .bind(customer)
    .bind("products")
    .fetch_all(&db.pool)
    .await
    .expect("load failed migration row");
    assert_eq!(rows, vec![("failed".to_string(), Some(public_error))]);
    let requests = http_client.recorded_requests();
    assert_eq!(
        requests.len(),
        2,
        "pre-replication execute failure should fetch source ops and attempt source resume only"
    );
    assert!(
        requests
            .iter()
            .all(|request| request.method != Method::DELETE),
        "pre-replication failure must not clean up an unstarted destination replication"
    );
}

#[tokio::test]
async fn migration_execute_failure_recovery_rejects_identity_drift_without_source_overwrite() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_migration_recovery_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let source_vm_id = load_target_identity(&db.pool, customer, "products")
        .await
        .vm_id
        .expect("migration target has source VM");
    let dest_vm_id = Uuid::new_v4();
    let newer_owner_vm_id = Uuid::new_v4();
    insert_vm(&db.pool, dest_vm_id).await;
    insert_vm(&db.pool, newer_owner_vm_id).await;
    let node_secret_manager = mock_node_secret_manager();
    node_secret_manager
        .create_node_api_key(&format!("vm-{source_vm_id}"), "us-east-1")
        .await
        .expect("seed source VM API key");
    node_secret_manager
        .create_node_api_key(&format!("vm-us-east-1-{dest_vm_id}"), "us-east-1")
        .await
        .expect("seed destination VM API key");
    let http_client = Arc::new(CountingMigrationHttpClient::default());
    let index_uid = flapjack_index_uid(customer, "products");
    enqueue_source_ops(&http_client, &index_uid, 100);
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(&index_uid, 100),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(&index_uid, 95),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(&index_uid, 100),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: oplog_metric(&index_uid, 100),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 500,
        body: "destination resume failed".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.enqueue_response(Ok(MigrationHttpResponse {
        status: 200,
        body: "{}".to_string(),
    }));
    http_client.drift_identity_after_resume(
        pool_in_schema(&db.schema).await,
        customer,
        "products",
        newer_owner_vm_id,
    );
    let repo_pool = pooled_repo_connections_in_schema(&db.schema).await;
    let tenant_repo = Arc::new(PgTenantRepo::new(repo_pool.clone()));
    let service = MigrationService::with_http_client_config_and_lifecycle(
        tenant_repo.clone(),
        Arc::new(PgVmInventoryRepo::new(repo_pool.clone())),
        Arc::new(PgIndexMigrationRepo::new(repo_pool)),
        Arc::new(MockAlertService::new()),
        Arc::new(DiscoveryService::with_ttl(
            tenant_repo,
            Arc::new(PgVmInventoryRepo::new(db.pool.clone())),
            3600,
        )),
        node_secret_manager,
        http_client.clone(),
        MigrationConfig {
            max_concurrent: 3,
            rollback_window: Duration::seconds(300),
            replication_timeout: std::time::Duration::from_millis(50),
            replication_poll_interval: std::time::Duration::from_millis(10),
            replication_near_zero_lag_ops: 10,
            long_running_warning_threshold: std::time::Duration::from_secs(600),
        },
        Some(Arc::new(IndexLifecycleLease::new(
            PgAlgoliaImportJobRepo::new(db.pool.clone()),
        ))),
    );

    let result = service
        .execute(MigrationRequest {
            index_name: "products".to_string(),
            customer_id: customer,
            source_vm_id,
            dest_vm_id,
            requested_by: "catalog-lifecycle-test".to_string(),
        })
        .await;

    assert!(
        matches!(result, Err(MigrationError::Http(_))),
        "destination resume failure remains the public execute error, got {result:?}"
    );
    let public_error = result
        .expect_err("destination resume failure must remain public")
        .to_string();
    let identity_after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(
        identity_after.vm_id,
        Some(newer_owner_vm_id),
        "stale execute-failure recovery must not overwrite a newer owner's VM assignment"
    );
    assert_eq!(
        identity_after.tier, "pinned",
        "stale execute-failure recovery must preserve the newer owner's tier"
    );
    let requests = http_client.recorded_requests();
    assert!(
        requests.iter().any(|request| {
            request.method == Method::POST
                && request.url.contains(&format!(
                    "/internal/resume/{}",
                    urlencoding::encode(&index_uid)
                ))
        }),
        "source resume remains outside the guarded catalog publication"
    );
    assert!(
        requests.iter().any(|request| {
            request.method == Method::DELETE
                && request
                    .url
                    .contains(&format!("/1/indexes/{}", urlencoding::encode(&index_uid)))
        }),
        "destination cleanup remains outside the guarded catalog publication"
    );
    let rows = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT status, error
         FROM index_migrations
         WHERE customer_id = $1 AND index_name = $2",
    )
    .bind(customer)
    .bind("products")
    .fetch_all(&db.pool)
    .await
    .expect("load recovery migration row");
    assert_eq!(rows, vec![("failed".to_string(), Some(public_error))]);
}

#[tokio::test]
async fn catalog_lifecycle_lease_rejects_same_customer_same_target_contention() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_same_target").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let first_pool = pool_in_schema(&db.schema).await;
    let second_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(first_pool));
    let competing_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(second_pool));

    let first = service
        .begin(customer, "products")
        .await
        .expect("first lifecycle guard");
    let second = competing_service.begin(customer, "products").await;

    assert!(
        matches!(second, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
    service
        .commit(first, None)
        .await
        .expect("commit first guard");
}

#[tokio::test]
async fn catalog_lifecycle_lease_allows_equal_logical_names_across_tenants() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_cross_tenant").await else {
        return;
    };
    let first_customer = Uuid::new_v4();
    let second_customer = Uuid::new_v4();
    insert_active_customer(&db.pool, first_customer, 1).await;
    insert_active_customer(&db.pool, second_customer, 1).await;
    let first_pool = pool_in_schema(&db.schema).await;
    let second_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(first_pool));
    let second_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(second_pool));

    let first = service
        .begin(first_customer, "products")
        .await
        .expect("first customer guard");
    let second = second_service
        .begin(second_customer, "products")
        .await
        .expect("same target name for another customer must not conflict");

    second_service
        .commit(second, None)
        .await
        .expect("commit second guard");
    service
        .commit(first, None)
        .await
        .expect("commit first guard");
}

#[tokio::test]
async fn catalog_lifecycle_lease_serializes_two_api_workers_racing() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_workers").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let first_pool = pool_in_schema(&db.schema).await;
    let second_pool = pool_in_schema(&db.schema).await;
    let first_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(first_pool));
    let second_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(second_pool));

    let first = first_service
        .begin(customer, "products")
        .await
        .expect("first worker guard");
    let second = second_service.begin(customer, "products").await;

    assert!(
        matches!(second, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
    first_service
        .commit(first, None)
        .await
        .expect("commit first guard");
}

#[tokio::test]
async fn catalog_lifecycle_lease_drop_rolls_back_and_releases_target() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_rollback").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));

    let first = service
        .begin(customer, "products")
        .await
        .expect("first guard");
    drop(first);
    let second = service
        .begin(customer, "products")
        .await
        .expect("dropped transaction-scoped guard must release target");

    service
        .commit(second, None)
        .await
        .expect("commit second guard");
}

#[tokio::test]
async fn replacement_reservation_blocks_lifecycle_writer() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_replace_blocks").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    repo.create_replace(replace_job(customer, "products", "replace-key"))
        .await
        .expect("replace reservation");
    let service = IndexLifecycleLease::new(repo);

    let guarded = service.begin(customer, "products").await;

    assert!(
        matches!(guarded, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
}

#[tokio::test]
async fn lifecycle_writer_blocks_replacement_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_blocks_replace").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;
    let guarded_pool = pool_in_schema(&db.schema).await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(guarded_pool));
    let repo = PgAlgoliaImportJobRepo::new(competing_pool);
    let guard = service
        .begin(customer, "products")
        .await
        .expect("lifecycle guard");

    let replaced = repo
        .create_replace(replace_job(customer, "products", "replace-key"))
        .await;

    assert!(admission_refusal_code(&replaced) == Some("destination_conflict"));
    service
        .commit(guard, Some(&expected_identity))
        .await
        .expect("commit lifecycle guard");
}

#[tokio::test]
async fn import_reservation_blocks_lifecycle_writer() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_import_blocks").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    repo.create(import_job(customer, "products", "import-key"))
        .await
        .expect("import reservation");
    let service = IndexLifecycleLease::new(repo);

    let guarded = service.begin(customer, "products").await;

    assert!(
        matches!(guarded, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
}

#[tokio::test]
async fn guarded_mutation_rejects_active_import_without_running_callback() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_guarded_import_blocks").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    repo.create(import_job(customer, "products", "import-key"))
        .await
        .expect("import reservation");
    let service = IndexLifecycleLease::new(repo);
    let callback_calls = Arc::new(AtomicUsize::new(0));

    let mutated = service
        .guarded_mutation(customer, "products", None, {
            let callback_calls = Arc::clone(&callback_calls);
            move || async move {
                callback_calls.fetch_add(1, Ordering::SeqCst);
                Ok::<_, RepoError>(())
            }
        })
        .await;

    assert!(
        matches!(mutated, Err(RepoError::Conflict(message)) if message == "destination_conflict")
    );
    assert_eq!(
        callback_calls.load(Ordering::SeqCst),
        0,
        "guarded mutation callback must not run after active reservation refusal"
    );
}

#[tokio::test]
async fn guarded_mutation_rejects_identity_drift_without_running_callback() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_guarded_identity_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;
    update_replace_target_column(
        &db.pool,
        customer,
        "products",
        "customer_tenants",
        "tier",
        "migrating",
    )
    .await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));
    let callback_calls = Arc::new(AtomicUsize::new(0));

    let mutated = service
        .guarded_mutation(customer, "products", Some(&expected_identity), {
            let callback_calls = Arc::clone(&callback_calls);
            move || async move {
                callback_calls.fetch_add(1, Ordering::SeqCst);
                Ok::<_, RepoError>(())
            }
        })
        .await;

    assert!(
        matches!(mutated, Err(RepoError::Conflict(message)) if message == "destination_changed")
    );
    assert_eq!(
        callback_calls.load(Ordering::SeqCst),
        0,
        "guarded mutation callback must not run after identity validation refusal"
    );
}

#[tokio::test]
async fn guarded_mutation_allows_create_callback_to_publish_expected_absent_target() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_guarded_create_callback").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));
    let callback_pool = pool_in_schema(&db.schema).await;

    service
        .guarded_mutation(customer, "products", None, || async {
            insert_authenticated_target_row(&callback_pool, customer, "products").await;
            Ok::<_, RepoError>(())
        })
        .await
        .expect("guarded create callback");

    let identity = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(identity.tier, "active");
    assert_eq!(identity.service_type, "flapjack");
    assert!(
        identity.vm_id.is_some(),
        "create callback must publish the target row"
    );
}

#[tokio::test]
async fn guarded_mutation_cancellation_releases_advisory_key() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_guarded_cancel_release").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let guarded_pool = pool_in_schema(&db.schema).await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = Arc::new(IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(
        guarded_pool,
    )));
    let competing_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(competing_pool));
    let callback_calls = Arc::new(AtomicUsize::new(0));
    let (entered_tx, entered_rx) = oneshot::channel();
    let (_release_tx, release_rx) = oneshot::channel::<()>();

    let task = tokio::spawn({
        let service = Arc::clone(&service);
        let callback_calls = Arc::clone(&callback_calls);
        async move {
            service
                .guarded_mutation(customer, "products", None, move || async move {
                    callback_calls.fetch_add(1, Ordering::SeqCst);
                    let _ = entered_tx.send(());
                    let _ = release_rx.await;
                    Ok::<_, RepoError>(())
                })
                .await
        }
    });
    entered_rx.await.expect("guarded callback entered");

    let blocked = competing_service.begin(customer, "products").await;
    assert!(
        matches!(blocked, Err(RepoError::Conflict(message)) if message == "destination_conflict"),
        "competing guard must be blocked while callback owns the advisory key"
    );

    task.abort();
    assert!(task
        .await
        .expect_err("cancel guarded mutation")
        .is_cancelled());

    let next_guard = begin_lifecycle_guard_with_retry(&competing_service, customer, "products")
        .await
        .expect("cancelled guarded mutation must release target");
    competing_service
        .commit(next_guard, None)
        .await
        .expect("commit guard after cancellation");
    assert_eq!(
        callback_calls.load(Ordering::SeqCst),
        1,
        "cancelled guarded mutation should only enter the callback once"
    );
}

#[tokio::test]
async fn lifecycle_guard_connection_loss_releases_advisory_key() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_guard_conn_loss").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let application_name = format!("catalog-lifecycle-guard-{}", Uuid::new_v4());
    let guarded_pool =
        pool_in_schema_with_application_name(&db.schema, Some(application_name.clone())).await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(guarded_pool));
    let competing_service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(competing_pool));
    let guard = service
        .begin(customer, "products")
        .await
        .expect("first lifecycle guard");

    let blocked = competing_service.begin(customer, "products").await;
    assert!(
        matches!(blocked, Err(RepoError::Conflict(message)) if message == "destination_conflict"),
        "competing guard must be blocked before connection loss"
    );

    let terminated = sqlx::query_scalar::<_, Option<bool>>(
        "SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE application_name = $1 AND pid <> pg_backend_pid()
         LIMIT 1",
    )
    .bind(&application_name)
    .fetch_optional(&db.pool)
    .await
    .expect("terminate guarded backend")
    .flatten();
    assert_eq!(
        terminated,
        Some(true),
        "guarded backend should be terminated by application_name"
    );

    let released_guard = begin_lifecycle_guard_with_retry(&competing_service, customer, "products")
        .await
        .expect("connection loss must release advisory target");
    competing_service
        .commit(released_guard, None)
        .await
        .expect("commit guard after connection loss");

    drop(guard);
}

#[tokio::test]
async fn tenant_repo_creates_non_discoverable_provisioning_intent_atomically() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_tenant_create_intent").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let deployment_id = Uuid::new_v4();
    insert_running_deployment(&db.pool, customer, deployment_id).await;
    let repo = PgTenantRepo::new(db.pool.clone());

    let intent = repo
        .create_lifecycle_intent(customer, "products", deployment_id, "provisioning")
        .await
        .expect("create provisioning intent");

    assert_eq!(intent.customer_id, customer);
    assert_eq!(intent.tenant_id, "products");
    assert_eq!(intent.deployment_id, deployment_id);
    assert_eq!(intent.tier, "provisioning");
    assert_eq!(intent.vm_id, None);
    assert_eq!(intent.service_type, "flapjack");
}

#[tokio::test]
async fn tenant_repo_publish_placement_rejects_identity_drift_without_changes() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_tenant_publish_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let deployment_id = Uuid::new_v4();
    let vm_id = Uuid::new_v4();
    insert_running_deployment(&db.pool, customer, deployment_id).await;
    insert_vm(&db.pool, vm_id).await;
    let repo = PgTenantRepo::new(db.pool.clone());
    let intent = repo
        .create_lifecycle_intent(customer, "products", deployment_id, "provisioning")
        .await
        .expect("create provisioning intent");
    let expected_identity = CatalogLifecycleTargetIdentity {
        deployment_id: intent.deployment_id,
        vm_id: intent.vm_id,
        tier: intent.tier.clone(),
        cold_snapshot_id: intent.cold_snapshot_id,
        service_type: intent.service_type.clone(),
    };
    repo.set_tier(customer, "products", "deleting")
        .await
        .expect("drift intent tier");

    let published = repo
        .publish_lifecycle_placement(customer, "products", &expected_identity, Some(vm_id))
        .await;

    assert!(
        matches!(&published, Err(RepoError::Conflict(message)) if message == "destination_changed"),
        "stale publication must return destination_changed, got {published:?}"
    );
    let after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(after.tier, "deleting");
    assert_eq!(after.vm_id, None);
}

#[tokio::test]
async fn tenant_repo_publishes_delete_intent_with_active_identity_cas() {
    let Some(db) = connect_and_migrate("tenant_repo_publish_delete_intent").await else {
        return;
    };
    let customer = Uuid::new_v4();
    let vm_id = seed_delete_route_target(&db.pool, customer, "products").await;
    let repo = PgTenantRepo::new(db.pool.clone());
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;

    let deleting = repo
        .publish_delete_lifecycle_intent(customer, "products", &expected_identity)
        .await
        .expect("publish delete intent");

    assert_eq!(deleting.customer_id, customer);
    assert_eq!(deleting.tenant_id, "products");
    assert_eq!(deleting.deployment_id, expected_identity.deployment_id);
    assert_eq!(deleting.vm_id, Some(vm_id));
    assert_eq!(deleting.tier, "deleting");
    assert_eq!(deleting.cold_snapshot_id, None);
    assert_eq!(deleting.service_type, "flapjack");
}

#[tokio::test]
async fn tenant_repo_delete_intent_rejects_identity_drift_without_changes() {
    let Some(db) = connect_and_migrate("tenant_repo_publish_delete_drift").await else {
        return;
    };
    let customer = Uuid::new_v4();
    seed_delete_route_target(&db.pool, customer, "products").await;
    let repo = PgTenantRepo::new(db.pool.clone());
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;
    repo.set_tier(customer, "products", "migrating")
        .await
        .expect("drift source tier");

    let published = repo
        .publish_delete_lifecycle_intent(customer, "products", &expected_identity)
        .await;

    assert!(
        matches!(&published, Err(RepoError::Conflict(message)) if message == "destination_changed"),
        "stale delete intent publication must return destination_changed, got {published:?}"
    );
    let after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(after.tier, "migrating");
    assert_eq!(after.vm_id, expected_identity.vm_id);
}

#[tokio::test]
async fn tenant_repo_removes_matching_lifecycle_intent() {
    let Some(db) = connect_and_migrate("tenant_repo_remove_matching_intent").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let deployment_id = Uuid::new_v4();
    insert_running_deployment(&db.pool, customer, deployment_id).await;
    let repo = PgTenantRepo::new(db.pool.clone());
    repo.create_lifecycle_intent(customer, "products", deployment_id, "provisioning")
        .await
        .expect("create provisioning intent");
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;

    let removed = repo
        .remove_lifecycle_intent(customer, "products", &expected_identity)
        .await
        .expect("remove matching lifecycle intent");

    assert!(removed, "matching lifecycle intent must be removed");
    assert!(
        tenant_rows(&db.pool, customer).await.is_empty(),
        "matching removal must leave no tenant row"
    );
}

#[tokio::test]
async fn tenant_repo_preserves_drifted_lifecycle_intent() {
    let Some(db) = connect_and_migrate("tenant_repo_preserve_drifted_intent").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let deployment_id = Uuid::new_v4();
    insert_running_deployment(&db.pool, customer, deployment_id).await;
    let repo = PgTenantRepo::new(db.pool.clone());
    repo.create_lifecycle_intent(customer, "products", deployment_id, "provisioning")
        .await
        .expect("create provisioning intent");
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;
    repo.set_tier(customer, "products", "deleting")
        .await
        .expect("drift intent tier");

    let removed = repo
        .remove_lifecycle_intent(customer, "products", &expected_identity)
        .await;

    assert!(
        matches!(&removed, Err(RepoError::Conflict(message)) if message == "destination_changed"),
        "stale removal must return destination_changed, got {removed:?}"
    );
    let after = load_target_identity(&db.pool, customer, "products").await;
    assert_eq!(after.tier, "deleting");
    assert_eq!(tenant_rows(&db.pool, customer).await.len(), 1);
}

#[tokio::test]
async fn migration_allows_catalog_lifecycle_intent_tiers_only() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_intent_tiers").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;

    for tier in ["provisioning", "deleting"] {
        sqlx::query(
            "UPDATE customer_tenants
             SET tier = $3
             WHERE customer_id = $1 AND tenant_id = $2",
        )
        .bind(customer)
        .bind("products")
        .bind(tier)
        .execute(&db.pool)
        .await
        .unwrap_or_else(|error| panic!("intent tier {tier} must satisfy tier constraint: {error}"));
    }

    let invalid = sqlx::query(
        "UPDATE customer_tenants
         SET tier = 'catalog_lifecycle_shadow'
         WHERE customer_id = $1 AND tenant_id = $2",
    )
    .bind(customer)
    .bind("products")
    .execute(&db.pool)
    .await;

    assert!(
        invalid.is_err(),
        "tier constraint must remain closed outside known lifecycle states"
    );
}

#[tokio::test]
async fn lifecycle_writer_blocks_import_reservation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_blocks_import").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let guarded_pool = pool_in_schema(&db.schema).await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(guarded_pool));
    let repo = PgAlgoliaImportJobRepo::new(competing_pool);
    let guard = service
        .begin(customer, "products")
        .await
        .expect("lifecycle guard");

    let imported = repo
        .create(import_job(customer, "products", "import-key"))
        .await;

    assert!(admission_refusal_code(&imported) == Some("destination_conflict"));
    service
        .commit(guard, None)
        .await
        .expect("commit lifecycle guard");
}

#[tokio::test]
async fn catalog_lifecycle_commit_rejects_changed_target_identity() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_identity_changed").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let expected_identity = load_target_identity(&db.pool, customer, "products").await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));

    update_replace_target_column(
        &competing_pool,
        customer,
        "products",
        "customer_tenants",
        "tier",
        "migrating",
    )
    .await;
    let guard = service
        .begin(customer, "products")
        .await
        .expect("lifecycle guard");

    let committed = service.commit(guard, Some(&expected_identity)).await;

    assert!(matches!(
        committed,
        Err(RepoError::Conflict(message)) if message == "destination_changed"
    ));
}

#[tokio::test]
async fn catalog_lifecycle_create_commit_rejects_unexpected_target_appearance() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_target_appears").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_active_customer(&db.pool, customer, 1).await;
    let competing_pool = pool_in_schema(&db.schema).await;
    let service = IndexLifecycleLease::new(PgAlgoliaImportJobRepo::new(db.pool.clone()));

    insert_authenticated_target_row(&competing_pool, customer, "products").await;
    let guard = service
        .begin(customer, "products")
        .await
        .expect("lifecycle guard");

    let committed = service.commit(guard, None).await;

    assert!(matches!(
        committed,
        Err(RepoError::Conflict(message)) if message == "destination_changed"
    ));
}

fn writer_id(owner_path: &str, function_name: &str, source_anchor: &str) -> String {
    format!(
        "catalog_writer__{}__{}__{}",
        slug(owner_path.trim_end_matches(".rs")),
        slug(function_name),
        slug(source_anchor)
    )
}

fn slug(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect::<String>()
        .split('_')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("_")
}

/// A soft-deleted customer's catalog target stays fenced across every lease
/// entrypoint. `read_active_customer_generation` inside
/// `begin_lifecycle_target_guard_inner` refuses `begin`, `guarded_mutation`, and
/// `guarded_locked_mutation` with the existing `customer lifecycle is not active`
/// conflict before any mutation callback runs, and the retained catalog target,
/// deployment, and active-reservation rows are left byte-for-byte unchanged.
#[tokio::test]
async fn soft_deleted_customer_lease_entrypoints_refuse_without_running_mutation() {
    let Some(db) = connect_and_migrate("catalog_lifecycle_soft_delete_lease").await else {
        return;
    };
    let customer = Uuid::new_v4();
    insert_replace_target(&db.pool, customer, "products").await;
    let repo = PgAlgoliaImportJobRepo::new(db.pool.clone());
    // Retained active reservation evidence, captured at the customer's active
    // generation (G) before the delete.
    repo.create_replace(replace_job(
        customer,
        "products",
        "retained-soft-delete-lease",
    ))
    .await
    .expect("seed active replacement reservation at generation G");

    let before_delete = RetainedTargetSnapshot::load(&db.pool, customer, "products").await;
    assert_eq!(
        before_delete.operations.len(),
        1,
        "active reservation evidence must be present before the delete"
    );

    // Real customer soft delete: status active -> deleted, generation G -> G+1.
    assert!(
        PgCustomerRepo::new(db.pool.clone())
            .soft_delete(customer)
            .await
            .expect("soft delete active customer"),
        "soft_delete must report it changed the active customer row"
    );

    let lease = IndexLifecycleLease::new(repo.clone());

    match lease.begin(customer, "products").await {
        Err(RepoError::Conflict(message)) => assert_eq!(
            message, "customer lifecycle is not active",
            "begin must refuse a soft-deleted customer with the lifecycle conflict"
        ),
        Ok(_) => panic!("begin must refuse a soft-deleted customer, but a guard was granted"),
        Err(other) => {
            panic!("begin must refuse with the lifecycle conflict, got {other:?}")
        }
    }
    before_delete
        .assert_unchanged_after(&db.pool, customer, "begin")
        .await;

    let guarded_calls = Arc::new(AtomicUsize::new(0));
    let before_guarded = RetainedTargetSnapshot::load(&db.pool, customer, "products").await;
    let guarded = lease
        .guarded_mutation(customer, "products", None, {
            let guarded_calls = Arc::clone(&guarded_calls);
            move || async move {
                guarded_calls.fetch_add(1, Ordering::SeqCst);
                Ok::<(), RepoError>(())
            }
        })
        .await;
    assert!(
        matches!(
            &guarded,
            Err(RepoError::Conflict(message)) if message == "customer lifecycle is not active"
        ),
        "guarded_mutation must refuse a soft-deleted customer, got {guarded:?}"
    );
    assert_eq!(
        guarded_calls.load(Ordering::SeqCst),
        0,
        "guarded_mutation callback must not run behind the deleted-customer fence"
    );
    before_guarded
        .assert_unchanged_after(&db.pool, customer, "guarded_mutation")
        .await;

    let locked_calls = Arc::new(AtomicUsize::new(0));
    let before_locked = RetainedTargetSnapshot::load(&db.pool, customer, "products").await;
    let locked = lease
        .guarded_locked_mutation(customer, "products", {
            let locked_calls = Arc::clone(&locked_calls);
            move || async move {
                locked_calls.fetch_add(1, Ordering::SeqCst);
                Ok::<(), RepoError>(())
            }
        })
        .await;
    assert!(
        matches!(
            &locked,
            Err(RepoError::Conflict(message)) if message == "customer lifecycle is not active"
        ),
        "guarded_locked_mutation must refuse a soft-deleted customer, got {locked:?}"
    );
    assert_eq!(
        locked_calls.load(Ordering::SeqCst),
        0,
        "guarded_locked_mutation callback must not run behind the deleted-customer fence"
    );
    before_locked
        .assert_unchanged_after(&db.pool, customer, "guarded_locked_mutation")
        .await;
}

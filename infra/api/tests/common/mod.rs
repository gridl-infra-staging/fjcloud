// Each platform-test shard compiles this shared support module independently,
// so helpers used by one integration file can appear unused in another.
#![allow(dead_code)]

//! Stub summary for mod.rs.

pub mod admin_broadcast_test_support;
pub mod admin_vm_retirement_test_support;
pub mod algolia_import_job_test_support;
pub mod algolia_import_reservation_lifetime;
pub mod builders;
pub mod capacity_profiles;
pub mod catalog_live_binding;
pub mod engine_health;
pub mod engine_index_identity_test_support;
pub mod flapjack_proxy_test_support;
pub mod indexes_route_test_support;
#[cfg(not(test))]
pub mod integration_helpers;
#[cfg(test)]
#[path = "integration_helpers.rs"]
pub mod integration_helpers;
pub mod live_stripe_helpers;
pub mod mocks;
pub mod poll;
pub mod source_assertions;
pub mod storage_metering_test_support;
pub mod storage_s3_auth_support;
pub mod storage_s3_object_route_support;
pub mod storage_s3_signed_router_harness;
pub mod stripe_webhook_test_support;
pub mod support;
pub mod vm_inventory_reference_guard_fixtures;
pub mod vm_inventory_reference_guard_matrix;
pub mod vm_inventory_reference_guard_races;
pub mod vm_inventory_repo_contract;
pub mod vm_inventory_repo_races;

pub use builders::*;
pub use mocks::*;

use api::auth::Claims;
use api::models::vm_inventory::NewVmInventory;
use api::openapi::ApiDoc;
use api::repos::index_replica_repo::IndexReplicaRepo;
use api::repos::{TenantRepo, VmInventoryRepo};
use api::secrets::{mock::MockNodeSecretManager, NodeSecretManager};
use api::services::object_store::{InMemoryObjectStore, ObjectStore, ObjectStoreError};
use api::services::replication::{ReplicationConfig, ReplicationOrchestrator};
use async_trait::async_trait;
use chrono::{Duration, Utc};
use jsonwebtoken::{EncodingKey, Header};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use utoipa::OpenApi;
use uuid::Uuid;

/// Parse the generated ApiDoc spec into JSON for OpenAPI integration assertions.
pub fn openapi_spec_json() -> serde_json::Value {
    let json_str = ApiDoc::openapi()
        .to_json()
        .expect("ApiDoc should serialize to JSON");
    serde_json::from_str(&json_str).expect("spec JSON should parse")
}

fn unix_now() -> usize {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as usize
}

fn encode_jwt(customer_id: Uuid, exp: usize, iat: usize, secret: &str) -> String {
    let claims = Claims {
        sub: customer_id.to_string(),
        exp,
        iat,
    };

    jsonwebtoken::encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .expect("JWT encoding should not fail")
}

/// Generate a valid JWT signed with `TEST_JWT_SECRET`, expiring in 1 hour.
pub fn create_test_jwt(customer_id: Uuid) -> String {
    let now = unix_now();
    encode_jwt(customer_id, now + 3600, now, TEST_JWT_SECRET)
}

/// Generate an expired JWT (exp = now - 3600, well past the 60-second leeway).
pub fn create_expired_jwt(customer_id: Uuid) -> String {
    let now = unix_now();
    encode_jwt(customer_id, now - 3600, now - 7200, TEST_JWT_SECRET)
}

/// Generate a JWT signed with a custom secret (for wrong-secret tests).
pub fn create_jwt_with_secret(customer_id: Uuid, secret: &str) -> String {
    let now = unix_now();
    encode_jwt(customer_id, now + 3600, now, secret)
}

pub struct TestOAuthProvider {
    pub token_endpoint: String,
    pub userinfo_endpoint: String,
}

pub async fn spawn_test_oauth_provider() -> TestOAuthProvider {
    let app = axum::Router::new()
        .route(
            "/oauth/token",
            axum::routing::post(
                |axum::Form(params): axum::Form<HashMap<String, String>>| async move {
                    let code = params.get("code").map(String::as_str).unwrap_or_default();
                    if code == "provider-error" {
                        return (
                            axum::http::StatusCode::BAD_GATEWAY,
                            axum::Json(serde_json::json!({"error": "simulated_exchange_failure"})),
                        );
                    }
                    (
                        axum::http::StatusCode::OK,
                        axum::Json(serde_json::json!({"access_token": format!("token-{code}")})),
                    )
                },
            ),
        )
        .route(
            "/oauth/userinfo",
            axum::routing::get(|headers: axum::http::HeaderMap| async move {
                let auth = headers
                    .get(axum::http::header::AUTHORIZATION)
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or_default();
                if !auth.starts_with("Bearer token-") {
                    return (
                        axum::http::StatusCode::UNAUTHORIZED,
                        axum::Json(serde_json::json!({"error": "missing_or_invalid_token"})),
                    );
                }
                (
                    axum::http::StatusCode::OK,
                    axum::Json(serde_json::json!({
                        "sub": "google-provider-user-1",
                        "email": "oauth-happy-path@integration.test",
                        "name": "OAuth Happy Path"
                    })),
                )
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind oauth test provider listener");
    let addr = listener
        .local_addr()
        .expect("resolve oauth test provider listener address");
    tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve oauth test provider");
    });

    let base = format!("http://127.0.0.1:{}", addr.port());
    TestOAuthProvider {
        token_endpoint: format!("{base}/oauth/token"),
        userinfo_endpoint: format!("{base}/oauth/userinfo"),
    }
}

pub struct ReplicationHarness {
    pub orchestrator: ReplicationOrchestrator,
    pub http_client: Arc<MockReplicationHttpClient>,
    pub replica_repo: Arc<api::repos::InMemoryIndexReplicaRepo>,
    pub replica_id: Uuid,
}

/// Shared replication setup used by both reliability and unit replication tests.
/// `seed_replica_key=false` is useful for secret lookup failure scenarios.
pub async fn setup_replication_harness(
    config: ReplicationConfig,
    seed_replica_key: bool,
) -> ReplicationHarness {
    let vm_repo = mock_vm_inventory_repo();
    let primary_vm = vm_repo
        .create(vm_seed("us-east-1", "aws", "vm-primary"))
        .await
        .unwrap();
    let replica_vm = vm_repo
        .create(vm_seed("eu-central-1", "hetzner", "vm-replica"))
        .await
        .unwrap();

    let customer_id = Uuid::new_v4();
    let replica_repo = Arc::new(api::repos::InMemoryIndexReplicaRepo::new());
    let replica = replica_repo
        .create(
            customer_id,
            "products",
            primary_vm.id,
            replica_vm.id,
            "eu-central-1",
        )
        .await
        .unwrap();

    let http_client = Arc::new(MockReplicationHttpClient::new());
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key(&primary_vm.id.to_string(), &primary_vm.region)
        .await
        .unwrap();
    if seed_replica_key {
        node_secret_manager
            .create_node_api_key(&replica_vm.id.to_string(), &replica_vm.region)
            .await
            .unwrap();
    }

    let orchestrator = ReplicationOrchestrator::new(
        replica_repo.clone() as Arc<dyn IndexReplicaRepo>,
        vm_repo,
        http_client.clone(),
        node_secret_manager as Arc<dyn NodeSecretManager>,
        config,
    );

    ReplicationHarness {
        orchestrator,
        http_client,
        replica_repo,
        replica_id: replica.id,
    }
}

pub fn vm_seed(region: &str, provider: &str, hostname: &str) -> NewVmInventory {
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

pub fn oplog_metric(index_name: &str, seq: i64) -> String {
    format!(r#"flapjack_oplog_current_seq{{index="{index_name}"}} {seq}"#)
}

// ---------------------------------------------------------------------------
// FailableObjectStore — wraps InMemoryObjectStore with a should_fail toggle
// ---------------------------------------------------------------------------

pub struct FailableObjectStore {
    inner: Arc<InMemoryObjectStore>,
    should_fail: Arc<AtomicBool>,
    put_calls: AtomicUsize,
}

impl FailableObjectStore {
    pub fn new(inner: Arc<InMemoryObjectStore>, should_fail: Arc<AtomicBool>) -> Self {
        Self {
            inner,
            should_fail,
            put_calls: AtomicUsize::new(0),
        }
    }

    pub fn inner(&self) -> &InMemoryObjectStore {
        &self.inner
    }

    pub fn put_call_count(&self) -> usize {
        self.put_calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl ObjectStore for FailableObjectStore {
    async fn put(&self, key: &str, data: &[u8]) -> Result<(), ObjectStoreError> {
        self.put_calls.fetch_add(1, Ordering::SeqCst);
        if self.should_fail.load(Ordering::SeqCst) {
            return Err(ObjectStoreError::Other(
                "403 Forbidden: access denied".into(),
            ));
        }
        self.inner.put(key, data).await
    }

    async fn get(&self, key: &str) -> Result<Vec<u8>, ObjectStoreError> {
        if self.should_fail.load(Ordering::SeqCst) {
            return Err(ObjectStoreError::Other(
                "403 Forbidden: access denied".into(),
            ));
        }
        self.inner.get(key).await
    }

    async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        if self.should_fail.load(Ordering::SeqCst) {
            return Err(ObjectStoreError::Other(
                "403 Forbidden: access denied".into(),
            ));
        }
        self.inner.delete(key).await
    }

    async fn exists(&self, key: &str) -> Result<bool, ObjectStoreError> {
        if self.should_fail.load(Ordering::SeqCst) {
            return Err(ObjectStoreError::Other(
                "403 Forbidden: access denied".into(),
            ));
        }
        self.inner.exists(key).await
    }

    async fn size(&self, key: &str) -> Result<u64, ObjectStoreError> {
        if self.should_fail.load(Ordering::SeqCst) {
            return Err(ObjectStoreError::Other(
                "403 Forbidden: access denied".into(),
            ));
        }
        self.inner.size(key).await
    }
}

/// Seed an idle index (last accessed 31 days ago) with all the dependent entities
/// needed by ColdTierService: customer, VM inventory, deployment, and tenant.
pub async fn seed_idle_cold_tier_index(
    customer_repo: &MockCustomerRepo,
    tenant_repo: &MockTenantRepo,
    vm_inventory_repo: &MockVmInventoryRepo,
    tenant_id: &str,
) -> (Uuid, Uuid) {
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let deployment_id = Uuid::new_v4();
    let vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: format!("vm-{}.flapjack.foo", Uuid::new_v4()),
            flapjack_url: "http://vm-1.flapjack.foo".to_string(),
            capacity: serde_json::json!({
                "cpu": 100.0,
                "memory_mb": 4096.0,
                "disk_gb": 100.0
            }),
        })
        .await
        .expect("create vm");
    let vm_id = vm.id;

    tenant_repo.seed_deployment(
        deployment_id,
        "us-east-1",
        Some("http://vm-1.flapjack.foo"),
        "healthy",
        "running",
    );

    tenant_repo
        .create(customer.id, tenant_id, deployment_id)
        .await
        .expect("create tenant");

    tenant_repo
        .set_vm_id(customer.id, tenant_id, vm_id)
        .await
        .expect("set vm_id");

    tenant_repo
        .set_last_accessed_at(
            customer.id,
            tenant_id,
            Some(Utc::now() - Duration::days(31)),
        )
        .expect("set last_accessed_at");

    (customer.id, vm_id)
}

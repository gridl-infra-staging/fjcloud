mod common;

use api::models::RateCardRow;
use api::services::object_store::{InMemoryObjectStore, ObjectStore, ObjectStoreError};
use api::startup_env::{ColdStorageStartupMode, RawEnvFamilyState, StartupEnvSnapshot};
use chrono::Utc;
use rust_decimal_macros::dec;
use serde_json::json;
use std::sync::{Mutex, OnceLock};
use uuid::Uuid;

fn sample_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "launch-2026".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.200000),
        region_multipliers: json!({"us-east-1": "1.0"}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.020000),
        object_storage_rate_per_gb_month: dec!(0.024000),
        object_storage_egress_rate_per_gb: dec!(0.010000),
        created_at: Utc::now(),
    }
}

fn object_store_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, previous }
    }

    fn unset(key: &'static str) -> Self {
        let previous = std::env::var(key).ok();
        std::env::remove_var(key);
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

#[tokio::test]
async fn in_memory_object_store_put_get_delete() {
    let store = InMemoryObjectStore::new();

    store
        .put("cold/customer-a/index-a/snapshot.fj", b"snapshot-bytes")
        .await
        .expect("put should succeed");

    assert!(store
        .exists("cold/customer-a/index-a/snapshot.fj")
        .await
        .expect("exists should succeed"));
    assert_eq!(
        store
            .size("cold/customer-a/index-a/snapshot.fj")
            .await
            .expect("size should succeed"),
        14
    );

    let bytes = store
        .get("cold/customer-a/index-a/snapshot.fj")
        .await
        .expect("get should succeed");
    assert_eq!(bytes, b"snapshot-bytes");

    store
        .delete("cold/customer-a/index-a/snapshot.fj")
        .await
        .expect("delete should succeed");

    assert!(!store
        .exists("cold/customer-a/index-a/snapshot.fj")
        .await
        .expect("exists after delete should succeed"));
    assert!(matches!(
        store.get("cold/customer-a/index-a/snapshot.fj").await,
        Err(ObjectStoreError::NotFound(_))
    ));
}

#[tokio::test]
async fn app_state_includes_usable_object_store() {
    let state = common::test_state();

    state
        .object_store
        .put("test/key", b"hello")
        .await
        .expect("state object store should accept puts");

    let bytes = state
        .object_store
        .get("test/key")
        .await
        .expect("state object store should return stored bytes");

    assert_eq!(bytes, b"hello");
}

#[test]
fn s3_object_store_with_custom_endpoint_configures_correctly() {
    use api::services::object_store::S3ObjectStoreConfig;

    let _lock = object_store_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _bucket = EnvVarGuard::set("COLD_STORAGE_BUCKET", "my-bucket");
    let _prefix = EnvVarGuard::set("COLD_STORAGE_PREFIX", "snapshots");
    let _region = EnvVarGuard::set("COLD_STORAGE_REGION", "eu-central-1");
    let _endpoint = EnvVarGuard::set(
        "COLD_STORAGE_ENDPOINT",
        "https://fsn1.your-objectstorage.com",
    );
    let _access_key = EnvVarGuard::set("COLD_STORAGE_ACCESS_KEY", "cold-access");
    let _secret_key = EnvVarGuard::set("COLD_STORAGE_SECRET_KEY", "cold-secret");

    let config = S3ObjectStoreConfig::from_env();
    assert_eq!(config.bucket, "my-bucket");
    assert_eq!(config.prefix, "snapshots");
    assert_eq!(config.region, "eu-central-1");
    assert_eq!(
        config.endpoint.as_deref(),
        Some("https://fsn1.your-objectstorage.com")
    );
    assert_eq!(config.access_key.as_deref(), Some("cold-access"));
    assert_eq!(config.secret_key.as_deref(), Some("cold-secret"));
}

#[test]
fn s3_object_store_default_uses_aws() {
    use api::services::object_store::S3ObjectStoreConfig;

    let _lock = object_store_env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _endpoint = EnvVarGuard::unset("COLD_STORAGE_ENDPOINT");
    let _bucket = EnvVarGuard::unset("COLD_STORAGE_BUCKET");
    let _prefix = EnvVarGuard::unset("COLD_STORAGE_PREFIX");
    let _region = EnvVarGuard::unset("COLD_STORAGE_REGION");
    let _access_key = EnvVarGuard::unset("COLD_STORAGE_ACCESS_KEY");
    let _secret_key = EnvVarGuard::unset("COLD_STORAGE_SECRET_KEY");

    let config = S3ObjectStoreConfig::from_env();
    assert_eq!(config.bucket, "fjcloud-cold");
    assert_eq!(config.prefix, "");
    assert_eq!(config.region, "us-east-1");
    assert!(config.endpoint.is_none());
    assert!(config.access_key.is_none());
    assert!(config.secret_key.is_none());
}

// ---------------------------------------------------------------------------
// RegionObjectStoreResolver tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn region_resolver_returns_region_specific_store() {
    use api::services::object_store::RegionObjectStoreResolver;
    use std::collections::HashMap;
    use std::sync::Arc;

    let default_store = Arc::new(InMemoryObjectStore::new());
    let eu_store = Arc::new(InMemoryObjectStore::new());

    // Put different data in each store to distinguish them
    default_store.put("marker", b"default").await.unwrap();
    eu_store.put("marker", b"eu-central-1").await.unwrap();

    let mut region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>> = HashMap::new();
    region_stores.insert(
        "eu-central-1".to_string(),
        eu_store.clone() as Arc<dyn ObjectStore + Send + Sync>,
    );

    let resolver = RegionObjectStoreResolver::new(
        default_store.clone() as Arc<dyn ObjectStore + Send + Sync>,
        region_stores,
    );

    // eu-central-1 should return the EU store
    let resolved_eu = resolver.for_region("eu-central-1");
    let eu_data = resolved_eu.get("marker").await.unwrap();
    assert_eq!(eu_data, b"eu-central-1");

    // us-east-1 (not configured) should return the default store
    let resolved_default = resolver.for_region("us-east-1");
    let default_data = resolved_default.get("marker").await.unwrap();
    assert_eq!(default_data, b"default");

    assert_eq!(resolver.region_count(), 1);
}

#[tokio::test]
async fn region_resolver_single_always_returns_default() {
    use api::services::object_store::RegionObjectStoreResolver;
    use std::sync::Arc;

    let store = Arc::new(InMemoryObjectStore::new());
    store.put("key", b"hello").await.unwrap();

    let resolver =
        RegionObjectStoreResolver::single(store.clone() as Arc<dyn ObjectStore + Send + Sync>);

    // Any region should return the default store
    let s1 = resolver.for_region("us-east-1");
    let s2 = resolver.for_region("eu-central-1");
    let s3 = resolver.for_region("unknown-region");

    assert_eq!(s1.get("key").await.unwrap(), b"hello");
    assert_eq!(s2.get("key").await.unwrap(), b"hello");
    assert_eq!(s3.get("key").await.unwrap(), b"hello");
    assert_eq!(resolver.region_count(), 0);
}

#[test]
fn rate_card_cold_storage_override() {
    let card = sample_rate_card();
    let effective = card
        .with_overrides(&json!({
            "cold_storage_rate_per_gb_month": "0.015000",
            "minimum_spend_cents": 300,
            "shared_minimum_spend_cents": 180
        }))
        .expect("overrides should parse");

    assert_eq!(effective.cold_storage_rate_per_gb_month, dec!(0.015000));
    assert_eq!(effective.minimum_spend_cents, 300);
    assert_eq!(effective.shared_minimum_spend_cents, 180);
    // Existing baseline fields remain unchanged when not overridden.
    assert_eq!(effective.storage_rate_per_mb_month, dec!(0.200000));
    assert_eq!(effective.object_storage_rate_per_gb_month, dec!(0.024000));
}

#[test]
fn local_memory_backend_with_absent_cold_storage_env_uses_in_memory_mode() {
    let memory_only = StartupEnvSnapshot::from_reader(|key| match key {
        "NODE_SECRET_BACKEND" => Some("memory".to_string()),
        _ => None,
    });
    assert_eq!(
        memory_only.cold_storage_startup_mode(),
        ColdStorageStartupMode::S3
    );

    let startup_env = StartupEnvSnapshot::from_reader(|key| match key {
        "ENVIRONMENT" => Some("local".to_string()),
        "NODE_SECRET_BACKEND" => Some("memory".to_string()),
        _ => None,
    });

    assert_eq!(
        startup_env.cold_storage_startup_mode(),
        ColdStorageStartupMode::InMemory
    );
    assert_eq!(
        startup_env.cold_storage_family_state(),
        RawEnvFamilyState::AllAbsent
    );
}

#[test]
fn local_memory_backend_with_explicit_cold_storage_env_uses_s3_mode() {
    let startup_env = StartupEnvSnapshot::from_reader(|key| match key {
        "ENVIRONMENT" => Some("local".to_string()),
        "NODE_SECRET_BACKEND" => Some("memory".to_string()),
        "COLD_STORAGE_BUCKET" => Some("fjcloud-cold".to_string()),
        _ => None,
    });

    assert_eq!(
        startup_env.cold_storage_startup_mode(),
        ColdStorageStartupMode::S3
    );
}

#[test]
fn non_local_backend_with_absent_cold_storage_env_uses_s3_mode() {
    let startup_env = StartupEnvSnapshot::from_reader(|_| None);

    assert_eq!(
        startup_env.cold_storage_startup_mode(),
        ColdStorageStartupMode::S3
    );
}

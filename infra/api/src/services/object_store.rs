//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/object_store.rs.
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ObjectStoreError {
    #[error("object not found: {0}")]
    NotFound(String),
    #[error("object store error: {0}")]
    Other(String),
}

#[async_trait]
pub trait ObjectStore: Send + Sync {
    async fn put(&self, key: &str, data: &[u8]) -> Result<(), ObjectStoreError>;
    async fn get(&self, key: &str) -> Result<Vec<u8>, ObjectStoreError>;
    async fn delete(&self, key: &str) -> Result<(), ObjectStoreError>;
    async fn exists(&self, key: &str) -> Result<bool, ObjectStoreError>;
    async fn size(&self, key: &str) -> Result<u64, ObjectStoreError>;
}

/// In-memory object store for testing.
pub struct InMemoryObjectStore {
    data: Mutex<HashMap<String, Vec<u8>>>,
}

impl InMemoryObjectStore {
    pub fn new() -> Self {
        Self {
            data: Mutex::new(HashMap::new()),
        }
    }
}

impl Default for InMemoryObjectStore {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl ObjectStore for InMemoryObjectStore {
    async fn put(&self, key: &str, data: &[u8]) -> Result<(), ObjectStoreError> {
        let mut store = self.data.lock().unwrap();
        store.insert(key.to_string(), data.to_vec());
        Ok(())
    }

    async fn get(&self, key: &str) -> Result<Vec<u8>, ObjectStoreError> {
        let store = self.data.lock().unwrap();
        store
            .get(key)
            .cloned()
            .ok_or_else(|| ObjectStoreError::NotFound(key.to_string()))
    }

    async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        let mut store = self.data.lock().unwrap();
        store.remove(key);
        Ok(())
    }

    async fn exists(&self, key: &str) -> Result<bool, ObjectStoreError> {
        let store = self.data.lock().unwrap();
        Ok(store.contains_key(key))
    }

    async fn size(&self, key: &str) -> Result<u64, ObjectStoreError> {
        let store = self.data.lock().unwrap();
        store
            .get(key)
            .map(|d| d.len() as u64)
            .ok_or_else(|| ObjectStoreError::NotFound(key.to_string()))
    }
}

/// Configuration for building an `S3ObjectStore`.
pub struct S3ObjectStoreConfig {
    pub bucket: String,
    pub prefix: String,
    pub region: String,
    /// Custom S3-compatible endpoint (e.g. Hetzner Object Storage).
    /// When set, enables `force_path_style` for S3-compatible services.
    pub endpoint: Option<String>,
    /// Explicit S3 access key for S3-compatible stores.
    ///
    /// When unset, the AWS SDK's default credential chain is used.
    pub access_key: Option<String>,
    /// Explicit S3 secret key for S3-compatible stores.
    ///
    /// Kept separate from global AWS credentials so local/alternate S3 stores
    /// do not inherit EC2 or Route53 credentials from the process environment.
    pub secret_key: Option<String>,
}

impl S3ObjectStoreConfig {
    pub fn from_env() -> Self {
        Self {
            bucket: std::env::var("COLD_STORAGE_BUCKET")
                .unwrap_or_else(|_| "fjcloud-cold".to_string()),
            prefix: std::env::var("COLD_STORAGE_PREFIX").unwrap_or_default(),
            region: std::env::var("COLD_STORAGE_REGION")
                .unwrap_or_else(|_| "us-east-1".to_string()),
            endpoint: std::env::var("COLD_STORAGE_ENDPOINT").ok(),
            access_key: std::env::var("COLD_STORAGE_ACCESS_KEY").ok(),
            secret_key: std::env::var("COLD_STORAGE_SECRET_KEY").ok(),
        }
    }

    /// Builds an [`S3ObjectStore`] from the given configuration.
    ///
    /// Constructs an AWS SDK S3 client using the configured region, and enables
    /// `force_path_style` when a custom endpoint is set (required for
    /// S3-compatible stores like Garage or MinIO).
    pub async fn build(config: Self) -> S3ObjectStore {
        let aws_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_sdk_s3::config::Region::new(config.region.clone()))
            .load()
            .await;

        let mut s3_config_builder = aws_sdk_s3::config::Builder::from(&aws_config);

        if let Some(ref endpoint) = config.endpoint {
            s3_config_builder = s3_config_builder
                .endpoint_url(endpoint)
                .force_path_style(true);
        }

        match (config.access_key.as_ref(), config.secret_key.as_ref()) {
            (Some(access_key), Some(secret_key)) => {
                let credentials = aws_sdk_s3::config::Credentials::new(
                    access_key,
                    secret_key,
                    None,
                    None,
                    "cold-storage-env",
                );
                s3_config_builder = s3_config_builder.credentials_provider(credentials);
            }
            (Some(_), None) | (None, Some(_)) => {
                tracing::warn!(
                    "ignoring partial COLD_STORAGE_ACCESS_KEY/COLD_STORAGE_SECRET_KEY configuration"
                );
            }
            (None, None) => {}
        }

        let client = aws_sdk_s3::Client::from_conf(s3_config_builder.build());

        S3ObjectStore {
            client,
            bucket: config.bucket,
            prefix: config.prefix,
            endpoint: config.endpoint,
        }
    }
}

/// S3-backed object store for production use.
pub struct S3ObjectStore {
    client: aws_sdk_s3::Client,
    bucket: String,
    prefix: String,
    endpoint: Option<String>,
}

impl S3ObjectStore {
    pub async fn from_env() -> Self {
        S3ObjectStoreConfig::build(S3ObjectStoreConfig::from_env()).await
    }

    pub fn bucket(&self) -> &str {
        &self.bucket
    }

    pub fn prefix(&self) -> &str {
        &self.prefix
    }

    pub fn endpoint(&self) -> Option<&str> {
        self.endpoint.as_deref()
    }

    fn full_key(&self, key: &str) -> String {
        if self.prefix.is_empty() {
            key.to_string()
        } else {
            format!("{}/{}", self.prefix.trim_end_matches('/'), key)
        }
    }
}

#[async_trait]
impl ObjectStore for S3ObjectStore {
    async fn put(&self, key: &str, data: &[u8]) -> Result<(), ObjectStoreError> {
        let full_key = self.full_key(key);
        self.client
            .put_object()
            .bucket(&self.bucket)
            .key(&full_key)
            .body(aws_sdk_s3::primitives::ByteStream::from(data.to_vec()))
            .send()
            .await
            .map_err(|e| ObjectStoreError::Other(e.to_string()))?;
        Ok(())
    }

    /// Downloads an object by key via the S3 `GetObject` API.
    ///
    /// Reads the entire response body into a byte vector. Maps `NoSuchKey`
    /// errors to [`ObjectStoreError::NotFound`].
    async fn get(&self, key: &str) -> Result<Vec<u8>, ObjectStoreError> {
        let full_key = self.full_key(key);
        let resp = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(&full_key)
            .send()
            .await
            .map_err(|e| {
                let msg = e.to_string();
                if msg.contains("NoSuchKey") || msg.contains("not found") {
                    ObjectStoreError::NotFound(key.to_string())
                } else {
                    ObjectStoreError::Other(msg)
                }
            })?;

        let bytes = resp
            .body
            .collect()
            .await
            .map_err(|e| ObjectStoreError::Other(e.to_string()))?
            .into_bytes()
            .to_vec();
        Ok(bytes)
    }

    async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        let full_key = self.full_key(key);
        self.client
            .delete_object()
            .bucket(&self.bucket)
            .key(&full_key)
            .send()
            .await
            .map_err(|e| ObjectStoreError::Other(e.to_string()))?;
        Ok(())
    }

    /// Checks whether an object exists via the S3 `HeadObject` API.
    ///
    /// Returns `true` on success, `false` when the response is `NotFound` or
    /// HTTP 404, and propagates other errors.
    async fn exists(&self, key: &str) -> Result<bool, ObjectStoreError> {
        let full_key = self.full_key(key);
        match self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(&full_key)
            .send()
            .await
        {
            Ok(_) => Ok(true),
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("NotFound") || msg.contains("not found") || msg.contains("404") {
                    Ok(false)
                } else {
                    Err(ObjectStoreError::Other(msg))
                }
            }
        }
    }

    /// Returns the size in bytes of an object via the S3 `HeadObject` API's
    /// `content_length` field.
    ///
    /// Maps not-found responses to [`ObjectStoreError::NotFound`].
    async fn size(&self, key: &str) -> Result<u64, ObjectStoreError> {
        let full_key = self.full_key(key);
        let resp = self
            .client
            .head_object()
            .bucket(&self.bucket)
            .key(&full_key)
            .send()
            .await
            .map_err(|e| {
                let msg = e.to_string();
                if msg.contains("NotFound") || msg.contains("not found") || msg.contains("404") {
                    ObjectStoreError::NotFound(key.to_string())
                } else {
                    ObjectStoreError::Other(msg)
                }
            })?;

        Ok(resp.content_length().unwrap_or(0) as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn in_memory_put_get_roundtrip() {
        let store = InMemoryObjectStore::new();
        store.put("key1", b"hello").await.unwrap();
        let data = store.get("key1").await.unwrap();
        assert_eq!(data, b"hello");
    }

    #[tokio::test]
    async fn in_memory_get_missing_returns_not_found() {
        let store = InMemoryObjectStore::new();
        let err = store.get("nonexistent").await.unwrap_err();
        assert!(matches!(err, ObjectStoreError::NotFound(_)));
    }

    #[tokio::test]
    async fn in_memory_exists_true_and_false() {
        let store = InMemoryObjectStore::new();
        assert!(!store.exists("k").await.unwrap());
        store.put("k", b"v").await.unwrap();
        assert!(store.exists("k").await.unwrap());
    }

    #[tokio::test]
    async fn in_memory_delete_removes_key() {
        let store = InMemoryObjectStore::new();
        store.put("k", b"v").await.unwrap();
        store.delete("k").await.unwrap();
        assert!(!store.exists("k").await.unwrap());
    }

    #[tokio::test]
    async fn in_memory_size_returns_byte_count() {
        let store = InMemoryObjectStore::new();
        store.put("k", b"12345").await.unwrap();
        assert_eq!(store.size("k").await.unwrap(), 5);
    }

    #[tokio::test]
    async fn in_memory_size_missing_returns_not_found() {
        let store = InMemoryObjectStore::new();
        let err = store.size("nope").await.unwrap_err();
        assert!(matches!(err, ObjectStoreError::NotFound(_)));
    }

    #[tokio::test]
    async fn in_memory_overwrite_replaces_data() {
        let store = InMemoryObjectStore::new();
        store.put("k", b"old").await.unwrap();
        store.put("k", b"new-value").await.unwrap();
        assert_eq!(store.get("k").await.unwrap(), b"new-value");
    }

    #[tokio::test]
    async fn in_memory_default_trait() {
        let store = InMemoryObjectStore::default();
        store.put("x", b"y").await.unwrap();
        assert_eq!(store.get("x").await.unwrap(), b"y");
    }

    #[test]
    fn region_resolver_single_always_returns_default() {
        let default: Arc<dyn ObjectStore + Send + Sync> = Arc::new(InMemoryObjectStore::new());
        let resolver = RegionObjectStoreResolver::single(default.clone());
        assert_eq!(resolver.region_count(), 0);
        // for_region with any string returns the default
        let _ = resolver.for_region("us-east-1");
        let _ = resolver.for_region("eu-west-1");
        let _ = resolver.default_store();
    }

    /// Verifies that [`RegionObjectStoreResolver`] returns the region-specific
    /// store for a configured region and falls back to the default store for
    /// unknown regions, using `Arc::ptr_eq` to confirm store identity.
    #[test]
    fn region_resolver_routes_to_correct_store() {
        let default: Arc<dyn ObjectStore + Send + Sync> = Arc::new(InMemoryObjectStore::new());
        let eu_store: Arc<dyn ObjectStore + Send + Sync> = Arc::new(InMemoryObjectStore::new());

        let mut region_stores = HashMap::new();
        region_stores.insert("eu-west-1".to_string(), eu_store.clone());

        let resolver = RegionObjectStoreResolver::new(default.clone(), region_stores);
        assert_eq!(resolver.region_count(), 1);

        // eu-west-1 should get the eu store (different Arc pointer)
        let resolved_eu = resolver.for_region("eu-west-1");
        assert!(Arc::ptr_eq(resolved_eu, &eu_store));

        // unknown region falls back to default
        let resolved_unknown = resolver.for_region("ap-southeast-1");
        assert!(Arc::ptr_eq(resolved_unknown, &default));
    }
}

// ---------------------------------------------------------------------------
// Per-region object store resolver
// ---------------------------------------------------------------------------

/// Per-region cold storage endpoint configuration.
/// Parsed from `COLD_STORAGE_REGIONS` env var (JSON).
#[derive(Debug, Clone, serde::Deserialize)]
pub struct RegionStoreEntry {
    pub bucket: String,
    pub region: String,
    #[serde(default)]
    pub prefix: String,
    pub endpoint: Option<String>,
    #[serde(default, alias = "accessKey")]
    pub access_key: Option<String>,
    #[serde(default, alias = "secretKey")]
    pub secret_key: Option<String>,
}

/// Resolves the correct `ObjectStore` for a given region.
///
/// When `COLD_STORAGE_REGIONS` is set, each region in the JSON map gets its
/// own S3/S3-compatible bucket+endpoint. Regions not listed in the map fall
/// back to the default store (configured via the existing `COLD_STORAGE_*`
/// env vars).
pub struct RegionObjectStoreResolver {
    default_store: Arc<dyn ObjectStore + Send + Sync>,
    region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>>,
}

impl RegionObjectStoreResolver {
    /// Create a resolver with a default store and per-region overrides.
    pub fn new(
        default_store: Arc<dyn ObjectStore + Send + Sync>,
        region_stores: HashMap<String, Arc<dyn ObjectStore + Send + Sync>>,
    ) -> Self {
        Self {
            default_store,
            region_stores,
        }
    }

    /// Create a resolver that always returns the same store (no per-region routing).
    /// Used when `COLD_STORAGE_REGIONS` is not configured or in tests.
    pub fn single(store: Arc<dyn ObjectStore + Send + Sync>) -> Self {
        Self {
            default_store: store,
            region_stores: HashMap::new(),
        }
    }

    /// Get the object store for a given region.
    /// Returns the region-specific store if configured, otherwise the default.
    pub fn for_region(&self, region: &str) -> &Arc<dyn ObjectStore + Send + Sync> {
        self.region_stores
            .get(region)
            .unwrap_or(&self.default_store)
    }

    /// Get the default (fallback) store.
    pub fn default_store(&self) -> &Arc<dyn ObjectStore + Send + Sync> {
        &self.default_store
    }

    /// Number of region-specific overrides configured.
    pub fn region_count(&self) -> usize {
        self.region_stores.len()
    }

    /// Build a resolver from environment variables.
    /// Reads `COLD_STORAGE_REGIONS` (JSON) for per-region overrides.
    /// Falls back to a single default store when the env var is absent.
    pub async fn from_env() -> Self {
        let default_config = S3ObjectStoreConfig::from_env();
        let default_access_key = default_config.access_key.clone();
        let default_secret_key = default_config.secret_key.clone();
        let default_store: Arc<dyn ObjectStore + Send + Sync> =
            Arc::new(S3ObjectStoreConfig::build(default_config).await);

        let regions_json = std::env::var("COLD_STORAGE_REGIONS").ok();
        let Some(json) = regions_json else {
            return Self::single(default_store);
        };

        let entries: HashMap<String, RegionStoreEntry> = match serde_json::from_str(&json) {
            Ok(entries) => entries,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "COLD_STORAGE_REGIONS is not valid JSON, using single default store"
                );
                return Self::single(default_store);
            }
        };

        let mut region_stores = HashMap::new();
        for (region_id, entry) in entries {
            let config = S3ObjectStoreConfig {
                bucket: entry.bucket,
                prefix: entry.prefix,
                region: entry.region,
                endpoint: entry.endpoint,
                access_key: entry.access_key.or_else(|| default_access_key.clone()),
                secret_key: entry.secret_key.or_else(|| default_secret_key.clone()),
            };
            let store: Arc<dyn ObjectStore + Send + Sync> =
                Arc::new(S3ObjectStoreConfig::build(config).await);
            region_stores.insert(region_id, store);
        }

        Self::new(default_store, region_stores)
    }
}

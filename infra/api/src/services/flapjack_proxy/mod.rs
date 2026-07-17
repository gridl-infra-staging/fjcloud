use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::secrets::NodeSecretManager;
use crate::services::access_tracker::AccessTracker;

mod analytics;
mod chat;
mod debug;
mod dictionaries;
mod documents;
mod experiments;
mod index_metrics_scrape;
mod lifecycle;
mod migration;
mod personalization;
mod recommendations;
mod rules;
mod search;
mod security_sources;
mod settings;
mod suggestions;
mod synonyms;

/// Default time-to-live for cached admin keys. On cache miss, the key is fetched
/// from SSM and stored for this duration to avoid per-request SSM reads.
const DEFAULT_CACHE_TTL: Duration = Duration::from_secs(300); // 5 minutes

#[derive(Debug, thiserror::Error)]
pub enum ProxyError {
    #[error("flapjack VM unreachable: {0}")]
    Unreachable(String),

    #[error("flapjack API error (HTTP {status}): {message}")]
    FlapjackError { status: u16, message: String },

    #[error("secret manager error: {0}")]
    SecretError(String),

    #[error("request timed out")]
    Timeout,
}

const DEFAULT_REQUIRED_FLAPJACK_CAPABILITY: &str = "vectorSearchLocal";
const REQUIRED_FLAPJACK_IDENTITY_ENV_NAMES: [&str; 4] = [
    "FJCLOUD_FLAPJACK_VERSION",
    "FJCLOUD_FLAPJACK_REQUIRED_REVISION",
    "FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID",
    "FJCLOUD_FLAPJACK_REQUIRED_SHA256",
];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("incomplete Flapjack engine identity configuration; missing {missing_variables:?}")]
pub struct FlapjackEngineRequirementsError {
    missing_variables: Vec<&'static str>,
}

impl FlapjackEngineRequirementsError {
    pub fn missing_variables(&self) -> &[&'static str] {
        &self.missing_variables
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlapjackEngineRequirements {
    pub expected_version: Option<String>,
    pub required_revision: Option<String>,
    pub required_build_id: Option<String>,
    pub required_sha256: Option<String>,
    pub required_capability: Option<String>,
}

impl FlapjackEngineRequirements {
    pub fn new(
        expected_version: Option<&str>,
        required_revision: Option<&str>,
        required_build_id: Option<&str>,
        required_sha256: Option<&str>,
        required_capability: Option<&str>,
    ) -> Self {
        Self {
            expected_version: non_empty_string(expected_version),
            required_revision: non_empty_string(required_revision),
            required_build_id: non_empty_string(required_build_id),
            required_sha256: non_empty_string(required_sha256),
            required_capability: non_empty_string(required_capability),
        }
    }

    pub fn from_env() -> Result<Self, FlapjackEngineRequirementsError> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    fn from_lookup(
        mut lookup: impl FnMut(&str) -> Option<String>,
    ) -> Result<Self, FlapjackEngineRequirementsError> {
        let mut configured_value =
            |name| lookup(name).and_then(|value| non_empty_string(Some(value.as_str())));
        let requirements = Self {
            expected_version: configured_value("FJCLOUD_FLAPJACK_VERSION"),
            required_revision: configured_value("FJCLOUD_FLAPJACK_REQUIRED_REVISION"),
            required_build_id: configured_value("FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID"),
            required_sha256: configured_value("FJCLOUD_FLAPJACK_REQUIRED_SHA256"),
            required_capability: configured_value("FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY")
                .or_else(|| Some(DEFAULT_REQUIRED_FLAPJACK_CAPABILITY.to_string())),
        };
        let configured_identity = [
            requirements.expected_version.as_ref(),
            requirements.required_revision.as_ref(),
            requirements.required_build_id.as_ref(),
            requirements.required_sha256.as_ref(),
        ];
        let missing_variables = REQUIRED_FLAPJACK_IDENTITY_ENV_NAMES
            .into_iter()
            .zip(configured_identity)
            .filter_map(|(name, value)| value.is_none().then_some(name))
            .collect::<Vec<_>>();
        if missing_variables.is_empty() {
            Ok(requirements)
        } else {
            Err(FlapjackEngineRequirementsError { missing_variables })
        }
    }

    fn exact_identity_required(&self) -> bool {
        self.required_revision.is_some()
            || self.required_build_id.is_some()
            || self.required_sha256.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlapjackEngineCompatibilityResult {
    pub reason: FlapjackRuntimeIdentityReason,
}

impl FlapjackEngineCompatibilityResult {
    fn new(reason: FlapjackRuntimeIdentityReason) -> Self {
        Self { reason }
    }

    pub fn is_match(&self) -> bool {
        self.reason == FlapjackRuntimeIdentityReason::Match
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlapjackRuntimeIdentityReason {
    Match,
    VersionMismatch,
    RevisionMismatch,
    BuildIdMismatch,
    ChecksumMismatch,
    DirtyLocalBuild,
    MissingCapability,
    LegacyMalformedHealth,
    RuntimeUnreachable,
}

impl FlapjackRuntimeIdentityReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Match => "match",
            Self::VersionMismatch => "version_mismatch",
            Self::RevisionMismatch => "revision_mismatch",
            Self::BuildIdMismatch => "build_id_mismatch",
            Self::ChecksumMismatch => "checksum_mismatch",
            Self::DirtyLocalBuild => "dirty_local_build",
            Self::MissingCapability => "missing_capability",
            Self::LegacyMalformedHealth => "legacy_malformed_health",
            Self::RuntimeUnreachable => "runtime_unreachable",
        }
    }
}

fn non_empty_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlapjackIndexInfo {
    pub name: String,
    pub entries: u64,
    pub data_size: u64,
    pub file_size: u64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlapjackIndexListResponse {
    pub items: Vec<FlapjackIndexInfo>,
    pub nb_pages: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlapjackApiKey {
    pub key: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlapjackHttpRequest {
    pub method: reqwest::Method,
    pub url: String,
    pub api_key: String,
    pub json_body: Option<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlapjackHttpResponse {
    pub status: u16,
    pub body: String,
    pub request_api_key: String,
}

#[async_trait]
pub trait FlapjackHttpClient: Send + Sync {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError>;

    async fn send_unauthenticated_get(
        &self,
        url: String,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        self.send(FlapjackHttpRequest {
            method: reqwest::Method::GET,
            url,
            api_key: String::new(),
            json_body: None,
        })
        .await
    }
}

struct ReqwestFlapjackHttpClient {
    client: reqwest::Client,
}

impl ReqwestFlapjackHttpClient {
    fn new(client: reqwest::Client) -> Self {
        Self { client }
    }
}

#[async_trait]
impl FlapjackHttpClient for ReqwestFlapjackHttpClient {
    /// Sends an HTTP request to a flapjack VM, injecting the
    /// `X-Algolia-API-Key` and `X-Algolia-Application-Id` authentication
    /// headers. Maps transport errors to [`ProxyError::Unreachable`] (or
    /// [`ProxyError::Timeout`] for timeouts) and returns the raw status code
    /// and body for the caller to interpret.
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError> {
        let mut req = self
            .client
            .request(request.method, &request.url)
            .header("X-Algolia-API-Key", &request.api_key)
            // Flapjack requires both API-Key and Application-Id headers;
            // the value of Application-Id is not validated, but its presence is mandatory.
            .header("X-Algolia-Application-Id", "flapjack");

        if let Some(body) = request.json_body {
            req = req.json(&body);
        }

        let resp = req.send().await.map_err(|e| {
            if e.is_timeout() {
                ProxyError::Timeout
            } else {
                ProxyError::Unreachable(e.to_string())
            }
        })?;

        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| ProxyError::Unreachable(format!("failed to read response body: {e}")))?;

        Ok(FlapjackHttpResponse {
            status,
            body,
            request_api_key: request.api_key,
        })
    }

    async fn send_unauthenticated_get(
        &self,
        url: String,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        let resp = self.client.get(&url).send().await.map_err(|e| {
            if e.is_timeout() {
                ProxyError::Timeout
            } else {
                ProxyError::Unreachable(e.to_string())
            }
        })?;

        let status = resp.status().as_u16();
        let body = resp
            .text()
            .await
            .map_err(|e| ProxyError::Unreachable(format!("failed to read response body: {e}")))?;

        Ok(FlapjackHttpResponse {
            status,
            body,
            request_api_key: String::new(),
        })
    }
}

/// Proxies management operations from the fjcloud API to individual flapjack VMs.
/// Uses the node admin key (from SSM) to authenticate via `X-Algolia-API-Key` header.
/// Dashboard operations go through this service; SDK traffic goes directly to the VM.
pub struct FlapjackProxy {
    http_client: Arc<dyn FlapjackHttpClient>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
    key_cache: Arc<RwLock<HashMap<String, (String, Instant)>>>,
    cache_ttl: Duration,
    access_tracker: Option<Arc<AccessTracker>>,
}

impl FlapjackProxy {
    pub fn new(
        http_client: reqwest::Client,
        node_secret_manager: Arc<dyn NodeSecretManager>,
    ) -> Self {
        Self::with_http_client(
            Arc::new(ReqwestFlapjackHttpClient::new(http_client)),
            node_secret_manager,
        )
    }

    pub fn with_http_client(
        http_client: Arc<dyn FlapjackHttpClient>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
    ) -> Self {
        Self::with_http_client_and_access_tracker(http_client, node_secret_manager, None)
    }

    pub fn new_with_access_tracker(
        http_client: reqwest::Client,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        access_tracker: Arc<AccessTracker>,
    ) -> Self {
        Self::with_http_client_and_access_tracker(
            Arc::new(ReqwestFlapjackHttpClient::new(http_client)),
            node_secret_manager,
            Some(access_tracker),
        )
    }

    pub fn with_http_client_and_access_tracker(
        http_client: Arc<dyn FlapjackHttpClient>,
        node_secret_manager: Arc<dyn NodeSecretManager>,
        access_tracker: Option<Arc<AccessTracker>>,
    ) -> Self {
        Self {
            http_client,
            node_secret_manager,
            key_cache: Arc::new(RwLock::new(HashMap::new())),
            cache_ttl: DEFAULT_CACHE_TTL,
            access_tracker,
        }
    }

    /// Build a proxy with a custom cache TTL. Intended for testing cache expiry
    /// behavior — production callers should use the default constructors (300s TTL).
    pub fn with_cache_ttl(mut self, ttl: Duration) -> Self {
        self.cache_ttl = ttl;
        self
    }

    /// Retrieve the admin API key for a node, using an in-memory cache with TTL.
    /// On cache miss, reads from SSM via NodeSecretManager.
    /// On SSM failure, falls back to a stale (expired) cache entry if available,
    /// so temporary SSM outages don't take down the proxy.
    async fn get_admin_key(&self, node_id: &str, region: &str) -> Result<String, ProxyError> {
        let cache_key = format!("{node_id}:{region}");

        // Check cache — return immediately if within TTL.
        {
            let cache = self.key_cache.read().await;
            if let Some((key, fetched_at)) = cache.get(&cache_key) {
                if fetched_at.elapsed() < self.cache_ttl {
                    return Ok(key.clone());
                }
            }
        }

        // Cache miss or expired — try to refresh from SSM.
        match self
            .node_secret_manager
            .get_node_api_key(node_id, region)
            .await
        {
            Ok(key) => {
                // Store fresh key and prune very old entries (4× TTL) to bound memory
                // while keeping recently-expired entries available for stale-on-error.
                let prune_threshold = self.cache_ttl * 4;
                let mut cache = self.key_cache.write().await;
                cache.insert(cache_key, (key.clone(), Instant::now()));
                cache.retain(|_, (_, fetched_at)| fetched_at.elapsed() < prune_threshold);
                Ok(key)
            }
            Err(ssm_err) => {
                // SSM failed — fall back to stale cache entry if present.
                let cache = self.key_cache.read().await;
                if let Some((stale_key, _)) = cache.get(&cache_key) {
                    tracing::warn!(
                        node_id,
                        region,
                        error = %ssm_err,
                        "SSM fetch failed, using stale cached admin key"
                    );
                    return Ok(stale_key.clone());
                }

                // No stale entry — propagate the error.
                Err(ProxyError::SecretError(ssm_err.to_string()))
            }
        }
    }

    /// Convenience method that delegates to [`FlapjackHttpClient::send`],
    /// passing the HTTP method, target URL, node API key, and optional JSON
    /// body. Provides a single entry point for all authenticated flapjack
    /// requests from route handlers.
    async fn send_authenticated_request(
        &self,
        method: reqwest::Method,
        url: String,
        api_key: String,
        json_body: Option<serde_json::Value>,
    ) -> Result<FlapjackHttpResponse, ProxyError> {
        self.http_client
            .send(FlapjackHttpRequest {
                method,
                url,
                api_key,
                json_body,
            })
            .await
    }

    pub async fn check_engine_compatibility(
        &self,
        flapjack_base_url: &str,
        requirements: &FlapjackEngineRequirements,
    ) -> FlapjackEngineCompatibilityResult {
        let response = self
            .http_client
            .send_unauthenticated_get(flapjack_health_url(flapjack_base_url))
            .await;

        let response = match response {
            Ok(response) if (200..300).contains(&response.status) => response,
            Ok(_) | Err(_) => {
                return FlapjackEngineCompatibilityResult::new(
                    FlapjackRuntimeIdentityReason::RuntimeUnreachable,
                );
            }
        };

        FlapjackEngineCompatibilityResult::new(classify_flapjack_health(
            &response.body,
            requirements,
        ))
    }

    /// Check the response status and return ProxyError::FlapjackError for non-success.
    fn check_response_status(status: u16, body: &str) -> Result<(), ProxyError> {
        if (200..300).contains(&status) {
            Ok(())
        } else {
            Err(ProxyError::FlapjackError {
                status,
                message: body.to_string(),
            })
        }
    }

    fn parse_json_response<T>(body: &str, error_context: &str) -> Result<T, ProxyError>
    where
        T: DeserializeOwned,
    {
        serde_json::from_str(body).map_err(|e| ProxyError::FlapjackError {
            status: 200,
            message: format!("{error_context}: {e}"),
        })
    }

    fn normalize_forwarded_query_params(query_params: &str) -> &str {
        query_params.trim().trim_start_matches(['?', '&'])
    }

    fn encode_path_segment(value: &str) -> String {
        let mut encoded = String::with_capacity(value.len());
        for byte in value.bytes() {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                encoded.push(byte as char);
            } else {
                encoded.push_str(&format!("%{byte:02X}"));
            }
        }
        encoded
    }
}

fn flapjack_health_url(flapjack_base_url: &str) -> String {
    format!("{}/health", flapjack_base_url.trim_end_matches('/'))
}

fn classify_flapjack_health(
    body: &str,
    requirements: &FlapjackEngineRequirements,
) -> FlapjackRuntimeIdentityReason {
    let Ok(health) = serde_json::from_str::<serde_json::Value>(body) else {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    };
    let Some(health) = health.as_object() else {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    };
    let build = health
        .get("build")
        .and_then(serde_json::Value::as_object)
        .unwrap_or(health);

    classify_flapjack_identity(requirements, observed_identity(build, health))
}

/// Build the observed identity for a parsed health payload.
///
/// Immutable build/capability fields (`version`, `revision`, `build_id`,
/// `binary_sha`, `dirty`, `capabilities`) are resolved exactly as before and
/// remain authoritative for compatibility decisions. The `runtime_security`
/// seam is resolved the same way `capabilities` is (build object first, then
/// the top-level health object) but is *forward-compatible only*: it carries
/// non-build runtime security observations and is never consulted by
/// `classify_flapjack_identity`.
fn observed_identity<'a>(
    build: &'a serde_json::Map<String, serde_json::Value>,
    health: &'a serde_json::Map<String, serde_json::Value>,
) -> ObservedFlapjackIdentity<'a> {
    let version = first_string(build, &["version"]).or_else(|| first_string(health, &["version"]));
    ObservedFlapjackIdentity {
        version,
        revision: first_string(build, &["producer_revision", "revision"]),
        build_id: first_string(build, &["build_id", "workspaceDigest"]),
        binary_sha: first_string(build, &["binary_sha256", "sha256"]),
        dirty: build.get("dirty").and_then(serde_json::Value::as_bool),
        capabilities: build
            .get("capabilities")
            .or_else(|| health.get("capabilities")),
        runtime_security: build
            .get("runtime_security")
            .or_else(|| health.get("runtime_security"))
            .and_then(|value| {
                serde_json::from_value::<ObservedRuntimeSecurity>(value.clone()).ok()
            }),
    }
}

struct ObservedFlapjackIdentity<'a> {
    version: Option<&'a str>,
    revision: Option<&'a str>,
    build_id: Option<&'a str>,
    binary_sha: Option<&'a str>,
    dirty: Option<bool>,
    capabilities: Option<&'a serde_json::Value>,
    /// Forward-compatible runtime security observations. Populated from the
    /// health payload but intentionally NOT consulted by
    /// `classify_flapjack_identity`; build/capability compatibility is decided
    /// solely by the immutable-identity fields above. See
    /// [`ObservedRuntimeSecurity`].
    ///
    /// Not yet read by production code — this is a deliberate forward seam for
    /// future runtime-security enforcement.
    #[allow(dead_code)]
    runtime_security: Option<ObservedRuntimeSecurity>,
}

/// Typed, forward-compatible view of an engine's *runtime* security posture as
/// reported by its health payload.
///
/// This is a deliberate seam for FUTURE non-build security observations. It is
/// never consulted for build/capability decisions (those stay owned by
/// `FlapjackEngineRequirements`, `FlapjackRuntimeIdentityReason`, and
/// `classify_flapjack_identity`). Unknown/future runtime-security fields are
/// tolerated on purpose — there is no `#[serde(deny_unknown_fields)]` — so
/// newer engines can report additional posture signals without regressing
/// build-identity classification. Field names are intentionally generic
/// runtime-posture observations, not build-identity or issuance concepts.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
struct ObservedRuntimeSecurity {
    #[serde(default)]
    posture: Option<String>,
    #[serde(default)]
    enforced: Option<bool>,
}

// Typed accessors for the forward seam. Exercised by tests today; production
// enforcement will consume them in a later stage.
#[allow(dead_code)]
impl ObservedRuntimeSecurity {
    /// Reported runtime security posture label, if the engine advertised one.
    fn posture(&self) -> Option<&str> {
        self.posture.as_deref()
    }

    /// Whether the engine reports runtime security enforcement active, if
    /// advertised.
    fn enforced(&self) -> Option<bool> {
        self.enforced
    }
}

fn classify_flapjack_identity(
    requirements: &FlapjackEngineRequirements,
    observed: ObservedFlapjackIdentity<'_>,
) -> FlapjackRuntimeIdentityReason {
    if observed.version.is_none() {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    if requirements
        .expected_version
        .as_deref()
        .is_some_and(|expected| observed.version != Some(expected))
    {
        return FlapjackRuntimeIdentityReason::VersionMismatch;
    }
    if observed.dirty == Some(true) {
        return FlapjackRuntimeIdentityReason::DirtyLocalBuild;
    }
    if requirements.exact_identity_required() && observed.dirty.is_none() {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    if missing_required_identity_field(requirements, &observed) {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    if requirements
        .required_revision
        .as_deref()
        .is_some_and(|expected| observed.revision != Some(expected))
    {
        return FlapjackRuntimeIdentityReason::RevisionMismatch;
    }
    if requirements
        .required_build_id
        .as_deref()
        .is_some_and(|expected| observed.build_id != Some(expected))
    {
        return FlapjackRuntimeIdentityReason::BuildIdMismatch;
    }
    if requirements
        .required_sha256
        .as_deref()
        .is_some_and(|expected| observed.binary_sha != Some(expected))
    {
        return FlapjackRuntimeIdentityReason::ChecksumMismatch;
    }
    if !required_capability_present(requirements, observed.capabilities) {
        return FlapjackRuntimeIdentityReason::MissingCapability;
    }
    if requirements.exact_identity_required()
        && !(observed.revision.is_some()
            && observed.build_id.is_some()
            && observed.binary_sha.is_some())
    {
        return FlapjackRuntimeIdentityReason::LegacyMalformedHealth;
    }
    FlapjackRuntimeIdentityReason::Match
}

fn missing_required_identity_field(
    requirements: &FlapjackEngineRequirements,
    observed: &ObservedFlapjackIdentity<'_>,
) -> bool {
    (requirements.required_revision.is_some() && observed.revision.is_none())
        || (requirements.required_build_id.is_some() && observed.build_id.is_none())
        || (requirements.required_sha256.is_some() && observed.binary_sha.is_none())
}

fn required_capability_present(
    requirements: &FlapjackEngineRequirements,
    capabilities: Option<&serde_json::Value>,
) -> bool {
    let Some(required_capability) = requirements.required_capability.as_deref() else {
        return true;
    };
    match capabilities {
        Some(serde_json::Value::Array(items)) => items
            .iter()
            .any(|item| item.as_str() == Some(required_capability)),
        Some(serde_json::Value::Object(map)) => map
            .get(required_capability)
            .is_some_and(|value| value.as_bool() == Some(true)),
        _ => false,
    }
}

fn first_string<'a>(
    payload: &'a serde_json::Map<String, serde_json::Value>,
    names: &[&str],
) -> Option<&'a str> {
    names.iter().find_map(|name| {
        payload
            .get(*name)
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
    })
}

#[cfg(test)]
mod engine_compatibility_tests;

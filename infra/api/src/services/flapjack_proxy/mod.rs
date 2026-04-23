//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/flapjack_proxy/mod.rs.
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
}

#[async_trait]
pub trait FlapjackHttpClient: Send + Sync {
    async fn send(&self, request: FlapjackHttpRequest) -> Result<FlapjackHttpResponse, ProxyError>;
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

        Ok(FlapjackHttpResponse { status, body })
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

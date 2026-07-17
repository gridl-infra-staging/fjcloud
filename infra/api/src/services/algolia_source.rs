use async_trait::async_trait;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use reqwest::redirect::Policy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use thiserror::Error;
use utoipa::ToSchema;

type HmacSha256 = Hmac<Sha256>;

const ALGOLIA_HITS_PER_PAGE: u32 = 100;
const MIN_ALGOLIA_HITS_PER_PAGE: u32 = 1;
const MAX_ALGOLIA_HITS_PER_PAGE: u32 = 100;
const MAX_RETRY_ATTEMPTS: usize = 3;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const HANDLER_BUDGET: Duration = Duration::from_secs(8);
const CURSOR_VERSION: u8 = 1;
const MIN_CURSOR_KEY_BYTES: usize = 32;
const MAX_UPSTREAM_BODY_BYTES: usize = 2 * 1024 * 1024;
pub(crate) const MAX_TOTAL_ITEMS: usize = 10_000;
pub(crate) const MAX_TOTAL_PAGES: u32 = 100;
pub(crate) const MAX_METADATA_BYTES: usize = 1024 * 1024;

#[derive(Clone)]
pub struct AlgoliaClientRequest {
    pub url: reqwest::Url,
    pub page: u32,
    pub hits_per_page: u32,
    app_id: String,
    api_key: String,
}

impl AlgoliaClientRequest {
    fn new(url: reqwest::Url, app_id: String, api_key: String, page: u32) -> Self {
        Self {
            url,
            page,
            hits_per_page: ALGOLIA_HITS_PER_PAGE,
            app_id,
            api_key,
        }
    }

    #[cfg(test)]
    fn for_test(url: reqwest::Url, app_id: &str, api_key: &str, page: u32) -> Self {
        Self::new(url, app_id.to_string(), api_key.to_string(), page)
    }
}

impl fmt::Debug for AlgoliaClientRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaClientRequest")
            .field("url", &self.url)
            .field("page", &self.page)
            .field("hits_per_page", &self.hits_per_page)
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone)]
pub struct AlgoliaClientResponse {
    pub status: u16,
    body: Vec<u8>,
}

impl AlgoliaClientResponse {
    #[cfg(test)]
    fn success(page: AlgoliaPage) -> Self {
        Self {
            status: 200,
            body: serde_json::to_vec(&page).expect("test page serializes"),
        }
    }

    #[cfg(test)]
    fn status(status: u16) -> Self {
        Self {
            status,
            body: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AlgoliaClientError {
    #[error("Algolia request timed out")]
    Timeout,
    #[error("Algolia transport unavailable")]
    Transport,
}

#[async_trait]
pub trait AlgoliaSourceClient: Send + Sync {
    async fn list_indexes(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaClientError>;
}

pub struct ReqwestAlgoliaSourceClient {
    http: reqwest::Client,
}

impl ReqwestAlgoliaSourceClient {
    pub fn new() -> Result<Self, reqwest::Error> {
        let http = reqwest::Client::builder()
            .redirect(Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(HANDLER_BUDGET)
            .build()?;
        Ok(Self { http })
    }
}

#[async_trait]
impl AlgoliaSourceClient for ReqwestAlgoliaSourceClient {
    async fn list_indexes(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaClientError> {
        let response = self
            .http
            .get(request.url)
            .header("X-Algolia-Application-Id", request.app_id)
            .header("X-Algolia-API-Key", request.api_key)
            .query(&[
                ("page", request.page.to_string()),
                ("hitsPerPage", request.hits_per_page.to_string()),
            ])
            .send()
            .await
            .map_err(classify_reqwest_error)?;
        let status = response.status().as_u16();
        let body = response
            .bytes()
            .await
            .map_err(classify_reqwest_error)?
            .to_vec();
        if body.len() > MAX_UPSTREAM_BODY_BYTES {
            return Err(AlgoliaClientError::Transport);
        }
        Ok(AlgoliaClientResponse { status, body })
    }
}

fn classify_reqwest_error(error: reqwest::Error) -> AlgoliaClientError {
    if error.is_timeout() {
        AlgoliaClientError::Timeout
    } else {
        AlgoliaClientError::Transport
    }
}

#[derive(Clone)]
pub struct AlgoliaSourceListRequest {
    pub app_id: String,
    pub api_key: String,
    pub cursor: Option<String>,
    pub hits_per_page: Option<u32>,
}

impl fmt::Debug for AlgoliaSourceListRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaSourceListRequest")
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("cursor", &self.cursor.as_ref().map(|_| "[REDACTED]"))
            .field("hits_per_page", &self.hits_per_page)
            .finish()
    }
}

#[derive(Debug, Clone, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaSourceListResponse {
    pub items: Vec<AlgoliaIndexMetadata>,
    #[schema(required)]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaIndexMetadata {
    pub name: String,
    pub entries: u64,
    pub data_size: u64,
    pub file_size: u64,
    /// Last updated timestamp reported by Algolia.
    pub updated_at: DateTime<Utc>,
    /// Duration in seconds of Algolia's most recent index build.
    pub last_build_time_s: u64,
    #[serde(default)]
    #[schema(required)]
    pub pending_task: bool,
    /// Primary index name, when this index is a replica.
    #[serde(default)]
    #[schema(required)]
    pub primary: Option<String>,
    /// Replica index names configured for this primary index.
    #[serde(default)]
    #[schema(required)]
    pub replicas: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AlgoliaPage {
    items: Vec<AlgoliaIndexMetadata>,
    #[serde(default)]
    page: Option<u32>,
    nb_pages: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AlgoliaSourceError {
    #[error("invalid Algolia application ID")]
    InvalidApplicationId,
    #[error("invalid Algolia credentials")]
    InvalidCredentials,
    #[error("Algolia discovery requires the listIndexes ACL")]
    ListIndexesAclRequired,
    #[error("invalid discovery cursor")]
    InvalidCursor,
    #[error("invalid Algolia response")]
    InvalidUpstreamResponse,
    #[error("Algolia discovery timed out")]
    TimedOut,
    #[error("Algolia discovery unavailable")]
    Unavailable,
    #[error("source_catalog_too_large")]
    SourceCatalogTooLarge,
    #[error("invalid cursor signing key")]
    InvalidCursorKey,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CursorPayload {
    version: u8,
    page: u32,
    items_seen: usize,
    metadata_bytes: usize,
    source_fingerprint: String,
}

pub struct AlgoliaSourceService {
    client: Arc<dyn AlgoliaSourceClient>,
    cursor_key: Vec<u8>,
    spent_cursors: Mutex<HashSet<[u8; 32]>>,
}

#[async_trait]
pub trait AlgoliaSourceLister: Send + Sync {
    async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError>;
}

#[async_trait]
impl AlgoliaSourceLister for AlgoliaSourceService {
    async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        AlgoliaSourceService::list_indexes(self, request).await
    }
}

impl AlgoliaSourceService {
    pub fn new(
        client: Arc<dyn AlgoliaSourceClient>,
        cursor_key: impl AsRef<[u8]>,
    ) -> Result<Self, AlgoliaSourceError> {
        let cursor_key = cursor_key.as_ref();
        if cursor_key.len() < MIN_CURSOR_KEY_BYTES {
            return Err(AlgoliaSourceError::InvalidCursorKey);
        }
        Ok(Self {
            client,
            cursor_key: cursor_key.to_vec(),
            spent_cursors: Mutex::new(HashSet::new()),
        })
    }

    pub async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        let operation = self.list_indexes_with_budget(request);
        tokio::time::timeout(HANDLER_BUDGET, operation)
            .await
            .map_err(|_| AlgoliaSourceError::TimedOut)?
    }

    async fn list_indexes_with_budget(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        let url = algolia_list_url(&request.app_id)?;
        if request.api_key.is_empty() {
            return Err(AlgoliaSourceError::InvalidCredentials);
        }
        let hits_per_page = validated_hits_per_page(request.hits_per_page)?;
        let source_fingerprint = self.source_fingerprint(&request.app_id, &request.api_key);
        let progress = self.decode_progress(request.cursor.as_deref(), &source_fingerprint)?;
        let mut client_request =
            AlgoliaClientRequest::new(url, request.app_id, request.api_key, progress.page);
        client_request.hits_per_page = hits_per_page;
        let upstream = self.fetch_with_retries(client_request).await?;
        self.build_response(progress, upstream, source_fingerprint)
    }

    async fn fetch_with_retries(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
        for attempt in 0..MAX_RETRY_ATTEMPTS {
            let response = self
                .client
                .list_indexes(request.clone())
                .await
                .map_err(map_client_error)?;
            match response.status {
                200 => return Ok(response),
                401 => return Err(AlgoliaSourceError::InvalidCredentials),
                403 => return Err(AlgoliaSourceError::ListIndexesAclRequired),
                400 | 404 => return Err(AlgoliaSourceError::InvalidApplicationId),
                429 | 500..=599 if attempt + 1 < MAX_RETRY_ATTEMPTS => {
                    tokio::time::sleep(Duration::from_millis(50 * (attempt as u64 + 1))).await;
                }
                429 | 500..=599 => return Err(AlgoliaSourceError::Unavailable),
                300..=399 => return Err(AlgoliaSourceError::Unavailable),
                _ => return Err(AlgoliaSourceError::InvalidUpstreamResponse),
            }
        }
        Err(AlgoliaSourceError::Unavailable)
    }

    fn decode_progress(
        &self,
        cursor: Option<&str>,
        expected_fingerprint: &str,
    ) -> Result<CursorPayload, AlgoliaSourceError> {
        let Some(cursor) = cursor else {
            return Ok(CursorPayload {
                version: CURSOR_VERSION,
                page: 0,
                items_seen: 0,
                metadata_bytes: 0,
                source_fingerprint: expected_fingerprint.to_string(),
            });
        };
        let (encoded_payload, encoded_signature) = cursor
            .split_once('.')
            .ok_or(AlgoliaSourceError::InvalidCursor)?;
        let payload_bytes = URL_SAFE_NO_PAD
            .decode(encoded_payload)
            .map_err(|_| AlgoliaSourceError::InvalidCursor)?;
        let signature = URL_SAFE_NO_PAD
            .decode(encoded_signature)
            .map_err(|_| AlgoliaSourceError::InvalidCursor)?;
        self.verify_signature(&payload_bytes, &signature)?;
        let payload: CursorPayload = serde_json::from_slice(&payload_bytes)
            .map_err(|_| AlgoliaSourceError::InvalidCursor)?;
        if payload.version != CURSOR_VERSION
            || payload.page == 0
            || payload.page >= MAX_TOTAL_PAGES
            || payload.items_seen > MAX_TOTAL_ITEMS
            || payload.metadata_bytes > MAX_METADATA_BYTES
            || payload.source_fingerprint != expected_fingerprint
        {
            return Err(AlgoliaSourceError::InvalidCursor);
        }
        let cursor_digest: [u8; 32] = Sha256::digest(cursor.as_bytes()).into();
        if !self.spent_cursors.lock().unwrap().insert(cursor_digest) {
            return Err(AlgoliaSourceError::InvalidCursor);
        }
        Ok(payload)
    }

    fn build_response(
        &self,
        progress: CursorPayload,
        upstream: AlgoliaClientResponse,
        source_fingerprint: String,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        let page: AlgoliaPage = serde_json::from_slice(&upstream.body)
            .map_err(|_| AlgoliaSourceError::InvalidUpstreamResponse)?;
        let response_page = page.page.unwrap_or(progress.page);
        if response_page != progress.page || (page.nb_pages == 0 && response_page != 0) {
            return Err(AlgoliaSourceError::InvalidUpstreamResponse);
        }
        if page.nb_pages > MAX_TOTAL_PAGES {
            return Err(AlgoliaSourceError::SourceCatalogTooLarge);
        }
        let page_metadata_bytes = serde_json::to_vec(&page.items)
            .map_err(|_| AlgoliaSourceError::InvalidUpstreamResponse)?
            .len();
        let items_seen = progress
            .items_seen
            .checked_add(page.items.len())
            .ok_or(AlgoliaSourceError::SourceCatalogTooLarge)?;
        let metadata_bytes = progress
            .metadata_bytes
            .checked_add(page_metadata_bytes)
            .ok_or(AlgoliaSourceError::SourceCatalogTooLarge)?;
        if items_seen > MAX_TOTAL_ITEMS || metadata_bytes > MAX_METADATA_BYTES {
            return Err(AlgoliaSourceError::SourceCatalogTooLarge);
        }
        let next_page = response_page.saturating_add(1);
        let next_cursor = if next_page < page.nb_pages {
            Some(self.encode_cursor(&CursorPayload {
                version: CURSOR_VERSION,
                page: next_page,
                items_seen,
                metadata_bytes,
                source_fingerprint,
            })?)
        } else {
            None
        };
        Ok(AlgoliaSourceListResponse {
            items: page.items,
            next_cursor,
        })
    }

    fn encode_cursor(&self, payload: &CursorPayload) -> Result<String, AlgoliaSourceError> {
        let payload = serde_json::to_vec(payload).map_err(|_| AlgoliaSourceError::InvalidCursor)?;
        let signature = self.sign(&payload);
        Ok(format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(payload),
            URL_SAFE_NO_PAD.encode(signature)
        ))
    }

    fn verify_signature(&self, payload: &[u8], signature: &[u8]) -> Result<(), AlgoliaSourceError> {
        let mut mac = HmacSha256::new_from_slice(&self.cursor_key)
            .map_err(|_| AlgoliaSourceError::InvalidCursor)?;
        mac.update(payload);
        mac.verify_slice(signature)
            .map_err(|_| AlgoliaSourceError::InvalidCursor)
    }

    fn sign(&self, value: &[u8]) -> Vec<u8> {
        let mut mac =
            HmacSha256::new_from_slice(&self.cursor_key).expect("cursor key length was validated");
        mac.update(value);
        mac.finalize().into_bytes().to_vec()
    }

    fn source_fingerprint(&self, app_id: &str, api_key: &str) -> String {
        let mut source = app_id.to_ascii_lowercase().into_bytes();
        source.push(0);
        source.extend_from_slice(Sha256::digest(api_key.as_bytes()).as_slice());
        URL_SAFE_NO_PAD.encode(&self.sign(&source)[..16])
    }
}

fn map_client_error(error: AlgoliaClientError) -> AlgoliaSourceError {
    match error {
        AlgoliaClientError::Timeout => AlgoliaSourceError::TimedOut,
        AlgoliaClientError::Transport => AlgoliaSourceError::Unavailable,
    }
}

fn algolia_list_url(app_id: &str) -> Result<reqwest::Url, AlgoliaSourceError> {
    if app_id.is_empty()
        || app_id.len() > 64
        || !app_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(AlgoliaSourceError::InvalidApplicationId);
    }
    format!(
        "https://{}.algolia.net/1/indexes",
        app_id.to_ascii_lowercase()
    )
    .parse()
    .map_err(|_| AlgoliaSourceError::InvalidApplicationId)
}

fn validated_hits_per_page(value: Option<u32>) -> Result<u32, AlgoliaSourceError> {
    let value = value.unwrap_or(ALGOLIA_HITS_PER_PAGE);
    if (MIN_ALGOLIA_HITS_PER_PAGE..=MAX_ALGOLIA_HITS_PER_PAGE).contains(&value) {
        Ok(value)
    } else {
        Err(AlgoliaSourceError::InvalidUpstreamResponse)
    }
}

#[cfg(test)]
mod tests;

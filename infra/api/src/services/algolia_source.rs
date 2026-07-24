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
use zeroize::Zeroizing;

use crate::models::algolia_import_job::{AlgoliaImportSource, AlgoliaImportSourceMetadata};

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
    // The temporary Algolia key is carried in a zeroizing owner so every clone
    // made during retries and per-page fetches is scrubbed from allocator
    // memory on drop rather than lingering as cleartext.
    api_key: Zeroizing<String>,
}

impl AlgoliaClientRequest {
    fn new(url: reqwest::Url, app_id: String, api_key: Zeroizing<String>, page: u32) -> Self {
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
        Self::new(
            url,
            app_id.to_string(),
            Zeroizing::new(api_key.to_string()),
            page,
        )
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
            .header("X-Algolia-API-Key", request.api_key.as_str())
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

/// Trusted input for the final temporary-key source inspection performed at
/// create admission. Carries only the volatile credentials plus the selected
/// source index name; it deliberately holds no browser-supplied record counts
/// or sizes, so those can never enter the source fingerprint or quota path.
#[derive(Clone)]
pub struct AlgoliaSourceInspectRequest {
    pub app_id: String,
    // Final temporary key held under zeroizing ownership so admission can hand
    // it in without minting an ordinary `String` copy, and every retained clone
    // (including test observers) is scrubbed on drop.
    pub api_key: Zeroizing<String>,
    pub source_name: String,
}

impl fmt::Debug for AlgoliaSourceInspectRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaSourceInspectRequest")
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("source_name", &"[REDACTED]")
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
    #[error("final Algolia key lacks a required source permission (settings/browse)")]
    SourcePermissionRequired,
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
    #[error("selected Algolia source index was not found")]
    SourceIndexNotFound,
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

    /// Re-fetch the authoritative metadata for the selected source index using
    /// the fresh temporary key and build the F3 `AlgoliaImportSource` from
    /// server-reported figures only.
    async fn inspect_source(
        &self,
        request: AlgoliaSourceInspectRequest,
    ) -> Result<AlgoliaImportSource, AlgoliaSourceError>;
}

#[async_trait]
impl AlgoliaSourceLister for AlgoliaSourceService {
    async fn list_indexes(
        &self,
        request: AlgoliaSourceListRequest,
    ) -> Result<AlgoliaSourceListResponse, AlgoliaSourceError> {
        AlgoliaSourceService::list_indexes(self, request).await
    }

    async fn inspect_source(
        &self,
        request: AlgoliaSourceInspectRequest,
    ) -> Result<AlgoliaImportSource, AlgoliaSourceError> {
        AlgoliaSourceService::inspect_source(self, request).await
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
        let mut client_request = AlgoliaClientRequest::new(
            url,
            request.app_id,
            Zeroizing::new(request.api_key),
            progress.page,
        );
        client_request.hits_per_page = hits_per_page;
        let upstream = self.fetch_with_retries(client_request).await?;
        self.build_response(progress, upstream, source_fingerprint)
    }

    /// Inspect the selected source index with the fresh temporary key and
    /// return an `AlgoliaImportSource` built from server-authoritative
    /// metadata. Bounded by the same handler budget as discovery.
    pub async fn inspect_source(
        &self,
        request: AlgoliaSourceInspectRequest,
    ) -> Result<AlgoliaImportSource, AlgoliaSourceError> {
        let trace_request = request.clone();
        let operation = self.inspect_source_with_budget(request);
        let result = match tokio::time::timeout(HANDLER_BUDGET, operation).await {
            Ok(result) => result,
            Err(_) => Err(AlgoliaSourceError::TimedOut),
        };
        if let Err(error) = &result {
            tracing::warn!(
                request = ?trace_request,
                error = ?error,
                "Algolia source inspection failed"
            );
        }
        result
    }

    async fn inspect_source_with_budget(
        &self,
        request: AlgoliaSourceInspectRequest,
    ) -> Result<AlgoliaImportSource, AlgoliaSourceError> {
        let url = algolia_list_url(&request.app_id)?;
        if request.api_key.is_empty() {
            return Err(AlgoliaSourceError::InvalidCredentials);
        }
        if request.source_name.is_empty() {
            return Err(AlgoliaSourceError::SourceIndexNotFound);
        }
        let mut page = 0;
        let mut items_seen = 0usize;
        loop {
            let mut client_request = AlgoliaClientRequest::new(
                url.clone(),
                request.app_id.clone(),
                request.api_key.clone(),
                page,
            );
            client_request.hits_per_page = ALGOLIA_HITS_PER_PAGE;
            let upstream = self.fetch_with_retries(client_request).await?;
            let parsed: AlgoliaPage = serde_json::from_slice(&upstream.body)
                .map_err(|_| AlgoliaSourceError::InvalidUpstreamResponse)?;
            if parsed.page.unwrap_or(page) != page {
                return Err(AlgoliaSourceError::InvalidUpstreamResponse);
            }
            if parsed.nb_pages > MAX_TOTAL_PAGES {
                return Err(AlgoliaSourceError::SourceCatalogTooLarge);
            }
            if let Some(found) = parsed
                .items
                .iter()
                .find(|item| item.name == request.source_name)
            {
                let source = inspected_source(&request.app_id, found);
                // The final key must be able to read settings and browse the
                // selected index, not merely list it, before we accept the job.
                self.verify_final_key_permissions(
                    &url,
                    &request.app_id,
                    &request.api_key,
                    &request.source_name,
                )
                .await?;
                return Ok(source);
            }
            items_seen = items_seen
                .checked_add(parsed.items.len())
                .filter(|seen| *seen <= MAX_TOTAL_ITEMS)
                .ok_or(AlgoliaSourceError::SourceCatalogTooLarge)?;
            page = page.saturating_add(1);
            if page >= parsed.nb_pages {
                return Err(AlgoliaSourceError::SourceIndexNotFound);
            }
        }
    }

    /// Fetch a discovery/listing page, mapping the terminal status the way the
    /// list-indices probe requires (a 403 here means the listIndexes ACL).
    async fn fetch_with_retries(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
        let response = self.fetch_terminal(request).await?;
        interpret_list_status(response)
    }

    /// Retry transient upstream failures (429/5xx) up to [`MAX_RETRY_ATTEMPTS`]
    /// and return the terminal response for the caller to interpret. Transport
    /// and timeout failures are mapped immediately. This is the shared retry
    /// core behind both the list-indices fetch and the final-key permission
    /// probes, so the two never diverge on retry policy.
    async fn fetch_terminal(
        &self,
        request: AlgoliaClientRequest,
    ) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
        for attempt in 0..MAX_RETRY_ATTEMPTS {
            let response = self
                .client
                .list_indexes(request.clone())
                .await
                .map_err(map_client_error)?;
            if matches!(response.status, 429 | 500..=599) && attempt + 1 < MAX_RETRY_ATTEMPTS {
                tokio::time::sleep(Duration::from_millis(50 * (attempt as u64 + 1))).await;
                continue;
            }
            return Ok(response);
        }
        // Unreachable: the final attempt always returns above.
        Err(AlgoliaSourceError::Unavailable)
    }

    /// Prove the final temporary key can actually run the migration against the
    /// selected index by probing the two ACLs the engine needs beyond
    /// `listIndexes`: `settings` (read index configuration) and `browse` (read
    /// every record). A key that can only list indexes is refused here, before
    /// the route persists any job. Probes reuse the redacted client, so the key
    /// never leaks.
    async fn verify_final_key_permissions(
        &self,
        base_url: &reqwest::Url,
        app_id: &str,
        api_key: &str,
        source_name: &str,
    ) -> Result<(), AlgoliaSourceError> {
        for action in ["settings", "browse"] {
            let url = algolia_index_action_url(base_url, source_name, action)?;
            let request = AlgoliaClientRequest::new(
                url,
                app_id.to_string(),
                Zeroizing::new(api_key.to_string()),
                0,
            );
            let response = self.fetch_terminal(request).await?;
            interpret_permission_status(response.status)?;
        }
        Ok(())
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

/// Build an F3 `AlgoliaImportSource` from a server-authoritative index row.
///
/// Only the re-fetched server figures feed the source metadata: the on-disk
/// `file_size` is the source size, `entries` the record count, and the reported
/// `updated_at`/`last_build_time_s` pair the revision so a rebuild changes the
/// fingerprint. No browser-supplied picker count or size participates.
fn inspected_source(app_id: &str, item: &AlgoliaIndexMetadata) -> AlgoliaImportSource {
    let metadata = AlgoliaImportSourceMetadata::new(
        i64::try_from(item.file_size).ok(),
        i64::try_from(item.entries).ok(),
        format!(
            "{}:{}",
            item.updated_at.to_rfc3339(),
            item.last_build_time_s
        ),
    );
    AlgoliaImportSource::from_final_key_metadata(app_id, &item.name, metadata)
}

fn map_client_error(error: AlgoliaClientError) -> AlgoliaSourceError {
    match error {
        AlgoliaClientError::Timeout => AlgoliaSourceError::TimedOut,
        AlgoliaClientError::Transport => AlgoliaSourceError::Unavailable,
    }
}

/// Interpret the terminal status of a list-indices fetch. A 403 here means the
/// key lacks the `listIndexes` ACL.
fn interpret_list_status(
    response: AlgoliaClientResponse,
) -> Result<AlgoliaClientResponse, AlgoliaSourceError> {
    match response.status {
        200 => Ok(response),
        401 => Err(AlgoliaSourceError::InvalidCredentials),
        403 => Err(AlgoliaSourceError::ListIndexesAclRequired),
        400 | 404 => Err(AlgoliaSourceError::InvalidApplicationId),
        429 | 500..=599 | 300..=399 => Err(AlgoliaSourceError::Unavailable),
        _ => Err(AlgoliaSourceError::InvalidUpstreamResponse),
    }
}

/// Interpret the terminal status of a final-key permission probe (settings or
/// browse). A 403 here means the required source permission is absent; a 404
/// means the just-listed index vanished under a race.
fn interpret_permission_status(status: u16) -> Result<(), AlgoliaSourceError> {
    match status {
        200 => Ok(()),
        401 => Err(AlgoliaSourceError::InvalidCredentials),
        403 => Err(AlgoliaSourceError::SourcePermissionRequired),
        404 => Err(AlgoliaSourceError::SourceIndexNotFound),
        400 => Err(AlgoliaSourceError::InvalidApplicationId),
        429 | 500..=599 | 300..=399 => Err(AlgoliaSourceError::Unavailable),
        _ => Err(AlgoliaSourceError::InvalidUpstreamResponse),
    }
}

/// Build the `/1/indexes/{name}/{action}` URL for a per-index permission probe
/// from the validated list base URL. The index name is percent-encoded as a
/// path segment so an exotic name cannot escape the path.
fn algolia_index_action_url(
    base_url: &reqwest::Url,
    source_name: &str,
    action: &str,
) -> Result<reqwest::Url, AlgoliaSourceError> {
    let mut url = base_url.clone();
    url.path_segments_mut()
        .map_err(|_| AlgoliaSourceError::InvalidApplicationId)?
        .push(source_name)
        .push(action);
    Ok(url)
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

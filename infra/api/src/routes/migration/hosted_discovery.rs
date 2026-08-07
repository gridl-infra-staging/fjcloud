//! Hosted source-index discovery request admission, forwarding, and revisions.
use std::fmt;
use std::net::IpAddr;
use std::time::Duration;

use axum::body::Bytes;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use reqwest::redirect::Policy;
use reqwest::Url;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use utoipa::{PartialSchema, ToSchema};

use crate::errors::ApiError;
use crate::models::algolia_import_job::SourceImportProvider;
use crate::models::AlgoliaImportErrorCode;
use crate::services::flapjack_proxy::{ProxyError, SourceIndexDiscoveryRequest};
use crate::state::AppState;

use super::source::MigrationProxyOperation;
use super::{migration_error, serde_offending_field, REDACTED_CREDENTIAL};

const ALLOW_LOOPBACK_SOURCE_ORIGINS_ENV: &str = "FJCLOUD_ALLOW_LOOPBACK_SOURCE_ORIGINS";
const TYPESENSE_REVISION_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TYPESENSE_REVISION_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListMeilisearchIndexesRequest {
    pub endpoint: String,
    pub api_key: String,
}

pub(super) trait HostedSourceRequest: DeserializeOwned {
    fn source_origin(&self) -> &str;
    fn api_key(&self) -> &str;
    fn into_forward_body(self, normalized_origin: &str) -> String;
}

impl HostedSourceRequest for ListMeilisearchIndexesRequest {
    fn source_origin(&self) -> &str {
        &self.endpoint
    }

    fn api_key(&self) -> &str {
        &self.api_key
    }

    fn into_forward_body(self, normalized_origin: &str) -> String {
        serde_json::json!({
            "endpoint": normalized_origin,
            "apiKey": self.api_key,
        })
        .to_string()
    }
}

impl fmt::Debug for ListMeilisearchIndexesRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ListMeilisearchIndexesRequest")
            .field("endpoint", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .finish()
    }
}

impl Serialize for ListMeilisearchIndexesRequest {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;

        let mut request = serializer.serialize_struct("ListMeilisearchIndexesRequest", 2)?;
        request.serialize_field("endpoint", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListTypesenseIndexesRequest {
    pub node: String,
    pub api_key: String,
}

impl HostedSourceRequest for ListTypesenseIndexesRequest {
    fn source_origin(&self) -> &str {
        &self.node
    }

    fn api_key(&self) -> &str {
        &self.api_key
    }

    fn into_forward_body(self, normalized_origin: &str) -> String {
        serde_json::json!({
            "node": normalized_origin,
            "apiKey": self.api_key,
        })
        .to_string()
    }
}

impl fmt::Debug for ListTypesenseIndexesRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ListTypesenseIndexesRequest")
            .field("node", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .finish()
    }
}

impl Serialize for ListTypesenseIndexesRequest {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;

        let mut request = serializer.serialize_struct("ListTypesenseIndexesRequest", 2)?;
        request.serialize_field("node", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.end()
    }
}

#[derive(Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListSourceIndexesResponse {
    pub indexes: Vec<SourceIndexSummary>,
    #[schema(format = Int64, minimum = 0)]
    pub limit: Option<i64>,
    #[schema(format = Int64, minimum = 0)]
    pub offset: Option<i64>,
    #[schema(format = Int64, minimum = 0)]
    pub total: Option<i64>,
}

impl ListSourceIndexesResponse {
    fn validate(&self) -> Result<(), &'static str> {
        if [self.limit, self.offset, self.total]
            .into_iter()
            .flatten()
            .any(|value| value < 0)
        {
            return Err("pagination values must be non-negative");
        }
        if self
            .indexes
            .iter()
            .any(SourceIndexSummary::has_negative_value)
        {
            return Err("index metadata values must be non-negative");
        }
        Ok(())
    }
}

#[derive(Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceIndexSummary {
    pub name: String,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true)]
    pub primary_key: Option<String>,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true, format = Int64, minimum = 0)]
    pub entries: Option<i64>,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true, format = Int64, minimum = 0)]
    pub document_count: Option<i64>,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true)]
    pub created_at: Option<SourceIndexCreatedAt>,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true)]
    pub updated_at: Option<String>,
    // Omitted rather than emitted as `null` when the adapter carries no content
    // revision: the discovery response is a published contract whose other
    // optional fields are absent-not-null, and every neutral discovery contract
    // test compares the whole body.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(deserialize_with = "deserialize_required_option")]
    #[schema(required = true)]
    pub default_sorting_field: Option<String>,
}

impl SourceIndexSummary {
    fn has_negative_value(&self) -> bool {
        [self.entries, self.document_count]
            .into_iter()
            .flatten()
            .any(|value| value < 0)
            || matches!(self.created_at.as_ref(), Some(SourceIndexCreatedAt::Epoch(value)) if *value < 0)
    }
}

fn deserialize_required_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::deserialize(deserializer)
}

#[derive(Deserialize, Serialize)]
#[serde(untagged)]
pub enum SourceIndexCreatedAt {
    Text(String),
    Epoch(i64),
}

impl PartialSchema for SourceIndexCreatedAt {
    fn schema() -> utoipa::openapi::RefOr<utoipa::openapi::schema::Schema> {
        utoipa::openapi::OneOfBuilder::new()
            .item(utoipa::openapi::ObjectBuilder::new().schema_type(utoipa::openapi::Type::String))
            .item(
                utoipa::openapi::ObjectBuilder::new()
                    .schema_type(utoipa::openapi::Type::Integer)
                    .format(Some(utoipa::openapi::SchemaFormat::KnownFormat(
                        utoipa::openapi::KnownFormat::Int64,
                    )))
                    .minimum(Some(0)),
            )
            .into()
    }
}

impl ToSchema for SourceIndexCreatedAt {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct HostedSourceRevision {
    pub(super) document_count: i64,
    pub(super) updated_at: Option<String>,
    pub(super) revision: Option<String>,
}

impl HostedSourceRevision {
    fn from_index(index: &SourceIndexSummary) -> Option<Self> {
        // Same precedence the browser normalizer uses, so the pinned value
        // and the re-read value are derived from the same field priority.
        index
            .document_count
            .or(index.entries)
            .map(|document_count| Self {
                document_count,
                updated_at: index.updated_at.clone(),
                revision: index.revision.clone(),
            })
    }
}

#[derive(Debug, Default)]
pub(super) struct ListSourceIndexesQuery {
    pub(super) offset: Option<u64>,
    pub(super) limit: Option<u64>,
}

pub(super) async fn list_hosted_source_indexes<Request: HostedSourceRequest>(
    state: &AppState,
    source_provider: SourceImportProvider,
    raw_query: Option<&str>,
    body: &Bytes,
) -> Result<Response, ApiError> {
    // Decode before the typed parse so the UTF-8 refusal is the branch that
    // actually reports a non-UTF-8 body; `serde_json` would otherwise reject it
    // first as a generic incompatible body.
    let body = std::str::from_utf8(body).map_err(|_| {
        migration_error(
            StatusCode::BAD_REQUEST,
            "invalid source discovery request: request body must be valid UTF-8",
            AlgoliaImportErrorCode::IncompatibleData,
        )
    })?;
    let request = serde_json::from_str::<Request>(body)
        .map_err(|error| map_discovery_request_deserialize_error(source_provider, error))?;
    let normalized_origin = validate_hosted_source_origin(request.source_origin())?;
    let api_key = request.api_key().to_string();
    // Forward the canonical origin we validated, not the caller's raw spelling.
    // This keeps the API and engine from interpreting a crafted authority with
    // different URL-parser rules.
    let body = request.into_forward_body(&normalized_origin);
    let query = parse_list_source_indexes_query(raw_query)?;
    let target = MigrationProxyOperation::SourceDiscovery
        .backend_target(state)
        .await?;
    let response = state
        .flapjack_proxy
        .list_source_indexes(
            &target.flapjack_url,
            &target.node_secret_id,
            &target.region,
            SourceIndexDiscoveryRequest::new(source_provider, query.offset, query.limit, &body),
        )
        .await
        .map_err(|error| MigrationProxyOperation::SourceDiscovery.map_proxy_error(error))?;
    let mut decoded = serde_json::from_value::<ListSourceIndexesResponse>(response)
        .map_err(map_invalid_hosted_discovery_response)?;
    decoded
        .validate()
        .map_err(map_invalid_hosted_discovery_response)?;
    decorate_hosted_source_revisions(source_provider, &mut decoded, &normalized_origin, &api_key)
        .await;

    Ok(Json(decoded).into_response())
}

/// Enforce the hosted-source origin contract at the API boundary. The engine
/// receives the source credential and performs the network request, so the
/// browser-side form guard is not an authorization boundary: direct API clients
/// must be unable to select loopback, IP-literal, or explicitly local authorities.
/// Local parity tests retain an explicit private-server opt-in for exact
/// loopback hostnames only.
pub(super) fn validate_hosted_source_origin(value: &str) -> Result<String, ApiError> {
    let allow_loopback = std::env::var(ALLOW_LOOPBACK_SOURCE_ORIGINS_ENV).as_deref() == Ok("1");
    normalize_hosted_source_origin(value, allow_loopback).ok_or_else(|| {
        migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_source_host",
            AlgoliaImportErrorCode::IncompatibleData,
        )
    })
}

fn normalize_hosted_source_origin(value: &str, allow_loopback: bool) -> Option<String> {
    if value.is_empty() || value != value.trim() {
        return None;
    }
    let Ok(parsed) = Url::parse(value) else {
        return None;
    };
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || parsed.path() != "/"
    {
        return None;
    }

    let hostname = parsed.host_str().map(str::to_ascii_lowercase)?;
    // `Url::host_str` retains brackets for IPv6 literals. Normalize only for
    // classification; the parsed URL remains the canonical authority owner.
    let normalized_hostname = hostname
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(&hostname);
    let loopback = matches!(normalized_hostname, "localhost" | "127.0.0.1" | "::1");
    if allow_loopback && loopback && matches!(parsed.scheme(), "http" | "https") {
        return Some(parsed.origin().ascii_serialization());
    }

    (parsed.scheme() == "https"
        && parsed.port().is_none()
        && normalized_hostname.parse::<IpAddr>().is_err()
        && normalized_hostname != "localhost"
        && !normalized_hostname.ends_with(".localhost")
        && normalized_hostname.contains('.'))
    .then(|| parsed.origin().ascii_serialization())
}

/// One discovery page is the largest the picker itself requests, so a
/// create-time re-read paging at the same width sees the catalog exactly as the
/// picker paged it.
const SOURCE_REVISION_PAGE_SIZE: u64 = 100;

/// Bound on the re-read traversal. `list_hosted_source_indexes` already refuses
/// oversized catalogs upstream; this only stops a non-advancing adapter from
/// looping forever.
const SOURCE_REVISION_MAX_PAGES: usize = 50;

/// Fresh producer-native revision for one hosted source index, read through the
/// same engine discovery surface the source picker read.
///
/// `Ok(None)` means the index is no longer discoverable, or the adapter no
/// longer reports a count for it. Both are indeterminate against a pinned source
/// revision, and the caller treats indeterminate as drift rather than as proof
/// the source held still.
pub(super) async fn read_hosted_source_revision(
    state: &AppState,
    source_provider: SourceImportProvider,
    credentials: &str,
    source_name: &str,
) -> Result<Option<HostedSourceRevision>, ApiError> {
    let target = MigrationProxyOperation::SourceDiscovery
        .backend_target(state)
        .await?;
    let mut offset = 0u64;
    for _ in 0..SOURCE_REVISION_MAX_PAGES {
        let response = state
            .flapjack_proxy
            .list_source_indexes(
                &target.flapjack_url,
                &target.node_secret_id,
                &target.region,
                SourceIndexDiscoveryRequest::new(
                    source_provider,
                    Some(offset),
                    Some(SOURCE_REVISION_PAGE_SIZE),
                    credentials,
                ),
            )
            .await
            .map_err(|error| MigrationProxyOperation::SourceDiscovery.map_proxy_error(error))?;
        let mut page = serde_json::from_value::<ListSourceIndexesResponse>(response)
            .map_err(map_invalid_hosted_discovery_response)?;
        page.validate()
            .map_err(map_invalid_hosted_discovery_response)?;
        if let Some((origin, api_key)) =
            typesense_credentials_from_forward_body(source_provider, credentials)
        {
            decorate_hosted_source_revisions(source_provider, &mut page, &origin, &api_key).await;
        }
        if let Some(index) = page.indexes.iter().find(|index| index.name == source_name) {
            return Ok(HostedSourceRevision::from_index(index));
        }
        if page.indexes.is_empty() {
            return Ok(None);
        }
        offset = offset.saturating_add(page.indexes.len() as u64);
        if page
            .total
            .is_some_and(|total| offset >= total.max(0) as u64)
        {
            return Ok(None);
        }
    }
    Ok(None)
}

fn typesense_credentials_from_forward_body(
    source_provider: SourceImportProvider,
    credentials: &str,
) -> Option<(String, String)> {
    if source_provider != SourceImportProvider::Typesense {
        return None;
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TypesenseCredentials {
        node: String,
        api_key: String,
    }
    let parsed = serde_json::from_str::<TypesenseCredentials>(credentials).ok()?;
    Some((parsed.node, parsed.api_key))
}

async fn decorate_hosted_source_revisions(
    source_provider: SourceImportProvider,
    response: &mut ListSourceIndexesResponse,
    origin: &str,
    api_key: &str,
) {
    if source_provider != SourceImportProvider::Typesense {
        return;
    }
    for index in &mut response.indexes {
        if index.revision.is_some() {
            continue;
        }
        index.revision = read_typesense_collection_revision(origin, api_key, &index.name).await;
    }
}

async fn read_typesense_collection_revision(
    origin: &str,
    api_key: &str,
    collection: &str,
) -> Option<String> {
    read_typesense_collection_revision_with_timeout(
        origin,
        api_key,
        collection,
        TYPESENSE_REVISION_REQUEST_TIMEOUT,
    )
    .await
}

pub(super) async fn read_typesense_collection_revision_with_timeout(
    origin: &str,
    api_key: &str,
    collection: &str,
    request_timeout: Duration,
) -> Option<String> {
    let mut url = Url::parse(origin).ok()?;
    {
        let mut segments = url.path_segments_mut().ok()?;
        segments
            .clear()
            .push("collections")
            .push(collection)
            .push("documents")
            .push("export");
    }
    let client = reqwest::Client::builder()
        .redirect(Policy::none())
        .connect_timeout(TYPESENSE_REVISION_CONNECT_TIMEOUT)
        .timeout(request_timeout)
        .build()
        .ok()?;
    let mut response = client
        .get(url)
        .header("x-typesense-api-key", api_key)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    // Hash the export incrementally so a collection's size never decides
    // whether it gets a revision. Buffering the whole export and giving up past
    // a byte ceiling made every large collection indeterminate, and an
    // indeterminate revision is not evidence the source held still. Streaming
    // keeps memory flat at one chunk while still producing a determinate hash
    // for exports of any size.
    let mut digest = Sha256::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        digest.update(&chunk);
    }
    Some(format!("sha256:{}", hex::encode(digest.finalize())))
}

pub(super) fn map_invalid_hosted_discovery_response(error: impl fmt::Display) -> ApiError {
    MigrationProxyOperation::SourceDiscovery.map_proxy_error(ProxyError::FlapjackError {
        status: StatusCode::INTERNAL_SERVER_ERROR.as_u16(),
        message: format!("invalid source index list response: {error}"),
    })
}

pub(super) fn map_discovery_request_deserialize_error(
    source_provider: SourceImportProvider,
    error: serde_json::Error,
) -> ApiError {
    let message = match serde_offending_field(&error) {
        Some(field) => format!(
            "invalid {} discovery request: field `{field}` is incompatible",
            source_provider.as_str()
        ),
        None => format!(
            "invalid {} discovery request: request body is incompatible",
            source_provider.as_str()
        ),
    };
    migration_error(
        StatusCode::BAD_REQUEST,
        message,
        AlgoliaImportErrorCode::IncompatibleData,
    )
}

pub(super) fn parse_list_source_indexes_query(
    raw_query: Option<&str>,
) -> Result<ListSourceIndexesQuery, ApiError> {
    let mut query = ListSourceIndexesQuery::default();
    for pair in raw_query
        .unwrap_or_default()
        .split('&')
        .filter(|pair| !pair.is_empty())
    {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        match name {
            "offset" => query.offset = Some(parse_source_discovery_query_u64(name, value)?),
            "limit" => query.limit = Some(parse_source_discovery_query_u64(name, value)?),
            _ => {}
        }
    }
    Ok(query)
}

fn parse_source_discovery_query_u64(name: &str, value: &str) -> Result<u64, ApiError> {
    value.parse::<u64>().map_err(|_| {
        migration_error(
            StatusCode::BAD_REQUEST,
            format!("invalid source discovery query parameter `{name}`"),
            AlgoliaImportErrorCode::IncompatibleData,
        )
    })
}

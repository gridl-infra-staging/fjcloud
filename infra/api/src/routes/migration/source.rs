//! Source-index discovery (`POST /migration/{source_provider}/list-indexes`)
//! for every adapter-backed provider, and the single mapping of Algolia
//! source-service errors onto stable migration codes.
use std::fmt;

use axum::body::Bytes;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use utoipa::{PartialSchema, ToSchema};

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::SourceImportProvider;
use crate::models::{AlgoliaImportErrorCode, VmInventory};
use crate::services::algolia_source::{
    AlgoliaSourceError, AlgoliaSourceListRequest, AlgoliaSourceListResponse,
};
use crate::services::flapjack_proxy::{ProxyError, SourceIndexDiscoveryRequest};
use crate::state::AppState;

use super::{
    migration_backend_unavailable, migration_error, migration_unavailable,
    require_json_content_type, serde_offending_field, validate_adapter_source_provider,
    MigrationSourcePath, ALGOLIA_ACL_GUIDANCE, REDACTED_CREDENTIAL,
};

const MAX_LIST_INDEXES_HITS_PER_PAGE: u32 = 100;

pub(super) struct MigrationBackendTarget {
    pub flapjack_url: String,
    pub node_secret_id: String,
    pub region: String,
}

impl From<VmInventory> for MigrationBackendTarget {
    fn from(vm: VmInventory) -> Self {
        let node_secret_id = vm.node_secret_id().to_string();
        Self {
            flapjack_url: vm.flapjack_url,
            node_secret_id,
            region: vm.region,
        }
    }
}

#[derive(Clone, Copy)]
pub(super) enum MigrationProxyOperation {
    Preview,
    SourceDiscovery,
}

impl MigrationProxyOperation {
    fn internal_error_name(self) -> &'static str {
        match self {
            Self::Preview => "migration_preview_failed",
            Self::SourceDiscovery => "migration_source_discovery_failed",
        }
    }

    fn rejection_error_name(self) -> &'static str {
        match self {
            Self::Preview => "migration_preview_rejected",
            Self::SourceDiscovery => "migration_source_discovery_rejected",
        }
    }

    fn log_name(self) -> &'static str {
        match self {
            Self::Preview => "migration preview",
            Self::SourceDiscovery => "migration source discovery",
        }
    }

    fn internal_error(self) -> ApiError {
        migration_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            self.internal_error_name(),
            AlgoliaImportErrorCode::Internal,
        )
    }

    pub(super) async fn backend_target(
        self,
        state: &AppState,
    ) -> Result<MigrationBackendTarget, ApiError> {
        let target = state
            .vm_inventory_repo
            .list_active(None)
            .await
            .map_err(|error| {
                tracing::error!("{} could not read VM inventory: {error}", self.log_name());
                self.internal_error()
            })?
            .into_iter()
            .next()
            .ok_or_else(|| {
                migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
            })?;

        Ok(target.into())
    }

    pub(super) fn map_proxy_error(self, error: ProxyError) -> ApiError {
        match error {
            // Engine diagnostics are untrusted and can reflect the credential-bearing
            // request body. Keep them out of both the customer response and logs.
            ProxyError::FlapjackError { status, message: _ } if (400..500).contains(&status) => {
                migration_error(
                    StatusCode::BAD_REQUEST,
                    self.rejection_error_name(),
                    AlgoliaImportErrorCode::IncompatibleData,
                )
            }
            ProxyError::Unreachable(message) => {
                tracing::warn!("{} backend unreachable: {message}", self.log_name());
                migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
            }
            ProxyError::Timeout => {
                migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
            }
            ProxyError::FlapjackError { status, message: _ } => {
                tracing::error!("{} engine failed (HTTP {status})", self.log_name());
                self.internal_error()
            }
            ProxyError::SecretError(message) => {
                tracing::error!("{} secret lookup failed: {message}", self.log_name());
                self.internal_error()
            }
        }
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListAlgoliaIndexesRequest {
    pub app_id: String,
    pub api_key: String,
    pub cursor: Option<String>,
    #[schema(minimum = 1, maximum = 100)]
    pub hits_per_page: Option<u32>,
}

impl fmt::Debug for ListAlgoliaIndexesRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ListAlgoliaIndexesRequest")
            .field("app_id", &REDACTED_CREDENTIAL)
            .field("api_key", &REDACTED_CREDENTIAL)
            .field("cursor", &self.cursor.as_ref().map(|_| REDACTED_CREDENTIAL))
            .field("hits_per_page", &self.hits_per_page)
            .finish()
    }
}

impl Serialize for ListAlgoliaIndexesRequest {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;

        let mut request = serializer.serialize_struct("ListAlgoliaIndexesRequest", 4)?;
        request.serialize_field("appId", REDACTED_CREDENTIAL)?;
        request.serialize_field("apiKey", REDACTED_CREDENTIAL)?;
        request.serialize_field("cursor", &self.cursor.as_ref().map(|_| REDACTED_CREDENTIAL))?;
        request.serialize_field("hitsPerPage", &self.hits_per_page)?;
        request.end()
    }
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListMeilisearchIndexesRequest {
    pub endpoint: String,
    pub api_key: String,
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

#[derive(Serialize, ToSchema)]
#[serde(untagged)]
pub enum ListSourceIndexesRequest {
    Algolia(ListAlgoliaIndexesRequest),
    Meilisearch(ListMeilisearchIndexesRequest),
    Typesense(ListTypesenseIndexesRequest),
}

#[derive(Serialize, ToSchema)]
#[serde(untagged)]
pub enum ListSourceIndexesResponseBody {
    Algolia(AlgoliaSourceListResponse),
    Hosted(ListSourceIndexesResponse),
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

#[derive(Debug, Default)]
struct ListSourceIndexesQuery {
    offset: Option<u64>,
    limit: Option<u64>,
}

#[utoipa::path(
    post,
    path = "/migration/{source_provider}/list-indexes",
    operation_id = "list_algolia_indexes",
    tag = "Migration",
    params(
        ("source_provider" = SourceImportProvider, Path, description = "Source migration provider"),
        ("offset" = Option<i64>, Query, description = "Hosted source discovery page offset", minimum = 0),
        ("limit" = Option<i64>, Query, description = "Hosted source discovery page size", minimum = 0),
    ),
    request_body = ListSourceIndexesRequest,
    responses(
        (status = 200, description = "One page of source-index picker metadata", body = ListSourceIndexesResponseBody),
        (status = 400, description = "Invalid credentials, request body, cursor, or bounded catalog", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Algolia key requires listIndexes ACL", body = crate::errors::MigrationErrorResponse),
        (status = 415, description = "Request body must use a JSON media type", body = crate::errors::MigrationErrorResponse),
        (status = 500, description = "Backend target, engine response, or secret lookup failed", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Algolia discovery unavailable or timed out", body = crate::errors::MigrationErrorResponse),
    )
)]
/// Lists source indexes for the validated migration provider.
pub async fn list_source_indexes(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    RawQuery(raw_query): RawQuery,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    let source_provider = validate_adapter_source_provider(path.source_provider.as_deref())?;
    // Gate on availability before media type, matching preview: an unavailable
    // provider answers 503 regardless of how the request was framed.
    if !super::migration_available(&state, source_provider) {
        return Err(migration_unavailable());
    }
    require_json_content_type(&headers)?;
    match source_provider {
        SourceImportProvider::Algolia => list_algolia_indexes(&state, &body).await,
        SourceImportProvider::Meilisearch => {
            list_hosted_source_indexes::<ListMeilisearchIndexesRequest>(
                &state,
                source_provider,
                raw_query.as_deref(),
                &body,
            )
            .await
        }
        SourceImportProvider::Typesense => {
            list_hosted_source_indexes::<ListTypesenseIndexesRequest>(
                &state,
                source_provider,
                raw_query.as_deref(),
                &body,
            )
            .await
        }
    }
}

async fn list_algolia_indexes(state: &AppState, body: &[u8]) -> Result<Response, ApiError> {
    let request = deserialize_list_algolia_indexes_request(body)?;
    if request.api_key.is_empty() {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
        ));
    }
    if matches!(request.hits_per_page, Some(0))
        || request.hits_per_page > Some(MAX_LIST_INDEXES_HITS_PER_PAGE)
    {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "source_catalog_too_large",
            AlgoliaImportErrorCode::SourceCatalogTooLarge,
        ));
    }
    let response = state
        .algolia_source_service
        .list_indexes(AlgoliaSourceListRequest {
            app_id: request.app_id,
            api_key: request.api_key,
            cursor: request.cursor,
            hits_per_page: request.hits_per_page,
        })
        .await
        .map_err(map_algolia_source_error)?;
    Ok(Json(response).into_response())
}

async fn list_hosted_source_indexes<Request: DeserializeOwned>(
    state: &AppState,
    source_provider: SourceImportProvider,
    raw_query: Option<&str>,
    body: &[u8],
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
    serde_json::from_str::<Request>(body)
        .map(drop)
        .map_err(|error| map_discovery_request_deserialize_error(source_provider, error))?;
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
            SourceIndexDiscoveryRequest::new(source_provider, query.offset, query.limit, body),
        )
        .await
        .map_err(|error| MigrationProxyOperation::SourceDiscovery.map_proxy_error(error))?;
    let decoded = serde_json::from_value::<ListSourceIndexesResponse>(response.clone())
        .map_err(map_invalid_hosted_discovery_response)?;
    decoded
        .validate()
        .map_err(map_invalid_hosted_discovery_response)?;

    Ok(Json(response).into_response())
}

fn map_invalid_hosted_discovery_response(error: impl fmt::Display) -> ApiError {
    MigrationProxyOperation::SourceDiscovery.map_proxy_error(ProxyError::FlapjackError {
        status: StatusCode::INTERNAL_SERVER_ERROR.as_u16(),
        message: format!("invalid source index list response: {error}"),
    })
}

fn deserialize_list_algolia_indexes_request(
    body: &[u8],
) -> Result<ListAlgoliaIndexesRequest, ApiError> {
    serde_json::from_slice::<ListAlgoliaIndexesRequest>(body).map_err(|error| {
        map_discovery_request_deserialize_error(SourceImportProvider::Algolia, error)
    })
}

fn map_discovery_request_deserialize_error(
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

fn parse_list_source_indexes_query(
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

/// Single mapping of the source service's typed errors onto stable migration
/// codes. Shared by list-indexes discovery here and the create handler's final
/// source inspection in the parent module.
pub(super) fn map_algolia_source_error(error: AlgoliaSourceError) -> ApiError {
    match error {
        AlgoliaSourceError::InvalidApplicationId => migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_application_id",
            AlgoliaImportErrorCode::SourceNotFound,
        ),
        AlgoliaSourceError::InvalidCredentials => migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
        ),
        AlgoliaSourceError::InvalidCursor => migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_discovery_cursor",
            AlgoliaImportErrorCode::SourceChanged,
        ),
        AlgoliaSourceError::SourceIndexNotFound => migration_error(
            StatusCode::BAD_REQUEST,
            "algolia_source_index_not_found",
            AlgoliaImportErrorCode::SourceNotFound,
        ),
        AlgoliaSourceError::SourceCatalogTooLarge => migration_error(
            StatusCode::BAD_REQUEST,
            "source_catalog_too_large",
            AlgoliaImportErrorCode::SourceCatalogTooLarge,
        ),
        AlgoliaSourceError::ListIndexesAclRequired
        | AlgoliaSourceError::SourcePermissionRequired => migration_error(
            StatusCode::FORBIDDEN,
            ALGOLIA_ACL_GUIDANCE,
            AlgoliaImportErrorCode::MissingSourcePermission,
        ),
        AlgoliaSourceError::TimedOut => {
            migration_backend_unavailable("algolia_discovery_timed_out")
        }
        AlgoliaSourceError::Unavailable
        | AlgoliaSourceError::InvalidUpstreamResponse
        | AlgoliaSourceError::InvalidCursorKey => {
            migration_backend_unavailable("algolia_discovery_unavailable")
        }
    }
}

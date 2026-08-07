//! Source-index discovery (`POST /migration/{source_provider}/list-indexes`)
//! for every adapter-backed provider, and the single mapping of Algolia
//! source-service errors onto stable migration codes.
use std::fmt;

use axum::body::Bytes;
use axum::extract::{Path, RawQuery, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::SourceImportProvider;
use crate::models::{AlgoliaImportErrorCode, VmInventory};
use crate::services::algolia_source::{
    AlgoliaSourceError, AlgoliaSourceListRequest, AlgoliaSourceListResponse,
};
use crate::services::flapjack_proxy::ProxyError;
use crate::state::AppState;

use super::{
    migration_backend_unavailable, migration_error, migration_unavailable,
    require_json_content_type, validate_adapter_source_provider, MigrationSourcePath,
    ALGOLIA_ACL_GUIDANCE, REDACTED_CREDENTIAL,
};

pub(super) use super::hosted_discovery::{
    read_hosted_source_revision, validate_hosted_source_origin,
};
pub use super::hosted_discovery::{
    ListMeilisearchIndexesRequest, ListSourceIndexesResponse, ListTypesenseIndexesRequest,
    SourceIndexCreatedAt, SourceIndexSummary,
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
        let vm = state
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

        // Prime the shared VM's node admin key before proxying. The proxy's own
        // `get_admin_key` reads the secret store but does not create-on-missing,
        // and the local/dev in-memory backend never has a key until one is
        // created on demand. Without this, every browser-driven discovery /
        // preview against a freshly auto-provisioned shared VM fails with a
        // secret-store error ("no key found for node ..."). This mirrors
        // `ensure_shared_vm_has_admin_key` on the index-placement path; in
        // production the proxy and provisioning service share one
        // `NodeSecretManager`, so the primed key is visible to the later proxy
        // lookup.
        crate::services::flapjack_node::get_or_create_node_api_key(
            state.provisioning_service.node_secret_manager.as_ref(),
            &vm,
        )
        .await
        .map_err(|error| {
            tracing::error!(
                "{} could not prime shared VM admin key: {error}",
                self.log_name()
            );
            self.internal_error()
        })?;

        Ok(vm.into())
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
            super::hosted_discovery::list_hosted_source_indexes::<ListMeilisearchIndexesRequest>(
                &state,
                source_provider,
                raw_query.as_deref(),
                &body,
            )
            .await
        }
        SourceImportProvider::Typesense => {
            super::hosted_discovery::list_hosted_source_indexes::<ListTypesenseIndexesRequest>(
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

fn deserialize_list_algolia_indexes_request(
    body: &[u8],
) -> Result<ListAlgoliaIndexesRequest, ApiError> {
    serde_json::from_slice::<ListAlgoliaIndexesRequest>(body).map_err(|error| {
        super::hosted_discovery::map_discovery_request_deserialize_error(
            SourceImportProvider::Algolia,
            error,
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

#[cfg(test)]
mod tests {
    use std::time::Duration;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn typesense_revision_read_refuses_a_response_past_its_deadline() {
        let source = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/collections/slow/documents/export"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_delay(Duration::from_millis(100))
                    .set_body_string(r#"{"id":"too-late"}"#),
            )
            .mount(&source)
            .await;

        let revision =
            super::super::hosted_discovery::read_typesense_collection_revision_with_timeout(
                &source.uri(),
                "TIMEOUT-KEY-CANARY",
                "slow",
                Duration::from_millis(20),
            )
            .await;

        assert_eq!(revision, None);
    }
}

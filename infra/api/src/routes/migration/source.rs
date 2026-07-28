//! Algolia source-index discovery (`POST /migration/algolia/list-indexes`) and
//! the single mapping of source-service errors onto stable migration codes.
use std::fmt;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::AlgoliaImportErrorCode;
use crate::services::algolia_source::{
    AlgoliaSourceError, AlgoliaSourceListRequest, AlgoliaSourceListResponse,
};
use crate::state::AppState;

use super::{
    migration_backend_unavailable, migration_error, migration_unavailable,
    validate_source_provider, MigrationSourcePath, ALGOLIA_ACL_GUIDANCE,
};

const MAX_LIST_INDEXES_HITS_PER_PAGE: u32 = 100;

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
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
            .field("app_id", &"[REDACTED]")
            .field("api_key", &"[REDACTED]")
            .field("cursor", &self.cursor.as_ref().map(|_| "[REDACTED]"))
            .field("hits_per_page", &self.hits_per_page)
            .finish()
    }
}

#[utoipa::path(
    post,
    path = "/migration/algolia/list-indexes",
    operation_id = "list_algolia_indexes",
    tag = "Migration",
    request_body = ListAlgoliaIndexesRequest,
    responses(
        (status = 200, description = "One page of Algolia source-index picker metadata", body = AlgoliaSourceListResponse),
        (status = 400, description = "Invalid Algolia credentials, application ID, cursor, or bounded catalog", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Algolia key requires listIndexes ACL", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Algolia discovery unavailable or timed out", body = crate::errors::MigrationErrorResponse),
    )
)]
/// Lists source indexes for the validated migration provider.
pub async fn list_source_indexes(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
    Json(request): Json<ListAlgoliaIndexesRequest>,
) -> Result<Json<AlgoliaSourceListResponse>, ApiError> {
    validate_source_provider(path.source_provider.as_deref())?;
    if !super::migration_available(&state) {
        return Err(migration_unavailable());
    }
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
    Ok(Json(response))
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

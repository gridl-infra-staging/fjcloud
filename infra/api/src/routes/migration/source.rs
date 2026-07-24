//! Algolia source-index discovery (`POST /migration/algolia/list-indexes`) and
//! the single mapping of source-service errors onto stable migration codes.
use std::fmt;

use axum::extract::State;
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

use super::{migration_backend_unavailable, migration_error, ALGOLIA_ACL_GUIDANCE};

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct ListAlgoliaIndexesRequest {
    pub app_id: String,
    pub api_key: String,
    pub cursor: Option<String>,
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
pub async fn list_algolia_indexes(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(request): Json<ListAlgoliaIndexesRequest>,
) -> Result<Json<AlgoliaSourceListResponse>, ApiError> {
    if request.api_key.is_empty() {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "invalid_algolia_credentials",
            AlgoliaImportErrorCode::InvalidCredentials,
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

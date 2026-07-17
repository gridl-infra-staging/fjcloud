use std::fmt;

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::services::algolia_source::{
    AlgoliaSourceError, AlgoliaSourceListRequest, AlgoliaSourceListResponse,
};
use crate::state::AppState;

pub const ALGOLIA_MIGRATION_UNAVAILABLE_REASON: &str = "temporarily_unavailable";
pub const ALGOLIA_MIGRATION_UNAVAILABLE_MESSAGE: &str =
    "Algolia migration is temporarily unavailable while we replace the importer.";
pub const ALGOLIA_ACL_GUIDANCE: &str = "Algolia discovery requires listIndexes. Migration requires settings and browse; seeUnretrievableAttributes is optional.";

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

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaMigrationAvailabilityReason {
    TemporarilyUnavailable,
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaMigrationAvailabilityResponse {
    pub available: bool,
    pub reason: AlgoliaMigrationAvailabilityReason,
    pub message: String,
}

impl AlgoliaMigrationAvailabilityResponse {
    fn unavailable() -> Self {
        Self {
            available: false,
            reason: AlgoliaMigrationAvailabilityReason::TemporarilyUnavailable,
            message: ALGOLIA_MIGRATION_UNAVAILABLE_MESSAGE.to_string(),
        }
    }
}

#[utoipa::path(
    get,
    path = "/migration/algolia/availability",
    tag = "Migration",
    responses(
        (status = 200, description = "Algolia migration availability", body = AlgoliaMigrationAvailabilityResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn algolia_availability(
    _auth: AuthenticatedTenant,
    State(_state): State<AppState>,
) -> Json<AlgoliaMigrationAvailabilityResponse> {
    // Stage 1 intentionally fails closed: customer-facing migration admission
    // remains unavailable until the replacement importer and its route surface
    // exist together again.
    Json(AlgoliaMigrationAvailabilityResponse::unavailable())
}

#[utoipa::path(
    post,
    path = "/migration/algolia/list-indexes",
    tag = "Migration",
    request_body = ListAlgoliaIndexesRequest,
    responses(
        (status = 200, description = "One page of Algolia source-index picker metadata", body = AlgoliaSourceListResponse),
        (status = 400, description = "Invalid Algolia credentials, application ID, cursor, or bounded catalog", body = crate::errors::ErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Algolia key requires listIndexes ACL", body = crate::errors::ErrorResponse),
        (status = 503, description = "Algolia discovery unavailable or timed out", body = crate::errors::ErrorResponse),
    )
)]
pub async fn list_algolia_indexes(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(request): Json<ListAlgoliaIndexesRequest>,
) -> Result<Json<AlgoliaSourceListResponse>, ApiError> {
    if request.api_key.is_empty() {
        return Err(ApiError::BadRequest(
            "invalid_algolia_credentials".to_string(),
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

fn map_algolia_source_error(error: AlgoliaSourceError) -> ApiError {
    match error {
        AlgoliaSourceError::InvalidApplicationId => {
            ApiError::BadRequest("invalid_algolia_application_id".to_string())
        }
        AlgoliaSourceError::InvalidCredentials => {
            ApiError::BadRequest("invalid_algolia_credentials".to_string())
        }
        AlgoliaSourceError::InvalidCursor => {
            ApiError::BadRequest("invalid_algolia_discovery_cursor".to_string())
        }
        AlgoliaSourceError::SourceCatalogTooLarge => {
            ApiError::BadRequest("source_catalog_too_large".to_string())
        }
        AlgoliaSourceError::ListIndexesAclRequired => {
            ApiError::Forbidden(ALGOLIA_ACL_GUIDANCE.to_string())
        }
        AlgoliaSourceError::TimedOut => {
            ApiError::ServiceUnavailable("algolia_discovery_timed_out".to_string())
        }
        AlgoliaSourceError::Unavailable
        | AlgoliaSourceError::InvalidUpstreamResponse
        | AlgoliaSourceError::InvalidCursorKey => {
            ApiError::ServiceUnavailable("algolia_discovery_unavailable".to_string())
        }
    }
}

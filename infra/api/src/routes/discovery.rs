//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/discovery.rs.
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use crate::auth::api_key::ApiKeyAuth;
use crate::errors::ApiError;
use crate::scopes;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct DiscoverQuery {
    pub index: String,
}

/// `GET /discover?index=<name>` — resolve an index name to its flapjack endpoint.
///
/// **Auth:** API key (`ApiKeyAuth`), requires `search` scope.
/// Returns the flapjack URL, node ID, and region for the named index, or
/// 404 if the index does not exist for the authenticated customer.
pub async fn discover(
    auth: ApiKeyAuth,
    State(state): State<AppState>,
    Query(query): Query<DiscoverQuery>,
) -> Result<impl IntoResponse, ApiError> {
    auth.require_scope(scopes::SEARCH)?;

    let result = state
        .discovery_service
        .discover(auth.customer_id, &query.index)
        .await
        .map_err(|e| match e {
            crate::services::discovery::DiscoveryError::NotFound => {
                ApiError::NotFound("index not found".into())
            }
            crate::services::discovery::DiscoveryError::RepoError(msg) => ApiError::Internal(msg),
        })?;

    Ok((StatusCode::OK, Json(result)))
}

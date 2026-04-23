//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/auth/storage.rs.
use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::services::storage::s3_auth::{S3AuthContext, S3AuthService};
use crate::services::storage::s3_error::{from_auth_error, S3ErrorResponse};
use crate::state::AppState;

const DEFAULT_S3_REQUEST_ID: &str = "s3-auth-request";

#[async_trait]
impl FromRequestParts<AppState> for S3AuthContext {
    type Rejection = S3ErrorResponse;

    /// Returns the [`S3AuthContext`] from request extensions if already present
    /// (e.g. injected by middleware or test harness), otherwise delegates to
    /// [`S3AuthService::authenticate`].
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        if let Some(context) = parts.extensions.get::<S3AuthContext>() {
            return Ok(context.clone());
        }

        let method = parts.method.as_str();
        let uri = parts
            .uri
            .path_and_query()
            .map(|path_and_query| path_and_query.as_str())
            .unwrap_or_else(|| parts.uri.path());
        let headers = request_headers(parts);
        let auth_service = S3AuthService::new(
            state.storage_key_repo.clone(),
            state.customer_repo.clone(),
            state.storage_master_key,
        );

        auth_service
            .authenticate(method, uri, &headers)
            .await
            .map_err(|error| from_auth_error(&error, parts.uri.path(), request_id(parts)))
    }
}

fn request_headers(parts: &Parts) -> Vec<(&str, &str)> {
    let mut headers = Vec::with_capacity(parts.headers.len());
    for (name, value) in &parts.headers {
        if let Ok(value) = value.to_str() {
            headers.push((name.as_str(), value));
        }
    }
    headers
}

fn request_id(parts: &Parts) -> &str {
    parts
        .headers
        .get("x-amz-request-id")
        .and_then(|value| value.to_str().ok())
        .or_else(|| {
            parts
                .headers
                .get("x-request-id")
                .and_then(|value| value.to_str().ok())
        })
        .unwrap_or(DEFAULT_S3_REQUEST_ID)
}

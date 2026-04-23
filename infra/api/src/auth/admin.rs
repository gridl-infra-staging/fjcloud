//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/auth/admin.rs.
use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use subtle::ConstantTimeEq;

use crate::auth::error::AuthError;
use crate::state::AppState;

#[derive(Debug, Clone, Copy)]
pub struct AdminAuth;

#[async_trait]
impl FromRequestParts<AppState> for AdminAuth {
    type Rejection = AuthError;

    /// Extracts the `x-admin-key` header and performs a constant-time comparison
    /// against the configured admin key. Returns `MissingAdminKey` when the
    /// header is absent or `InvalidAdminKey` on mismatch.
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let provided = parts
            .headers
            .get("x-admin-key")
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::MissingAdminKey)?;

        if provided.as_bytes().ct_eq(state.admin_key.as_bytes()).into() {
            Ok(AdminAuth)
        } else {
            Err(AuthError::InvalidAdminKey)
        }
    }
}

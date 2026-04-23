//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/auth/api_key.rs.
use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::auth::error::AuthError;
use crate::errors::ApiError;
use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct ApiKeyAuth {
    pub customer_id: Uuid,
    pub key_id: Uuid,
    pub scopes: Vec<String>,
}

impl ApiKeyAuth {
    pub fn require_scope(&self, scope: &str) -> Result<(), ApiError> {
        if self.scopes.iter().any(|s| s == scope) {
            Ok(())
        } else {
            Err(ApiError::Forbidden("insufficient scope".into()))
        }
    }
}

#[async_trait]
impl FromRequestParts<AppState> for ApiKeyAuth {
    type Rejection = AuthError;

    /// Authenticates via `Authorization: Bearer <key>`. Performs a prefix-based
    /// DB lookup (first 16 chars), then SHA-256 hash comparison using constant-time
    /// equality. Checks customer status (Suspended → 403, missing → 401) and
    /// fires a non-blocking `last_used` timestamp update via `tokio::spawn`.
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::MissingToken)?;

        let key = auth_header
            .strip_prefix("Bearer ")
            .ok_or(AuthError::MissingToken)?;

        let is_management_key = key.starts_with("gridl_live_") || key.starts_with("fj_live_");
        if !is_management_key || key.len() < 16 {
            return Err(AuthError::InvalidToken);
        }

        let prefix = &key[..16];

        let mut hasher = Sha256::new();
        hasher.update(key.as_bytes());
        let provided_hash = hex::encode(hasher.finalize());

        let candidates = state
            .api_key_repo
            .find_by_prefix(prefix)
            .await
            .map_err(|_| AuthError::Internal)?;

        let matched_key = candidates
            .into_iter()
            .find(|k| provided_hash.as_bytes().ct_eq(k.key_hash.as_bytes()).into());

        let key_row = matched_key.ok_or(AuthError::InvalidToken)?;

        let customer = state
            .customer_repo
            .find_by_id(key_row.customer_id)
            .await
            .map_err(|_| AuthError::Internal)?;

        match customer_auth_state(customer.as_ref()) {
            CustomerAuthState::Suspended => return Err(AuthError::Forbidden),
            CustomerAuthState::Missing => return Err(AuthError::InvalidToken),
            CustomerAuthState::Active => {}
        }

        let repo = state.api_key_repo.clone();
        let key_id = key_row.id;
        tokio::spawn(async move {
            let _ = repo.update_last_used(key_id).await;
        });

        Ok(ApiKeyAuth {
            customer_id: key_row.customer_id,
            key_id: key_row.id,
            scopes: key_row.scopes,
        })
    }
}

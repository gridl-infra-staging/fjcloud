//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/auth/tenant.rs.
use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use uuid::Uuid;

use crate::auth::claims::Claims;
use crate::auth::error::AuthError;
use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct AuthenticatedTenant {
    pub customer_id: Uuid,
}

#[async_trait]
impl FromRequestParts<AppState> for AuthenticatedTenant {
    type Rejection = AuthError;

    /// Decodes the JWT (HS256) from the `Authorization: Bearer` header, parses
    /// the UUID `sub` claim as the customer ID, and verifies the customer is
    /// not suspended.
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::MissingToken)?;

        let token = auth_header
            .strip_prefix("Bearer ")
            .ok_or(AuthError::MissingToken)?;

        let token_data = jsonwebtoken::decode::<Claims>(
            token,
            &DecodingKey::from_secret(state.jwt_secret.as_bytes()),
            &Validation::new(Algorithm::HS256),
        )
        .map_err(|_| AuthError::InvalidToken)?;

        let customer_id = token_data
            .claims
            .sub
            .parse::<Uuid>()
            .map_err(|_| AuthError::InvalidToken)?;

        // Check customer status — suspended customers get 403
        let customer = state
            .customer_repo
            .find_by_id(customer_id)
            .await
            .map_err(|_| AuthError::Internal)?;

        match customer_auth_state(customer.as_ref()) {
            CustomerAuthState::Suspended => return Err(AuthError::Forbidden),
            CustomerAuthState::Missing => return Err(AuthError::InvalidToken),
            CustomerAuthState::Active => {}
        }

        Ok(AuthenticatedTenant { customer_id })
    }
}

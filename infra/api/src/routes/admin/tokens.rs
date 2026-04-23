//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/tokens.rs.
use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use jsonwebtoken::{EncodingKey, Header};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::{AdminAuth, Claims};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateTokenRequest {
    pub customer_id: Uuid,
    pub expires_in_secs: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct CreateTokenResponse {
    pub token: String,
    pub expires_at: String,
}

/// `POST /admin/tokens` — mint a JWT for a given customer.
///
/// **Auth:** `AdminAuth`.
/// `expires_in_secs` is clamped to 1 minute – 30 days (default 24 hours).
/// Returns the signed token and its expiration timestamp.
pub async fn create_token(
    _admin: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<CreateTokenRequest>,
) -> Json<CreateTokenResponse> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_secs();

    const MIN_EXPIRY: u64 = 60; // 1 minute
    const MAX_EXPIRY: u64 = 30 * 24 * 3600; // 30 days
    let duration = req
        .expires_in_secs
        .unwrap_or(86400)
        .clamp(MIN_EXPIRY, MAX_EXPIRY);
    let exp = now + duration;

    let claims = Claims {
        sub: req.customer_id.to_string(),
        exp: exp as usize,
        iat: now as usize,
    };

    let token = jsonwebtoken::encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(state.jwt_secret.as_bytes()),
    )
    .expect("JWT encoding should not fail");

    let expires_at: DateTime<Utc> =
        DateTime::from_timestamp(exp as i64, 0).expect("valid timestamp");

    Json(CreateTokenResponse {
        token,
        expires_at: expires_at.to_rfc3339(),
    })
}

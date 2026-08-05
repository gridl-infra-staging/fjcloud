//! `POST /admin/tokens` — mint a JWT for a given customer.
//!
//! The optional `purpose` discriminator is retained only as caller-supplied
//! context in the audit metadata. Every successful admin-minted customer JWT
//! is audited because the route always grants tenant impersonation capability.
use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use jsonwebtoken::{EncodingKey, Header};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::{AdminAuth, Claims};
use crate::errors::ApiError;
use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::services::audit_log::{AuditEntry, ACTION_IMPERSONATION_TOKEN_CREATED};
use crate::state::AppState;

const PURPOSE_ADMIN: &str = "admin";
const PURPOSE_IMPERSONATION: &str = "impersonation";

#[derive(Debug, Deserialize)]
pub struct CreateTokenRequest {
    pub customer_id: Uuid,
    pub expires_in_secs: Option<u64>,
    /// Optional discriminator. Accepted values:
    /// * unset or `"admin"` — mint the token and record `purpose="admin"`
    /// * `"impersonation"` — mint the token and record `purpose="impersonation"`
    ///
    /// Any other value is rejected with 400 so a caller typo cannot silently
    /// change the route's audit metadata.
    #[serde(default)]
    pub purpose: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateTokenResponse {
    pub token: String,
    pub expires_at: String,
}

/// Validate the optional purpose discriminator against the supported values.
fn validated_purpose(purpose: Option<&str>) -> Result<Option<&str>, ApiError> {
    match purpose {
        None | Some(PURPOSE_ADMIN) | Some(PURPOSE_IMPERSONATION) => Ok(purpose),
        Some(other) => Err(ApiError::BadRequest(format!(
            "invalid purpose '{other}'; expected one of: admin, impersonation"
        ))),
    }
}

/// Fail fast when the requested token target would be rejected by tenant auth.
async fn require_token_customer(state: &AppState, customer_id: Uuid) -> Result<(), ApiError> {
    let customer = state.customer_repo.find_by_id(customer_id).await?;

    match customer_auth_state(customer.as_ref()) {
        CustomerAuthState::Active => Ok(()),
        CustomerAuthState::Suspended => Err(ApiError::Forbidden("customer is suspended".into())),
        CustomerAuthState::Missing => Err(ApiError::NotFound("customer not found".into())),
    }
}

/// `POST /admin/tokens` — mint a JWT for a given customer.
///
/// **Auth:** `AdminAuth`.
/// Requires the target customer to exist and not be suspended or deleted.
/// `expires_in_secs` is clamped to 1 minute – 30 days (default 24 hours).
/// Returns the signed token and its expiration timestamp.
///
/// Accepted `purpose` values are `"admin"` and `"impersonation"` (or omit the
/// field for the default `"admin"` metadata value).
///
/// Before signing the JWT, the handler always writes an `audit_log` row with
/// `action="impersonation_token_created"`, `target_tenant_id=customer_id`, and
/// metadata containing the clamped expiry plus the requested purpose. Audit
/// failures block token issuance.
pub async fn create_token(
    auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<CreateTokenRequest>,
) -> Result<Json<CreateTokenResponse>, ApiError> {
    let purpose = validated_purpose(req.purpose.as_deref())?;
    require_token_customer(&state, req.customer_id).await?;

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
    let audit_purpose = purpose.unwrap_or(PURPOSE_ADMIN);

    state
        .audit_log_writer
        .write(&AuditEntry {
            actor_id: auth.operator_id,
            action: ACTION_IMPERSONATION_TOKEN_CREATED.to_owned(),
            target_tenant_id: Some(req.customer_id),
            metadata: serde_json::json!({
            "duration_secs": duration,
            "purpose": audit_purpose,
            }),
        })
        .await
        .map_err(|err| {
            tracing::error!(
                error = %err,
                customer_id = %req.customer_id,
                purpose = audit_purpose,
                "failed to write admin token audit_log row"
            );
            ApiError::Internal("failed to persist admin token audit log".into())
        })?;

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

    Ok(Json(CreateTokenResponse {
        token,
        expires_at: expires_at.to_rfc3339(),
    }))
}

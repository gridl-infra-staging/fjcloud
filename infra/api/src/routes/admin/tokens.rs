//! `POST /admin/tokens` — mint a JWT for a given customer.
//!
//! Adds an optional `purpose` discriminator: when set to "impersonation",
//! the handler writes an `audit_log` row so there's a durable trail of
//! who impersonated whom and when. Default (purpose unset or "admin") is
//! treated as a routine token mint and writes nothing — keeps audit_log's
//! signal-to-noise ratio high for T1.4's per-customer audit view.
use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use jsonwebtoken::{EncodingKey, Header};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::{AdminAuth, Claims};
use crate::errors::ApiError;
use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::services::audit_log::{
    write_audit_log, ACTION_IMPERSONATION_TOKEN_CREATED, ADMIN_SENTINEL_ACTOR_ID,
};
use crate::state::AppState;

/// Discriminator value for the `purpose` field that triggers an audit row.
const PURPOSE_ADMIN: &str = "admin";
const PURPOSE_IMPERSONATION: &str = "impersonation";

#[derive(Debug, Deserialize)]
pub struct CreateTokenRequest {
    pub customer_id: Uuid,
    pub expires_in_secs: Option<u64>,
    /// Optional discriminator. Accepted values:
    /// * unset or `"admin"` — mint the token without an audit row
    /// * `"impersonation"` — mint the token and append an audit row
    ///
    /// Any other value is rejected with 400 so a caller typo cannot silently
    /// disable the audit trail for an intended impersonation token.
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
/// field for the default `"admin"` behavior).
///
/// When `purpose=="impersonation"` the handler writes an `audit_log` row with
/// `action="impersonation_token_created"`, `target_tenant_id=customer_id`, and
/// metadata `{ "duration_secs": <clamped expiry> }`. The audit write is
/// best-effort: failures are logged at `error!` level but do NOT block token
/// issuance — see the comment on `write_audit_log` for the rationale.
pub async fn create_token(
    _admin: AdminAuth,
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

    // Write the audit row only for impersonation tokens. Routine admin token
    // mints (the most common case — ops scripts, integration tests, etc.) are
    // intentionally excluded so audit_log stays signal-dense for T1.4.
    if purpose == Some(PURPOSE_IMPERSONATION) {
        // Best-effort: log on failure but do NOT propagate. A transient DB
        // hiccup must not block legitimate impersonation flows. Worst case is
        // we lose ONE audit row; tracing!error gives ops visibility.
        if let Err(err) = write_audit_log(
            &state.pool,
            ADMIN_SENTINEL_ACTOR_ID,
            ACTION_IMPERSONATION_TOKEN_CREATED,
            Some(req.customer_id),
            serde_json::json!({ "duration_secs": duration }),
        )
        .await
        {
            tracing::error!(
                error = %err,
                customer_id = %req.customer_id,
                "failed to write impersonation audit_log row"
            );
        }
    }

    Ok(Json(CreateTokenResponse {
        token,
        expires_at: expires_at.to_rfc3339(),
    }))
}

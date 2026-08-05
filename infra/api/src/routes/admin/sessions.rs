use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::admin::{resolve_admin_key, AdminAuth};
use crate::auth::AuthError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateAdminSessionRequest {
    pub max_age_seconds: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct CreateAdminSessionResponse {
    pub session_id: String,
}

pub async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateAdminSessionRequest>,
) -> Result<Json<CreateAdminSessionResponse>, AuthError> {
    if headers.contains_key("x-admin-session") {
        return Err(AuthError::InvalidAdminKey);
    }
    let admin_key = headers
        .get("x-admin-key")
        .ok_or(AuthError::MissingAdminKey)?
        .to_str()
        .map_err(|_| AuthError::InvalidAdminKey)?;
    let operator = resolve_admin_key(&state, admin_key).await?;
    let session_id = state
        .admin_session_repo
        .create(operator.operator_id, request.max_age_seconds)
        .await
        .map_err(|_| AuthError::Internal)?;

    Ok(Json(CreateAdminSessionResponse { session_id }))
}

#[derive(Debug, Serialize)]
pub struct CurrentAdminSessionResponse {
    pub operator_id: Uuid,
}

/// Non-destructive validation of the caller's durable session. The `AdminAuth`
/// extractor is the single validator — it already runs `validate_and_touch`, so
/// this handler only projects the non-secret operator identity. A raw
/// `x-admin-key` authenticates but carries no session, which is not a current
/// session and therefore fails closed.
pub async fn get_current(auth: AdminAuth) -> Result<Json<CurrentAdminSessionResponse>, AuthError> {
    auth.session_id.ok_or(AuthError::InvalidAdminKey)?;
    Ok(Json(CurrentAdminSessionResponse {
        operator_id: auth.operator_id,
    }))
}

pub async fn revoke_current(
    State(state): State<AppState>,
    auth: AdminAuth,
) -> Result<StatusCode, AuthError> {
    let session_id = auth.session_id.ok_or(AuthError::InvalidAdminKey)?;
    let revoked = state
        .admin_session_repo
        .revoke_current(session_id)
        .await
        .map_err(|_| AuthError::Internal)?;
    if !revoked {
        return Err(AuthError::InvalidAdminKey);
    }
    Ok(StatusCode::NO_CONTENT)
}

pub async fn revoke_all(
    State(state): State<AppState>,
    auth: AdminAuth,
) -> Result<StatusCode, AuthError> {
    auth.session_id.ok_or(AuthError::InvalidAdminKey)?;
    state
        .admin_session_repo
        .revoke_all(auth.operator_id)
        .await
        .map_err(|_| AuthError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

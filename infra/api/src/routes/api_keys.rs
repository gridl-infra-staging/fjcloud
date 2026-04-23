//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_2_utoipa_openapi_docs/fjcloud_dev/infra/api/src/routes/api_keys.rs.
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use utoipa::ToSchema;
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::scopes::validate_scopes;
use crate::state::AppState;
use crate::validation::{validate_length, MAX_API_KEY_NAME_LEN, MAX_SCOPE_ENTRIES};

#[derive(Debug, Deserialize, ToSchema)]
pub struct CreateApiKeyRequest {
    pub name: String,
    pub scopes: Vec<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct CreateApiKeyResponse {
    pub id: Uuid,
    pub name: String,
    pub key: String,
    pub key_prefix: String,
    pub scopes: Vec<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ApiKeyListItem {
    pub id: Uuid,
    pub name: String,
    pub key_prefix: String,
    pub scopes: Vec<String>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

fn generate_api_key() -> String {
    use rand::rngs::OsRng;
    use rand::Rng;
    let random_bytes: [u8; 16] = OsRng.gen();
    format!("gridl_live_{}", hex::encode(random_bytes))
}

fn hash_key(key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

// POST /api-keys
#[utoipa::path(
    post,
    path = "/api-keys",
    tag = "API Keys",
    request_body = CreateApiKeyRequest,
    responses(
        (status = 201, description = "API key created", body = CreateApiKeyResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Validation error", body = ErrorResponse),
    )
)]
/// `POST /api-keys` — generate a new API key for the authenticated customer.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates the name and scopes, generates a `gridl_live_`-prefixed random
/// key, stores its SHA-256 hash (never the plaintext), and returns the full
/// key **exactly once** in `CreateApiKeyResponse.key`. Subsequent listings
/// only expose the 16-character prefix.
pub async fn create_api_key(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<CreateApiKeyRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let name = req.name.trim();
    if name.is_empty() {
        return Err(ApiError::BadRequest("name must not be empty".into()));
    }
    validate_length("name", name, MAX_API_KEY_NAME_LEN)?;

    if req.scopes.is_empty() {
        return Err(ApiError::BadRequest("scopes must not be empty".into()));
    }
    if req.scopes.len() > MAX_SCOPE_ENTRIES {
        return Err(ApiError::BadRequest(format!(
            "scopes must have at most {MAX_SCOPE_ENTRIES} entries"
        )));
    }
    validate_scopes(&req.scopes)?;

    let key = generate_api_key();
    let key_hash = hash_key(&key);
    let key_prefix = &key[..16];

    let row = state
        .api_key_repo
        .create(tenant.customer_id, name, &key_hash, key_prefix, &req.scopes)
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(CreateApiKeyResponse {
            id: row.id,
            name: row.name,
            key,
            key_prefix: row.key_prefix,
            scopes: row.scopes,
            created_at: row.created_at,
        }),
    ))
}

// GET /api-keys
#[utoipa::path(
    get,
    path = "/api-keys",
    tag = "API Keys",
    responses(
        (status = 200, description = "API keys", body = [ApiKeyListItem]),
        (status = 401, description = "Authentication required", body = ErrorResponse),
    )
)]
/// `GET /api-keys` — list all API keys for the authenticated customer.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Returns key metadata (id, name, prefix, scopes, timestamps) but never
/// the full key — that is only available at creation time.
pub async fn list_api_keys(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let keys = state
        .api_key_repo
        .list_by_customer(tenant.customer_id)
        .await?;

    let response: Vec<ApiKeyListItem> = keys
        .into_iter()
        .map(|k| ApiKeyListItem {
            id: k.id,
            name: k.name,
            key_prefix: k.key_prefix,
            scopes: k.scopes,
            last_used_at: k.last_used_at,
            created_at: k.created_at,
        })
        .collect();

    Ok(Json(response))
}

// DELETE /api-keys/:id
#[utoipa::path(
    delete,
    path = "/api-keys/{key_id}",
    tag = "API Keys",
    params(
        ("key_id" = Uuid, Path, description = "API key identifier")
    ),
    responses(
        (status = 204, description = "API key revoked"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "API key not found", body = ErrorResponse),
    )
)]
/// `DELETE /api-keys/{key_id}` — revoke an API key.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Verifies the key belongs to the authenticated customer before revoking.
/// Returns 204 on success, 404 if the key does not exist or belongs to
/// another customer (no ownership leak).
pub async fn delete_api_key(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(key_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    // Verify the key belongs to this customer
    let key = state
        .api_key_repo
        .find_by_id(key_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("api key not found".into()))?;

    if key.customer_id != tenant.customer_id {
        return Err(ApiError::NotFound("api key not found".into()));
    }

    state.api_key_repo.revoke(key_id).await?;

    Ok(StatusCode::NO_CONTENT)
}

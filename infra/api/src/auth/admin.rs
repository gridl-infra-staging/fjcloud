use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::auth::error::AuthError;
use crate::state::AppState;

pub const ADMIN_CREDENTIAL_PREFIX_LENGTH: usize = 16;
const BOOTSTRAP_ADMIN_IDENTIFIER: &str = "bootstrap-admin-key";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminCredentialCandidate {
    pub operator_id: Uuid,
    pub identifier: String,
    pub credential_sha256: String,
}

#[async_trait]
pub trait AdminUserRepo: Send + Sync {
    async fn active_candidates_by_prefix(
        &self,
        credential_prefix: &str,
    ) -> anyhow::Result<Vec<AdminCredentialCandidate>>;
}

#[derive(Clone)]
pub struct PgAdminUserRepo {
    pool: sqlx::PgPool,
}

impl PgAdminUserRepo {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl AdminUserRepo for PgAdminUserRepo {
    async fn active_candidates_by_prefix(
        &self,
        credential_prefix: &str,
    ) -> anyhow::Result<Vec<AdminCredentialCandidate>> {
        let rows: Vec<(Uuid, String, String)> = sqlx::query_as(
            "SELECT id, identifier, credential_sha256 \
             FROM admin_users \
             WHERE credential_prefix = $1 AND revoked_at IS NULL",
        )
        .bind(credential_prefix)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(
                |(operator_id, identifier, credential_sha256)| AdminCredentialCandidate {
                    operator_id,
                    identifier,
                    credential_sha256,
                },
            )
            .collect())
    }
}

fn credential_prefix(credential: &str) -> Option<&str> {
    credential.get(..ADMIN_CREDENTIAL_PREFIX_LENGTH)
}

fn credential_sha256_hex(credential: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(credential.as_bytes());
    hex::encode(hasher.finalize())
}

pub async fn bootstrap_admin_user_if_empty(
    pool: &sqlx::PgPool,
    admin_key: &str,
) -> anyhow::Result<bool> {
    let prefix = credential_prefix(admin_key).ok_or_else(|| {
        anyhow::anyhow!(
            "configured admin key must be at least {ADMIN_CREDENTIAL_PREFIX_LENGTH} characters"
        )
    })?;
    let credential_hash = credential_sha256_hex(admin_key);
    let inserted = sqlx::query(
        "INSERT INTO admin_users (identifier, credential_prefix, credential_sha256) \
         SELECT $1, $2, $3 \
         WHERE NOT EXISTS (SELECT 1 FROM admin_users) \
         ON CONFLICT DO NOTHING",
    )
    .bind(BOOTSTRAP_ADMIN_IDENTIFIER)
    .bind(prefix)
    .bind(credential_hash)
    .execute(pool)
    .await?
    .rows_affected();

    Ok(inserted == 1)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminAuth {
    pub operator_id: Uuid,
    pub identifier: String,
    pub session_id: Option<Uuid>,
}

pub async fn resolve_admin_key(state: &AppState, provided: &str) -> Result<AdminAuth, AuthError> {
    let credential_prefix = credential_prefix(provided).ok_or(AuthError::InvalidAdminKey)?;

    // Admin credentials are machine-generated high-entropy keys, so this
    // matches the API-key SHA-256 scheme; password.rs Argon2 is reserved
    // for low-entropy user-chosen passwords.
    let provided_hash = credential_sha256_hex(provided);
    let candidates = state
        .admin_user_repo
        .active_candidates_by_prefix(credential_prefix)
        .await
        .map_err(|_| AuthError::Internal)?;
    let candidate = candidates
        .into_iter()
        .find(|candidate| {
            provided_hash
                .as_bytes()
                .ct_eq(candidate.credential_sha256.as_bytes())
                .into()
        })
        .ok_or(AuthError::InvalidAdminKey)?;

    Ok(AdminAuth {
        operator_id: candidate.operator_id,
        identifier: candidate.identifier,
        session_id: None,
    })
}

#[async_trait]
impl FromRequestParts<AppState> for AdminAuth {
    type Rejection = AuthError;

    /// Resolves `x-admin-key` to an active persisted operator.
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let admin_key = parts.headers.get("x-admin-key");
        let admin_session = parts.headers.get("x-admin-session");
        match (admin_key, admin_session) {
            (Some(_), Some(_)) => Err(AuthError::InvalidAdminKey),
            (Some(admin_key), None) => {
                let provided = admin_key.to_str().map_err(|_| AuthError::InvalidAdminKey)?;
                resolve_admin_key(state, provided).await
            }
            (None, Some(admin_session)) => {
                let token = admin_session
                    .to_str()
                    .map_err(|_| AuthError::InvalidAdminKey)?;
                let session = state
                    .admin_session_repo
                    .validate_and_touch(token)
                    .await
                    .map_err(|_| AuthError::Internal)?
                    .ok_or(AuthError::InvalidAdminKey)?;
                Ok(AdminAuth {
                    operator_id: session.operator_id,
                    identifier: session.identifier,
                    session_id: Some(session.session_id),
                })
            }
            (None, None) => Err(AuthError::MissingAdminKey),
        }
    }
}

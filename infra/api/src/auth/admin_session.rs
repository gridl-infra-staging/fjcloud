use async_trait::async_trait;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

pub const ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS: u64 = 24 * 60 * 60;
pub const ADMIN_SESSION_INACTIVITY_TIMEOUT_SECONDS: i64 = 60 * 60;
const ADMIN_SESSION_SECRET_BYTES: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedAdminSession {
    pub session_id: Uuid,
    pub operator_id: Uuid,
    pub identifier: String,
}

#[async_trait]
pub trait AdminSessionRepo: Send + Sync {
    async fn create(
        &self,
        operator_id: Uuid,
        requested_lifetime_seconds: Option<u64>,
    ) -> anyhow::Result<String>;

    async fn validate_and_touch(
        &self,
        token: &str,
    ) -> anyhow::Result<Option<ValidatedAdminSession>>;

    async fn revoke_current(&self, session_id: Uuid) -> anyhow::Result<bool>;

    async fn revoke_all(&self, operator_id: Uuid) -> anyhow::Result<u64>;
}

#[derive(Clone)]
pub struct PgAdminSessionRepo {
    pool: sqlx::PgPool,
}

impl PgAdminSessionRepo {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

fn secret_sha256_hex(secret: &[u8]) -> String {
    hex::encode(Sha256::digest(secret))
}

fn parse_token(token: &str) -> Option<(Uuid, Vec<u8>)> {
    let (session_id, encoded_secret) = token.split_once('.')?;
    if encoded_secret.contains('.') {
        return None;
    }

    let session_id = Uuid::parse_str(session_id).ok()?;
    let secret = URL_SAFE_NO_PAD.decode(encoded_secret).ok()?;
    (secret.len() == ADMIN_SESSION_SECRET_BYTES).then_some((session_id, secret))
}

#[async_trait]
impl AdminSessionRepo for PgAdminSessionRepo {
    async fn create(
        &self,
        operator_id: Uuid,
        requested_lifetime_seconds: Option<u64>,
    ) -> anyhow::Result<String> {
        let lifetime_seconds = requested_lifetime_seconds
            .unwrap_or(ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS)
            .min(ADMIN_SESSION_ABSOLUTE_LIFETIME_SECONDS);
        let lifetime_seconds = i64::try_from(lifetime_seconds)?;

        let mut secret = [0_u8; ADMIN_SESSION_SECRET_BYTES];
        OsRng.fill_bytes(&mut secret);
        let secret_sha256 = secret_sha256_hex(&secret);
        let session_id: Uuid = sqlx::query_scalar(
            "INSERT INTO admin_sessions (admin_user_id, secret_sha256, expires_at) \
             VALUES ($1, $2, NOW() + ($3 * INTERVAL '1 second')) \
             RETURNING id",
        )
        .bind(operator_id)
        .bind(secret_sha256)
        .bind(lifetime_seconds)
        .fetch_one(&self.pool)
        .await?;

        Ok(format!("{session_id}.{}", URL_SAFE_NO_PAD.encode(secret)))
    }

    async fn validate_and_touch(
        &self,
        token: &str,
    ) -> anyhow::Result<Option<ValidatedAdminSession>> {
        let Some((session_id, secret)) = parse_token(token) else {
            return Ok(None);
        };
        let Some(expected_hash) = sqlx::query_scalar::<_, String>(
            "SELECT secret_sha256 FROM admin_sessions WHERE id = $1",
        )
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        let provided_hash = secret_sha256_hex(&secret);
        if !bool::from(provided_hash.as_bytes().ct_eq(expected_hash.as_bytes())) {
            return Ok(None);
        }

        let identity: Option<(Uuid, String)> = sqlx::query_as(
            "UPDATE admin_sessions AS session \
             SET last_activity_at = NOW() \
             FROM admin_users AS admin_user \
             WHERE session.id = $1 \
               AND session.admin_user_id = admin_user.id \
               AND session.revoked_at IS NULL \
               AND admin_user.revoked_at IS NULL \
               AND session.expires_at > NOW() \
               AND session.last_activity_at >= \
                   NOW() - ($2 * INTERVAL '1 second') \
             RETURNING admin_user.id, admin_user.identifier",
        )
        .bind(session_id)
        .bind(ADMIN_SESSION_INACTIVITY_TIMEOUT_SECONDS)
        .fetch_optional(&self.pool)
        .await?;

        Ok(
            identity.map(|(operator_id, identifier)| ValidatedAdminSession {
                session_id,
                operator_id,
                identifier,
            }),
        )
    }

    async fn revoke_current(&self, session_id: Uuid) -> anyhow::Result<bool> {
        let rows_affected = sqlx::query(
            "UPDATE admin_sessions SET revoked_at = NOW() \
             WHERE id = $1 AND revoked_at IS NULL",
        )
        .bind(session_id)
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(rows_affected == 1)
    }

    async fn revoke_all(&self, operator_id: Uuid) -> anyhow::Result<u64> {
        Ok(sqlx::query(
            "UPDATE admin_sessions SET revoked_at = NOW() \
             WHERE admin_user_id = $1 AND revoked_at IS NULL",
        )
        .bind(operator_id)
        .execute(&self.pool)
        .await?
        .rows_affected())
    }
}

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

const STAGE1_API_KEY_COMPAT_DECISION_TOKEN: &str = "HARD_CUT";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage1ApiKeyCompatDecision {
    HardCutOk,
    KeepLegacyAccept,
}

impl Stage1ApiKeyCompatDecision {
    pub fn from_token(token: &str) -> Self {
        match token {
            "HARD_CUT" | "HARD_CUT_OK" => Self::HardCutOk,
            "KEEP_LEGACY_ACCEPT" => Self::KeepLegacyAccept,
            _ => Self::HardCutOk,
        }
    }

    pub fn accepts_legacy_fj_live_keys(self) -> bool {
        matches!(self, Self::KeepLegacyAccept)
    }
}

#[derive(Debug, Clone)]
pub struct ApiKeyAuth {
    pub customer_id: Uuid,
    pub key_id: Uuid,
    pub scopes: Vec<String>,
}

impl ApiKeyAuth {
    pub fn active_stage1_compat_decision() -> Stage1ApiKeyCompatDecision {
        Stage1ApiKeyCompatDecision::from_token(STAGE1_API_KEY_COMPAT_DECISION_TOKEN)
    }

    fn accepts_management_prefix(key: &str, stage1_decision: Stage1ApiKeyCompatDecision) -> bool {
        // Cloud-management routes always accept fjc_live_*. The legacy fj_live_*
        // branch is only enabled under KEEP_LEGACY_ACCEPT, which is derived from
        // the Stage 1 live-usage decision artifact:
        // docs/research/20260524T174343Z_fj_live_prod_usage.md
        key.starts_with("fjc_live_")
            || (stage1_decision.accepts_legacy_fj_live_keys() && key.starts_with("fj_live_"))
    }

    /// Shared extractor implementation used by `FromRequestParts` and tests.
    /// Runtime code should call `from_request_parts` (which injects the active
    /// Stage 1 compatibility decision); tests can pass an explicit decision to
    /// exercise both outcomes: `fjc_live_*` only (`HARD_CUT`) or dual-accept
    /// (`fjc_live_*` plus legacy `fj_live_*`) when `KEEP_LEGACY_ACCEPT` is active.
    pub async fn from_request_parts_with_stage1_decision(
        parts: &mut Parts,
        state: &AppState,
        stage1_decision: Stage1ApiKeyCompatDecision,
    ) -> Result<Self, AuthError> {
        let auth_header = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::MissingToken)?;

        let key = auth_header
            .strip_prefix("Bearer ")
            .ok_or(AuthError::MissingToken)?;

        if !Self::accepts_management_prefix(key, stage1_decision) || key.len() < 16 {
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

    /// Authenticates via `Authorization: Bearer <key>`. Accepts `fjc_live_*`
    /// keys always, and accepts legacy `fj_live_*` keys only when the Stage 1
    /// compatibility decision is `KEEP_LEGACY_ACCEPT`. Performs a prefix-based
    /// DB lookup (first 16 chars),
    /// then SHA-256 hash comparison using constant-time equality. Checks customer
    /// status (Suspended → 403, missing → 401) and fires a non-blocking `last_used`
    /// timestamp update via `tokio::spawn`.
    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Self::from_request_parts_with_stage1_decision(
            parts,
            state,
            Self::active_stage1_compat_decision(),
        )
        .await
    }
}

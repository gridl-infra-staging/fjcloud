use async_trait::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use axum::http::{Extensions, HeaderMap};
use chrono::Utc;
use ipnet::IpNet;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::auth::error::AuthError;
use crate::errors::ApiError;
use crate::models::api_key::ApiKeyRow;
use crate::models::customer::{customer_auth_state, CustomerAuthState};
use crate::router::middleware::extract_client_ip_from_parts;
use crate::state::AppState;

/// Returns `true` iff the request's client IP satisfies the key's
/// `restrict_sources` allowlist. Fails closed: only a transport-verified socket
/// peer can satisfy the allowlist, and any single unparseable stored CIDR makes
/// the whole allowlist untrustworthy and denies the request. Callers must only
/// invoke this when `restrict_sources` is non-empty.
fn source_ip_allowed(
    headers: &HeaderMap,
    extensions: &Extensions,
    restrict_sources: &[String],
) -> bool {
    let Some(client_ip) = extract_client_ip_from_parts(headers, extensions).trusted_socket_ip()
    else {
        return false;
    };

    let mut matched = false;
    for source in restrict_sources {
        match source.parse::<IpNet>() {
            Ok(net) => {
                if net.contains(&client_ip) {
                    matched = true;
                }
            }
            // A malformed CIDR means the stored allowlist is corrupt; deny
            // rather than partially honor an untrustworthy configuration.
            Err(_) => return false,
        }
    }
    matched
}

fn api_key_rate_limit_bucket(headers: &HeaderMap, extensions: &Extensions, key_id: Uuid) -> String {
    let ip_key = extract_client_ip_from_parts(headers, extensions).rate_limit_key();
    format!("api_key:{key_id}:ip:{ip_key}")
}

fn enforce_api_key_hourly_limit(
    parts: &Parts,
    state: &AppState,
    key_row: &ApiKeyRow,
) -> Result<(), AuthError> {
    let Some(raw_limit) = key_row.max_queries_per_ip_per_hour else {
        return Ok(());
    };
    if raw_limit <= 0 {
        // Corrupt persisted managed-key limits fail closed with the same shape
        // as unknown keys rather than becoming unlimited or a one-request budget.
        return Err(AuthError::InvalidToken);
    }
    let limit = raw_limit as u32;

    let bucket = api_key_rate_limit_bucket(&parts.headers, &parts.extensions, key_row.id);
    match state.api_key_rate_limiter.check_with_limit(&bucket, limit) {
        Ok(None) => Ok(()),
        Ok(Some(retry_after_seconds)) => Err(AuthError::RateLimited {
            retry_after_seconds,
        }),
        Err(_) => Err(AuthError::InvalidToken),
    }
}

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
    indexes: Vec<String>,
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

        if key_row
            .expires_at
            .is_some_and(|expires_at| expires_at <= Utc::now())
        {
            // Expired keys match unknown keys so auth responses do not reveal credential existence.
            return Err(AuthError::InvalidToken);
        }

        // Enforce `restrict_sources`: when the key pins an allowlist of source
        // CIDRs, the request's client IP must fall inside one of them. The IP is
        // resolved through the single middleware owner so there is exactly one
        // trust policy. Only a transport-verified socket peer may satisfy the
        // allowlist — header-derived or unresolved IPs, and any malformed stored
        // CIDR, fail closed. We return the same `InvalidToken` shape used for
        // unknown and expired keys so a source-disallowed key stays
        // indistinguishable from one that never existed.
        if !key_row.restrict_sources.is_empty()
            && !source_ip_allowed(&parts.headers, &parts.extensions, &key_row.restrict_sources)
        {
            return Err(AuthError::InvalidToken);
        }

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

        // Managed-key query caps reuse the shared sliding-window limiter. This
        // is stricter near wall-clock boundaries than fixed UTC-hour buckets.
        // The counter is intentionally in-process: restarts reset it and each
        // API instance grants its own budget. That is the accepted local posture
        // here, not distributed production enforcement.
        enforce_api_key_hourly_limit(parts, state, &key_row)?;

        let repo = state.api_key_repo.clone();
        let key_id = key_row.id;
        tokio::spawn(async move {
            let _ = repo.update_last_used(key_id).await;
        });

        Ok(ApiKeyAuth {
            customer_id: key_row.customer_id,
            key_id: key_row.id,
            scopes: key_row.scopes,
            indexes: key_row.indexes,
        })
    }

    pub fn require_scope(&self, scope: &str) -> Result<(), ApiError> {
        if self.scopes.iter().any(|s| s == scope) {
            Ok(())
        } else {
            Err(ApiError::Forbidden("insufficient scope".into()))
        }
    }

    /// An empty allowlist is unrestricted. Every future index-bearing route
    /// authenticated by `ApiKeyAuth` must call this method before index access.
    pub fn require_index(&self, index: &str) -> Result<(), ApiError> {
        if self.indexes.is_empty() || self.indexes.iter().any(|allowed| allowed == index) {
            Ok(())
        } else {
            Err(ApiError::NotFound("index not found".into()))
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
    /// status (Suspended → 403, missing → 401) and key expiry, then fires a
    /// non-blocking `last_used` timestamp update via `tokio::spawn`.
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

//! Destination eligibility (`POST /migration/algolia/destination-eligibility`).
use std::fmt;

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Duration, Utc};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    validate_algolia_create_provider, AlgoliaImportDestinationKind,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{AlgoliaImportJobRepo, PgAlgoliaImportJobRepo};
use crate::state::AppState;

use super::{
    map_eligibility_snapshot_error, migration_error, migration_unavailable,
    sign_destination_eligibility, verify_provider_envelope, AlgoliaEligibilityPhase,
    DestinationEligibilityClaims, DESTINATION_ELIGIBILITY_DOMAIN,
    DESTINATION_ELIGIBILITY_TOKEN_TTL_SECONDS,
};

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AlgoliaDestinationEligibilityRequest {
    phase: AlgoliaEligibilityPhase,
    mode: AlgoliaImportDestinationKind,
    target: AlgoliaDestinationEligibilityTargetRequest,
    /// Provider-phase envelope replayed by the `target` phase. Absent in the
    /// `provider` phase, which mints (never consumes) an eligibility envelope.
    #[serde(default)]
    eligibility_token: Option<String>,
}

#[derive(Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct AlgoliaDestinationEligibilityTargetRequest {
    pub(super) region: String,
    pub(super) name: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaDestinationEligibilityResponse {
    phase: AlgoliaEligibilityPhase,
    mode: AlgoliaImportDestinationKind,
    provider: String,
    target: AlgoliaDestinationEligibilityTargetResponse,
    eligibility_token: String,
    expires_at: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
struct AlgoliaDestinationEligibilityTargetResponse {
    kind: AlgoliaImportDestinationKind,
    region: String,
    name: String,
}

impl fmt::Debug for AlgoliaDestinationEligibilityRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaDestinationEligibilityRequest")
            .field("phase", &self.phase)
            .field("mode", &self.mode)
            .field("target", &self.target)
            .field(
                "eligibility_token",
                &self.eligibility_token.as_ref().map(|_| "[REDACTED]"),
            )
            .finish()
    }
}

impl fmt::Debug for AlgoliaDestinationEligibilityTargetRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AlgoliaDestinationEligibilityTargetRequest")
            .field("region", &self.region)
            .field("name", &self.name)
            .finish()
    }
}

#[utoipa::path(
    post,
    path = "/migration/algolia/destination-eligibility",
    tag = "Migration",
    request_body = AlgoliaDestinationEligibilityRequest,
    responses(
        (status = 200, description = "Signed destination-eligibility envelope for the requested phase", body = AlgoliaDestinationEligibilityResponse),
        (status = 400, description = "Invalid, tampered, expired, or wrong-phase eligibility envelope, or unsupported destination", body = crate::errors::MigrationErrorResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Eligibility envelope minted for another customer", body = crate::errors::MigrationErrorResponse),
        (status = 503, description = "Migration admission disabled or backpressured", body = crate::errors::MigrationErrorResponse),
    )
)]
pub async fn check_algolia_destination_eligibility(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(request): Json<AlgoliaDestinationEligibilityRequest>,
) -> Result<Json<AlgoliaDestinationEligibilityResponse>, ApiError> {
    if !state.algolia_migration_enabled {
        return Err(migration_unavailable());
    }
    match request.phase {
        AlgoliaEligibilityPhase::Provider => provider_eligibility_phase(&state, &auth, request),
        AlgoliaEligibilityPhase::Target => target_eligibility_phase(&state, &auth, request).await,
    }
}

/// Credential-free `provider` phase: validate coarse create-destination
/// eligibility (AWS-backed region) and mint a short-lived provider envelope.
/// It never consumes an envelope — replay is the `target` phase's job.
fn provider_eligibility_phase(
    state: &AppState,
    auth: &AuthenticatedTenant,
    request: AlgoliaDestinationEligibilityRequest,
) -> Result<Json<AlgoliaDestinationEligibilityResponse>, ApiError> {
    if request.eligibility_token.is_some() {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "unexpected_eligibility_token",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }
    if request.mode != AlgoliaImportDestinationKind::Create {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "migration_provider_unsupported",
            AlgoliaImportErrorCode::MigrationProviderUnsupported,
        ));
    }
    validate_algolia_create_provider(&state.region_config, &request.target.region).map_err(
        |code| {
            migration_error(
                StatusCode::BAD_REQUEST,
                "migration_provider_unsupported",
                code,
            )
        },
    )?;

    issue_eligibility(
        state,
        auth.customer_id,
        EligibilityGrant {
            phase: AlgoliaEligibilityPhase::Provider,
            mode: AlgoliaImportDestinationKind::Create,
            region: request.target.region,
            name: request.target.name,
            lifecycle_generation: None,
            routing_identity: None,
        },
    )
}

/// Credential-free `target` phase: finalize the concrete destination and mint
/// the binding the create step will later revalidate. Create replays and
/// verifies the provider envelope (a locally checkable failure); replace
/// authenticates the owned target and pins its current routing generation
/// against a repository snapshot before any source access or mutation.
async fn target_eligibility_phase(
    state: &AppState,
    auth: &AuthenticatedTenant,
    request: AlgoliaDestinationEligibilityRequest,
) -> Result<Json<AlgoliaDestinationEligibilityResponse>, ApiError> {
    match request.mode {
        AlgoliaImportDestinationKind::Create => {
            let token = request.eligibility_token.as_deref().ok_or_else(|| {
                migration_error(
                    StatusCode::BAD_REQUEST,
                    "eligibility_token_required",
                    AlgoliaImportErrorCode::DestinationChanged,
                )
            })?;
            verify_provider_envelope(
                state,
                auth,
                token,
                AlgoliaImportDestinationKind::Create,
                &request.target,
            )?;
            issue_eligibility(
                state,
                auth.customer_id,
                EligibilityGrant {
                    phase: AlgoliaEligibilityPhase::Target,
                    mode: AlgoliaImportDestinationKind::Create,
                    region: request.target.region,
                    name: request.target.name,
                    lifecycle_generation: None,
                    routing_identity: None,
                },
            )
        }
        AlgoliaImportDestinationKind::Replace => {
            // Replace targets are authenticated directly against the owned index,
            // so there is no credential-free provider pre-phase to replay.
            if request.eligibility_token.is_some() {
                return Err(migration_error(
                    StatusCode::BAD_REQUEST,
                    "unexpected_eligibility_token",
                    AlgoliaImportErrorCode::DestinationChanged,
                ));
            }
            let snapshot = PgAlgoliaImportJobRepo::new(state.pool.clone())
                .snapshot_replace_target_eligibility(auth.customer_id, &request.target.name)
                .await
                .map_err(map_eligibility_snapshot_error)?;
            if snapshot.region != request.target.region {
                return Err(migration_error(
                    StatusCode::BAD_REQUEST,
                    "destination_changed",
                    AlgoliaImportErrorCode::DestinationChanged,
                ));
            }
            issue_eligibility(
                state,
                auth.customer_id,
                EligibilityGrant {
                    phase: AlgoliaEligibilityPhase::Target,
                    mode: AlgoliaImportDestinationKind::Replace,
                    region: snapshot.region,
                    name: request.target.name,
                    lifecycle_generation: Some(snapshot.lifecycle_generation),
                    routing_identity: Some(snapshot.routing_identity),
                },
            )
        }
    }
}

/// Trusted inputs for minting one eligibility envelope + response.
struct EligibilityGrant {
    phase: AlgoliaEligibilityPhase,
    mode: AlgoliaImportDestinationKind,
    region: String,
    name: String,
    lifecycle_generation: Option<i64>,
    routing_identity: Option<String>,
}

fn issue_eligibility(
    state: &AppState,
    customer_id: uuid::Uuid,
    grant: EligibilityGrant,
) -> Result<Json<AlgoliaDestinationEligibilityResponse>, ApiError> {
    let expires_at = Utc::now() + Duration::seconds(DESTINATION_ELIGIBILITY_TOKEN_TTL_SECONDS);
    let claims = DestinationEligibilityClaims {
        domain: DESTINATION_ELIGIBILITY_DOMAIN,
        version: 1,
        phase: &grant.phase,
        mode: grant.mode,
        customer_id: customer_id.to_string(),
        region: &grant.region,
        name: &grant.name,
        lifecycle_generation: grant.lifecycle_generation,
        routing_identity: grant.routing_identity.as_deref(),
        exp: expires_at.timestamp(),
    };
    let eligibility_token = sign_destination_eligibility(state, &claims)?;
    Ok(Json(AlgoliaDestinationEligibilityResponse {
        phase: grant.phase,
        mode: grant.mode,
        provider: "aws".to_string(),
        target: AlgoliaDestinationEligibilityTargetResponse {
            kind: grant.mode,
            region: grant.region,
            name: grant.name,
        },
        eligibility_token,
        expires_at: expires_at.to_rfc3339(),
    }))
}

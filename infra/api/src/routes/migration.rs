use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use utoipa::ToSchema;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::algolia_import_job::{
    AlgoliaImportDestinationKind, AlgoliaImportTargetBinding, SourceImportProvider,
};
use crate::models::AlgoliaImportErrorCode;
use crate::repos::{
    AlgoliaImportJobAdmissionError, AlgoliaImportJobListCursor, DestinationEligibilityError,
};
use crate::state::AppState;

type HmacSha256 = Hmac<Sha256>;

pub const ALGOLIA_MIGRATION_UNAVAILABLE_REASON: &str = "temporarily_unavailable";
pub const ALGOLIA_MIGRATION_UNAVAILABLE_MESSAGE: &str =
    "Algolia migration is temporarily unavailable while we replace the importer.";
pub const ALGOLIA_ACL_GUIDANCE: &str = "Algolia discovery requires listIndexes. Migration requires settings and browse; seeUnretrievableAttributes is optional.";
const DESTINATION_ELIGIBILITY_TOKEN_TTL_SECONDS: i64 = 300;
const MIGRATION_RETRY_AFTER_SECONDS: u64 = 30;
const DESTINATION_ELIGIBILITY_DOMAIN: &str = "fjcloud.algolia_migration.destination_eligibility.v1";
const LIST_CURSOR_DOMAIN: &str = "fjcloud.algolia_migration.list_cursor.v1";
const LIST_CURSOR_TTL_SECONDS: i64 = 900;

mod capabilities;
mod eligibility;
mod jobs;
mod retained_jobs;
mod source;

use source::map_algolia_source_error;

// Re-export handlers, request DTOs, and `#[utoipa::path]`-generated path items
// so existing route assembly and test-only OpenAPI generation resolve unchanged
// after extracting the migration route surface.
pub use capabilities::AlgoliaMigrationCapabilities;
pub use eligibility::{
    __path_check_destination_eligibility, check_destination_eligibility,
    AlgoliaDestinationEligibilityRequest, AlgoliaDestinationEligibilityResponse,
};
pub use jobs::{
    __path_cancel_import_job, __path_create_import_job, __path_resume_import_job,
    cancel_import_job, create_import_job, resume_import_job, CancelAlgoliaImportJobRequest,
    CreateAlgoliaImportJobRequest, ResumeAlgoliaImportJobRequest,
};
pub use retained_jobs::{
    __path_get_import_job, __path_list_import_jobs, get_import_job, list_import_jobs,
    ListAlgoliaImportJobsQuery, PublicAlgoliaImportJob, PublicAlgoliaImportJobPage,
};
pub use source::{__path_list_source_indexes, list_source_indexes, ListAlgoliaIndexesRequest};

pub use check_destination_eligibility as check_algolia_destination_eligibility;
pub use list_source_indexes as list_algolia_indexes;
pub use {
    __path_cancel_import_job as __path_cancel_algolia_import_job,
    __path_check_destination_eligibility as __path_check_algolia_destination_eligibility,
    __path_create_import_job as __path_create_algolia_import_job,
    __path_get_import_job as __path_get_algolia_import_job,
    __path_list_import_jobs as __path_list_algolia_import_jobs,
    __path_list_source_indexes as __path_list_algolia_indexes,
    __path_resume_import_job as __path_resume_algolia_import_job,
};
pub use {
    cancel_import_job as cancel_algolia_import_job, create_import_job as create_algolia_import_job,
    get_import_job as get_algolia_import_job, list_import_jobs as list_algolia_import_jobs,
    resume_import_job as resume_algolia_import_job,
};

#[derive(Deserialize)]
pub struct MigrationSourcePath {
    #[serde(default)]
    pub(super) source_provider: Option<String>,
}

#[derive(Deserialize)]
pub struct MigrationJobPath {
    #[serde(default)]
    pub(super) source_provider: Option<String>,
    pub(super) id: uuid::Uuid,
}

fn validate_source_provider(
    source_provider: Option<&str>,
) -> Result<SourceImportProvider, ApiError> {
    // Legacy Algolia routes omit the source-provider segment, and persisted
    // Algolia rows keep decoding through the default/backfilled durable value.
    let provider = SourceImportProvider::parse(
        source_provider.unwrap_or_else(|| SourceImportProvider::Algolia.as_str()),
    )
    .map_err(|_| {
        let error_code = AlgoliaImportErrorCode::SourceProviderUnsupported;
        migration_error(StatusCode::BAD_REQUEST, error_code.as_str(), error_code)
    })?;

    // The adapter refusal must stay ahead of credential handling, repository
    // access, and migration-engine calls for recognized but unimplemented
    // source identities.
    if !provider.has_adapter() {
        let error_code = AlgoliaImportErrorCode::SourceProviderUnsupported;
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            error_code.as_str(),
            error_code,
        ));
    }

    Ok(provider)
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, ToSchema)]
#[serde(rename_all = "snake_case")]
enum AlgoliaEligibilityPhase {
    Provider,
    Target,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DestinationEligibilityClaims<'a> {
    domain: &'static str,
    version: u8,
    phase: &'a AlgoliaEligibilityPhase,
    mode: AlgoliaImportDestinationKind,
    customer_id: String,
    region: &'a str,
    name: &'a str,
    /// Present only on `target`-phase replace envelopes: the customer lifecycle
    /// generation the routing identity was pinned against.
    #[serde(skip_serializing_if = "Option::is_none")]
    lifecycle_generation: Option<i64>,
    /// Present only on `target`-phase replace envelopes: the authoritative
    /// physical routing identity of the owned target.
    #[serde(skip_serializing_if = "Option::is_none")]
    routing_identity: Option<&'a str>,
    exp: i64,
}

/// Owned, deserializable view of a signed eligibility envelope, used by the
/// `target` phase to re-authenticate a replayed `provider` envelope.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedEligibilityClaims {
    domain: String,
    version: u8,
    phase: AlgoliaEligibilityPhase,
    mode: AlgoliaImportDestinationKind,
    customer_id: String,
    region: String,
    name: String,
    lifecycle_generation: Option<i64>,
    routing_identity: Option<String>,
    exp: i64,
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AlgoliaMigrationAvailabilityReason {
    TemporarilyUnavailable,
}

#[derive(Debug, Serialize, ToSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AlgoliaMigrationAvailabilityResponse {
    pub available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<AlgoliaMigrationAvailabilityReason>,
    pub message: String,
    pub capabilities: AlgoliaMigrationCapabilities,
}

impl AlgoliaMigrationAvailabilityResponse {
    fn unavailable() -> Self {
        Self {
            available: false,
            reason: Some(AlgoliaMigrationAvailabilityReason::TemporarilyUnavailable),
            message: ALGOLIA_MIGRATION_UNAVAILABLE_MESSAGE.to_string(),
            capabilities: capabilities::migration_capabilities(
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    resume: false,
                    replace: false,
                },
                AlgoliaMigrationCapabilities {
                    cancel: false,
                    resume: false,
                    replace: false,
                },
            ),
        }
    }
}

fn compute_availability(
    flag_enabled: bool,
    route_mounted: AlgoliaMigrationCapabilities,
    engine_supported: AlgoliaMigrationCapabilities,
) -> AlgoliaMigrationAvailabilityResponse {
    let mut caps = capabilities::migration_capabilities(route_mounted, engine_supported);
    // Resume is never customer-advertised independent of route or engine input.
    caps.resume = false;

    if flag_enabled && caps.cancel {
        return AlgoliaMigrationAvailabilityResponse {
            available: true,
            reason: None,
            message: "Algolia migration is available.".to_string(),
            capabilities: caps,
        };
    }

    AlgoliaMigrationAvailabilityResponse::unavailable()
}

pub(super) fn current_migration_availability(
    state: &AppState,
) -> AlgoliaMigrationAvailabilityResponse {
    compute_availability(
        state.algolia_migration_enabled,
        capabilities::route_mounted_migration_capabilities(),
        capabilities::engine_supported_migration_capabilities(),
    )
}

pub(super) fn migration_available(state: &AppState) -> bool {
    current_migration_availability(state).available
}

#[utoipa::path(
    get,
    path = "/migration/algolia/availability",
    operation_id = "algolia_availability",
    tag = "Migration",
    responses(
        (status = 200, description = "Algolia migration availability", body = AlgoliaMigrationAvailabilityResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn migration_availability(
    _auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(path): Path<MigrationSourcePath>,
) -> Result<Json<AlgoliaMigrationAvailabilityResponse>, ApiError> {
    validate_source_provider(path.source_provider.as_deref())?;
    Ok(Json(current_migration_availability(&state)))
}

pub use __path_migration_availability as __path_algolia_availability;
pub use migration_availability as algolia_availability;

fn open_signed_eligibility_claims(
    state: &AppState,
    token: &str,
) -> Result<SignedEligibilityClaims, ApiError> {
    let (payload_b64, signature_b64) = token
        .split_once('.')
        .ok_or_else(invalid_eligibility_token)?;
    let payload = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|_| invalid_eligibility_token())?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature_b64)
        .map_err(|_| invalid_eligibility_token())?;
    if !verify_migration_hmac(state, DESTINATION_ELIGIBILITY_DOMAIN, &payload, &signature) {
        return Err(invalid_eligibility_token());
    }

    serde_json::from_slice(&payload).map_err(|_| invalid_eligibility_token())
}

fn validate_eligibility_claims(
    claims: &SignedEligibilityClaims,
    now_ts: i64,
    auth_customer_id: &str,
    expected_phase: AlgoliaEligibilityPhase,
) -> Result<(), ApiError> {
    if claims.domain != DESTINATION_ELIGIBILITY_DOMAIN || claims.version != 1 {
        return Err(invalid_eligibility_token());
    }
    if now_ts >= claims.exp {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "eligibility_token_expired",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }
    if claims.phase != expected_phase {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "eligibility_phase_mismatch",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }
    if claims.customer_id != auth_customer_id {
        return Err(migration_error(
            StatusCode::FORBIDDEN,
            "eligibility_customer_mismatch",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }

    Ok(())
}

/// Verify a replayed provider envelope. Every failure here is locally decidable
/// and must precede any repository or source access.
fn verify_provider_envelope(
    state: &AppState,
    auth: &AuthenticatedTenant,
    token: &str,
    expected_mode: AlgoliaImportDestinationKind,
    expected_target: &eligibility::AlgoliaDestinationEligibilityTargetRequest,
) -> Result<(), ApiError> {
    let claims = open_signed_eligibility_claims(state, token)?;
    validate_provider_claims(
        &claims,
        Utc::now().timestamp(),
        &auth.customer_id.to_string(),
        expected_mode,
        expected_target,
    )
}

fn verify_target_envelope(
    state: &AppState,
    auth: &AuthenticatedTenant,
    request: &jobs::CreateAlgoliaImportJobRequest,
) -> Result<AlgoliaImportTargetBinding, ApiError> {
    let claims = open_signed_eligibility_claims(state, &request.target.eligibility_token)?;
    validate_target_claims(
        &claims,
        Utc::now().timestamp(),
        &auth.customer_id.to_string(),
    )?;
    if claims.mode != request.mode {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "eligibility_mode_mismatch",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }
    match claims.mode {
        AlgoliaImportDestinationKind::Create => {
            if claims.lifecycle_generation.is_some() || claims.routing_identity.is_some() {
                return Err(invalid_eligibility_token());
            }
            Ok(AlgoliaImportTargetBinding::create(
                auth.customer_id,
                claims.name,
                claims.region,
            ))
        }
        AlgoliaImportDestinationKind::Replace => Ok(AlgoliaImportTargetBinding::replace(
            auth.customer_id,
            claims.name,
            claims.region,
            claims
                .lifecycle_generation
                .ok_or_else(invalid_eligibility_token)?,
            claims
                .routing_identity
                .ok_or_else(invalid_eligibility_token)?,
        )),
    }
}

fn validate_target_claims(
    claims: &SignedEligibilityClaims,
    now_ts: i64,
    auth_customer_id: &str,
) -> Result<(), ApiError> {
    validate_eligibility_claims(
        claims,
        now_ts,
        auth_customer_id,
        AlgoliaEligibilityPhase::Target,
    )
}

/// Pure, clock-injectable validation of a decoded and signature-verified
/// provider envelope against the current request. Separated from the signature
/// check so envelope expiry, phase, customer, and destination binding are
/// deterministically unit-testable.
fn validate_provider_claims(
    claims: &SignedEligibilityClaims,
    now_ts: i64,
    auth_customer_id: &str,
    expected_mode: AlgoliaImportDestinationKind,
    expected_target: &eligibility::AlgoliaDestinationEligibilityTargetRequest,
) -> Result<(), ApiError> {
    validate_eligibility_claims(
        claims,
        now_ts,
        auth_customer_id,
        AlgoliaEligibilityPhase::Provider,
    )?;
    if claims.mode != expected_mode || claims.region != expected_target.region {
        return Err(migration_error(
            StatusCode::BAD_REQUEST,
            "destination_changed",
            AlgoliaImportErrorCode::DestinationChanged,
        ));
    }
    Ok(())
}

fn invalid_eligibility_token() -> ApiError {
    migration_error(
        StatusCode::BAD_REQUEST,
        "invalid_eligibility_token",
        AlgoliaImportErrorCode::DestinationChanged,
    )
}

pub(super) fn job_not_found() -> ApiError {
    ApiError::NotFound("algolia_import_job_not_found".into())
}

/// Single mapping of the typed replace-eligibility snapshot refusal onto stable
/// migration codes and statuses.
fn map_eligibility_snapshot_error(error: DestinationEligibilityError) -> ApiError {
    match error {
        DestinationEligibilityError::TargetNotFound => migration_error(
            StatusCode::BAD_REQUEST,
            "destination_changed",
            AlgoliaImportErrorCode::DestinationChanged,
        ),
        DestinationEligibilityError::LifecycleUnavailable => migration_backpressure(),
        DestinationEligibilityError::Ineligible(code) => match code {
            AlgoliaImportErrorCode::BackendUnavailable => migration_backpressure(),
            AlgoliaImportErrorCode::DestinationConflict => {
                migration_code_error(StatusCode::CONFLICT, code)
            }
            other => migration_code_error(StatusCode::BAD_REQUEST, other),
        },
        DestinationEligibilityError::Internal(_) => {
            ApiError::Internal("eligibility snapshot failed".into())
        }
    }
}

fn map_create_admission_error(
    error: crate::routes::indexes::lifecycle::AlgoliaCreateAdmissionError,
) -> ApiError {
    match error {
        crate::routes::indexes::lifecycle::AlgoliaCreateAdmissionError::Route(error) => error,
        crate::routes::indexes::lifecycle::AlgoliaCreateAdmissionError::Job(error) => {
            map_job_admission_error(error)
        }
    }
}

fn map_job_admission_error(error: AlgoliaImportJobAdmissionError) -> ApiError {
    match error {
        AlgoliaImportJobAdmissionError::Refused(code) => match code {
            AlgoliaImportErrorCode::BackendUnavailable => migration_backpressure(),
            AlgoliaImportErrorCode::DestinationConflict => {
                migration_code_error(StatusCode::CONFLICT, code)
            }
            other => migration_code_error(StatusCode::BAD_REQUEST, other),
        },
        AlgoliaImportJobAdmissionError::Repository(error) => ApiError::from(error),
    }
}

fn migration_code_error(status: StatusCode, code: AlgoliaImportErrorCode) -> ApiError {
    ApiError::Migration {
        status,
        message: code.as_str().to_string(),
        code,
        retry_after_seconds: None,
    }
}

fn migration_backpressure() -> ApiError {
    migration_backend_unavailable(AlgoliaImportErrorCode::BackendUnavailable.as_str())
}

/// Single constructor for every `503 backend_unavailable` the migration routes
/// return: always the canonical code with the one bounded `Retry-After`, and a
/// caller-supplied human message.
fn migration_backend_unavailable(message: &str) -> ApiError {
    ApiError::Migration {
        status: StatusCode::SERVICE_UNAVAILABLE,
        message: message.to_string(),
        code: AlgoliaImportErrorCode::BackendUnavailable,
        retry_after_seconds: Some(MIGRATION_RETRY_AFTER_SECONDS),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ListCursorClaims<'a> {
    domain: &'static str,
    version: u8,
    customer_id: String,
    created_at_micros: i64,
    id: &'a str,
    exp: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedListCursorClaims {
    domain: String,
    version: u8,
    customer_id: String,
    created_at_micros: i64,
    id: String,
    exp: i64,
}

fn sign_list_cursor(
    state: &AppState,
    customer_id: uuid::Uuid,
    cursor: AlgoliaImportJobListCursor,
) -> Result<String, ApiError> {
    let id = cursor.id.to_string();
    let claims = ListCursorClaims {
        domain: LIST_CURSOR_DOMAIN,
        version: 1,
        customer_id: customer_id.to_string(),
        created_at_micros: cursor.created_at.timestamp_micros(),
        id: &id,
        exp: (Utc::now() + Duration::seconds(LIST_CURSOR_TTL_SECONDS)).timestamp(),
    };
    let payload = serde_json::to_vec(&claims)
        .map_err(|_| ApiError::Internal("failed to encode list cursor".into()))?;
    Ok(sign_migration_token(state, LIST_CURSOR_DOMAIN, &payload))
}

/// Verify a signed retained-list cursor: rejects tampered, expired, and
/// cross-customer cursors before it is used as a keyset boundary.
fn verify_list_cursor(
    state: &AppState,
    auth: &AuthenticatedTenant,
    token: &str,
) -> Result<AlgoliaImportJobListCursor, ApiError> {
    let payload =
        open_migration_token(state, LIST_CURSOR_DOMAIN, token).ok_or_else(invalid_list_cursor)?;
    let claims: SignedListCursorClaims =
        serde_json::from_slice(&payload).map_err(|_| invalid_list_cursor())?;
    validate_list_cursor_claims(
        &claims,
        Utc::now().timestamp(),
        &auth.customer_id.to_string(),
    )
}

/// Pure validation of a decoded (signature-verified) list cursor against a
/// caller-supplied clock and tenant. Split out from `verify_list_cursor` so
/// expiry and cross-customer rejection are deterministically testable without
/// forging HMAC tokens or waiting out the real clock.
fn validate_list_cursor_claims(
    claims: &SignedListCursorClaims,
    now_secs: i64,
    customer_id: &str,
) -> Result<AlgoliaImportJobListCursor, ApiError> {
    if claims.domain != LIST_CURSOR_DOMAIN || claims.version != 1 {
        return Err(invalid_list_cursor());
    }
    if now_secs >= claims.exp {
        return Err(ApiError::BadRequest("list_cursor_expired".into()));
    }
    if claims.customer_id != customer_id {
        return Err(invalid_list_cursor());
    }
    let created_at = DateTime::from_timestamp_micros(claims.created_at_micros)
        .ok_or_else(invalid_list_cursor)?;
    let id = uuid::Uuid::parse_str(&claims.id).map_err(|_| invalid_list_cursor())?;
    Ok(AlgoliaImportJobListCursor { created_at, id })
}

fn invalid_list_cursor() -> ApiError {
    ApiError::BadRequest("invalid_list_cursor".into())
}

fn migration_error(
    status: StatusCode,
    message: &'static str,
    code: AlgoliaImportErrorCode,
) -> ApiError {
    ApiError::Migration {
        status,
        message: message.to_string(),
        code,
        retry_after_seconds: None,
    }
}

fn migration_unavailable() -> ApiError {
    ApiError::Migration {
        status: StatusCode::SERVICE_UNAVAILABLE,
        message: AlgoliaImportErrorCode::BackendUnavailable
            .as_str()
            .to_string(),
        code: AlgoliaImportErrorCode::BackendUnavailable,
        retry_after_seconds: Some(MIGRATION_RETRY_AFTER_SECONDS),
    }
}

fn sign_destination_eligibility(
    state: &AppState,
    claims: &DestinationEligibilityClaims<'_>,
) -> Result<String, ApiError> {
    let payload = serde_json::to_vec(claims)
        .map_err(|_| ApiError::Internal("failed to encode migration eligibility".into()))?;
    Ok(sign_migration_token(
        state,
        DESTINATION_ELIGIBILITY_DOMAIN,
        &payload,
    ))
}

/// Serialize `payload` as `base64(payload).base64(hmac)` under the given
/// migration domain separator. The one migration token owner shared by the
/// eligibility envelope and the retained-list cursor.
fn sign_migration_token(state: &AppState, domain: &str, payload: &[u8]) -> String {
    let signature = migration_hmac(state, domain, payload);
    format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(payload),
        URL_SAFE_NO_PAD.encode(signature)
    )
}

/// Verify and decode a `sign_migration_token` string under `domain`, returning
/// the raw payload bytes. `None` on any structural or signature failure.
fn open_migration_token(state: &AppState, domain: &str, token: &str) -> Option<Vec<u8>> {
    let (payload_b64, signature_b64) = token.split_once('.')?;
    let payload = URL_SAFE_NO_PAD.decode(payload_b64).ok()?;
    let signature = URL_SAFE_NO_PAD.decode(signature_b64).ok()?;
    verify_migration_hmac(state, domain, &payload, &signature).then_some(payload)
}

fn migration_hmac(state: &AppState, domain: &str, payload: &[u8]) -> Vec<u8> {
    migration_mac(state, domain, payload)
        .finalize()
        .into_bytes()
        .to_vec()
}

/// Constant-time verification of a domain-separated migration signature.
fn verify_migration_hmac(state: &AppState, domain: &str, payload: &[u8], signature: &[u8]) -> bool {
    migration_mac(state, domain, payload)
        .verify_slice(signature)
        .is_ok()
}

fn migration_mac(state: &AppState, domain: &str, payload: &[u8]) -> HmacSha256 {
    let mut mac = HmacSha256::new_from_slice(state.jwt_secret.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(domain.as_bytes());
    mac.update(&[0]);
    mac.update(payload);
    mac
}

#[cfg(test)]
mod tests;

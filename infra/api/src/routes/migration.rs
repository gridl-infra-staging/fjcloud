use axum::extract::State;
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
use crate::models::algolia_import_job::{AlgoliaImportDestinationKind, AlgoliaImportTargetBinding};
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
mod source;

use source::map_algolia_source_error;

// Re-export handlers, request DTOs, and `#[utoipa::path]`-generated path items
// so existing route assembly and test-only OpenAPI generation resolve unchanged
// after extracting the migration route surface.
pub use capabilities::AlgoliaMigrationCapabilities;
pub use eligibility::{
    __path_check_algolia_destination_eligibility, check_algolia_destination_eligibility,
    AlgoliaDestinationEligibilityRequest, AlgoliaDestinationEligibilityResponse,
};
pub use jobs::{
    __path_cancel_algolia_import_job, __path_create_algolia_import_job,
    __path_get_algolia_import_job, __path_list_algolia_import_jobs,
    __path_resume_algolia_import_job, cancel_algolia_import_job, create_algolia_import_job,
    get_algolia_import_job, list_algolia_import_jobs, resume_algolia_import_job,
    CancelAlgoliaImportJobRequest, CreateAlgoliaImportJobRequest, ListAlgoliaImportJobsQuery,
    PublicAlgoliaImportJob, PublicAlgoliaImportJobPage, ResumeAlgoliaImportJobRequest,
};
pub use source::{__path_list_algolia_indexes, list_algolia_indexes, ListAlgoliaIndexesRequest};

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
    pub reason: AlgoliaMigrationAvailabilityReason,
    pub message: String,
    pub capabilities: AlgoliaMigrationCapabilities,
}

impl AlgoliaMigrationAvailabilityResponse {
    fn unavailable() -> Self {
        Self {
            available: false,
            reason: AlgoliaMigrationAvailabilityReason::TemporarilyUnavailable,
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

#[utoipa::path(
    get,
    path = "/migration/algolia/availability",
    tag = "Migration",
    responses(
        (status = 200, description = "Algolia migration availability", body = AlgoliaMigrationAvailabilityResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn algolia_availability(
    _auth: AuthenticatedTenant,
    State(_state): State<AppState>,
) -> Json<AlgoliaMigrationAvailabilityResponse> {
    // Stage 1 intentionally fails closed: customer-facing migration admission
    // remains unavailable until the replacement importer and its route surface
    // exist together again.
    Json(AlgoliaMigrationAvailabilityResponse::unavailable())
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
    let claims: SignedEligibilityClaims =
        serde_json::from_slice(&payload).map_err(|_| invalid_eligibility_token())?;
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
    let (payload_b64, signature_b64) = request
        .target
        .eligibility_token
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
    let claims: SignedEligibilityClaims =
        serde_json::from_slice(&payload).map_err(|_| invalid_eligibility_token())?;
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
    if claims.phase != AlgoliaEligibilityPhase::Target {
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
    if claims.phase != AlgoliaEligibilityPhase::Provider {
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
    if claims.mode != expected_mode
        || claims.region != expected_target.region
        || claims.name != expected_target.name
    {
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
mod tests {
    use super::*;

    fn provider_claims() -> SignedEligibilityClaims {
        SignedEligibilityClaims {
            domain: DESTINATION_ELIGIBILITY_DOMAIN.to_string(),
            version: 1,
            phase: AlgoliaEligibilityPhase::Provider,
            mode: AlgoliaImportDestinationKind::Create,
            customer_id: "11111111-1111-1111-1111-111111111111".to_string(),
            region: "us-east-1".to_string(),
            name: "products".to_string(),
            lifecycle_generation: None,
            routing_identity: None,
            exp: 2_000_000_000,
        }
    }

    fn target(region: &str, name: &str) -> eligibility::AlgoliaDestinationEligibilityTargetRequest {
        eligibility::AlgoliaDestinationEligibilityTargetRequest {
            region: region.to_string(),
            name: name.to_string(),
        }
    }

    fn migration_failure(error: ApiError) -> (StatusCode, String) {
        match error {
            ApiError::Migration {
                status, message, ..
            } => (status, message),
            other => panic!("expected migration error, got {other:?}"),
        }
    }

    #[test]
    fn valid_provider_claims_are_accepted() {
        let claims = provider_claims();
        assert!(validate_provider_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
            AlgoliaImportDestinationKind::Create,
            &target("us-east-1", "products"),
        )
        .is_ok());
    }

    #[test]
    fn expired_provider_envelope_is_rejected() {
        let claims = provider_claims();
        let error = validate_provider_claims(
            &claims,
            claims.exp,
            "11111111-1111-1111-1111-111111111111",
            AlgoliaImportDestinationKind::Create,
            &target("us-east-1", "products"),
        )
        .expect_err("an envelope at or past its expiry is rejected");
        let (status, message) = migration_failure(error);
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(message, "eligibility_token_expired");
    }

    #[test]
    fn non_provider_phase_envelope_is_rejected() {
        let mut claims = provider_claims();
        claims.phase = AlgoliaEligibilityPhase::Target;
        let error = validate_provider_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
            AlgoliaImportDestinationKind::Create,
            &target("us-east-1", "products"),
        )
        .expect_err("only provider-phase envelopes may be replayed into the target phase");
        let (status, message) = migration_failure(error);
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(message, "eligibility_phase_mismatch");
    }

    #[test]
    fn cross_customer_envelope_is_rejected() {
        let claims = provider_claims();
        let error = validate_provider_claims(
            &claims,
            claims.exp - 1,
            "22222222-2222-2222-2222-222222222222",
            AlgoliaImportDestinationKind::Create,
            &target("us-east-1", "products"),
        )
        .expect_err("an envelope minted for another customer is rejected");
        let (status, message) = migration_failure(error);
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(message, "eligibility_customer_mismatch");
    }

    #[test]
    fn changed_destination_binding_is_rejected() {
        let claims = provider_claims();
        let error = validate_provider_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
            AlgoliaImportDestinationKind::Create,
            &target("eu-west-1", "products"),
        )
        .expect_err("a region change invalidates the provider envelope binding");
        let (status, message) = migration_failure(error);
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(message, "destination_changed");
    }

    fn list_cursor_claims() -> SignedListCursorClaims {
        SignedListCursorClaims {
            domain: LIST_CURSOR_DOMAIN.to_string(),
            version: 1,
            customer_id: "11111111-1111-1111-1111-111111111111".to_string(),
            created_at_micros: 1_700_000_000_000_000,
            id: "01890f4f-a0b1-7298-9f0b-7e6fdf45d111".to_string(),
            exp: 2_000_000_000,
        }
    }

    fn bad_request_message(error: ApiError) -> String {
        match error {
            ApiError::BadRequest(message) => message,
            other => panic!("expected bad-request error, got {other:?}"),
        }
    }

    #[test]
    fn valid_list_cursor_claims_are_accepted() {
        let claims = list_cursor_claims();
        let cursor = validate_list_cursor_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
        )
        .expect("a fresh, matching cursor is accepted");
        assert_eq!(cursor.id.to_string(), claims.id);
        assert_eq!(
            cursor.created_at.timestamp_micros(),
            claims.created_at_micros
        );
    }

    #[test]
    fn expired_list_cursor_is_rejected() {
        let claims = list_cursor_claims();
        // Clock exactly at expiry is already stale: rejection is inclusive of `exp`.
        let error = validate_list_cursor_claims(
            &claims,
            claims.exp,
            "11111111-1111-1111-1111-111111111111",
        )
        .expect_err("a cursor at or past its expiry is rejected");
        assert_eq!(bad_request_message(error), "list_cursor_expired");
    }

    #[test]
    fn cross_customer_list_cursor_is_rejected() {
        let claims = list_cursor_claims();
        // A non-expired cursor minted for another tenant must never be honored,
        // and the rejection must be indistinguishable from a tampered cursor.
        let error = validate_list_cursor_claims(
            &claims,
            claims.exp - 1,
            "22222222-2222-2222-2222-222222222222",
        )
        .expect_err("a cursor minted for another customer is rejected");
        assert_eq!(bad_request_message(error), "invalid_list_cursor");
    }

    #[test]
    fn foreign_domain_list_cursor_is_rejected() {
        let mut claims = list_cursor_claims();
        claims.domain = "fjcloud.some_other_domain.v1".to_string();
        let error = validate_list_cursor_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
        )
        .expect_err("a cursor from a different token domain is rejected");
        assert_eq!(bad_request_message(error), "invalid_list_cursor");
    }

    #[test]
    fn foreign_domain_envelope_is_rejected() {
        let mut claims = provider_claims();
        claims.domain = "fjcloud.some_other_domain.v1".to_string();
        let error = validate_provider_claims(
            &claims,
            claims.exp - 1,
            "11111111-1111-1111-1111-111111111111",
            AlgoliaImportDestinationKind::Create,
            &target("us-east-1", "products"),
        )
        .expect_err("an envelope from a different HMAC domain is rejected");
        let (_status, message) = migration_failure(error);
        assert_eq!(message, "invalid_eligibility_token");
    }
}

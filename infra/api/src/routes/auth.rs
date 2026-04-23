use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use chrono::{Duration, Utc};
use jsonwebtoken::{EncodingKey, Header};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::auth::{AuthenticatedTenant, Claims};
use crate::errors::{ApiError, ErrorResponse};
use crate::state::AppState;
use crate::validation::{
    validate_email, validate_length, validate_password, MAX_NAME_LEN, MAX_PASSWORD_LEN,
};

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, ToSchema)]
pub struct RegisterRequest {
    pub name: String,
    pub email: String,
    pub password: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct AuthResponse {
    pub token: String,
    pub customer_id: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct VerifyEmailRequest {
    pub token: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct ForgotPasswordRequest {
    pub email: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct ResetPasswordRequest {
    pub token: String,
    pub new_password: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct MessageResponse {
    pub message: String,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Encode a JWT with a 24-hour expiry for the given `customer_id`.
///
/// Uses HS256 with `secret` as the signing key. Returns `ApiError::Internal`
/// if the system clock is unavailable or encoding fails.
fn issue_jwt(customer_id: &str, secret: &str) -> Result<String, ApiError> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| ApiError::Internal("system clock error".into()))?
        .as_secs() as usize;

    let claims = Claims {
        sub: customer_id.to_string(),
        exp: now + 86400, // 24 hours
        iat: now,
    };

    jsonwebtoken::encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .map_err(|e| ApiError::Internal(format!("JWT encoding failed: {e}")))
}

fn generate_token() -> String {
    use rand::rngs::OsRng;
    use rand::Rng;
    let bytes: [u8; 32] = OsRng.gen();
    hex::encode(bytes)
}

use crate::password::{hash_password, verify_password};

// ---------------------------------------------------------------------------
// POST /auth/register
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/register",
    tag = "Auth",
    security(()),
    request_body = RegisterRequest,
    responses(
        (status = 201, description = "Account created", body = AuthResponse),
        (status = 400, description = "Validation error", body = ErrorResponse),
        (status = 409, description = "Email already registered", body = ErrorResponse),
    )
)]
pub async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<AuthResponse>), ApiError> {
    if req.name.trim().is_empty() || req.email.trim().is_empty() || req.password.is_empty() {
        return Err(ApiError::BadRequest(
            "name, email, and password are required".into(),
        ));
    }

    let name = req.name.trim();
    validate_length("name", name, MAX_NAME_LEN)?;

    let email = req.email.trim().to_lowercase();
    validate_email(&email)?;
    validate_password(&req.password)?;

    let password_hash = hash_password(&req.password)?;

    let customer = state
        .customer_repo
        .create_with_password(name, &email, &password_hash)
        .await
        .map_err(|e| match e {
            crate::repos::RepoError::Conflict(_) => {
                ApiError::Conflict("email already registered".into())
            }
            other => ApiError::from(other),
        })?;

    setup_email_verification(&state, customer.id, &email).await?;
    create_stripe_customer_best_effort(&state, customer.id, name, &email).await;

    let token = issue_jwt(&customer.id.to_string(), &state.jwt_secret)?;

    Ok((
        StatusCode::CREATED,
        Json(AuthResponse {
            token,
            customer_id: customer.id.to_string(),
        }),
    ))
}

/// Best-effort email verification setup: generates a verification token,
/// stores it, and either auto-verifies (dev mode) or sends the verification email.
async fn setup_email_verification(
    state: &AppState,
    customer_id: uuid::Uuid,
    email: &str,
) -> Result<(), ApiError> {
    let verify_token = generate_token();
    let expires_at = Utc::now() + Duration::hours(24);
    state
        .customer_repo
        .set_email_verify_token(customer_id, &verify_token, expires_at)
        .await
        .map_err(ApiError::from)?;

    // Dev mode: auto-verify email so users can immediately create indexes
    // without needing a working email delivery pipeline.
    if std::env::var("SKIP_EMAIL_VERIFICATION").is_ok() {
        if let Err(e) = state.customer_repo.verify_email(&verify_token).await {
            tracing::warn!(
                "SKIP_EMAIL_VERIFICATION: failed to auto-verify {}: {e}",
                email
            );
        } else {
            tracing::info!("SKIP_EMAIL_VERIFICATION: auto-verified {}", email);
        }
    } else if let Err(e) = state
        .email_service
        .send_verification_email(email, &verify_token)
        .await
    {
        tracing::warn!(
            "failed to send verification email to {}: {e} — customer can re-request later",
            email
        );
    }

    Ok(())
}

/// Best-effort Stripe customer creation: creates a Stripe customer and stores
/// the stripe_customer_id. Logs warnings on failure but never fails registration.
async fn create_stripe_customer_best_effort(
    state: &AppState,
    customer_id: uuid::Uuid,
    name: &str,
    email: &str,
) {
    match state.stripe_service.create_customer(name, email).await {
        Ok(stripe_id) => {
            if let Err(e) = state
                .customer_repo
                .set_stripe_customer_id(customer_id, &stripe_id)
                .await
            {
                tracing::warn!(
                    "failed to store stripe_customer_id for customer {}: {e}",
                    customer_id
                );
            }
        }
        Err(e) => {
            tracing::warn!(
                "failed to create Stripe customer for {}: {e} — can be synced later via /admin/customers/:id/sync-stripe",
                customer_id
            );
        }
    }
}

// ---------------------------------------------------------------------------
// POST /auth/login
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/login",
    tag = "Auth",
    security(()),
    request_body = LoginRequest,
    responses(
        (status = 200, description = "Login successful", body = AuthResponse),
        (status = 400, description = "Invalid credentials", body = ErrorResponse),
    )
)]
/// `POST /auth/login` — authenticate with email and password (no auth required).
///
/// Looks up the customer by email (case-insensitive), rejects deleted accounts,
/// and verifies the password against the stored bcrypt hash. Returns a 24-hour
/// JWT in `AuthResponse`, or 400 with a generic "invalid email or password"
/// message for any credential mismatch (avoids leaking which field was wrong).
pub async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, ApiError> {
    if req.password.len() > MAX_PASSWORD_LEN {
        return Err(ApiError::BadRequest(format!(
            "password must be at most {MAX_PASSWORD_LEN} characters"
        )));
    }

    let customer = state
        .customer_repo
        .find_by_email(&req.email.trim().to_lowercase())
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::BadRequest("invalid email or password".into()))?;

    if customer.status == "deleted" {
        return Err(ApiError::BadRequest("invalid email or password".into()));
    }

    let hash = customer
        .password_hash
        .as_deref()
        .ok_or_else(|| ApiError::BadRequest("invalid email or password".into()))?;

    if !verify_password(&req.password, hash) {
        return Err(ApiError::BadRequest("invalid email or password".into()));
    }

    let token = issue_jwt(&customer.id.to_string(), &state.jwt_secret)?;

    Ok(Json(AuthResponse {
        token,
        customer_id: customer.id.to_string(),
    }))
}

// ---------------------------------------------------------------------------
// POST /auth/verify-email
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/verify-email",
    tag = "Auth",
    security(()),
    request_body = VerifyEmailRequest,
    responses(
        (status = 200, description = "Email verified", body = MessageResponse),
        (status = 400, description = "Invalid or expired token", body = ErrorResponse),
    )
)]
pub async fn verify_email(
    State(state): State<AppState>,
    Json(req): Json<VerifyEmailRequest>,
) -> Result<Json<MessageResponse>, ApiError> {
    let _customer = state
        .customer_repo
        .verify_email(&req.token)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::BadRequest("invalid or expired verification token".into()))?;

    Ok(Json(MessageResponse {
        message: "email verified".into(),
    }))
}

// ---------------------------------------------------------------------------
// POST /auth/resend-verification
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/resend-verification",
    tag = "Auth",
    request_body = (),
    responses(
        (status = 200, description = "Verification email sent", body = MessageResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Email already verified", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
        (status = 503, description = "Email service unavailable", body = ErrorResponse),
    )
)]
/// `POST /auth/resend-verification` — re-send the email verification link.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Generates a fresh 24-hour verification token (replacing any previous one)
/// and dispatches it via the email service. Returns 400 if the email is
/// already verified, 503 if the email service is unreachable.
pub async fn resend_verification(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<Json<MessageResponse>, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(auth.customer_id)
        .await
        .map_err(ApiError::from)?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    if customer.email_verified_at.is_some() {
        return Err(ApiError::BadRequest("email already verified".into()));
    }

    let verify_token = generate_token();
    let expires_at = Utc::now() + Duration::hours(24);
    let updated = state
        .customer_repo
        .set_email_verify_token(customer.id, &verify_token, expires_at)
        .await
        .map_err(ApiError::from)?;
    if !updated {
        return Err(ApiError::NotFound("customer not found".into()));
    }

    if let Err(e) = state
        .email_service
        .send_verification_email(&customer.email, &verify_token)
        .await
    {
        tracing::warn!(
            "failed to resend verification email to {}: {e}",
            customer.email
        );
        return Err(ApiError::ServiceUnavailable(
            "verification email temporarily unavailable".into(),
        ));
    }

    Ok(Json(MessageResponse {
        message: "verification email sent".into(),
    }))
}

// ---------------------------------------------------------------------------
// POST /auth/forgot-password
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/forgot-password",
    tag = "Auth",
    security(()),
    request_body = ForgotPasswordRequest,
    responses(
        (status = 200, description = "Reset email sent if account exists", body = MessageResponse),
    )
)]
/// `POST /auth/forgot-password` — request a password-reset email (no auth required).
///
/// Always returns 200 regardless of whether the email exists, preventing
/// email enumeration. If the account exists and is not deleted, stores a
/// 1-hour reset token and dispatches the reset email (best-effort).
pub async fn forgot_password(
    State(state): State<AppState>,
    Json(req): Json<ForgotPasswordRequest>,
) -> Result<Json<MessageResponse>, ApiError> {
    // Always return 200 to avoid email enumeration
    let customer = state
        .customer_repo
        .find_by_email(&req.email.trim().to_lowercase())
        .await
        .map_err(ApiError::from)?;

    if let Some(customer) = customer {
        if customer.status != "deleted" {
            let reset_token = generate_token();
            let expires_at = Utc::now() + Duration::hours(1);
            state
                .customer_repo
                .set_password_reset_token(customer.id, &reset_token, expires_at)
                .await
                .map_err(ApiError::from)?;

            if let Err(e) = state
                .email_service
                .send_password_reset_email(&customer.email, &reset_token)
                .await
            {
                tracing::warn!(
                    "failed to send password reset email to {}: {e}",
                    customer.email
                );
            }
        }
    }

    Ok(Json(MessageResponse {
        message: "if an account exists with that email, a password reset link has been sent".into(),
    }))
}

// ---------------------------------------------------------------------------
// POST /auth/reset-password
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/auth/reset-password",
    tag = "Auth",
    security(()),
    request_body = ResetPasswordRequest,
    responses(
        (status = 200, description = "Password reset successful", body = MessageResponse),
        (status = 400, description = "Invalid or expired token", body = ErrorResponse),
    )
)]
/// `POST /auth/reset-password` — consume a reset token and set a new password
/// (no auth required).
///
/// Validates the new password, hashes it with bcrypt, and atomically consumes
/// the token. Returns 400 if the token is invalid or expired.
pub async fn reset_password(
    State(state): State<AppState>,
    Json(req): Json<ResetPasswordRequest>,
) -> Result<Json<MessageResponse>, ApiError> {
    validate_password(&req.new_password)?;

    let new_hash = hash_password(&req.new_password)?;

    let success = state
        .customer_repo
        .reset_password(&req.token, &new_hash)
        .await
        .map_err(ApiError::from)?;

    if !success {
        return Err(ApiError::BadRequest(
            "invalid or expired reset token".into(),
        ));
    }

    Ok(Json(MessageResponse {
        message: "password has been reset".into(),
    }))
}

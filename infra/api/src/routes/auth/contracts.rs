use axum::http::HeaderMap;
use axum::Json;
use jsonwebtoken::{EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::future::Future;
use utoipa::ToSchema;

use crate::auth::Claims;
use crate::errors::ApiError;
use crate::services::email::EmailError;

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
pub struct ResendPasswordResetRequest {
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

const TEST_FORCE_EMAIL_FAILURE_HEADER: &str = "x-test-force-email-failure";
const AUTH_EMAIL_DELIVERY_MAX_ATTEMPTS: usize = 2;
const PASSWORD_RESET_SENT_MESSAGE: &str =
    "if an account exists with that email, a password reset link has been sent";

pub(super) fn password_reset_sent_response() -> Json<MessageResponse> {
    Json(MessageResponse {
        message: PASSWORD_RESET_SENT_MESSAGE.into(),
    })
}

/// Encode a JWT with a 24-hour expiry for the given `customer_id`.
///
/// Uses HS256 with `secret` as the signing key. Returns `ApiError::Internal`
/// if the system clock is unavailable or encoding fails.
pub(super) fn issue_jwt(customer_id: &str, secret: &str) -> Result<String, ApiError> {
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

pub(super) fn generate_token() -> String {
    use rand::rngs::OsRng;
    use rand::Rng;
    let bytes: [u8; 32] = OsRng.gen();
    hex::encode(bytes)
}

pub(super) fn email_domain(email: &str) -> Option<&str> {
    email.rsplit_once('@').map(|(_, domain)| domain)
}

pub(super) fn to_retry_after_header_seconds(seconds: i64) -> u64 {
    u64::try_from(seconds)
        .ok()
        .filter(|value| *value > 0)
        .unwrap_or(1)
}

fn should_force_email_delivery_failure(headers: &HeaderMap) -> bool {
    let Some(header_value) = headers.get(TEST_FORCE_EMAIL_FAILURE_HEADER) else {
        return false;
    };
    let Some(raw_value) = header_value.to_str().ok() else {
        return false;
    };
    let normalized_value = raw_value.trim().to_ascii_lowercase();
    let is_truthy = matches!(normalized_value.as_str(), "1" | "true" | "yes" | "on");
    if !is_truthy {
        return false;
    }

    let startup_env = crate::startup_env::StartupEnvSnapshot::from_env();
    if startup_env.allow_test_force_email_failure_header() {
        return true;
    }

    tracing::warn!(
        "{TEST_FORCE_EMAIL_FAILURE_HEADER} ignored because startup environment is not local zero-dependency"
    );
    false
}

pub(super) async fn send_auth_email_with_retry<F, Fut>(
    headers: &HeaderMap,
    unavailable_message: &'static str,
    mut send_once: F,
) -> Result<(), ApiError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<(), EmailError>>,
{
    if should_force_email_delivery_failure(headers) {
        tracing::warn!(
            "{TEST_FORCE_EMAIL_FAILURE_HEADER} forced auth email delivery failure for test"
        );
        return Err(ApiError::ServiceUnavailable(
            unavailable_message.to_string(),
        ));
    }

    for attempt in 1..=AUTH_EMAIL_DELIVERY_MAX_ATTEMPTS {
        match send_once().await {
            Ok(()) => return Ok(()),
            Err(err) if attempt < AUTH_EMAIL_DELIVERY_MAX_ATTEMPTS => {
                tracing::warn!(
                    "auth email delivery attempt {attempt}/{AUTH_EMAIL_DELIVERY_MAX_ATTEMPTS} failed: {err}"
                );
            }
            Err(err) => {
                tracing::warn!(
                    "auth email delivery exhausted retries ({AUTH_EMAIL_DELIVERY_MAX_ATTEMPTS} attempts): {err}"
                );
                return Err(ApiError::ServiceUnavailable(
                    unavailable_message.to_string(),
                ));
            }
        }
    }

    Err(ApiError::ServiceUnavailable(
        unavailable_message.to_string(),
    ))
}

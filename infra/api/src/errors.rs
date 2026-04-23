use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::json;
use utoipa::ToSchema;

use crate::repos::RepoError;
use crate::services::ayb_admin::AybAdminError;
use crate::services::flapjack_proxy::ProxyError;
use crate::services::provisioning::ProvisioningError;
use crate::stripe::StripeError;

/// Shared error envelope returned by all API error responses.
/// Shape: `{"error": "<message>"}`.
#[derive(Debug, Serialize, Deserialize, ToSchema)]
pub struct ErrorResponse {
    /// Human-readable error description.
    pub error: String,
}

#[derive(Debug)]
pub enum ApiError {
    NotFound(String),
    Conflict(String),
    BadRequest(String),
    Forbidden(String),
    ServiceUnavailable(String),
    ServiceNotConfigured(String),
    Gone(String),
    Internal(String),
}

fn map_flapjack_error(status: u16, message: String) -> ApiError {
    match status {
        404 => ApiError::NotFound(message),
        409 => ApiError::Conflict(message),
        400..=499 => ApiError::BadRequest(message),
        _ => ApiError::Internal(format!("flapjack error (HTTP {status}): {message}")),
    }
}

impl IntoResponse for ApiError {
    /// Maps each variant to its HTTP status code and JSON error body.
    /// `Internal` hides the original message behind a generic "internal server error".
    /// `ServiceNotConfigured` logs a warning before returning 503.
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            ApiError::NotFound(msg) => (StatusCode::NOT_FOUND, msg.as_str()),
            ApiError::Conflict(msg) => (StatusCode::CONFLICT, msg.as_str()),
            ApiError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.as_str()),
            ApiError::Forbidden(msg) => (StatusCode::FORBIDDEN, msg.as_str()),
            ApiError::ServiceUnavailable(msg) => (StatusCode::SERVICE_UNAVAILABLE, msg.as_str()),
            ApiError::ServiceNotConfigured(service) => {
                tracing::warn!("{service} service not configured");
                (StatusCode::SERVICE_UNAVAILABLE, "service_not_configured")
            }
            ApiError::Gone(msg) => (StatusCode::GONE, msg.as_str()),
            ApiError::Internal(msg) => {
                tracing::error!("internal error: {msg}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
            }
        };

        (status, Json(json!({"error": message}))).into_response()
    }
}

impl From<RepoError> for ApiError {
    fn from(err: RepoError) -> Self {
        match err {
            RepoError::NotFound => ApiError::NotFound("entity not found".into()),
            RepoError::Conflict(msg) => ApiError::Conflict(msg),
            RepoError::Other(msg) => ApiError::Internal(msg),
        }
    }
}

impl From<ProvisioningError> for ApiError {
    fn from(err: ProvisioningError) -> Self {
        match err {
            ProvisioningError::CustomerNotFound => ApiError::NotFound("customer not found".into()),
            ProvisioningError::CustomerSuspended => {
                ApiError::Forbidden("customer is suspended".into())
            }
            ProvisioningError::DeploymentNotFound | ProvisioningError::NotOwned => {
                ApiError::NotFound("deployment not found".into())
            }
            ProvisioningError::InvalidState(msg) => ApiError::BadRequest(msg),
            ProvisioningError::DeploymentLimitReached(max) => {
                ApiError::BadRequest(format!("deployment limit reached (max {max})"))
            }
            ProvisioningError::ProvisionerFailed(msg) => ApiError::Internal(msg),
            ProvisioningError::DnsFailed(msg) => ApiError::Internal(msg),
            ProvisioningError::SecretFailed(msg) => ApiError::Internal(msg),
            ProvisioningError::RepoError(msg) => ApiError::Internal(msg),
        }
    }
}

impl From<ProxyError> for ApiError {
    /// Converts [`ProxyError`] to API responses. `Unreachable` returns 503 and
    /// hides the VM IP address in a generic message (logging the original).
    /// `FlapjackError` maps by HTTP status; `SecretError` and `Timeout`→500/503.
    fn from(err: ProxyError) -> Self {
        match err {
            ProxyError::Unreachable(msg) => {
                tracing::warn!("flapjack VM unreachable: {msg}");
                ApiError::ServiceUnavailable("backend temporarily unavailable".into())
            }
            ProxyError::FlapjackError { status, message } => map_flapjack_error(status, message),
            ProxyError::SecretError(msg) => ApiError::Internal(format!("secret error: {msg}")),
            ProxyError::Timeout => ApiError::ServiceUnavailable("request timed out".into()),
        }
    }
}

impl From<StripeError> for ApiError {
    fn from(err: StripeError) -> Self {
        match err {
            StripeError::NotConfigured => ApiError::ServiceNotConfigured("billing".into()),
            other => ApiError::Internal(other.to_string()),
        }
    }
}

impl From<AybAdminError> for ApiError {
    fn from(err: AybAdminError) -> Self {
        match err {
            AybAdminError::BadRequest(msg) => ApiError::BadRequest(msg),
            AybAdminError::NotFound(msg) => ApiError::NotFound(msg),
            AybAdminError::Conflict(msg) => ApiError::Conflict(msg),
            AybAdminError::ServiceUnavailable => {
                ApiError::ServiceUnavailable("AYB service unavailable".into())
            }
            AybAdminError::Unauthorized => {
                ApiError::Internal("AYB admin authentication failed".into())
            }
            AybAdminError::Internal(msg) => {
                tracing::error!("AYB admin error: {msg}");
                ApiError::Internal("AYB admin operation failed".into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;

    async fn error_status_and_body(err: ApiError) -> (StatusCode, serde_json::Value) {
        let resp = err.into_response();
        let status = resp.status();
        let body = Body::new(resp.into_body())
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        (status, json)
    }

    #[tokio::test]
    async fn not_found_returns_404() {
        let (status, body) =
            error_status_and_body(ApiError::NotFound("tenant not found".into())).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body, json!({"error": "tenant not found"}));
    }

    #[tokio::test]
    async fn conflict_returns_409() {
        let (status, body) =
            error_status_and_body(ApiError::Conflict("email already exists".into())).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body, json!({"error": "email already exists"}));
    }

    #[tokio::test]
    async fn bad_request_returns_400() {
        let (status, body) =
            error_status_and_body(ApiError::BadRequest("no fields to update".into())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body, json!({"error": "no fields to update"}));
    }

    #[tokio::test]
    async fn forbidden_returns_403() {
        let (status, body) =
            error_status_and_body(ApiError::Forbidden("access denied".into())).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body, json!({"error": "access denied"}));
    }

    #[tokio::test]
    async fn internal_does_not_expose_details() {
        let (status, body) =
            error_status_and_body(ApiError::Internal("db connection failed".into())).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    // ─── ProxyError → ApiError conversion tests ───────────────────────

    #[tokio::test]
    async fn proxy_flapjack_404_returns_not_found() {
        let err: ApiError = ProxyError::FlapjackError {
            status: 404,
            message: "index 'test' not found".into(),
        }
        .into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body, json!({"error": "index 'test' not found"}));
    }

    #[tokio::test]
    async fn proxy_flapjack_409_returns_conflict() {
        let err: ApiError = ProxyError::FlapjackError {
            status: 409,
            message: "index already exists".into(),
        }
        .into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body, json!({"error": "index already exists"}));
    }

    #[tokio::test]
    async fn proxy_flapjack_400_returns_bad_request() {
        let err: ApiError = ProxyError::FlapjackError {
            status: 422,
            message: "invalid index name".into(),
        }
        .into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body, json!({"error": "invalid index name"}));
    }

    #[tokio::test]
    async fn proxy_flapjack_5xx_returns_internal_without_details() {
        let err: ApiError = ProxyError::FlapjackError {
            status: 502,
            message: "upstream storage engine crashed".into(),
        }
        .into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        // Must NOT expose flapjack internal details to client
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    #[tokio::test]
    async fn proxy_unreachable_returns_503_without_details() {
        let err: ApiError =
            ProxyError::Unreachable("connection refused to 10.0.1.5:8080".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        // Must NOT expose VM IP addresses to client — hardcoded message only
        assert_eq!(body, json!({"error": "backend temporarily unavailable"}));
    }

    #[tokio::test]
    async fn proxy_timeout_returns_503() {
        let err: ApiError = ProxyError::Timeout.into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body, json!({"error": "request timed out"}));
    }

    #[tokio::test]
    async fn proxy_secret_error_returns_internal() {
        let err: ApiError = ProxyError::SecretError("SSM unavailable".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        // Must NOT expose SSM details to client
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    #[tokio::test]
    async fn stripe_not_configured_returns_service_not_configured() {
        let err: ApiError = StripeError::NotConfigured.into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body, json!({"error": "service_not_configured"}));
    }

    #[tokio::test]
    async fn stripe_api_returns_internal_without_leaking_details() {
        let err: ApiError = StripeError::Api("invalid API key".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    #[tokio::test]
    async fn stripe_webhook_verification_returns_internal() {
        let err: ApiError = StripeError::WebhookVerification("invalid signature".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    #[tokio::test]
    async fn service_not_configured_returns_503_with_fixed_message() {
        let (status, body) =
            error_status_and_body(ApiError::ServiceNotConfigured("billing".into())).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body, json!({"error": "service_not_configured"}));
    }

    // ─── AybAdminError → ApiError conversion tests ─────────────────────

    #[tokio::test]
    async fn ayb_admin_bad_request_returns_400() {
        let err: ApiError = AybAdminError::BadRequest("tenant is already deleted".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body, json!({"error": "tenant is already deleted"}));
    }

    #[tokio::test]
    async fn ayb_admin_not_found_returns_404() {
        let err: ApiError = AybAdminError::NotFound("tenant not found".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body, json!({"error": "tenant not found"}));
    }

    #[tokio::test]
    async fn ayb_admin_conflict_returns_409() {
        let err: ApiError = AybAdminError::Conflict("tenant already exists".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body, json!({"error": "tenant already exists"}));
    }

    #[tokio::test]
    async fn ayb_admin_service_unavailable_returns_503() {
        let err: ApiError = AybAdminError::ServiceUnavailable.into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body, json!({"error": "AYB service unavailable"}));
    }

    #[tokio::test]
    async fn ayb_admin_unauthorized_returns_internal_without_leaking() {
        let err: ApiError = AybAdminError::Unauthorized.into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body, json!({"error": "internal server error"}));
    }

    #[tokio::test]
    async fn ayb_admin_internal_returns_internal_without_leaking() {
        let err: ApiError = AybAdminError::Internal("raw upstream message".into()).into();
        let (status, body) = error_status_and_body(err).await;
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        // Must NOT expose raw upstream details
        assert_eq!(body, json!({"error": "internal server error"}));
    }
}

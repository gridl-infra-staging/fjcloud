use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

/// Authentication and authorization error variants returned by extractors.
/// Maps to HTTP status codes: `MissingToken`/`InvalidToken`/`MissingAdminKey`/`InvalidAdminKey` → 401,
/// `Forbidden` → 403, `Internal` → 500.
#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("missing authorization header")]
    MissingToken,

    #[error("invalid or expired token")]
    InvalidToken,

    #[error("missing admin key")]
    MissingAdminKey,

    #[error("invalid admin key")]
    InvalidAdminKey,

    #[error("forbidden")]
    Forbidden,

    #[error("too many requests")]
    RateLimited { retry_after_seconds: u64 },

    #[error("internal error")]
    Internal,
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            AuthError::MissingToken => (StatusCode::UNAUTHORIZED, "missing authorization header"),
            AuthError::InvalidToken => (StatusCode::UNAUTHORIZED, "invalid or expired token"),
            AuthError::MissingAdminKey => (StatusCode::UNAUTHORIZED, "missing admin key"),
            AuthError::InvalidAdminKey => (StatusCode::UNAUTHORIZED, "invalid admin key"),
            AuthError::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
            AuthError::RateLimited { .. } => (StatusCode::TOO_MANY_REQUESTS, "too many requests"),
            AuthError::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
        };

        let mut response = (status, Json(json!({"error": message}))).into_response();
        if let AuthError::RateLimited {
            retry_after_seconds,
        } = self
        {
            response.headers_mut().insert(
                header::RETRY_AFTER,
                retry_after_header_value(retry_after_seconds),
            );
        }
        response
    }
}

fn retry_after_header_value(retry_after_seconds: u64) -> HeaderValue {
    HeaderValue::from_str(&retry_after_seconds.to_string())
        .unwrap_or_else(|_| HeaderValue::from_static("1"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;

    async fn error_response_parts(
        err: AuthError,
    ) -> (StatusCode, serde_json::Value, Option<String>) {
        let resp = err.into_response();
        let status = resp.status();
        let retry_after = resp
            .headers()
            .get(axum::http::header::RETRY_AFTER)
            .map(|value| value.to_str().unwrap().to_string());
        let body = Body::new(resp.into_body())
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        (status, json, retry_after)
    }

    #[tokio::test]
    async fn missing_token_returns_401() {
        let (status, body, retry_after) = error_response_parts(AuthError::MissingToken).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "missing authorization header"}));
        assert_eq!(retry_after, None);
    }

    #[tokio::test]
    async fn invalid_token_returns_401() {
        let (status, body, _retry_after) = error_response_parts(AuthError::InvalidToken).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "invalid or expired token"}));
    }

    #[tokio::test]
    async fn missing_admin_key_returns_401() {
        let (status, body, _retry_after) = error_response_parts(AuthError::MissingAdminKey).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "missing admin key"}));
    }

    #[tokio::test]
    async fn invalid_admin_key_returns_401() {
        let (status, body, _retry_after) = error_response_parts(AuthError::InvalidAdminKey).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "invalid admin key"}));
    }

    #[tokio::test]
    async fn forbidden_returns_403() {
        let (status, body, _retry_after) = error_response_parts(AuthError::Forbidden).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body, json!({"error": "forbidden"}));
    }

    #[tokio::test]
    async fn rate_limited_returns_429_with_retry_after() {
        let (status, body, retry_after) = error_response_parts(AuthError::RateLimited {
            retry_after_seconds: 3480,
        })
        .await;

        assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(body, json!({"error": "too many requests"}));
        assert_eq!(retry_after.as_deref(), Some("3480"));
    }
}

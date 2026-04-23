//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/auth/error.rs.
use axum::http::StatusCode;
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
            AuthError::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
        };

        (status, Json(json!({"error": message}))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;

    async fn error_status_and_body(err: AuthError) -> (StatusCode, serde_json::Value) {
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
    async fn missing_token_returns_401() {
        let (status, body) = error_status_and_body(AuthError::MissingToken).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "missing authorization header"}));
    }

    #[tokio::test]
    async fn invalid_token_returns_401() {
        let (status, body) = error_status_and_body(AuthError::InvalidToken).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "invalid or expired token"}));
    }

    #[tokio::test]
    async fn missing_admin_key_returns_401() {
        let (status, body) = error_status_and_body(AuthError::MissingAdminKey).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "missing admin key"}));
    }

    #[tokio::test]
    async fn invalid_admin_key_returns_401() {
        let (status, body) = error_status_and_body(AuthError::InvalidAdminKey).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, json!({"error": "invalid admin key"}));
    }

    #[tokio::test]
    async fn forbidden_returns_403() {
        let (status, body) = error_status_and_body(AuthError::Forbidden).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body, json!({"error": "forbidden"}));
    }
}

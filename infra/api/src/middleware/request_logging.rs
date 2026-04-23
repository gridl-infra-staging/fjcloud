//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/middleware/request_logging.rs.
use axum::http::Request;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use std::sync::Arc;
use std::time::Duration;
use tower_http::trace::{MakeSpan, OnResponse};
use tracing::Span;

use crate::auth::Claims;

/// Creates a tracing span for each request with request metadata.
#[derive(Clone)]
pub struct RequestSpan {
    jwt_secret: Arc<str>,
}

impl RequestSpan {
    pub fn new(jwt_secret: Arc<str>) -> Self {
        Self { jwt_secret }
    }

    fn extract_tenant_id<B>(&self, request: &Request<B>) -> Option<String> {
        let auth_header = request.headers().get("authorization")?.to_str().ok()?;
        let token = auth_header.strip_prefix("Bearer ")?;
        let token_data = jsonwebtoken::decode::<Claims>(
            token,
            &DecodingKey::from_secret(self.jwt_secret.as_bytes()),
            &Validation::new(Algorithm::HS256),
        )
        .ok()?;
        Some(token_data.claims.sub)
    }
}

impl<B> MakeSpan<B> for RequestSpan {
    /// Creates the per-request tracing span with fields: `request_id` from the
    /// `x-request-id` header (or `"-"`), HTTP method, path, and `tenant_id`
    /// extracted from the JWT `sub` claim (or `"-"` when unauthenticated).
    fn make_span(&mut self, request: &Request<B>) -> Span {
        let request_id = request
            .headers()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("-");
        let tenant_id = self
            .extract_tenant_id(request)
            .unwrap_or_else(|| "-".to_string());

        tracing::info_span!(
            "request",
            request_id = %request_id,
            method = %request.method(),
            path = %request.uri().path(),
            tenant_id = %tenant_id,
        )
    }
}

/// Logs the completed response with status and duration at the appropriate level.
/// 2xx/3xx → INFO, 4xx → WARN, 5xx → ERROR.
#[derive(Clone)]
pub struct ResponseLogger;

impl<B> OnResponse<B> for ResponseLogger {
    /// Logs request completion with status code and `duration_ms`.
    /// Uses INFO for 2xx/3xx, WARN for 4xx, and ERROR for 5xx responses.
    fn on_response(self, response: &axum::http::Response<B>, latency: Duration, span: &Span) {
        let status = response.status().as_u16();
        let duration_ms = latency.as_millis() as u64;

        if status >= 500 {
            span.in_scope(|| {
                tracing::error!(parent: span, status, duration_ms, "request completed");
            });
        } else if status >= 400 {
            span.in_scope(|| {
                tracing::warn!(parent: span, status, duration_ms, "request completed");
            });
        } else {
            span.in_scope(|| {
                tracing::info!(parent: span, status, duration_ms, "request completed");
            });
        }
    }
}

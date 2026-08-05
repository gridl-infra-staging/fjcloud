use axum::{
    extract::{Request, State},
    http::{header, HeaderName, HeaderValue, Method},
    middleware::Next,
    response::{IntoResponse, Response},
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use reqwest::Url;
use std::sync::Arc;
use std::time::Duration;
use subtle::ConstantTimeEq;
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::auth::claims::Claims;
use crate::auth::error::AuthError;
use crate::services::storage::s3_auth::{S3AuthContext, S3AuthService};
use crate::services::storage::s3_error;
use crate::state::AppState;

use super::RateLimiter;

const DEFAULT_CLOUD_CORS_ALLOWED_ORIGIN: &str = "https://cloud.flapjack.foo";
const ROBOTS_HEADER_VALUE: &str =
    "noindex, nofollow, noarchive, nosnippet, noimageindex, noai, noimageai";

pub(super) const TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV: &str =
    "TRUST_PROXY_HEADERS_FOR_RATE_LIMIT";

#[derive(Clone)]
pub(super) struct AuthRateLimitState {
    pub(super) limiter: RateLimiter,
    pub(super) admin_key: Arc<str>,
}

/// State for the tenant rate limit middleware — includes the rate limiter and the JWT secret
/// needed to extract the tenant_id from the Authorization header.
#[derive(Clone)]
pub(super) struct TenantRateLimitState {
    pub(super) limiter: RateLimiter,
    pub(super) jwt_secret: Arc<str>,
}

pub(super) fn auth_rate_limit_rpm_from_env() -> u32 {
    parse_positive_u32_env_var("AUTH_RATE_LIMIT_RPM", super::DEFAULT_AUTH_RATE_LIMIT_RPM)
}

pub(super) fn tenant_rate_limit_rpm_from_env() -> u32 {
    parse_positive_u32_env_var(
        "TENANT_RATE_LIMIT_RPM",
        super::DEFAULT_TENANT_RATE_LIMIT_RPM,
    )
}

pub(super) fn admin_rate_limit_rpm_from_env() -> u32 {
    parse_positive_u32_env_var("ADMIN_RATE_LIMIT_RPM", super::DEFAULT_ADMIN_RATE_LIMIT_RPM)
}

/// Reads a positive `u32` from the environment variable `env_key`.
/// Returns `default_value` when the variable is missing, empty, zero, or unparseable,
/// logging a warning on invalid values.
fn parse_positive_u32_env_var(env_key: &str, default_value: u32) -> u32 {
    match std::env::var(env_key) {
        Ok(value) => match value.trim().parse::<u32>() {
            Ok(parsed) if parsed > 0 => parsed,
            _ => {
                tracing::warn!(
                    env_key = %env_key,
                    value = %value,
                    fallback = default_value,
                    "invalid positive integer env var, using default"
                );
                default_value
            }
        },
        Err(_) => default_value,
    }
}

/// Appends security headers to every response: HSTS with a two-year max-age
/// and `includeSubDomains`, `X-Content-Type-Options: nosniff`,
/// `X-Frame-Options: DENY`, `X-XSS-Protection: 1; mode=block`, and beta
/// crawler controls.
pub(super) async fn security_headers_middleware(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::STRICT_TRANSPORT_SECURITY,
        HeaderValue::from_static("max-age=63072000; includeSubDomains"),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    headers.insert(
        HeaderName::from_static("x-xss-protection"),
        HeaderValue::from_static("1; mode=block"),
    );
    // The site should be accessible to Stripe reviewers and link unfurl bots,
    // but not indexed while public beta copy and product surfaces are changing.
    headers.insert(
        HeaderName::from_static("x-robots-tag"),
        HeaderValue::from_static(ROBOTS_HEADER_VALUE),
    );
    response
}

pub(super) async fn auth_rate_limit_middleware(
    State(rate_state): State<AuthRateLimitState>,
    request: Request,
    next: Next,
) -> Response {
    if is_admin_keyed_register_request(&request, &rate_state.admin_key) {
        tracing::info!("bypassing auth rate limit for admin-keyed canary register request");
        return next.run(request).await;
    }

    let key = extract_ip_key(&request);

    if let Some(retry_after_seconds) = rate_state.limiter.check(&key) {
        return rate_limited_response(retry_after_seconds);
    }

    next.run(request).await
}

fn is_admin_keyed_register_request(request: &Request, admin_key: &str) -> bool {
    if request.uri().path() != "/auth/register" {
        return false;
    }

    let Some(provided) = request.headers().get("x-admin-key") else {
        return false;
    };

    provided.as_bytes().ct_eq(admin_key.as_bytes()).into()
}

/// Per-tenant rate-limit middleware keyed by the `sub` claim in the JWT.
/// Skips rate limiting when the JWT is missing or invalid—the downstream
/// auth extractor will reject the request with 401 instead.
pub(super) async fn tenant_rate_limit_middleware(
    State(rate_state): State<TenantRateLimitState>,
    request: Request,
    next: Next,
) -> Response {
    // Extract tenant_id from the JWT. If the JWT is missing or invalid,
    // skip rate limiting — the handler's auth extractor will return 401.
    let tenant_id = extract_tenant_id_from_jwt(&request, &rate_state.jwt_secret);

    if let Some(tenant_id) = tenant_id {
        if let Some(retry_after_seconds) = rate_state.limiter.check(&tenant_id) {
            return rate_limited_response(retry_after_seconds);
        }
    }

    next.run(request).await
}

/// Extract tenant_id (sub claim) from the Authorization Bearer JWT.
/// Returns None if auth header is missing/malformed or JWT is invalid.
fn extract_tenant_id_from_jwt(request: &Request, jwt_secret: &str) -> Option<String> {
    let auth_header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())?;

    let token = auth_header.strip_prefix("Bearer ")?;

    let token_data = jsonwebtoken::decode::<Claims>(
        token,
        &DecodingKey::from_secret(jwt_secret.as_bytes()),
        &Validation::new(Algorithm::HS256),
    )
    .ok()?;

    Some(token_data.claims.sub)
}

pub(super) async fn admin_rate_limit_middleware(
    State(limiter): State<RateLimiter>,
    request: Request,
    next: Next,
) -> Response {
    let key = extract_ip_key(&request);

    if let Some(retry_after_seconds) = limiter.check(&key) {
        return rate_limited_response(retry_after_seconds);
    }

    next.run(request).await
}

/// Authenticates S3 requests via AWS SigV4 signature verification.
/// Short-circuits if an [`S3AuthContext`] already exists in request extensions
/// (e.g. placed by a test harness), otherwise delegates to
/// [`S3AuthService::authenticate`] and stores the result in extensions.
pub(super) async fn s3_auth_middleware(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Response {
    if request.extensions().get::<S3AuthContext>().is_some() {
        return next.run(request).await;
    }

    let method = request.method().as_str().to_string();
    let uri = request
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| request.uri().path().to_string());
    let resource = request.uri().path().to_string();

    let headers: Vec<(String, String)> = request
        .headers()
        .iter()
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|v| (k.as_str().to_string(), v.to_string()))
        })
        .collect();
    let header_refs: Vec<(&str, &str)> = headers
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();

    let auth_service = S3AuthService::new(
        state.storage_key_repo.clone(),
        state.customer_repo.clone(),
        state.storage_master_key,
    );

    match auth_service.authenticate(&method, &uri, &header_refs).await {
        Ok(ctx) => {
            request.extensions_mut().insert(ctx);
            next.run(request).await
        }
        Err(err) => s3_error::from_auth_error(&err, &resource, "s3-auth").into_response(),
    }
}

pub(super) async fn s3_rate_limit_middleware(
    State(limiter): State<RateLimiter>,
    request: Request,
    next: Next,
) -> Response {
    if let Some(ctx) = request.extensions().get::<S3AuthContext>() {
        let key = ctx.customer_id.to_string();
        if let Some(retry_after) = limiter.check(&key) {
            return s3_rate_limited_response(retry_after);
        }
    }
    next.run(request).await
}

fn s3_rate_limited_response(retry_after_seconds: u64) -> Response {
    let err = s3_error::s3_error_response(
        "SlowDown",
        "Please reduce your request rate.",
        "/",
        "s3-rate-limit",
    );
    response_with_retry_after(err.into_response(), retry_after_seconds)
}

fn trust_proxy_headers_for_rate_limit() -> bool {
    std::env::var(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV)
        .ok()
        .map(|raw| {
            matches!(
                raw.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

/// Resolved client IP, carrying the provenance of the value so downstream
/// consumers can apply the right trust policy.
///
/// Rate limiting only needs a stable bucket key and accepts any of these; the
/// `restrict_sources` authorization boundary in `ApiKeyAuth` requires a
/// transport-verified socket peer and therefore only honors `Socket`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ClientIpResolution {
    /// Socket peer address from `ConnectInfo` — verified by the transport layer
    /// and therefore trustworthy for authorization decisions.
    Socket(std::net::IpAddr),
    /// Value derived from a forwarding header. Only produced when proxy-header
    /// trust is explicitly enabled, and never trustworthy for authorization
    /// because clients can spoof these headers.
    Header(String),
    /// No client IP could be determined.
    Unknown,
}

impl ClientIpResolution {
    /// Bucket key used for rate limiting: the string form of whatever we
    /// resolved, or `"unknown"` when nothing was available.
    pub(crate) fn rate_limit_key(&self) -> String {
        match self {
            Self::Socket(ip) => ip.to_string(),
            Self::Header(value) => value.clone(),
            Self::Unknown => "unknown".to_string(),
        }
    }

    /// The socket-peer IP, if and only if the client IP was verified by the
    /// transport layer (`ConnectInfo`). Header-derived and unknown values
    /// return `None` so authorization can fail closed.
    pub(crate) fn trusted_socket_ip(&self) -> Option<std::net::IpAddr> {
        match self {
            Self::Socket(ip) => Some(*ip),
            Self::Header(_) | Self::Unknown => None,
        }
    }
}

/// Resolve the client IP from request parts, preserving provenance.
///
/// This is the single owner of the client-IP trust policy. Both rate limiting
/// and the `restrict_sources` authorization boundary route through here so
/// there is exactly one place that decides whether a forwarding header may be
/// consulted.
///
/// Security model:
/// - Prefer the socket peer IP when `ConnectInfo` is available.
/// - Do NOT trust forwarding headers by default (spoofable by clients).
/// - Forwarding headers are only consulted when explicitly enabled via
///   TRUST_PROXY_HEADERS_FOR_RATE_LIMIT=1|true|yes|on, and even then the result
///   is tagged `Header` so authorization callers can reject it.
pub(crate) fn extract_client_ip_from_parts(
    headers: &axum::http::HeaderMap,
    extensions: &axum::http::Extensions,
) -> ClientIpResolution {
    if let Some(connect_info) = extensions.get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
    {
        return ClientIpResolution::Socket(connect_info.0.ip());
    }

    if !trust_proxy_headers_for_rate_limit() {
        return ClientIpResolution::Unknown;
    }

    if let Some(forwarded_for) = headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
    {
        if let Some(ip) = forwarded_for
            .rsplit(',')
            .next()
            .map(str::trim)
            .filter(|ip| !ip.is_empty())
        {
            return ClientIpResolution::Header(ip.to_string());
        }
    }

    if let Some(real_ip) = headers
        .get("x-real-ip")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|ip| !ip.is_empty())
    {
        return ClientIpResolution::Header(real_ip.to_string());
    }

    ClientIpResolution::Unknown
}

/// Extract the best-effort client IP key used for rate limiting. Thin delegate
/// to the shared [`extract_client_ip_from_parts`] owner.
fn extract_ip_key(request: &Request) -> String {
    extract_client_ip_from_parts(request.headers(), request.extensions()).rate_limit_key()
}

fn rate_limited_response(retry_after_seconds: u64) -> Response {
    AuthError::RateLimited {
        retry_after_seconds,
    }
    .into_response()
}

fn response_with_retry_after(mut response: Response, retry_after_seconds: u64) -> Response {
    response.headers_mut().insert(
        header::RETRY_AFTER,
        retry_after_header_value(retry_after_seconds),
    );
    response
}

fn retry_after_header_value(retry_after_seconds: u64) -> HeaderValue {
    HeaderValue::from_str(&retry_after_seconds.to_string())
        .unwrap_or_else(|_| HeaderValue::from_static("1"))
}

/// Builds the CORS layer allowing credentialed cross-origin requests.
/// Permits GET, POST, PUT, PATCH, DELETE, and OPTIONS with custom headers
/// (`Authorization`, `Content-Type`, `sentry-trace`, `baggage`).
/// Preflight responses are cached for one hour.
pub(super) fn build_cors_layer(cors_allowed_origins: Option<&str>) -> CorsLayer {
    let allowed_origins = parse_allowed_origins(cors_allowed_origins);

    CorsLayer::new()
        .allow_origin(AllowOrigin::list(allowed_origins))
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            header::CONTENT_TYPE,
            header::AUTHORIZATION,
            HeaderName::from_static("x-admin-key"),
            HeaderName::from_static("x-api-key"),
            HeaderName::from_static("stripe-signature"),
            HeaderName::from_static("x-request-id"),
        ])
        .allow_credentials(true)
        .max_age(Duration::from_secs(3600))
}

fn default_cors_allowed_origins() -> Vec<String> {
    vec![
        super::LOCALHOST_CORS_ALLOWED_ORIGIN.to_string(),
        DEFAULT_CLOUD_CORS_ALLOWED_ORIGIN.to_string(),
    ]
}

/// Parses a comma-separated list of allowed origins into validated `HeaderValue`s.
/// Falls back to `localhost:3000` and `https://{DEFAULT_DNS_DOMAIN}` when the
/// input is `None` or empty.
fn parse_allowed_origins(cors_allowed_origins: Option<&str>) -> Vec<HeaderValue> {
    let configured_origins: Vec<String> = cors_allowed_origins
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|origin| !origin.is_empty())
        .map(str::to_string)
        .collect();

    let origins = if configured_origins.is_empty() {
        default_cors_allowed_origins()
    } else {
        configured_origins
    };

    let parsed: Vec<HeaderValue> = origins
        .iter()
        .filter_map(|origin| match parse_allowed_origin(origin) {
            Some(value) => Some(value),
            None => {
                tracing::warn!(
                    origin = %origin,
                    "ignoring invalid credentialed CORS origin in CORS_ALLOWED_ORIGINS"
                );
                None
            }
        })
        .collect();

    if parsed.is_empty() {
        tracing::warn!("no valid CORS origins configured, falling back to default allowed origins");
        default_cors_allowed_origins()
            .into_iter()
            .map(|origin| {
                HeaderValue::from_str(&origin)
                    .expect("default CORS origins should always be valid header values")
            })
            .collect()
    } else {
        parsed
    }
}

/// Validates a single origin string for use in CORS.
/// Rejects wildcard (`*`), non-HTTP(S) schemes, origins containing
/// userinfo, query strings, or fragment components. Returns `None`
/// for any invalid origin.
fn parse_allowed_origin(origin: &str) -> Option<HeaderValue> {
    if origin == "*" {
        return None;
    }

    let parsed = Url::parse(origin).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    parsed.host_str()?;
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }
    if parsed.path() != "/" || parsed.query().is_some() || parsed.fragment().is_some() {
        return None;
    }

    HeaderValue::from_str(origin).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::extract::ConnectInfo;
    use axum::http::{HeaderValue, Request as HttpRequest, StatusCode};
    use http_body_util::BodyExt;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvVarGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: Option<&str>) -> Self {
            let previous = std::env::var(key).ok();
            // SAFETY: These tests run serially (not in parallel) and each guard
            // restores the previous value on drop.
            unsafe {
                match value {
                    Some(v) => std::env::set_var(key, v),
                    None => std::env::remove_var(key),
                }
            }
            Self { key, previous }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            // SAFETY: See set() above.
            unsafe {
                if let Some(ref value) = self.previous {
                    std::env::set_var(self.key, value);
                } else {
                    std::env::remove_var(self.key);
                }
            }
        }
    }

    fn shared_dns_origin_header() -> HeaderValue {
        HeaderValue::from_static(DEFAULT_CLOUD_CORS_ALLOWED_ORIGIN)
    }

    #[tokio::test]
    async fn rate_limited_response_returns_canonical_generic_429_contract() {
        let response = rate_limited_response(3480);
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(
            response
                .headers()
                .get(header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok()),
            Some("3480")
        );

        let body = Body::new(response.into_body())
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(body, serde_json::json!({"error": "too many requests"}));
    }

    #[test]
    fn extract_ip_key_ignores_forward_headers_by_default() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, None);

        let request = HttpRequest::builder()
            .uri("/auth/login")
            .header("x-forwarded-for", "1.2.3.4, 5.6.7.8")
            .header("x-real-ip", "9.9.9.9")
            .body(Body::empty())
            .expect("request should build");

        assert_eq!(extract_ip_key(&request), "unknown");
    }

    #[test]
    fn extract_ip_key_uses_forward_headers_when_explicitly_enabled() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, Some("1"));

        let request = HttpRequest::builder()
            .uri("/auth/login")
            .header("x-forwarded-for", "1.2.3.4, 5.6.7.8")
            .body(Body::empty())
            .expect("request should build");

        assert_eq!(extract_ip_key(&request), "5.6.7.8");
    }

    /// Verifies that `ConnectInfo` peer address takes priority over
    /// `X-Forwarded-For` headers when both are present.
    #[test]
    fn extract_ip_key_prefers_connect_info_over_headers() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, Some("1"));

        let mut request = HttpRequest::builder()
            .uri("/auth/login")
            .header("x-forwarded-for", "1.2.3.4, 5.6.7.8")
            .body(Body::empty())
            .expect("request should build");

        request.extensions_mut().insert(ConnectInfo(
            "203.0.113.25:44321"
                .parse::<std::net::SocketAddr>()
                .expect("socket addr should parse"),
        ));

        assert_eq!(extract_ip_key(&request), "203.0.113.25");
    }

    /// `ConnectInfo` wins even when spoofable headers are present and trusted:
    /// the socket peer is transport-verified and marked as such.
    #[test]
    fn extract_client_ip_marks_connect_info_as_trusted_socket() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, Some("1"));

        let mut request = HttpRequest::builder()
            .uri("/test")
            .header("x-forwarded-for", "1.2.3.4")
            .body(Body::empty())
            .expect("request should build");
        request.extensions_mut().insert(ConnectInfo(
            "203.0.113.25:44321"
                .parse::<std::net::SocketAddr>()
                .expect("socket addr should parse"),
        ));

        let resolution = extract_client_ip_from_parts(request.headers(), request.extensions());
        assert_eq!(
            resolution,
            ClientIpResolution::Socket("203.0.113.25".parse().expect("ip"))
        );
        assert_eq!(
            resolution.trusted_socket_ip(),
            Some("203.0.113.25".parse().expect("ip")),
            "socket peers must be trusted for authorization"
        );
    }

    /// Forwarding headers are ignored by default: no proxy trust means the
    /// resolution is `Unknown` and carries no trusted IP.
    #[test]
    fn extract_client_ip_ignores_headers_by_default() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, None);

        let request = HttpRequest::builder()
            .uri("/test")
            .header("x-forwarded-for", "1.2.3.4")
            .header("x-real-ip", "9.9.9.9")
            .body(Body::empty())
            .expect("request should build");

        let resolution = extract_client_ip_from_parts(request.headers(), request.extensions());
        assert_eq!(resolution, ClientIpResolution::Unknown);
        assert_eq!(
            resolution.trusted_socket_ip(),
            None,
            "header-only requests must not yield a trusted IP"
        );
    }

    /// With proxy trust enabled, a header-derived value is usable as a rate
    /// limit key but stays tagged `Header`, so authorization callers can reject
    /// it rather than mistaking it for a verified socket peer.
    #[test]
    fn extract_client_ip_marks_trusted_headers_as_header_derived() {
        let _guard = env_lock().lock().expect("env lock poisoned");
        let _env = EnvVarGuard::set(TRUST_PROXY_HEADERS_FOR_RATE_LIMIT_ENV, Some("1"));

        let request = HttpRequest::builder()
            .uri("/test")
            .header("x-forwarded-for", "1.2.3.4, 5.6.7.8")
            .body(Body::empty())
            .expect("request should build");

        let resolution = extract_client_ip_from_parts(request.headers(), request.extensions());
        assert_eq!(
            resolution,
            ClientIpResolution::Header("5.6.7.8".to_string())
        );
        assert_eq!(resolution.rate_limit_key(), "5.6.7.8");
        assert_eq!(
            resolution.trusted_socket_ip(),
            None,
            "header-derived IPs must never be trusted for authorization"
        );
    }

    #[test]
    fn default_cors_origins_include_cloud_flapjack_foo() {
        let expected_origin = "https://cloud.flapjack.foo";
        assert!(
            default_cors_allowed_origins()
                .iter()
                .any(|origin| origin == expected_origin),
            "default CORS origins must include the shared DNS domain"
        );
    }

    #[test]
    fn parse_allowed_origins_falls_back_to_cloud_flapjack_foo() {
        let origins = parse_allowed_origins(None);
        assert!(
            origins.contains(&shared_dns_origin_header()),
            "fallback origins must include https://cloud.flapjack.foo"
        );
    }

    #[test]
    fn parse_allowed_origins_empty_env_falls_back_to_cloud_flapjack_foo() {
        let origins = parse_allowed_origins(Some(""));
        assert!(
            origins.contains(&shared_dns_origin_header()),
            "empty CORS_ALLOWED_ORIGINS must fall back to defaults including https://cloud.flapjack.foo"
        );
    }

    #[test]
    fn parse_allowed_origins_invalid_env_falls_back_to_cloud_flapjack_foo() {
        let origins = parse_allowed_origins(Some("\u{7f}"));
        assert!(
            origins.contains(&shared_dns_origin_header()),
            "invalid CORS_ALLOWED_ORIGINS must fall back to defaults including https://cloud.flapjack.foo"
        );
    }

    #[test]
    fn parse_allowed_origins_uses_explicit_override() {
        let origins = parse_allowed_origins(Some("https://custom.example.com"));
        assert_eq!(origins.len(), 1);
        assert_eq!(
            origins[0],
            HeaderValue::from_static("https://custom.example.com")
        );
    }

    #[test]
    fn parse_allowed_origins_rejects_wildcard_override() {
        let origins = parse_allowed_origins(Some("*"));
        assert!(
            origins.contains(&shared_dns_origin_header()),
            "wildcard CORS_ALLOWED_ORIGINS must fall back to defaults including https://cloud.flapjack.foo"
        );
        assert!(
            !origins.contains(&HeaderValue::from_static("*")),
            "wildcard origin must not be accepted on a credentialed API"
        );
    }

    #[test]
    fn parse_allowed_origins_rejects_non_http_origins() {
        let origins = parse_allowed_origins(Some("file:///tmp/app"));
        assert!(
            origins.contains(&shared_dns_origin_header()),
            "non-http origins must fall back to defaults including https://cloud.flapjack.foo"
        );
    }

    #[test]
    fn parse_allowed_origins_keeps_valid_entries_when_mixed() {
        let origins = parse_allowed_origins(Some(
            "https://good.example.com,*,https://also-good.example.com",
        ));
        assert_eq!(origins.len(), 2);
        assert!(origins.contains(&HeaderValue::from_static("https://good.example.com")));
        assert!(origins.contains(&HeaderValue::from_static("https://also-good.example.com")));
    }
}

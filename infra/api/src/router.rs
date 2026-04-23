use axum::{
    extract::DefaultBodyLimit,
    middleware as axum_middleware,
    routing::{get, put},
    Router,
};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tower_http::catch_panic::CatchPanicLayer;
use tower_http::request_id::{PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::trace::TraceLayer;

use crate::config::Config;
use crate::middleware::metrics::metrics_middleware;
use crate::middleware::{RequestSpan, ResponseLogger, UuidRequestId};
use crate::state::AppState;

mod middleware;
mod route_assembly;

const LOCALHOST_CORS_ALLOWED_ORIGIN: &str = "http://localhost:5173";
const DEFAULT_AUTH_RATE_LIMIT_RPM: u32 = 10;
const DEFAULT_AUTH_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);
const DEFAULT_TENANT_RATE_LIMIT_RPM: u32 = 100;
const DEFAULT_ADMIN_RATE_LIMIT_RPM: u32 = 30;
const DEFAULT_RATE_LIMIT_WINDOW: Duration = Duration::from_secs(60);

/// API key authenticated routes for external API consumers (SDKs, curl).
fn v1_routes() -> Router<AppState> {
    Router::new().route("/discover", get(crate::routes::discovery::discover))
}

/// Internal service routes (same-network service-to-service calls).
/// All routes are gated by `x-internal-key` auth via middleware applied in `build_router_inner`.
fn internal_routes() -> Router<AppState> {
    Router::new()
        .route("/tenant-map", get(crate::routes::internal::tenant_map))
        .route("/regions", get(crate::routes::internal::regions))
        .route(
            "/cold-storage-usage",
            get(crate::routes::internal::cold_storage_usage),
        )
        .route("/metrics", get(crate::routes::internal::metrics))
}

/// Sliding-window rate limiter keyed by an arbitrary string (IP, tenant_id, etc.).
#[derive(Clone)]
pub struct RateLimiter {
    rpm: u32,
    window: Duration,
    state: Arc<Mutex<RateLimiterState>>,
}

struct RateLimiterState {
    requests_by_key: HashMap<String, VecDeque<Instant>>,
    last_cleanup_at: Instant,
}

impl RateLimiter {
    /// Creates a sliding-window rate limiter with the given requests-per-window limit.
    /// Clamps a zero `rpm` to 1 with a warning to prevent division-by-zero panics.
    fn new(rpm: u32, window: Duration) -> Self {
        let effective_rpm = if rpm == 0 {
            tracing::warn!(
                configured_rpm = rpm,
                fallback_rpm = 1u32,
                "invalid zero RPM for rate limiter; clamping to fallback"
            );
            1
        } else {
            rpm
        };

        Self {
            rpm: effective_rpm,
            window,
            state: Arc::new(Mutex::new(RateLimiterState {
                requests_by_key: HashMap::new(),
                last_cleanup_at: Instant::now(),
            })),
        }
    }

    /// Check if a request with the given key is allowed. Returns `None` if allowed
    /// (and records the request), or `Some(retry_after_seconds)` if rate-limited.
    fn check(&self, key: &str) -> Option<u64> {
        let now = Instant::now();
        let window_start = now - self.window;
        let mut state = self.state.lock().unwrap_or_else(|poisoned| {
            tracing::warn!("rate limiter state mutex poisoned, recovering");
            poisoned.into_inner()
        });

        if now.saturating_duration_since(state.last_cleanup_at) >= Duration::from_secs(30) {
            state.requests_by_key.retain(|_, requests| {
                while let Some(oldest) = requests.front() {
                    if *oldest <= window_start {
                        requests.pop_front();
                    } else {
                        break;
                    }
                }
                !requests.is_empty()
            });
            state.last_cleanup_at = now;
        }

        let requests = state.requests_by_key.entry(key.to_string()).or_default();

        while let Some(oldest) = requests.front() {
            if *oldest <= window_start {
                requests.pop_front();
            } else {
                break;
            }
        }

        if requests.len() >= self.rpm as usize {
            let oldest = requests
                .front()
                .copied()
                .expect("request queue should not be empty when at limit");
            let elapsed = now.saturating_duration_since(oldest);
            let retry_after = self.window.saturating_sub(elapsed).as_secs().max(1);
            return Some(retry_after);
        }

        requests.push_back(now);
        None
    }
}

/// Configuration for all rate limiters in the router.
pub struct RateLimitConfig {
    pub auth_rpm: u32,
    pub auth_window: Duration,
    /// Per-tenant RPM limit. `None` disables tenant rate limiting.
    pub tenant_rpm: Option<u32>,
    pub tenant_window: Duration,
    /// Per-IP admin RPM limit. `None` disables admin rate limiting.
    pub admin_rpm: Option<u32>,
    pub admin_window: Duration,
}

impl RateLimitConfig {
    fn from_env() -> Self {
        Self {
            auth_rpm: middleware::auth_rate_limit_rpm_from_env(),
            auth_window: DEFAULT_AUTH_RATE_LIMIT_WINDOW,
            tenant_rpm: Some(middleware::tenant_rate_limit_rpm_from_env()),
            tenant_window: DEFAULT_RATE_LIMIT_WINDOW,
            admin_rpm: Some(middleware::admin_rate_limit_rpm_from_env()),
            admin_window: DEFAULT_RATE_LIMIT_WINDOW,
        }
    }

    fn auth_only(rpm: u32, window: Duration) -> Self {
        Self {
            auth_rpm: rpm,
            auth_window: window,
            tenant_rpm: None,
            tenant_window: DEFAULT_RATE_LIMIT_WINDOW,
            admin_rpm: None,
            admin_window: DEFAULT_RATE_LIMIT_WINDOW,
        }
    }
}

pub fn build_router(state: AppState) -> Router {
    let cors_allowed_origins = std::env::var("CORS_ALLOWED_ORIGINS").ok();
    build_router_with_cors(state, cors_allowed_origins.as_deref())
}

pub fn build_router_with_cors(state: AppState, cors_allowed_origins: Option<&str>) -> Router {
    build_router_inner(state, cors_allowed_origins, RateLimitConfig::from_env())
}

/// Build a router with explicit auth rate limit config. Used in tests to set a short window.
pub fn build_router_with_auth_rate_config(state: AppState, rpm: u32, window: Duration) -> Router {
    build_router_inner(state, None, RateLimitConfig::auth_only(rpm, window))
}

/// Build a router with full rate limit configuration. Used in tests for tenant/admin rate limit tests.
pub fn build_router_with_rate_config(state: AppState, config: RateLimitConfig) -> Router {
    build_router_inner(state, None, config)
}

pub fn build_s3_router(state: AppState, cfg: &Config) -> Router {
    use crate::routes::storage::{buckets, objects};

    let rate_limiter = RateLimiter::new(cfg.s3_rate_limit_rps, Duration::from_secs(1));

    Router::new()
        .route("/", get(buckets::list_buckets))
        .route(
            "/:bucket",
            put(buckets::create_bucket)
                .head(buckets::head_bucket)
                .delete(buckets::delete_bucket)
                .get(buckets::list_objects_v2),
        )
        .route(
            "/:bucket/*key",
            put(objects::put_object)
                .get(objects::get_object)
                .delete(objects::delete_object)
                .head(objects::head_object),
        )
        .with_state(state.clone())
        .layer(axum_middleware::from_fn_with_state(
            rate_limiter,
            middleware::s3_rate_limit_middleware,
        ))
        .layer(axum_middleware::from_fn_with_state(
            state,
            middleware::s3_auth_middleware,
        ))
        .layer(axum_middleware::from_fn(
            middleware::security_headers_middleware,
        ))
        .layer(DefaultBodyLimit::max(100_000_000))
}

fn build_router_inner(
    state: AppState,
    cors_allowed_origins: Option<&str>,
    rate_config: RateLimitConfig,
) -> Router {
    let request_span = RequestSpan::new(state.jwt_secret.clone());
    let metrics_collector = state.metrics_collector.clone();
    let auth_rate_limiter = RateLimiter::new(rate_config.auth_rpm, rate_config.auth_window);
    let auth_rate_limited_routes =
        route_assembly::build_auth_rate_limited_routes(auth_rate_limiter);
    let tenant_routes = route_assembly::build_tenant_routes(&state, &rate_config);
    let router = route_assembly::build_router_without_layers(
        &state,
        auth_rate_limited_routes,
        tenant_routes,
    );
    let router = route_assembly::nest_admin_routes_with_optional_rate_limit(router, &rate_config);

    router
        .with_state(state)
        .layer(CatchPanicLayer::new())
        .layer(axum_middleware::from_fn(
            middleware::security_headers_middleware,
        ))
        .layer(axum_middleware::from_fn_with_state(
            metrics_collector,
            metrics_middleware,
        ))
        .layer(middleware::build_cors_layer(cors_allowed_origins))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(request_span)
                .on_response(ResponseLogger),
        )
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::x_request_id(UuidRequestId))
}

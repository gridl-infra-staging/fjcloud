//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/metering-agent/src/health.rs.
use std::sync::{Arc, Mutex};

use axum::{extract::State, routing::get, Json, Router};
use chrono::{DateTime, Utc};
use serde::Serialize;
use tokio::net::TcpListener;

/// Shared health state updated by the scrape and storage poll loops.
#[derive(Debug, Clone)]
pub struct HealthState {
    pub last_scrape_at: Option<DateTime<Utc>>,
    pub last_storage_poll_at: Option<DateTime<Utc>>,
}

impl HealthState {
    pub fn new() -> Self {
        Self {
            last_scrape_at: None,
            last_storage_poll_at: None,
        }
    }
}

impl Default for HealthState {
    fn default() -> Self {
        Self::new()
    }
}

/// Thread-safe handle to health state, shared between main loops and HTTP handler.
pub type SharedHealthState = Arc<Mutex<HealthState>>;

#[derive(Serialize)]
struct HealthResponse {
    status: String,
    last_scrape_at: Option<String>,
    last_storage_poll_at: Option<String>,
}

async fn health_handler(State(state): State<SharedHealthState>) -> Json<HealthResponse> {
    let guard = match state.lock() {
        Ok(g) => g,
        Err(poisoned) => {
            tracing::warn!("health state mutex poisoned, recovering");
            poisoned.into_inner()
        }
    };
    Json(HealthResponse {
        status: "ok".to_string(),
        last_scrape_at: guard.last_scrape_at.map(|t| t.to_rfc3339()),
        last_storage_poll_at: guard.last_storage_poll_at.map(|t| t.to_rfc3339()),
    })
}

/// Build the health router.
pub fn health_router(state: SharedHealthState) -> Router {
    Router::new()
        .route("/health", get(health_handler))
        .with_state(state)
}

/// Spawn the health HTTP server on the given port. Returns when shutdown signal fires.
pub async fn serve_health(
    port: u16,
    state: SharedHealthState,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let app = health_router(state);
    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr)
        .await
        .expect("health port bind failed");
    tracing::info!(port, "health endpoint listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            let _ = shutdown.wait_for(|&v| v).await;
        })
        .await
        .expect("health server failed");
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn make_state() -> SharedHealthState {
        Arc::new(Mutex::new(HealthState::new()))
    }

    /// Guards the baseline health response: `GET /health` on a freshly
    /// initialised agent must return HTTP 200 with `{"status":"ok"}` and null
    /// timestamps for both `last_scrape_at` and `last_storage_poll_at`.
    ///
    /// Null timestamps are expected because neither loop has run yet.
    #[tokio::test]
    async fn health_returns_200_with_status_ok() {
        let state = make_state();
        let app = health_router(state);

        let req = axum::http::Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), 200);

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

        assert_eq!(json["status"], "ok");
        assert!(json["last_scrape_at"].is_null());
        assert!(json["last_storage_poll_at"].is_null());
    }

    /// Guards that the health endpoint reflects mutations to the shared state
    /// written by the scrape and storage-poll loops.
    ///
    /// After writing timestamps to the `SharedHealthState` the next request
    /// must return non-null RFC 3339 strings for both `last_scrape_at` and
    /// `last_storage_poll_at`.  This ensures the health handler reads the
    /// live state rather than a snapshot captured at startup.
    #[tokio::test]
    async fn health_reflects_updated_timestamps() {
        let state = make_state();
        let now = Utc::now();

        {
            let mut guard = state.lock().unwrap();
            guard.last_scrape_at = Some(now);
            guard.last_storage_poll_at = Some(now);
        }

        let app = health_router(state);
        let req = axum::http::Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), 200);

        let body = resp.into_body().collect().await.unwrap().to_bytes();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

        assert_eq!(json["status"], "ok");
        assert!(json["last_scrape_at"].is_string());
        assert!(json["last_storage_poll_at"].is_string());
    }

    #[test]
    fn default_matches_new_state() {
        let from_new = HealthState::new();
        let from_default = HealthState::default();

        assert_eq!(from_default.last_scrape_at, from_new.last_scrape_at);
        assert_eq!(
            from_default.last_storage_poll_at,
            from_new.last_storage_poll_at
        );
    }
}

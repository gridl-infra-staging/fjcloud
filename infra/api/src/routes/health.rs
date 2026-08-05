use axum::Json;
use serde::Serialize;
use utoipa::ToSchema;

/// Liveness response for the public `GET /health` probe.
#[derive(Debug, Serialize, ToSchema)]
pub struct HealthResponse {
    /// Always `"ok"` while the API process is serving requests.
    pub status: String,
}

#[utoipa::path(
    get,
    path = "/health",
    tag = "Health",
    security(()),
    responses(
        (status = 200, description = "Service is live", body = HealthResponse),
    )
)]
pub async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok".to_string(),
    })
}

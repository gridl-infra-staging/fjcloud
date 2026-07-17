use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use pricing_calculator::types::WorkloadProfile;

/// POST /pricing/compare — compare pricing across providers for a workload profile.
/// Public endpoint (no authentication required).
#[utoipa::path(
    post,
    path = "/pricing/compare",
    tag = "Pricing",
    security(()),
    request_body(content = serde_json::Value, description = "Workload profile for pricing comparison"),
    responses(
        (status = 200, description = "Pricing comparison results", body = serde_json::Value),
        (status = 400, description = "Invalid workload profile", body = crate::errors::ErrorResponse),
    )
)]
pub async fn compare(
    Json(workload): Json<WorkloadProfile>,
) -> Result<impl IntoResponse, impl IntoResponse> {
    pricing_calculator::compare_all(&workload)
        .map(Json)
        .map_err(|error| {
            (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({ "error": error.to_string() })),
            )
        })
}

use super::*;

/// POST /indexes/:name/recommendations
#[utoipa::path(
    post,
    path = "/indexes/{name}/recommendations",
    tag = "Recommendations",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Recommendation results", body = serde_json::Value),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 410, description = "Index is in cold storage", body = ErrorResponse),
        (status = 503, description = "Index is restoring or endpoint not ready", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn recommend(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(body): Json<serde_json::Value>,
) -> Result<impl IntoResponse, ApiError> {
    if !body.is_object() {
        return Err(ApiError::BadRequest(
            "recommendations request must be a JSON object".into(),
        ));
    }

    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let result = state
        .flapjack_proxy
        .recommend(&target.flapjack_url, &target.node_id, &target.region, body)
        .await?;

    Ok(Json(result))
}

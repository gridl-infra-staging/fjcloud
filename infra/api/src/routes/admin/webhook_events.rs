use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct GetWebhookEventQuery {
    pub stripe_event_id: Option<String>,
}

fn required_stripe_event_id(query: GetWebhookEventQuery) -> Result<String, ApiError> {
    query
        .stripe_event_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| ApiError::BadRequest("stripe_event_id query parameter is required".into()))
}

/// `GET /admin/webhook-events?stripe_event_id=<id>` — fetch one persisted webhook row.
pub async fn get_webhook_event(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Query(query): Query<GetWebhookEventQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_event_id = required_stripe_event_id(query)?;
    let row = state
        .webhook_event_repo
        .find_by_stripe_event_id(&stripe_event_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("webhook event not found".to_string()))?;

    Ok(Json(row))
}

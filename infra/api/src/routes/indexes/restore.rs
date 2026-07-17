//! Customer restore endpoints for cold indexes.
use super::*;
use crate::services::restore::RestoreError;

fn map_restore_error(error: RestoreError, index_name: &str) -> ApiError {
    match error {
        RestoreError::NotCold => ApiError::BadRequest("index is not in cold storage".into()),
        RestoreError::NotFound => ApiError::NotFound(format!("index '{index_name}' not found")),
        RestoreError::AtLimit => {
            ApiError::BadRequest("restore capacity reached, try again later".into())
        }
        RestoreError::DestinationConflict | RestoreError::DestinationChanged => {
            ApiError::Conflict(error.to_string())
        }
        other => ApiError::Internal(other.to_string()),
    }
}

/// POST /indexes/:name/restore — initiate restore of a cold index
#[utoipa::path(
    post,
    path = "/indexes/{name}/restore",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 202, description = "Restore initiated", body = serde_json::Value),
        (status = 400, description = "Index is not in cold storage", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 429, description = "Maximum concurrent restores reached", body = serde_json::Value),
    )
)]
pub async fn restore_index(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let restore_service = state
        .restore_service
        .as_ref()
        .ok_or_else(|| ApiError::Internal("restore service not configured".into()))?
        .clone();

    match restore_service
        .initiate_restore(auth.customer_id, &name)
        .await
    {
        Ok(response) => {
            if response.created_new_job {
                let restore_task_service = restore_service.clone();
                let job_id = response.job_id;
                tokio::spawn(async move {
                    restore_task_service.execute_restore(job_id).await;
                });
            }

            Ok((
                StatusCode::ACCEPTED,
                Json(serde_json::json!({
                    "restore_job_id": response.job_id,
                    "status": response.status,
                    "poll_url": format!("/indexes/{}/restore-status", name)
                })),
            )
                .into_response())
        }
        Err(RestoreError::NotCold) => Err(map_restore_error(RestoreError::NotCold, &name)),
        Err(RestoreError::NotFound) => Err(map_restore_error(RestoreError::NotFound, &name)),
        Err(RestoreError::AtLimit) => {
            let mut response = (
                StatusCode::TOO_MANY_REQUESTS,
                Json(serde_json::json!({
                    "error": "restore_capacity_reached",
                    "message": "Maximum concurrent restores reached. Try again later."
                })),
            )
                .into_response();
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, header::HeaderValue::from_static("60"));
            Ok(response)
        }
        Err(RestoreError::DestinationConflict) => {
            Err(map_restore_error(RestoreError::DestinationConflict, &name))
        }
        Err(RestoreError::DestinationChanged) => {
            Err(map_restore_error(RestoreError::DestinationChanged, &name))
        }
        Err(e) => Err(ApiError::Internal(e.to_string())),
    }
}

/// GET /indexes/:name/restore-status — poll restore status
#[utoipa::path(
    get,
    path = "/indexes/{name}/restore-status",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Restore status", body = serde_json::Value),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found or no restore job", body = ErrorResponse),
    )
)]
pub async fn restore_status(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let restore_service = state
        .restore_service
        .as_ref()
        .ok_or_else(|| ApiError::Internal("restore service not configured".into()))?;

    match restore_service
        .get_restore_status(auth.customer_id, &name)
        .await
    {
        Ok(Some(status)) => Ok(Json(serde_json::json!({
            "restore_job_id": status.job.id,
            "status": status.job.status,
            "started_at": status.job.started_at,
            "completed_at": status.job.completed_at,
            "estimated_completion_at": status.estimated_completion_at,
            "error": status.job.error
        }))),
        Ok(None) => Err(ApiError::NotFound(
            "no active restore for this index".into(),
        )),
        Err(e) => Err(ApiError::Internal(e.to_string())),
    }
}

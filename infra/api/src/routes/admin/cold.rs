use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::state::AppState;

/// GET /admin/cold — list all cold indexes with full snapshot metadata
pub async fn list_cold_snapshots(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let cold_tenants = state
        .tenant_repo
        .list_active_global()
        .await?
        .into_iter()
        .filter(|t| t.tier == "cold")
        .collect::<Vec<_>>();

    let mut entries = Vec::new();

    for tenant in &cold_tenants {
        let snapshot = match tenant.cold_snapshot_id {
            Some(sid) => state.cold_snapshot_repo.get(sid).await?,
            None => None,
        };

        let (snapshot_id, size_bytes, status, object_key, cold_since) = match &snapshot {
            Some(s) => (
                Some(s.id),
                s.size_bytes,
                s.status.as_str(),
                Some(s.object_key.as_str()),
                s.completed_at.map(|ts| ts.to_rfc3339()),
            ),
            None => (None, 0, "unknown", None, None),
        };

        entries.push(serde_json::json!({
            "customer_id": tenant.customer_id,
            "tenant_id": tenant.tenant_id,
            "snapshot_id": snapshot_id,
            "size_bytes": size_bytes,
            "status": status,
            "object_key": object_key,
            "cold_since": cold_since,
            "last_accessed_at": tenant.last_accessed_at,
        }));
    }

    Ok(Json(entries))
}

/// GET /admin/cold/:snapshot_id — snapshot detail with full metadata
pub async fn get_cold_snapshot(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(snapshot_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let snapshot = state
        .cold_snapshot_repo
        .get(snapshot_id)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("snapshot {snapshot_id} not found")))?;

    Ok(Json(serde_json::json!({
        "id": snapshot.id,
        "customer_id": snapshot.customer_id,
        "tenant_id": snapshot.tenant_id,
        "source_vm_id": snapshot.source_vm_id,
        "object_key": snapshot.object_key,
        "size_bytes": snapshot.size_bytes,
        "checksum": snapshot.checksum,
        "status": snapshot.status,
        "error": snapshot.error,
        "created_at": snapshot.created_at.to_rfc3339(),
        "completed_at": snapshot.completed_at.map(|ts| ts.to_rfc3339()),
        "expires_at": snapshot.expires_at.map(|ts| ts.to_rfc3339()),
    })))
}

/// POST /admin/cold/:snapshot_id/restore — admin-triggered restore
pub async fn admin_restore(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(snapshot_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let restore_service = state
        .restore_service
        .as_ref()
        .ok_or_else(|| ApiError::Internal("restore service not configured".into()))?
        .clone();

    // Find the tenant that owns this snapshot
    let tenants = state.tenant_repo.list_active_global().await?;
    let tenant = tenants
        .iter()
        .find(|t| t.cold_snapshot_id == Some(snapshot_id))
        .ok_or_else(|| {
            ApiError::NotFound(format!("no cold tenant found for snapshot {snapshot_id}"))
        })?;

    match restore_service
        .initiate_restore(tenant.customer_id, &tenant.tenant_id)
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
                })),
            )
                .into_response())
        }
        Err(crate::services::restore::RestoreError::NotCold) => {
            Err(ApiError::BadRequest("index is not in cold storage".into()))
        }
        Err(crate::services::restore::RestoreError::AtLimit) => Err(ApiError::BadRequest(
            "restore capacity reached, try again later".into(),
        )),
        Err(e) => Err(ApiError::Internal(e.to_string())),
    }
}

use super::*;
use crate::services::engine_index_identity_observer::record_caller;

pub(super) fn map_replica_error(error: ReplicaError) -> ApiError {
    match error {
        ReplicaError::IndexNotFound | ReplicaError::ReplicaNotFound => {
            ApiError::NotFound(error.to_string())
        }
        ReplicaError::RegionNotAvailable(_)
        | ReplicaError::SameRegionAsPrimary
        | ReplicaError::NoCapacityInRegion(_)
        | ReplicaError::NoPrimaryVm => ApiError::BadRequest(error.to_string()),
        ReplicaError::LimitReached(_) | ReplicaError::AlreadyExistsInRegion(_) => {
            ApiError::Conflict(error.to_string())
        }
        ReplicaError::DestinationConflict | ReplicaError::DestinationChanged => {
            ApiError::Conflict(error.to_string())
        }
        ReplicaError::Repo(message) => ApiError::Internal(message),
    }
}

/// POST /indexes/:name/replicas — create a read replica in another region
#[utoipa::path(
    post,
    path = "/indexes/{name}/replicas",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    request_body = CreateReplicaRequest,
    responses(
        (status = 201, description = "Replica created", body = crate::models::index_replica::CustomerIndexReplicaSummary),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn create_replica(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<CreateReplicaRequest>,
) -> Result<impl IntoResponse, ApiError> {
    record_caller("routes.indexes.lifecycle.create_replica");
    let created = state
        .replica_service
        .create_replica(auth.customer_id, &name, &req.region)
        .await
        .map_err(map_replica_error)?;

    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    let summary = summaries
        .into_iter()
        .find(|r| r.id == created.id)
        .ok_or_else(|| ApiError::Internal("replica created but summary missing".to_string()))?;

    Ok((StatusCode::CREATED, Json(summary.to_customer_summary())))
}

/// GET /indexes/:name/replicas — list read replicas for an index
#[utoipa::path(
    get,
    path = "/indexes/{name}/replicas",
    tag = "Indexes",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "List of replicas", body = [crate::models::index_replica::CustomerIndexReplicaSummary]),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
    )
)]
pub async fn list_replicas(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    record_caller("routes.indexes.lifecycle.list_replicas");
    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    let customer_summaries: Vec<_> = summaries.iter().map(|s| s.to_customer_summary()).collect();
    Ok(Json(customer_summaries))
}

/// DELETE /indexes/:name/replicas/:replica_id — remove a read replica
#[utoipa::path(
    delete,
    path = "/indexes/{name}/replicas/{replica_id}",
    tag = "Indexes",
    params(
        ("name" = String, Path, description = "Index name"),
        ("replica_id" = Uuid, Path, description = "Replica ID"),
    ),
    responses(
        (status = 204, description = "Replica deleted"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Replica not found", body = ErrorResponse),
    )
)]
pub async fn delete_replica(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path((name, replica_id)): Path<(String, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    record_caller("routes.indexes.lifecycle.delete_replica");
    let summaries = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(map_replica_error)?;
    if !summaries.iter().any(|r| r.id == replica_id) {
        return Err(ApiError::NotFound(format!(
            "replica {replica_id} not found for index {name}"
        )));
    }

    state
        .replica_service
        .remove_replica(auth.customer_id, replica_id)
        .await
        .map_err(map_replica_error)?;

    Ok(StatusCode::NO_CONTENT)
}

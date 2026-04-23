use axum::extract::{Query, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ReplicaListParams {
    pub status: Option<String>,
}

/// GET /admin/replicas — list all replicas across the fleet with optional status filter.
pub async fn list_replicas(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Query(params): Query<ReplicaListParams>,
) -> Result<impl IntoResponse, ApiError> {
    let all_replicas = state.index_replica_repo.list_all().await?;

    let filtered = match &params.status {
        Some(status) => all_replicas
            .into_iter()
            .filter(|r| {
                // "syncing" filter includes legacy "replicating" status (semantic equivalent)
                if status == "syncing" {
                    r.status == "syncing" || r.status == "replicating"
                } else {
                    r.status == *status
                }
            })
            .collect::<Vec<_>>(),
        None => all_replicas,
    };

    // Enrich with VM hostnames by looking up primary and replica VMs
    let mut entries = Vec::with_capacity(filtered.len());
    for replica in &filtered {
        let primary_vm = state.vm_inventory_repo.get(replica.primary_vm_id).await?;
        let replica_vm = state.vm_inventory_repo.get(replica.replica_vm_id).await?;

        entries.push(serde_json::json!({
            "id": replica.id,
            "customer_id": replica.customer_id,
            "tenant_id": replica.tenant_id,
            "replica_region": replica.replica_region,
            "status": replica.status,
            "lag_ops": replica.lag_ops,
            "primary_vm_id": replica.primary_vm_id,
            "primary_vm_hostname": primary_vm.as_ref().map(|v| v.hostname.as_str()).unwrap_or("unknown"),
            "primary_vm_region": primary_vm.as_ref().map(|v| v.region.as_str()).unwrap_or("unknown"),
            "replica_vm_id": replica.replica_vm_id,
            "replica_vm_hostname": replica_vm.as_ref().map(|v| v.hostname.as_str()).unwrap_or("unknown"),
            "created_at": replica.created_at.to_rfc3339(),
            "updated_at": replica.updated_at.to_rfc3339(),
        }));
    }

    Ok(Json(entries))
}

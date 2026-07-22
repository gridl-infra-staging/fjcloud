use std::collections::HashMap;

use axum::extract::{Path, State};
use axum::Json;
use chrono::Utc;
use serde::Serialize;
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::models::vm_inventory::VmInventory;
use crate::services::public_topology::{
    to_public_topology, UtilizationBucket, PUBLIC_TOPOLOGY_MIN_REFRESH_INTERVAL_SECS,
};
use crate::state::{AppState, CustomerIndexMetricsResponse};

use super::index_metrics_route::load_customer_index_metrics;

const INFRASTRUCTURE_METRICS_CALLER_ID: &str =
    "routes.indexes.infrastructure.get_index_infrastructure";

#[derive(Debug, Clone, Serialize, utoipa::ToSchema)]
pub struct IndexInfrastructureResponse {
    pub index: String,
    pub primary: InfrastructurePrimary,
    pub replicas: Vec<InfrastructureReplica>,
    pub footprint: InfrastructureFootprint,
    pub headroom: HeadroomStatus,
    pub minimum_refresh_interval_seconds: u64,
}

#[derive(Debug, Clone, Serialize, utoipa::ToSchema)]
pub struct InfrastructurePrimary {
    pub region: String,
    pub status: String,
    #[schema(required)]
    pub utilization: Option<UtilizationBucket>,
}

#[derive(Debug, Clone, Serialize, utoipa::ToSchema)]
pub struct InfrastructureReplica {
    pub region: String,
    pub status: String,
    pub lag_ops: i64,
    #[schema(required)]
    pub utilization: Option<UtilizationBucket>,
}

#[derive(Debug, Clone, Serialize, utoipa::ToSchema)]
pub struct InfrastructureFootprint {
    pub documents_count: u64,
    pub storage_bytes: u64,
    pub search_requests_total: u64,
    pub write_operations_total: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum HeadroomStatus {
    Comfortable,
    Busy,
    ApproachingLimits,
}

#[utoipa::path(
    get,
    path = "/indexes/{name}/infrastructure",
    tag = "Index Infrastructure",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Index infrastructure", body = IndexInfrastructureResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 503, description = "Backend temporarily unavailable", body = ErrorResponse),
    )
)]
pub async fn get_index_infrastructure(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<Json<IndexInfrastructureResponse>, ApiError> {
    let (summary, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;
    let footprint = load_customer_index_metrics(
        &state,
        auth.customer_id,
        &name,
        &target,
        INFRASTRUCTURE_METRICS_CALLER_ID,
    )
    .await?;
    let quota = super::resolve_index_quota(&state, auth.customer_id, &name).await?;
    let replicas = state
        .replica_service
        .list_replicas(auth.customer_id, &name)
        .await
        .map_err(super::replicas::map_replica_error)?;

    let primary_vm = state.vm_inventory_repo.get(target.vm_id).await?;
    let mut ordered_vms = Vec::new();
    if let Some(vm) = primary_vm {
        ordered_vms.push((target.vm_id, vm));
    }

    for replica in &replicas {
        if let Some(vm) = state.vm_inventory_repo.get(replica.replica_vm_id).await? {
            ordered_vms.push((replica.replica_vm_id, vm));
        }
    }

    let utilization_by_vm_id = utilization_by_vm_id(&ordered_vms);
    let infrastructure_footprint = InfrastructureFootprint::from(footprint);
    let response = IndexInfrastructureResponse {
        index: name,
        primary: InfrastructurePrimary {
            region: summary.region,
            status: summary.health_status,
            utilization: utilization_by_vm_id.get(&target.vm_id).copied().flatten(),
        },
        replicas: replicas
            .into_iter()
            .map(|replica| InfrastructureReplica {
                region: replica.replica_region,
                status: replica.status,
                lag_ops: replica.lag_ops,
                utilization: utilization_by_vm_id
                    .get(&replica.replica_vm_id)
                    .copied()
                    .flatten(),
            })
            .collect(),
        headroom: headroom_status(&infrastructure_footprint, quota.max_storage_bytes),
        footprint: infrastructure_footprint,
        minimum_refresh_interval_seconds: PUBLIC_TOPOLOGY_MIN_REFRESH_INTERVAL_SECS,
    };

    Ok(Json(response))
}

fn utilization_by_vm_id(vms: &[(Uuid, VmInventory)]) -> HashMap<Uuid, Option<UtilizationBucket>> {
    let vm_refs = vms.iter().map(|(_, vm)| vm).collect::<Vec<_>>();
    let views = to_public_topology(&vm_refs, Utc::now());
    vms.iter()
        .map(|(vm_id, _)| *vm_id)
        .zip(views.into_iter().map(|view| view.utilization))
        .collect()
}

fn headroom_status(footprint: &InfrastructureFootprint, max_storage_bytes: u64) -> HeadroomStatus {
    let used = u128::from(footprint.storage_bytes) * 100;
    let max = u128::from(max_storage_bytes);
    if used < max * 50 {
        HeadroomStatus::Comfortable
    } else if used <= max * 80 {
        HeadroomStatus::Busy
    } else {
        HeadroomStatus::ApproachingLimits
    }
}

impl From<CustomerIndexMetricsResponse> for InfrastructureFootprint {
    fn from(metrics: CustomerIndexMetricsResponse) -> Self {
        Self {
            documents_count: metrics.documents_count,
            storage_bytes: metrics.storage_bytes,
            search_requests_total: metrics.search_requests_total,
            write_operations_total: metrics.write_operations_total,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headroom_status_boundaries_use_storage_ratio_only() {
        let footprint = |storage_bytes, search_requests_total, write_operations_total| {
            InfrastructureFootprint {
                documents_count: 1,
                storage_bytes,
                search_requests_total,
                write_operations_total,
            }
        };

        assert_eq!(
            headroom_status(&footprint(49, 1_000_000, 1_000_000), 100),
            HeadroomStatus::Comfortable
        );
        assert_eq!(
            headroom_status(&footprint(50, 1, 1), 100),
            HeadroomStatus::Busy
        );
        assert_eq!(
            headroom_status(&footprint(80, 1, 1), 100),
            HeadroomStatus::Busy
        );
        assert_eq!(
            headroom_status(&footprint(81, 0, 0), 100),
            HeadroomStatus::ApproachingLimits
        );
        assert_eq!(
            headroom_status(&footprint(80, 1, 1), 100),
            headroom_status(&footprint(80, u64::MAX, u64::MAX), 100)
        );
    }
}

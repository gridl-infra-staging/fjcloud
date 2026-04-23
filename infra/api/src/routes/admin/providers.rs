//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/providers.rs.
use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::state::AppState;

#[derive(Debug, Serialize)]
pub struct ProviderSummaryResponse {
    pub provider: String,
    pub region_count: usize,
    pub regions: Vec<String>,
    pub vm_count: usize,
}

/// `GET /admin/providers` — list VM providers with region and active VM counts.
///
/// **Auth:** `AdminAuth`.
/// Aggregates regions from `region_config` and counts active VMs per provider
/// from `vm_inventory_repo`. Read-only summary endpoint.
pub async fn list_providers(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let mut regions_by_provider: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (region_id, entry) in state.region_config.all_regions() {
        regions_by_provider
            .entry(entry.provider.clone())
            .or_default()
            .push(region_id.clone());
    }

    for regions in regions_by_provider.values_mut() {
        regions.sort();
    }

    let active_vms = state.vm_inventory_repo.list_active(None).await?;
    let mut vm_counts: HashMap<String, usize> = HashMap::new();
    for vm in active_vms {
        *vm_counts.entry(vm.provider).or_insert(0) += 1;
    }

    let summaries: Vec<ProviderSummaryResponse> = regions_by_provider
        .into_iter()
        .map(|(provider, regions)| ProviderSummaryResponse {
            vm_count: vm_counts.get(&provider).copied().unwrap_or(0),
            region_count: regions.len(),
            regions,
            provider,
        })
        .collect();

    Ok(Json(summaries))
}

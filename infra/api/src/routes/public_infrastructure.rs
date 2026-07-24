use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

use crate::errors::ApiError;
use crate::provisioner::region_map::{RegionConfig, RegionEntry};
use crate::repos::{DeploymentRepo, TenantRepo, VmInventoryRepo};
use crate::services::public_topology::{to_public_topology, UtilizationBucket};
use crate::services::vm_health_rollup::{health_rollup_from_deployment_healths, VmHealth};
use crate::state::AppState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, utoipa::ToSchema)]
#[serde(rename_all = "lowercase")]
pub enum PublicRegionHealth {
    Operational,
    Degraded,
    Outage,
    Unknown,
}

#[derive(Debug, Clone, Copy)]
struct RegionVmSignal {
    health: VmHealth,
    utilization: Option<UtilizationBucket>,
}

#[derive(Debug, Clone, PartialEq, Serialize, utoipa::ToSchema)]
pub struct PublicRegionInfrastructure {
    pub region: String,
    pub provider: String,
    pub display_name: String,
    pub provider_location: String,
    pub health: PublicRegionHealth,
    pub utilization: Option<UtilizationBucket>,
    pub vm_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, utoipa::ToSchema)]
pub struct PublicInfrastructureOverall {
    pub availability_pct: Option<f64>,
    pub total_regions: usize,
    pub total_vms: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, utoipa::ToSchema)]
pub struct PublicInfrastructureResponse {
    pub regions: Vec<PublicRegionInfrastructure>,
    pub overall: PublicInfrastructureOverall,
}

#[utoipa::path(
    get,
    path = "/public/infrastructure",
    tag = "Public",
    security(()),
    responses(
        (status = 200, description = "Public infrastructure health by region", body = PublicInfrastructureResponse),
        (status = 500, description = "Internal server error", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_public_infrastructure(
    State(state): State<AppState>,
) -> Result<Json<PublicInfrastructureResponse>, ApiError> {
    if let Some(response) = state.public_infrastructure_cache.get() {
        return Ok(Json(response));
    }

    let response = compute_public_infrastructure(
        state.vm_inventory_repo.as_ref(),
        state.tenant_repo.as_ref(),
        state.deployment_repo.as_ref(),
        &state.region_config,
        Utc::now(),
    )
    .await?;
    state.public_infrastructure_cache.insert(response.clone());
    Ok(Json(response))
}

pub async fn compute_public_infrastructure(
    vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
    tenant_repo: &(dyn TenantRepo + Send + Sync),
    deployment_repo: &(dyn DeploymentRepo + Send + Sync),
    region_config: &RegionConfig,
    now: DateTime<Utc>,
) -> Result<PublicInfrastructureResponse, ApiError> {
    let active_vms = vm_inventory_repo.list_active(None).await?;
    let available_regions = region_config.available_regions();
    let available_region_ids: BTreeSet<_> = available_regions
        .iter()
        .map(|(region, _)| region.as_str())
        .collect();
    let published_vms: Vec<_> = active_vms
        .into_iter()
        .filter(|vm| available_region_ids.contains(vm.region.as_str()))
        .collect();

    if published_vms.is_empty() {
        let regions = available_regions
            .into_iter()
            .map(|(region, entry)| build_region_response(region, entry, &[]))
            .collect::<Vec<_>>();
        return Ok(PublicInfrastructureResponse {
            overall: build_overall_response(regions.len(), &[]),
            regions,
        });
    }

    let public_vm_refs: Vec<_> = published_vms.iter().collect();
    let public_topology = to_public_topology(&public_vm_refs, now);
    let mut signals_by_region: BTreeMap<String, Vec<RegionVmSignal>> = BTreeMap::new();
    let published_vm_ids = published_vms.iter().map(|vm| vm.id).collect::<Vec<_>>();
    let tenants = tenant_repo.list_by_vms(&published_vm_ids).await?;
    let mut tenants_by_vm: BTreeMap<Uuid, Vec<_>> = BTreeMap::new();
    let mut deployment_ids = BTreeSet::new();

    for tenant in tenants {
        if let Some(vm_id) = tenant.vm_id {
            deployment_ids.insert(tenant.deployment_id);
            tenants_by_vm.entry(vm_id).or_default().push(tenant);
        }
    }

    let deployments = if deployment_ids.is_empty() {
        Vec::new()
    } else {
        deployment_repo
            .find_by_ids(&deployment_ids.into_iter().collect::<Vec<_>>())
            .await?
    };
    let deployment_healths_by_id: BTreeMap<Uuid, String> = deployments
        .into_iter()
        .map(|deployment| (deployment.id, deployment.health_status))
        .collect();

    for (vm, public_view) in published_vms.iter().zip(public_topology) {
        let tenants = tenants_by_vm.get(&vm.id).map(Vec::as_slice).unwrap_or(&[]);
        let health = health_rollup_from_deployment_healths(tenants, &deployment_healths_by_id);
        signals_by_region
            .entry(vm.region.clone())
            .or_default()
            .push(RegionVmSignal {
                health,
                utilization: public_view.utilization,
            });
    }

    let mut all_signals = Vec::with_capacity(published_vms.len());
    let regions = available_regions
        .into_iter()
        .map(|(region, entry)| {
            let signals = signals_by_region
                .get(region.as_str())
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            all_signals.extend_from_slice(signals);
            build_region_response(region, entry, signals)
        })
        .collect::<Vec<_>>();

    Ok(PublicInfrastructureResponse {
        overall: build_overall_response(regions.len(), &all_signals),
        regions,
    })
}

fn build_region_response(
    region: &str,
    entry: &RegionEntry,
    vm_signals: &[RegionVmSignal],
) -> PublicRegionInfrastructure {
    PublicRegionInfrastructure {
        region: region.to_string(),
        provider: entry.provider.clone(),
        display_name: entry.display_name.clone(),
        provider_location: entry.provider_location.clone(),
        health: region_health(vm_signals),
        utilization: worst_region_utilization(
            vm_signals.len(),
            &vm_signals
                .iter()
                .map(|signal| signal.utilization)
                .collect::<Vec<_>>(),
        ),
        vm_count: vm_signals.len(),
    }
}

fn region_health(vm_signals: &[RegionVmSignal]) -> PublicRegionHealth {
    if vm_signals.is_empty() {
        return PublicRegionHealth::Unknown;
    }
    let healthy_count = healthy_vm_count(vm_signals);
    if healthy_count == vm_signals.len() {
        PublicRegionHealth::Operational
    } else if healthy_count > 0 {
        PublicRegionHealth::Degraded
    } else {
        PublicRegionHealth::Outage
    }
}

fn worst_region_utilization(
    vm_count: usize,
    buckets: &[Option<UtilizationBucket>],
) -> Option<UtilizationBucket> {
    if vm_count < 2 {
        return None;
    }
    buckets
        .iter()
        .filter_map(|bucket| *bucket)
        .max_by_key(|bucket| match bucket {
            UtilizationBucket::Green => 0,
            UtilizationBucket::Yellow => 1,
            UtilizationBucket::Red => 2,
        })
}

fn build_overall_response(
    total_regions: usize,
    vm_signals: &[RegionVmSignal],
) -> PublicInfrastructureOverall {
    let total_vms = vm_signals.len();
    let availability_pct = if total_vms == 0 {
        None
    } else {
        Some((healthy_vm_count(vm_signals) as f64 / total_vms as f64) * 100.0)
    };
    PublicInfrastructureOverall {
        availability_pct,
        total_regions,
        total_vms,
    }
}

fn healthy_vm_count(vm_signals: &[RegionVmSignal]) -> usize {
    vm_signals
        .iter()
        .filter(|signal| signal.health == VmHealth::Healthy)
        .count()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use chrono::{TimeZone, Utc};
    use serde_json::{json, Value};
    use uuid::Uuid;

    use super::*;
    use crate::models::VmInventory;
    use crate::provisioner::region_map::RegionEntry;
    use crate::services::public_topology::{to_public_topology, UtilizationBucket};
    use crate::services::vm_health_rollup::VmHealth;

    fn region_entry() -> RegionEntry {
        RegionEntry {
            provider: "aws".to_string(),
            provider_location: "us-east-1".to_string(),
            display_name: "US East (Virginia)".to_string(),
            available: true,
        }
    }

    fn signal(health: VmHealth, utilization: Option<UtilizationBucket>) -> RegionVmSignal {
        RegionVmSignal {
            health,
            utilization,
        }
    }

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 21, 12, 0, 0).unwrap()
    }

    fn vector(cpu_weight: f64, mem_rss_bytes: u64, disk_bytes: u64) -> Value {
        json!({
            "cpu_weight": cpu_weight,
            "mem_rss_bytes": mem_rss_bytes,
            "disk_bytes": disk_bytes,
            "query_rps": cpu_weight,
            "indexing_rps": cpu_weight,
        })
    }

    fn vm(capacity: Value, current_load: Value) -> VmInventory {
        VmInventory {
            id: Uuid::new_v4(),
            region: "us-east-1".to_string(),
            provider: "aws".to_string(),
            hostname: "private-host.internal".to_string(),
            flapjack_url: "http://10.11.12.13:7700".to_string(),
            capacity,
            current_load,
            load_scraped_at: Some(now()),
            status: "active".to_string(),
            created_at: now(),
            updated_at: now(),
        }
    }

    fn region_health(vms: &[RegionVmSignal]) -> PublicRegionHealth {
        build_region_response("us-east-1", &region_entry(), vms).health
    }

    #[test]
    fn region_rollup_classifies_each_health_branch() {
        assert_eq!(
            region_health(&[
                signal(VmHealth::Healthy, None),
                signal(VmHealth::Healthy, None),
            ]),
            PublicRegionHealth::Operational
        );
        assert_eq!(
            region_health(&[
                signal(VmHealth::Healthy, None),
                signal(VmHealth::Unhealthy, None),
            ]),
            PublicRegionHealth::Degraded
        );
        assert_eq!(
            region_health(&[
                signal(VmHealth::Healthy, None),
                signal(VmHealth::Unknown, None),
            ]),
            PublicRegionHealth::Degraded
        );
        assert_eq!(
            region_health(&[signal(VmHealth::Unhealthy, None)]),
            PublicRegionHealth::Outage
        );
        assert_eq!(
            region_health(&[signal(VmHealth::Unknown, None)]),
            PublicRegionHealth::Outage
        );

        let empty = build_region_response("us-east-1", &region_entry(), &[]);
        assert_eq!(empty.health, PublicRegionHealth::Unknown);
        assert_eq!(empty.vm_count, 0);
    }

    #[test]
    fn region_rollup_reduces_utilization_to_worst_bucket_after_k_anonymity() {
        assert_eq!(
            worst_region_utilization(
                2,
                &[
                    Some(UtilizationBucket::Green),
                    Some(UtilizationBucket::Green)
                ]
            ),
            Some(UtilizationBucket::Green)
        );
        assert_eq!(
            worst_region_utilization(
                3,
                &[
                    Some(UtilizationBucket::Green),
                    Some(UtilizationBucket::Red),
                    Some(UtilizationBucket::Yellow),
                ]
            ),
            Some(UtilizationBucket::Red)
        );
        assert_eq!(worst_region_utilization(2, &[None, None]), None);
        assert_eq!(worst_region_utilization(0, &[]), None);
        assert_eq!(
            worst_region_utilization(1, &[Some(UtilizationBucket::Red)]),
            None
        );

        let zero_capacity_vm = vm(vector(0.0, 0, 0), vector(0.0, 0, 0));
        let topology = to_public_topology(&[&zero_capacity_vm], now());
        assert_eq!(
            worst_region_utilization(2, &[topology[0].utilization]),
            None
        );
    }

    #[test]
    fn overall_rollup_counts_unknown_and_unhealthy_in_denominator() {
        let regions = [
            build_region_response(
                "us-east-1",
                &region_entry(),
                &[
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Unhealthy, None),
                ],
            ),
            build_region_response("eu-west-1", &region_entry(), &[]),
        ];

        assert_eq!(
            regions.iter().map(|region| region.vm_count).sum::<usize>(),
            4
        );

        assert_eq!(
            build_overall_response(
                2,
                &[
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Healthy, None),
                    signal(VmHealth::Unhealthy, None),
                ],
            ),
            PublicInfrastructureOverall {
                availability_pct: Some(75.0),
                total_regions: 2,
                total_vms: 4,
            }
        );
        assert_eq!(
            build_overall_response(1, &[]),
            PublicInfrastructureOverall {
                availability_pct: None,
                total_regions: 1,
                total_vms: 0,
            }
        );
    }

    #[test]
    fn public_region_serializes_only_documented_keys() {
        let serialized = serde_json::to_value(build_region_response(
            "us-east-1",
            &region_entry(),
            &[signal(VmHealth::Healthy, Some(UtilizationBucket::Green))],
        ))
        .unwrap();
        let keys = serialized
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>();

        assert_eq!(
            keys,
            BTreeSet::from([
                "display_name".to_string(),
                "health".to_string(),
                "provider".to_string(),
                "provider_location".to_string(),
                "region".to_string(),
                "utilization".to_string(),
                "vm_count".to_string(),
            ])
        );
    }
}

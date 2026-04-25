//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/internal.rs.
use axum::extract::Request;
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::{extract::State, Json};
use chrono::{NaiveDate, Utc};
use serde::Serialize;
use std::collections::HashMap;
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::errors::ApiError;
use crate::routes::indexes::flapjack_index_uid;
use crate::state::AppState;

#[derive(Debug, Clone, Serialize)]
pub struct TenantMapEntry {
    pub tenant_id: String,
    pub flapjack_uid: String,
    pub customer_id: Uuid,
    pub vm_id: Option<Uuid>,
    pub flapjack_url: Option<String>,
    pub tier: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ColdStorageUsageEntry {
    pub customer_id: Uuid,
    pub tenant_id: String,
    pub size_bytes: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct RegionEntryResponse {
    pub id: String,
    pub provider: String,
    pub provider_location: String,
    pub display_name: String,
    pub available: bool,
}

/// `GET /internal/tenant-map` — list all active tenants with their deployment URLs.
///
/// **Auth:** `x-internal-key` header (internal service auth).
/// Caches deployment URL lookups to avoid repeated DB hits when multiple
/// tenants share a deployment. Falls back to `vm_inventory.flapjack_url`
/// when the deployment row has no URL — this matches the seeded shared-VM
/// path (`POST /admin/tenants/:id/indexes` with `flapjack_url`), which
/// stores the routable URL on the VM rather than the deployment. Without
/// the fallback, the metering agent on the shared VM filters those
/// tenants out (it skips entries whose `flapjack_url` doesn't match
/// `local_flapjack_url`), and `usage_records` for those tenants never
/// gets written. Used by the metering agent and aggregation job.
pub async fn tenant_map(
    State(state): State<AppState>,
) -> Result<Json<Vec<TenantMapEntry>>, ApiError> {
    let tenants = state.tenant_repo.list_active_global().await?;
    let mut deployment_url_cache: HashMap<Uuid, Option<String>> = HashMap::new();
    let mut vm_url_cache: HashMap<Uuid, Option<String>> = HashMap::new();
    let mut response = Vec::with_capacity(tenants.len());

    for tenant in tenants {
        let mut flapjack_url = if let Some(cached) = deployment_url_cache.get(&tenant.deployment_id)
        {
            cached.clone()
        } else {
            let fetched = state
                .deployment_repo
                .find_by_id(tenant.deployment_id)
                .await?
                .and_then(|deployment| deployment.flapjack_url);
            deployment_url_cache.insert(tenant.deployment_id, fetched.clone());
            fetched
        };

        if flapjack_url.is_none() {
            if let Some(vm_id) = tenant.vm_id {
                let vm_url = if let Some(cached) = vm_url_cache.get(&vm_id) {
                    cached.clone()
                } else {
                    let fetched = state
                        .vm_inventory_repo
                        .get(vm_id)
                        .await?
                        .map(|vm| vm.flapjack_url);
                    vm_url_cache.insert(vm_id, fetched.clone());
                    fetched
                };
                flapjack_url = vm_url;
            }
        }

        response.push(TenantMapEntry {
            flapjack_uid: flapjack_index_uid(tenant.customer_id, &tenant.tenant_id),
            tenant_id: tenant.tenant_id,
            customer_id: tenant.customer_id,
            vm_id: tenant.vm_id,
            flapjack_url,
            tier: tenant.tier,
        });
    }

    Ok(Json(response))
}

/// `GET /internal/cold-storage-usage` — list completed cold snapshots for billing.
///
/// **Auth:** `x-internal-key` header (internal service auth).
/// Returns every completed cold snapshot from epoch to now, keyed by
/// customer and tenant, with `size_bytes` for billing aggregation.
pub async fn cold_storage_usage(
    State(state): State<AppState>,
) -> Result<Json<Vec<ColdStorageUsageEntry>>, ApiError> {
    let snapshots = state
        .cold_snapshot_repo
        .list_completed_for_billing(
            NaiveDate::from_ymd_opt(1970, 1, 1).expect("static date is valid"),
            Utc::now().date_naive(),
        )
        .await?;

    let entries = snapshots
        .into_iter()
        .map(|snapshot| ColdStorageUsageEntry {
            customer_id: snapshot.customer_id,
            tenant_id: snapshot.tenant_id,
            size_bytes: snapshot.size_bytes,
        })
        .collect();

    Ok(Json(entries))
}

/// `GET /internal/regions` — list all configured regions with availability status.
///
/// **Auth:** `x-internal-key` header (internal service auth).
/// Reads from the static `RegionConfig` loaded at startup; no DB access.
pub async fn regions(
    State(state): State<AppState>,
) -> Result<Json<Vec<RegionEntryResponse>>, ApiError> {
    let regions = state
        .region_config
        .available_regions()
        .into_iter()
        .map(|(id, entry)| RegionEntryResponse {
            id: id.clone(),
            provider: entry.provider.clone(),
            provider_location: entry.provider_location.clone(),
            display_name: entry.display_name.clone(),
            available: entry.available,
        })
        .collect();

    Ok(Json(regions))
}

const METRICS_CONTENT_TYPE: &str = "text/plain; version=0.0.4; charset=utf-8";

pub async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, METRICS_CONTENT_TYPE)],
        state.metrics_collector.render(),
    )
}

/// Middleware that gates all internal routes behind `x-internal-key` auth.
/// Applied as a route_layer on the `/internal` nest in the router.
pub async fn internal_auth_middleware(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    if !is_internal_request_authorized(request.headers(), &state) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    next.run(request).await
}

fn is_internal_request_authorized(headers: &HeaderMap, state: &AppState) -> bool {
    let Some(expected) = state.internal_auth_token.as_deref() else {
        // Fail closed when internal auth is not configured.
        // This avoids accidentally exposing `/internal/*` endpoints due to missing env config.
        tracing::error!("INTERNAL_AUTH_TOKEN is not configured; denying internal request");
        return false;
    };

    let Some(provided) = headers.get("x-internal-key").and_then(|v| v.to_str().ok()) else {
        return false;
    };

    provided.as_bytes().ct_eq(expected.as_bytes()).into()
}

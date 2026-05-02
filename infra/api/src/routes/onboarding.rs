use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;
use serde::Serialize;
use utoipa::ToSchema;
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::models::{BillingPlan, Deployment};
use crate::services::tenant_quota::FreeTierLimits;
use crate::state::AppState;

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, ToSchema)]
pub struct OnboardingStatusResponse {
    pub has_payment_method: bool,
    pub has_region: bool,
    pub region_ready: bool,
    pub has_index: bool,
    pub has_api_key: bool,
    pub completed: bool,
    pub billing_plan: BillingPlan,
    pub free_tier_limits: Option<FreeTierLimitsResponse>,
    pub flapjack_url: Option<String>,
    pub suggested_next_step: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct FreeTierLimitsResponse {
    pub max_searches_per_month: u64,
    pub max_records: u64,
    pub max_storage_gb: u64,
    pub max_indexes: u32,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct CredentialsResponse {
    pub endpoint: String,
    pub api_key: String,
    pub application_id: String,
}

const ONBOARDING_KEY_ACLS: &[&str] = &["search", "browse"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Derive the next onboarding action label from the customer's current state.
///
/// Priority order: payment method (Shared plan only) → create first index
/// (with a "waiting" variant if the region is provisioning) → "all set".
fn suggested_next_step(
    billing_plan: BillingPlan,
    has_payment_method: bool,
    has_region: bool,
    region_ready: bool,
    has_index: bool,
) -> String {
    if matches!(billing_plan, BillingPlan::Shared) && !has_payment_method {
        return "Add a payment method".into();
    }

    if !has_index && has_region && !region_ready {
        return "Waiting for your search endpoint to be ready".into();
    }

    if !has_index {
        return "Create your first index".into();
    }

    "You're all set!".into()
}

/// Check whether the customer has at least one Stripe payment method.
///
/// Returns `false` (rather than an error) when Stripe lookup fails for
/// free-plan customers, because payment methods are not required on the
/// free tier and a transient Stripe outage should not block onboarding.
async fn lookup_payment_method_status(
    state: &AppState,
    billing_plan: BillingPlan,
    stripe_customer_id: Option<&str>,
) -> Result<bool, ApiError> {
    let Some(stripe_customer_id) = stripe_customer_id else {
        return Ok(false);
    };

    match state
        .stripe_service
        .list_payment_methods(stripe_customer_id)
        .await
    {
        Ok(methods) => Ok(!methods.is_empty()),
        Err(err) if matches!(billing_plan, BillingPlan::Free) => {
            tracing::warn!(
                stripe_customer_id,
                error = ?err,
                "ignoring Stripe payment method lookup failure for free-plan onboarding"
            );
            Ok(false)
        }
        Err(err) => Err(err.into()),
    }
}

async fn list_customer_deployments(
    state: &AppState,
    customer_id: Uuid,
) -> Result<Vec<Deployment>, ApiError> {
    state
        .deployment_repo
        .list_by_customer(customer_id, false)
        .await
        .map_err(Into::into)
}

fn find_running_deployment(deployments: &[Deployment]) -> Option<&Deployment> {
    deployments
        .iter()
        .find(|deployment| deployment.status == "running")
}

fn free_tier_limits(state: &AppState, billing_plan: BillingPlan) -> Option<FreeTierLimitsResponse> {
    matches!(billing_plan, BillingPlan::Free).then(|| FreeTierLimitsResponse {
        max_searches_per_month: state.free_tier_limits.max_searches_per_month,
        max_records: FreeTierLimits::default_max_records(),
        max_storage_gb: FreeTierLimits::default_max_storage_gb(),
        max_indexes: state.free_tier_limits.max_indexes,
    })
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /onboarding/status — returns onboarding state derived from existing data
#[utoipa::path(
    get,
    path = "/onboarding/status",
    tag = "Onboarding",
    responses(
        (status = 200, description = "Onboarding status", body = OnboardingStatusResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
        (status = 500, description = "Internal error", body = ErrorResponse),
        (status = 503, description = "Billing service unavailable", body = ErrorResponse),
    )
)]
pub async fn get_status(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(auth.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;
    let billing_plan = customer.billing_plan_enum();

    let has_payment_method =
        lookup_payment_method_status(&state, billing_plan, customer.stripe_customer_id.as_deref())
            .await?;

    // Check deployments
    let deployments = list_customer_deployments(&state, auth.customer_id).await?;
    let has_region = !deployments.is_empty();
    let running_deployment = find_running_deployment(&deployments);
    let region_ready = running_deployment.is_some();
    let flapjack_url = running_deployment.and_then(|d| d.flapjack_url.clone());

    // Check indexes
    let index_count = state
        .tenant_repo
        .count_by_customer(auth.customer_id)
        .await?;
    let has_index = index_count > 0;

    // Check API keys
    let api_keys = state
        .api_key_repo
        .list_by_customer(auth.customer_id)
        .await?;
    let has_api_key = !api_keys.is_empty();

    let completed = match billing_plan {
        BillingPlan::Free => has_index,
        BillingPlan::Shared => has_payment_method && has_index,
    };

    let next_step = suggested_next_step(
        billing_plan,
        has_payment_method,
        has_region,
        region_ready,
        has_index,
    );
    let free_tier_limits = free_tier_limits(&state, billing_plan);

    Ok(Json(OnboardingStatusResponse {
        has_payment_method,
        has_region,
        region_ready,
        has_index,
        has_api_key,
        completed,
        billing_plan,
        free_tier_limits,
        flapjack_url,
        suggested_next_step: next_step,
    }))
}

/// `POST /onboarding/credentials` — generate a search-only API key via flapjack.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Requires at least one running deployment and one index. Creates a
/// flapjack search key scoped to the customer's indexes (ACLs: search,
/// browse). Resolves the correct proxy node ID for shared-VM deployments.
/// Returns 400 if no deployment or indexes exist yet.
#[utoipa::path(
    post,
    path = "/onboarding/credentials",
    tag = "Onboarding",
    responses(
        (status = 200, description = "Credentials generated", body = CredentialsResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "No active endpoint or indexes available", body = ErrorResponse),
        (status = 500, description = "Internal error", body = ErrorResponse),
        (status = 503, description = "Flapjack temporarily unavailable", body = ErrorResponse),
    )
)]
pub async fn generate_credentials(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    // Find first running deployment
    let deployments = list_customer_deployments(&state, auth.customer_id).await?;

    let running = find_running_deployment(&deployments)
        .ok_or_else(|| ApiError::BadRequest("No active endpoint yet".into()))?;

    let flapjack_url = running
        .flapjack_url
        .as_deref()
        .ok_or_else(|| ApiError::Internal("deployment running but no flapjack_url".into()))?;

    // Get customer's indexes on this deployment
    let indexes = state.tenant_repo.find_by_deployment(running.id).await?;

    let customer_tenant_names: Vec<&str> = indexes
        .iter()
        .filter(|t| t.customer_id == auth.customer_id)
        .map(|t| t.tenant_id.as_str())
        .collect();

    if customer_tenant_names.is_empty() {
        return Err(ApiError::BadRequest(
            "Create at least one index before generating credentials".into(),
        ));
    }

    // Map customer-facing names to tenant-scoped flapjack UIDs for the search key.
    let flapjack_uids: Vec<String> = customer_tenant_names
        .iter()
        .map(|name| crate::routes::indexes::flapjack_index_uid(auth.customer_id, name))
        .collect();
    let customer_indexes: Vec<&str> = flapjack_uids.iter().map(|s| s.as_str()).collect();

    let proxy_node_id = if let Some(raw_tenant) = state
        .tenant_repo
        .find_raw(auth.customer_id, customer_tenant_names[0])
        .await?
    {
        if let Some(vm_id) = raw_tenant.vm_id {
            if let Some(vm) = state.vm_inventory_repo.get(vm_id).await? {
                crate::routes::indexes::resolve_shared_vm_proxy_node_id(&state, &vm, running).await
            } else {
                running.node_id.clone()
            }
        } else {
            running.node_id.clone()
        }
    } else {
        running.node_id.clone()
    };

    let key = state
        .flapjack_proxy
        .create_search_key(
            flapjack_url,
            &proxy_node_id,
            &running.region,
            &customer_indexes,
            ONBOARDING_KEY_ACLS,
            "default API key",
        )
        .await?;

    Ok(Json(CredentialsResponse {
        endpoint: flapjack_url.to_string(),
        api_key: key.key,
        application_id: "flapjack".to_string(),
    }))
}

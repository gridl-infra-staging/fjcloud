use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::invoicing;
use crate::models::PlanTier;
use crate::routes::usage::{default_month, parse_month, UsageQuery};
use crate::state::AppState;

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct SetupIntentResponse {
    pub client_secret: String,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CreateBillingPortalSessionRequest {
    pub return_url: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct BillingPortalSessionResponse {
    pub portal_url: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct PaymentMethodResponse {
    pub id: String,
    pub card_brand: String,
    pub last4: String,
    pub exp_month: u32,
    pub exp_year: u32,
    pub is_default: bool,
}

/// Helper: look up customer and extract stripe_customer_id, returning appropriate errors.
async fn get_stripe_customer_id(
    state: &AppState,
    customer_id: uuid::Uuid,
) -> Result<String, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    customer
        .stripe_customer_id
        .ok_or_else(|| ApiError::BadRequest("no stripe customer linked".into()))
}

fn checkout_redirect_url(base_url: &str, subscription_state: &str) -> Result<String, ApiError> {
    let mut url = reqwest::Url::parse(base_url).map_err(|e| {
        ApiError::Internal(format!(
            "invalid checkout redirect URL configuration ({base_url}): {e}"
        ))
    })?;
    url.query_pairs_mut()
        .append_pair("subscription", subscription_state);
    Ok(url.into())
}

/// Verify that a payment method belongs to the authenticated customer.
async fn verify_pm_ownership(
    state: &AppState,
    stripe_customer_id: &str,
    pm_id: &str,
) -> Result<(), ApiError> {
    let methods = state
        .stripe_service
        .list_payment_methods(stripe_customer_id)
        .await?;

    if !methods.iter().any(|pm| pm.id == pm_id) {
        return Err(ApiError::NotFound("payment method not found".into()));
    }
    Ok(())
}

// POST /billing/setup-intent
#[utoipa::path(
    post,
    path = "/billing/setup-intent",
    tag = "Billing",
    responses(
        (status = 200, description = "Setup intent created", body = SetupIntentResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
pub async fn create_setup_intent(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;

    let client_secret = state
        .stripe_service
        .create_setup_intent(&stripe_customer_id)
        .await?;

    Ok(Json(SetupIntentResponse { client_secret }))
}

// POST /billing/portal
#[utoipa::path(
    post,
    path = "/billing/portal",
    tag = "Billing",
    request_body = CreateBillingPortalSessionRequest,
    responses(
        (status = 200, description = "Billing portal session created", body = BillingPortalSessionResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
        (status = 503, description = "Stripe not configured", body = ErrorResponse),
    )
)]
pub async fn create_billing_portal_session(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<CreateBillingPortalSessionRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;
    let session = state
        .stripe_service
        .create_billing_portal_session(
            &stripe_customer_id,
            &crate::stripe::CreatePortalSessionRequest {
                return_url: req.return_url,
            },
        )
        .await?;

    Ok(Json(BillingPortalSessionResponse {
        portal_url: session.url,
    }))
}

// GET /billing/payment-methods
/// `GET /billing/payment-methods` — list saved payment methods from Stripe.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Resolves the customer's `stripe_customer_id` and fetches all attached
/// payment methods from Stripe. Returns 400 if no Stripe customer is linked.
#[utoipa::path(
    get,
    path = "/billing/payment-methods",
    tag = "Billing",
    responses(
        (status = 200, description = "List of payment methods", body = Vec<PaymentMethodResponse>),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
pub async fn list_payment_methods(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;

    let methods = state
        .stripe_service
        .list_payment_methods(&stripe_customer_id)
        .await?;

    let response: Vec<PaymentMethodResponse> = methods
        .into_iter()
        .map(|pm| PaymentMethodResponse {
            id: pm.id,
            card_brand: pm.card_brand,
            last4: pm.last4,
            exp_month: pm.exp_month,
            exp_year: pm.exp_year,
            is_default: pm.is_default,
        })
        .collect();

    Ok(Json(response))
}

// DELETE /billing/payment-methods/:pm_id
#[utoipa::path(
    delete,
    path = "/billing/payment-methods/{pm_id}",
    tag = "Billing",
    params(
        ("pm_id" = String, Path, description = "Payment method identifier")
    ),
    responses(
        (status = 204, description = "Payment method deleted"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Payment method not found", body = ErrorResponse),
    )
)]
pub async fn delete_payment_method(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(pm_id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;
    verify_pm_ownership(&state, &stripe_customer_id, &pm_id).await?;

    state.stripe_service.detach_payment_method(&pm_id).await?;

    Ok(StatusCode::NO_CONTENT)
}

// POST /billing/payment-methods/:pm_id/default
#[utoipa::path(
    post,
    path = "/billing/payment-methods/{pm_id}/default",
    tag = "Billing",
    params(
        ("pm_id" = String, Path, description = "Payment method identifier")
    ),
    responses(
        (status = 204, description = "Default payment method set"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Payment method not found", body = ErrorResponse),
    )
)]
pub async fn set_default_payment_method(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(pm_id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;
    verify_pm_ownership(&state, &stripe_customer_id, &pm_id).await?;

    state
        .stripe_service
        .set_default_payment_method(&stripe_customer_id, &pm_id)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// Estimated current bill
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct EstimateLineItem {
    pub description: String,
    pub quantity: String,
    pub unit: String,
    pub unit_price_cents: String,
    pub amount_cents: i64,
    pub region: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct EstimatedBillResponse {
    pub month: String,
    pub subtotal_cents: i64,
    pub total_cents: i64,
    pub line_items: Vec<EstimateLineItem>,
    pub minimum_applied: bool,
}

// GET /billing/estimate
/// `GET /billing/estimate` — compute an estimated invoice for a given month.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Accepts an optional `?month=YYYY-MM` query param (defaults to current month).
/// Runs the invoice computation pipeline against live usage data without
/// persisting the result. The response includes line items, subtotal/total,
/// and whether the plan minimum was applied.
#[utoipa::path(
    get,
    path = "/billing/estimate",
    tag = "Billing",
    params(UsageQuery),
    responses(
        (status = 200, description = "Estimated bill for the month", body = EstimatedBillResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
pub async fn get_estimate(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Query(query): Query<UsageQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let month = query.month.unwrap_or_else(default_month);
    let (start_date, end_date) = parse_month(&month)?;

    let customer = state
        .customer_repo
        .find_by_id(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    let repos = invoicing::BillingRepos::from_state(&state);
    let generated = invoicing::compute_invoice_for_customer(
        &repos,
        tenant.customer_id,
        start_date,
        end_date,
        customer.billing_plan_enum(),
        customer.object_storage_egress_carryforward_cents,
    )
    .await?;

    let line_items: Vec<EstimateLineItem> = generated
        .line_items
        .iter()
        .map(|li| EstimateLineItem {
            description: li.description.clone(),
            quantity: li.quantity.to_string(),
            unit: li.unit.clone(),
            unit_price_cents: li.unit_price_cents.to_string(),
            amount_cents: li.amount_cents,
            region: li.region.clone(),
        })
        .collect();

    Ok(Json(EstimatedBillResponse {
        month,
        subtotal_cents: generated.subtotal_cents,
        total_cents: generated.total_cents,
        line_items,
        minimum_applied: generated.minimum_applied,
    }))
}

// ---------------------------------------------------------------------------
// Checkout Session and Subscription Lifecycle
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CreateCheckoutSessionRequest {
    pub plan_tier: PlanTier,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct CheckoutSessionResponseBody {
    pub checkout_url: String,
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
fn plan_tier_to_price_id(
    plan_registry: &dyn billing::plan::PlanRegistry,
    tier: PlanTier,
) -> Result<String, ApiError> {
    plan_registry.get_stripe_price_id(tier).ok_or_else(|| {
        ApiError::BadRequest(format!("no stripe price configured for plan: {}", tier))
    })
}

// POST /billing/checkout-session
/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
#[utoipa::path(
    post,
    path = "/billing/checkout-session",
    tag = "Billing",
    request_body = CreateCheckoutSessionRequest,
    responses(
        (status = 200, description = "Checkout session created", body = CheckoutSessionResponseBody),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
        (status = 409, description = "Customer already has subscription", body = ErrorResponse),
    )
)]
#[deprecated(note = "Use invoice-based billing instead")]
pub async fn create_checkout_session(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<CreateCheckoutSessionRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if state
        .subscription_repo
        .find_by_customer(tenant.customer_id)
        .await?
        .is_some()
    {
        return Err(ApiError::Conflict(
            "customer already has a non-canceled subscription".into(),
        ));
    }

    let stripe_customer_id = get_stripe_customer_id(&state, tenant.customer_id).await?;

    let price_id = plan_tier_to_price_id(state.plan_registry.as_ref(), req.plan_tier)?;

    let success_url = checkout_redirect_url(&state.stripe_success_url, "success")?;
    let cancel_url = checkout_redirect_url(&state.stripe_cancel_url, "cancelled")?;
    let mut metadata = HashMap::new();
    metadata.insert("customer_id".to_string(), tenant.customer_id.to_string());
    metadata.insert("plan_tier".to_string(), req.plan_tier.to_string());

    let session = state
        .stripe_service
        .create_checkout_session(
            &stripe_customer_id,
            &price_id,
            &success_url,
            &cancel_url,
            Some(&metadata),
        )
        .await?;

    Ok(Json(CheckoutSessionResponseBody {
        checkout_url: session.url,
    }))
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CancelSubscriptionRequest {
    pub cancel_at_period_end: bool,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct SubscriptionResponse {
    pub id: String,
    pub plan_tier: String,
    pub status: String,
    pub current_period_end: String,
    pub cancel_at_period_end: bool,
}

// GET /billing/subscription
/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
#[utoipa::path(
    get,
    path = "/billing/subscription",
    tag = "Billing",
    responses(
        (status = 200, description = "Current subscription", body = SubscriptionResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "No subscription found", body = ErrorResponse),
    )
)]
#[deprecated(note = "Use invoice-based billing instead")]
pub async fn get_subscription(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let subscription = state
        .subscription_repo
        .find_by_customer(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("no subscription found".into()))?;

    Ok(Json(SubscriptionResponse {
        id: subscription.stripe_subscription_id,
        plan_tier: subscription.plan_tier,
        status: subscription.status,
        current_period_end: subscription.current_period_end.to_string(),
        cancel_at_period_end: subscription.cancel_at_period_end,
    }))
}

// POST /billing/subscription/cancel
/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
#[utoipa::path(
    post,
    path = "/billing/subscription/cancel",
    tag = "Billing",
    request_body = CancelSubscriptionRequest,
    responses(
        (status = 200, description = "Subscription cancelled", body = SubscriptionResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "No subscription found", body = ErrorResponse),
    )
)]
#[deprecated(note = "Use invoice-based billing instead")]
pub async fn cancel_subscription(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<CancelSubscriptionRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let subscription = state
        .subscription_repo
        .find_by_customer(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("no subscription found".into()))?;

    let updated = state
        .stripe_service
        .cancel_subscription(
            &subscription.stripe_subscription_id,
            req.cancel_at_period_end,
        )
        .await?;

    state
        .subscription_repo
        .set_cancel_at_period_end(subscription.id, req.cancel_at_period_end)
        .await?;

    if !req.cancel_at_period_end {
        state
            .subscription_repo
            .mark_canceled(subscription.id)
            .await?;
    }

    let plan_tier = updated
        .items
        .first()
        .and_then(|i| {
            state
                .plan_registry
                .get_tier_by_price_id(&i.price_id)
                .map(|t| t.as_str().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    Ok(Json(subscription_data_to_response(updated, plan_tier)))
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct UpdateSubscriptionRequest {
    pub plan_tier: PlanTier,
}

fn subscription_data_to_response(
    data: crate::stripe::SubscriptionData,
    plan_tier: String,
) -> SubscriptionResponse {
    SubscriptionResponse {
        id: data.id,
        plan_tier,
        status: data.status,
        current_period_end: chrono::DateTime::from_timestamp(data.current_period_end, 0)
            .map(|dt| dt.format("%Y-%m-%d").to_string())
            .unwrap_or_default(),
        cancel_at_period_end: data.cancel_at_period_end,
    }
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
fn validate_plan_change(
    current_tier: PlanTier,
    new_tier: PlanTier,
    is_upgrade: bool,
) -> Result<(), ApiError> {
    if is_upgrade && !current_tier.is_upgrade_to(new_tier) {
        return Err(ApiError::BadRequest(format!(
            "cannot upgrade from {:?} to {:?}",
            current_tier, new_tier
        )));
    }
    if !is_upgrade && !current_tier.is_downgrade_to(new_tier) {
        return Err(ApiError::BadRequest(format!(
            "cannot downgrade from {:?} to {:?}",
            current_tier, new_tier
        )));
    }
    Ok(())
}

// POST /billing/subscription/upgrade
/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
#[utoipa::path(
    post,
    path = "/billing/subscription/upgrade",
    tag = "Billing",
    request_body = UpdateSubscriptionRequest,
    responses(
        (status = 200, description = "Subscription upgraded", body = SubscriptionResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "No subscription found", body = ErrorResponse),
    )
)]
#[deprecated(note = "Use invoice-based billing instead")]
pub async fn upgrade_subscription(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<UpdateSubscriptionRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let subscription = state
        .subscription_repo
        .find_by_customer(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("no subscription found".into()))?;

    let current_tier = subscription
        .parsed_plan_tier()
        .map_err(ApiError::BadRequest)?;

    validate_plan_change(current_tier, req.plan_tier, true)?;

    let new_price_id = plan_tier_to_price_id(state.plan_registry.as_ref(), req.plan_tier)?;

    let updated = state
        .stripe_service
        .update_subscription_price(
            &subscription.stripe_subscription_id,
            &new_price_id,
            "always_invoice",
        )
        .await?;

    state
        .subscription_repo
        .update_plan(subscription.id, req.plan_tier, &new_price_id)
        .await?;

    Ok(Json(subscription_data_to_response(
        updated,
        req.plan_tier.as_str().to_string(),
    )))
}

// POST /billing/subscription/downgrade
/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
#[utoipa::path(
    post,
    path = "/billing/subscription/downgrade",
    tag = "Billing",
    request_body = UpdateSubscriptionRequest,
    responses(
        (status = 200, description = "Subscription downgraded", body = SubscriptionResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 404, description = "No subscription found", body = ErrorResponse),
    )
)]
#[deprecated(note = "Use invoice-based billing instead")]
pub async fn downgrade_subscription(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<UpdateSubscriptionRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let subscription = state
        .subscription_repo
        .find_by_customer(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("no subscription found".into()))?;

    let current_tier = subscription
        .parsed_plan_tier()
        .map_err(ApiError::BadRequest)?;

    validate_plan_change(current_tier, req.plan_tier, false)?;

    let new_price_id = plan_tier_to_price_id(state.plan_registry.as_ref(), req.plan_tier)?;

    let updated = state
        .stripe_service
        .update_subscription_price(&subscription.stripe_subscription_id, &new_price_id, "none")
        .await?;

    state
        .subscription_repo
        .update_plan(subscription.id, req.plan_tier, &new_price_id)
        .await?;

    Ok(Json(subscription_data_to_response(
        updated,
        req.plan_tier.as_str().to_string(),
    )))
}

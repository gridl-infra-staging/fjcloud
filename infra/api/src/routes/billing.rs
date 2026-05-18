use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::invoicing;
use crate::models::BillingPlan;
use crate::routes::usage::{default_month, parse_month, UsageQuery};
use crate::state::AppState;
use crate::stripe::{activation_upgrade_idempotency_key, PaidInvoice, StripeInvoiceLineItem};

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
pub struct PublishableKeyResponse {
    #[serde(rename = "publishableKey")]
    pub publishable_key: String,
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

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct BillingUpgradeResponse {
    pub billing_plan: BillingPlan,
    pub subscription_cycle_anchor_at: DateTime<Utc>,
    pub stripe_invoice_id: String,
    pub activation_amount_cents: i64,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct UpgradePaymentRequiredResponse {
    pub error: &'static str,
    pub code: String,
    pub decline_code: Option<String>,
    pub message: Option<String>,
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

fn has_default_payment_method(methods: &[crate::stripe::PaymentMethodSummary]) -> bool {
    methods
        .iter()
        .any(|payment_method| payment_method.is_default)
}

fn activation_invoice_metadata(
    customer_id: uuid::Uuid,
    anchor_at: DateTime<Utc>,
) -> HashMap<String, String> {
    HashMap::from([
        (
            "purpose".to_string(),
            "shared_activation_upgrade".to_string(),
        ),
        ("customer_id".to_string(), customer_id.to_string()),
        (
            "subscription_cycle_anchor_at".to_string(),
            anchor_at.to_rfc3339(),
        ),
    ])
}

fn payment_required_response(payment: &PaidInvoice) -> Option<UpgradePaymentRequiredResponse> {
    let last_error = payment.last_payment_error.as_ref()?;
    let code = last_error.code.as_deref()?;
    if code != "card_declined" && code != "invoice_payment_intent_requires_action" {
        return None;
    }

    Some(UpgradePaymentRequiredResponse {
        error: "payment_required",
        code: code.to_string(),
        decline_code: last_error.decline_code.clone(),
        message: last_error.message.clone(),
    })
}

async fn rollback_upgrade_for_anchor(
    state: &AppState,
    customer_id: uuid::Uuid,
    anchor_at: DateTime<Utc>,
) -> Result<(), ApiError> {
    // Atomic rollback keeps plan + anchor persistence as one trusted seam.
    let rolled_back = state
        .customer_repo
        .rollback_upgrade_to_free_atomic(customer_id, anchor_at)
        .await?;
    if !rolled_back {
        return Err(ApiError::Internal(
            "failed to rollback upgrade state".into(),
        ));
    }
    Ok(())
}

async fn rollback_upgrade_and_void_invoice(
    state: &AppState,
    customer_id: uuid::Uuid,
    anchor_at: DateTime<Utc>,
    stripe_invoice_id: &str,
) -> Result<(), ApiError> {
    let rollback_result = rollback_upgrade_for_anchor(state, customer_id, anchor_at).await;
    let void_result = state.stripe_service.void_invoice(stripe_invoice_id).await;

    match (rollback_result, void_result) {
        (Ok(()), Ok(_)) => Ok(()),
        (Err(rollback_error), Ok(_)) => Err(rollback_error),
        (Ok(()), Err(void_error)) => Err(ApiError::from(void_error)),
        (Err(rollback_error), Err(void_error)) => Err(ApiError::Internal(format!(
            "failed to rollback upgrade state and void activation invoice: rollback_error={rollback_error:?}; void_error={void_error}"
        ))),
    }
}

fn validated_billing_return_url(state: &AppState, return_url: &str) -> Result<String, ApiError> {
    let parsed = reqwest::Url::parse(return_url)
        .map_err(|_| ApiError::BadRequest("return_url must be an absolute URL".into()))?;
    let request_origin = parsed.origin().ascii_serialization();

    let success_origin = reqwest::Url::parse(&state.stripe_success_url)
        .map_err(|_| ApiError::Internal("stripe_success_url is not a valid URL".into()))?
        .origin()
        .ascii_serialization();
    let cancel_origin = reqwest::Url::parse(&state.stripe_cancel_url)
        .map_err(|_| ApiError::Internal("stripe_cancel_url is not a valid URL".into()))?
        .origin()
        .ascii_serialization();

    if request_origin != success_origin && request_origin != cancel_origin {
        return Err(ApiError::BadRequest(
            "return_url origin is not allowed".into(),
        ));
    }

    Ok(return_url.to_string())
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
    let return_url = validated_billing_return_url(&state, &req.return_url)?;
    let session = state
        .stripe_service
        .create_billing_portal_session(
            &stripe_customer_id,
            &crate::stripe::CreatePortalSessionRequest { return_url },
        )
        .await?;

    Ok(Json(BillingPortalSessionResponse {
        portal_url: session.url,
    }))
}

// GET /billing/publishable-key
#[utoipa::path(
    get,
    path = "/billing/publishable-key",
    tag = "Billing",
    responses(
        (status = 200, description = "Stripe publishable key", body = PublishableKeyResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 503, description = "Stripe publishable key unavailable", body = ErrorResponse),
    )
)]
pub async fn get_publishable_key(
    _tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let publishable_key = state
        .stripe_publishable_key
        .clone()
        .ok_or_else(|| ApiError::ServiceUnavailable("stripe_publishable_key_unavailable".into()))?;

    Ok(Json(PublishableKeyResponse { publishable_key }))
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

// POST /billing/upgrade
#[utoipa::path(
    post,
    path = "/billing/upgrade",
    tag = "Billing",
    responses(
        (status = 200, description = "Upgrade completed", body = BillingUpgradeResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Stripe customer/default payment method missing", body = ErrorResponse),
        (status = 402, description = "Card declined or customer action required", body = UpgradePaymentRequiredResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
        (status = 409, description = "Customer is no longer eligible for free-to-shared upgrade", body = ErrorResponse),
        (status = 503, description = "Billing service unavailable", body = ErrorResponse),
    )
)]
pub async fn upgrade_to_shared(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(tenant.customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    let stripe_customer_id = customer
        .stripe_customer_id
        .ok_or_else(|| ApiError::BadRequest("no stripe customer linked".into()))?;

    let payment_methods = state
        .stripe_service
        .list_payment_methods(&stripe_customer_id)
        .await?;
    if !has_default_payment_method(&payment_methods) {
        return Err(ApiError::BadRequest(
            "default payment method required".into(),
        ));
    }

    let active_rate_card = state
        .rate_card_repo
        .get_active()
        .await?
        .ok_or_else(|| ApiError::ServiceUnavailable("active rate card unavailable".into()))?;
    let activation_amount_cents = active_rate_card.shared_minimum_spend_cents;

    let subscription_cycle_anchor_at = Utc::now();
    let claimed = state
        .customer_repo
        .try_upgrade_to_shared_atomic(tenant.customer_id, subscription_cycle_anchor_at)
        .await?;
    if !claimed {
        return Err(ApiError::Conflict(
            "customer is not eligible for free-to-shared upgrade".into(),
        ));
    }

    let metadata = activation_invoice_metadata(tenant.customer_id, subscription_cycle_anchor_at);
    let idempotency_key =
        activation_upgrade_idempotency_key(tenant.customer_id, subscription_cycle_anchor_at);

    let finalized_invoice = match state
        .stripe_service
        .create_and_finalize_invoice(
            &stripe_customer_id,
            &[StripeInvoiceLineItem {
                description: "Shared plan activation".to_string(),
                amount_cents: activation_amount_cents,
            }],
            Some(&metadata),
            Some(&idempotency_key),
        )
        .await
    {
        Ok(invoice) => invoice,
        Err(err) => {
            rollback_upgrade_for_anchor(&state, tenant.customer_id, subscription_cycle_anchor_at)
                .await?;
            return Err(ApiError::from(err));
        }
    };

    let paid_invoice = match state
        .stripe_service
        .pay_invoice(&finalized_invoice.stripe_invoice_id)
        .await
    {
        Ok(payment) => payment,
        Err(err) => {
            rollback_upgrade_and_void_invoice(
                &state,
                tenant.customer_id,
                subscription_cycle_anchor_at,
                &finalized_invoice.stripe_invoice_id,
            )
            .await?;
            return Err(ApiError::from(err));
        }
    };

    if paid_invoice.status != "paid" {
        rollback_upgrade_and_void_invoice(
            &state,
            tenant.customer_id,
            subscription_cycle_anchor_at,
            &finalized_invoice.stripe_invoice_id,
        )
        .await?;
        if let Some(payment_required) = payment_required_response(&paid_invoice) {
            return Ok((StatusCode::PAYMENT_REQUIRED, Json(payment_required)).into_response());
        }
        return Err(ApiError::Internal(
            "activation invoice payment did not complete".into(),
        ));
    }

    if paid_invoice.amount_paid_cents != activation_amount_cents {
        rollback_upgrade_and_void_invoice(
            &state,
            tenant.customer_id,
            subscription_cycle_anchor_at,
            &finalized_invoice.stripe_invoice_id,
        )
        .await?;
        return Err(ApiError::Internal(
            "activation invoice amount mismatch".into(),
        ));
    }

    let persisted_customer = match state.customer_repo.find_by_id(tenant.customer_id).await {
        Ok(Some(customer)) => customer,
        Ok(None) => {
            rollback_upgrade_and_void_invoice(
                &state,
                tenant.customer_id,
                subscription_cycle_anchor_at,
                &finalized_invoice.stripe_invoice_id,
            )
            .await?;
            return Err(ApiError::Internal(
                "failed to verify persisted upgrade state".into(),
            ));
        }
        Err(repo_error) => {
            rollback_upgrade_and_void_invoice(
                &state,
                tenant.customer_id,
                subscription_cycle_anchor_at,
                &finalized_invoice.stripe_invoice_id,
            )
            .await?;
            return Err(ApiError::from(repo_error));
        }
    };
    let Some(persisted_anchor_at) = persisted_customer.subscription_cycle_anchor_at else {
        rollback_upgrade_and_void_invoice(
            &state,
            tenant.customer_id,
            subscription_cycle_anchor_at,
            &finalized_invoice.stripe_invoice_id,
        )
        .await?;
        return Err(ApiError::Internal(
            "failed to verify persisted upgrade state".into(),
        ));
    };
    if persisted_anchor_at != subscription_cycle_anchor_at {
        rollback_upgrade_and_void_invoice(
            &state,
            tenant.customer_id,
            persisted_anchor_at,
            &finalized_invoice.stripe_invoice_id,
        )
        .await?;
        return Err(ApiError::Internal(
            "failed to verify persisted upgrade state".into(),
        ));
    }
    if persisted_customer.billing_plan != "shared" {
        rollback_upgrade_and_void_invoice(
            &state,
            tenant.customer_id,
            subscription_cycle_anchor_at,
            &finalized_invoice.stripe_invoice_id,
        )
        .await?;
        return Err(ApiError::Internal(
            "failed to verify persisted upgrade state".into(),
        ));
    }

    Ok((
        StatusCode::OK,
        Json(BillingUpgradeResponse {
            billing_plan: BillingPlan::Shared,
            subscription_cycle_anchor_at: persisted_anchor_at,
            stripe_invoice_id: finalized_invoice.stripe_invoice_id,
            activation_amount_cents,
        }),
    )
        .into_response())
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
        customer.billing_plan_for_billing(),
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

use axum::extract::State;
use axum::http::header;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::helpers::lock_account_lifecycle;
use crate::models::{BillingPlan, Customer};
use crate::password::{hash_password, verify_password};
use crate::state::AppState;
use crate::validation::{validate_length, validate_password, MAX_NAME_LEN, MAX_PASSWORD_LEN};

const ACTIVE_AYB_DELETE_CONFLICT_MESSAGE: &str =
    "Delete your active AllYourBase instance before deleting your account.";

#[derive(Debug, Serialize, ToSchema)]
pub struct CustomerProfileResponse {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub email_verified: bool,
    pub billing_plan: BillingPlan,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct AccountExportResponse {
    /// Export intentionally includes only the customer-safe profile row and
    /// excludes password hash, Stripe/customer billing internals, API keys,
    /// verification/reset tokens, status, updated_at, quota-warning, and
    /// object-storage carry-forward fields.
    pub profile: CustomerProfileResponse,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct UpdateProfileRequest {
    pub name: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct DeleteAccountRequest {
    pub password: String,
}

impl From<Customer> for CustomerProfileResponse {
    fn from(customer: Customer) -> Self {
        let billing_plan = customer.billing_plan_enum();

        Self {
            id: customer.id,
            name: customer.name,
            email: customer.email,
            email_verified: customer.email_verified_at.is_some(),
            billing_plan,
            created_at: customer.created_at,
        }
    }
}

async fn find_customer(state: &AppState, customer_id: Uuid) -> Result<Customer, ApiError> {
    state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))
}

fn password_hash(customer: &Customer) -> Result<&str, ApiError> {
    customer
        .password_hash
        .as_deref()
        .ok_or_else(|| ApiError::BadRequest("no password set for this account".into()))
}

// GET /account
#[utoipa::path(
    get,
    path = "/account",
    tag = "Account",
    responses(
        (status = 200, description = "Customer profile", body = CustomerProfileResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
pub async fn get_profile(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = find_customer(&state, tenant.customer_id).await?;
    Ok(Json(CustomerProfileResponse::from(customer)))
}

// GET /account/export
#[utoipa::path(
    get,
    path = "/account/export",
    tag = "Account",
    responses(
        (status = 200, description = "Account export payload", body = AccountExportResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
pub async fn export_account(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = find_customer(&state, tenant.customer_id).await?;
    Ok((
        [(header::CACHE_CONTROL, "private, no-store")],
        Json(AccountExportResponse {
            profile: CustomerProfileResponse::from(customer),
        }),
    ))
}

// PATCH /account
#[utoipa::path(
    patch,
    path = "/account",
    tag = "Account",
    request_body = UpdateProfileRequest,
    responses(
        (status = 200, description = "Profile updated", body = CustomerProfileResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Validation error", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
/// `PATCH /account` — update the authenticated customer's display name.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Trims and validates the name length, then persists the change.
/// Returns the full `CustomerProfileResponse`.
pub async fn update_profile(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<UpdateProfileRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let name = req.name.trim();
    if name.is_empty() {
        return Err(ApiError::BadRequest("name must not be empty".into()));
    }
    validate_length("name", name, MAX_NAME_LEN)?;

    let customer = state
        .customer_repo
        .update(tenant.customer_id, Some(name), None)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    Ok(Json(CustomerProfileResponse::from(customer)))
}

// POST /account/change-password
#[utoipa::path(
    post,
    path = "/account/change-password",
    tag = "Account",
    request_body = ChangePasswordRequest,
    responses(
        (status = 204, description = "Password changed"),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Validation error", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
/// `POST /account/change-password` — rotate the authenticated customer's password.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Verifies `current_password` against the stored bcrypt hash before accepting
/// the new password. Returns 204 on success, 400 if the current password is
/// incorrect or the new password fails validation.
pub async fn change_password(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<ChangePasswordRequest>,
) -> Result<impl IntoResponse, ApiError> {
    validate_length("current password", &req.current_password, MAX_PASSWORD_LEN)?;
    validate_password(&req.new_password)?;

    let customer = find_customer(&state, tenant.customer_id).await?;
    let current_hash = password_hash(&customer)?;

    if !verify_password(&req.current_password, current_hash) {
        return Err(ApiError::BadRequest("current password is incorrect".into()));
    }

    let new_hash = hash_password(&req.new_password)?;

    state
        .customer_repo
        .change_password(tenant.customer_id, &new_hash)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

// DELETE /account
#[utoipa::path(
    delete,
    path = "/account",
    tag = "Account",
    request_body = DeleteAccountRequest,
    responses(
        (status = 204, description = "Account deleted"),
        (status = 409, description = "Active AllYourBase instance must be deleted first", body = ErrorResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 400, description = "Validation error", body = ErrorResponse),
        (status = 404, description = "Customer not found", body = ErrorResponse),
    )
)]
/// `DELETE /account` — soft-delete the authenticated customer's account.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Requires the customer's current password as confirmation. Sets the
/// customer status to "deleted" (soft delete — row retained for audit).
/// Rejects deletion with 409 while the customer still has active local
/// AllYourBase tenant rows.
/// Returns 204 on success.
pub async fn delete_account(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(req): Json<DeleteAccountRequest>,
) -> Result<impl IntoResponse, ApiError> {
    validate_length("password", &req.password, MAX_PASSWORD_LEN)?;

    let customer = find_customer(&state, tenant.customer_id).await?;
    let password_hash = password_hash(&customer)?;

    if !verify_password(&req.password, password_hash) {
        return Err(ApiError::BadRequest("password is incorrect".into()));
    }

    let _account_lifecycle_lock = lock_account_lifecycle(&state, tenant.customer_id).await?;

    let active_ayb_tenants = state
        .ayb_tenant_repo
        .find_active_by_customer(tenant.customer_id)
        .await?;
    if !active_ayb_tenants.is_empty() {
        return Err(ApiError::Conflict(
            ACTIVE_AYB_DELETE_CONFLICT_MESSAGE.into(),
        ));
    }

    let deleted = state.customer_repo.soft_delete(tenant.customer_id).await?;
    if !deleted {
        return Err(ApiError::NotFound("customer not found".into()));
    }

    Ok(StatusCode::NO_CONTENT)
}

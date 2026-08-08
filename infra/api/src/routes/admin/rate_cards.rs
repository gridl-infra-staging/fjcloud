//! Admin rate card routes: CRUD and customer override management.
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::models::RateCardRow;
use crate::services::audit_log::{write_audit_log, ACTION_RATE_CARD_OVERRIDE};
use crate::state::AppState;
use crate::validation::validate_non_negative_decimal;

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// Customer rate override request. Every field here must reach generated
/// invoice behavior — `minimum_spend_cents` is deliberately absent because
/// nothing consumes a per-customer minimum spend floor (migration
/// `049_free_plan_zero_minimum_spend.sql` removed the last consumer). The
/// `deny_unknown_fields` attribute makes that withdrawal observable: a caller
/// still sending the dead knob gets 422 instead of a silent drop.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetRateOverrideRequest {
    pub storage_rate_per_mb_month: Option<String>,
    pub cold_storage_rate_per_gb_month: Option<String>,
    pub object_storage_rate_per_gb_month: Option<String>,
    pub object_storage_egress_rate_per_gb: Option<String>,
    pub shared_minimum_spend_cents: Option<i64>,
    pub region_multipliers: Option<serde_json::Value>,
}

impl SetRateOverrideRequest {
    /// Returns true if no override fields are set.
    fn is_empty(&self) -> bool {
        self.storage_rate_per_mb_month.is_none()
            && self.cold_storage_rate_per_gb_month.is_none()
            && self.object_storage_rate_per_gb_month.is_none()
            && self.object_storage_egress_rate_per_gb.is_none()
            && self.shared_minimum_spend_cents.is_none()
            && self.region_multipliers.is_none()
    }

    /// Validate all override fields and build a JSON object for persistence.
    ///
    /// Decimal rate fields are validated via `validate_non_negative_decimal`;
    /// integer fields via `insert_non_negative_integer`. Region multipliers
    /// are normalized through `RateCardRow::normalized_region_multiplier_value`.
    fn to_overrides_json(&self) -> Result<serde_json::Value, ApiError> {
        let mut map = serde_json::Map::new();

        // Validate and insert each decimal rate field.
        let decimal_fields: &[(&str, &Option<String>)] = &[
            ("storage_rate_per_mb_month", &self.storage_rate_per_mb_month),
            (
                "cold_storage_rate_per_gb_month",
                &self.cold_storage_rate_per_gb_month,
            ),
            (
                "object_storage_rate_per_gb_month",
                &self.object_storage_rate_per_gb_month,
            ),
            (
                "object_storage_egress_rate_per_gb",
                &self.object_storage_egress_rate_per_gb,
            ),
        ];
        for (name, value) in decimal_fields {
            if let Some(v) = value {
                let dec = validate_non_negative_decimal(name, v)?;
                map.insert((*name).into(), serde_json::Value::String(dec.to_string()));
            }
        }

        insert_non_negative_integer(
            &mut map,
            "shared_minimum_spend_cents",
            self.shared_minimum_spend_cents,
        )?;
        if let Some(ref v) = self.region_multipliers {
            map.insert(
                "region_multipliers".into(),
                RateCardRow::normalized_region_multiplier_value(v).map_err(|_| {
                    ApiError::BadRequest(
                        "region_multipliers must be an object of decimal strings keyed by region"
                            .into(),
                    )
                })?,
            );
        }

        Ok(serde_json::Value::Object(map))
    }
}

#[derive(Debug, Serialize)]
pub struct RateCardResponse {
    pub id: Uuid,
    pub name: String,
    pub storage_rate_per_mb_month: String,
    pub cold_storage_rate_per_gb_month: String,
    pub object_storage_rate_per_gb_month: String,
    pub object_storage_egress_rate_per_gb: String,
    pub region_multipliers: HashMap<String, String>,
    /// Retained: the rate card's base minimum spend is still reported to admins.
    /// Only the per-customer *override* of this value was withdrawn.
    pub minimum_spend_cents: i64,
    pub shared_minimum_spend_cents: i64,
    pub has_override: bool,
    pub override_fields: serde_json::Value,
}

/// Build the admin rate card response, merging base card with customer overrides.
///
/// Applies overrides via `card.with_overrides()` to produce effective values,
/// parses region multipliers into a `HashMap`, and flags whether any overrides
/// are active.
fn build_rate_card_response(
    card: &RateCardRow,
    override_json: Option<&serde_json::Value>,
) -> Result<RateCardResponse, ApiError> {
    let effective = match override_json {
        Some(ov) => card.with_overrides(ov)?,
        None => card.clone(),
    };

    let multipliers: HashMap<String, String> =
        RateCardRow::parse_region_multiplier_map(&effective.region_multipliers)?
            .into_iter()
            .map(|(k, v)| (k, v.to_string()))
            .collect();

    let (has_override, override_fields) = match override_json {
        Some(ov) if ov.as_object().is_some_and(|m| !m.is_empty()) => (true, ov.clone()),
        _ => (false, serde_json::json!({})),
    };

    Ok(RateCardResponse {
        id: card.id,
        name: card.name.clone(),
        storage_rate_per_mb_month: effective.storage_rate_per_mb_month.to_string(),
        cold_storage_rate_per_gb_month: effective.cold_storage_rate_per_gb_month.to_string(),
        object_storage_rate_per_gb_month: effective.object_storage_rate_per_gb_month.to_string(),
        object_storage_egress_rate_per_gb: effective.object_storage_egress_rate_per_gb.to_string(),
        region_multipliers: multipliers,
        // Base value survives; the route can no longer set an override for it,
        // but historical override rows still apply through `with_overrides`.
        minimum_spend_cents: effective.minimum_spend_cents,
        shared_minimum_spend_cents: effective.shared_minimum_spend_cents,
        has_override,
        override_fields,
    })
}

/// Validate that an integer value is >= 0 and insert it into a JSON map.
///
/// No-op when `value` is `None`. Returns 400 if the value is negative.
fn insert_non_negative_integer(
    map: &mut serde_json::Map<String, serde_json::Value>,
    field: &str,
    value: Option<i64>,
) -> Result<(), ApiError> {
    let Some(value) = value else {
        return Ok(());
    };

    if value < 0 {
        return Err(ApiError::BadRequest(format!(
            "{field} must not be negative"
        )));
    }

    map.insert(field.into(), serde_json::Value::Number(value.into()));
    Ok(())
}

async fn get_active_rate_card(state: &AppState) -> Result<RateCardRow, ApiError> {
    state
        .rate_card_repo
        .get_active()
        .await?
        .ok_or_else(|| ApiError::NotFound("no active rate card".into()))
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `GET /admin/tenants/{id}/rate-card` — retrieve the active rate card with customer overrides.
///
/// **Auth:** `AdminAuth`.
/// Returns the base rate card merged with any customer-specific override row.
pub async fn get_rate_card(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let card = get_active_rate_card(&state).await?;

    // Check for override
    let override_row = state
        .rate_card_repo
        .get_override(customer_id, card.id)
        .await?;

    let override_json = override_row.as_ref().map(|r| &r.overrides);
    let response = build_rate_card_response(&card, override_json)?;
    Ok(Json(response))
}

/// `PUT /admin/tenants/{id}/rate-card` — set or update customer-specific rate overrides.
///
/// **Auth:** `AdminAuth`.
/// Requires at least one override field. Validates decimal and integer fields,
/// then upserts the override row against the active rate card.
///
/// `SetRateOverrideRequest` is `deny_unknown_fields`, so any key outside the
/// accepted set — notably the withdrawn `minimum_spend_cents` — is rejected at
/// deserialization. Axum 0.7 renders that schema mismatch as 422 Unprocessable
/// Entity before the handler runs, not as `ApiError::BadRequest`.
pub async fn set_rate_override(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(req): Json<SetRateOverrideRequest>,
) -> Result<impl IntoResponse, ApiError> {
    // Validate at least one field
    if req.is_empty() {
        return Err(ApiError::BadRequest("no fields to update".into()));
    }

    // Validate decimals and build overrides JSON
    let overrides_json = req.to_overrides_json()?;

    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let card = get_active_rate_card(&state).await?;

    // Upsert override
    let override_row = state
        .rate_card_repo
        .upsert_override(customer_id, card.id, overrides_json)
        .await?;

    let mut override_field_keys = override_row
        .overrides
        .as_object()
        .map(|map| map.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    override_field_keys.sort();

    if let Err(err) = write_audit_log(
        &state.pool,
        auth.operator_id,
        ACTION_RATE_CARD_OVERRIDE,
        Some(customer_id),
        serde_json::json!({ "override_field_keys": override_field_keys }),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %customer_id,
            "failed to write rate_card_override audit_log row"
        );
    }

    let response = build_rate_card_response(&card, Some(&override_row.overrides))?;
    Ok(Json(response))
}

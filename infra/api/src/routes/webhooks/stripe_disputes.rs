//! Stripe dispute webhook handling helpers.
use std::collections::HashMap;

use crate::errors::ApiError;
use crate::models::InvoiceRow;
use crate::repos::{DisputeRow, DisputeUpsertInput};
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::audit_log::{
    write_audit_log, ACTION_STRIPE_DISPUTE_UPDATED, ADMIN_SENTINEL_ACTOR_ID,
};
use crate::state::AppState;

pub(super) async fn handle_charge_dispute_event(
    state: &AppState,
    event_type: &str,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let object = &data["object"];
    let stripe_dispute_id = match object["id"].as_str() {
        Some(value) => value,
        None => return Ok(()),
    };
    let stripe_charge_id = match object["charge"].as_str() {
        Some(value) => value,
        None => return Ok(()),
    };
    let stripe_customer_id = object["customer"].as_str().map(str::to_string);
    let fallback_payment_intent_id = object["payment_intent"].as_str().map(str::to_string);

    let (invoice_id, resolved_invoice, resolution_source, resolved_payment_intent_id) =
        resolve_invoice_for_dispute_event(
            state,
            stripe_charge_id,
            fallback_payment_intent_id.as_deref(),
        )
        .await?;
    let target_customer_id = resolve_dispute_customer_id(
        state,
        resolved_invoice.as_ref(),
        stripe_customer_id.as_deref(),
    )
    .await;

    let status = dispute_status_for_event(event_type, object);
    let now = chrono::Utc::now();
    let disputed_at = matches!(event_type, "charge.dispute.created").then_some(now);
    let resolved_at = matches!(
        event_type,
        "charge.dispute.funds_reinstated" | "charge.dispute.closed"
    )
    .then_some(now);

    let upsert_input = DisputeUpsertInput {
        stripe_dispute_id: stripe_dispute_id.to_string(),
        stripe_charge_id: stripe_charge_id.to_string(),
        stripe_payment_intent_id: resolved_payment_intent_id.or(fallback_payment_intent_id),
        invoice_id,
        amount_cents: object["amount"].as_i64().unwrap_or_default(),
        currency: object["currency"]
            .as_str()
            .unwrap_or("usd")
            .to_string()
            .to_lowercase(),
        reason: object["reason"].as_str().map(str::to_string),
        status: status.to_string(),
        evidence_due_by: object["evidence_details"]["due_by"]
            .as_i64()
            .and_then(|epoch| chrono::DateTime::from_timestamp(epoch, 0)),
        disputed_at,
        resolved_at,
    };

    let dispute = state.dispute_repo.upsert(&upsert_input).await?;
    apply_dispute_invoice_terminal_transition(state, event_type, status, resolved_invoice.as_ref())
        .await?;

    if should_alert_for_dispute_event(event_type) {
        super::send_alert_best_effort(
            state,
            dispute_alert(
                event_type,
                &dispute,
                target_customer_id,
                stripe_customer_id.as_deref(),
                resolution_source,
            ),
        )
        .await;
    }

    write_dispute_audit_best_effort(
        state,
        resolved_invoice.as_ref(),
        stripe_customer_id.as_deref(),
        event_type,
        resolution_source,
        &dispute,
    )
    .await;

    Ok(())
}

fn dispute_status_for_event<'a>(event_type: &str, object: &'a serde_json::Value) -> &'a str {
    match event_type {
        "charge.dispute.created" => "needs_response",
        "charge.dispute.funds_withdrawn" => "warning_needs_response",
        "charge.dispute.funds_reinstated" => "won",
        "charge.dispute.closed" => object["status"].as_str().unwrap_or("warning_closed"),
        _ => object["status"].as_str().unwrap_or("needs_response"),
    }
}

fn should_alert_for_dispute_event(event_type: &str) -> bool {
    matches!(
        event_type,
        "charge.dispute.created" | "charge.dispute.funds_withdrawn"
    )
}

async fn find_invoice_by_stripe_invoice_id(
    state: &AppState,
    stripe_invoice_id: &str,
) -> Result<Option<InvoiceRow>, ApiError> {
    Ok(state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?)
}

async fn find_customer_id_by_stripe_customer_id_best_effort(
    state: &AppState,
    stripe_customer_id: &str,
    warning_context: &str,
) -> Option<uuid::Uuid> {
    match state
        .customer_repo
        .find_by_stripe_customer_id(stripe_customer_id)
        .await
    {
        Ok(customer) => customer.map(|row| row.id),
        Err(error) => {
            tracing::warn!("{warning_context}: {error}");
            None
        }
    }
}

fn dispute_alert(
    event_type: &str,
    dispute: &DisputeRow,
    customer_id: Option<uuid::Uuid>,
    stripe_customer_id: Option<&str>,
    resolution_source: &str,
) -> Alert {
    let mut metadata = HashMap::from([
        (
            "stripe_dispute_id".to_string(),
            dispute.stripe_dispute_id.to_string(),
        ),
        (
            "stripe_charge_id".to_string(),
            dispute.stripe_charge_id.to_string(),
        ),
        (
            "invoice_resolution_source".to_string(),
            resolution_source.to_string(),
        ),
    ]);
    if let Some(customer_id) = stripe_customer_id {
        metadata.insert("stripe_customer_id".to_string(), customer_id.to_string());
    }
    if let Some(customer_id) = customer_id {
        metadata.insert("customer_id".to_string(), customer_id.to_string());
    }
    if let Some(invoice_id) = dispute.invoice_id {
        metadata.insert("invoice_id".to_string(), invoice_id.to_string());
    }

    let severity =
        if event_type == "charge.dispute.funds_withdrawn" || resolution_source == "unresolved" {
            AlertSeverity::Critical
        } else {
            AlertSeverity::Warning
        };
    Alert {
        severity,
        title: format!("Stripe dispute update: {event_type}"),
        message: format!(
            "Dispute {} processed with status {}",
            dispute.stripe_dispute_id, dispute.status
        ),
        metadata,
    }
}

/// TODO: Document resolve_dispute_target_customer_id.
async fn resolve_dispute_customer_id(
    state: &AppState,
    invoice: Option<&InvoiceRow>,
    stripe_customer_id: Option<&str>,
) -> Option<uuid::Uuid> {
    if let Some(invoice) = invoice {
        return Some(invoice.customer_id);
    }

    find_customer_id_by_stripe_customer_id_best_effort(
        state,
        stripe_customer_id?,
        "failed to resolve dispute customer by stripe id",
    )
    .await
}

async fn resolve_invoice_for_dispute_event(
    state: &AppState,
    stripe_charge_id: &str,
    payment_intent_hint: Option<&str>,
) -> Result<
    (
        Option<uuid::Uuid>,
        Option<InvoiceRow>,
        &'static str,
        Option<String>,
    ),
    ApiError,
> {
    if let Some(payment_intent_id) = payment_intent_hint {
        if let Some(stripe_invoice_id) = state
            .webhook_event_repo
            .find_latest_invoice_id_by_payment_intent(payment_intent_id)
            .await?
        {
            if let Some(invoice) =
                find_invoice_by_stripe_invoice_id(state, &stripe_invoice_id).await?
            {
                return Ok((
                    Some(invoice.id),
                    Some(invoice),
                    "webhook_event",
                    Some(payment_intent_id.to_string()),
                ));
            }
        }
    }

    match state
        .stripe_service
        .lookup_charge_fallback_fields(stripe_charge_id)
        .await
    {
        Ok(lookup) => {
            if let Some(stripe_invoice_id) = lookup.invoice_id.clone() {
                if let Some(invoice) =
                    find_invoice_by_stripe_invoice_id(state, &stripe_invoice_id).await?
                {
                    return Ok((
                        Some(invoice.id),
                        Some(invoice),
                        "charge_lookup",
                        lookup.payment_intent_id,
                    ));
                }
            }
            Ok((None, None, "unresolved", lookup.payment_intent_id))
        }
        Err(error) => {
            tracing::warn!(
                "charge lookup fallback failed for dispute charge {stripe_charge_id}: {error}"
            );
            Ok((
                None,
                None,
                "unresolved",
                payment_intent_hint.map(str::to_string),
            ))
        }
    }
}

async fn apply_dispute_invoice_terminal_transition(
    state: &AppState,
    event_type: &str,
    dispute_status: &str,
    invoice: Option<&InvoiceRow>,
) -> Result<(), ApiError> {
    let Some(invoice) = invoice else {
        return Ok(());
    };
    if invoice.status != "paid" {
        return Ok(());
    }
    if should_mark_dispute_invoice_refunded(event_type, dispute_status) {
        state.invoice_repo.mark_refunded(invoice.id).await?;
    }
    Ok(())
}

fn is_losing_dispute_status(dispute_status: &str) -> bool {
    dispute_status.eq_ignore_ascii_case("lost")
}

fn should_mark_dispute_invoice_refunded(event_type: &str, dispute_status: &str) -> bool {
    event_type == "charge.dispute.funds_withdrawn"
        || (event_type == "charge.dispute.closed" && is_losing_dispute_status(dispute_status))
}

async fn write_dispute_audit_best_effort(
    state: &AppState,
    invoice: Option<&InvoiceRow>,
    stripe_customer_id: Option<&str>,
    event_type: &str,
    resolution_source: &str,
    dispute: &DisputeRow,
) {
    let target_tenant_id = resolve_dispute_customer_id(state, invoice, stripe_customer_id).await;

    if let Err(error) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
        ACTION_STRIPE_DISPUTE_UPDATED,
        target_tenant_id,
        serde_json::json!({
            "event_type": event_type,
            "invoice_resolution_source": resolution_source,
            "stripe_dispute_id": dispute.stripe_dispute_id,
            "stripe_charge_id": dispute.stripe_charge_id,
            "status": dispute.status,
            "invoice_id": dispute.invoice_id,
        }),
    )
    .await
    {
        tracing::error!("failed to write dispute audit row: {error}");
    }
}

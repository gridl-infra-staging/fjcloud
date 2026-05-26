use std::collections::HashMap;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use base64::Engine as _;
use openssl::hash::MessageDigest;
use openssl::sign::Verifier;
use openssl::x509::X509;
use serde::Deserialize;

use crate::errors::ApiError;
use crate::models::{Customer, InvoiceRow};
use crate::repos::DisputeUpsertInput;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::audit_log::{
    write_audit_log, ACTION_SES_COMPLAINT_SUPPRESSED, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
    ACTION_STRIPE_DISPUTE_UPDATED, ADMIN_SENTINEL_ACTOR_ID,
};
use crate::services::email::{
    DunningRecoveredAfterFailureEmailRequest, DunningRetriesExhaustedEmailRequest,
    DunningRetryScheduledEmailRequest,
};
use crate::services::email_suppression::{
    normalize_recipient_email, EmailSuppressionStore, PgEmailSuppressionStore,
};
use crate::state::AppState;

const SNS_NOTIFICATION: &str = "Notification";
const SNS_SUBSCRIPTION_CONFIRMATION: &str = "SubscriptionConfirmation";
const SNS_UNSUBSCRIBE_CONFIRMATION: &str = "UnsubscribeConfirmation";
const SNS_SUPPRESSION_SOURCE: &str = "ses_sns_webhook";
const TRUSTED_SNS_ACCOUNT_ID: &str = "213880904778";
const TRUSTED_SES_FEEDBACK_TOPIC_PREFIX: &str = "fjcloud-ses-feedback-";

/// `POST /webhooks/ses/sns` — receive AWS SNS events carrying SES feedback.
///
/// Supported SNS types:
/// - `Notification`: parse SES payload and suppress permanent bounces + complaints
/// - `SubscriptionConfirmation`: verify signature then confirm subscription URL
/// - `UnsubscribeConfirmation`: verify signature then no-op
///
/// Signature verification is always completed before any DB write or outbound
/// subscription-confirmation call.
pub async fn ses_sns_webhook(
    State(state): State<AppState>,
    body: String,
) -> Result<StatusCode, ApiError> {
    // Log the underlying ApiError on rejection — the request_logging
    // middleware only records HTTP status, not the variant message.
    process_ses_sns_request(&state, &body)
        .await
        .inspect_err(|err| {
            tracing::warn!(target: "api::routes::webhooks::ses_sns",
            body_len = body.len(), error = ?err, "ses_sns_webhook rejected");
        })
}

async fn process_ses_sns_request(state: &AppState, body: &str) -> Result<StatusCode, ApiError> {
    let envelope = parse_sns_envelope(body)?;
    let sns_type = parse_sns_type(&envelope.sns_type)?;
    validate_sns_topic_arn(&envelope.topic_arn)?;
    validate_sns_url(&envelope.signing_cert_url, "SigningCertURL")?;
    if let Some(subscribe_url) = envelope.subscribe_url.as_deref() {
        validate_sns_url(subscribe_url, "SubscribeURL")?;
    }
    verify_sns_signature(state, &envelope, sns_type).await?;
    match sns_type {
        SnsType::SubscriptionConfirmation => confirm_subscription(state, &envelope).await?,
        SnsType::Notification => handle_ses_notification(state, &envelope).await?,
        SnsType::UnsubscribeConfirmation => {}
    }
    Ok(StatusCode::OK)
}

/// `POST /webhooks/stripe` — receive and process Stripe webhook events.
///
/// **Auth:** Stripe signature verification (`stripe-signature` header), no JWT.
/// Verifies the webhook signature against the configured secret, then
/// deduplicates via `webhook_event_repo.try_insert` (idempotent — exactly one
/// caller wins first insert for each `stripe_event_id`). Duplicate deliveries
/// return `200` immediately if the persisted row is already marked processed;
/// unprocessed duplicates are re-processed (Stripe retries after a failed first
/// attempt must not be permanently rejected). Dispatches to event-specific
/// handlers based on `event_type`, then marks the event as processed.
pub async fn stripe_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: String,
) -> Result<StatusCode, ApiError> {
    let webhook_secret = state
        .stripe_webhook_secret
        .as_deref()
        .ok_or_else(|| ApiError::Internal("webhook secret not configured".into()))?;

    let signature = headers
        .get("stripe-signature")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| ApiError::BadRequest("missing stripe-signature header".into()))?;

    let event = state
        .stripe_service
        .construct_webhook_event(&body, signature, webhook_secret)
        .map_err(|_| ApiError::BadRequest("invalid webhook signature".into()))?;

    // Idempotency: process event only for the single caller that inserted
    // this stripe_event_id row first.
    let payload: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| ApiError::BadRequest(format!("invalid JSON payload: {e}")))?;

    let should_process = state
        .webhook_event_repo
        .try_insert(&event.id, &event.event_type, &payload)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    if !should_process {
        let existing = state
            .webhook_event_repo
            .find_by_stripe_event_id(&event.id)
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
        match existing {
            Some(row) if row.processed_at.is_some() => {
                tracing::info!(
                    event_id = event.id,
                    event_type = event.event_type,
                    "acknowledging duplicate webhook delivery for already processed event"
                );
                return Ok(StatusCode::OK);
            }
            Some(_) => {
                tracing::warn!(
                    event_id = event.id,
                    event_type = event.event_type,
                    "rejecting duplicate webhook delivery because event is persisted but still unprocessed"
                );
                return Err(ApiError::Internal(
                    "webhook event already exists but is not marked processed".into(),
                ));
            }
            None => {
                return Err(ApiError::Internal(format!(
                    "webhook event {} reported duplicate insert but row not found",
                    event.id
                )));
            }
        }
    }

    let handler_result = match event.event_type.as_str() {
        "invoice.payment_succeeded" => handle_payment_succeeded(&state, &event.data).await,
        "invoice.payment_failed" => handle_payment_failed(&state, &event.data).await,
        "invoice.payment_action_required" => {
            handle_payment_action_required(&state, &event.data).await
        }
        "checkout.session.completed"
        | "customer.subscription.created"
        | "customer.subscription.updated"
        | "customer.subscription.deleted" => {
            tracing::info!(
                event_id = event.id,
                event_type = event.event_type,
                "acknowledged deprecated Stripe subscription webhook event as no-op"
            );
            Ok(())
        }
        "charge.refunded" => handle_charge_refunded(&state, &event.data).await,
        "charge.dispute.created"
        | "charge.dispute.funds_withdrawn"
        | "charge.dispute.funds_reinstated"
        | "charge.dispute.closed" => {
            handle_charge_dispute_event(&state, &event.event_type, &event.data).await
        }
        _ => {
            tracing::debug!("ignoring webhook event type: {}", event.event_type);
            Ok(())
        }
    };

    if let Err(e) = handler_result {
        let _ = state.webhook_event_repo.delete_unprocessed(&event.id).await;
        return Err(e);
    }

    state
        .webhook_event_repo
        .mark_processed(&event.id)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok(StatusCode::OK)
}

fn invoice_object_id<'a>(data: &'a serde_json::Value, event_type: &str) -> Option<&'a str> {
    match data["object"]["id"].as_str() {
        Some(id) => Some(id),
        None => {
            tracing::warn!("{event_type} event missing invoice id in data.object");
            None
        }
    }
}

fn invoice_alert_metadata(invoice: &InvoiceRow) -> HashMap<String, String> {
    HashMap::from([
        ("customer_id".to_string(), invoice.customer_id.to_string()),
        ("invoice_id".to_string(), invoice.id.to_string()),
        ("amount_cents".to_string(), invoice.total_cents.to_string()),
    ])
}

/// Handle `invoice.payment_succeeded` — mark the invoice paid and recover suspended customers.
///
/// Looks up the invoice by `stripe_invoice_id`. Only transitions invoices
/// in `finalized` or `failed` status to `paid`. If the invoice was previously
/// `failed`, reactivates the customer and
/// sends an info-level recovery alert.
async fn handle_payment_succeeded(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let Some(stripe_invoice_id) = invoice_object_id(data, "invoice.payment_succeeded") else {
        return Ok(());
    };

    let Some(invoice) = state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?
    else {
        return Ok(());
    };

    let was_failed = invoice.status == "failed";
    if invoice.status != "finalized" && !was_failed {
        return Ok(());
    }

    state.invoice_repo.mark_paid(invoice.id).await?;

    if !was_failed {
        return Ok(());
    }

    let customer = state
        .customer_repo
        .find_by_id(invoice.customer_id)
        .await
        .ok()
        .flatten();
    let Some(customer) = customer else {
        return Ok(());
    };

    match state.customer_repo.reactivate(invoice.customer_id).await {
        Ok(true) => {
            send_dunning_recovered_after_failure_email_best_effort(
                state,
                &customer.email,
                &invoice,
            )
            .await;
        }
        Ok(false) => {
            tracing::warn!(
                "customer {} was not suspended during payment recovery; skipping recovery dunning email",
                invoice.customer_id
            );
        }
        Err(e) => {
            tracing::error!(
                "failed to reactivate customer {} after payment recovery: {e}",
                invoice.customer_id
            );
        }
    }

    let mut metadata = invoice_alert_metadata(&invoice);
    metadata.insert("customer_email".to_string(), customer.email);

    send_alert_best_effort(
        state,
        Alert {
            severity: AlertSeverity::Info,
            title: format!("Payment recovered — invoice {}", invoice.id),
            message: format!(
                "Previously failed invoice {} was paid successfully for customer {}",
                invoice.id, invoice.customer_id
            ),
            metadata,
        },
    )
    .await;

    Ok(())
}

async fn handle_payment_failed(state: &AppState, data: &serde_json::Value) -> Result<(), ApiError> {
    let Some(stripe_invoice_id) = invoice_object_id(data, "invoice.payment_failed") else {
        return Ok(());
    };

    let next_payment_attempt_is_null = data["object"]["next_payment_attempt"].is_null();
    let next_payment_attempt = data["object"]["next_payment_attempt"].as_i64();
    let attempt_count = data["object"]["attempt_count"]
        .as_i64()
        .and_then(|value| u32::try_from(value).ok());

    if let Some(invoice) = state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?
    {
        let customer = state
            .customer_repo
            .find_by_id(invoice.customer_id)
            .await
            .ok()
            .flatten();

        let mut metadata = invoice_alert_metadata(&invoice);
        if let Some(count) = attempt_count {
            metadata.insert("attempt_count".to_string(), count.to_string());
        }

        if next_payment_attempt_is_null {
            handle_retries_exhausted(state, &invoice, customer, metadata, attempt_count).await?;
        } else {
            handle_retry_scheduled(
                state,
                &invoice,
                customer,
                metadata,
                next_payment_attempt,
                attempt_count,
            )
            .await?;
        }
    }

    Ok(())
}

/// Handle `invoice.payment_action_required` by sending a warning alert.
async fn handle_payment_action_required(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let Some(stripe_invoice_id) = invoice_object_id(data, "invoice.payment_action_required") else {
        return Ok(());
    };

    let Some(invoice) = state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?
    else {
        return Ok(());
    };

    let metadata = invoice_alert_metadata(&invoice);

    send_alert_best_effort(
        state,
        Alert {
            severity: AlertSeverity::Warning,
            title: format!("Payment action required — invoice {}", invoice.id),
            message: format!(
                "Action required to recover payment for invoice {} (customer {})",
                invoice.id, invoice.customer_id
            ),
            metadata,
        },
    )
    .await;

    Ok(())
}

/// Handle `charge.refunded` — mark the associated invoice as refunded.
///
/// Looks up the invoice via `data.object.invoice`. Only transitions
/// invoices in `paid` status to `refunded`; other statuses are ignored.
async fn handle_charge_refunded(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let mut stripe_invoice_id = data["object"]["invoice"].as_str().map(str::to_string);

    if stripe_invoice_id.is_none() {
        if let Some(payment_intent_id) = data["object"]["payment_intent"].as_str() {
            stripe_invoice_id = state
                .webhook_event_repo
                .find_latest_invoice_id_by_payment_intent(payment_intent_id)
                .await?;
        }
    }

    if stripe_invoice_id.is_none() {
        if let Some(stripe_customer_id) = data["object"]["customer"].as_str() {
            if let Some(customer) = state
                .customer_repo
                .find_by_stripe_customer_id(stripe_customer_id)
                .await?
            {
                let amount_refunded = data["object"]["amount_refunded"].as_i64();
                let mut invoices = state.invoice_repo.list_by_customer(customer.id).await?;
                invoices.sort_by_key(|invoice| invoice.paid_at);
                invoices.reverse();

                stripe_invoice_id = invoices.into_iter().find_map(|invoice| {
                    if invoice.status != "paid" {
                        return None;
                    }
                    if amount_refunded.is_some_and(|amount| invoice.total_cents != amount) {
                        return None;
                    }
                    invoice.stripe_invoice_id
                });
            }
        }
    }

    let Some(stripe_invoice_id) = stripe_invoice_id else {
        tracing::warn!(
            "charge.refunded event missing invoice mapping (invoice/payment_intent/customer fallback all unresolved)"
        );
        return Ok(());
    };

    if let Some(invoice) = state
        .invoice_repo
        .find_by_stripe_invoice_id(&stripe_invoice_id)
        .await?
    {
        if invoice.status == "paid" {
            state.invoice_repo.mark_refunded(invoice.id).await?;
        }
    }

    Ok(())
}

/// Handle payment retries exhausted: mark invoice failed, suspend customer,
/// and fire critical alert.
async fn handle_retries_exhausted(
    state: &AppState,
    invoice: &InvoiceRow,
    customer: Option<Customer>,
    mut metadata: HashMap<String, String>,
    attempt_count: Option<u32>,
) -> Result<(), ApiError> {
    match invoice.status.as_str() {
        "finalized" => {
            state.invoice_repo.mark_failed(invoice.id).await?;
        }
        "failed" => {
            // Keep going: allow existing retry state to continue to suspension.
        }
        _ => return Ok(()),
    }

    state.customer_repo.suspend(invoice.customer_id).await?;
    if let Some(customer) = customer {
        metadata.insert("customer_email".to_string(), customer.email.clone());
        send_dunning_retries_exhausted_email_best_effort(
            state,
            &customer.email,
            invoice,
            attempt_count,
        )
        .await;
    }

    send_alert_best_effort(
        state,
        Alert {
            severity: AlertSeverity::Critical,
            title: format!("Payment retries exhausted — invoice {}", invoice.id),
            message: format!(
                "Customer {} suspended after exhausted payment retries on invoice {}",
                invoice.customer_id, invoice.id
            ),
            metadata,
        },
    )
    .await;

    tracing::warn!(
        "customer {} suspended due to exhausted payment retries for invoice {}",
        invoice.customer_id,
        invoice.id
    );

    Ok(())
}

/// Handle payment failed with retries remaining: fire warning alert with
/// next_payment_attempt timestamp. Only processes finalized invoices.
async fn handle_retry_scheduled(
    state: &AppState,
    invoice: &InvoiceRow,
    customer: Option<Customer>,
    mut metadata: HashMap<String, String>,
    next_payment_attempt: Option<i64>,
    attempt_count: Option<u32>,
) -> Result<(), ApiError> {
    if invoice.status != "finalized" {
        return Ok(());
    }

    if let Some(next_attempt) = next_payment_attempt {
        metadata.insert("next_payment_attempt".to_string(), next_attempt.to_string());
        if let Some(customer) = customer {
            send_dunning_retry_scheduled_email_best_effort(
                state,
                &customer.email,
                invoice,
                next_attempt,
                attempt_count,
            )
            .await;
        }
    }

    send_alert_best_effort(
        state,
        Alert {
            severity: AlertSeverity::Warning,
            title: format!("Payment failed — invoice {}", invoice.id),
            message: format!(
                "Payment failed for invoice {} (customer {}), retries remaining",
                invoice.id, invoice.customer_id
            ),
            metadata,
        },
    )
    .await;

    tracing::info!(
        "payment failed for invoice {}, next attempt scheduled",
        invoice.id
    );

    Ok(())
}

async fn send_alert_best_effort(state: &AppState, alert: Alert) {
    if let Err(err) = state.alert_service.send_alert(alert).await {
        tracing::warn!("failed to send webhook alert: {err}");
    }
}

async fn handle_charge_dispute_event(
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
    let target_customer_id = resolve_dispute_target_customer_id(
        state,
        resolved_invoice.as_ref(),
        stripe_customer_id.as_deref(),
    )
    .await;

    let status = dispute_status_for_event(event_type, object);
    let now = chrono::Utc::now();
    let disputed_at = if event_type == "charge.dispute.created" {
        Some(now)
    } else {
        None
    };
    let resolved_at = if event_type == "charge.dispute.funds_reinstated"
        || event_type == "charge.dispute.closed"
    {
        Some(now)
    } else {
        None
    };

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
        send_alert_best_effort(
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
        dispute.invoice_id,
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
    event_type == "charge.dispute.created" || event_type == "charge.dispute.funds_withdrawn"
}

fn dispute_alert(
    event_type: &str,
    dispute: &crate::repos::DisputeRow,
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

async fn resolve_dispute_target_customer_id(
    state: &AppState,
    invoice: Option<&InvoiceRow>,
    stripe_customer_id: Option<&str>,
) -> Option<uuid::Uuid> {
    if let Some(invoice) = invoice {
        return Some(invoice.customer_id);
    }
    let stripe_customer_id = stripe_customer_id?;
    match state
        .customer_repo
        .find_by_stripe_customer_id(stripe_customer_id)
        .await
    {
        Ok(customer) => customer.map(|row| row.id),
        Err(error) => {
            tracing::warn!("failed to resolve dispute customer by stripe id: {error}");
            None
        }
    }
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
            if let Some(invoice) = state
                .invoice_repo
                .find_by_stripe_invoice_id(&stripe_invoice_id)
                .await?
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
                if let Some(invoice) = state
                    .invoice_repo
                    .find_by_stripe_invoice_id(&stripe_invoice_id)
                    .await?
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
    if event_type == "charge.dispute.funds_withdrawn"
        || (event_type == "charge.dispute.closed" && is_losing_dispute_status(dispute_status))
    {
        state.invoice_repo.mark_refunded(invoice.id).await?;
    }
    Ok(())
}

fn is_losing_dispute_status(dispute_status: &str) -> bool {
    dispute_status.eq_ignore_ascii_case("lost")
}

async fn write_dispute_audit_best_effort(
    state: &AppState,
    invoice_id: Option<uuid::Uuid>,
    stripe_customer_id: Option<&str>,
    event_type: &str,
    resolution_source: &str,
    dispute: &crate::repos::DisputeRow,
) {
    let target_tenant_id = if let Some(invoice_id) = invoice_id {
        match state.invoice_repo.find_by_id(invoice_id).await {
            Ok(invoice) => invoice.map(|row| row.customer_id),
            Err(error) => {
                tracing::warn!("failed to resolve invoice for dispute audit target: {error}");
                None
            }
        }
    } else if let Some(stripe_customer_id) = stripe_customer_id {
        match state
            .customer_repo
            .find_by_stripe_customer_id(stripe_customer_id)
            .await
        {
            Ok(customer) => customer.map(|row| row.id),
            Err(error) => {
                tracing::warn!(
                    "failed to resolve stripe customer for dispute audit target: {error}"
                );
                None
            }
        }
    } else {
        None
    };

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

async fn send_dunning_retry_scheduled_email_best_effort(
    state: &AppState,
    to: &str,
    invoice: &InvoiceRow,
    next_payment_attempt_unix_seconds: i64,
    attempt_count: Option<u32>,
) {
    if state.dunning_emails_disabled {
        return;
    }

    let customer_id = invoice.customer_id.to_string();
    let invoice_id = invoice.id.to_string();
    let request = DunningRetryScheduledEmailRequest {
        customer_id: &customer_id,
        invoice_id: &invoice_id,
        hosted_invoice_url: invoice.hosted_invoice_url.as_deref(),
        next_payment_attempt_unix_seconds,
        attempt_count,
    };
    if let Err(err) = state
        .email_service
        .send_dunning_retry_scheduled_email(to, &request)
        .await
    {
        tracing::warn!(
            "failed to send retry-scheduled dunning email for invoice {}: {err}",
            invoice.id
        );
    }
}

async fn send_dunning_retries_exhausted_email_best_effort(
    state: &AppState,
    to: &str,
    invoice: &InvoiceRow,
    attempt_count: Option<u32>,
) {
    if state.dunning_emails_disabled {
        return;
    }

    let customer_id = invoice.customer_id.to_string();
    let invoice_id = invoice.id.to_string();
    let request = DunningRetriesExhaustedEmailRequest {
        customer_id: &customer_id,
        invoice_id: &invoice_id,
        hosted_invoice_url: invoice.hosted_invoice_url.as_deref(),
        attempt_count,
    };
    if let Err(err) = state
        .email_service
        .send_dunning_retries_exhausted_email(to, &request)
        .await
    {
        tracing::warn!(
            "failed to send retries-exhausted dunning email for invoice {}: {err}",
            invoice.id
        );
    }
}

async fn send_dunning_recovered_after_failure_email_best_effort(
    state: &AppState,
    to: &str,
    invoice: &InvoiceRow,
) {
    if state.dunning_emails_disabled {
        return;
    }

    let customer_id = invoice.customer_id.to_string();
    let invoice_id = invoice.id.to_string();
    let request = DunningRecoveredAfterFailureEmailRequest {
        customer_id: &customer_id,
        invoice_id: &invoice_id,
        hosted_invoice_url: invoice.hosted_invoice_url.as_deref(),
    };
    if let Err(err) = state
        .email_service
        .send_dunning_recovered_after_failure_email(to, &request)
        .await
    {
        tracing::warn!(
            "failed to send recovered-after-failure dunning email for invoice {}: {err}",
            invoice.id
        );
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SnsType {
    Notification,
    SubscriptionConfirmation,
    UnsubscribeConfirmation,
}

#[derive(Debug, Deserialize)]
struct SnsEnvelope {
    #[serde(rename = "Type")]
    sns_type: String,
    #[serde(rename = "MessageId")]
    message_id: String,
    #[serde(rename = "TopicArn")]
    topic_arn: String,
    #[serde(rename = "Message")]
    message: String,
    #[serde(rename = "Timestamp")]
    timestamp: String,
    #[serde(rename = "SignatureVersion")]
    signature_version: String,
    #[serde(rename = "Signature")]
    signature: String,
    #[serde(rename = "SigningCertURL")]
    signing_cert_url: String,
    #[serde(rename = "Subject")]
    subject: Option<String>,
    #[serde(rename = "Token")]
    token: Option<String>,
    #[serde(rename = "SubscribeURL")]
    subscribe_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SesNotification {
    // AWS SESv2 config-set event destination publishes with `eventType`
    // (NOT `notificationType` — that's the older SES Email Receiving
    // format). Pinned by webhooks_ses_event_payload_tests.rs.
    #[serde(rename = "eventType")]
    notification_type: String,
    mail: SesMail,
    bounce: Option<SesBounce>,
    complaint: Option<SesComplaint>,
}

#[derive(Debug, Deserialize)]
struct SesMail {
    #[serde(rename = "messageId")]
    message_id: String,
}

#[derive(Debug, Deserialize)]
struct SesBounce {
    #[serde(rename = "bounceType")]
    bounce_type: String,
    #[serde(rename = "bounceSubType")]
    bounce_sub_type: String,
    #[serde(rename = "bouncedRecipients")]
    bounced_recipients: Vec<SesRecipient>,
}

#[derive(Debug, Deserialize)]
struct SesComplaint {
    #[serde(rename = "complainedRecipients")]
    complained_recipients: Vec<SesRecipient>,
}

#[derive(Debug, Deserialize)]
struct SesRecipient {
    #[serde(rename = "emailAddress")]
    email_address: String,
}

fn parse_sns_envelope(body: &str) -> Result<SnsEnvelope, ApiError> {
    let envelope: SnsEnvelope = serde_json::from_str(body)
        .map_err(|error| ApiError::BadRequest(format!("invalid SNS envelope JSON: {error}")))?;

    let required = [
        ("Type", envelope.sns_type.as_str()),
        ("MessageId", envelope.message_id.as_str()),
        ("TopicArn", envelope.topic_arn.as_str()),
        ("Message", envelope.message.as_str()),
        ("Timestamp", envelope.timestamp.as_str()),
        ("SignatureVersion", envelope.signature_version.as_str()),
        ("Signature", envelope.signature.as_str()),
        ("SigningCertURL", envelope.signing_cert_url.as_str()),
    ];
    for (field, value) in required {
        if value.trim().is_empty() {
            return Err(ApiError::BadRequest(format!(
                "missing required SNS field: {field}"
            )));
        }
    }

    Ok(envelope)
}

fn parse_sns_type(value: &str) -> Result<SnsType, ApiError> {
    match value {
        SNS_NOTIFICATION => Ok(SnsType::Notification),
        SNS_SUBSCRIPTION_CONFIRMATION => Ok(SnsType::SubscriptionConfirmation),
        SNS_UNSUBSCRIBE_CONFIRMATION => Ok(SnsType::UnsubscribeConfirmation),
        _ => Err(ApiError::BadRequest(format!(
            "unsupported SNS Type: {value}"
        ))),
    }
}

/// Reject cross-account or wrong-topic SNS envelopes before we trust their
/// signed payload. AWS signatures prove "an AWS SNS topic sent this", not "our
/// SES feedback topic sent this". Without an ARN allowlist, an attacker can
/// create their own SNS topic, trick us into auto-confirming it, then publish
/// signed Notification messages that suppress arbitrary recipients.
fn validate_sns_topic_arn(topic_arn: &str) -> Result<(), ApiError> {
    let segments: Vec<&str> = topic_arn.split(':').collect();
    if segments.len() != 6 {
        return Err(ApiError::BadRequest(format!(
            "TopicArn must use AWS ARN format: {topic_arn}"
        )));
    }
    if segments[0] != "arn" || segments[1] != "aws" || segments[2] != "sns" {
        return Err(ApiError::BadRequest(format!(
            "TopicArn must be an AWS SNS ARN: {topic_arn}"
        )));
    }
    if segments[3].is_empty() {
        return Err(ApiError::BadRequest("TopicArn region is empty".to_string()));
    }
    if segments[4] != TRUSTED_SNS_ACCOUNT_ID {
        return Err(ApiError::BadRequest(format!(
            "TopicArn account is not trusted: {}",
            segments[4]
        )));
    }
    if !segments[5].starts_with(TRUSTED_SES_FEEDBACK_TOPIC_PREFIX) {
        return Err(ApiError::BadRequest(format!(
            "TopicArn topic is not trusted: {}",
            segments[5]
        )));
    }
    Ok(())
}

fn validate_sns_url(url_value: &str, field_name: &str) -> Result<(), ApiError> {
    let parsed = reqwest::Url::parse(url_value).map_err(|error| {
        ApiError::BadRequest(format!("{field_name} is not a valid URL: {error}"))
    })?;
    if parsed.scheme() != "https" {
        return Err(ApiError::BadRequest(format!("{field_name} must use https")));
    }

    let Some(host) = parsed.host_str() else {
        return Err(ApiError::BadRequest(format!(
            "{field_name} must include a host"
        )));
    };

    if !is_trusted_sns_host(host) {
        return Err(ApiError::BadRequest(format!(
            "{field_name} host is not trusted: {host}"
        )));
    }

    Ok(())
}

fn is_trusted_sns_host(host: &str) -> bool {
    let Some(prefix) = host.strip_suffix(".amazonaws.com") else {
        return false;
    };
    prefix.starts_with("sns.") && prefix.len() > "sns.".len()
}

fn required_subscription_url(envelope: &SnsEnvelope) -> Result<&str, ApiError> {
    envelope
        .subscribe_url
        .as_deref()
        .filter(|url| !url.trim().is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing required SNS field: SubscribeURL".to_string()))
}

fn required_subscription_token(envelope: &SnsEnvelope) -> Result<&str, ApiError> {
    envelope
        .token
        .as_deref()
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| ApiError::BadRequest("missing required SNS field: Token".to_string()))
}

async fn verify_sns_signature(
    state: &AppState,
    envelope: &SnsEnvelope,
    sns_type: SnsType,
) -> Result<(), ApiError> {
    let canonical = canonical_sns_string(envelope, sns_type)?;
    let digest = match envelope.signature_version.as_str() {
        "1" => MessageDigest::sha1(),
        "2" => MessageDigest::sha256(),
        _ => {
            return Err(ApiError::BadRequest(format!(
                "unsupported SNS SignatureVersion: {}",
                envelope.signature_version
            )))
        }
    };

    let signature_bytes = base64::engine::general_purpose::STANDARD
        .decode(envelope.signature.as_bytes())
        .map_err(|error| {
            ApiError::BadRequest(format!("invalid SNS signature encoding: {error}"))
        })?;

    let cert_pem = state
        .webhook_http_client
        .get_text(&envelope.signing_cert_url)
        .await
        .map_err(|error| ApiError::BadRequest(format!("failed to fetch signing cert: {error}")))?;
    let cert = X509::from_pem(cert_pem.as_bytes())
        .map_err(|error| ApiError::BadRequest(format!("invalid signing cert PEM: {error}")))?;
    let public_key = cert.public_key().map_err(|error| {
        ApiError::BadRequest(format!("invalid signing cert public key: {error}"))
    })?;
    let mut verifier = Verifier::new(digest, &public_key).map_err(|error| {
        ApiError::BadRequest(format!("failed to initialize signature verifier: {error}"))
    })?;
    verifier.update(canonical.as_bytes()).map_err(|error| {
        ApiError::BadRequest(format!("failed to feed signature payload: {error}"))
    })?;

    let is_valid = verifier.verify(&signature_bytes).map_err(|error| {
        ApiError::BadRequest(format!("failed to verify SNS signature: {error}"))
    })?;
    if !is_valid {
        return Err(ApiError::BadRequest("invalid SNS signature".to_string()));
    }

    Ok(())
}

/// Build the canonical signing string per the AWS SNS HTTP/HTTPS signature
/// spec, used as input to SHA1/SHA256 signature verification.
///
/// Format (load-bearing — must match AWS exactly, off-by-one-byte breaks
/// every real-world signature):
///   `<Key1>\n<Value1>\n<Key2>\n<Value2>\n...\n<KeyN>\n<ValueN>\n`
///
/// In particular, each key AND each value is followed by `\n`, including
/// the final value. A previous version of this function used `join("\n")`
/// which omitted the trailing `\n` on the last value; that produced a
/// canonical string one byte short of what AWS signed, so every real
/// SubscriptionConfirmation and Notification was rejected at signature
/// verification while unit tests still passed (because the unit-test
/// fixture mirrored the same off-by-one canonicalization). Symptom in
/// the wild: SNS subscriptions stuck in PendingConfirmation because our
/// handler returned 400 on AWS's redelivered confirmations.
///
/// Reference: https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
fn canonical_sns_string(envelope: &SnsEnvelope, sns_type: SnsType) -> Result<String, ApiError> {
    let mut fields: Vec<(&str, &str)> = Vec::new();
    fields.push(("Message", envelope.message.as_str()));
    fields.push(("MessageId", envelope.message_id.as_str()));

    match sns_type {
        SnsType::Notification => {
            if let Some(subject) = envelope.subject.as_deref() {
                if !subject.is_empty() {
                    fields.push(("Subject", subject));
                }
            }
            fields.push(("Timestamp", envelope.timestamp.as_str()));
        }
        SnsType::SubscriptionConfirmation | SnsType::UnsubscribeConfirmation => {
            fields.push(("SubscribeURL", required_subscription_url(envelope)?));
            fields.push(("Timestamp", envelope.timestamp.as_str()));
            fields.push(("Token", required_subscription_token(envelope)?));
        }
    }

    fields.push(("TopicArn", envelope.topic_arn.as_str()));
    fields.push(("Type", envelope.sns_type.as_str()));

    // Each (key, value) pair contributes `key\nvalue\n` — the trailing `\n`
    // on the last value is what AWS's signing process does, so omitting it
    // would produce a canonical string one byte short of AWS's input.
    let mut out = String::new();
    for (key, value) in &fields {
        out.push_str(key);
        out.push('\n');
        out.push_str(value);
        out.push('\n');
    }
    Ok(out)
}

async fn confirm_subscription(state: &AppState, envelope: &SnsEnvelope) -> Result<(), ApiError> {
    let subscribe_url = required_subscription_url(envelope)?;
    state
        .webhook_http_client
        .get_success(subscribe_url)
        .await
        .map_err(|error| ApiError::BadRequest(format!("subscription confirmation failed: {error}")))
}

async fn handle_ses_notification(state: &AppState, envelope: &SnsEnvelope) -> Result<(), ApiError> {
    let notification: SesNotification =
        serde_json::from_str(&envelope.message).map_err(|error| {
            ApiError::BadRequest(format!("invalid SES notification payload JSON: {error}"))
        })?;

    match notification.notification_type.as_str() {
        "Bounce" => handle_bounce_notification(state, envelope, &notification).await,
        "Complaint" => handle_complaint_notification(state, envelope, &notification).await,
        _ => Ok(()),
    }
}

async fn handle_bounce_notification(
    state: &AppState,
    envelope: &SnsEnvelope,
    notification: &SesNotification,
) -> Result<(), ApiError> {
    let Some(bounce) = notification.bounce.as_ref() else {
        return Err(ApiError::BadRequest(
            "SES bounce notification missing bounce payload".to_string(),
        ));
    };

    if bounce.bounce_type != "Permanent" {
        return Ok(());
    }

    let recipient = extract_recipient_from_bounce(bounce)?;
    let normalized_recipient = normalize_recipient_email(&recipient);
    if normalized_recipient.is_empty() {
        return Err(ApiError::BadRequest(
            "SES bounce recipient email is empty".to_string(),
        ));
    }

    let suppression_reason = format!(
        "bounce_{}_{}",
        bounce.bounce_type.to_ascii_lowercase(),
        bounce.bounce_sub_type.to_ascii_lowercase()
    );
    let suppression_store = PgEmailSuppressionStore::new(state.pool.clone());
    suppression_store
        .upsert_suppressed_recipient(
            &normalized_recipient,
            &suppression_reason,
            SNS_SUPPRESSION_SOURCE,
        )
        .await
        .map_err(ApiError::Internal)?;

    write_ses_suppression_audit(
        state,
        ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
        &normalized_recipient,
        serde_json::json!({
            "recipient_email": normalized_recipient,
            "sns_message_id": envelope.message_id,
            "sns_topic_arn": envelope.topic_arn,
            "ses_mail_message_id": notification.mail.message_id,
            "notification_type": notification.notification_type,
            "bounce_type": bounce.bounce_type,
            "bounce_sub_type": bounce.bounce_sub_type,
            "suppression_reason": suppression_reason,
        }),
    )
    .await;

    send_alert_best_effort(
        state,
        ses_suppression_alert(
            AlertSeverity::Warning,
            "SES permanent bounce suppressed recipient",
            &normalized_recipient,
            &notification.mail.message_id,
            &suppression_reason,
        ),
    )
    .await;

    Ok(())
}

async fn handle_complaint_notification(
    state: &AppState,
    envelope: &SnsEnvelope,
    notification: &SesNotification,
) -> Result<(), ApiError> {
    let Some(complaint) = notification.complaint.as_ref() else {
        return Err(ApiError::BadRequest(
            "SES complaint notification missing complaint payload".to_string(),
        ));
    };

    let recipient = extract_recipient_from_complaint(complaint)?;
    let normalized_recipient = normalize_recipient_email(&recipient);
    if normalized_recipient.is_empty() {
        return Err(ApiError::BadRequest(
            "SES complaint recipient email is empty".to_string(),
        ));
    }

    let suppression_store = PgEmailSuppressionStore::new(state.pool.clone());
    suppression_store
        .upsert_suppressed_recipient(&normalized_recipient, "complaint", SNS_SUPPRESSION_SOURCE)
        .await
        .map_err(ApiError::Internal)?;

    write_ses_suppression_audit(
        state,
        ACTION_SES_COMPLAINT_SUPPRESSED,
        &normalized_recipient,
        serde_json::json!({
            "recipient_email": normalized_recipient,
            "sns_message_id": envelope.message_id,
            "sns_topic_arn": envelope.topic_arn,
            "ses_mail_message_id": notification.mail.message_id,
            "notification_type": notification.notification_type,
            "suppression_reason": "complaint",
        }),
    )
    .await;

    send_alert_best_effort(
        state,
        ses_suppression_alert(
            AlertSeverity::Warning,
            "SES complaint suppressed recipient",
            &normalized_recipient,
            &notification.mail.message_id,
            "complaint",
        ),
    )
    .await;

    Ok(())
}

fn ses_suppression_alert(
    severity: AlertSeverity,
    title_prefix: &str,
    recipient_email: &str,
    ses_mail_message_id: &str,
    suppression_reason: &str,
) -> Alert {
    let mut metadata = HashMap::new();
    metadata.insert("recipient_email".to_string(), recipient_email.to_string());
    metadata.insert(
        "ses_mail_message_id".to_string(),
        ses_mail_message_id.to_string(),
    );
    metadata.insert(
        "suppression_reason".to_string(),
        suppression_reason.to_string(),
    );

    Alert {
        severity,
        title: format!("{title_prefix} {recipient_email}"),
        message: format!(
            "Recipient {recipient_email} was suppressed for {suppression_reason} (ses_mail_message_id={ses_mail_message_id})"
        ),
        metadata,
    }
}

fn extract_recipient_from_bounce(bounce: &SesBounce) -> Result<String, ApiError> {
    let Some(first) = bounce.bounced_recipients.first() else {
        return Err(ApiError::BadRequest(
            "SES bounce has no recipients".to_string(),
        ));
    };
    Ok(first.email_address.clone())
}

fn extract_recipient_from_complaint(complaint: &SesComplaint) -> Result<String, ApiError> {
    let Some(first) = complaint.complained_recipients.first() else {
        return Err(ApiError::BadRequest(
            "SES complaint has no recipients".to_string(),
        ));
    };
    Ok(first.email_address.clone())
}

async fn write_ses_suppression_audit(
    state: &AppState,
    action: &str,
    normalized_recipient: &str,
    metadata: serde_json::Value,
) {
    let target_tenant_id = match state
        .customer_repo
        .find_by_email(normalized_recipient)
        .await
    {
        Ok(customer) => customer.map(|row| row.id),
        Err(error) => {
            tracing::warn!(
                "failed to correlate SES suppression audit target for {}: {}",
                normalized_recipient,
                error
            );
            None
        }
    };

    if let Err(error) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
        action,
        target_tenant_id,
        metadata,
    )
    .await
    {
        tracing::error!("failed to write SES suppression audit row: {error}");
    }
}

// Regression tests pinning the AWS-SNS-spec canonical signing-string
// format byte-for-byte. Located in a sibling file so this module stays
// under the file-size guardrail; the `#[path]` form keeps the tests
// scoped INSIDE this `webhooks` module so `use super::*;` in the test
// file resolves the private `SnsType`, `SnsEnvelope`, and
// `canonical_sns_string` items it asserts against.
//
// Spec: https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
#[cfg(test)]
#[path = "webhooks_canonical_sns_string_tests.rs"]
mod canonical_sns_string_tests;

// Regression tests for the AWS SESv2 event-destination payload format.
// Sibling file for the same size-guardrail reason as the SNS tests above.
#[cfg(test)]
#[path = "webhooks_ses_event_payload_tests.rs"]
mod ses_event_payload_tests;

#[cfg(test)]
mod sns_topic_arn_tests {
    use super::*;

    #[test]
    fn accepts_trusted_ses_feedback_topic_arn() {
        let trusted = "arn:aws:sns:us-east-1:213880904778:fjcloud-ses-feedback-staging";
        assert!(validate_sns_topic_arn(trusted).is_ok());
    }

    #[test]
    fn rejects_untrusted_account_even_when_topic_name_matches() {
        let err = validate_sns_topic_arn(
            "arn:aws:sns:us-east-1:999999999999:fjcloud-ses-feedback-staging",
        )
        .unwrap_err();
        assert!(
            matches!(err, ApiError::BadRequest(ref message) if message.contains("TopicArn account is not trusted")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn rejects_non_feedback_topic_in_trusted_account() {
        let err =
            validate_sns_topic_arn("arn:aws:sns:us-east-1:213880904778:attacker-controlled-topic")
                .unwrap_err();
        assert!(
            matches!(err, ApiError::BadRequest(ref message) if message.contains("TopicArn topic is not trusted")),
            "unexpected error: {err:?}"
        );
    }
}

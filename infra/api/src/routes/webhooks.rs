use std::collections::HashMap;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use base64::Engine as _;
use chrono::NaiveDate;
use openssl::hash::MessageDigest;
use openssl::sign::Verifier;
use openssl::x509::X509;
use serde::Deserialize;

use crate::errors::ApiError;
use crate::models::{Customer, InvoiceRow, PlanTier, SubscriptionStatus};
use crate::repos::error::RepoError;
use crate::repos::subscription_repo::NewSubscription;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::audit_log::{
    write_audit_log, ACTION_SES_COMPLAINT_SUPPRESSED, ACTION_SES_PERMANENT_BOUNCE_SUPPRESSED,
    ADMIN_SENTINEL_ACTOR_ID,
};
use crate::services::email_suppression::{
    normalize_recipient_email, EmailSuppressionStore, PgEmailSuppressionStore,
};
use crate::state::AppState;

const SNS_NOTIFICATION: &str = "Notification";
const SNS_SUBSCRIPTION_CONFIRMATION: &str = "SubscriptionConfirmation";
const SNS_UNSUBSCRIBE_CONFIRMATION: &str = "UnsubscribeConfirmation";
const SNS_SUPPRESSION_SOURCE: &str = "ses_sns_webhook";

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
/// deduplicates via `webhook_event_repo.try_insert` (idempotent — replayed
/// events return 200 without reprocessing). Dispatches to event-specific
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

    // Idempotency: process event only if it is new or previously unprocessed.
    let payload: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| ApiError::BadRequest(format!("invalid JSON payload: {e}")))?;

    let should_process = state
        .webhook_event_repo
        .try_insert(&event.id, &event.event_type, &payload)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    if !should_process {
        return Ok(StatusCode::OK);
    }

    match event.event_type.as_str() {
        "invoice.payment_succeeded" => {
            handle_payment_succeeded(&state, &event.data).await?;
        }
        "invoice.payment_failed" => {
            handle_payment_failed(&state, &event.data).await?;
        }
        "invoice.payment_action_required" => {
            handle_payment_action_required(&state, &event.data).await?;
        }
        "customer.subscription.created" => {
            handle_subscription_created(&state, &event.data).await?;
        }
        "customer.subscription.updated" => {
            handle_subscription_updated(&state, &event.data).await?;
        }
        "customer.subscription.deleted" => {
            handle_subscription_deleted(&state, &event.data).await?;
        }
        "checkout.session.completed" => {
            handle_checkout_session_completed(&state, &event.data).await?;
        }
        "charge.refunded" => {
            handle_charge_refunded(&state, &event.data).await?;
        }
        _ => {
            tracing::debug!("ignoring webhook event type: {}", event.event_type);
        }
    }

    state
        .webhook_event_repo
        .mark_processed(&event.id)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok(StatusCode::OK)
}

/// Handle `invoice.payment_succeeded` — mark the invoice paid and recover suspended customers.
///
/// Looks up the invoice by `stripe_invoice_id`. Only transitions invoices
/// in `finalized` or `failed` status to `paid`. Calls
/// `set_subscription_active_after_payment` to clear delinquent state.
/// If the invoice was previously `failed`, reactivates the customer and
/// sends an info-level recovery alert.
async fn handle_payment_succeeded(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let stripe_invoice_id = match data["object"]["id"].as_str() {
        Some(id) => id,
        None => {
            tracing::warn!("invoice.payment_succeeded event missing invoice id in data.object");
            return Ok(());
        }
    };

    if let Some(invoice) = state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?
    {
        let was_failed = invoice.status == "failed";
        let transitioned_to_paid = invoice.status == "finalized" || was_failed;
        if !transitioned_to_paid {
            return Ok(());
        }

        state.invoice_repo.mark_paid(invoice.id).await?;
        if let Err(e) = set_subscription_active_after_payment(state, invoice.customer_id).await {
            tracing::error!(
                "failed to transition subscription after successful payment: {:?}",
                e
            );
        }

        let customer = state
            .customer_repo
            .find_by_id(invoice.customer_id)
            .await
            .ok()
            .flatten();
        if let Some(customer) = customer {
            if was_failed {
                if let Err(e) = state.customer_repo.reactivate(invoice.customer_id).await {
                    tracing::error!(
                        "failed to reactivate customer {} after payment recovery: {e}",
                        invoice.customer_id
                    );
                }

                let mut metadata = HashMap::new();
                metadata.insert("customer_id".to_string(), invoice.customer_id.to_string());
                metadata.insert("invoice_id".to_string(), invoice.id.to_string());
                metadata.insert("amount_cents".to_string(), invoice.total_cents.to_string());
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
            }
        }
    }

    Ok(())
}

/// Transition a delinquent subscription back to `active` after a successful payment.
///
/// Only transitions subscriptions in a delinquent state (e.g. `past_due`)
/// back to `active`. No-op if the customer has no subscription or the
/// subscription is already non-delinquent.
async fn set_subscription_active_after_payment(
    state: &AppState,
    customer_id: uuid::Uuid,
) -> Result<(), ApiError> {
    let subscription = match state
        .subscription_repo
        .find_by_customer(customer_id)
        .await?
    {
        Some(subscription) => subscription,
        None => return Ok(()),
    };

    let status = subscription.parsed_status().map_err(ApiError::Internal)?;

    if status.is_delinquent() {
        let status: SubscriptionStatus = "active".parse().map_err(ApiError::Internal)?;
        state
            .subscription_repo
            .update_status(subscription.id, status)
            .await?;
    }

    Ok(())
}

async fn handle_payment_failed(state: &AppState, data: &serde_json::Value) -> Result<(), ApiError> {
    let stripe_invoice_id = match data["object"]["id"].as_str() {
        Some(id) => id,
        None => {
            tracing::warn!("invoice.payment_failed event missing invoice id in data.object");
            return Ok(());
        }
    };

    let next_payment_attempt_is_null = data["object"]["next_payment_attempt"].is_null();
    let next_payment_attempt = data["object"]["next_payment_attempt"]
        .as_i64()
        .map(|v| v.to_string());
    let attempt_count = data["object"]["attempt_count"]
        .as_i64()
        .map(|v| v.to_string());

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

        let mut metadata = HashMap::new();
        metadata.insert("customer_id".to_string(), invoice.customer_id.to_string());
        metadata.insert("invoice_id".to_string(), invoice.id.to_string());
        metadata.insert("amount_cents".to_string(), invoice.total_cents.to_string());
        if let Some(count) = attempt_count {
            metadata.insert("attempt_count".to_string(), count);
        }

        if next_payment_attempt_is_null {
            handle_retries_exhausted(state, &invoice, customer, metadata).await?;
        } else {
            handle_retry_scheduled(state, &invoice, metadata, next_payment_attempt).await?;
        }
    }

    Ok(())
}

/// Handle `invoice.payment_action_required` — mark subscription past-due.
///
/// Transitions the customer's subscription to `PastDue` and sends a
/// warning alert with the invoice amount and customer identifiers.
async fn handle_payment_action_required(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let stripe_invoice_id = match data["object"]["id"].as_str() {
        Some(id) => id,
        None => {
            tracing::warn!(
                "invoice.payment_action_required event missing invoice id in data.object"
            );
            return Ok(());
        }
    };

    let invoice = match state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?
    {
        Some(invoice) => invoice,
        None => return Ok(()),
    };

    if let Some(subscription) = state
        .subscription_repo
        .find_by_customer(invoice.customer_id)
        .await?
    {
        state
            .subscription_repo
            .update_status(subscription.id, SubscriptionStatus::PastDue)
            .await?;

        let mut metadata = HashMap::new();
        metadata.insert("customer_id".to_string(), invoice.customer_id.to_string());
        metadata.insert("invoice_id".to_string(), invoice.id.to_string());
        metadata.insert("amount_cents".to_string(), invoice.total_cents.to_string());

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
    }

    Ok(())
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
async fn handle_subscription_created(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    handle_subscription_change(state, data, "created", SubscriptionStatusAction::Create).await
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
async fn handle_subscription_updated(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    handle_subscription_change(state, data, "updated", SubscriptionStatusAction::Update).await
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
async fn handle_subscription_deleted(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    handle_subscription_change(state, data, "deleted", SubscriptionStatusAction::Delete).await
}

/// Shared logic for subscription.updated and subscription.deleted webhook events.
/// Tries to parse the payload from the event data, falling back to a Stripe API lookup.
async fn handle_subscription_change(
    state: &AppState,
    data: &serde_json::Value,
    event_name: &str,
    action: SubscriptionStatusAction,
) -> Result<(), ApiError> {
    let payload = match parse_subscription_payload_from_event(state, data) {
        Some(payload) => payload,
        None => {
            let subscription_id = match extract_subscription_id(data) {
                Some(id) => id,
                None => {
                    tracing::warn!(
                        "customer.subscription.{event_name} event missing required fields and no fallback id"
                    );
                    return Ok(());
                }
            };
            match fetch_subscription_payload_from_stripe(state, &subscription_id).await? {
                Some(payload) => payload,
                None => {
                    tracing::warn!(
                        "customer.subscription.{event_name} event could not be reconciled from payload or Stripe lookup"
                    );
                    return Ok(());
                }
            }
        }
    };

    apply_subscription_payload(state, payload, action).await
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
async fn apply_subscription_payload(
    state: &AppState,
    payload: SubscriptionPayload,
    action: SubscriptionStatusAction,
) -> Result<(), ApiError> {
    let customer = match state
        .customer_repo
        .find_by_stripe_customer_id(&payload.stripe_customer_id)
        .await
    {
        Ok(Some(customer)) => customer,
        Ok(None) => {
            tracing::warn!(
                subscription_id = payload.stripe_subscription_id,
                "subscription event skipped: no customer for stripe customer id {}",
                payload.stripe_customer_id
            );
            return Ok(());
        }
        Err(err) => {
            return Err(ApiError::Internal(format!(
                "failed to resolve customer from stripe customer id {}: {err}",
                payload.stripe_customer_id
            )))
        }
    };

    let status = match action {
        SubscriptionStatusAction::Delete => SubscriptionStatus::Canceled,
        _ => payload.status,
    };

    if let Some(existing) = state
        .subscription_repo
        .find_by_stripe_id(&payload.stripe_subscription_id)
        .await?
    {
        state
            .subscription_repo
            .update_status(existing.id, status)
            .await?;
        state
            .subscription_repo
            .update_plan(existing.id, payload.plan_tier, &payload.stripe_price_id)
            .await?;
        state
            .subscription_repo
            .update_period(
                existing.id,
                payload.current_period_start,
                payload.current_period_end,
            )
            .await?;
        state
            .subscription_repo
            .set_cancel_at_period_end(existing.id, payload.cancel_at_period_end)
            .await?;
        return Ok(());
    }

    let create_error = state
        .subscription_repo
        .create(NewSubscription {
            customer_id: customer.id,
            stripe_subscription_id: payload.stripe_subscription_id,
            stripe_price_id: payload.stripe_price_id,
            plan_tier: payload.plan_tier,
            status,
            current_period_start: payload.current_period_start,
            current_period_end: payload.current_period_end,
            cancel_at_period_end: payload.cancel_at_period_end,
        })
        .await
        .err();

    match create_error {
        Some(RepoError::Conflict(_)) => {
            tracing::warn!(
                "subscription row already exists for reconcile payload; skipping create"
            );
            Ok(())
        }
        Some(other) => Err(ApiError::Internal(other.to_string())),
        None => Ok(()),
    }
}

/// Extract subscription fields from a webhook `data.object` JSON value.
///
/// Parses `id`, `customer`, `status`, period timestamps, `cancel_at_period_end`,
/// and the first price ID from `items.data[].price.id`. Resolves the plan
/// tier via `plan_registry.get_tier_by_price_id`. Returns `None` if any
/// required field is missing or the price ID is unrecognized.
fn parse_subscription_payload_from_event(
    state: &AppState,
    data: &serde_json::Value,
) -> Option<SubscriptionPayload> {
    let object = data.get("object")?;
    let stripe_subscription_id = object.get("id")?.as_str()?.to_string();
    let stripe_customer_id = object.get("customer")?.as_str()?.to_string();
    let status = parse_subscription_status(object.get("status")?.as_str()?)?;
    let current_period_start =
        parse_timestamp_to_date(object.get("current_period_start")?.as_i64()?)?;
    let current_period_end = parse_timestamp_to_date(object.get("current_period_end")?.as_i64()?)?;
    let cancel_at_period_end = object
        .get("cancel_at_period_end")
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    let stripe_price_id = first_price_id_from_value(object.get("items")?)?;
    let plan_tier = state.plan_registry.get_tier_by_price_id(&stripe_price_id)?;

    Some(SubscriptionPayload {
        stripe_subscription_id,
        stripe_customer_id,
        status,
        plan_tier,
        stripe_price_id,
        current_period_start,
        current_period_end,
        cancel_at_period_end,
    })
}

async fn fetch_subscription_payload_from_stripe(
    state: &AppState,
    stripe_subscription_id: &str,
) -> Result<Option<SubscriptionPayload>, ApiError> {
    let data = state
        .stripe_service
        .retrieve_subscription(stripe_subscription_id)
        .await
        .map_err(|err| {
            ApiError::Internal(format!("failed to fetch subscription from stripe: {err}"))
        })?;

    Ok(parse_subscription_payload_from_data(state, &data))
}

/// Convert a `SubscriptionData` struct (from Stripe API lookup) to a `SubscriptionPayload`.
///
/// Same field extraction as `parse_subscription_payload_from_event` but
/// operates on a typed struct rather than raw JSON. Used as fallback when
/// the webhook payload is missing required fields.
fn parse_subscription_payload_from_data(
    state: &AppState,
    data: &crate::stripe::SubscriptionData,
) -> Option<SubscriptionPayload> {
    let current_period_start = parse_timestamp_to_date(data.current_period_start)?;
    let current_period_end = parse_timestamp_to_date(data.current_period_end)?;
    let stripe_price_id = data.items.first()?.price_id.clone();
    let plan_tier = state.plan_registry.get_tier_by_price_id(&stripe_price_id)?;

    Some(SubscriptionPayload {
        stripe_subscription_id: data.id.clone(),
        stripe_customer_id: data.customer.clone(),
        status: parse_subscription_status(&data.status)?,
        plan_tier,
        stripe_price_id,
        current_period_start,
        current_period_end,
        cancel_at_period_end: data.cancel_at_period_end,
    })
}

fn parse_subscription_status(value: &str) -> Option<SubscriptionStatus> {
    value.parse().ok()
}

fn parse_timestamp_to_date(timestamp: i64) -> Option<NaiveDate> {
    chrono::DateTime::from_timestamp(timestamp, 0).map(|value| value.naive_utc().date())
}

fn first_price_id_from_value(value: &serde_json::Value) -> Option<String> {
    let items = value.get("data")?;
    let first_item = items.as_array()?.first()?;
    let price = first_item
        .get("price")
        .and_then(|entry| entry.get("id"))
        .or_else(|| first_item.get("price_id"))?;
    price.as_str().map(|id| id.to_string())
}

fn extract_subscription_id(data: &serde_json::Value) -> Option<String> {
    let object = data.get("object")?;
    object.get("id")?.as_str().map(str::to_string)
}

#[derive(Debug)]
struct SubscriptionPayload {
    stripe_subscription_id: String,
    stripe_customer_id: String,
    status: SubscriptionStatus,
    plan_tier: PlanTier,
    stripe_price_id: String,
    current_period_start: NaiveDate,
    current_period_end: NaiveDate,
    cancel_at_period_end: bool,
}

enum SubscriptionStatusAction {
    Create,
    Update,
    Delete,
}

/// DEPRECATED for invoice totals — preserved for quota enforcement and legacy compatibility.
async fn handle_checkout_session_completed(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let subscription_id = match data
        .get("object")
        .and_then(|object| object.get("subscription"))
        .and_then(|value| value.as_str())
    {
        Some(id) => id.to_string(),
        None => {
            tracing::warn!("checkout.session.completed event missing required subscription id");
            return Ok(());
        }
    };

    let payload = match fetch_subscription_payload_from_stripe(state, &subscription_id).await? {
        Some(payload) => payload,
        None => {
            tracing::warn!(
                "checkout.session.completed event could not be reconciled from Stripe subscription {}",
                subscription_id
            );
            return Ok(());
        }
    };

    apply_subscription_payload(state, payload, SubscriptionStatusAction::Create).await
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

/// Handle payment retries exhausted: mark invoice failed, cancel delinquent
/// subscription, suspend customer, and fire critical alert.
async fn handle_retries_exhausted(
    state: &AppState,
    invoice: &InvoiceRow,
    customer: Option<Customer>,
    mut metadata: HashMap<String, String>,
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

    if let Some(subscription) = state
        .subscription_repo
        .find_by_customer(invoice.customer_id)
        .await?
    {
        if let Ok(status) = subscription.parsed_status() {
            if status.is_delinquent() {
                state
                    .subscription_repo
                    .update_status(subscription.id, SubscriptionStatus::Canceled)
                    .await?;
            }
        }
    }

    state.customer_repo.suspend(invoice.customer_id).await?;
    if let Some(customer) = customer {
        metadata.insert("customer_email".to_string(), customer.email);
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
    mut metadata: HashMap<String, String>,
    next_payment_attempt: Option<String>,
) -> Result<(), ApiError> {
    if invoice.status != "finalized" {
        return Ok(());
    }

    if let Some(next_attempt) = next_payment_attempt {
        metadata.insert("next_payment_attempt".to_string(), next_attempt);
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
    #[serde(rename = "notificationType")]
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

    Ok(())
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

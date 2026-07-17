//! Stripe webhook processing helpers.
use std::collections::HashMap;

use axum::http::{HeaderMap, StatusCode};

use crate::errors::ApiError;
use crate::invoicing::stripe_sync::send_invoice_ready_email_best_effort;
use crate::models::{Customer, InvoiceRow};
use crate::repos::WebhookEventRepo;
use crate::services::alerting::{Alert, AlertSeverity};
use crate::services::email::{
    DunningRecoveredAfterFailureEmailRequest, DunningRetriesExhaustedEmailRequest,
    DunningRetryScheduledEmailRequest,
};
use crate::state::AppState;

pub(super) async fn process_stripe_webhook(
    state: &AppState,
    headers: &HeaderMap,
    body: &str,
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
        .construct_webhook_event(body, signature, webhook_secret)
        .map_err(|_| ApiError::BadRequest("invalid webhook signature".into()))?;

    // Idempotency: process event only for the single caller that inserted
    // this stripe_event_id row first.
    let payload: serde_json::Value = serde_json::from_str(body)
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
        "invoice.payment_succeeded" => handle_payment_succeeded(state, &event.data).await,
        "invoice.payment_failed" => handle_payment_failed(state, &event.data).await,
        "invoice.payment_action_required" => {
            handle_payment_action_required(state, &event.data).await
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
        "charge.refunded" => handle_charge_refunded(state, &event.data).await,
        "charge.dispute.created"
        | "charge.dispute.funds_withdrawn"
        | "charge.dispute.funds_reinstated"
        | "charge.dispute.closed" => {
            super::stripe_disputes::handle_charge_dispute_event(
                state,
                &event.event_type,
                &event.data,
            )
            .await
        }
        _ => {
            tracing::debug!("ignoring webhook event type: {}", event.event_type);
            Ok(())
        }
    };

    if let Err(e) = handler_result {
        delete_unprocessed_webhook_event(state.webhook_event_repo.as_ref(), &event.id).await;
        return Err(e);
    }

    mark_webhook_event_processed(state.webhook_event_repo.as_ref(), &event.id).await?;

    Ok(StatusCode::OK)
}

async fn delete_unprocessed_webhook_event(
    webhook_event_repo: &(dyn WebhookEventRepo + Send + Sync),
    stripe_event_id: &str,
) {
    let _ = webhook_event_repo.delete_unprocessed(stripe_event_id).await;
}

async fn mark_webhook_event_processed(
    webhook_event_repo: &(dyn WebhookEventRepo + Send + Sync),
    stripe_event_id: &str,
) -> Result<(), ApiError> {
    match webhook_event_repo.mark_processed(stripe_event_id).await {
        Ok(()) => Ok(()),
        Err(error) => {
            delete_unprocessed_webhook_event(webhook_event_repo, stripe_event_id).await;
            Err(ApiError::Internal(error.to_string()))
        }
    }
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

async fn find_event_invoice(
    state: &AppState,
    data: &serde_json::Value,
    event_type: &str,
) -> Result<Option<InvoiceRow>, ApiError> {
    let Some(stripe_invoice_id) = invoice_object_id(data, event_type) else {
        return Ok(None);
    };

    Ok(state
        .invoice_repo
        .find_by_stripe_invoice_id(stripe_invoice_id)
        .await?)
}

async fn find_customer_by_id_best_effort(
    state: &AppState,
    customer_id: uuid::Uuid,
) -> Option<Customer> {
    state
        .customer_repo
        .find_by_id(customer_id)
        .await
        .ok()
        .flatten()
}

fn insert_customer_email(metadata: &mut HashMap<String, String>, customer: &Customer) {
    metadata.insert("customer_email".to_string(), customer.email.clone());
}

/// Handle `invoice.payment_succeeded` — mark the invoice paid and recover suspended customers.
///
/// Looks up the invoice by `stripe_invoice_id`. Only transitions invoices
/// in `finalized` or `failed` status to `paid`. If the invoice was previously
/// `failed`, reactivates the customer and sends an info-level recovery alert.
async fn handle_payment_succeeded(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let Some(invoice) = find_event_invoice(state, data, "invoice.payment_succeeded").await? else {
        return Ok(());
    };

    let was_failed = invoice.status == "failed";
    if invoice.status != "finalized" && !was_failed {
        return Ok(());
    }

    state.invoice_repo.mark_paid(invoice.id).await?;

    let Some(customer) = find_customer_by_id_best_effort(state, invoice.customer_id).await else {
        if !was_failed {
            tracing::warn!(
                "customer {} not found after invoice.payment_succeeded; skipping invoice-ready email",
                invoice.customer_id
            );
        }
        return Ok(());
    };

    if !was_failed {
        send_invoice_ready_email_best_effort(
            state,
            &customer.email,
            invoice.id,
            invoice.hosted_invoice_url.as_deref(),
            invoice.pdf_url.as_deref(),
            "invoice_payment_succeeded",
        )
        .await;
        return Ok(());
    }

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
    insert_customer_email(&mut metadata, &customer);

    super::send_alert_best_effort(
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
    let Some(invoice) = find_event_invoice(state, data, "invoice.payment_failed").await? else {
        return Ok(());
    };

    let next_payment_attempt_is_null = data["object"]
        .get("next_payment_attempt")
        .is_some_and(serde_json::Value::is_null);
    let next_payment_attempt = data["object"]["next_payment_attempt"].as_i64();
    let attempt_count = data["object"]["attempt_count"]
        .as_i64()
        .and_then(|value| u32::try_from(value).ok());

    let customer = find_customer_by_id_best_effort(state, invoice.customer_id).await;

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

    Ok(())
}

/// Handle `invoice.payment_action_required` by sending a warning alert.
async fn handle_payment_action_required(
    state: &AppState,
    data: &serde_json::Value,
) -> Result<(), ApiError> {
    let Some(invoice) = find_event_invoice(state, data, "invoice.payment_action_required").await?
    else {
        return Ok(());
    };

    let metadata = invoice_alert_metadata(&invoice);

    super::send_alert_best_effort(
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

    super::send_alert_best_effort(
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

    super::send_alert_best_effort(
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

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::time::Duration;

    use async_trait::async_trait;
    use chrono::Utc;

    use super::mark_webhook_event_processed;
    use crate::errors::ApiError;
    use crate::repos::webhook_event_repo::WebhookEventRow;
    use crate::repos::{RepoError, WebhookEventRepo};

    struct MarkProcessedTestRepo {
        mark_processed_error: Option<RepoError>,
        mark_processed_calls: Mutex<Vec<String>>,
        deleted_unprocessed_calls: Mutex<Vec<String>>,
    }

    impl MarkProcessedTestRepo {
        fn succeed() -> Self {
            Self {
                mark_processed_error: None,
                mark_processed_calls: Mutex::new(Vec::new()),
                deleted_unprocessed_calls: Mutex::new(Vec::new()),
            }
        }

        fn fail_mark_processed(message: &str) -> Self {
            Self {
                mark_processed_error: Some(RepoError::Other(message.to_string())),
                mark_processed_calls: Mutex::new(Vec::new()),
                deleted_unprocessed_calls: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl WebhookEventRepo for MarkProcessedTestRepo {
        async fn try_insert(
            &self,
            _stripe_event_id: &str,
            _event_type: &str,
            _payload: &serde_json::Value,
        ) -> Result<bool, RepoError> {
            unreachable!("try_insert is not used in these unit tests")
        }

        async fn mark_processed(&self, stripe_event_id: &str) -> Result<(), RepoError> {
            self.mark_processed_calls
                .lock()
                .unwrap()
                .push(stripe_event_id.to_string());
            match &self.mark_processed_error {
                Some(error) => Err(match error {
                    RepoError::NotFound => RepoError::NotFound,
                    RepoError::Conflict(message) => RepoError::Conflict(message.clone()),
                    RepoError::Other(message) => RepoError::Other(message.clone()),
                }),
                None => Ok(()),
            }
        }

        async fn find_latest_invoice_id_by_payment_intent(
            &self,
            _payment_intent_id: &str,
        ) -> Result<Option<String>, RepoError> {
            unreachable!("find_latest_invoice_id_by_payment_intent is not used in these tests")
        }

        async fn count_stale_unprocessed(&self, _older_than: Duration) -> Result<i64, RepoError> {
            unreachable!("count_stale_unprocessed is not used in these tests")
        }

        async fn delete_unprocessed(&self, stripe_event_id: &str) -> Result<(), RepoError> {
            self.deleted_unprocessed_calls
                .lock()
                .unwrap()
                .push(stripe_event_id.to_string());
            Ok(())
        }

        async fn find_by_stripe_event_id(
            &self,
            stripe_event_id: &str,
        ) -> Result<Option<WebhookEventRow>, RepoError> {
            Ok(Some(WebhookEventRow {
                stripe_event_id: stripe_event_id.to_string(),
                event_type: "invoice.payment_succeeded".to_string(),
                payload: serde_json::json!({}),
                processed_at: None,
                created_at: Utc::now(),
            }))
        }
    }

    #[tokio::test]
    async fn mark_webhook_event_processed_cleans_up_failed_finalize_attempt() {
        let repo = MarkProcessedTestRepo::fail_mark_processed("mark processed failed");

        let err = mark_webhook_event_processed(&repo, "evt_finalize_failure")
            .await
            .expect_err("mark_processed failure should surface as ApiError::Internal");

        match err {
            ApiError::Internal(message) => assert_eq!(message, "mark processed failed"),
            other => panic!("expected ApiError::Internal, got {other:?}"),
        }
        assert_eq!(
            repo.mark_processed_calls.lock().unwrap().as_slice(),
            ["evt_finalize_failure"]
        );
        assert_eq!(
            repo.deleted_unprocessed_calls.lock().unwrap().as_slice(),
            ["evt_finalize_failure"]
        );
    }

    #[tokio::test]
    async fn mark_webhook_event_processed_keeps_successful_finalize_rows_intact() {
        let repo = MarkProcessedTestRepo::succeed();

        mark_webhook_event_processed(&repo, "evt_finalize_success")
            .await
            .expect("successful mark_processed should stay successful");

        assert_eq!(
            repo.mark_processed_calls.lock().unwrap().as_slice(),
            ["evt_finalize_success"]
        );
        assert!(
            repo.deleted_unprocessed_calls.lock().unwrap().is_empty(),
            "successful finalize should not delete the idempotency row"
        );
    }
}

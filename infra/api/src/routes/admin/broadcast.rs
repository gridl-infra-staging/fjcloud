use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use tokio::task::JoinSet;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::models::Customer;
use crate::services::email::{BroadcastDeliveryStatus, EmailError};
use crate::state::AppState;

// Fixed per-request pressure bound, not a global SES rate limiter. Keep it
// below the recorded SES MaxSendRate of 14 and SQLx PgPool::connect's default
// 10-connection ceiling so one admin request leaves capacity for unrelated
// requests while it fans out recipient delivery and best-effort log writes.
const BROADCAST_SEND_CONCURRENCY_LIMIT: usize = 5;

#[derive(Debug, Deserialize)]
pub struct BroadcastRequest {
    pub subject: String,
    #[serde(default)]
    pub html_body: Option<String>,
    #[serde(default)]
    pub text_body: Option<String>,
    pub dry_run: bool,
}

#[derive(Debug, Serialize)]
pub struct DryRunBroadcastResponse {
    pub mode: &'static str,
    pub subject: String,
    pub recipient_count: usize,
}

#[derive(Debug, Serialize)]
pub struct LiveBroadcastResponse {
    pub mode: &'static str,
    pub subject: String,
    pub attempted_count: usize,
    pub success_count: usize,
    pub suppressed_count: usize,
    pub failure_count: usize,
}

struct BroadcastDeliveryTask {
    state: AppState,
    recipient_email: String,
    subject: String,
    html_body: Option<String>,
    text_body: Option<String>,
    abort_scheduling: Arc<AtomicBool>,
}

struct BroadcastDeliveryInputs {
    state: AppState,
    subject: String,
    html_body: Option<String>,
    text_body: Option<String>,
    abort_scheduling: Arc<AtomicBool>,
}

enum BroadcastDeliveryOutcome {
    Sent,
    Suppressed,
    DeliveryFailed,
    InvalidRequest(String),
}

fn validate_broadcast_request(req: &BroadcastRequest) -> Result<(), ApiError> {
    if req.subject.trim().is_empty() {
        return Err(ApiError::BadRequest("subject must not be empty".into()));
    }

    if req.html_body.is_none() && req.text_body.is_none() {
        return Err(ApiError::BadRequest(
            "broadcast email requires html_body or text_body".into(),
        ));
    }

    if req
        .html_body
        .as_ref()
        .is_some_and(|html| html.trim().is_empty())
    {
        return Err(ApiError::BadRequest(
            "broadcast html body must not be empty".into(),
        ));
    }
    if req
        .text_body
        .as_ref()
        .is_some_and(|text| text.trim().is_empty())
    {
        return Err(ApiError::BadRequest(
            "broadcast text body must not be empty".into(),
        ));
    }

    Ok(())
}

async fn list_non_deleted_customers(state: &AppState) -> Result<Vec<Customer>, ApiError> {
    let customers = state.customer_repo.list().await?;
    Ok(customers
        .into_iter()
        .filter(|customer| customer.status != "deleted")
        .collect())
}

async fn persist_email_log_best_effort(
    state: &AppState,
    recipient_email: &str,
    subject: &str,
    delivery_status: &str,
    error_message: Option<&str>,
) {
    if let Err(err) = sqlx::query(
        "INSERT INTO email_log (recipient_email, subject, delivery_status, error_message) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(recipient_email)
    .bind(subject)
    .bind(delivery_status)
    .bind(error_message)
    .execute(&state.pool)
    .await
    {
        tracing::error!(
            error = %err,
            recipient_email,
            subject,
            delivery_status,
            "failed to persist admin broadcast email_log row"
        );
    }
}

async fn deliver_broadcast_recipient(task: BroadcastDeliveryTask) -> BroadcastDeliveryOutcome {
    let send_result = task
        .state
        .email_service
        .send_broadcast_email(
            &task.recipient_email,
            &task.subject,
            task.html_body.as_deref(),
            task.text_body.as_deref(),
        )
        .await;

    match send_result {
        Ok(BroadcastDeliveryStatus::Sent) => {
            persist_email_log_best_effort(
                &task.state,
                &task.recipient_email,
                &task.subject,
                "success",
                None,
            )
            .await;
            BroadcastDeliveryOutcome::Sent
        }
        Ok(BroadcastDeliveryStatus::Suppressed) => {
            persist_email_log_best_effort(
                &task.state,
                &task.recipient_email,
                &task.subject,
                "suppressed",
                None,
            )
            .await;
            BroadcastDeliveryOutcome::Suppressed
        }
        Err(EmailError::DeliveryFailed(message)) => {
            persist_email_log_best_effort(
                &task.state,
                &task.recipient_email,
                &task.subject,
                "failed",
                Some(&message),
            )
            .await;
            BroadcastDeliveryOutcome::DeliveryFailed
        }
        Err(EmailError::InvalidRequest(message)) => {
            task.abort_scheduling.store(true, Ordering::SeqCst);
            BroadcastDeliveryOutcome::InvalidRequest(message)
        }
    }
}

fn spawn_broadcast_delivery(
    tasks: &mut JoinSet<BroadcastDeliveryOutcome>,
    inputs: &BroadcastDeliveryInputs,
    recipient_email: String,
) {
    tasks.spawn(deliver_broadcast_recipient(BroadcastDeliveryTask {
        state: inputs.state.clone(),
        recipient_email,
        subject: inputs.subject.clone(),
        html_body: inputs.html_body.clone(),
        text_body: inputs.text_body.clone(),
        abort_scheduling: Arc::clone(&inputs.abort_scheduling),
    }));
}

fn fill_broadcast_delivery_window(
    tasks: &mut JoinSet<BroadcastDeliveryOutcome>,
    pending_recipients: &mut impl Iterator<Item = String>,
    inputs: &BroadcastDeliveryInputs,
) {
    while !inputs.abort_scheduling.load(Ordering::SeqCst)
        && tasks.len() < BROADCAST_SEND_CONCURRENCY_LIMIT
    {
        let Some(recipient_email) = pending_recipients.next() else {
            break;
        };
        spawn_broadcast_delivery(tasks, inputs, recipient_email);
    }
}

pub async fn broadcast_email(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<BroadcastRequest>,
) -> Result<Response, ApiError> {
    validate_broadcast_request(&req)?;

    // Keep recipient discovery on CustomerRepo::list() and preserve the repo's
    // created_at DESC ordering by filtering in-memory only.
    let recipients = list_non_deleted_customers(&state).await?;
    if req.dry_run {
        return Ok(Json(DryRunBroadcastResponse {
            mode: "dry_run",
            subject: req.subject,
            recipient_count: recipients.len(),
        })
        .into_response());
    }

    let attempted_count = recipients.len();
    let mut pending_recipients = recipients.into_iter().map(|recipient| recipient.email);
    let delivery_inputs = BroadcastDeliveryInputs {
        state: state.clone(),
        subject: req.subject,
        html_body: req.html_body,
        text_body: req.text_body,
        abort_scheduling: Arc::new(AtomicBool::new(false)),
    };
    let mut tasks = JoinSet::new();
    let mut success_count = 0usize;
    let mut suppressed_count = 0usize;
    let mut failure_count = 0usize;
    let mut invalid_request_message = None;

    // 2026-07 postmortem: the first bounce/complaint probe broadcast returned
    // HTTP 504 after roughly 60 seconds. Bounded fan-out removes compounded
    // per-recipient SES/log latency while preserving the synchronous response
    // contract. Raising the ALB timeout would only mask serial latency, and a
    // durable job queue would add async status/idempotency ownership not
    // warranted for the measured 55-recipient lane.
    fill_broadcast_delivery_window(&mut tasks, &mut pending_recipients, &delivery_inputs);

    while let Some(join_result) = tasks.join_next().await {
        let outcome = join_result.map_err(|err| {
            ApiError::Internal(format!("admin broadcast delivery task failed: {err}"))
        })?;

        match outcome {
            BroadcastDeliveryOutcome::Sent => {
                success_count += 1;
            }
            BroadcastDeliveryOutcome::Suppressed => {
                suppressed_count += 1;
            }
            BroadcastDeliveryOutcome::DeliveryFailed => {
                failure_count += 1;
            }
            BroadcastDeliveryOutcome::InvalidRequest(message) => {
                invalid_request_message = Some(message);
            }
        }

        if invalid_request_message.is_none()
            && !delivery_inputs.abort_scheduling.load(Ordering::SeqCst)
            && tasks.len() < BROADCAST_SEND_CONCURRENCY_LIMIT
        {
            fill_broadcast_delivery_window(&mut tasks, &mut pending_recipients, &delivery_inputs);
        }
    }

    if let Some(message) = invalid_request_message {
        return Err(ApiError::BadRequest(message));
    }

    Ok(Json(LiveBroadcastResponse {
        mode: "live_send",
        subject: delivery_inputs.subject,
        attempted_count,
        success_count,
        suppressed_count,
        failure_count,
    })
    .into_response())
}

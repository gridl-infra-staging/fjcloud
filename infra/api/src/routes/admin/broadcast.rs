use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::models::Customer;
use crate::services::email::{BroadcastDeliveryStatus, EmailError};
use crate::state::AppState;

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

    let mut success_count = 0usize;
    let mut suppressed_count = 0usize;
    let mut failure_count = 0usize;
    for recipient in &recipients {
        let send_result = state
            .email_service
            .send_broadcast_email(
                &recipient.email,
                &req.subject,
                req.html_body.as_deref(),
                req.text_body.as_deref(),
            )
            .await;

        match send_result {
            Ok(BroadcastDeliveryStatus::Sent) => {
                success_count += 1;
                persist_email_log_best_effort(
                    &state,
                    &recipient.email,
                    &req.subject,
                    "success",
                    None,
                )
                .await;
            }
            Ok(BroadcastDeliveryStatus::Suppressed) => {
                suppressed_count += 1;
                persist_email_log_best_effort(
                    &state,
                    &recipient.email,
                    &req.subject,
                    "suppressed",
                    None,
                )
                .await;
            }
            Err(EmailError::DeliveryFailed(message)) => {
                failure_count += 1;
                persist_email_log_best_effort(
                    &state,
                    &recipient.email,
                    &req.subject,
                    "failed",
                    Some(&message),
                )
                .await;
            }
            Err(EmailError::InvalidRequest(message)) => {
                return Err(ApiError::BadRequest(message));
            }
        }
    }

    Ok(Json(LiveBroadcastResponse {
        mode: "live_send",
        subject: req.subject,
        attempted_count: recipients.len(),
        success_count,
        suppressed_count,
        failure_count,
    })
    .into_response())
}

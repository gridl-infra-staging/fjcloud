//! Webhook route owner with per-source private child modules.
mod ses;
mod stripe;
mod stripe_disputes;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};

use crate::errors::ApiError;
use crate::services::alerting::Alert;
use crate::state::AppState;

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
    ses::process_ses_sns_request(&state, &body)
        .await
        .inspect_err(|err| {
            tracing::warn!(target: "api::routes::webhooks::ses_sns",
            body_len = body.len(), error = ?err, "ses_sns_webhook rejected");
        })
}

/// `POST /webhooks/stripe` — receive and process Stripe webhook events.
pub async fn stripe_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: String,
) -> Result<StatusCode, ApiError> {
    stripe::process_stripe_webhook(&state, &headers, &body).await
}

pub(super) async fn send_alert_best_effort(state: &AppState, alert: Alert) {
    if let Err(err) = state.alert_service.send_alert(alert).await {
        tracing::warn!("failed to send webhook alert: {err}");
    }
}

#[cfg(test)]
mod module_split_tests {
    #[test]
    fn request_processors_live_in_private_child_modules() {
        let _ = super::ses::process_ses_sns_request;
        let _ = super::stripe::process_stripe_webhook;
        let _ = super::stripe_disputes::handle_charge_dispute_event;
    }
}

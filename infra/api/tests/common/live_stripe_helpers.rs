use api::stripe::live::LiveStripeService;
use api::stripe::{StripeInvoiceLineItem, StripeService};
use sqlx::PgPool;
use std::time::Instant;
use tokio::sync::OnceCell;
use uuid::Uuid;

const WEBHOOK_PROBE_EVENT_QUERY: &str = "SELECT COUNT(*) FROM webhook_events \
    WHERE event_type IN ('invoice.finalized', 'invoice.payment_succeeded') \
    AND payload->'data'->'object'->>'id' = $1";

#[derive(Debug, Clone)]
#[allow(dead_code)] // fields consumed by launch-gate diagnostics in tests
pub struct WebhookProbeResult {
    pub passed: bool,
    pub elapsed_ms: u64,
    pub detail: String,
}

pub struct LiveStripeHandles {
    pub client: stripe::Client,
    pub service: LiveStripeService,
}

pub fn stripe_test_key() -> Option<String> {
    let key = std::env::var("STRIPE_SECRET_KEY").ok()?;
    if key.starts_with("sk_test_") {
        Some(key)
    } else {
        eprintln!("[skip] STRIPE_SECRET_KEY is set but doesn't start with sk_test_");
        None
    }
}

pub fn stripe_webhook_secret() -> Option<String> {
    let secret = std::env::var("STRIPE_WEBHOOK_SECRET").ok()?;
    if secret.starts_with("whsec_") {
        Some(secret)
    } else {
        eprintln!("[skip] STRIPE_WEBHOOK_SECRET is set but doesn't start with whsec_");
        None
    }
}

pub fn stripe_api_available() -> bool {
    stripe_test_key().is_some()
}

pub fn stripe_webhook_configured() -> bool {
    stripe_webhook_secret().is_some() && crate::integration_helpers::integration_enabled()
}

pub fn build_stripe_service(stripe_secret_key: &str) -> LiveStripeService {
    LiveStripeService::new(stripe_secret_key)
}

pub fn build_live_stripe_handles() -> LiveStripeHandles {
    let key = stripe_test_key().expect("STRIPE_SECRET_KEY must be set");
    LiveStripeHandles {
        client: stripe::Client::new(&key),
        service: build_stripe_service(&key),
    }
}

pub async fn validate_stripe_key_live() -> Result<(), String> {
    let key = match std::env::var("STRIPE_SECRET_KEY") {
        Ok(key) if !key.is_empty() => key,
        _ => return Err("STRIPE_SECRET_KEY is not set".to_string()),
    };
    if !key.starts_with("sk_test_") {
        return Err("STRIPE_SECRET_KEY has invalid prefix (expected sk_test_)".to_string());
    }

    let client = stripe::Client::new(&key);
    stripe::Balance::retrieve(&client, None)
        .await
        .map_err(|err| format!("Stripe API rejected key: {err}"))?;
    Ok(())
}

pub async fn delete_stripe_customer(client: &stripe::Client, customer_id: &str) {
    let customer_id: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");
    if let Err(err) = stripe::Customer::delete(client, &customer_id).await {
        eprintln!("[cleanup] failed to delete Stripe customer {customer_id}: {err}");
    }
}

pub async fn attach_test_payment_method(client: &stripe::Client, customer_id: &str) -> String {
    let customer_id: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");
    let payment_method = stripe::PaymentMethod::attach(
        client,
        &"pm_card_visa".parse().expect("invalid test payment method"),
        stripe::AttachPaymentMethod {
            customer: customer_id,
        },
    )
    .await
    .expect("failed to attach test payment method");

    payment_method.id.to_string()
}

pub async fn attach_declining_payment_method(client: &stripe::Client, customer_id: &str) -> String {
    let customer_id: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");
    let payment_method = stripe::PaymentMethod::attach(
        client,
        &"pm_card_chargeCustomerFail"
            .parse()
            .expect("invalid declining payment method"),
        stripe::AttachPaymentMethod {
            customer: customer_id,
        },
    )
    .await
    .expect("failed to attach declining payment method");

    payment_method.id.to_string()
}

pub async fn validate_stripe_webhook_delivery() -> Result<WebhookProbeResult, String> {
    let start = Instant::now();

    if !stripe_api_available() {
        return Err("Stripe API not available (STRIPE_SECRET_KEY missing or invalid)".to_string());
    }
    if !stripe_webhook_configured() {
        return Err(
            "Stripe webhook not configured (STRIPE_WEBHOOK_SECRET or INTEGRATION missing)"
                .to_string(),
        );
    }

    let api_url = crate::integration_helpers::api_base();
    if !crate::integration_helpers::endpoint_reachable(&api_url).await {
        return Err(format!("API endpoint unreachable at {api_url}"));
    }

    let db_url = crate::integration_helpers::db_url();
    let pool = PgPool::connect(&db_url)
        .await
        .map_err(|err| format!("integration DB unreachable at {db_url}: {err}"))?;

    let stripe = build_live_stripe_handles();
    let probe_email = format!("stripe-probe-{}@flapjack.foo", Uuid::new_v4());
    let stripe_customer_id = stripe
        .service
        .create_customer("Stripe Probe", &probe_email)
        .await
        .map_err(|err| format!("failed creating Stripe probe customer: {err}"))?;

    let pm_id = attach_test_payment_method(&stripe.client, &stripe_customer_id).await;
    if let Err(err) = stripe
        .service
        .set_default_payment_method(&stripe_customer_id, &pm_id)
        .await
    {
        delete_stripe_customer(&stripe.client, &stripe_customer_id).await;
        return Err(format!(
            "failed setting default payment method for webhook probe: {err}"
        ));
    }

    let probe_invoice = stripe
        .service
        .create_and_finalize_invoice(
            &stripe_customer_id,
            &[StripeInvoiceLineItem {
                description: "Stripe webhook probe".to_string(),
                amount_cents: 50,
            }],
            None,
            None,
        )
        .await
        .map_err(|err| format!("failed creating Stripe probe invoice: {err}"))?;

    let stripe_invoice_id = probe_invoice.stripe_invoice_id.clone();
    let poll_pool = pool.clone();
    let webhook_seen = tokio::spawn(async move {
        crate::common::poll::poll_until(
            "stripe_webhook_delivery_probe",
            std::time::Duration::from_secs(10),
            std::time::Duration::from_millis(500),
            move || {
                let pool = poll_pool.clone();
                let invoice_id = stripe_invoice_id.clone();
                async move {
                    let count: i64 = sqlx::query_scalar(WEBHOOK_PROBE_EVENT_QUERY)
                        .bind(&invoice_id)
                        .fetch_one(&pool)
                        .await
                        .unwrap_or(0);
                    (count > 0).then_some(())
                }
            },
        )
        .await;
    })
    .await
    .is_ok();

    delete_stripe_customer(&stripe.client, &stripe_customer_id).await;

    let elapsed_ms = start.elapsed().as_millis() as u64;
    if webhook_seen {
        Ok(WebhookProbeResult {
            passed: true,
            elapsed_ms,
            detail: format!("invoice.payment_succeeded webhook received in {elapsed_ms}ms"),
        })
    } else {
        Ok(WebhookProbeResult {
            passed: false,
            elapsed_ms,
            detail: "webhook not received within 10s; ensure `stripe listen --forward-to localhost:3099/webhooks/stripe` is running".to_string(),
        })
    }
}

static STRIPE_WEBHOOK_AVAILABLE: OnceCell<bool> = OnceCell::const_new();

pub async fn stripe_webhook_available() -> bool {
    *STRIPE_WEBHOOK_AVAILABLE
        .get_or_init(|| async {
            match validate_stripe_webhook_delivery().await {
                Ok(result) => {
                    if !result.passed {
                        eprintln!("[skip] {}", result.detail);
                    }
                    result.passed
                }
                Err(err) => {
                    eprintln!("[skip] {err}");
                    false
                }
            }
        })
        .await
}

#[cfg(test)]
mod tests {
    use super::WEBHOOK_PROBE_EVENT_QUERY;

    #[test]
    fn webhook_probe_query_accepts_fast_invoice_event_delivery() {
        assert!(
            WEBHOOK_PROBE_EVENT_QUERY.contains("invoice.finalized"),
            "webhook delivery probe should accept invoice.finalized so it stays robust when payment_succeeded is delayed"
        );
    }
}

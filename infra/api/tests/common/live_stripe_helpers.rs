use api::stripe::live::LiveStripeService;
use api::stripe::{StripeInvoiceLineItem, StripeService};
use sqlx::PgPool;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Instant;
use tokio::sync::OnceCell;
use uuid::Uuid;

const STRIPE_PRICE_STARTER_ENV: &str = "STRIPE_PRICE_STARTER";
const STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV: &str =
    "STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS";
const WEBHOOK_PROBE_EVENT_QUERY: &str = "SELECT COUNT(*) FROM webhook_events \
    WHERE event_type IN ('invoice.finalized', 'invoice.payment_succeeded') \
    AND payload->'data'->'object'->>'id' = $1";
const DEFAULT_INTEGRATION_API_BASE: &str = "http://localhost:3099";

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

const ACCEPTED_TEST_PREFIXES: &[&str] = &["sk_test_", "rk_test_"];

fn has_accepted_test_prefix(key: &str) -> bool {
    ACCEPTED_TEST_PREFIXES.iter().any(|p| key.starts_with(p))
}

pub fn stripe_test_key() -> Option<String> {
    let key = std::env::var("STRIPE_SECRET_KEY").ok()?;
    if has_accepted_test_prefix(&key) {
        Some(key)
    } else {
        eprintln!(
            "[skip] STRIPE_SECRET_KEY is set but doesn't start with an accepted test prefix (sk_test_ or rk_test_)"
        );
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

pub fn stripe_price_starter_id() -> Option<String> {
    let price_id = std::env::var(STRIPE_PRICE_STARTER_ENV).ok()?;
    if price_id.starts_with("price_") {
        Some(price_id)
    } else {
        eprintln!("[skip] STRIPE_PRICE_STARTER is set but doesn't start with price_");
        None
    }
}

pub fn stripe_price_starter_configured() -> bool {
    stripe_price_starter_id().is_some()
}

pub fn expected_starter_unit_amount_cents() -> Result<i64, String> {
    let raw = std::env::var(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV).map_err(|_| {
        format!(
            "{STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV} must be set to a positive integer amount in cents"
        )
    })?;
    let amount = raw.parse::<i64>().map_err(|_| {
        format!(
            "{STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV} must be an integer number of cents, got: {raw}"
        )
    })?;
    if amount <= 0 {
        return Err(format!(
            "{STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV} must be > 0, got: {amount}"
        ));
    }
    Ok(amount)
}

pub fn expected_first_cycle_amount_cents_from_contract(quantity: u64) -> Result<i64, String> {
    let unit_amount = expected_starter_unit_amount_cents()?;
    let quantity = i64::try_from(quantity).map_err(|_| "quantity exceeds i64".to_string())?;
    Ok(unit_amount * quantity)
}

pub fn stripe_webhook_configured() -> bool {
    stripe_webhook_secret().is_some() && integration_enabled()
}

fn integration_enabled() -> bool {
    std::env::var("INTEGRATION")
        .map(|value| value == "1")
        .unwrap_or(false)
}

fn api_base() -> String {
    std::env::var("INTEGRATION_API_BASE")
        .unwrap_or_else(|_| DEFAULT_INTEGRATION_API_BASE.to_string())
}

async fn endpoint_reachable(base_url: &str) -> bool {
    let parsed = match reqwest::Url::parse(base_url) {
        Ok(url) => url,
        Err(_) => return false,
    };

    let host = match parsed.host_str() {
        Some(host) => host,
        None => return false,
    };
    let port = parsed
        .port_or_known_default()
        .unwrap_or(if parsed.scheme() == "https" { 443 } else { 80 });

    tokio::time::timeout(
        std::time::Duration::from_millis(500),
        tokio::net::TcpStream::connect((host, port)),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

fn db_url() -> String {
    if let Ok(url) = std::env::var("INTEGRATION_DB_URL") {
        return url;
    }

    let host = std::env::var("INTEGRATION_DB_HOST").unwrap_or_else(|_| "localhost".to_string());
    let port = std::env::var("INTEGRATION_DB_PORT").unwrap_or_else(|_| "5432".to_string());
    let user = std::env::var("INTEGRATION_DB_USER").ok();
    let password = std::env::var("INTEGRATION_DB_PASSWORD").ok();
    let db_name =
        std::env::var("INTEGRATION_DB").unwrap_or_else(|_| "fjcloud_integration_test".to_string());

    if let Some(user) = user {
        if let Some(password) = password {
            format!("postgres://{user}:{password}@{host}:{port}/{db_name}")
        } else {
            format!("postgres://{user}@{host}:{port}/{db_name}")
        }
    } else {
        format!("postgres://{host}:{port}/{db_name}")
    }
}

fn test_env_lock() -> MutexGuard<'static, ()> {
    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
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
    if !has_accepted_test_prefix(&key) {
        return Err(
            "STRIPE_SECRET_KEY has invalid prefix (expected sk_test_ or rk_test_)".to_string(),
        );
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

pub async fn try_attach_test_payment_method(
    client: &stripe::Client,
    customer_id: &str,
) -> Result<String, String> {
    let customer_id: stripe::CustomerId = customer_id
        .parse()
        .map_err(|_| format!("invalid customer ID: {customer_id}"))?;
    let payment_method = stripe::PaymentMethod::attach(
        client,
        &"pm_card_visa".parse().expect("invalid test payment method"),
        stripe::AttachPaymentMethod {
            customer: customer_id,
        },
    )
    .await
    .map_err(|err| format!("failed to attach test payment method: {err}"))?;

    Ok(payment_method.id.to_string())
}

#[allow(dead_code)] // Shared helper API used by other integration binaries.
pub async fn attach_test_payment_method(client: &stripe::Client, customer_id: &str) -> String {
    try_attach_test_payment_method(client, customer_id)
        .await
        .expect("failed to attach test payment method")
}

/// TODO: Document attach_declining_payment_method.
pub async fn try_attach_declining_payment_method(
    client: &stripe::Client,
    customer_id: &str,
) -> Result<String, String> {
    let customer_id: stripe::CustomerId = customer_id
        .parse()
        .map_err(|_| format!("invalid customer ID: {customer_id}"))?;
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
    .map_err(|err| format!("failed to attach declining payment method: {err}"))?;

    Ok(payment_method.id.to_string())
}

#[allow(dead_code)] // Shared helper API used by other integration binaries.
pub async fn attach_declining_payment_method(client: &stripe::Client, customer_id: &str) -> String {
    try_attach_declining_payment_method(client, customer_id)
        .await
        .expect("failed to attach declining payment method")
}

pub async fn create_test_clock(
    client: &stripe::Client,
    name: &str,
    frozen_time: i64,
) -> Result<stripe::TestHelpersTestClock, String> {
    stripe::TestHelpersTestClock::create(client, &stripe::CreateTestClock { frozen_time, name })
        .await
        .map_err(|err| format!("failed creating test clock: {err}"))
}

pub async fn create_clock_bound_customer(
    client: &stripe::Client,
    name: &str,
    email: &str,
    test_clock_id: &stripe::TestHelpersTestClockId,
) -> Result<String, String> {
    let mut params = stripe::CreateCustomer::new();
    params.name = Some(name);
    params.email = Some(email);
    params.test_clock = Some(test_clock_id.as_ref());
    let customer = stripe::Customer::create(client, params)
        .await
        .map_err(|err| format!("failed creating clock-bound customer: {err}"))?;
    Ok(customer.id.to_string())
}

pub async fn create_trialing_subscription_for_price(
    client: &stripe::Client,
    customer_id: &str,
    price_id: &str,
    trial_end: i64,
) -> Result<stripe::Subscription, String> {
    let customer_id: stripe::CustomerId = customer_id
        .parse()
        .map_err(|_| format!("invalid customer ID: {customer_id}"))?;
    let price_id: stripe::PriceId = price_id
        .parse()
        .map_err(|_| format!("invalid price ID: {price_id}"))?;

    let mut params = stripe::CreateSubscription::new(customer_id);
    params.collection_method = Some(stripe::CollectionMethod::ChargeAutomatically);
    params.items = Some(vec![stripe::CreateSubscriptionItems {
        price: Some(price_id.to_string()),
        quantity: Some(1),
        ..Default::default()
    }]);
    params.trial_end = Some(stripe::Scheduled::at(trial_end));
    params.expand = &["latest_invoice"];

    stripe::Subscription::create(client, params)
        .await
        .map_err(|err| format!("failed creating trialing subscription: {err}"))
}

pub async fn advance_test_clock_and_wait_ready(
    client: &stripe::Client,
    test_clock_id: &str,
    target_frozen_time: i64,
) -> Result<stripe::TestHelpersTestClock, String> {
    let test_clock_id: stripe::TestHelpersTestClockId = test_clock_id
        .parse()
        .map_err(|_| format!("invalid test clock ID: {test_clock_id}"))?;

    stripe::TestHelpersTestClock::advance(
        client,
        &test_clock_id,
        &stripe::AdvanceTestClock {
            frozen_time: target_frozen_time,
        },
    )
    .await
    .map_err(|err| format!("failed advancing test clock: {err}"))?;

    let client = client.clone();
    crate::common::poll::poll_until_result(
        "stripe_test_clock_ready",
        std::time::Duration::from_secs(90),
        std::time::Duration::from_secs(2),
        move || {
            let client = client.clone();
            let clock_id = test_clock_id.clone();
            async move {
                let clock = stripe::TestHelpersTestClock::retrieve(&client, &clock_id)
                    .await
                    .ok()?;
                let clock_is_ready = matches!(
                    clock.status,
                    Some(stripe::TestHelpersTestClockStatus::Ready)
                ) && clock.frozen_time.unwrap_or_default()
                    >= target_frozen_time;
                clock_is_ready.then_some(clock)
            }
        },
    )
    .await
}

pub async fn poll_paid_invoice_for_subscription(
    client: &stripe::Client,
    subscription_id: &str,
) -> Result<stripe::Invoice, String> {
    let subscription_id: stripe::SubscriptionId = subscription_id
        .parse()
        .map_err(|_| format!("invalid subscription ID: {subscription_id}"))?;
    let client = client.clone();
    crate::common::poll::poll_until_result(
        "stripe_subscription_paid_invoice",
        std::time::Duration::from_secs(90),
        std::time::Duration::from_secs(2),
        move || {
            let client = client.clone();
            let subscription_id = subscription_id.clone();
            async move {
                let mut params = stripe::ListInvoices::new();
                params.subscription = Some(subscription_id);
                params.status = Some(stripe::InvoiceStatus::Paid);
                params.limit = Some(1);
                let invoices = stripe::Invoice::list(&client, &params).await.ok()?;
                invoices.data.into_iter().next()
            }
        },
    )
    .await
}

pub async fn retrieve_subscription(
    client: &stripe::Client,
    subscription_id: &str,
) -> Result<stripe::Subscription, String> {
    let subscription_id: stripe::SubscriptionId = subscription_id
        .parse()
        .map_err(|_| format!("invalid subscription ID: {subscription_id}"))?;
    stripe::Subscription::retrieve(client, &subscription_id, &[])
        .await
        .map_err(|err| format!("failed retrieving subscription {subscription_id}: {err}"))
}

pub async fn cleanup_test_clock_cycle(
    client: &stripe::Client,
    subscription_id: Option<&str>,
    customer_id: Option<&str>,
    test_clock_id: Option<&str>,
) {
    if let Some(subscription_id) = subscription_id {
        let parsed: Result<stripe::SubscriptionId, _> = subscription_id.parse();
        match parsed {
            Ok(subscription_id) => {
                if let Err(err) = stripe::Subscription::cancel(
                    client,
                    &subscription_id,
                    stripe::CancelSubscription::new(),
                )
                .await
                {
                    eprintln!(
                        "[cleanup] failed to cancel Stripe subscription {subscription_id}: {err}"
                    );
                }
            }
            Err(_) => {
                eprintln!("[cleanup] invalid Stripe subscription ID: {subscription_id}");
            }
        }
    }

    if let Some(customer_id) = customer_id {
        delete_stripe_customer(client, customer_id).await;
    }

    if let Some(test_clock_id) = test_clock_id {
        let parsed: Result<stripe::TestHelpersTestClockId, _> = test_clock_id.parse();
        match parsed {
            Ok(test_clock_id) => {
                if let Err(err) = stripe::TestHelpersTestClock::delete(client, &test_clock_id).await
                {
                    eprintln!(
                        "[cleanup] failed to delete Stripe test clock {test_clock_id}: {err}"
                    );
                }
            }
            Err(_) => {
                eprintln!("[cleanup] invalid Stripe test clock ID: {test_clock_id}");
            }
        }
    }
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

    let api_url = api_base();
    if !endpoint_reachable(&api_url).await {
        return Err(format!("API endpoint unreachable at {api_url}"));
    }

    let db_url = db_url();
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

    let stripe_invoice_id = match async {
        let pm_id = try_attach_test_payment_method(&stripe.client, &stripe_customer_id)
            .await
            .map_err(|err| format!("failed attaching payment method for webhook probe: {err}"))?;
        stripe
            .service
            .set_default_payment_method(&stripe_customer_id, &pm_id)
            .await
            .map_err(|err| {
                format!("failed setting default payment method for webhook probe: {err}")
            })?;

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

        Ok::<String, String>(probe_invoice.stripe_invoice_id.clone())
    }
    .await
    {
        Ok(stripe_invoice_id) => stripe_invoice_id,
        Err(err) => {
            delete_stripe_customer(&stripe.client, &stripe_customer_id).await;
            return Err(err);
        }
    };

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
    use super::{
        expected_first_cycle_amount_cents_from_contract, expected_starter_unit_amount_cents,
        try_attach_declining_payment_method, try_attach_test_payment_method,
    };
    use super::{STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV, WEBHOOK_PROBE_EVENT_QUERY};

    struct EnvRestore {
        key: &'static str,
        original: Option<String>,
    }

    impl EnvRestore {
        fn capture(key: &'static str) -> Self {
            Self {
                key,
                original: std::env::var(key).ok(),
            }
        }
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                std::env::set_var(self.key, value);
            } else {
                std::env::remove_var(self.key);
            }
        }
    }

    #[test]
    fn expected_starter_amount_requires_positive_integer_env_value() {
        let _guard = super::test_env_lock();
        let _restore = EnvRestore::capture(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV);
        std::env::remove_var(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV);
        assert!(expected_starter_unit_amount_cents().is_err());

        std::env::set_var(
            STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV,
            "not-a-number",
        );
        assert!(expected_starter_unit_amount_cents().is_err());

        std::env::set_var(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV, "0");
        assert!(expected_starter_unit_amount_cents().is_err());

        std::env::set_var(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV, "900");
        assert_eq!(
            expected_starter_unit_amount_cents().expect("valid env"),
            900
        );
    }

    #[test]
    fn contract_amount_multiplies_unit_amount_by_quantity() {
        let _guard = super::test_env_lock();
        let _restore = EnvRestore::capture(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV);
        std::env::set_var(STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS_ENV, "900");
        assert_eq!(
            expected_first_cycle_amount_cents_from_contract(2).expect("valid contract amount"),
            1800
        );
    }

    #[test]
    fn webhook_probe_query_accepts_fast_invoice_event_delivery() {
        assert!(
            WEBHOOK_PROBE_EVENT_QUERY.contains("invoice.finalized"),
            "webhook delivery probe should accept invoice.finalized so it stays robust when payment_succeeded is delayed"
        );
    }

    #[tokio::test]
    async fn attach_test_payment_method_reports_invalid_customer_id() {
        let client = stripe::Client::new("sk_test_contract_only");
        let error = try_attach_test_payment_method(&client, "not-a-customer-id")
            .await
            .expect_err("invalid customer IDs should surface as Result errors");
        assert!(error.contains("invalid customer ID: not-a-customer-id"));
    }

    #[tokio::test]
    async fn attach_declining_payment_method_reports_invalid_customer_id() {
        let client = stripe::Client::new("sk_test_contract_only");
        let error = try_attach_declining_payment_method(&client, "not-a-customer-id")
            .await
            .expect_err("invalid customer IDs should surface as Result errors");
        assert!(error.contains("invalid customer ID: not-a-customer-id"));
    }
}

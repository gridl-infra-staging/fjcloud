#![allow(clippy::await_holding_lock)]

mod common;
#[path = "common/integration_helpers.rs"]
mod integration_helpers;
#[path = "common/live_stripe_helpers.rs"]
mod live_stripe_helpers;

use api::stripe::StripeService;

const TRIAL_DAYS: i64 = 3;
const SECONDS_PER_DAY: i64 = 24 * 60 * 60;
const CLOCK_ADVANCE_BUFFER_SECONDS: i64 = 60 * 60;
const EXPECTED_SUBSCRIPTION_QUANTITY: u64 = 1;

#[tokio::test]
async fn stripe_test_clock_full_cycle_bills_expected_amount() {
    // This test shares a binary with helper tests that intentionally mutate
    // `STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS`. Hold the same env lock
    // they use for the entire live scenario so the hand-calculated assertion
    // cannot race against those mutations under the default Rust test scheduler.
    let _env_guard = integration_helpers::test_env_lock();

    require_live!(
        integration_helpers::integration_enabled(),
        "INTEGRATION=1 must be set for stripe test-clock nightly coverage"
    );
    require_live!(
        live_stripe_helpers::validate_stripe_key_live()
            .await
            .is_ok(),
        "STRIPE_SECRET_KEY must be present and accepted by Stripe API"
    );
    require_live!(
        live_stripe_helpers::stripe_price_starter_configured(),
        "STRIPE_PRICE_STARTER must be set to a Stripe price_ identifier"
    );
    require_live!(
        live_stripe_helpers::expected_starter_unit_amount_cents().is_ok(),
        "STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS must be set to a positive integer"
    );

    let price_id = live_stripe_helpers::stripe_price_starter_id()
        .expect("STRIPE_PRICE_STARTER must be set when live gate preconditions pass");
    let stripe = live_stripe_helpers::build_live_stripe_handles();

    let frozen_time = chrono::Utc::now().timestamp();
    let trial_end = frozen_time + (TRIAL_DAYS * SECONDS_PER_DAY);
    let target_frozen_time = trial_end + CLOCK_ADVANCE_BUFFER_SECONDS;

    let test_clock = live_stripe_helpers::create_test_clock(
        &stripe.client,
        "fjcloud-nightly-full-cycle",
        frozen_time,
    )
    .await
    .expect("Stripe test clock should be created");
    let test_clock_id = test_clock.id.to_string();
    let mut stripe_customer_id: Option<String> = None;
    let mut stripe_subscription_id: Option<String> = None;

    let scenario_result: Result<(), String> = async {
        let customer_email = format!("stripe-clock-full-cycle-{}@flapjack.foo", uuid::Uuid::new_v4());
        let customer_id = live_stripe_helpers::create_clock_bound_customer(
            &stripe.client,
            "Stripe Clock Full Cycle",
            &customer_email,
            &test_clock.id,
        )
        .await?;
        stripe_customer_id = Some(customer_id.clone());

        let payment_method_id = live_stripe_helpers::try_attach_test_payment_method(
            &stripe.client,
            &customer_id,
        )
        .await
        .map_err(|err| format!("failed attaching payment method: {err}"))?;
        stripe
            .service
            .set_default_payment_method(&customer_id, &payment_method_id)
            .await
            .map_err(|err| format!("failed setting default payment method: {err}"))?;

        let subscription = live_stripe_helpers::create_trialing_subscription_for_price(
            &stripe.client,
            &customer_id,
            &price_id,
            trial_end,
        )
        .await?;
        let subscription_id = subscription.id.to_string();
        stripe_subscription_id = Some(subscription_id.clone());

        let _ready_clock = live_stripe_helpers::advance_test_clock_and_wait_ready(
            &stripe.client,
            &test_clock_id,
            target_frozen_time,
        )
        .await?;

        let paid_invoice = live_stripe_helpers::poll_paid_invoice_for_subscription(
            &stripe.client,
            &subscription_id,
        )
        .await?;
        let expected_first_cycle_amount_cents =
            live_stripe_helpers::expected_first_cycle_amount_cents_from_contract(
                EXPECTED_SUBSCRIPTION_QUANTITY,
            )?;

        assert_eq!(
            paid_invoice.amount_paid.unwrap_or_default(),
            expected_first_cycle_amount_cents,
            "hand-calculated first-cycle amount (unit price x quantity) must match Stripe paid amount after advancing test clock past trial end"
        );
        assert_eq!(
            paid_invoice.status,
            Some(stripe::InvoiceStatus::Paid),
            "first invoice generated after clock advance must be paid"
        );

        let latest_subscription =
            live_stripe_helpers::retrieve_subscription(&stripe.client, &subscription_id).await?;
        assert_eq!(
            latest_subscription.status,
            stripe::SubscriptionStatus::Active,
            "subscription should be active after first post-trial invoice is paid"
        );
        assert_eq!(
            latest_subscription.items.data.len(),
            1,
            "nightly owner should exercise exactly one recurring price item"
        );
        let observed_price_id = latest_subscription.items.data[0]
            .price
            .as_ref()
            .map(|price| price.id.to_string())
            .unwrap_or_default();
        assert_eq!(
            observed_price_id, price_id,
            "subscription item should remain pinned to STRIPE_PRICE_STARTER"
        );
        assert!(
            latest_subscription.current_period_end > latest_subscription.current_period_start,
            "full-cycle boundary should advance current_period_end beyond current_period_start"
        );
        Ok(())
    }
    .await;

    live_stripe_helpers::cleanup_test_clock_cycle(
        &stripe.client,
        stripe_subscription_id.as_deref(),
        stripe_customer_id.as_deref(),
        Some(test_clock_id.as_str()),
    )
    .await;

    if let Err(err) = scenario_result {
        panic!("stripe test-clock full-cycle scenario failed: {err}");
    }
}

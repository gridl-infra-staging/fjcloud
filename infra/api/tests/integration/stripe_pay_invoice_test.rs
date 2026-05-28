#![allow(dead_code)]

use api::stripe::local::LocalStripeService;
use api::stripe::{PaidInvoice, StripeInvoiceLineItem, StripeLastPaymentError, StripeService};

async fn build_local_invoice_with_default_pm(pm_id: &str) -> (LocalStripeService, String) {
    let (service, _dispatcher) = LocalStripeService::new(
        "whsec_pay_test".to_string(),
        "http://localhost:3001/webhooks/stripe".to_string(),
    );
    let customer_id = service
        .create_customer("Pay Test", "pay-test@fjcloud.dev")
        .await
        .expect("local customer should be created");
    service.seed_default_payment_method(&customer_id, pm_id);

    let invoice = service
        .create_and_finalize_invoice(
            &customer_id,
            &[StripeInvoiceLineItem {
                description: "Stripe pay contract".to_string(),
                amount_cents: 1750,
            }],
            None,
            None,
        )
        .await
        .expect("local invoice should finalize");

    (service, invoice.stripe_invoice_id)
}

#[tokio::test]
async fn stripe_pay_invoice_local_paid_path_returns_contract_shape() {
    let (service, invoice_id) = build_local_invoice_with_default_pm("pm_test_visa_4242").await;

    let paid = service
        .pay_invoice(&invoice_id)
        .await
        .expect("local pay should succeed");

    assert_eq!(
        paid,
        PaidInvoice {
            id: invoice_id,
            status: "paid".to_string(),
            amount_paid_cents: 1750,
            last_payment_error: None,
        }
    );
}

#[tokio::test]
async fn stripe_pay_invoice_local_declined_path_returns_decline_error_contract() {
    let (service, invoice_id) =
        build_local_invoice_with_default_pm("pm_test_decline_insufficient_funds").await;

    let paid = service
        .pay_invoice(&invoice_id)
        .await
        .expect("declined local pay should still return Stripe pay response");

    assert_eq!(
        paid,
        PaidInvoice {
            id: invoice_id,
            status: "open".to_string(),
            amount_paid_cents: 0,
            last_payment_error: Some(StripeLastPaymentError {
                code: Some("card_declined".to_string()),
                decline_code: Some("insufficient_funds".to_string()),
                message: Some("Your card has insufficient funds.".to_string()),
            }),
        }
    );
}

#[tokio::test]
async fn stripe_pay_invoice_local_requires_action_path_returns_action_required_contract() {
    let (service, invoice_id) = build_local_invoice_with_default_pm("pm_test_3ds_required").await;

    let paid = service
        .pay_invoice(&invoice_id)
        .await
        .expect("requires_action local pay should return Stripe pay response");

    assert_eq!(
        paid,
        PaidInvoice {
            id: invoice_id,
            status: "open".to_string(),
            amount_paid_cents: 0,
            last_payment_error: Some(StripeLastPaymentError {
                code: Some("invoice_payment_intent_requires_action".to_string()),
                decline_code: None,
                message: Some("Payment requires customer action.".to_string()),
            }),
        }
    );
}

#[tokio::test]
#[ignore = "requires STRIPE_SECRET_KEY sandbox credentials"]
async fn pay_invoice_against_live_sandbox() {
    let stripe = crate::common::live_stripe_helpers::build_live_stripe_handles();

    let customer_email = format!("stage2-pay-live-{}@flapjack.foo", uuid::Uuid::new_v4());
    let stripe_customer_id = stripe
        .service
        .create_customer("Stage2 Pay Contract", &customer_email)
        .await
        .expect("live stripe customer should be created");
    let payment_method_id = crate::common::live_stripe_helpers::attach_test_payment_method(
        &stripe.client,
        &stripe_customer_id,
    )
    .await;

    stripe
        .service
        .set_default_payment_method(&stripe_customer_id, &payment_method_id)
        .await
        .expect("default payment method should set");

    let finalized_invoice = stripe
        .service
        .create_and_finalize_invoice(
            &stripe_customer_id,
            &[StripeInvoiceLineItem {
                description: "Stage2 live pay contract".to_string(),
                amount_cents: 250,
            }],
            None,
            None,
        )
        .await
        .expect("live invoice should finalize");

    let pay_result = stripe
        .service
        .pay_invoice(&finalized_invoice.stripe_invoice_id)
        .await
        .expect("live invoice pay should succeed");

    assert_eq!(pay_result.id, finalized_invoice.stripe_invoice_id);
    assert_eq!(pay_result.status, "paid");
    assert_eq!(pay_result.amount_paid_cents, 250);
    assert!(pay_result.last_payment_error.is_none());

    crate::common::live_stripe_helpers::delete_stripe_customer(&stripe.client, &stripe_customer_id)
        .await;
}

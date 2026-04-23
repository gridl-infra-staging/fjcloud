mod common;

use api::models::{PlanTier, SubscriptionStatus};
use api::repos::subscription_repo::{NewSubscription, SubscriptionRepo};
use api::repos::RepoError;
use chrono::NaiveDate;
use common::MockSubscriptionRepo;
use std::sync::Arc;
use uuid::Uuid;

fn create_test_subscription(customer_id: Uuid) -> NewSubscription {
    NewSubscription {
        customer_id,
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        stripe_price_id: "price_starter_monthly".to_string(),
        plan_tier: PlanTier::Starter,
        status: SubscriptionStatus::Active,
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        cancel_at_period_end: false,
    }
}

// ============================================================================
// CREATE TESTS
// ============================================================================

#[tokio::test]
async fn create_inserts_and_returns_subscription() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let sub = repo.create(new_sub.clone()).await.unwrap();

    assert_eq!(sub.customer_id, customer_id);
    assert_eq!(sub.stripe_subscription_id, new_sub.stripe_subscription_id);
    assert_eq!(sub.stripe_price_id, new_sub.stripe_price_id);
    assert_eq!(sub.plan_tier, "starter");
    assert_eq!(sub.status, "active");
    assert!(!sub.cancel_at_period_end);
}

#[tokio::test]
async fn create_duplicate_customer_returns_conflict() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    repo.create(new_sub.clone()).await.unwrap();

    // Try to create another subscription for the same customer
    let new_sub2 = NewSubscription {
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        ..new_sub
    };
    let result = repo.create(new_sub2).await;

    assert!(matches!(result, Err(RepoError::Conflict(_))));
}

#[tokio::test]
async fn create_duplicate_stripe_id_returns_conflict() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    repo.create(new_sub.clone()).await.unwrap();

    // Try to create another subscription with the same stripe_subscription_id
    let customer_id2 = Uuid::new_v4();
    let new_sub2 = NewSubscription {
        customer_id: customer_id2,
        ..new_sub
    };
    let result = repo.create(new_sub2).await;

    assert!(matches!(result, Err(RepoError::Conflict(_))));
}

// ============================================================================
// FIND TESTS
// ============================================================================

#[tokio::test]
async fn find_by_id_returns_subscription() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    let found = repo.find_by_id(created.id).await.unwrap();

    assert!(found.is_some());
    assert_eq!(found.unwrap().id, created.id);
}

#[tokio::test]
async fn find_by_id_returns_none_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let found = repo.find_by_id(Uuid::new_v4()).await.unwrap();

    assert!(found.is_none());
}

#[tokio::test]
async fn find_by_customer_returns_subscription() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    repo.create(new_sub).await.unwrap();
    let found = repo.find_by_customer(customer_id).await.unwrap();

    assert!(found.is_some());
    assert_eq!(found.unwrap().customer_id, customer_id);
}

#[tokio::test]
async fn find_by_customer_returns_none_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let found = repo.find_by_customer(Uuid::new_v4()).await.unwrap();

    assert!(found.is_none());
}

#[tokio::test]
async fn find_by_stripe_id_returns_subscription() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub.clone()).await.unwrap();
    let found = repo
        .find_by_stripe_id(&new_sub.stripe_subscription_id)
        .await
        .unwrap();

    assert!(found.is_some());
    assert_eq!(found.unwrap().id, created.id);
}

#[tokio::test]
async fn find_by_stripe_id_returns_none_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let found = repo.find_by_stripe_id("sub_nonexistent").await.unwrap();

    assert!(found.is_none());
}

// ============================================================================
// UPDATE STATUS TESTS
// ============================================================================

#[tokio::test]
async fn update_status_changes_subscription_status() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    assert_eq!(created.status, "active");

    repo.update_status(created.id, SubscriptionStatus::PastDue)
        .await
        .unwrap();

    let updated = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "past_due");
}

#[tokio::test]
async fn update_status_returns_not_found_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let result = repo
        .update_status(Uuid::new_v4(), SubscriptionStatus::Active)
        .await;

    assert!(matches!(result, Err(RepoError::NotFound)));
}

// ============================================================================
// UPDATE PLAN TESTS
// ============================================================================

#[tokio::test]
async fn update_plan_changes_tier_and_price_id() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    assert_eq!(created.plan_tier, "starter");
    assert_eq!(created.stripe_price_id, "price_starter_monthly");

    repo.update_plan(created.id, PlanTier::Pro, "price_pro_monthly")
        .await
        .unwrap();

    let updated = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(updated.plan_tier, "pro");
    assert_eq!(updated.stripe_price_id, "price_pro_monthly");
}

#[tokio::test]
async fn update_plan_returns_not_found_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let result = repo
        .update_plan(Uuid::new_v4(), PlanTier::Pro, "price_pro_monthly")
        .await;

    assert!(matches!(result, Err(RepoError::NotFound)));
}

// ============================================================================
// UPDATE PERIOD TESTS
// ============================================================================

#[tokio::test]
async fn update_period_changes_billing_period() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    assert_eq!(
        created.current_period_start,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap()
    );
    assert_eq!(
        created.current_period_end,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap()
    );

    let new_start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let new_end = NaiveDate::from_ymd_opt(2026, 3, 1).unwrap();

    repo.update_period(created.id, new_start, new_end)
        .await
        .unwrap();

    let updated = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(updated.current_period_start, new_start);
    assert_eq!(updated.current_period_end, new_end);
}

#[tokio::test]
async fn update_period_returns_not_found_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let result = repo
        .update_period(
            Uuid::new_v4(),
            NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
            NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        )
        .await;

    assert!(matches!(result, Err(RepoError::NotFound)));
}

// ============================================================================
// SET CANCEL AT PERIOD END TESTS
// ============================================================================

#[tokio::test]
async fn set_cancel_at_period_end_updates_flag() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    assert!(!created.cancel_at_period_end);

    repo.set_cancel_at_period_end(created.id, true)
        .await
        .unwrap();

    let updated = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert!(updated.cancel_at_period_end);

    // Can also clear the flag
    repo.set_cancel_at_period_end(created.id, false)
        .await
        .unwrap();

    let cleared = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert!(!cleared.cancel_at_period_end);
}

#[tokio::test]
async fn set_cancel_at_period_end_returns_not_found_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let result = repo.set_cancel_at_period_end(Uuid::new_v4(), true).await;

    assert!(matches!(result, Err(RepoError::NotFound)));
}

// ============================================================================
// MARK CANCELED TESTS
// ============================================================================

#[tokio::test]
async fn mark_canceled_sets_status_and_clears_flag() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = NewSubscription {
        cancel_at_period_end: true,
        ..create_test_subscription(customer_id)
    };

    let created = repo.create(new_sub).await.unwrap();
    repo.mark_canceled(created.id).await.unwrap();

    let updated = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "canceled");
    assert!(!updated.cancel_at_period_end);
}

#[tokio::test]
async fn find_by_customer_returns_none_after_cancellation() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();
    repo.mark_canceled(created.id).await.unwrap();

    let found = repo.find_by_customer(customer_id).await.unwrap();
    assert!(
        found.is_none(),
        "find_by_customer should only return a non-canceled current subscription"
    );
}

#[tokio::test]
async fn create_allows_resubscribe_after_cancellation() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let initial = create_test_subscription(customer_id);

    let canceled = repo.create(initial).await.unwrap();
    repo.mark_canceled(canceled.id).await.unwrap();

    let replacement = NewSubscription {
        customer_id,
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        stripe_price_id: "price_pro_monthly".to_string(),
        plan_tier: PlanTier::Pro,
        status: SubscriptionStatus::Active,
        current_period_start: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        cancel_at_period_end: false,
    };

    let created = repo
        .create(replacement)
        .await
        .expect("customer should be able to create a new subscription after cancellation");
    assert_eq!(created.plan_tier, "pro");

    let current = repo.find_by_customer(customer_id).await.unwrap().unwrap();
    assert_eq!(current.id, created.id);
}

#[tokio::test]
async fn mark_canceled_returns_not_found_for_nonexistent() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let result = repo.mark_canceled(Uuid::new_v4()).await;

    assert!(matches!(result, Err(RepoError::NotFound)));
}

// ============================================================================
// PLAN TIER TESTS
// ============================================================================

#[tokio::test]
async fn create_with_different_plan_tiers() {
    let repo = Arc::new(MockSubscriptionRepo::new());

    // Starter
    let customer1 = Uuid::new_v4();
    let sub1 = NewSubscription {
        customer_id: customer1,
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        stripe_price_id: "price_starter".to_string(),
        plan_tier: PlanTier::Starter,
        status: SubscriptionStatus::Active,
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        cancel_at_period_end: false,
    };
    let created1 = repo.create(sub1).await.unwrap();
    assert_eq!(created1.plan_tier, "starter");

    // Pro
    let customer2 = Uuid::new_v4();
    let sub2 = NewSubscription {
        customer_id: customer2,
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        stripe_price_id: "price_pro".to_string(),
        plan_tier: PlanTier::Pro,
        status: SubscriptionStatus::Active,
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        cancel_at_period_end: false,
    };
    let created2 = repo.create(sub2).await.unwrap();
    assert_eq!(created2.plan_tier, "pro");

    // Enterprise
    let customer3 = Uuid::new_v4();
    let sub3 = NewSubscription {
        customer_id: customer3,
        stripe_subscription_id: format!("sub_{}", Uuid::new_v4().simple()),
        stripe_price_id: "price_enterprise".to_string(),
        plan_tier: PlanTier::Enterprise,
        status: SubscriptionStatus::Active,
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        cancel_at_period_end: false,
    };
    let created3 = repo.create(sub3).await.unwrap();
    assert_eq!(created3.plan_tier, "enterprise");
}

// ============================================================================
// SUBSCRIPTION STATUS TESTS
// ============================================================================

#[tokio::test]
async fn update_status_through_all_states() {
    let repo = Arc::new(MockSubscriptionRepo::new());
    let customer_id = Uuid::new_v4();
    let new_sub = create_test_subscription(customer_id);

    let created = repo.create(new_sub).await.unwrap();

    // Active -> Trialing
    repo.update_status(created.id, SubscriptionStatus::Trialing)
        .await
        .unwrap();
    let s = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(s.status, "trialing");

    // Trialing -> Active
    repo.update_status(created.id, SubscriptionStatus::Active)
        .await
        .unwrap();
    let s = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(s.status, "active");

    // Active -> PastDue
    repo.update_status(created.id, SubscriptionStatus::PastDue)
        .await
        .unwrap();
    let s = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(s.status, "past_due");

    // PastDue -> Unpaid
    repo.update_status(created.id, SubscriptionStatus::Unpaid)
        .await
        .unwrap();
    let s = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(s.status, "unpaid");

    // Unpaid -> Canceled
    repo.update_status(created.id, SubscriptionStatus::Canceled)
        .await
        .unwrap();
    let s = repo.find_by_id(created.id).await.unwrap().unwrap();
    assert_eq!(s.status, "canceled");
}

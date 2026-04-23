mod common;

use api::models::PlanTier;

#[tokio::test]
async fn test_state_wires_subscription_repo_and_plan_registry() {
    let state = common::test_state();

    // Ensure the injected repo is callable and returns no record for unknown customer.
    let customer_id = uuid::Uuid::new_v4();
    let found = state
        .subscription_repo
        .find_by_customer(customer_id)
        .await
        .expect("subscription lookup should succeed");
    assert!(found.is_none());

    // Ensure plan registry is present and returns expected tier limits.
    let starter = state.plan_registry.get_limits(PlanTier::Starter);
    assert_eq!(starter.max_searches_per_month, 100_000);
    assert_eq!(starter.max_indexes, 5);
}

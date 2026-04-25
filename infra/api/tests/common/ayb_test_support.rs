use api::models::ayb_tenant::{AybTenantStatus, NewAybTenant};
use api::repos::InMemoryAybTenantRepo;
use api::state::AppState;
use billing::plan::PlanTier;
use std::sync::Arc;
use uuid::Uuid;

use super::{MockCustomerRepo, TestStateBuilder};

/// Shared AYB in-memory repo constructor for account and allyourbase route tests.
pub fn seed_ayb_tenant_repo() -> Arc<InMemoryAybTenantRepo> {
    Arc::new(InMemoryAybTenantRepo::new())
}

/// Canonical active/ready AYB tenant seed used by route-level tests.
pub fn new_ready_ayb_tenant(customer_id: Uuid) -> NewAybTenant {
    NewAybTenant {
        customer_id,
        ayb_tenant_id: format!("ayb-tid-{}", Uuid::new_v4()),
        ayb_slug: format!("slug-{}", &Uuid::new_v4().to_string()[..8]),
        ayb_cluster_id: "cluster-01".to_string(),
        ayb_url: "https://ayb.test/cluster-01".to_string(),
        status: AybTenantStatus::Ready,
        plan: PlanTier::Starter,
    }
}

/// Build AppState with a caller-provided AYB tenant repo and customer repo.
pub fn test_state_with_ayb_tenant_repo(
    customer_repo: Arc<MockCustomerRepo>,
    ayb_repo: Arc<InMemoryAybTenantRepo>,
) -> AppState {
    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .build();
    state.ayb_tenant_repo = ayb_repo;
    state
}

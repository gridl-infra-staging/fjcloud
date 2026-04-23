mod common;

use api::models::PlanTier;
use api::services::ayb_admin::{
    AybAdminClient, AybAdminError, AybTenantResponse, CreateTenantRequest,
};
use async_trait::async_trait;
use common::builders::TestStateBuilder;
use std::sync::Arc;

struct MockAybAdminClient;

#[async_trait]
impl AybAdminClient for MockAybAdminClient {
    fn base_url(&self) -> &str {
        "https://mock.ayb.example.com"
    }

    fn cluster_id(&self) -> &str {
        "cluster-01"
    }

    async fn create_tenant(
        &self,
        _request: CreateTenantRequest,
    ) -> Result<AybTenantResponse, AybAdminError> {
        Ok(AybTenantResponse {
            tenant_id: "mock-tenant-123".to_string(),
            name: "Mock Tenant".to_string(),
            slug: "mock-slug".to_string(),
            state: "active".to_string(),
            plan_tier: PlanTier::Enterprise,
        })
    }

    async fn delete_tenant(&self, tenant_id: &str) -> Result<AybTenantResponse, AybAdminError> {
        Ok(AybTenantResponse {
            tenant_id: tenant_id.to_string(),
            name: "Mock Tenant".to_string(),
            slug: "mock-slug".to_string(),
            state: "deleting".to_string(),
            plan_tier: PlanTier::Enterprise,
        })
    }
}

#[tokio::test]
async fn ayb_admin_app_state_boots_without_ayb_configured() {
    let state = TestStateBuilder::new().build();
    assert!(state.ayb_admin_client.is_none());
}

#[tokio::test]
async fn ayb_admin_app_state_boots_with_ayb_configured() {
    let mock_client: Arc<dyn AybAdminClient + Send + Sync> = Arc::new(MockAybAdminClient);
    let state = TestStateBuilder::new()
        .with_ayb_admin_client(mock_client)
        .build();
    assert!(state.ayb_admin_client.is_some());
}

#[tokio::test]
async fn ayb_admin_injected_mock_client_is_usable() {
    let mock_client: Arc<dyn AybAdminClient + Send + Sync> = Arc::new(MockAybAdminClient);
    let state = TestStateBuilder::new()
        .with_ayb_admin_client(mock_client)
        .build();

    let client = state.ayb_admin_client.as_ref().unwrap();
    let resp = client
        .create_tenant(CreateTenantRequest {
            name: "Test Tenant".to_string(),
            slug: "test".to_string(),
            plan_tier: PlanTier::Enterprise,
            owner_user_id: None,
            region: None,
            org_metadata: None,
            idempotency_key: None,
        })
        .await
        .unwrap();

    assert_eq!(resp.tenant_id, "mock-tenant-123");
}

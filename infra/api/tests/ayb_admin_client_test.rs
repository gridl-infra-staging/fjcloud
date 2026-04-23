use api::config::AybAdminConfig;
use api::models::PlanTier;
use api::services::ayb_admin::{
    AybAdminClient, AybAdminError, CreateTenantRequest, ReqwestAybAdminClient,
};
use serde_json::{json, Value};
use std::time::Duration;
use wiremock::matchers::{body_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn test_config(base_url: &str) -> AybAdminConfig {
    AybAdminConfig {
        base_url: base_url.to_string(),
        cluster_id: "cluster-01".to_string(),
        admin_password: "test-admin-pw".to_string(),
    }
}

fn create_request() -> CreateTenantRequest {
    CreateTenantRequest {
        name: "My Tenant".to_string(),
        slug: "my-tenant".to_string(),
        plan_tier: PlanTier::Enterprise,
        owner_user_id: None,
        region: None,
        org_metadata: None,
        idempotency_key: None,
    }
}

fn create_tenant_payload(owner_user_id: Option<&str>) -> Value {
    let mut payload = json!({
        "name": "My Tenant",
        "slug": "my-tenant",
        "isolationMode": "schema",
        "planTier": "enterprise"
    });

    if let Some(owner_user_id) = owner_user_id {
        payload
            .as_object_mut()
            .expect("payload should be object")
            .insert("ownerUserId".to_string(), json!(owner_user_id));
    }

    payload
}

fn tenant_response_with_id(tenant_id: &str, state: &str) -> Value {
    json!({
        "id": tenant_id,
        "name": "My Tenant",
        "slug": "my-tenant",
        "isolationMode": "schema",
        "planTier": "enterprise",
        "state": state,
        "createdAt": "2026-03-17T04:00:00Z",
        "updatedAt": "2026-03-17T04:00:00Z"
    })
}

fn tenant_response(state: &str) -> Value {
    tenant_response_with_id("ayb-tenant-123", state)
}

async fn mount_login(server: &MockServer, token: &str) {
    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .and(body_json(json!({"password": "test-admin-pw"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": token})))
        .mount(server)
        .await;
}

async fn mount_create_tenant(server: &MockServer) {
    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .and(header("Authorization", "Bearer valid-token"))
        .and(body_json(create_tenant_payload(None)))
        .respond_with(ResponseTemplate::new(201).set_body_json(tenant_response("active")))
        .mount(server)
        .await;
}

#[tokio::test]
async fn ayb_admin_create_tenant_logs_in_and_returns_response() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;
    mount_create_tenant(&server).await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let resp = client.create_tenant(create_request()).await.unwrap();

    assert_eq!(resp.tenant_id, "ayb-tenant-123");
    assert_eq!(resp.name, "My Tenant");
    assert_eq!(resp.slug, "my-tenant");
    assert_eq!(resp.state, "active");
    assert_eq!(resp.plan_tier, PlanTier::Enterprise);
}

#[tokio::test]
async fn ayb_admin_bearer_token_is_reused_across_calls() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "valid-token"})))
        .expect(1)
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .and(header("Authorization", "Bearer valid-token"))
        .and(body_json(create_tenant_payload(None)))
        .respond_with(ResponseTemplate::new(201).set_body_json(tenant_response("active")))
        .expect(2)
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    client.create_tenant(create_request()).await.unwrap();
    client.create_tenant(create_request()).await.unwrap();
}

#[tokio::test]
async fn ayb_admin_retries_once_on_401_with_fresh_token() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "fresh-token"})))
        .expect(2)
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .respond_with(ResponseTemplate::new(401))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .and(header("Authorization", "Bearer fresh-token"))
        .and(body_json(create_tenant_payload(None)))
        .respond_with(ResponseTemplate::new(201).set_body_json(tenant_response("active")))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let resp = client.create_tenant(create_request()).await.unwrap();

    assert_eq!(resp.tenant_id, "ayb-tenant-123");
}

#[tokio::test]
async fn ayb_admin_no_infinite_retry_on_persistent_401() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"token": "bad-token"})))
        .expect(2)
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .respond_with(ResponseTemplate::new(401))
        .expect(2)
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::Unauthorized));
}

#[tokio::test]
async fn ayb_admin_upstream_404_returns_not_found() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::NotFound(_)));
}

#[tokio::test]
async fn ayb_admin_upstream_409_returns_conflict() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .respond_with(ResponseTemplate::new(409))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::Conflict(_)));
}

#[tokio::test]
async fn ayb_admin_upstream_5xx_returns_service_unavailable() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .respond_with(ResponseTemplate::new(502))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::ServiceUnavailable));
}

#[tokio::test]
async fn ayb_admin_unreachable_server_returns_service_unavailable() {
    let client = ReqwestAybAdminClient::new(&test_config("http://127.0.0.1:1"));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::ServiceUnavailable));
}

#[tokio::test]
async fn ayb_admin_login_failure_returns_unauthorized() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::Unauthorized));
}

#[tokio::test]
async fn ayb_admin_create_tenant_forwards_owner_user_id_when_set() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    Mock::given(method("POST"))
        .and(path("/admin/tenants"))
        .and(header("Authorization", "Bearer valid-token"))
        .and(body_json(create_tenant_payload(Some(
            "00000000-0000-0000-0000-000000000042",
        ))))
        .respond_with(ResponseTemplate::new(201).set_body_json(tenant_response("active")))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let req = CreateTenantRequest {
        owner_user_id: Some("00000000-0000-0000-0000-000000000042".to_string()),
        ..create_request()
    };
    let resp = client.create_tenant(req).await.unwrap();

    assert_eq!(resp.tenant_id, "ayb-tenant-123");
}

#[tokio::test]
async fn ayb_admin_delete_tenant_uses_verified_contract() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    Mock::given(method("DELETE"))
        .and(path("/admin/tenants/ayb-tenant-123"))
        .and(header("Authorization", "Bearer valid-token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(tenant_response("deleting")))
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let resp = client.delete_tenant("ayb-tenant-123").await.unwrap();

    assert_eq!(resp.tenant_id, "ayb-tenant-123");
    assert_eq!(resp.state, "deleting");
}

#[tokio::test]
async fn ayb_admin_delete_tenant_encodes_path_segments() {
    let server = MockServer::start().await;
    mount_login(&server, "valid-token").await;

    let tenant_id = "tenant/with?reserved#chars";
    Mock::given(method("DELETE"))
        .and(path("/admin/tenants/tenant%2Fwith%3Freserved%23chars"))
        .and(header("Authorization", "Bearer valid-token"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(tenant_response_with_id(tenant_id, "deleting")),
        )
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new(&test_config(&server.uri()));
    let resp = client.delete_tenant(tenant_id).await.unwrap();

    assert_eq!(resp.tenant_id, tenant_id);
    assert_eq!(resp.state, "deleting");
}

#[tokio::test]
async fn ayb_admin_timeout_returns_service_unavailable() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/admin/auth"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"token": "valid-token"}))
                .set_delay(Duration::from_secs(5)),
        )
        .mount(&server)
        .await;

    let client = ReqwestAybAdminClient::new_with_timeout(
        &test_config(&server.uri()),
        Duration::from_millis(100),
    );
    let err = client.create_tenant(create_request()).await.unwrap_err();

    assert!(matches!(err, AybAdminError::ServiceUnavailable));
}

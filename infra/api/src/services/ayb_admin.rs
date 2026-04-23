//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/ayb_admin.rs.
use async_trait::async_trait;
use reqwest::Url;
use reqwest::{Client, RequestBuilder, Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use std::time::Duration;
use tokio::sync::RwLock;

use crate::config::AybAdminConfig;
use crate::models::PlanTier;

const DEFAULT_ISOLATION_MODE: &str = "schema";
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug)]
pub enum AybAdminError {
    BadRequest(String),
    NotFound(String),
    Conflict(String),
    ServiceUnavailable,
    Unauthorized,
    Internal(String),
}

impl fmt::Display for AybAdminError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadRequest(msg) => write!(f, "bad request: {msg}"),
            Self::NotFound(msg) => write!(f, "not found: {msg}"),
            Self::Conflict(msg) => write!(f, "conflict: {msg}"),
            Self::ServiceUnavailable => write!(f, "AYB service unavailable"),
            Self::Unauthorized => write!(f, "AYB admin authentication failed"),
            Self::Internal(msg) => write!(f, "AYB internal error: {msg}"),
        }
    }
}

impl std::error::Error for AybAdminError {}

#[derive(Debug, Clone)]
pub struct CreateTenantRequest {
    pub name: String,
    pub slug: String,
    pub plan_tier: PlanTier,
    pub owner_user_id: Option<String>,
    pub region: Option<String>,
    pub org_metadata: Option<Value>,
    pub idempotency_key: Option<String>,
}

impl CreateTenantRequest {
    fn payload(&self) -> CreateTenantPayload<'_> {
        CreateTenantPayload {
            name: &self.name,
            slug: &self.slug,
            owner_user_id: self.owner_user_id.as_deref(),
            isolation_mode: DEFAULT_ISOLATION_MODE,
            plan_tier: self.plan_tier,
            region: self.region.as_deref(),
            org_metadata: self.org_metadata.as_ref(),
            idempotency_key: self.idempotency_key.as_deref(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateTenantPayload<'a> {
    name: &'a str,
    slug: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    owner_user_id: Option<&'a str>,
    isolation_mode: &'static str,
    plan_tier: PlanTier,
    #[serde(skip_serializing_if = "Option::is_none")]
    region: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    org_metadata: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    idempotency_key: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AybTenantResponse {
    #[serde(rename = "id")]
    pub tenant_id: String,
    pub name: String,
    pub slug: String,
    pub state: String,
    pub plan_tier: PlanTier,
}

#[async_trait]
pub trait AybAdminClient: Send + Sync {
    fn base_url(&self) -> &str;
    fn cluster_id(&self) -> &str;

    async fn create_tenant(
        &self,
        request: CreateTenantRequest,
    ) -> Result<AybTenantResponse, AybAdminError>;

    async fn delete_tenant(&self, tenant_id: &str) -> Result<AybTenantResponse, AybAdminError>;
}

pub struct ReqwestAybAdminClient {
    http: Client,
    base_url: String,
    cluster_id: String,
    admin_password: String,
    bearer_token: RwLock<Option<String>>,
}

impl ReqwestAybAdminClient {
    pub fn new(config: &AybAdminConfig) -> Self {
        Self::new_with_timeout(config, DEFAULT_REQUEST_TIMEOUT)
    }

    pub fn new_with_timeout(config: &AybAdminConfig, timeout: Duration) -> Self {
        let http = Client::builder()
            .timeout(timeout)
            .build()
            .expect("reqwest client builder should not fail");

        Self {
            http,
            base_url: config.base_url.trim_end_matches('/').to_string(),
            cluster_id: config.cluster_id.clone(),
            admin_password: config.admin_password.clone(),
            bearer_token: RwLock::new(None),
        }
    }

    fn auth_url(&self) -> String {
        self.admin_url(&["auth"])
    }

    fn tenants_url(&self) -> String {
        self.admin_url(&["tenants"])
    }

    fn tenant_url(&self, tenant_id: &str) -> String {
        self.admin_url(&["tenants", tenant_id])
    }

    fn admin_url(&self, segments: &[&str]) -> String {
        let mut url = Url::parse(&self.base_url)
            .expect("AYB base URL should have been validated during config parsing");
        {
            let mut path_segments = url
                .path_segments_mut()
                .expect("AYB base URL must support hierarchical path segments");
            path_segments.pop_if_empty();
            path_segments.push("admin");
            for segment in segments {
                path_segments.push(segment);
            }
        }
        url.to_string()
    }

    /// POSTs the admin password to the AYB authentication endpoint and returns
    /// the bearer token from the response.
    ///
    /// Maps HTTP 401 to [`AybAdminError::Unauthorized`] and 5xx status codes
    /// to [`AybAdminError::ServiceUnavailable`].
    async fn login(&self) -> Result<String, AybAdminError> {
        #[derive(Serialize)]
        struct LoginRequest<'a> {
            password: &'a str,
        }

        #[derive(Deserialize)]
        struct LoginResponse {
            token: String,
        }

        let response = self
            .http
            .post(self.auth_url())
            .json(&LoginRequest {
                password: &self.admin_password,
            })
            .send()
            .await
            .map_err(map_request_error)?;

        let status = response.status();
        if status == StatusCode::UNAUTHORIZED {
            return Err(AybAdminError::Unauthorized);
        }
        if status.is_server_error() {
            return Err(AybAdminError::ServiceUnavailable);
        }
        if !status.is_success() {
            return Err(AybAdminError::Internal(format!(
                "login returned HTTP {status}"
            )));
        }

        let body: LoginResponse = response.json().await.map_err(|error| {
            AybAdminError::Internal(format!("login response parse failed: {error}"))
        })?;

        Ok(body.token)
    }

    async fn ensure_token(&self) -> Result<String, AybAdminError> {
        {
            let cached = self.bearer_token.read().await;
            if let Some(token) = cached.as_ref() {
                return Ok(token.clone());
            }
        }

        let token = self.login().await?;
        let mut cached = self.bearer_token.write().await;
        *cached = Some(token.clone());
        Ok(token)
    }

    async fn invalidate_token(&self) {
        let mut cached = self.bearer_token.write().await;
        *cached = None;
    }

    /// Sends an HTTP request with the cached bearer token.
    ///
    /// On a 401 response, invalidates the cached token and retries exactly
    /// once with a freshly obtained token, providing transparent token refresh.
    async fn send_authenticated<F>(&self, build_request: F) -> Result<Response, AybAdminError>
    where
        F: Fn(&str) -> RequestBuilder,
    {
        let token = self.ensure_token().await?;
        let response = build_request(&token)
            .send()
            .await
            .map_err(map_request_error)?;

        if response.status() != StatusCode::UNAUTHORIZED {
            return Ok(response);
        }

        self.invalidate_token().await;

        let fresh_token = self.ensure_token().await?;
        build_request(&fresh_token)
            .send()
            .await
            .map_err(map_request_error)
    }
}

#[async_trait]
impl AybAdminClient for ReqwestAybAdminClient {
    fn base_url(&self) -> &str {
        &self.base_url
    }

    fn cluster_id(&self) -> &str {
        &self.cluster_id
    }

    async fn create_tenant(
        &self,
        request: CreateTenantRequest,
    ) -> Result<AybTenantResponse, AybAdminError> {
        let payload = request.payload();
        let url = self.tenants_url();
        let response = self
            .send_authenticated(|token| self.http.post(&url).bearer_auth(token).json(&payload))
            .await?;

        parse_tenant_response(response).await
    }

    async fn delete_tenant(&self, tenant_id: &str) -> Result<AybTenantResponse, AybAdminError> {
        let url = self.tenant_url(tenant_id);
        let response = self
            .send_authenticated(|token| self.http.delete(&url).bearer_auth(token))
            .await?;

        parse_tenant_response(response).await
    }
}

/// Parses an HTTP response body into an [`AybTenantResponse`].
///
/// Maps status codes to typed errors: 400 -> [`AybAdminError::BadRequest`],
/// 404 -> [`AybAdminError::NotFound`], 409 -> [`AybAdminError::Conflict`],
/// 5xx -> [`AybAdminError::ServiceUnavailable`].
async fn parse_tenant_response(response: Response) -> Result<AybTenantResponse, AybAdminError> {
    let status = response.status();

    if status.is_success() {
        return response
            .json()
            .await
            .map_err(|error| AybAdminError::Internal(format!("response parse failed: {error}")));
    }

    let body = response.text().await.unwrap_or_default();

    match status.as_u16() {
        400 => Err(AybAdminError::BadRequest("AYB request rejected".into())),
        404 => Err(AybAdminError::NotFound("AYB tenant not found".into())),
        409 => Err(AybAdminError::Conflict("AYB tenant already exists".into())),
        401 => Err(AybAdminError::Unauthorized),
        status if (500..600).contains(&status) => Err(AybAdminError::ServiceUnavailable),
        _ => Err(AybAdminError::Internal(format!(
            "unexpected HTTP {status}: {body}"
        ))),
    }
}

fn map_request_error(error: reqwest::Error) -> AybAdminError {
    if error.is_timeout() || error.is_connect() {
        AybAdminError::ServiceUnavailable
    } else {
        AybAdminError::Internal(format!("request failed: {error}"))
    }
}

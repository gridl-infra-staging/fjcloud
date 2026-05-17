use aes_gcm::aead::{Aead, OsRng};
use aes_gcm::{AeadCore, Aes256Gcm, KeyInit};
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::models::Customer;
use crate::repos::RepoError;
use crate::routes::auth::{issue_jwt, AuthResponse};
use crate::state::{AppState, OAuthProviderRuntimeConfig};

const GOOGLE_AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const GITHUB_AUTH_URL: &str = "https://github.com/login/oauth/authorize";
const OAUTH_STATE_COOKIE_NAME: &str = "oauth_state";
// Companion non-encrypted "binding" cookie. Same scope as oauth_state. The
// browser-binding defense is: at start_oauth we generate a fresh random
// `bound_session_id`, embed it in the encrypted OAuthState plaintext, AND
// write it to this separate cookie. At exchange time we require both
// cookies to be present AND matching. This stops the OAuth login-fixation
// vector where an attacker harvests their own oauth_state cookie and forces
// it onto a victim — a victim's browser would not have the matching
// binding cookie, so the exchange fails closed. See
// docs/runbooks/evidence/oauth-postmerge-review/20260506T084601Z/findings.md
// § DEFECT 2 for the threat model.
const OAUTH_STATE_BINDING_COOKIE_NAME: &str = "oauth_state_binding";
const OAUTH_STATE_COOKIE_MAX_AGE_SECONDS: u32 = 600;
const HKDF_INFO: &[u8] = b"fjcloud/oauth-state-cookie/v1";
const OAUTH_CUSTOMER_UNVERIFIED_LOCAL_CONFLICT: &str = "oauth_customer_unverified_local_conflict";
const OAUTH_SYNTHETIC_EMAIL_CONFLICT: &str = "oauth_synthetic_email_conflict";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Copy)]
enum OAuthProvider {
    Google,
    GitHub,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OAuthState {
    pub provider: String,
    pub csrf_state: String,
    pub pkce_verifier: Option<String>,
    // Required field — paired with the non-encrypted oauth_state_binding
    // cookie at exchange time. Old-format cookies missing this field will
    // fail to deserialize and force the user to restart the OAuth flow.
    // The 10-minute Max-Age caps the rollout-window UX hit.
    pub bound_session_id: String,
}

#[derive(Debug, Deserialize)]
pub struct ExchangeRequest {
    pub code: Option<String>,
    pub csrf_token: Option<String>,
}

#[derive(Debug)]
struct OAuthProviderIdentity {
    provider_user_id: String,
    email: Option<String>,
    email_verified: bool,
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OAuthTokenResponse {
    access_token: String,
}

#[derive(Debug, Deserialize)]
struct GoogleUserInfoResponse {
    sub: String,
    email: Option<String>,
    email_verified: Option<bool>,
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GitHubUserInfoResponse {
    id: u64,
    name: Option<String>,
    login: String,
}

#[derive(Debug, Deserialize)]
struct GitHubEmailEntry {
    email: String,
    primary: bool,
    verified: bool,
}

pub async fn start_oauth(
    State(state): State<AppState>,
    Path(provider): Path<String>,
) -> axum::response::Response {
    let provider = match parse_provider(&provider) {
        Some(provider) => provider,
        None => return oauth_not_implemented_response(),
    };

    let Some(provider_cfg) = provider_config_for(&state, provider) else {
        return oauth_not_implemented_response();
    };

    let csrf_state = random_urlsafe(32);
    let pkce_verifier = provider_uses_pkce(provider).then(|| random_urlsafe(64));
    // Browser-binding nonce: 32 url-safe chars of entropy. Stored in TWO
    // places — the encrypted oauth_state plaintext and a separate marker
    // cookie. Match check at exchange time is what closes the
    // login-fixation vector.
    let bound_session_id = random_urlsafe(32);
    let oauth_state = OAuthState {
        provider: provider_name(provider).to_string(),
        csrf_state: csrf_state.clone(),
        pkce_verifier: pkce_verifier.clone(),
        bound_session_id: bound_session_id.clone(),
    };

    let cookie_value = match encrypt_oauth_state_cookie(&state.jwt_secret, &oauth_state) {
        Ok(value) => value,
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "internal server error").into_response()
        }
    };

    let authorization_url = build_authorization_url(
        provider,
        &provider_cfg,
        &csrf_state,
        pkce_verifier.as_deref(),
    );

    let mut response = StatusCode::FOUND.into_response();
    response.headers_mut().insert(
        header::LOCATION,
        HeaderValue::from_str(&authorization_url).unwrap_or_else(|_| HeaderValue::from_static("/")),
    );

    // Order matters for tests that read the FIRST Set-Cookie header expecting
    // oauth_state — keep oauth_state appended first, then the binding cookie.
    if let Ok(cookie_header) =
        build_oauth_cookie_header(&state, OAUTH_STATE_COOKIE_NAME, &cookie_value)
    {
        response
            .headers_mut()
            .append(header::SET_COOKIE, cookie_header);
    }
    if let Ok(binding_header) =
        build_oauth_cookie_header(&state, OAUTH_STATE_BINDING_COOKIE_NAME, &bound_session_id)
    {
        response
            .headers_mut()
            .append(header::SET_COOKIE, binding_header);
    }

    response
}

pub async fn exchange_oauth_code(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    headers: HeaderMap,
    Json(req): Json<ExchangeRequest>,
) -> axum::response::Response {
    let provider = match parse_provider(&provider) {
        Some(provider) => provider,
        None => return oauth_not_implemented_response(),
    };
    let Some(provider_cfg) = provider_config_for(&state, provider) else {
        return oauth_not_implemented_response();
    };

    let Some(code) = req.code.as_deref().filter(|value| !value.is_empty()) else {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_code_missing");
    };
    let Some(csrf_token) = req.csrf_token.as_deref().filter(|value| !value.is_empty()) else {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_csrf_token_missing");
    };

    let Some(cookie_value) = extract_cookie(&headers, OAUTH_STATE_COOKIE_NAME) else {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_state_cookie_missing");
    };
    let oauth_state = match decrypt_oauth_state_cookie(&state.jwt_secret, &cookie_value) {
        Ok(state_value) => state_value,
        Err(_) => {
            return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_state_cookie_invalid")
        }
    };

    if oauth_state.provider != provider_name(provider) {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_provider_mismatch");
    }
    if oauth_state.csrf_state != csrf_token {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_csrf_mismatch");
    }
    if provider_uses_pkce(provider) && oauth_state.pkce_verifier.is_none() {
        return oauth_error_response(StatusCode::BAD_REQUEST, "oauth_pkce_verifier_missing");
    }
    // Browser-binding check: the non-encrypted marker cookie set in
    // start_oauth must be present AND match the bound_session_id encoded in
    // the encrypted oauth_state plaintext. Run BEFORE fetch_provider_identity
    // so a fixated cookie can't trigger an OAuth code exchange (which would
    // burn the code and create attacker-side state). 403 because the request
    // is well-formed but the binding contract is violated.
    let Some(binding_cookie) = extract_cookie(&headers, OAUTH_STATE_BINDING_COOKIE_NAME) else {
        return oauth_error_response(StatusCode::FORBIDDEN, "oauth_state_binding_missing");
    };
    if binding_cookie != oauth_state.bound_session_id {
        return oauth_error_response(StatusCode::FORBIDDEN, "oauth_state_binding_mismatch");
    }

    let identity = match fetch_provider_identity(
        provider,
        &provider_cfg,
        code,
        oauth_state.pkce_verifier.as_deref(),
    )
    .await
    {
        Ok(identity) => identity,
        Err((status, code)) => return oauth_error_response(status, code),
    };

    let customer = match resolve_oauth_customer(&state, provider_name(provider), identity).await {
        Ok(customer) => customer,
        Err((status, code)) => return oauth_error_response(status, code),
    };

    let token = match issue_jwt(&customer.id.to_string(), &state.jwt_secret) {
        Ok(token) => token,
        Err(_) => {
            return oauth_error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "oauth_token_issue_failed",
            )
        }
    };

    (
        StatusCode::OK,
        Json(AuthResponse {
            token,
            customer_id: customer.id.to_string(),
        }),
    )
        .into_response()
}

async fn resolve_oauth_customer(
    state: &AppState,
    provider: &str,
    identity: OAuthProviderIdentity,
) -> Result<Customer, (StatusCode, &'static str)> {
    match state
        .customer_repo
        .find_oauth_identity(provider, &identity.provider_user_id)
        .await
    {
        Ok(Some(customer)) => return Ok(customer),
        Ok(None) => {}
        Err(_) => {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "oauth_identity_lookup_failed",
            ))
        }
    }

    let customer_name = identity
        .display_name
        .as_deref()
        .filter(|name| !name.trim().is_empty())
        .unwrap_or("OAuth User");
    let synthetic_email = synthetic_oauth_email(provider, &identity.provider_user_id);
    let provider_verified_email = if identity.email_verified {
        identity
            .email
            .as_deref()
            .map(str::to_ascii_lowercase)
            .filter(|email| !email.trim().is_empty())
    } else {
        None
    };

    let customer = match provider_verified_email {
        Some(provider_email) => match find_active_customer_by_email(state, &provider_email).await {
            Ok(Some(existing)) if existing.email_verified_at.is_some() => existing,
            Ok(Some(_)) => {
                create_or_find_synthetic_oauth_customer(
                    state,
                    customer_name,
                    &synthetic_email,
                    provider,
                    &identity.provider_user_id,
                )
                .await?
            }
            Ok(None) => {
                match create_or_find_oauth_customer(state, customer_name, &provider_email).await {
                    Ok(customer) => customer,
                    Err((StatusCode::CONFLICT, OAUTH_CUSTOMER_UNVERIFIED_LOCAL_CONFLICT)) => {
                        create_or_find_synthetic_oauth_customer(
                            state,
                            customer_name,
                            &synthetic_email,
                            provider,
                            &identity.provider_user_id,
                        )
                        .await?
                    }
                    Err(code) => return Err(code),
                }
            }
            Err(code) => return Err(code),
        },
        None => {
            create_or_find_synthetic_oauth_customer(
                state,
                customer_name,
                &synthetic_email,
                provider,
                &identity.provider_user_id,
            )
            .await?
        }
    };

    match state
        .customer_repo
        .link_oauth_identity(customer.id, provider, &identity.provider_user_id)
        .await
    {
        Ok(()) => Ok(customer),
        Err(RepoError::NotFound) => Err((StatusCode::FORBIDDEN, "oauth_customer_deleted")),
        Err(RepoError::Conflict(_)) => match state
            .customer_repo
            .find_oauth_identity(provider, &identity.provider_user_id)
            .await
        {
            Ok(Some(existing)) => Ok(existing),
            _ => Err((StatusCode::CONFLICT, "oauth_identity_link_conflict")),
        },
        Err(_) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "oauth_identity_link_failed",
        )),
    }
}

async fn create_or_find_oauth_customer(
    state: &AppState,
    customer_name: &str,
    customer_email: &str,
) -> Result<Customer, (StatusCode, &'static str)> {
    match state
        .customer_repo
        .create_oauth_customer(customer_name, customer_email)
        .await
    {
        Ok(created) => Ok(created),
        Err(RepoError::Conflict(_)) => {
            match find_active_customer_by_email(state, customer_email).await {
                Ok(Some(existing)) if existing.email_verified_at.is_some() => Ok(existing),
                Ok(Some(_)) => Err((
                    StatusCode::CONFLICT,
                    OAUTH_CUSTOMER_UNVERIFIED_LOCAL_CONFLICT,
                )),
                Err(code) => Err(code),
                _ => Err((StatusCode::CONFLICT, "oauth_customer_create_conflict")),
            }
        }
        Err(_) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "oauth_customer_create_failed",
        )),
    }
}

async fn create_or_find_synthetic_oauth_customer(
    state: &AppState,
    customer_name: &str,
    synthetic_email: &str,
    provider: &str,
    provider_user_id: &str,
) -> Result<Customer, (StatusCode, &'static str)> {
    match state
        .customer_repo
        .create_oauth_customer(customer_name, synthetic_email)
        .await
    {
        Ok(created) => Ok(created),
        Err(RepoError::Conflict(_)) => {
            // Symmetric guard: both verified-email and synthetic-email paths must
            // reject soft-deleted customers with 403 oauth_customer_deleted.
            find_active_customer_by_email(state, synthetic_email).await?;
            match state
                .customer_repo
                .find_oauth_identity(provider, provider_user_id)
                .await
            {
                Ok(Some(existing)) => Ok(existing),
                Ok(None) => Err((StatusCode::CONFLICT, OAUTH_SYNTHETIC_EMAIL_CONFLICT)),
                Err(_) => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "oauth_identity_lookup_failed",
                )),
            }
        }
        Err(_) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "oauth_customer_create_failed",
        )),
    }
}

async fn find_active_customer_by_email(
    state: &AppState,
    email: &str,
) -> Result<Option<Customer>, (StatusCode, &'static str)> {
    match state.customer_repo.find_by_email(email).await {
        Ok(Some(customer)) if customer.status == "deleted" => {
            Err((StatusCode::FORBIDDEN, "oauth_customer_deleted"))
        }
        Ok(customer) => Ok(customer),
        Err(_) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "oauth_customer_lookup_failed",
        )),
    }
}

fn synthetic_oauth_email(provider: &str, provider_user_id: &str) -> String {
    let normalized = provider_user_id
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect::<String>();
    format!("oauth-{provider}-{normalized}@oauth.flapjack.foo").to_ascii_lowercase()
}

async fn fetch_provider_identity(
    provider: OAuthProvider,
    provider_cfg: &OAuthProviderRuntimeConfig,
    code: &str,
    pkce_verifier: Option<&str>,
) -> Result<OAuthProviderIdentity, (StatusCode, &'static str)> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|_| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "oauth_provider_http_client_init_failed",
            )
        })?;

    let mut token_form = vec![
        ("code", code.to_string()),
        ("client_id", provider_cfg.client_id.as_ref().to_string()),
        (
            "client_secret",
            provider_cfg.client_secret.as_ref().to_string(),
        ),
        (
            "redirect_uri",
            provider_cfg.redirect_uri.as_ref().to_string(),
        ),
    ];

    match provider {
        OAuthProvider::Google => {
            token_form.push(("grant_type", "authorization_code".to_string()));
            if let Some(verifier) = pkce_verifier {
                token_form.push(("code_verifier", verifier.to_string()));
            }
        }
        OAuthProvider::GitHub => {}
    }

    let token_response = client
        .post(provider_cfg.token_endpoint.as_ref())
        .header(header::ACCEPT.as_str(), "application/json")
        .header(header::USER_AGENT.as_str(), "fjcloud-oauth")
        .form(&token_form)
        .send()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_exchange_failed"))?;

    if !token_response.status().is_success() {
        return Err((StatusCode::BAD_GATEWAY, "oauth_provider_exchange_failed"));
    }

    let token_payload = token_response
        .json::<OAuthTokenResponse>()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_exchange_failed"))?;

    let userinfo_response = client
        .get(provider_cfg.userinfo_endpoint.as_ref())
        .bearer_auth(&token_payload.access_token)
        .header(header::ACCEPT.as_str(), "application/json")
        .header(header::USER_AGENT.as_str(), "fjcloud-oauth")
        .send()
        .await
        .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;

    if !userinfo_response.status().is_success() {
        return Err((StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"));
    }

    match provider {
        OAuthProvider::Google => {
            let payload = userinfo_response
                .json::<GoogleUserInfoResponse>()
                .await
                .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;
            Ok(OAuthProviderIdentity {
                provider_user_id: payload.sub,
                email: payload.email,
                email_verified: payload.email_verified.unwrap_or(false),
                display_name: payload.name,
            })
        }
        OAuthProvider::GitHub => {
            let payload = userinfo_response
                .json::<GitHubUserInfoResponse>()
                .await
                .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;

            let user_emails_endpoint = provider_cfg
                .user_emails_endpoint
                .as_ref()
                .ok_or((StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;

            let emails_response = client
                .get(user_emails_endpoint.as_ref())
                .bearer_auth(&token_payload.access_token)
                .header(header::ACCEPT.as_str(), "application/json")
                .header(header::USER_AGENT.as_str(), "fjcloud-oauth")
                .send()
                .await
                .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;

            if !emails_response.status().is_success() {
                return Err((StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"));
            }

            let email_entries = emails_response
                .json::<Vec<GitHubEmailEntry>>()
                .await
                .map_err(|_| (StatusCode::BAD_GATEWAY, "oauth_provider_userinfo_failed"))?;

            let primary_entry = email_entries.iter().find(|e| e.primary);
            let (email, email_verified) = match primary_entry {
                Some(entry) => (Some(entry.email.clone()), entry.verified),
                None => (None, false),
            };

            Ok(OAuthProviderIdentity {
                provider_user_id: payload.id.to_string(),
                email,
                email_verified,
                display_name: payload.name.or(Some(payload.login)),
            })
        }
    }
}

fn extract_cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    let cookie_header = headers.get(header::COOKIE)?.to_str().ok()?;
    cookie_header.split(';').find_map(|part| {
        let trimmed = part.trim();
        let (key, value) = trimmed.split_once('=')?;
        (key == name).then(|| value.to_string())
    })
}

fn oauth_not_implemented_response() -> axum::response::Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(serde_json::json!({"error": "oauth_not_implemented"})),
    )
        .into_response()
}

fn oauth_error_response(status: StatusCode, code: &'static str) -> axum::response::Response {
    (status, Json(serde_json::json!({ "error": code }))).into_response()
}

fn parse_provider(value: &str) -> Option<OAuthProvider> {
    match value {
        "google" => Some(OAuthProvider::Google),
        "github" => Some(OAuthProvider::GitHub),
        _ => None,
    }
}

fn provider_name(provider: OAuthProvider) -> &'static str {
    match provider {
        OAuthProvider::Google => "google",
        OAuthProvider::GitHub => "github",
    }
}

fn provider_uses_pkce(provider: OAuthProvider) -> bool {
    matches!(provider, OAuthProvider::Google)
}

fn provider_config_for(
    state: &AppState,
    provider: OAuthProvider,
) -> Option<OAuthProviderRuntimeConfig> {
    match provider {
        OAuthProvider::Google => state.oauth.google.clone(),
        OAuthProvider::GitHub => state.oauth.github.clone(),
    }
}

fn build_authorization_url(
    provider: OAuthProvider,
    provider_cfg: &OAuthProviderRuntimeConfig,
    csrf_state: &str,
    pkce_verifier: Option<&str>,
) -> String {
    let authorize_endpoint = match provider {
        OAuthProvider::Google => GOOGLE_AUTH_URL,
        OAuthProvider::GitHub => GITHUB_AUTH_URL,
    };

    let mut params = vec![
        ("client_id", provider_cfg.client_id.as_ref().to_string()),
        (
            "redirect_uri",
            provider_cfg.redirect_uri.as_ref().to_string(),
        ),
        ("state", csrf_state.to_string()),
    ];

    match provider {
        OAuthProvider::Google => {
            params.push(("response_type", "code".to_string()));
            params.push(("scope", "openid email profile".to_string()));
            if let Some(verifier) = pkce_verifier {
                params.push(("code_challenge", pkce_challenge(verifier)));
                params.push(("code_challenge_method", "S256".to_string()));
            }
        }
        OAuthProvider::GitHub => {
            params.push(("scope", "read:user user:email".to_string()));
        }
    }

    let query = params
        .into_iter()
        .map(|(k, v)| {
            format!(
                "{}={}",
                urlencoding::encode(k),
                urlencoding::encode(v.as_str())
            )
        })
        .collect::<Vec<_>>()
        .join("&");

    format!("{authorize_endpoint}?{query}")
}

fn pkce_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

// Builds a Set-Cookie header for either oauth_state (encrypted) or
// oauth_state_binding (raw nonce). Both cookies share the same scope —
// Path=/, HttpOnly, SameSite, Max-Age, optional Secure + Domain — because
// they must arrive together at exchange time. Differing scopes would
// silently break the binding check.
fn build_oauth_cookie_header(
    state: &AppState,
    cookie_name: &str,
    cookie_value: &str,
) -> Result<HeaderValue, String> {
    let mut parts = vec![
        format!("{cookie_name}={cookie_value}"),
        "Path=/".to_string(),
        "HttpOnly".to_string(),
        format!("SameSite={}", state.oauth.cookie_same_site.header_value()),
        format!("Max-Age={OAUTH_STATE_COOKIE_MAX_AGE_SECONDS}"),
    ];

    if state.oauth.cookie_secure {
        parts.push("Secure".to_string());
    }

    if let Some(domain) = state.oauth.cookie_domain.as_deref() {
        parts.push(format!("Domain={domain}"));
    }

    HeaderValue::from_str(&parts.join("; ")).map_err(|e| format!("invalid cookie header: {e}"))
}

fn random_urlsafe(length: usize) -> String {
    rand::thread_rng()
        .sample_iter(Alphanumeric)
        .take(length)
        .map(char::from)
        .collect()
}

fn encrypt_oauth_state_cookie(
    jwt_secret: &str,
    oauth_state: &OAuthState,
) -> Result<String, String> {
    let key = derive_oauth_state_key(jwt_secret)?;
    let cipher = Aes256Gcm::new((&key).into());
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let plaintext = serde_json::to_vec(oauth_state).map_err(|e| e.to_string())?;
    let ciphertext = cipher
        .encrypt(&nonce, plaintext.as_slice())
        .map_err(|e| format!("encrypt oauth state failed: {e}"))?;

    Ok(format!(
        "{}.{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(nonce),
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(ciphertext)
    ))
}

fn decrypt_oauth_state_cookie(jwt_secret: &str, cookie_value: &str) -> Result<OAuthState, String> {
    let (nonce_encoded, ciphertext_encoded) = cookie_value
        .split_once('.')
        .ok_or_else(|| "oauth cookie format invalid".to_string())?;

    let nonce_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(nonce_encoded)
        .map_err(|_| "oauth cookie nonce invalid".to_string())?;
    if nonce_bytes.len() != 12 {
        return Err("oauth cookie nonce size invalid".to_string());
    }
    let ciphertext = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(ciphertext_encoded)
        .map_err(|_| "oauth cookie ciphertext invalid".to_string())?;

    let key = derive_oauth_state_key(jwt_secret)?;
    let cipher = Aes256Gcm::new((&key).into());
    let plaintext = cipher
        .decrypt(
            aes_gcm::Nonce::from_slice(&nonce_bytes),
            ciphertext.as_slice(),
        )
        .map_err(|_| "oauth cookie decrypt failed".to_string())?;

    serde_json::from_slice::<OAuthState>(&plaintext)
        .map_err(|_| "oauth cookie decode failed".into())
}

fn derive_oauth_state_key(jwt_secret: &str) -> Result<[u8; 32], String> {
    let mut extract_mac =
        <HmacSha256 as Mac>::new_from_slice(&[0u8; 32]).map_err(|e| e.to_string())?;
    extract_mac.update(jwt_secret.as_bytes());
    let prk = extract_mac.finalize().into_bytes();

    let mut expand_mac = <HmacSha256 as Mac>::new_from_slice(&prk).map_err(|e| e.to_string())?;
    expand_mac.update(HKDF_INFO);
    expand_mac.update(&[1u8]);
    let okm = expand_mac.finalize().into_bytes();

    let mut key = [0u8; 32];
    key.copy_from_slice(&okm);
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::GitHubEmailEntry;

    #[test]
    fn github_email_entry_deserializes_documented_schema() {
        let fixture = r#"[
            {
                "email": "octocat@github.com",
                "primary": true,
                "verified": true,
                "visibility": "public"
            },
            {
                "email": "backup@example.com",
                "primary": false,
                "verified": false,
                "visibility": null
            }
        ]"#;

        let entries: Vec<GitHubEmailEntry> =
            serde_json::from_str(fixture).expect("fixture must deserialize");
        assert_eq!(entries.len(), 2);

        let primary = entries
            .iter()
            .find(|e| e.primary)
            .expect("must have primary");
        assert_eq!(primary.email, "octocat@github.com");
        assert!(primary.verified);

        let secondary = entries
            .iter()
            .find(|e| !e.primary)
            .expect("must have non-primary");
        assert_eq!(secondary.email, "backup@example.com");
        assert!(!secondary.verified);
    }
}

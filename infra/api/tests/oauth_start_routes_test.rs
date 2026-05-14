mod common;

use api::repos::CustomerRepo;
use api::state::OAuthCookieSameSite;
use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use serde_json::Value;
use std::collections::HashMap;
use tower::ServiceExt;

fn body_text(bytes: &[u8]) -> String {
    String::from_utf8(bytes.to_vec()).expect("body should be utf-8")
}

// Both cookie names are emitted by start_oauth (oauth_state + binding).
// Each Set-Cookie value is its own header — caller must iterate
// headers().get_all(SET_COOKIE) to find the right one. Within a Set-Cookie
// value we only match the EXACT cookie-name= prefix to avoid the classic
// "oauth_state=" matching "oauth_state_binding=" by substring.
fn extract_named_cookie(set_cookie: &str, cookie_name: &str) -> Option<String> {
    let prefix = format!("{cookie_name}=");
    set_cookie.split(';').find_map(|part| {
        part.trim()
            .strip_prefix(prefix.as_str())
            .map(std::string::ToString::to_string)
    })
}

fn extract_state_query(location: &str) -> String {
    let (_, query) = location
        .split_once('?')
        .expect("oauth start redirect should include query params");
    query
        .split('&')
        .find_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            (key == "state").then(|| value.to_string())
        })
        .expect("oauth start redirect should include state query param")
}

// Returns (oauth_state_cookie, oauth_state_binding_cookie, csrf_state).
// All three are needed at exchange time: the encrypted oauth_state cookie
// proves CSRF/PKCE/binding, the binding cookie matches the bound_session_id
// embedded in the encrypted plaintext, and csrf_state is the value the
// provider echoes back via the `state` query param.
async fn oauth_start_cookie_and_state(app: &Router, provider: &str) -> (String, String, String) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/auth/oauth/{provider}/start"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::FOUND);

    let location = response
        .headers()
        .get(header::LOCATION)
        .expect("oauth start should set location")
        .to_str()
        .expect("location should be utf-8");
    let state = extract_state_query(location);

    // Walk all Set-Cookie headers — start_oauth emits TWO (oauth_state and
    // oauth_state_binding). Single .get(SET_COOKIE) would only see the first.
    let mut oauth_cookie: Option<String> = None;
    let mut binding_cookie: Option<String> = None;
    for header_value in response.headers().get_all(header::SET_COOKIE).iter() {
        let raw = header_value.to_str().expect("set-cookie should be utf-8");
        if oauth_cookie.is_none() {
            if let Some(value) = extract_named_cookie(raw, "oauth_state") {
                oauth_cookie = Some(value);
                continue;
            }
        }
        if binding_cookie.is_none() {
            if let Some(value) = extract_named_cookie(raw, "oauth_state_binding") {
                binding_cookie = Some(value);
            }
        }
    }

    (
        oauth_cookie.expect("oauth_state cookie should be present"),
        binding_cookie.expect("oauth_state_binding cookie should be present"),
        state,
    )
}

// Builds the value for a single COOKIE request header carrying both cookies.
// Saves callers from typo-prone inline format!() calls.
fn oauth_request_cookie_header(oauth_state: &str, binding: &str) -> String {
    format!("oauth_state={oauth_state}; oauth_state_binding={binding}")
}

fn oauth_exchange_request(provider: &str, code: &str, csrf_token: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(format!("/auth/oauth/{provider}/exchange"))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "code": code,
                "csrf_token": csrf_token
            })
            .to_string(),
        ))
        .unwrap()
}

struct TestGoogleProvider {
    token_endpoint: String,
    userinfo_endpoint: String,
}

struct TestGitHubProvider {
    token_endpoint: String,
    userinfo_endpoint: String,
}

async fn spawn_test_google_provider(email: &str, email_verified: bool) -> TestGoogleProvider {
    let test_email = email.to_string();
    let app = axum::Router::new()
        .route(
            "/oauth/token",
            axum::routing::post(
                |axum::Form(params): axum::Form<HashMap<String, String>>| async move {
                    let code = params.get("code").map(String::as_str).unwrap_or_default();
                    (
                        axum::http::StatusCode::OK,
                        axum::Json(serde_json::json!({"access_token": format!("token-{code}")})),
                    )
                },
            ),
        )
        .route(
            "/oauth/userinfo",
            axum::routing::get(move |_headers: axum::http::HeaderMap| {
                let response_email = test_email.clone();
                async move {
                    (
                        axum::http::StatusCode::OK,
                        axum::Json(serde_json::json!({
                            "sub": "google-provider-user-1",
                            "email": response_email,
                            "email_verified": email_verified,
                            "name": "OAuth Test User"
                        })),
                    )
                }
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind oauth test provider listener");
    let addr = listener
        .local_addr()
        .expect("resolve oauth test provider listener address");
    tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve oauth test provider");
    });

    let base = format!("http://127.0.0.1:{}", addr.port());
    TestGoogleProvider {
        token_endpoint: format!("{base}/oauth/token"),
        userinfo_endpoint: format!("{base}/oauth/userinfo"),
    }
}

async fn spawn_test_github_provider(email: Option<&str>) -> TestGitHubProvider {
    let github_email = email.map(str::to_string);
    let app = axum::Router::new()
        .route(
            "/oauth/token",
            axum::routing::post(
                |axum::Form(params): axum::Form<HashMap<String, String>>| async move {
                    let code = params.get("code").map(String::as_str).unwrap_or_default();
                    (
                        axum::http::StatusCode::OK,
                        axum::Json(serde_json::json!({"access_token": format!("token-{code}")})),
                    )
                },
            ),
        )
        .route(
            "/oauth/userinfo",
            axum::routing::get(move |_headers: axum::http::HeaderMap| {
                let response_email = github_email.clone();
                async move {
                    (
                        axum::http::StatusCode::OK,
                        axum::Json(serde_json::json!({
                            "id": 7001_u64,
                            "email": response_email,
                            "name": "OAuth GitHub User",
                            "login": "oauth-gh-user"
                        })),
                    )
                }
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind oauth test provider listener");
    let addr = listener
        .local_addr()
        .expect("resolve oauth test provider listener address");
    tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve oauth test provider");
    });

    let base = format!("http://127.0.0.1:{}", addr.port());
    TestGitHubProvider {
        token_endpoint: format!("{base}/oauth/token"),
        userinfo_endpoint: format!("{base}/oauth/userinfo"),
    }
}

#[tokio::test]
async fn oauth_start_routes_return_501_when_provider_config_missing() {
    let app = common::TestStateBuilder::new().build_app();

    for provider in ["google", "github"] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/auth/oauth/{provider}/start"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    }
}

#[tokio::test]
async fn oauth_start_routes_redirect_when_provider_configured_with_expected_params() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .with_oauth_github_provider(
            "github-client-id",
            "github-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/github/callback",
        )
        .with_oauth_cookie_domain(Some(".flapjack.foo"))
        .build_app();

    let google_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/auth/oauth/google/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(google_response.status(), StatusCode::FOUND);
    let google_location = google_response
        .headers()
        .get(header::LOCATION)
        .expect("google start should set location")
        .to_str()
        .expect("location should be utf-8");
    assert!(google_location.starts_with("https://accounts.google.com/o/oauth2/v2/auth?"));
    assert!(google_location.contains("state="));
    assert!(google_location.contains("code_challenge="));
    assert!(google_location.contains("code_challenge_method=S256"));

    let google_cookie = google_response
        .headers()
        .get(header::SET_COOKIE)
        .expect("google start should set oauth cookie")
        .to_str()
        .expect("set-cookie should be utf-8");
    assert!(google_cookie.contains("oauth_state="));
    assert!(google_cookie.contains("SameSite=None"));
    assert!(google_cookie.contains("Secure"));
    assert!(google_cookie.contains("HttpOnly"));
    assert!(google_cookie.contains("Domain=.flapjack.foo"));

    let github_response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/auth/oauth/github/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(github_response.status(), StatusCode::FOUND);
    let github_location = github_response
        .headers()
        .get(header::LOCATION)
        .expect("github start should set location")
        .to_str()
        .expect("location should be utf-8");
    assert!(github_location.starts_with("https://github.com/login/oauth/authorize?"));
    assert!(github_location.contains("state="));
    assert!(!github_location.contains("code_challenge="));
    assert!(!github_location.contains("code_challenge_method="));
}

#[tokio::test]
async fn oauth_start_routes_use_lax_non_secure_cookie_for_local_http_callbacks() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "http://127.0.0.1:5173/auth/oauth/google/callback",
        )
        .with_oauth_cookie_policy(false, OAuthCookieSameSite::Lax)
        .build_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/auth/oauth/google/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FOUND);

    let cookie = response
        .headers()
        .get(header::SET_COOKIE)
        .expect("google start should set oauth cookie")
        .to_str()
        .expect("set-cookie should be utf-8");
    assert!(cookie.contains("SameSite=Lax"));
    assert!(!cookie.contains("Secure"));
    assert!(!cookie.contains("Domain="));
}

#[tokio::test]
async fn oauth_exchange_returns_400_when_state_cookie_missing() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let response = app
        .oneshot(oauth_exchange_request("google", "dummy-code", "dummy-csrf"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse exchange error body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_state_cookie_missing".into()))
    );
}

#[tokio::test]
async fn oauth_exchange_returns_400_when_state_cookie_cannot_be_decrypted() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let mut request = oauth_exchange_request("google", "dummy-code", "dummy-csrf");
    request.headers_mut().insert(
        header::COOKIE,
        "oauth_state=not-a-valid-state".parse().unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_state_cookie_invalid"));
}

#[tokio::test]
async fn oauth_exchange_returns_400_on_csrf_mismatch() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, _) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "dummy-code", "mismatched-csrf");
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_csrf_mismatch"));
}

// Defect-2 regression suite (browser-binding contract). The encrypted
// oauth_state cookie alone is not sufficient to authorize an exchange — the
// non-encrypted oauth_state_binding cookie must also be present AND match
// the bound_session_id encoded in the encrypted plaintext. Without this,
// an attacker who harvests their own oauth_state cookie can drop it onto a
// victim and silently log the victim into the attacker's account.
// Findings doc:
// docs/runbooks/evidence/oauth-postmerge-review/20260506T084601Z/findings.md

#[tokio::test]
async fn oauth_exchange_rejects_when_binding_cookie_missing() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let (oauth_state_cookie, _binding, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    // Send ONLY the encrypted state cookie — no binding cookie. Pre-fix this
    // would proceed into fetch_provider_identity; post-fix the binding
    // contract forbids it.
    let mut request = oauth_exchange_request("google", "dummy-code", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        format!("oauth_state={oauth_state_cookie}").parse().unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_state_binding_missing"));
}

#[tokio::test]
async fn oauth_exchange_rejects_when_binding_cookie_mismatched() {
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let (oauth_state_cookie, _binding, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    // Forge a binding value that does NOT match the bound_session_id in the
    // encrypted plaintext. The 32-char shape here matches the real nonce
    // length so the failure is the binding-mismatch check, not malformed input.
    let mut request = oauth_exchange_request("google", "dummy-code", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_state_binding_mismatch"));
}

#[tokio::test]
async fn oauth_exchange_rejects_state_cookie_replayed_from_different_browser() {
    // The actual attack scenario the binding closes:
    //   1. Attacker drives /auth/oauth/google/start in browser A; harvests
    //      the encrypted oauth_state cookie + state query param.
    //   2. Victim's browser B has its own oauth_state_binding cookie from a
    //      legitimate start_oauth (or none at all if the attacker forced
    //      the encrypted cookie onto B without going through start_oauth).
    //   3. Attacker tricks victim into hitting the exchange endpoint with
    //      attacker's encrypted oauth_state and attacker's csrf_state.
    //   Pre-fix: exchange succeeds and victim is logged into attacker's
    //   account. Post-fix: binding mismatch refuses.
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
        )
        .build_app();

    let (attacker_state_cookie, _attacker_binding, attacker_csrf) =
        oauth_start_cookie_and_state(&app, "google").await;
    let (_victim_state_cookie, victim_binding, _victim_csrf) =
        oauth_start_cookie_and_state(&app, "google").await;

    // Pair attacker's oauth_state with victim's binding cookie. The
    // bound_session_id in attacker's encrypted plaintext is from session A;
    // victim's binding is from session B. They are random and independent
    // with overwhelming probability.
    let mut request = oauth_exchange_request("google", "dummy-code", &attacker_csrf);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&attacker_state_cookie, &victim_binding)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_state_binding_mismatch"));
}

#[tokio::test]
async fn oauth_exchange_returns_501_when_provider_not_configured() {
    let app = common::TestStateBuilder::new().build_app();

    let response = app
        .oneshot(oauth_exchange_request("google", "dummy-code", "dummy-csrf"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let body_text = body_text(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    );
    assert!(body_text.contains("oauth_not_implemented"));
}

#[tokio::test]
async fn oauth_exchange_happy_path_returns_token_and_customer_id() {
    let provider_server = common::spawn_test_oauth_provider().await;
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "provider-code-123", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse success body");
    assert!(body.get("token").and_then(Value::as_str).is_some());
    assert!(body.get("customer_id").and_then(Value::as_str).is_some());
}

#[tokio::test]
async fn oauth_exchange_surfaces_deterministic_provider_error_payload() {
    let provider_server = common::spawn_test_oauth_provider().await;
    let app = common::TestStateBuilder::new()
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "provider-error", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse provider failure body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_provider_exchange_failed".into()))
    );
}

#[tokio::test]
async fn oauth_exchange_rejects_deleted_customer_with_verified_google_email() {
    let provider_server = spawn_test_google_provider("deleted-oauth@integration.test", true).await;
    let customer_repo = common::mock_repo();
    let deleted_customer = customer_repo.seed("Deleted OAuth", "deleted-oauth@integration.test");
    customer_repo
        .soft_delete(deleted_customer.id)
        .await
        .expect("soft delete seeded customer");
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "provider-code-deleted", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse deleted customer response body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_customer_deleted".into()))
    );
}

#[tokio::test]
async fn oauth_exchange_maps_link_not_found_to_deleted_customer_error() {
    let provider_server = spawn_test_google_provider("link-not-found@integration.test", true).await;
    let customer_repo = common::mock_repo();
    customer_repo.fail_next_oauth_link_not_found();
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "provider-code-link-not-found", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse link-not-found response body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_customer_deleted".into()))
    );
}

#[tokio::test]
async fn oauth_exchange_does_not_auto_link_unverified_google_email() {
    let provider_server =
        spawn_test_google_provider("existing-oauth@integration.test", false).await;
    let customer_repo = common::mock_repo();
    let existing = customer_repo.seed("Existing Local User", "existing-oauth@integration.test");
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request("google", "provider-code-unverified", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse unverified oauth response body");
    let issued_customer_id = body
        .get("customer_id")
        .and_then(Value::as_str)
        .expect("oauth exchange should return customer_id");
    assert_ne!(
        issued_customer_id,
        existing.id.to_string(),
        "unverified provider email must not auto-link to existing local customer"
    );
}

#[tokio::test]
async fn oauth_exchange_does_not_auto_link_to_unverified_local_customer() {
    let provider_server = spawn_test_google_provider("existing-oauth@integration.test", true).await;
    let customer_repo = common::mock_repo();
    let existing = customer_repo.seed("Existing Local User", "existing-oauth@integration.test");
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request =
        oauth_exchange_request("google", "provider-code-local-unverified", &csrf_state);
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse local unverified response body");
    let issued_customer_id = body
        .get("customer_id")
        .and_then(Value::as_str)
        .expect("oauth exchange should return customer_id");
    assert_ne!(
        issued_customer_id,
        existing.id.to_string(),
        "verified provider email must not auto-link to unverified local customer"
    );
}

#[tokio::test]
async fn oauth_exchange_conflict_fallback_does_not_auto_link_unverified_local_customer() {
    let provider_server = spawn_test_google_provider("race-oauth@integration.test", true).await;
    let customer_repo = common::mock_repo();
    customer_repo.inject_oauth_create_conflict_with_concurrent_unverified_local(
        "race-oauth@integration.test",
    );
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request(
        "google",
        "provider-code-conflict-race-unverified",
        &csrf_state,
    );
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let race_local_customer = customer_repo
        .find_by_email("race-oauth@integration.test")
        .await
        .expect("lookup race local customer")
        .expect("race local customer should exist");
    assert!(
        race_local_customer.email_verified_at.is_none(),
        "concurrent local signup fixture should be unverified"
    );

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse conflict race response body");
    let issued_customer_id = body
        .get("customer_id")
        .and_then(Value::as_str)
        .expect("oauth exchange should return customer_id");
    assert_ne!(
        issued_customer_id,
        race_local_customer.id.to_string(),
        "verified provider email conflict fallback must not auto-link to concurrent unverified local customer"
    );
}

#[tokio::test]
async fn oauth_exchange_unverified_google_synthetic_conflict_does_not_auto_link_local_customer() {
    let provider_server =
        spawn_test_google_provider("ignored-google@integration.test", false).await;
    let customer_repo = common::mock_repo();
    customer_repo.inject_oauth_create_conflict_with_concurrent_unverified_local(
        "oauth-google-google-provider-user-1@oauth.flapjack.foo",
    );
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_oauth_google_provider_with_endpoints(
            "google-client-id",
            "google-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/google/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "google").await;
    let mut request = oauth_exchange_request(
        "google",
        "provider-code-unverified-synthetic-conflict",
        &csrf_state,
    );
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse synthetic conflict response body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_synthetic_email_conflict".into())),
        "unverified Google synthetic-email conflict must return a deterministic error"
    );
}

#[tokio::test]
async fn oauth_exchange_github_synthetic_conflict_does_not_auto_link_local_customer() {
    let provider_server =
        spawn_test_github_provider(Some("github-visible-email@integration.test")).await;
    let customer_repo = common::mock_repo();
    customer_repo.inject_oauth_create_conflict_with_concurrent_unverified_local(
        "oauth-github-7001@oauth.flapjack.foo",
    );
    let app = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_oauth_github_provider_with_endpoints(
            "github-client-id",
            "github-client-secret",
            "https://cloud.flapjack.foo/auth/oauth/github/callback",
            &provider_server.token_endpoint,
            &provider_server.userinfo_endpoint,
        )
        .build_app();

    let (oauth_state_cookie, binding_cookie, csrf_state) =
        oauth_start_cookie_and_state(&app, "github").await;
    let mut request = oauth_exchange_request(
        "github",
        "provider-code-github-synthetic-conflict",
        &csrf_state,
    );
    request.headers_mut().insert(
        header::COOKIE,
        oauth_request_cookie_header(&oauth_state_cookie, &binding_cookie)
            .parse()
            .unwrap(),
    );
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);

    let body: Value = serde_json::from_slice(
        &response
            .into_body()
            .collect()
            .await
            .expect("collect body")
            .to_bytes(),
    )
    .expect("parse github synthetic conflict response body");
    assert_eq!(
        body.get("error"),
        Some(&Value::String("oauth_synthetic_email_conflict".into())),
        "GitHub synthetic-email conflict must return a deterministic error"
    );
}

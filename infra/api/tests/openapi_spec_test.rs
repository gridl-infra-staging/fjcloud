mod common;

use api::openapi::ApiDoc;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;
use utoipa::OpenApi;

#[test]
fn openapi_spec_generates_valid_json() {
    let json_str = ApiDoc::openapi()
        .to_json()
        .expect("ApiDoc should serialize to JSON");

    let spec: serde_json::Value = serde_json::from_str(&json_str).expect("spec JSON should parse");

    // OpenAPI version field must be present
    assert!(
        spec.get("openapi").is_some(),
        "spec must contain 'openapi' version field"
    );

    // Title must match project name
    let title = spec
        .pointer("/info/title")
        .and_then(|v| v.as_str())
        .expect("spec must contain info.title");
    assert_eq!(title, "fjcloud API");

    // Bearer JWT security scheme must be registered as a component
    let scheme = spec
        .pointer("/components/securitySchemes/bearer_jwt")
        .expect("spec must contain bearer_jwt security scheme");
    assert_eq!(
        scheme.pointer("/type").and_then(|v| v.as_str()),
        Some("http")
    );
    assert_eq!(
        scheme.pointer("/scheme").and_then(|v| v.as_str()),
        Some("bearer")
    );

    // Top-level security requirement must reference bearer_jwt
    let security = spec.get("security").and_then(|v| v.as_array());
    assert!(
        security.is_some_and(|arr| arr.iter().any(|req| req.get("bearer_jwt").is_some())),
        "spec must have a top-level security requirement referencing bearer_jwt"
    );
}

#[tokio::test]
async fn docs_endpoint_returns_200() {
    let app = common::test_app();

    let req = Request::builder().uri("/docs").body(Body::empty()).unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "GET /docs/ should return 200 with Scalar UI"
    );

    // Verify response contains HTML content (Scalar renders an HTML page)
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let html = String::from_utf8_lossy(&body);
    assert!(
        html.contains("</html>") || html.contains("scalar"),
        "response should contain HTML from Scalar UI"
    );
}

// ===========================================================================
// Stage 2 — Auth operations and shared schemas
// ===========================================================================

#[test]
fn spec_contains_auth_operations() {
    let spec = common::openapi_spec_json();

    // Every auth path must be present with POST method
    let auth_paths = [
        "/auth/register",
        "/auth/login",
        "/auth/verify-email",
        "/auth/forgot-password",
        "/auth/reset-password",
        "/auth/resend-verification",
    ];
    for path in auth_paths {
        let entry = spec
            .pointer(&format!("/paths/{}", path.replace('/', "~1")))
            .unwrap_or_else(|| panic!("spec must contain path {path}"));
        assert!(
            entry.get("post").is_some(),
            "{path} must have a POST operation"
        );
    }
}

#[test]
fn spec_contains_auth_schemas() {
    let spec = common::openapi_spec_json();

    let required_schemas = [
        "RegisterRequest",
        "AuthResponse",
        "LoginRequest",
        "VerifyEmailRequest",
        "ForgotPasswordRequest",
        "ResetPasswordRequest",
        "MessageResponse",
        "ErrorResponse",
    ];
    for schema in required_schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain schema {schema}"
        );
    }
}

#[test]
fn spec_public_routes_override_bearer_security() {
    let spec = common::openapi_spec_json();

    // Public routes must explicitly clear inherited bearer auth with empty security
    let public_paths = [
        "/auth/register",
        "/auth/login",
        "/auth/verify-email",
        "/auth/forgot-password",
        "/auth/reset-password",
        "/pricing/compare",
    ];
    for path in public_paths {
        let security = spec
            .pointer(&format!("/paths/{}/post/security", path.replace('/', "~1")))
            .unwrap_or_else(|| panic!("{path} must have explicit security override"));
        let arr = security
            .as_array()
            .unwrap_or_else(|| panic!("{path} security must be an array"));
        // utoipa `security(())` produces `[{}]` — an array with one empty object.
        // Both `[]` and `[{}]` are valid OpenAPI overrides meaning "no auth required".
        let is_public = arr.is_empty()
            || (arr.len() == 1 && arr[0].as_object().is_some_and(|obj| obj.is_empty()));
        assert!(
            is_public,
            "{path} must have empty security override (public route), got: {security}"
        );
    }

    // resend-verification requires auth — should NOT have an empty override
    let resend_security = spec.pointer("/paths/~1auth~1resend-verification/post/security");
    // Either absent (inherits top-level bearer) or explicitly set to bearer
    if let Some(sec) = resend_security {
        let arr = sec.as_array().expect("security must be array");
        assert!(
            !arr.is_empty(),
            "/auth/resend-verification must NOT have empty security (requires auth)"
        );
    }
    // If absent, it inherits the top-level bearer requirement — that's correct
}

#[test]
fn spec_stage5_documents_public_security_and_response_contracts() {
    let spec = common::openapi_spec_json();

    assert!(
        spec.pointer(
            "/paths/~1pricing~1compare/post/responses/400/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str())
        .is_some_and(|value| value.ends_with("/ErrorResponse")),
        "POST /pricing/compare must document the shared ErrorResponse schema for 400s"
    );

    assert!(
        spec.pointer("/paths/~1indexes~1{name}~1keys/post/responses/201")
            .is_some(),
        "POST /indexes/{{name}}/keys must be documented as 201 Created"
    );
    assert!(
        spec.pointer("/paths/~1indexes~1{name}~1keys/post/responses/200")
            .is_none(),
        "POST /indexes/{{name}}/keys must not be documented as 200"
    );

    let experiment_400_ops = [
        "/paths/~1indexes~1{name}~1experiments~1{id}/get/responses/400",
        "/paths/~1indexes~1{name}~1experiments~1{id}/delete/responses/400",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1start/post/responses/400",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1stop/post/responses/400",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1results/get/responses/400",
        "/paths/~1indexes~1{name}~1analytics~1status/get/responses/400",
    ];
    for response_ptr in experiment_400_ops {
        assert!(
            spec.pointer(response_ptr).is_some(),
            "{response_ptr} must be documented because the handler performs local request validation"
        );
    }

    let service_unavailable_ops = [
        "/paths/~1migration~1algolia~1list-indexes/post/responses/503",
        "/paths/~1migration~1algolia~1migrate/post/responses/503",
    ];
    for response_ptr in service_unavailable_ops {
        assert!(
            spec.pointer(response_ptr).is_some(),
            "{response_ptr} must be documented for the local ServiceUnavailable path"
        );
    }

    let cold_or_unavailable_ops = [
        "/paths/~1indexes~1{name}~1analytics~1searches/get",
        "/paths/~1indexes~1{name}~1analytics~1searches~1count/get",
        "/paths/~1indexes~1{name}~1analytics~1searches~1noResults/get",
        "/paths/~1indexes~1{name}~1analytics~1searches~1noResultRate/get",
        "/paths/~1indexes~1{name}~1analytics~1status/get",
        "/paths/~1indexes~1{name}~1experiments/get",
        "/paths/~1indexes~1{name}~1experiments/post",
        "/paths/~1indexes~1{name}~1experiments~1{id}/get",
        "/paths/~1indexes~1{name}~1experiments~1{id}/put",
        "/paths/~1indexes~1{name}~1experiments~1{id}/delete",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1start/post",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1stop/post",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1conclude/post",
        "/paths/~1indexes~1{name}~1experiments~1{id}~1results/get",
        "/paths/~1indexes~1{name}~1events~1debug/get",
        "/paths/~1indexes~1{name}~1keys/post",
    ];
    for operation_ptr in cold_or_unavailable_ops {
        assert!(
            spec.pointer(&format!("{operation_ptr}/responses/410"))
                .is_some(),
            "{operation_ptr} must document 410 for cold-tier indexes"
        );
        assert!(
            spec.pointer(&format!("{operation_ptr}/responses/503"))
                .is_some(),
            "{operation_ptr} must document 503 for restoring or not-ready indexes"
        );
    }
}

// ===========================================================================
// Stage 2 — Onboarding, account, and API key operations
// ===========================================================================

#[test]
fn spec_contains_lifecycle_operations() {
    let spec = common::openapi_spec_json();

    // Onboarding routes
    assert!(
        spec.pointer("/paths/~1onboarding~1status/get").is_some(),
        "spec must contain GET /onboarding/status"
    );
    assert!(
        spec.pointer("/paths/~1onboarding~1credentials/post")
            .is_some(),
        "spec must contain POST /onboarding/credentials"
    );

    // Account routes — GET/PATCH/DELETE on /account plus export and change-password
    assert!(
        spec.pointer("/paths/~1account/get").is_some(),
        "spec must contain GET /account"
    );
    assert!(
        spec.pointer("/paths/~1account~1export/get").is_some(),
        "spec must contain GET /account/export"
    );
    assert!(
        spec.pointer("/paths/~1account/patch").is_some(),
        "spec must contain PATCH /account"
    );
    assert!(
        spec.pointer("/paths/~1account/delete").is_some(),
        "spec must contain DELETE /account"
    );
    assert!(
        spec.pointer("/paths/~1account~1change-password/post")
            .is_some(),
        "spec must contain POST /account/change-password"
    );

    // API key routes — mounted at root /api-keys
    assert!(
        spec.pointer("/paths/~1api-keys/get").is_some(),
        "spec must contain GET /api-keys"
    );
    assert!(
        spec.pointer("/paths/~1api-keys/post").is_some(),
        "spec must contain POST /api-keys"
    );
    assert!(
        spec.pointer("/paths/~1api-keys~1{key_id}/delete").is_some(),
        "spec must contain DELETE /api-keys/{{key_id}}"
    );
}

#[test]
fn spec_contains_lifecycle_schemas() {
    let spec = common::openapi_spec_json();

    let required_schemas = [
        "OnboardingStatusResponse",
        "FreeTierLimitsResponse",
        "CredentialsResponse",
        "CustomerProfileResponse",
        "AccountExportResponse",
        "UpdateProfileRequest",
        "ChangePasswordRequest",
        "DeleteAccountRequest",
        "CreateApiKeyRequest",
        "CreateApiKeyResponse",
        "ApiKeyListItem",
    ];
    for schema in required_schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain schema {schema}"
        );
    }
}

#[test]
fn spec_lifecycle_routes_do_not_override_bearer_with_public_security() {
    let spec = common::openapi_spec_json();

    let lifecycle_ops = [
        "/paths/~1onboarding~1status/get/security",
        "/paths/~1onboarding~1credentials/post/security",
        "/paths/~1account/get/security",
        "/paths/~1account~1export/get/security",
        "/paths/~1account/patch/security",
        "/paths/~1account/delete/security",
        "/paths/~1account~1change-password/post/security",
        "/paths/~1api-keys/get/security",
        "/paths/~1api-keys/post/security",
        "/paths/~1api-keys~1{key_id}/delete/security",
    ];

    for op_security_ptr in lifecycle_ops {
        if let Some(security) = spec.pointer(op_security_ptr) {
            let arr = security
                .as_array()
                .unwrap_or_else(|| panic!("{op_security_ptr} must be an array when present"));
            let is_public_override = arr.is_empty()
                || (arr.len() == 1 && arr[0].as_object().is_some_and(|obj| obj.is_empty()));
            assert!(
                !is_public_override,
                "{op_security_ptr} must not clear bearer security for authenticated lifecycle routes"
            );
        }
    }
}

#[test]
fn spec_delete_api_key_declares_key_id_path_parameter() {
    let spec = common::openapi_spec_json();

    let parameters = spec
        .pointer("/paths/~1api-keys~1{key_id}/delete/parameters")
        .expect("DELETE /api-keys/{key_id} must define parameters")
        .as_array()
        .expect("delete parameters must be an array");

    let key_id = parameters
        .iter()
        .find(|param| param.get("name").and_then(|value| value.as_str()) == Some("key_id"))
        .expect("DELETE /api-keys/{key_id} must define key_id path parameter");

    assert_eq!(
        key_id.pointer("/in").and_then(|value| value.as_str()),
        Some("path")
    );
    assert_eq!(
        key_id
            .pointer("/required")
            .and_then(|value| value.as_bool()),
        Some(true)
    );
    assert_eq!(
        key_id
            .pointer("/schema/type")
            .and_then(|value| value.as_str()),
        Some("string")
    );
    assert_eq!(
        key_id
            .pointer("/schema/format")
            .and_then(|value| value.as_str()),
        Some("uuid")
    );
}

#[test]
fn spec_authenticated_stage2_routes_document_401_error_response() {
    let spec = common::openapi_spec_json();

    let authenticated_ops = [
        "/paths/~1auth~1resend-verification/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1onboarding~1status/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1onboarding~1credentials/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1account/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1account~1export/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1account/patch/responses/401/content/application~1json/schema/$ref",
        "/paths/~1account/delete/responses/401/content/application~1json/schema/$ref",
        "/paths/~1account~1change-password/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1api-keys/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1api-keys/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1api-keys~1{key_id}/delete/responses/401/content/application~1json/schema/$ref",
    ];

    for response_ref in authenticated_ops {
        assert_eq!(
            spec.pointer(response_ref).and_then(|value| value.as_str()),
            Some("#/components/schemas/ErrorResponse"),
            "{response_ref} must reference ErrorResponse for auth failures"
        );
    }
}

#[test]
fn spec_resend_verification_documents_stage3_status_matrix() {
    let spec = common::openapi_spec_json();
    let op_base = "/paths/~1auth~1resend-verification/post/responses";

    for status in ["200", "400", "401", "403", "429", "503"] {
        assert!(
            spec.pointer(&format!("{op_base}/{status}")).is_some(),
            "/auth/resend-verification must document HTTP {status}"
        );
    }

    assert!(
        spec.pointer(&format!("{op_base}/404")).is_none(),
        "/auth/resend-verification must not document unreachable 404 under AuthenticatedTenant"
    );

    assert_eq!(
        spec.pointer(
            "/paths/~1auth~1resend-verification/post/responses/429/headers/Retry-After/description"
        )
        .and_then(|value| value.as_str()),
        Some("Seconds remaining before another resend attempt is allowed"),
        "/auth/resend-verification 429 must document Retry-After header description"
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1auth~1resend-verification/post/responses/429/headers/Retry-After/schema/type"
        )
        .and_then(|value| value.as_str()),
        Some("integer"),
        "/auth/resend-verification 429 Retry-After schema must be integer seconds"
    );
    assert_eq!(
        spec.pointer("/paths/~1auth~1resend-verification/post/responses/403/content/application~1json/schema/$ref")
            .and_then(|value| value.as_str()),
        Some("#/components/schemas/ErrorResponse"),
        "/auth/resend-verification 403 must reuse the shared ErrorResponse schema"
    );
}

// Stage 3–5 tests are in openapi_spec_stages3_5_test.rs

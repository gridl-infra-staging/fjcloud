use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use std::path::PathBuf;
use tower::ServiceExt;
use utoipa::OpenApi;

use api::models::AlgoliaImportErrorCode;
use api::openapi::ApiDoc;

const REGENERATE_OPENAPI_ARTIFACT_COMMAND: &str =
    "(cd infra && UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api openapi_spec_matches_committed_artifact -- --nocapture)";

fn openapi_artifact_path() -> PathBuf {
    let api_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    api_dir
        .parent()
        .and_then(|infra_dir| infra_dir.parent())
        .expect("infra/api must have a repo root parent")
        .join("docs/reference/openapi.json")
}

fn repo_root_path() -> PathBuf {
    let api_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    api_dir
        .parent()
        .and_then(|infra_dir| infra_dir.parent())
        .expect("infra/api must have a repo root parent")
        .to_path_buf()
}

fn required_fields(spec: &serde_json::Value, schema_name: &str) -> Vec<String> {
    let mut fields = spec
        .pointer(&format!("/components/schemas/{schema_name}/required"))
        .and_then(|value| value.as_array())
        .unwrap_or_else(|| panic!("{schema_name} must document required fields"))
        .iter()
        .map(|value| {
            value
                .as_str()
                .unwrap_or_else(|| panic!("{schema_name} required field entries must be strings"))
                .to_string()
        })
        .collect::<Vec<_>>();
    fields.sort();
    fields
}

fn response_schema_ref<'a>(
    spec: &'a serde_json::Value,
    operation_ptr: &str,
    status: &str,
) -> Option<&'a str> {
    spec.pointer(&format!(
        "{operation_ptr}/responses/{status}/content/application~1json/schema/$ref"
    ))
    .and_then(|value| value.as_str())
}

#[test]
fn openapi_spec_matches_committed_artifact() {
    let artifact_path = openapi_artifact_path();
    let generated_spec = ApiDoc::openapi()
        .to_pretty_json()
        .expect("ApiDoc should serialize to pretty JSON");

    if std::env::var_os("UPDATE_OPENAPI_ARTIFACT").is_some() {
        let artifact_dir = artifact_path
            .parent()
            .expect("OpenAPI artifact path must have a parent directory");
        std::fs::create_dir_all(artifact_dir).expect("create OpenAPI artifact directory");
        std::fs::write(&artifact_path, generated_spec).expect("write OpenAPI artifact");
        return;
    }

    let committed_spec = std::fs::read_to_string(&artifact_path).unwrap_or_else(|error| {
        panic!(
            "read committed OpenAPI artifact at {}: {error}. Regenerate with: {REGENERATE_OPENAPI_ARTIFACT_COMMAND}",
            artifact_path.display()
        )
    });

    assert_eq!(
        committed_spec, generated_spec,
        "committed OpenAPI artifact is stale. Regenerate with: {REGENERATE_OPENAPI_ARTIFACT_COMMAND}"
    );
}

#[test]
fn algolia_cloud_discovery_openapi_surface_is_narrow_and_client_bound() {
    let spec = crate::common::openapi_spec_json();

    assert!(
        spec.pointer("/paths/~1migration~1algolia~1list-indexes/post")
            .is_some(),
        "POST /migration/algolia/list-indexes must be in OpenAPI"
    );
    assert!(
        spec.pointer("/paths/~1migration~1algolia~1migrate/post")
            .is_none(),
        "removed POST /migration/algolia/migrate must not be in OpenAPI"
    );

    assert!(
        spec.pointer("/paths/~1migration~1algolia~1availability/get")
            .is_some(),
        "authenticated GET /migration/algolia/availability must remain in OpenAPI"
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1algolia~1availability/get/responses/200/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/AlgoliaMigrationAvailabilityResponse"),
        "availability 200 response must use the dedicated schema"
    );
    assert_eq!(
        required_fields(&spec, "AlgoliaMigrationAvailabilityResponse"),
        vec![
            "available".to_string(),
            "capabilities".to_string(),
            "message".to_string(),
            "reason".to_string()
        ],
        "availability response must require every serialized field"
    );
    assert_eq!(
        spec.pointer(
            "/components/schemas/AlgoliaMigrationAvailabilityResponse/properties/capabilities/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/AlgoliaMigrationCapabilities"),
        "availability capabilities must use the dedicated nested schema"
    );
    assert_eq!(
        required_fields(&spec, "AlgoliaMigrationCapabilities"),
        vec![
            "cancel".to_string(),
            "replace".to_string(),
            "resume".to_string()
        ],
        "capabilities must require the complete operation set"
    );
    for operation in ["cancel", "resume", "replace"] {
        assert_eq!(
            spec.pointer(&format!(
                "/components/schemas/AlgoliaMigrationCapabilities/properties/{operation}/type"
            ))
            .and_then(|value| value.as_str()),
            Some("boolean"),
            "{operation} capability must be documented as a boolean"
        );
    }
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1algolia~1list-indexes/post/responses/200/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/AlgoliaSourceListResponse")
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1algolia~1list-indexes/post/requestBody/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/ListAlgoliaIndexesRequest")
    );
    let list_indexes_operation = "/paths/~1migration~1algolia~1list-indexes/post";
    for status in ["400", "403", "503"] {
        assert_eq!(
            response_schema_ref(&spec, list_indexes_operation, status),
            Some("#/components/schemas/MigrationErrorResponse"),
            "list-indexes {status} handler response must use coded migration errors"
        );
    }
    assert_eq!(
        response_schema_ref(&spec, list_indexes_operation, "401"),
        Some("#/components/schemas/ErrorResponse"),
        "middleware-owned auth errors remain legacy uncoded responses"
    );
    assert_eq!(
        required_fields(&spec, "ErrorResponse"),
        vec!["error".to_string()],
        "legacy ErrorResponse must not falsely require migration code"
    );
    assert_eq!(
        required_fields(&spec, "MigrationErrorResponse"),
        vec!["code".to_string(), "error".to_string()],
        "migration errors must require typed stable code and human error"
    );
    assert_eq!(
        spec.pointer("/components/schemas/MigrationErrorResponse/properties/code/$ref")
            .and_then(|value| value.as_str()),
        Some("#/components/schemas/AlgoliaImportErrorCode")
    );
    let code_values = spec
        .pointer("/components/schemas/AlgoliaImportErrorCode/enum")
        .and_then(|value| value.as_array())
        .expect("canonical Algolia import error code enum must be documented");
    let expected_codes = [
        AlgoliaImportErrorCode::InvalidCredentials,
        AlgoliaImportErrorCode::MissingSourcePermission,
        AlgoliaImportErrorCode::SourceNotFound,
        AlgoliaImportErrorCode::SourceCatalogTooLarge,
        AlgoliaImportErrorCode::DestinationConflict,
        AlgoliaImportErrorCode::QuotaExceeded,
        AlgoliaImportErrorCode::SourceTooLarge,
        AlgoliaImportErrorCode::InsufficientEngineStorage,
        AlgoliaImportErrorCode::DestinationChanged,
        AlgoliaImportErrorCode::SourceChanged,
        AlgoliaImportErrorCode::IncompatibleData,
        AlgoliaImportErrorCode::EngineUpgradeRequired,
        AlgoliaImportErrorCode::MigrationHaNotSupported,
        AlgoliaImportErrorCode::MigrationProviderUnsupported,
        AlgoliaImportErrorCode::BackendUnavailable,
        AlgoliaImportErrorCode::Interrupted,
        AlgoliaImportErrorCode::CancelNotPermitted,
        AlgoliaImportErrorCode::NotResumable,
        AlgoliaImportErrorCode::Internal,
    ]
    .into_iter()
    .map(|code| serde_json::json!(code.as_str()))
    .collect::<Vec<_>>();
    assert_eq!(code_values, &expected_codes);
    for absent_path in [
        "/paths/~1migration~1algolia~1destination-eligibility/post",
        "/paths/~1migration~1algolia~1jobs/post",
        "/paths/~1migration~1algolia~1jobs/get",
        "/paths/~1migration~1algolia~1jobs~1{id}/get",
        "/paths/~1migration~1algolia~1jobs~1{id}~1cancel/post",
        "/paths/~1migration~1algolia~1jobs~1{id}~1resume/post",
    ] {
        assert!(
            spec.pointer(absent_path).is_none(),
            "{absent_path} must stay absent until F11 activation"
        );
    }
    let required = spec
        .pointer("/components/schemas/ListAlgoliaIndexesRequest/required")
        .and_then(|value| value.as_array())
        .expect("list-indexes request must document required fields");
    assert!(required.contains(&serde_json::json!("appId")));
    assert!(required.contains(&serde_json::json!("apiKey")));
    assert!(
        !required.contains(&serde_json::json!("hitsPerPage")),
        "list-indexes hitsPerPage must stay optional"
    );
    assert_eq!(
        spec.pointer("/components/schemas/ListAlgoliaIndexesRequest/properties/hitsPerPage/type")
            .and_then(|value| value.as_array()),
        Some(&vec![
            serde_json::json!("integer"),
            serde_json::json!("null")
        ]),
        "list-indexes hitsPerPage must remain an optional nullable integer override"
    );
    let mut expected_metadata_required = [
        "name",
        "entries",
        "dataSize",
        "fileSize",
        "updatedAt",
        "lastBuildTimeS",
        "pendingTask",
        "primary",
        "replicas",
    ]
    .into_iter()
    .map(str::to_string)
    .collect::<Vec<_>>();
    expected_metadata_required.sort();
    assert_eq!(
        required_fields(&spec, "AlgoliaIndexMetadata"),
        expected_metadata_required,
        "Algolia picker metadata is always serialized, so OpenAPI must not mark fields optional"
    );
    assert_eq!(
        required_fields(&spec, "AlgoliaSourceListResponse"),
        vec!["items".to_string(), "nextCursor".to_string()]
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1algolia~1availability/get/responses/401/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/ErrorResponse"),
        "availability route must document the auth-required response"
    );

    if let Some(security) = spec.pointer("/paths/~1migration~1algolia~1availability/get/security") {
        let security = security
            .as_array()
            .expect("availability operation security must be an array when present");
        let clears_bearer = security.is_empty()
            || (security.len() == 1
                && security[0]
                    .as_object()
                    .is_some_and(|entry| entry.is_empty()));
        assert!(
            !clears_bearer,
            "availability route must not clear inherited bearer auth"
        );
    }

    assert_eq!(
        spec.pointer(
            "/components/schemas/AlgoliaMigrationAvailabilityResponse/properties/reason/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/AlgoliaMigrationAvailabilityReason"),
        "availability reason must be a typed fail-closed enum"
    );
    let reason_values = spec
        .pointer("/components/schemas/AlgoliaMigrationAvailabilityReason/enum")
        .and_then(|value| value.as_array())
        .expect("availability reason enum must be documented");
    assert_eq!(
        reason_values,
        &[serde_json::json!("temporarily_unavailable")],
        "availability reason enum must only allow the fail-closed reason"
    );

    let repo_root = repo_root_path();
    let client_source = std::fs::read_to_string(repo_root.join("web/src/lib/api/client.ts"))
        .expect("read generated API client");
    assert!(
        client_source.contains(
            "getAlgoliaMigrationAvailability(): Promise<AlgoliaMigrationAvailabilityResponse>"
        ),
        "generated client must expose the availability binding"
    );
    assert!(
        client_source.contains("this.api('GET', '/migration/algolia/availability')"),
        "generated client must call the availability GET route"
    );
    assert!(
        client_source.contains("listAlgoliaSourceIndexes(")
            && client_source.contains("request: ListAlgoliaIndexesRequest")
            && client_source.contains("): Promise<AlgoliaSourceListResponse>"),
        "client must expose Algolia source discovery"
    );
    assert!(
        client_source.contains(
            "return this.api('POST', '/migration/algolia/list-indexes', algoliaSourceListRequest(request));"
        ),
        "client must call the source discovery route with the canonical sanitized request body"
    );
    for (method, route) in [
        (
            "checkAlgoliaDestinationEligibility(",
            "/migration/algolia/destination-eligibility",
        ),
        ("createAlgoliaImportJob(", "/migration/algolia/jobs"),
        ("getAlgoliaImportJob(", "/migration/algolia/jobs/"),
        ("listAlgoliaImportJobs(", "/migration/algolia/jobs"),
        ("cancelAlgoliaImportJob(", "/migration/algolia/jobs/"),
        ("resumeAlgoliaImportJob(", "/migration/algolia/jobs/"),
    ] {
        assert!(
            client_source.contains(method),
            "client method {method} must be exposed for mounted route {route}"
        );
        assert!(
            client_source.contains(route),
            "client route binding {route} must be exposed after route activation"
        );
    }

    let types_source =
        std::fs::read_to_string(repo_root.join("web/src/lib/api/types_algolia_migration.ts"))
            .expect("read generated migration API types");
    assert!(
        types_source.contains("reason: 'temporarily_unavailable';"),
        "generated migration type must expose the fail-closed reason literal"
    );
    assert!(
        types_source.contains("hitsPerPage?: number | null;"),
        "generated migration request type must expose the optional hitsPerPage override"
    );
    assert!(
        types_source.contains("resumeProvenance: string | null;"),
        "generated migration job type must expose producer-authored resume provenance"
    );
    assert!(
        !types_source.contains("resumeCheckpoint:"),
        "public migration job types must not expose the internal engine resume checkpoint"
    );
    assert!(
        !types_source.contains("| 'available'"),
        "generated migration type must not advertise an available reason"
    );
    for field in [
        "updatedAt: string;",
        "lastBuildTimeS: number;",
        "primary: string | null;",
        "replicas: string[];",
    ] {
        assert!(
            types_source.contains(field),
            "missing picker metadata field {field}"
        );
    }
}

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
    assert_eq!(title, "Flapjack Cloud API");

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
    let app = crate::common::test_app();

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
    let spec = crate::common::openapi_spec_json();

    // Every auth path must be present with POST method
    let auth_paths = [
        "/auth/register",
        "/auth/login",
        "/auth/verify-email",
        "/auth/forgot-password",
        "/auth/reset-password",
        "/auth/resend-password-reset",
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
    let spec = crate::common::openapi_spec_json();

    let required_schemas = [
        "RegisterRequest",
        "AuthResponse",
        "LoginRequest",
        "VerifyEmailRequest",
        "ForgotPasswordRequest",
        "ResendPasswordResetRequest",
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
    let spec = crate::common::openapi_spec_json();

    // Public routes must explicitly clear inherited bearer auth with empty security
    let public_paths = [
        "/auth/register",
        "/auth/login",
        "/auth/verify-email",
        "/auth/forgot-password",
        "/auth/resend-password-reset",
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
    let spec = crate::common::openapi_spec_json();

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

    assert!(
        spec.pointer("/paths/~1migration~1algolia~1availability/get")
            .is_some(),
        "GET /migration/algolia/availability must be documented"
    );
    assert!(
        spec.pointer("/paths/~1migration~1algolia~1list-indexes/post")
            .is_some(),
        "Customer source discovery route must remain in OpenAPI"
    );
    assert!(
        spec.pointer("/paths/~1migration~1algolia~1migrate")
            .is_none(),
        "Removed customer migration mutate route must not remain in OpenAPI"
    );

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

#[test]
fn spec_documents_all_runtime_analytics_operations() {
    let spec = crate::common::openapi_spec_json();
    let required_operation_ptrs = [
        "/paths/~1indexes~1{name}~1analytics~1devices/get",
        "/paths/~1indexes~1{name}~1analytics~1countries/get",
        "/paths/~1indexes~1{name}~1analytics~1filters/get",
        "/paths/~1indexes~1{name}~1analytics~1conversions~1conversionRate/get",
    ];
    let missing_operation_ptrs = required_operation_ptrs
        .into_iter()
        .filter(|operation_ptr| spec.pointer(operation_ptr).is_none())
        .collect::<Vec<_>>();

    assert!(
        missing_operation_ptrs.is_empty(),
        "OpenAPI spec is missing runtime analytics operations: {missing_operation_ptrs:?}"
    );
}

// ===========================================================================
// Stage 2 — Onboarding, account, and API key operations
// ===========================================================================

#[test]
fn spec_contains_lifecycle_operations() {
    let spec = crate::common::openapi_spec_json();

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
    let spec = crate::common::openapi_spec_json();

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
fn spec_free_tier_limits_schema_uses_mb_storage_key() {
    let spec = crate::common::openapi_spec_json();

    assert!(
        spec.pointer("/components/schemas/FreeTierLimitsResponse/properties/max_storage_mb/type")
            .and_then(|value| value.as_str())
            .is_some_and(|value| value == "integer"),
        "FreeTierLimitsResponse must expose max_storage_mb as an integer field"
    );
    assert!(
        spec.pointer("/components/schemas/FreeTierLimitsResponse/properties/max_storage_gb")
            .is_none(),
        "FreeTierLimitsResponse must not expose legacy max_storage_gb"
    );
}

#[test]
fn spec_lifecycle_routes_do_not_override_bearer_with_public_security() {
    let spec = crate::common::openapi_spec_json();

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
    let spec = crate::common::openapi_spec_json();

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
    let spec = crate::common::openapi_spec_json();

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
    let spec = crate::common::openapi_spec_json();
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

#[test]
fn spec_resend_password_reset_documents_stage1_status_matrix() {
    let spec = crate::common::openapi_spec_json();
    let op_base = "/paths/~1auth~1resend-password-reset/post/responses";

    assert!(
        spec.pointer(&format!("{op_base}/200")).is_some(),
        "/auth/resend-password-reset must document HTTP 200"
    );
    assert!(
        spec.pointer(&format!("{op_base}/429")).is_none(),
        "/auth/resend-password-reset must not document account-level cooldown 429"
    );
    assert!(
        spec.pointer(&format!("{op_base}/503")).is_none(),
        "/auth/resend-password-reset must not document account-level email-delivery 503"
    );
}

// Stage 3–5 tests are in openapi_spec_stages3_5_test.rs

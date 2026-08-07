use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::oneshot;
use utoipa::OpenApi;

use api::models::AlgoliaImportErrorCode;
use api::openapi::ApiDoc;

const REGENERATE_OPENAPI_ARTIFACT_COMMAND: &str =
    "(cd infra && UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api openapi_spec_matches_committed_artifact -- --nocapture)";
const OPENAPI_OPERATION_METHODS: [&str; 8] = [
    "get", "put", "post", "delete", "options", "head", "patch", "trace",
];

#[path = "openapi_spec_test/neutral_source_discovery_contract.rs"]
mod neutral_source_discovery_contract;

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

fn response_schema_refs(
    spec: &serde_json::Value,
    operation_ptr: &str,
    status: &str,
) -> BTreeSet<String> {
    let schema = spec
        .pointer(&format!(
            "{operation_ptr}/responses/{status}/content/application~1json/schema"
        ))
        .unwrap_or_else(|| panic!("{operation_ptr} {status} response must document a JSON schema"));
    let mut refs = BTreeSet::new();
    let mut visited = BTreeSet::new();
    collect_schema_refs(spec, schema, &mut refs, &mut visited);
    refs
}

/// Create-request schema refs the published `SourceImportProvider` union implies,
/// one per accepted provider. Deriving the expectation from the spec's own provider
/// enum — rather than a hand-kept list — makes a new provider variant fail the create
/// contract test until the documented create union publishes its request shape.
fn published_create_request_schema_refs(spec: &serde_json::Value) -> BTreeSet<String> {
    let providers = spec
        .pointer("/components/schemas/SourceImportProvider/enum")
        .and_then(|value| value.as_array())
        .expect("SourceImportProvider must publish its closed provider enum");
    assert!(
        !providers.is_empty(),
        "the published provider enum must not be empty, or this guard would assert nothing"
    );

    providers
        .iter()
        .map(|provider| {
            let provider = provider
                .as_str()
                .expect("published provider values must be strings");
            let pascal_case: String = provider
                .split('_')
                .map(|segment| {
                    let mut characters = segment.chars();
                    match characters.next() {
                        Some(first) => first.to_uppercase().chain(characters).collect::<String>(),
                        None => String::new(),
                    }
                })
                .collect();
            format!("#/components/schemas/Create{pascal_case}ImportJobRequest")
        })
        .collect()
}

fn collect_schema_refs(
    spec: &serde_json::Value,
    schema: &serde_json::Value,
    refs: &mut BTreeSet<String>,
    visited: &mut BTreeSet<String>,
) {
    if let Some(reference) = schema.get("$ref").and_then(|value| value.as_str()) {
        if !visited.insert(reference.to_string()) {
            return;
        }
        if let Some(schema_name) = reference.strip_prefix("#/components/schemas/") {
            if let Some(component) = spec.pointer(&format!("/components/schemas/{schema_name}")) {
                if ["oneOf", "anyOf", "allOf"]
                    .iter()
                    .any(|key| component.get(key).is_some())
                {
                    collect_schema_refs(spec, component, refs, visited);
                    return;
                }
            }
        }
        refs.insert(reference.to_string());
    }
    for key in ["oneOf", "anyOf", "allOf"] {
        if let Some(entries) = schema.get(key).and_then(|value| value.as_array()) {
            for entry in entries {
                collect_schema_refs(spec, entry, refs, visited);
            }
        }
    }
}

fn schema_refs_at_pointer(spec: &serde_json::Value, pointer: &str) -> BTreeSet<String> {
    let schema = spec
        .pointer(pointer)
        .unwrap_or_else(|| panic!("OpenAPI schema must exist at {pointer}"));
    let mut refs = BTreeSet::new();
    let mut visited = BTreeSet::new();
    collect_schema_refs(spec, schema, &mut refs, &mut visited);
    refs
}

fn assert_optional_non_nullable_string_property(
    spec: &serde_json::Value,
    schema_name: &str,
    property_name: &str,
) {
    assert!(
        !required_fields(spec, schema_name).contains(&property_name.to_string()),
        "{schema_name}.{property_name} must be optional by omission"
    );
    assert_eq!(
        spec.pointer(&format!(
            "/components/schemas/{schema_name}/properties/{property_name}/type"
        )),
        Some(&serde_json::json!("string")),
        "{schema_name}.{property_name} must be a non-null string when present"
    );
}

fn assert_optional_non_nullable_ref_property(
    spec: &serde_json::Value,
    schema_name: &str,
    property_name: &str,
    expected_ref: &str,
) {
    assert!(
        !required_fields(spec, schema_name).contains(&property_name.to_string()),
        "{schema_name}.{property_name} must be optional by omission"
    );
    assert_eq!(
        spec.pointer(&format!(
            "/components/schemas/{schema_name}/properties/{property_name}/$ref"
        ))
        .and_then(|value| value.as_str()),
        Some(expected_ref),
        "{schema_name}.{property_name} must be a non-null component reference when present"
    );
}

fn scalar_api_reference_json(html: &str) -> serde_json::Value {
    let id_index = html
        .find(r#"id="api-reference""#)
        .expect("Scalar HTML must include api-reference JSON script");
    let script_body_start = html[id_index..]
        .find('>')
        .map(|offset| id_index + offset + 1)
        .expect("api-reference script must have an opening tag");
    let script_body_end = html[script_body_start..]
        .find("</script>")
        .map(|offset| script_body_start + offset)
        .expect("api-reference script must have a closing tag");

    serde_json::from_str(html[script_body_start..script_body_end].trim())
        .expect("api-reference script body must be valid OpenAPI JSON")
}

fn migration_http_operations(spec: &serde_json::Value) -> BTreeSet<(String, String)> {
    let paths = spec
        .get("paths")
        .and_then(|value| value.as_object())
        .expect("OpenAPI spec must contain object-valued paths");
    let mut operations = BTreeSet::new();
    for (path, path_item) in paths {
        if !path.starts_with("/migration/{source_provider}/") {
            continue;
        }
        let methods = path_item
            .as_object()
            .unwrap_or_else(|| panic!("OpenAPI path item for {path} must be an object"));
        for method in OPENAPI_OPERATION_METHODS {
            if methods.contains_key(method) {
                operations.insert((method.to_ascii_uppercase(), path.clone()));
            }
        }
    }
    operations
}

fn assert_no_legacy_algolia_path_items(spec: &serde_json::Value) {
    let paths = spec
        .get("paths")
        .and_then(|value| value.as_object())
        .expect("OpenAPI spec must contain object-valued paths");
    let legacy_paths = paths
        .keys()
        .filter(|path| {
            path.as_str() == "/migration/algolia" || path.starts_with("/migration/algolia/")
        })
        .collect::<Vec<_>>();

    assert!(
        legacy_paths.is_empty(),
        "legacy Algolia aliases must not duplicate the canonical neutral OpenAPI path items: {legacy_paths:?}"
    );
}

#[test]
fn migration_http_operations_counts_all_openapi_operation_methods() {
    let spec = serde_json::json!({
        "paths": {
            "/migration/{source_provider}/jobs": {
                "get": {},
                "put": {},
                "post": {},
                "delete": {},
                "options": {},
                "head": {},
                "patch": {},
                "trace": {},
                "parameters": []
            },
            "/migration/algolia/jobs": {
                "trace": {}
            }
        }
    });

    let operations = migration_http_operations(&spec);

    assert_eq!(
        operations,
        BTreeSet::from([
            (
                "DELETE".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "GET".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "HEAD".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "OPTIONS".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "PATCH".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "POST".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "PUT".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
            (
                "TRACE".to_string(),
                "/migration/{source_provider}/jobs".to_string()
            ),
        ])
    );
}

#[test]
fn legacy_algolia_path_item_guard_rejects_descendant_aliases() {
    let spec = serde_json::json!({
        "paths": {
            "/migration/{source_provider}/jobs": {"get": {}},
            "/migration/algolia/jobs": {"get": {}}
        }
    });

    let rejection = std::panic::catch_unwind(|| assert_no_legacy_algolia_path_items(&spec));

    assert!(
        rejection.is_err(),
        "legacy /migration/algolia/ descendant path items must be rejected"
    );
}

#[test]
fn public_infrastructure_openapi_surface_is_public_and_schema_bound() {
    let spec = crate::common::openapi_spec_json();
    let operation = spec
        .pointer("/paths/~1public~1infrastructure/get")
        .expect("GET /public/infrastructure must be registered in OpenAPI");

    assert_eq!(
        operation
            .pointer("/responses/200/content/application~1json/schema/$ref")
            .and_then(|value| value.as_str()),
        Some("#/components/schemas/PublicInfrastructureResponse")
    );
    assert_eq!(
        operation
            .pointer("/security")
            .and_then(|value| value.as_array()),
        Some(&vec![serde_json::json!({})]),
        "public infrastructure must override global bearer auth"
    );

    for (schema_name, expected_properties) in [
        (
            "PublicInfrastructureOverall",
            BTreeSet::from(["availability_pct", "total_regions", "total_vms"]),
        ),
        (
            "PublicRegionInfrastructure",
            BTreeSet::from([
                "display_name",
                "health",
                "provider",
                "provider_location",
                "region",
                "utilization",
                "vm_count",
            ]),
        ),
    ] {
        let properties = spec
            .pointer(&format!("/components/schemas/{schema_name}/properties"))
            .and_then(|value| value.as_object())
            .unwrap_or_else(|| panic!("{schema_name} must define object properties"))
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        assert_eq!(
            properties, expected_properties,
            "{schema_name} must expose only the public allowlist"
        );
    }
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
fn source_discovery_openapi_publishes_every_provider_request_contract() {
    let spec = crate::common::openapi_spec_json();
    assert_eq!(
        schema_refs_at_pointer(
            &spec,
            "/paths/~1migration~1{source_provider}~1list-indexes/post/requestBody/content/application~1json/schema",
        ),
        BTreeSet::from([
            "#/components/schemas/ListAlgoliaIndexesRequest".to_string(),
            "#/components/schemas/ListMeilisearchIndexesRequest".to_string(),
            "#/components/schemas/ListTypesenseIndexesRequest".to_string(),
        ]),
        "list-indexes must publish one request body contract per accepted source provider"
    );
}

#[test]
fn source_discovery_openapi_publishes_algolia_and_hosted_response_contracts() {
    let spec = crate::common::openapi_spec_json();
    assert_eq!(
        schema_refs_at_pointer(
            &spec,
            "/paths/~1migration~1{source_provider}~1list-indexes/post/responses/200/content/application~1json/schema",
        ),
        BTreeSet::from([
            "#/components/schemas/AlgoliaSourceListResponse".to_string(),
            "#/components/schemas/ListSourceIndexesResponse".to_string(),
        ]),
        "list-indexes 200 must publish both the Algolia compatibility and hosted engine response contracts"
    );
}

#[test]
fn source_migration_openapi_surface_is_narrow_and_client_bound() {
    let spec = crate::common::openapi_spec_json();

    assert!(
        spec.pointer("/paths/~1migration~1{source_provider}~1list-indexes/post")
            .is_some(),
        "POST /migration/{{source_provider}}/list-indexes must be in OpenAPI"
    );
    assert!(
        spec.pointer("/paths/~1migration~1{source_provider}~1migrate/post")
            .is_none(),
        "removed POST /migration/{{source_provider}}/migrate must not be in OpenAPI"
    );
    assert_no_legacy_algolia_path_items(&spec);

    assert!(
        spec.pointer("/paths/~1migration~1{source_provider}~1availability/get")
            .is_some(),
        "authenticated GET /migration/{{source_provider}}/availability must remain in OpenAPI"
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1{source_provider}~1availability/get/responses/200/content/application~1json/schema/$ref"
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
            "message".to_string()
        ],
        "availability response must not require optional reason"
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
            "preview".to_string(),
            "replace".to_string(),
            "resume".to_string(),
            "verify".to_string()
        ],
        "capabilities must require the complete operation set"
    );
    for operation in ["cancel", "preview", "replace", "resume", "verify"] {
        assert_eq!(
            spec.pointer(&format!(
                "/components/schemas/AlgoliaMigrationCapabilities/properties/{operation}/type"
            ))
            .and_then(|value| value.as_str()),
            Some("boolean"),
            "{operation} capability must be documented as a boolean"
        );
    }
    let list_indexes_operation = "/paths/~1migration~1{source_provider}~1list-indexes/post";
    for status in ["403", "500", "503"] {
        assert_eq!(
            response_schema_ref(&spec, list_indexes_operation, status),
            Some("#/components/schemas/MigrationErrorResponse"),
            "list-indexes {status} handler response must use coded migration errors"
        );
    }
    assert_eq!(
        spec.pointer(&format!(
            "{list_indexes_operation}/responses/500/description"
        ))
        .and_then(|value| value.as_str()),
        Some("Backend target, engine response, or secret lookup failed"),
        "list-indexes 500 must document every hosted discovery internal-failure family"
    );
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
        AlgoliaImportErrorCode::SourceProviderUnsupported,
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
    for mounted_path in [
        "/paths/~1migration~1{source_provider}~1destination-eligibility/post",
        "/paths/~1migration~1{source_provider}~1jobs/post",
        "/paths/~1migration~1{source_provider}~1jobs/get",
        "/paths/~1migration~1{source_provider}~1jobs~1{id}/get",
        "/paths/~1migration~1{source_provider}~1jobs~1{id}~1cancel/post",
        "/paths/~1migration~1{source_provider}~1jobs~1{id}~1resume/post",
    ] {
        assert!(
            spec.pointer(mounted_path).is_some(),
            "{mounted_path} must remain documented after route activation"
        );
    }
    for (mounted_path, operation_id) in [
        (
            "/paths/~1migration~1{source_provider}~1availability/get",
            "algolia_availability",
        ),
        (
            "/paths/~1migration~1{source_provider}~1list-indexes/post",
            "list_algolia_indexes",
        ),
        (
            "/paths/~1migration~1{source_provider}~1destination-eligibility/post",
            "check_algolia_destination_eligibility",
        ),
        (
            "/paths/~1migration~1{source_provider}~1jobs/post",
            "create_algolia_import_job",
        ),
        (
            "/paths/~1migration~1{source_provider}~1jobs/get",
            "list_algolia_import_jobs",
        ),
        (
            "/paths/~1migration~1{source_provider}~1jobs~1{id}/get",
            "get_algolia_import_job",
        ),
        (
            "/paths/~1migration~1{source_provider}~1jobs~1{id}~1cancel/post",
            "cancel_algolia_import_job",
        ),
        (
            "/paths/~1migration~1{source_provider}~1jobs~1{id}~1resume/post",
            "resume_algolia_import_job",
        ),
    ] {
        if mounted_path == "/paths/~1migration~1{source_provider}~1jobs/get" {
            assert_eq!(
                response_schema_refs(&spec, mounted_path, "400"),
                BTreeSet::from([
                    "#/components/schemas/ErrorResponse".to_string(),
                    "#/components/schemas/MigrationErrorResponse".to_string()
                ]),
                "{mounted_path} must document coded unsupported-provider errors and uncoded cursor errors"
            );
        } else {
            assert_eq!(
                response_schema_ref(&spec, mounted_path, "400"),
                Some("#/components/schemas/MigrationErrorResponse"),
                "{mounted_path} must document its coded unsupported-provider response"
            );
        }
        assert_eq!(
            spec.pointer(&format!("{mounted_path}/operationId"))
                .and_then(|value| value.as_str()),
            Some(operation_id),
            "{mounted_path} must preserve its public operationId"
        );
        let parameters = spec
            .pointer(&format!("{mounted_path}/parameters"))
            .and_then(|value| value.as_array())
            .unwrap_or_else(|| panic!("{mounted_path} must document operation parameters"));
        let source_provider = parameters
            .iter()
            .find(|parameter| {
                parameter.get("name").and_then(|value| value.as_str()) == Some("source_provider")
                    && parameter.get("in").and_then(|value| value.as_str()) == Some("path")
            })
            .unwrap_or_else(|| {
                panic!("{mounted_path} must document the source_provider path parameter")
            });
        assert_eq!(
            source_provider
                .get("required")
                .and_then(|value| value.as_bool()),
            Some(true),
            "{mounted_path} source_provider path parameter must be required"
        );
        assert_eq!(
            source_provider
                .pointer("/schema/$ref")
                .and_then(|value| value.as_str()),
            Some("#/components/schemas/SourceImportProvider"),
            "{mounted_path} source_provider path parameter must reuse the canonical provider schema"
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
    assert_eq!(
        spec.pointer(
            "/components/schemas/ListAlgoliaIndexesRequest/properties/hitsPerPage/minimum"
        )
        .and_then(|value| value.as_u64()),
        Some(1),
        "list-indexes hitsPerPage must reject zero and negative values at the contract boundary"
    );
    assert_eq!(
        spec.pointer(
            "/components/schemas/ListAlgoliaIndexesRequest/properties/hitsPerPage/maximum"
        )
        .and_then(|value| value.as_u64()),
        Some(100),
        "list-indexes hitsPerPage must cap authenticated discovery page fan-out"
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
        spec.pointer("/components/schemas/AlgoliaIndexMetadata/properties/revision/type"),
        Some(&serde_json::json!("string")),
        "Algolia picker metadata must publish absent producer-native revisions by omitting revision"
    );
    assert_eq!(
        required_fields(&spec, "AlgoliaSourceListResponse"),
        vec!["items".to_string(), "nextCursor".to_string()]
    );
    assert_eq!(
        spec.pointer(
            "/paths/~1migration~1{source_provider}~1availability/get/responses/401/content/application~1json/schema/$ref"
        )
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/ErrorResponse"),
        "availability route must document the auth-required response"
    );

    if let Some(security) =
        spec.pointer("/paths/~1migration~1{source_provider}~1availability/get/security")
    {
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

    let reason_one_of = spec
        .pointer("/components/schemas/AlgoliaMigrationAvailabilityResponse/properties/reason/oneOf")
        .and_then(|value| value.as_array())
        .expect("availability reason must be documented as an optional typed wrapper");
    assert_eq!(
        reason_one_of,
        &[
            serde_json::json!({ "type": "null" }),
            serde_json::json!({ "$ref": "#/components/schemas/AlgoliaMigrationAvailabilityReason" })
        ],
        "availability reason must retain the typed fail-closed enum through the optional wrapper"
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
    let types_source =
        std::fs::read_to_string(repo_root.join("web/src/lib/api/types_algolia_migration.ts"))
            .expect("read migration API types");
    assert!(
        types_source.contains("reason?: 'temporarily_unavailable';"),
        "web API migration type must expose the optional fail-closed reason literal"
    );
    assert!(
        types_source.contains("hitsPerPage?: number | null;"),
        "web API migration request type must expose the optional hitsPerPage override"
    );
    assert!(
        types_source.contains("resumeProvenance: string | null;"),
        "web API migration job type must expose producer-authored resume provenance"
    );
    assert!(
        !types_source.contains("resumeCheckpoint:"),
        "public migration job types must not expose the internal engine resume checkpoint"
    );
    assert!(
        !types_source.contains("| 'available'"),
        "web API migration type must not advertise an available reason"
    );
    for field in [
        "updatedAt: string;",
        "lastBuildTimeS: number;",
        "primary: string | null;",
        "replicas: string[];",
        "revision?: string;",
    ] {
        assert!(
            types_source.contains(field),
            "missing picker metadata field {field}"
        );
    }
}

#[test]
fn verify_source_migration_openapi_surface_is_schema_bound() {
    let spec = crate::common::openapi_spec_json();
    let operation = "/paths/~1migration~1{source_provider}~1verify/post";

    let published_verify_paths = spec
        .get("paths")
        .and_then(|value| value.as_object())
        .expect("spec must have a paths object")
        .keys()
        .filter(|path| path.starts_with("/migration/") && path.ends_with("/verify"))
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(
        published_verify_paths,
        vec!["/migration/{source_provider}/verify".to_string()],
        "verify must publish exactly the parameterized route mounted in route_assembly"
    );

    assert_eq!(
        spec.pointer(&format!("{operation}/operationId"))
            .and_then(|value| value.as_str()),
        Some("verify_source_migration"),
        "verify must preserve its public operationId"
    );
    assert_eq!(
        spec.pointer(&format!(
            "{operation}/requestBody/content/application~1json/schema/$ref"
        ))
        .and_then(|value| value.as_str()),
        Some("#/components/schemas/VerifySourceMigrationRequest"),
        "verify request body must reference the published request schema"
    );
    assert_eq!(
        response_schema_ref(&spec, operation, "200"),
        Some("#/components/schemas/VerifySourceMigrationResponse"),
        "verify 200 must publish the parity report schema it serves"
    );
    let bad_request_schema = spec
        .pointer(&format!(
            "{operation}/responses/400/content/application~1json/schema"
        ))
        .expect("verify 400 must document a JSON schema");
    assert!(
        bad_request_schema.get("oneOf").is_none(),
        "verify 400 must not publish overlapping oneOf alternatives"
    );
    assert_eq!(
        bad_request_schema
            .get("$ref")
            .and_then(|value| value.as_str()),
        Some("#/components/schemas/VerifySourceMigrationBadRequestResponse"),
        "verify 400 must publish one structural envelope with optional migration code"
    );
    for (status, expected) in [
        ("401", "#/components/schemas/ErrorResponse"),
        ("403", "#/components/schemas/MigrationErrorResponse"),
        ("404", "#/components/schemas/ErrorResponse"),
    ] {
        assert_eq!(
            response_schema_ref(&spec, operation, status),
            Some(expected),
            "verify {status} must publish {expected}"
        );
    }
    assert_eq!(
        response_schema_ref(&spec, operation, "410"),
        Some("#/components/schemas/VerifySourceMigrationRestoreStatusResponse"),
        "verify 410 must publish the shared cold-restore body shape it serves"
    );
    assert_eq!(
        response_schema_refs(&spec, operation, "503"),
        BTreeSet::from([
            "#/components/schemas/MigrationErrorResponse".to_string(),
            "#/components/schemas/VerifySourceMigrationRestoreStatusResponse".to_string()
        ]),
        "verify 503 must publish both coded backend errors and destination restoring bodies"
    );

    let source_provider = spec
        .pointer(&format!("{operation}/parameters"))
        .and_then(|value| value.as_array())
        .and_then(|parameters| {
            parameters.iter().find(|parameter| {
                parameter.get("name").and_then(|v| v.as_str()) == Some("source_provider")
            })
        })
        .expect("verify must document the source_provider path parameter");
    assert_eq!(
        source_provider.get("required").and_then(|v| v.as_bool()),
        Some(true),
        "verify source_provider path parameter must be required"
    );
    assert_eq!(
        source_provider
            .pointer("/schema/$ref")
            .and_then(|v| v.as_str()),
        Some("#/components/schemas/SourceImportProvider"),
        "verify source_provider must reuse the canonical provider schema"
    );

    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationRequest"),
        vec![
            "apiKey".to_string(),
            "appId".to_string(),
            "destinationIndex".to_string(),
            "queries".to_string(),
            "resultLimit".to_string(),
            "sourceIndex".to_string(),
        ],
        "verify request schema must require every credential and comparison field"
    );
    let verify_queries = spec
        .pointer("/components/schemas/VerifySourceMigrationRequest/properties/queries")
        .expect("verify request must publish its queries schema");
    assert_eq!(
        verify_queries
            .get("minItems")
            .and_then(|value| value.as_u64()),
        Some(1)
    );
    assert_eq!(
        verify_queries
            .get("maxItems")
            .and_then(|value| value.as_u64()),
        Some(20)
    );
    assert_eq!(
        verify_queries
            .pointer("/items/maxLength")
            .and_then(|value| value.as_u64()),
        Some(512),
        "verify query strings must publish the runtime search-query bound"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationResponse"),
        vec![
            "destinationIndex".to_string(),
            "queries".to_string(),
            "resultLimit".to_string(),
            "sourceIndex".to_string(),
        ],
        "verify response schema must always serialize the report envelope fields"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationQueryReport"),
        vec![
            "destinationOnly".to_string(),
            "hits".to_string(),
            "overlapCount".to_string(),
            "query".to_string(),
            "sourceOnly".to_string(),
        ],
        "verify per-query report must serialize the full parity breakdown"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationHitComparison"),
        vec![
            "destinationRank".to_string(),
            "objectID".to_string(),
            "rankDelta".to_string(),
            "sourceRank".to_string(),
        ],
        "verify hit comparison must serialize both ranks and the delta"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationBadRequestResponse"),
        vec!["error".to_string()],
        "verify 400 structural envelope must require the shared error field"
    );
    let bad_request_code_schema = spec
        .pointer("/components/schemas/VerifySourceMigrationBadRequestResponse/properties/code")
        .expect("verify 400 code property must be published");
    let mut bad_request_code_refs = BTreeSet::new();
    let mut visited_code_refs = BTreeSet::new();
    collect_schema_refs(
        &spec,
        bad_request_code_schema,
        &mut bad_request_code_refs,
        &mut visited_code_refs,
    );
    assert_eq!(
        bad_request_code_refs,
        BTreeSet::from(["#/components/schemas/AlgoliaImportErrorCode".to_string()]),
        "verify 400 optional code must still be typed when present"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationRestoreStatusResponse"),
        vec!["error".to_string(), "message".to_string()],
        "verify restore body must require the common restore-status fields"
    );
    let restore_links = spec
        .pointer("/components/schemas/VerifySourceMigrationRestoreStatusResponse/properties")
        .and_then(|value| value.as_object())
        .expect("verify restore body must publish properties")
        .keys()
        .filter(|field| *field == "poll_url" || *field == "restore_url")
        .cloned()
        .collect::<BTreeSet<_>>();
    assert_eq!(
        restore_links,
        BTreeSet::from(["poll_url".to_string(), "restore_url".to_string()]),
        "verify restore body must publish both cold restore_url and restoring poll_url"
    );
}

#[test]
fn source_migration_create_openapi_publishes_all_provider_request_contracts() {
    let spec = crate::common::openapi_spec_json();
    let operation = "/paths/~1migration~1{source_provider}~1jobs/post";
    let request_schema = spec
        .pointer(&format!(
            "{operation}/requestBody/content/application~1json/schema"
        ))
        .expect("POST /migration/{source_provider}/jobs must publish a JSON request schema");
    let mut request_variants = BTreeSet::new();
    let mut visited = BTreeSet::new();
    collect_schema_refs(&spec, request_schema, &mut request_variants, &mut visited);

    let expected_variants = published_create_request_schema_refs(&spec);
    assert_eq!(
        request_variants, expected_variants,
        "the create operation must publish one request variant per accepted provider"
    );
    assert_eq!(
        response_schema_ref(&spec, operation, "415"),
        Some("#/components/schemas/MigrationErrorResponse"),
        "the documented JSON-only request boundary must publish its 415 response"
    );

    let provider_field_contracts = [
        (
            "CreateAlgoliaImportJobRequest",
            vec!["apiKey", "appId", "mode", "sourceName", "target"],
            "appId",
            "sourceIndex",
        ),
        (
            "CreateMeilisearchImportJobRequest",
            vec!["apiKey", "endpoint", "mode", "sourceIndex", "target"],
            "endpoint",
            "sourceName",
        ),
        (
            "CreateTypesenseImportJobRequest",
            vec!["apiKey", "mode", "node", "sourceIndex", "target"],
            "node",
            "sourceName",
        ),
    ];

    assert_eq!(
        provider_field_contracts
            .iter()
            .map(|(schema, ..)| format!("#/components/schemas/{schema}"))
            .collect::<BTreeSet<String>>(),
        expected_variants,
        "every published provider create schema must also have a field-shape contract asserted below"
    );
    assert_eq!(
        required_fields(&spec, "CreateImportJobSourceRevisionRequest"),
        vec!["documentCount".to_string()],
        "source revision metadata must only require the monotonic document-count baseline"
    );
    assert_optional_non_nullable_string_property(
        &spec,
        "CreateImportJobSourceRevisionRequest",
        "updatedAt",
    );
    assert_optional_non_nullable_string_property(
        &spec,
        "CreateImportJobSourceRevisionRequest",
        "revision",
    );

    for (schema, expected_required, provider_field, forbidden_field) in provider_field_contracts {
        assert_eq!(
            required_fields(&spec, schema),
            expected_required,
            "{schema} must require its exact provider-specific create shape"
        );
        assert!(
            spec.pointer(&format!(
                "/components/schemas/{schema}/properties/{provider_field}"
            ))
            .is_some(),
            "{schema} must publish {provider_field}"
        );
        assert_optional_non_nullable_ref_property(
            &spec,
            schema,
            "sourceRevision",
            "#/components/schemas/CreateImportJobSourceRevisionRequest",
        );
        if schema != "CreateAlgoliaImportJobRequest" {
            let source_revision_schema = spec
                .pointer(&format!(
                    "/components/schemas/{schema}/properties/sourceRevision"
                ))
                .unwrap_or_else(|| panic!("{schema} must publish the hosted sourceRevision guard"));
            let mut source_revision_refs = BTreeSet::new();
            let mut visited = BTreeSet::new();
            collect_schema_refs(
                &spec,
                source_revision_schema,
                &mut source_revision_refs,
                &mut visited,
            );
            assert_eq!(
                source_revision_refs,
                BTreeSet::from([
                    "#/components/schemas/CreateImportJobSourceRevisionRequest".to_string()
                ]),
                "{schema}.sourceRevision must reuse the canonical source revision schema"
            );
        }
        assert!(
            spec.pointer(&format!(
                "/components/schemas/{schema}/properties/{forbidden_field}"
            ))
            .is_none(),
            "{schema} must not publish the sibling wire field {forbidden_field}"
        );
        assert_eq!(
            spec.pointer(&format!(
                "/components/schemas/{schema}/additionalProperties"
            ))
            .and_then(serde_json::Value::as_bool),
            Some(false),
            "{schema} must reject ambiguous or mismatched provider fields"
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
async fn openapi_docs_route_serves_exact_migration_contract_over_http() {
    let app = crate::common::TestStateBuilder::new().build_app();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral loopback listener for /docs test");
    let docs_url = format!(
        "http://{}/docs",
        listener
            .local_addr()
            .expect("bound listener must expose local address")
    );
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    let server_task = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = shutdown_rx.await;
            })
            .await
    });

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .expect("build bounded reqwest client");
    let response = tokio::time::timeout(Duration::from_secs(3), client.get(docs_url).send())
        .await
        .expect("GET /docs must not hang")
        .expect("GET /docs must complete over loopback");
    assert_eq!(
        response.status(),
        reqwest::StatusCode::OK,
        "GET /docs must return the Scalar UI"
    );

    let html = tokio::time::timeout(Duration::from_secs(3), response.text())
        .await
        .expect("reading /docs response body must not hang")
        .expect("GET /docs body must be readable");
    let served_spec = scalar_api_reference_json(&html);
    let expected_spec =
        serde_json::to_value(ApiDoc::openapi()).expect("ApiDoc must serialize to JSON");
    assert_eq!(
        served_spec, expected_spec,
        "/docs must serve the canonical ApiDoc document"
    );

    let operations = migration_http_operations(&served_spec);
    let expected_operations = BTreeSet::from([
        (
            "GET".to_string(),
            "/migration/{source_provider}/availability".to_string(),
        ),
        (
            "POST".to_string(),
            "/migration/{source_provider}/list-indexes".to_string(),
        ),
        ("POST".into(), "/migration/{source_provider}/preview".into()),
        ("POST".into(), "/migration/{source_provider}/verify".into()),
        (
            "POST".to_string(),
            "/migration/{source_provider}/destination-eligibility".to_string(),
        ),
        (
            "POST".to_string(),
            "/migration/{source_provider}/jobs".to_string(),
        ),
        (
            "GET".to_string(),
            "/migration/{source_provider}/jobs".to_string(),
        ),
        (
            "GET".to_string(),
            "/migration/{source_provider}/jobs/{id}".to_string(),
        ),
        (
            "POST".to_string(),
            "/migration/{source_provider}/jobs/{id}/cancel".to_string(),
        ),
        (
            "POST".to_string(),
            "/migration/{source_provider}/jobs/{id}/resume".to_string(),
        ),
    ]);
    assert_eq!(operations.len(), 10);
    assert_eq!(operations, expected_operations);

    shutdown_tx
        .send(())
        .expect("server shutdown receiver must still be live");
    let server_result = tokio::time::timeout(Duration::from_secs(3), server_task)
        .await
        .expect("server task must stop after graceful shutdown")
        .expect("server task must not panic");
    server_result.expect("server must exit without transport error");
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
        spec.pointer("/paths/~1migration~1{source_provider}~1availability/get")
            .is_some(),
        "GET /migration/{{source_provider}}/availability must be documented"
    );
    assert!(
        spec.pointer("/paths/~1migration~1{source_provider}~1list-indexes/post")
            .is_some(),
        "Customer source discovery route must remain in OpenAPI"
    );
    assert!(
        spec.pointer("/paths/~1migration~1{source_provider}~1migrate")
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

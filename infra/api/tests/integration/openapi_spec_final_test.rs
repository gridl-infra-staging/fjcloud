use serde_json::Value;

const ALGOLIA_MIGRATION_ENGINE_CONTRACT_JSON: &str =
    include_str!("../fixtures/algolia_migration_engine_contract.json");

// ===========================================================================
// Stage 5 — Method-level operation checks
// ===========================================================================

/// Verify all Stage 5 paths have the correct HTTP methods registered.
/// Complements the path-existence spot-checks in `spec_contains_only_stage_1_through_5_paths`
/// by asserting the exact method on each operation.
#[test]
fn algolia_cloud_discovery_spec_contains_stage5_operations() {
    let spec = crate::common::openapi_spec_json();

    let stage5_ops: &[(&str, &str)] = &[
        // Usage
        ("/usage", "get"),
        ("/usage/daily", "get"),
        // Invoices
        ("/invoices", "get"),
        ("/invoices/{invoice_id}", "get"),
        // Pricing (public)
        ("/pricing/compare", "post"),
        // Analytics proxy
        ("/indexes/{name}/analytics/searches", "get"),
        ("/indexes/{name}/analytics/searches/count", "get"),
        ("/indexes/{name}/analytics/searches/noResults", "get"),
        ("/indexes/{name}/analytics/searches/noResultRate", "get"),
        ("/indexes/{name}/analytics/status", "get"),
        // Experiments proxy
        ("/indexes/{name}/experiments", "get"),
        ("/indexes/{name}/experiments", "post"),
        ("/indexes/{name}/experiments/{id}", "get"),
        ("/indexes/{name}/experiments/{id}", "put"),
        ("/indexes/{name}/experiments/{id}", "delete"),
        ("/indexes/{name}/experiments/{id}/start", "post"),
        ("/indexes/{name}/experiments/{id}/stop", "post"),
        ("/indexes/{name}/experiments/{id}/conclude", "post"),
        ("/indexes/{name}/experiments/{id}/results", "get"),
        // Debug events
        ("/indexes/{name}/events/debug", "get"),
        ("/indexes/{name}/events", "post"),
        // Index keys
        ("/indexes/{name}/keys", "post"),
        // Source migration
        ("/migration/{source_provider}/availability", "get"),
        ("/migration/{source_provider}/list-indexes", "post"),
    ];

    for (path, method) in stage5_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            spec.pointer(&pointer).is_some(),
            "spec must contain {method} {path}"
        );
    }
}

// ===========================================================================
// Stage 5 — Schema presence checks
// ===========================================================================

/// Verify all Stage 5 DTOs are registered in /components/schemas/.
#[test]
fn algolia_cloud_discovery_spec_contains_stage5_schemas() {
    let spec = crate::common::openapi_spec_json();

    let stage5_schemas = [
        "DailyUsageEntry",
        "UsageSummaryResponse",
        "RegionUsageSummary",
        "InvoiceListItem",
        "LineItemResponse",
        "InvoiceDetailResponse",
        "CreateKeyRequest",
        "AlgoliaMigrationAvailabilityResponse",
        "ListAlgoliaIndexesRequest",
        "ListMeilisearchIndexesRequest",
        "ListTypesenseIndexesRequest",
        "AlgoliaSourceListResponse",
        "AlgoliaIndexMetadata",
        "ListSourceIndexesResponse",
        "SourceIndexSummary",
        // "InstanceResponse" removed: AYB / AllYourBase moved to aybcloud_dev
        // in commit f3dcaddd (Apr 26). The corresponding operations were
        // removed from spec_contains_stage5_operations in the same commit;
        // this schema entry was a missed leftover.
    ];
    for schema in stage5_schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain Stage 5 schema {schema}"
        );
    }
}

// ===========================================================================
// Cross-cutting structural checks
// ===========================================================================

/// Regression fence: the spec must contain at least the expected number of paths.
/// Catches accidental path removal during refactors.
#[test]
fn spec_path_count_guard() {
    let spec = crate::common::openapi_spec_json();

    let paths = spec
        .get("paths")
        .and_then(|v| v.as_object())
        .expect("spec must have a paths object");

    let count = paths.len();
    // 67 unique path strings from Stages 1-5; use >= so adding paths never breaks this test.
    // (The checklist estimated 93 but that counted path+method combos; OpenAPI deduplicates
    // methods under the same path key, yielding 66 unique path entries.)
    assert!(
        count >= 67,
        "spec must contain at least 67 paths (Stages 1-5), found {count}"
    );
}

/// Every operation in the spec must define at least one 2xx success response.
/// An operation without a success response is likely a documentation oversight.
#[test]
fn spec_every_operation_has_success_response() {
    let spec = crate::common::openapi_spec_json();

    let paths = spec
        .get("paths")
        .and_then(|v| v.as_object())
        .expect("spec must have a paths object");

    let http_methods = ["get", "post", "put", "patch", "delete"];

    for (path, path_item) in paths {
        let path_obj = path_item
            .as_object()
            .unwrap_or_else(|| panic!("path item for {path} must be an object"));

        for method in &http_methods {
            if let Some(operation) = path_obj.get(*method) {
                let responses = operation
                    .get("responses")
                    .and_then(|v| v.as_object())
                    .unwrap_or_else(|| panic!("{method} {path} must have a responses object"));

                let has_success = responses.keys().any(|code| code.starts_with('2'));

                assert!(
                    has_success,
                    "{method} {path} must define at least one 2xx success response, \
                     found only: {:?}",
                    responses.keys().collect::<Vec<_>>()
                );
            }
        }
    }
}

/// Every operation must have at least one tag assigned.
/// Untagged operations appear under "default" in Scalar UI, which is confusing.
#[test]
fn spec_no_empty_tags() {
    let spec = crate::common::openapi_spec_json();

    let paths = spec
        .get("paths")
        .and_then(|v| v.as_object())
        .expect("spec must have a paths object");

    let http_methods = ["get", "post", "put", "patch", "delete"];

    for (path, path_item) in paths {
        let path_obj = path_item
            .as_object()
            .unwrap_or_else(|| panic!("path item for {path} must be an object"));

        for method in &http_methods {
            if let Some(operation) = path_obj.get(*method) {
                let tags = operation.get("tags").and_then(|v| v.as_array());
                let has_tags = tags.is_some_and(|arr| !arr.is_empty());
                assert!(
                    has_tags,
                    "{method} {path} must have at least one tag to avoid \
                     appearing in the default group"
                );
            }
        }
    }
}

fn schema_ref<'a>(spec: &'a Value, pointer: &str) -> &'a str {
    spec.pointer(pointer)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("{pointer} must be a schema reference"))
}

fn required_fields(spec: &Value, schema_name: &str) -> Vec<String> {
    let mut fields = spec
        .pointer(&format!("/components/schemas/{schema_name}/required"))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{schema_name} must declare required fields"))
        .iter()
        .map(|field| {
            field
                .as_str()
                .unwrap_or_else(|| panic!("{schema_name} required fields must be strings"))
                .to_string()
        })
        .collect::<Vec<_>>();
    fields.sort();
    fields
}

fn optional_fields(spec: &Value, schema_name: &str) -> Vec<String> {
    let required = required_fields(spec, schema_name);
    let mut fields = spec
        .pointer(&format!("/components/schemas/{schema_name}/properties"))
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("{schema_name} must declare properties"))
        .keys()
        .filter(|field| !required.contains(field))
        .cloned()
        .collect::<Vec<_>>();
    fields.sort();
    fields
}

fn schema_refs(spec: &Value, schema: &Value) -> std::collections::BTreeSet<String> {
    fn collect(
        spec: &Value,
        schema: &Value,
        refs: &mut std::collections::BTreeSet<String>,
        visited: &mut std::collections::BTreeSet<String>,
    ) {
        if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
            if !visited.insert(reference.to_string()) {
                return;
            }
            if let Some(schema_name) = reference.strip_prefix("#/components/schemas/") {
                if let Some(component) = spec.pointer(&format!("/components/schemas/{schema_name}"))
                {
                    if ["oneOf", "anyOf", "allOf"]
                        .iter()
                        .any(|key| component.get(key).is_some())
                    {
                        collect(spec, component, refs, visited);
                        return;
                    }
                }
            }
            refs.insert(reference.to_string());
        }
        for key in ["oneOf", "anyOf", "allOf"] {
            if let Some(entries) = schema.get(key).and_then(Value::as_array) {
                for entry in entries {
                    collect(spec, entry, refs, visited);
                }
            }
        }
    }

    let mut refs = std::collections::BTreeSet::new();
    let mut visited = std::collections::BTreeSet::new();
    collect(spec, schema, &mut refs, &mut visited);
    refs
}

fn algolia_migration_engine_contract_json() -> Value {
    serde_json::from_str(ALGOLIA_MIGRATION_ENGINE_CONTRACT_JSON)
        .expect("algolia migration engine contract fixture must parse")
}

/// Reads engine-owned vocabularies without hand-copying their values.
fn contract_string_list(contract: &Value, pointer: &str) -> Vec<String> {
    contract
        .pointer(pointer)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("contract fixture must pin a string list at {pointer}"))
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .unwrap_or_else(|| panic!("contract entry at {pointer} must be a string"))
                .to_string()
        })
        .collect()
}

/// Schema names the published preview request union offers, in spec order.
fn published_request_variant_schemas(request_variants: &[Value]) -> Vec<&str> {
    request_variants
        .iter()
        .map(|variant| {
            variant
                .get("$ref")
                .and_then(Value::as_str)
                .and_then(|reference| reference.strip_prefix("#/components/schemas/"))
                .expect("each preview request variant must reference a published schema")
        })
        .collect()
}

fn assert_schema_fields_match_contract(
    spec: &Value,
    engine_contract: &Value,
    schema_contracts: &[(&str, &str)],
) {
    for (schema_name, contract_pointer) in schema_contracts {
        let required_pointer = format!("{contract_pointer}/required_fields");
        let optional_pointer = format!("{contract_pointer}/optional_fields");
        assert_eq!(
            required_fields(spec, schema_name),
            contract_string_list(engine_contract, &required_pointer),
            "published {schema_name} required fields must match the engine contract fixture"
        );
        assert_eq!(
            optional_fields(spec, schema_name),
            contract_string_list(engine_contract, &optional_pointer),
            "published {schema_name} optional fields must match the engine contract fixture"
        );
    }
}

fn assert_preview_route_contract(spec: &Value, engine_contract: &Value) {
    let preview_path = "/migration/{source_provider}/preview";
    let operation = "/paths/~1migration~1{source_provider}~1preview/post";

    let published_preview_paths = spec
        .get("paths")
        .and_then(Value::as_object)
        .expect("spec must have a paths object")
        .keys()
        .filter(|path| path.starts_with("/migration/") && path.ends_with("/preview"))
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(
        published_preview_paths,
        vec![preview_path.to_string()],
        "preview must publish exactly the parameterized route mounted in route_assembly"
    );
    assert_eq!(
        spec.pointer(&format!("{operation}/operationId"))
            .and_then(Value::as_str),
        Some("preview_source_migration")
    );
    for (suffix, expected) in [
        (
            "/requestBody/content/application~1json/schema/$ref",
            "#/components/schemas/MigrationPreviewRequest",
        ),
        (
            "/responses/200/content/application~1json/schema/$ref",
            "#/components/schemas/MigrationPreviewResponse",
        ),
    ] {
        assert_eq!(schema_ref(spec, &format!("{operation}{suffix}")), expected);
    }

    let source_provider_parameter = spec
        .pointer(&format!("{operation}/parameters"))
        .and_then(Value::as_array)
        .and_then(|parameters| parameters.iter().find(|p| p["name"] == "source_provider"))
        .expect("preview must publish the source_provider path parameter");
    assert_eq!(
        source_provider_parameter
            .pointer("/schema/$ref")
            .and_then(Value::as_str),
        Some("#/components/schemas/SourceImportProvider")
    );
    assert_eq!(
        spec.pointer("/components/schemas/SourceImportProvider/enum"),
        engine_contract.pointer("/provider_discriminator/values"),
        "published provider enum must match the engine contract's provider vocabulary"
    );
}

fn assert_preview_error_contract(spec: &Value) {
    let operation = "/paths/~1migration~1{source_provider}~1preview/post";
    for status in ["400", "500", "503"] {
        assert_eq!(
            schema_ref(
                spec,
                &format!("{operation}/responses/{status}/content/application~1json/schema/$ref"),
            ),
            "#/components/schemas/MigrationErrorResponse",
            "preview {status} must publish the coded migration error envelope it serves"
        );
    }
    assert_eq!(
        schema_ref(
            spec,
            &format!("{operation}/responses/401/content/application~1json/schema/$ref"),
        ),
        "#/components/schemas/ErrorResponse"
    );
    assert_eq!(required_fields(spec, "ErrorResponse"), vec!["error"]);
    assert!(optional_fields(spec, "ErrorResponse").is_empty());
    assert_eq!(
        required_fields(spec, "MigrationErrorResponse"),
        vec!["code", "error"]
    );
    assert!(optional_fields(spec, "MigrationErrorResponse").is_empty());
}

fn assert_preview_request_contract(spec: &Value, engine_contract: &Value) {
    let request_variants = spec
        .pointer("/components/schemas/MigrationPreviewRequest/oneOf")
        .and_then(Value::as_array)
        .expect("preview request must enumerate provider-specific payloads");
    assert_eq!(
        request_variants,
        &[
            serde_json::json!({
                "$ref": "#/components/schemas/AlgoliaMigrationPreviewRequest"
            }),
            serde_json::json!({
                "$ref": "#/components/schemas/MeilisearchMigrationPreviewRequest"
            }),
        ],
        "the engine contract has two distinct request shapes; Typesense currently reuses Algolia's shape"
    );

    let variant_schemas = published_request_variant_schemas(request_variants);
    for provider in contract_string_list(engine_contract, "/provider_discriminator/values") {
        let pinned_required = contract_string_list(
            engine_contract,
            &format!("/preview/request_fields/{provider}/required_fields"),
        );
        let pinned_optional = contract_string_list(
            engine_contract,
            &format!("/preview/request_fields/{provider}/optional_fields"),
        );
        let matching_variants = variant_schemas
            .iter()
            .filter(|schema_name| {
                required_fields(spec, schema_name) == pinned_required
                    && optional_fields(spec, schema_name) == pinned_optional
            })
            .count();
        assert_eq!(
            matching_variants, 1,
            "provider {provider} must resolve to exactly one published preview request variant \
             carrying its engine-pinned fields"
        );
    }

    assert_schema_fields_match_contract(
        spec,
        engine_contract,
        &[
            (
                "AlgoliaMigrationPreviewRequest",
                "/preview/request_fields/algolia",
            ),
            (
                "MeilisearchMigrationPreviewRequest",
                "/preview/request_fields/meilisearch",
            ),
        ],
    );
}

fn assert_preview_response_contract(spec: &Value, engine_contract: &Value) {
    assert_schema_fields_match_contract(
        spec,
        engine_contract,
        &[
            ("MigrationPreviewResponse", "/preview/response"),
            ("MigrationPreviewSourceCounts", "/preview/source_counts"),
            ("MigrationPreviewReport", "/preview/report"),
            ("MigrationPreviewReportSummary", "/preview/report_summary"),
            ("MigrationPreviewReportEntry", "/preview/report_entry"),
        ],
    );
    for (pointer, expected) in [
        (
            "/components/schemas/MigrationPreviewResponse/properties/sourceCounts/$ref",
            "#/components/schemas/MigrationPreviewSourceCounts",
        ),
        (
            "/components/schemas/MigrationPreviewResponse/properties/report/$ref",
            "#/components/schemas/MigrationPreviewReport",
        ),
        (
            "/components/schemas/MigrationPreviewReport/properties/summary/$ref",
            "#/components/schemas/MigrationPreviewReportSummary",
        ),
        (
            "/components/schemas/MigrationPreviewReport/properties/entries/items/$ref",
            "#/components/schemas/MigrationPreviewReportEntry",
        ),
    ] {
        assert_eq!(schema_ref(spec, pointer), expected);
    }
    for field in ["indexes", "records"] {
        let property = spec
            .pointer(&format!(
                "/components/schemas/MigrationPreviewSourceCounts/properties/{field}"
            ))
            .unwrap_or_else(|| panic!("sourceCounts.{field} must be published"));
        assert_eq!(property["type"], "integer");
        assert_eq!(property["minimum"], 0);
    }
    for (field, schema_name) in [
        ("severity", "MigrationPreviewReportSeverity"),
        ("code", "MigrationPreviewReportCode"),
        ("resource", "MigrationPreviewReportResource"),
    ] {
        assert_eq!(
            schema_ref(
                spec,
                &format!("/components/schemas/MigrationPreviewReportEntry/properties/{field}/$ref"),
            ),
            format!("#/components/schemas/{schema_name}")
        );
    }
    for (schema_name, contract_name) in [
        ("MigrationPreviewReportSeverity", "severity"),
        ("MigrationPreviewReportResource", "resource"),
        ("MigrationPreviewReportCode", "code"),
    ] {
        assert_eq!(
            spec.pointer(&format!("/components/schemas/{schema_name}/enum")),
            engine_contract.pointer(&format!("/preview/enums/{contract_name}")),
            "published preview {contract_name} enum must match the engine contract fixture"
        );
    }
}

#[test]
fn migration_preview_openapi_surface_is_schema_bound() {
    let spec = crate::common::openapi_spec_json();
    let engine_contract = algolia_migration_engine_contract_json();

    assert_preview_route_contract(&spec, &engine_contract);
    assert_preview_error_contract(&spec);
    assert_preview_request_contract(&spec, &engine_contract);
    assert_preview_response_contract(&spec, &engine_contract);
}

#[test]
fn migration_verify_openapi_surface_is_schema_bound() {
    let spec = crate::common::openapi_spec_json();
    let engine_contract = algolia_migration_engine_contract_json();

    let operation = "/paths/~1migration~1{source_provider}~1verify/post";

    let published_verify_paths = spec
        .get("paths")
        .and_then(Value::as_object)
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
            .and_then(Value::as_str),
        Some("verify_source_migration")
    );
    assert_eq!(
        schema_ref(
            &spec,
            &format!("{operation}/requestBody/content/application~1json/schema/$ref")
        ),
        "#/components/schemas/VerifySourceMigrationRequest"
    );
    assert_eq!(
        schema_ref(
            &spec,
            &format!("{operation}/responses/200/content/application~1json/schema/$ref")
        ),
        "#/components/schemas/VerifySourceMigrationResponse"
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
        bad_request_schema.get("$ref").and_then(Value::as_str),
        Some("#/components/schemas/VerifySourceMigrationBadRequestResponse"),
        "verify 400 must publish one structural envelope with optional migration code"
    );
    for (status, expected) in [
        ("403", "MigrationErrorResponse"),
        ("401", "ErrorResponse"),
        ("404", "ErrorResponse"),
    ] {
        assert_eq!(
            schema_ref(
                &spec,
                &format!("{operation}/responses/{status}/content/application~1json/schema/$ref")
            )
            .to_string(),
            format!("#/components/schemas/{expected}"),
            "verify {status} must publish the {expected} envelope it serves"
        );
    }
    assert_eq!(
        schema_ref(
            &spec,
            &format!("{operation}/responses/410/content/application~1json/schema/$ref")
        ),
        "#/components/schemas/VerifySourceMigrationRestoreStatusResponse"
    );
    let service_unavailable_schema = spec
        .pointer(&format!(
            "{operation}/responses/503/content/application~1json/schema"
        ))
        .expect("verify 503 must document a JSON schema");
    assert_eq!(
        schema_refs(&spec, service_unavailable_schema),
        std::collections::BTreeSet::from([
            "#/components/schemas/MigrationErrorResponse".to_string(),
            "#/components/schemas/VerifySourceMigrationRestoreStatusResponse".to_string()
        ]),
        "verify 503 must publish both coded backend errors and destination restoring bodies"
    );

    let source_provider_parameter = spec
        .pointer(&format!("{operation}/parameters"))
        .and_then(Value::as_array)
        .and_then(|parameters| parameters.iter().find(|p| p["name"] == "source_provider"))
        .expect("verify must publish the source_provider path parameter");
    assert_eq!(
        source_provider_parameter
            .pointer("/schema/$ref")
            .and_then(Value::as_str),
        Some("#/components/schemas/SourceImportProvider")
    );
    assert_eq!(
        spec.pointer("/components/schemas/SourceImportProvider/enum"),
        engine_contract.pointer("/provider_discriminator/values"),
        "verify must reuse the same canonical provider vocabulary as the rest of migration"
    );

    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationRequest"),
        vec![
            "apiKey",
            "appId",
            "destinationIndex",
            "queries",
            "resultLimit",
            "sourceIndex"
        ]
    );
    assert!(
        optional_fields(&spec, "VerifySourceMigrationRequest").is_empty(),
        "verify request must not mark any credential or comparison field optional"
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationResponse"),
        vec!["destinationIndex", "queries", "resultLimit", "sourceIndex"]
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationQueryReport"),
        vec![
            "destinationOnly",
            "hits",
            "overlapCount",
            "query",
            "sourceOnly"
        ]
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationHitComparison"),
        vec!["destinationRank", "objectID", "rankDelta", "sourceRank"]
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationBadRequestResponse"),
        vec!["error"]
    );
    let bad_request_code_schema = spec
        .pointer("/components/schemas/VerifySourceMigrationBadRequestResponse/properties/code")
        .expect("verify 400 code property must be published");
    assert_eq!(
        schema_refs(&spec, bad_request_code_schema),
        std::collections::BTreeSet::from([
            "#/components/schemas/AlgoliaImportErrorCode".to_string()
        ])
    );
    assert_eq!(
        required_fields(&spec, "VerifySourceMigrationRestoreStatusResponse"),
        vec!["error", "message"]
    );
    assert_eq!(
        required_fields(&spec, "MigrationErrorResponse"),
        vec!["code", "error"]
    );
}

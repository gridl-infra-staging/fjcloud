mod common;

// ===========================================================================
// Stage 5 — Method-level operation checks
// ===========================================================================

/// Verify all Stage 5 paths have the correct HTTP methods registered.
/// Complements the path-existence spot-checks in `spec_contains_only_stage_1_through_5_paths`
/// by asserting the exact method on each operation.
#[test]
fn spec_contains_stage5_operations() {
    let spec = common::openapi_spec_json();

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
        // Index keys
        ("/indexes/{name}/keys", "post"),
        // Algolia migration
        ("/migration/algolia/list-indexes", "post"),
        ("/migration/algolia/migrate", "post"),
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
fn spec_contains_stage5_schemas() {
    let spec = common::openapi_spec_json();

    let stage5_schemas = [
        "DailyUsageEntry",
        "UsageSummaryResponse",
        "RegionUsageSummary",
        "InvoiceListItem",
        "LineItemResponse",
        "InvoiceDetailResponse",
        "CreateKeyRequest",
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
    let spec = common::openapi_spec_json();

    let paths = spec
        .get("paths")
        .and_then(|v| v.as_object())
        .expect("spec must have a paths object");

    let count = paths.len();
    // 71 unique path strings from Stages 1-5; use >= so adding paths never breaks this test.
    // (The checklist estimated 93 but that counted path+method combos; OpenAPI deduplicates
    // methods under the same path key, yielding 71 unique path entries.)
    assert!(
        count >= 71,
        "spec must contain at least 71 paths (Stages 1-5), found {count}"
    );
}

/// Every operation in the spec must define at least one 2xx success response.
/// An operation without a success response is likely a documentation oversight.
#[test]
fn spec_every_operation_has_success_response() {
    let spec = common::openapi_spec_json();

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
    let spec = common::openapi_spec_json();

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

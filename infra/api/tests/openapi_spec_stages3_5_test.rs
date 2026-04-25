mod common;

// ===========================================================================
// Stage 3 — Billing operations and schemas
// ===========================================================================

#[test]
fn spec_contains_billing_operations() {
    let spec = common::openapi_spec_json();

    // All 11 billing paths with correct HTTP methods
    let billing_ops: &[(&str, &str)] = &[
        ("/billing/estimate", "get"),
        ("/billing/setup-intent", "post"),
        ("/billing/portal", "post"),
        ("/billing/checkout-session", "post"),
        ("/billing/payment-methods", "get"),
        ("/billing/payment-methods/{pm_id}", "delete"),
        ("/billing/payment-methods/{pm_id}/default", "post"),
        ("/billing/subscription", "get"),
        ("/billing/subscription/cancel", "post"),
        ("/billing/subscription/upgrade", "post"),
        ("/billing/subscription/downgrade", "post"),
    ];
    for (path, method) in billing_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            spec.pointer(&pointer).is_some(),
            "spec must contain {method} {path}"
        );
    }
}

#[test]
fn spec_billing_deprecated_routes_marked_deprecated() {
    let spec = common::openapi_spec_json();

    // 5 legacy routes must have deprecated: true on their operation
    let deprecated_ops = [
        "/paths/~1billing~1checkout-session/post",
        "/paths/~1billing~1subscription/get",
        "/paths/~1billing~1subscription~1cancel/post",
        "/paths/~1billing~1subscription~1upgrade/post",
        "/paths/~1billing~1subscription~1downgrade/post",
    ];
    for op_ptr in deprecated_ops {
        let deprecated = spec
            .pointer(&format!("{op_ptr}/deprecated"))
            .unwrap_or_else(|| panic!("{op_ptr} must have a deprecated field"));
        assert_eq!(
            deprecated.as_bool(),
            Some(true),
            "{op_ptr} must be marked deprecated"
        );
    }

    // Active billing routes must NOT be deprecated
    let active_ops = [
        "/paths/~1billing~1estimate/get",
        "/paths/~1billing~1setup-intent/post",
        "/paths/~1billing~1portal/post",
        "/paths/~1billing~1payment-methods/get",
        "/paths/~1billing~1payment-methods~1{pm_id}/delete",
        "/paths/~1billing~1payment-methods~1{pm_id}~1default/post",
    ];
    for op_ptr in active_ops {
        let deprecated = spec.pointer(&format!("{op_ptr}/deprecated"));
        // Either absent or explicitly false
        if let Some(val) = deprecated {
            assert_eq!(
                val.as_bool(),
                Some(false),
                "{op_ptr} must NOT be deprecated"
            );
        }
    }
}

#[test]
fn spec_authenticated_billing_routes_document_401() {
    let spec = common::openapi_spec_json();

    // All 11 billing operations must document 401 with ErrorResponse
    let billing_401_refs = [
        "/paths/~1billing~1estimate/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1setup-intent/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1portal/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1checkout-session/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1payment-methods/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1payment-methods~1{pm_id}/delete/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1payment-methods~1{pm_id}~1default/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1subscription/get/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1subscription~1cancel/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1subscription~1upgrade/post/responses/401/content/application~1json/schema/$ref",
        "/paths/~1billing~1subscription~1downgrade/post/responses/401/content/application~1json/schema/$ref",
    ];
    for ref_ptr in billing_401_refs {
        assert_eq!(
            spec.pointer(ref_ptr).and_then(|v| v.as_str()),
            Some("#/components/schemas/ErrorResponse"),
            "{ref_ptr} must reference ErrorResponse"
        );
    }
}

#[test]
fn spec_contains_billing_schemas() {
    let spec = common::openapi_spec_json();

    let billing_schemas = [
        "SetupIntentResponse",
        "CreateBillingPortalSessionRequest",
        "BillingPortalSessionResponse",
        "PaymentMethodResponse",
        "EstimateLineItem",
        "EstimatedBillResponse",
        "CreateCheckoutSessionRequest",
        "CheckoutSessionResponseBody",
        "CancelSubscriptionRequest",
        "SubscriptionResponse",
        "UpdateSubscriptionRequest",
    ];
    for schema in billing_schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain billing schema {schema}"
        );
    }

    // PlanTier must also be registered (single source of truth from billing crate)
    assert!(
        spec.pointer("/components/schemas/PlanTier").is_some(),
        "spec must contain PlanTier schema from billing crate"
    );
}

#[test]
fn spec_billing_portal_uses_dedicated_request_response_schemas() {
    let spec = common::openapi_spec_json();

    let request_schema = spec
        .pointer("/paths/~1billing~1portal/post/requestBody/content/application~1json/schema/$ref")
        .and_then(|v| v.as_str());
    assert_eq!(
        request_schema,
        Some("#/components/schemas/CreateBillingPortalSessionRequest"),
        "portal endpoint must use dedicated request schema"
    );

    let response_schema = spec
        .pointer(
            "/paths/~1billing~1portal/post/responses/200/content/application~1json/schema/$ref",
        )
        .and_then(|v| v.as_str());
    assert_eq!(
        response_schema,
        Some("#/components/schemas/BillingPortalSessionResponse"),
        "portal endpoint must use dedicated response schema"
    );
}

#[test]
fn spec_billing_pm_routes_declare_pm_id_path_parameter() {
    let spec = common::openapi_spec_json();

    // Both DELETE /billing/payment-methods/{pm_id} and
    // POST /billing/payment-methods/{pm_id}/default must declare pm_id
    let pm_ops = [
        "/paths/~1billing~1payment-methods~1{pm_id}/delete/parameters",
        "/paths/~1billing~1payment-methods~1{pm_id}~1default/post/parameters",
    ];
    for params_ptr in pm_ops {
        let parameters = spec
            .pointer(params_ptr)
            .unwrap_or_else(|| panic!("{params_ptr} must define parameters"))
            .as_array()
            .unwrap_or_else(|| panic!("{params_ptr} must be an array"));

        let pm_id = parameters
            .iter()
            .find(|p| p.get("name").and_then(|v| v.as_str()) == Some("pm_id"))
            .unwrap_or_else(|| panic!("{params_ptr} must contain pm_id parameter"));

        assert_eq!(
            pm_id.pointer("/in").and_then(|v| v.as_str()),
            Some("path"),
            "{params_ptr}: pm_id must be a path parameter"
        );
        assert_eq!(
            pm_id.pointer("/required").and_then(|v| v.as_bool()),
            Some(true),
            "{params_ptr}: pm_id must be required"
        );
        assert_eq!(
            pm_id.pointer("/schema/type").and_then(|v| v.as_str()),
            Some("string"),
            "{params_ptr}: pm_id schema type must be string"
        );
    }
}

// ===========================================================================
// Stage 4 — Index lifecycle, search, configuration, document, and advanced ops
// ===========================================================================

#[test]
fn spec_contains_index_lifecycle_and_search_operations() {
    let spec = common::openapi_spec_json();

    let lifecycle_ops: &[(&str, &str)] = &[
        ("/indexes", "get"),
        ("/indexes", "post"),
        ("/indexes/{name}", "get"),
        ("/indexes/{name}", "delete"),
        ("/indexes/{name}/search", "post"),
        ("/indexes/{name}/replicas", "get"),
        ("/indexes/{name}/replicas", "post"),
        ("/indexes/{name}/replicas/{replica_id}", "delete"),
        ("/indexes/{name}/restore", "post"),
        ("/indexes/{name}/restore-status", "get"),
    ];
    for (path, method) in lifecycle_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            spec.pointer(&pointer).is_some(),
            "spec must contain {method} {path}"
        );
    }
}

#[test]
fn spec_contains_index_lifecycle_schemas() {
    let spec = common::openapi_spec_json();

    let schemas = [
        "CreateIndexRequest",
        "DeleteIndexRequest",
        "SearchRequest",
        "CreateReplicaRequest",
        "IndexResponse",
        "CustomerIndexReplicaSummary",
    ];
    for schema in schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain schema {schema}"
        );
    }
}

#[test]
fn spec_contains_configuration_proxy_operations() {
    let spec = common::openapi_spec_json();

    let config_ops: &[(&str, &str)] = &[
        ("/indexes/{name}/settings", "get"),
        ("/indexes/{name}/settings", "put"),
        ("/indexes/{name}/rules/search", "post"),
        ("/indexes/{name}/rules/{object_id}", "get"),
        ("/indexes/{name}/rules/{object_id}", "put"),
        ("/indexes/{name}/rules/{object_id}", "delete"),
        ("/indexes/{name}/synonyms/search", "post"),
        ("/indexes/{name}/synonyms/{object_id}", "get"),
        ("/indexes/{name}/synonyms/{object_id}", "put"),
        ("/indexes/{name}/synonyms/{object_id}", "delete"),
        ("/indexes/{name}/dictionaries/languages", "get"),
        (
            "/indexes/{name}/dictionaries/{dictionary_name}/search",
            "post",
        ),
        (
            "/indexes/{name}/dictionaries/{dictionary_name}/batch",
            "post",
        ),
        ("/indexes/{name}/dictionaries/settings", "get"),
        ("/indexes/{name}/dictionaries/settings", "put"),
    ];
    for (path, method) in config_ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            spec.pointer(&pointer).is_some(),
            "spec must contain {method} {path}"
        );
    }
}

#[test]
fn spec_contains_configuration_schemas() {
    let spec = common::openapi_spec_json();

    let schemas = ["RulesSearchRequest", "SynonymsSearchRequest"];
    for schema in schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain schema {schema}"
        );
    }
}

#[test]
fn spec_contains_document_and_advanced_operations() {
    let spec = common::openapi_spec_json();

    let ops: &[(&str, &str)] = &[
        ("/indexes/{name}/batch", "post"),
        ("/indexes/{name}/browse", "post"),
        ("/indexes/{name}/objects/{object_id}", "get"),
        ("/indexes/{name}/objects/{object_id}", "delete"),
        ("/indexes/{name}/personalization/strategy", "get"),
        ("/indexes/{name}/personalization/strategy", "put"),
        ("/indexes/{name}/personalization/strategy", "delete"),
        (
            "/indexes/{name}/personalization/profiles/{user_token}",
            "get",
        ),
        (
            "/indexes/{name}/personalization/profiles/{user_token}",
            "delete",
        ),
        ("/indexes/{name}/security/sources", "get"),
        ("/indexes/{name}/security/sources", "post"),
        ("/indexes/{name}/security/sources/{source}", "delete"),
        ("/indexes/{name}/recommendations", "post"),
        ("/indexes/{name}/chat", "post"),
        ("/indexes/{name}/suggestions", "get"),
        ("/indexes/{name}/suggestions", "put"),
        ("/indexes/{name}/suggestions", "delete"),
        ("/indexes/{name}/suggestions/status", "get"),
    ];
    for (path, method) in ops {
        let pointer = format!("/paths/{}/{method}", path.replace('/', "~1"));
        assert!(
            spec.pointer(&pointer).is_some(),
            "spec must contain {method} {path}"
        );
    }
}

#[test]
fn spec_contains_document_schemas() {
    let spec = common::openapi_spec_json();

    let schemas = [
        "BatchDocumentsRequest",
        "BatchDocumentOperation",
        "BrowseDocumentsRequest",
    ];
    for schema in schemas {
        assert!(
            spec.pointer(&format!("/components/schemas/{schema}"))
                .is_some(),
            "spec must contain schema {schema}"
        );
    }
}

#[test]
fn spec_stage4_json_proxy_operations_declare_request_bodies() {
    let spec = common::openapi_spec_json();
    let request_body_ops = ["/paths/~1indexes~1{name}~1settings/put/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1rules~1{object_id}/put/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1synonyms~1{object_id}/put/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1dictionaries~1{dictionary_name}~1search/post/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1dictionaries~1{dictionary_name}~1batch/post/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1dictionaries~1settings/put/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1personalization~1strategy/put/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1security~1sources/post/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1recommendations/post/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1chat/post/requestBody/content/application~1json/schema", "/paths/~1indexes~1{name}~1suggestions/put/requestBody/content/application~1json/schema"];
    let response_body_ops = ["/paths/~1indexes~1{name}~1search/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1replicas/post/responses/201/content/application~1json/schema", "/paths/~1indexes~1{name}~1replicas/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1settings/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1settings/put/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1rules~1search/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1synonyms~1search/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1dictionaries~1languages/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1batch/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1personalization~1strategy/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1security~1sources/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1recommendations/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1chat/post/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1suggestions/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1suggestions~1status/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1restore-status/get/responses/200/content/application~1json/schema", "/paths/~1indexes~1{name}~1restore/post/responses/202/content/application~1json/schema"];
    for request_body_ptr in request_body_ops {
        assert!(
            spec.pointer(request_body_ptr).is_some(),
            "{request_body_ptr} must exist for JSON passthrough endpoints"
        );
    }
    for response_body_ptr in response_body_ops {
        assert!(
            spec.pointer(response_body_ptr).is_some(),
            "{response_body_ptr} must exist for Stage 4 JSON responses"
        );
    }
}

#[test]
fn spec_stage4_delete_operations_document_no_content_status() {
    let spec = common::openapi_spec_json();

    let no_content_ops = [
        "/paths/~1indexes~1{name}/delete/responses/204",
        "/paths/~1indexes~1{name}~1replicas~1{replica_id}/delete/responses/204",
    ];
    for response_ptr in no_content_ops {
        assert!(
            spec.pointer(response_ptr).is_some(),
            "{response_ptr} must be documented as 204 No Content"
        );
    }

    let should_not_have_200 = [
        "/paths/~1indexes~1{name}/delete/responses/200",
        "/paths/~1indexes~1{name}~1replicas~1{replica_id}/delete/responses/200",
    ];
    for response_ptr in should_not_have_200 {
        assert!(
            spec.pointer(response_ptr).is_none(),
            "{response_ptr} must not be documented when the handler returns 204"
        );
    }
}

#[test]
fn spec_stage4_recommendations_and_chat_use_distinct_tags() {
    let spec = common::openapi_spec_json();

    assert_eq!(
        spec.pointer("/paths/~1indexes~1{name}~1recommendations/post/tags/0")
            .and_then(|value| value.as_str()),
        Some("Recommendations"),
        "recommendations endpoint must use the Recommendations tag"
    );
    assert_eq!(
        spec.pointer("/paths/~1indexes~1{name}~1chat/post/tags/0")
            .and_then(|value| value.as_str()),
        Some("Chat"),
        "chat endpoint must use the Chat tag"
    );
}

#[test]
fn spec_stage4_proxy_operations_document_cold_and_not_ready_errors() {
    let spec = common::openapi_spec_json();

    let stage4_proxy_ops = [
        "/paths/~1indexes~1{name}~1search/post",
        "/paths/~1indexes~1{name}~1settings/get",
        "/paths/~1indexes~1{name}~1settings/put",
        "/paths/~1indexes~1{name}~1rules~1search/post",
        "/paths/~1indexes~1{name}~1rules~1{object_id}/get",
        "/paths/~1indexes~1{name}~1rules~1{object_id}/put",
        "/paths/~1indexes~1{name}~1rules~1{object_id}/delete",
        "/paths/~1indexes~1{name}~1synonyms~1search/post",
        "/paths/~1indexes~1{name}~1synonyms~1{object_id}/get",
        "/paths/~1indexes~1{name}~1synonyms~1{object_id}/put",
        "/paths/~1indexes~1{name}~1synonyms~1{object_id}/delete",
        "/paths/~1indexes~1{name}~1dictionaries~1languages/get",
        "/paths/~1indexes~1{name}~1dictionaries~1{dictionary_name}~1search/post",
        "/paths/~1indexes~1{name}~1dictionaries~1{dictionary_name}~1batch/post",
        "/paths/~1indexes~1{name}~1dictionaries~1settings/get",
        "/paths/~1indexes~1{name}~1dictionaries~1settings/put",
        "/paths/~1indexes~1{name}~1batch/post",
        "/paths/~1indexes~1{name}~1browse/post",
        "/paths/~1indexes~1{name}~1objects~1{object_id}/get",
        "/paths/~1indexes~1{name}~1objects~1{object_id}/delete",
        "/paths/~1indexes~1{name}~1personalization~1strategy/get",
        "/paths/~1indexes~1{name}~1personalization~1strategy/put",
        "/paths/~1indexes~1{name}~1personalization~1strategy/delete",
        "/paths/~1indexes~1{name}~1personalization~1profiles~1{user_token}/get",
        "/paths/~1indexes~1{name}~1personalization~1profiles~1{user_token}/delete",
        "/paths/~1indexes~1{name}~1security~1sources/get",
        "/paths/~1indexes~1{name}~1security~1sources/post",
        "/paths/~1indexes~1{name}~1security~1sources~1{source}/delete",
        "/paths/~1indexes~1{name}~1recommendations/post",
        "/paths/~1indexes~1{name}~1chat/post",
        "/paths/~1indexes~1{name}~1suggestions/get",
        "/paths/~1indexes~1{name}~1suggestions/put",
        "/paths/~1indexes~1{name}~1suggestions/delete",
        "/paths/~1indexes~1{name}~1suggestions~1status/get",
    ];

    for operation_ptr in stage4_proxy_ops {
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
// Stage 5 — Boundary and coverage validation
// ===========================================================================

#[test]
fn spec_contains_only_stage_1_through_5_paths() {
    let spec = common::openapi_spec_json();

    let paths = spec
        .get("paths")
        .and_then(|v| v.as_object())
        .expect("spec must have a paths object");

    // Allowed path prefixes for Stages 1–5
    let allowed_prefixes = [
        "/auth/",
        "/onboarding/",
        "/account",
        "/api-keys",
        "/billing/",
        "/health",
        "/docs",
        "/indexes",
        "/usage",
        "/invoices",
        "/pricing",
        "/allyourbase",
        "/migration",
    ];

    // Admin routes are out of scope — must NOT appear
    let forbidden_prefixes = ["/admin"];

    for path in paths.keys() {
        for forbidden in &forbidden_prefixes {
            assert!(
                !path.starts_with(forbidden),
                "spec must not contain {forbidden} paths yet, but found: {path}"
            );
        }

        let is_allowed = allowed_prefixes
            .iter()
            .any(|prefix| path.starts_with(prefix));
        assert!(
            is_allowed,
            "unexpected path in spec: {path} — only Stage 1–5 paths should be registered"
        );
    }

    // Spot-check: key Stage 5 paths must exist
    let required_stage5_paths = [
        "/usage",
        "/usage/daily",
        "/invoices",
        "/invoices/{invoice_id}",
        "/indexes/{name}/analytics/searches",
        "/indexes/{name}/experiments",
        "/indexes/{name}/events/debug",
        "/indexes/{name}/keys",
        "/allyourbase/instances",
        "/migration/algolia/list-indexes",
        "/pricing/compare",
    ];

    for required in &required_stage5_paths {
        assert!(
            paths.contains_key(*required),
            "spec must contain Stage 5 path: {required}"
        );
    }
}

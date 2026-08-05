use std::collections::BTreeSet;

use serde_json::Value;

fn required_fields(spec: &Value, schema_name: &str) -> Vec<String> {
    let mut fields = spec
        .pointer(&format!("/components/schemas/{schema_name}/required"))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{schema_name} must document required fields"))
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

fn assert_required_fields(spec: &Value, schema_name: &str, expected: &[&str]) {
    let mut expected = expected
        .iter()
        .map(|field| field.to_string())
        .collect::<Vec<_>>();
    expected.sort();
    assert_eq!(
        required_fields(spec, schema_name),
        expected,
        "{schema_name} must publish the exact required-field contract"
    );
}

fn schema_properties<'a>(spec: &'a Value, schema_name: &str) -> &'a serde_json::Map<String, Value> {
    spec.pointer(&format!("/components/schemas/{schema_name}/properties"))
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("{schema_name} must document object properties"))
}

fn schema_property<'a>(spec: &'a Value, schema_name: &str, property_name: &str) -> &'a Value {
    schema_properties(spec, schema_name)
        .get(property_name)
        .unwrap_or_else(|| panic!("{schema_name}.{property_name} must be documented"))
}

fn assert_schema_properties(spec: &Value, schema_name: &str, expected: &[&str]) {
    let actual = schema_properties(spec, schema_name)
        .keys()
        .cloned()
        .collect::<BTreeSet<_>>();
    let expected = expected
        .iter()
        .map(|property| property.to_string())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        actual, expected,
        "{schema_name} must publish exactly the expected properties"
    );
}

fn assert_additional_properties_false(spec: &Value, schema_name: &str) {
    assert_eq!(
        spec.pointer(&format!(
            "/components/schemas/{schema_name}/additionalProperties"
        ))
        .and_then(Value::as_bool),
        Some(false),
        "{schema_name} must reject unknown request fields"
    );
}

fn assert_property_type(
    spec: &Value,
    schema_name: &str,
    property_name: &str,
    expected_type: Value,
) {
    assert_eq!(
        schema_property(spec, schema_name, property_name).get("type"),
        Some(&expected_type),
        "{schema_name}.{property_name} must publish the expected JSON type"
    );
}

fn assert_non_negative_nullable_i64_property(spec: &Value, schema_name: &str, property_name: &str) {
    let property = schema_property(spec, schema_name, property_name);
    assert_eq!(
        property.get("type"),
        Some(&serde_json::json!(["integer", "null"])),
        "{schema_name}.{property_name} must be nullable integer metadata"
    );
    assert_eq!(
        property.get("format").and_then(Value::as_str),
        Some("int64"),
        "{schema_name}.{property_name} must preserve producer integer width"
    );
    assert_eq!(
        property.get("minimum").and_then(Value::as_u64),
        Some(0),
        "{schema_name}.{property_name} must reject negative metadata values"
    );
}

fn schema_one_of_variants<'a>(
    spec: &'a Value,
    schema_name: &str,
    property_name: &str,
) -> &'a Vec<Value> {
    schema_property(spec, schema_name, property_name)
        .get("oneOf")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{schema_name}.{property_name} must publish oneOf variants"))
}

fn assert_source_index_created_at_component(spec: &Value) {
    let variants = spec
        .pointer("/components/schemas/SourceIndexCreatedAt/oneOf")
        .and_then(Value::as_array)
        .expect("SourceIndexCreatedAt component must be registered with oneOf variants");
    assert_eq!(
        variants.len(),
        2,
        "SourceIndexCreatedAt must publish exactly string and non-negative int64 variants"
    );
    assert!(
        variants
            .iter()
            .any(|variant| variant.get("type").and_then(Value::as_str) == Some("string")),
        "SourceIndexCreatedAt must accept provider-native string timestamps"
    );
    assert!(
        variants.iter().any(|variant| {
            variant.get("type").and_then(Value::as_str) == Some("integer")
                && variant.get("format").and_then(Value::as_str) == Some("int64")
                && variant.get("minimum").and_then(Value::as_u64) == Some(0)
        }),
        "SourceIndexCreatedAt must accept non-negative int64 timestamps"
    );
}

fn operation_parameter<'a>(
    spec: &'a Value,
    operation_ptr: &str,
    name: &str,
    location: &str,
) -> &'a Value {
    let parameters = spec
        .pointer(&format!("{operation_ptr}/parameters"))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{operation_ptr} must document operation parameters"));
    parameters
        .iter()
        .find(|parameter| {
            parameter.get("name").and_then(Value::as_str) == Some(name)
                && parameter.get("in").and_then(Value::as_str) == Some(location)
        })
        .unwrap_or_else(|| panic!("{operation_ptr} must document {location} parameter {name}"))
}

fn assert_optional_non_negative_i64_query_parameter(spec: &Value, operation_ptr: &str, name: &str) {
    let parameter = operation_parameter(spec, operation_ptr, name, "query");
    assert_eq!(
        parameter.get("required").and_then(Value::as_bool),
        Some(false),
        "{name} query parameter must be optional"
    );
    assert_eq!(
        parameter.pointer("/schema/type").and_then(Value::as_str),
        Some("integer"),
        "{name} query parameter must be an integer"
    );
    assert_eq!(
        parameter.pointer("/schema/format").and_then(Value::as_str),
        Some("int64"),
        "{name} query parameter must preserve producer integer width"
    );
    assert_eq!(
        parameter.pointer("/schema/minimum").and_then(Value::as_u64),
        Some(0),
        "{name} query parameter must reject negative values"
    );
}

#[test]
fn source_discovery_openapi_pins_hosted_request_schema_contracts() {
    let spec = crate::common::openapi_spec_json();

    assert_required_fields(
        &spec,
        "ListMeilisearchIndexesRequest",
        &["apiKey", "endpoint"],
    );
    assert_schema_properties(
        &spec,
        "ListMeilisearchIndexesRequest",
        &["apiKey", "endpoint"],
    );
    assert_additional_properties_false(&spec, "ListMeilisearchIndexesRequest");
    assert_property_type(
        &spec,
        "ListMeilisearchIndexesRequest",
        "apiKey",
        serde_json::json!("string"),
    );
    assert_property_type(
        &spec,
        "ListMeilisearchIndexesRequest",
        "endpoint",
        serde_json::json!("string"),
    );

    assert_required_fields(&spec, "ListTypesenseIndexesRequest", &["apiKey", "node"]);
    assert_schema_properties(&spec, "ListTypesenseIndexesRequest", &["apiKey", "node"]);
    assert_additional_properties_false(&spec, "ListTypesenseIndexesRequest");
    assert_property_type(
        &spec,
        "ListTypesenseIndexesRequest",
        "apiKey",
        serde_json::json!("string"),
    );
    assert_property_type(
        &spec,
        "ListTypesenseIndexesRequest",
        "node",
        serde_json::json!("string"),
    );
}

fn assert_list_source_indexes_response_schema(spec: &Value) {
    assert_required_fields(spec, "ListSourceIndexesResponse", &["indexes"]);
    assert_schema_properties(
        spec,
        "ListSourceIndexesResponse",
        &["indexes", "limit", "offset", "total"],
    );
    assert_eq!(
        schema_property(spec, "ListSourceIndexesResponse", "indexes").get("type"),
        Some(&serde_json::json!("array")),
        "ListSourceIndexesResponse.indexes must be an array"
    );
    assert_eq!(
        schema_property(spec, "ListSourceIndexesResponse", "indexes")
            .pointer("/items/$ref")
            .and_then(Value::as_str),
        Some("#/components/schemas/SourceIndexSummary"),
        "ListSourceIndexesResponse.indexes must contain SourceIndexSummary entries"
    );
    for property_name in ["limit", "offset", "total"] {
        assert_non_negative_nullable_i64_property(spec, "ListSourceIndexesResponse", property_name);
    }
}

fn assert_source_index_summary_schema(spec: &Value) {
    assert_required_fields(
        spec,
        "SourceIndexSummary",
        &[
            "createdAt",
            "defaultSortingField",
            "documentCount",
            "entries",
            "name",
            "primaryKey",
            "updatedAt",
        ],
    );
    assert_schema_properties(
        spec,
        "SourceIndexSummary",
        &[
            "createdAt",
            "defaultSortingField",
            "documentCount",
            "entries",
            "name",
            "primaryKey",
            "updatedAt",
        ],
    );
    assert_property_type(
        spec,
        "SourceIndexSummary",
        "name",
        serde_json::json!("string"),
    );
    assert_property_type(
        spec,
        "SourceIndexSummary",
        "primaryKey",
        serde_json::json!(["string", "null"]),
    );
    assert_property_type(
        spec,
        "SourceIndexSummary",
        "updatedAt",
        serde_json::json!(["string", "null"]),
    );
    assert_property_type(
        spec,
        "SourceIndexSummary",
        "defaultSortingField",
        serde_json::json!(["string", "null"]),
    );
    assert_non_negative_nullable_i64_property(spec, "SourceIndexSummary", "entries");
    assert_non_negative_nullable_i64_property(spec, "SourceIndexSummary", "documentCount");
}

fn assert_source_index_summary_created_at_schema(spec: &Value) {
    let created_at_one_of = schema_one_of_variants(spec, "SourceIndexSummary", "createdAt");
    assert_eq!(
        created_at_one_of.len(),
        2,
        "SourceIndexSummary.createdAt must publish exactly null and source-created-at variants"
    );
    assert!(
        created_at_one_of
            .iter()
            .any(|variant| variant.get("type").and_then(Value::as_str) == Some("null")),
        "SourceIndexSummary.createdAt must remain nullable"
    );
    assert!(
        created_at_one_of
            .iter()
            .any(|variant| variant.get("$ref").and_then(Value::as_str)
                == Some("#/components/schemas/SourceIndexCreatedAt")),
        "SourceIndexSummary.createdAt must preserve provider-native created-at values"
    );
    assert_source_index_created_at_component(spec);
}

#[test]
fn source_discovery_openapi_pins_hosted_response_schema_contracts() {
    let spec = crate::common::openapi_spec_json();

    assert_list_source_indexes_response_schema(&spec);
    assert_source_index_summary_schema(&spec);
    assert_source_index_summary_created_at_schema(&spec);
}

#[test]
fn source_discovery_openapi_publishes_hosted_pagination_query_contract() {
    let spec = crate::common::openapi_spec_json();
    let operation_ptr = "/paths/~1migration~1{source_provider}~1list-indexes/post";

    assert_optional_non_negative_i64_query_parameter(&spec, operation_ptr, "offset");
    assert_optional_non_negative_i64_query_parameter(&spec, operation_ptr, "limit");
}

#[test]
fn source_discovery_openapi_publishes_json_media_type_error_contract() {
    let spec = crate::common::openapi_spec_json();
    let operation_ptr = "/paths/~1migration~1{source_provider}~1list-indexes/post";

    assert_eq!(
        spec.pointer(&format!(
            "{operation_ptr}/responses/415/content/application~1json/schema/$ref"
        ))
        .and_then(Value::as_str),
        Some("#/components/schemas/MigrationErrorResponse"),
        "list-indexes must publish coded 415 MigrationErrorResponse for non-JSON requests"
    );
}

//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/src/routes/indexes/mod.rs.
use axum::extract::{Path, RawQuery, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::{Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::models::resource_vector::ResourceVector;
use crate::models::tenant::CustomerTenantSummary;
use crate::models::vm_inventory::VmInventory;
use crate::models::BillingPlan;
use crate::repos::advisory_lock::{advisory_lock, auto_provision_lock_key};
use crate::secrets::NodeSecretError;
use crate::services::placement::{place_index, VmWithLoad};
use crate::services::replica::ReplicaError;
use crate::services::tenant_quota::ResolvedQuota;
use crate::state::AppState;
use crate::validation::{
    validate_length, validate_path_segment, MAX_ACL_ENTRIES, MAX_DESCRIPTION_LEN,
    MAX_SEARCH_QUERY_LEN,
};

// ---------------------------------------------------------------------------
// Domain modules
// ---------------------------------------------------------------------------

pub(crate) mod analytics;
pub(crate) mod chat;
pub(crate) mod debug;
pub(crate) mod dictionaries;
pub(crate) mod documents;
pub(crate) mod experiments;
pub(crate) mod lifecycle;
pub(crate) mod personalization;
pub(crate) mod recommendations;
pub(crate) mod rules;
pub(crate) mod search;
pub(crate) mod security_sources;
pub(crate) mod settings;
mod shared_vm;
pub(crate) mod suggestions;
pub(crate) mod synonyms;

pub(crate) const RESERVED_NAMES: &[&str] = &["_internal", "health", "metrics"];

pub use crate::scopes::VALID_ACLS;
pub(crate) const MAX_ANALYTICS_DAYS: i64 = 90;
pub(crate) const MAX_ANALYTICS_LIMIT: u32 = 1000;

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CreateIndexRequest {
    pub name: String,
    pub region: String,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct DeleteIndexRequest {
    #[serde(default)]
    pub confirm: bool,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
/// Search query with extensible parameters. Additional fields beyond `query`
/// (e.g. page, hitsPerPage, facets) are forwarded to the search engine via serde flatten.
pub struct SearchRequest {
    /// The search query string (required).
    pub query: String,
    /// Additional search parameters (page, hitsPerPage, facets, etc.)
    /// forwarded to flapjack as-is.
    #[serde(flatten)]
    #[schema(value_type = Object)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CreateKeyRequest {
    pub description: String,
    pub acl: Vec<String>,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub struct CreateReplicaRequest {
    pub region: String,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct IndexResponse {
    pub name: String,
    pub region: String,
    pub endpoint: Option<String>,
    pub entries: u64,
    pub data_size_bytes: u64,
    pub status: String,
    pub tier: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_accessed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cold_since: Option<String>,
    pub created_at: String,
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Validate an index name against naming rules.
///
/// Accepts 1-64 characters: alphanumeric start/end, interior may include
/// hyphens and underscores. Rejects reserved names (`_internal`, `health`,
/// `metrics`).
pub fn validate_index_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty() || name.len() > 64 {
        return Err(ApiError::BadRequest(
            "index name must be between 1 and 64 characters".into(),
        ));
    }

    if RESERVED_NAMES.contains(&name) {
        return Err(ApiError::BadRequest(format!(
            "'{name}' is a reserved name and cannot be used"
        )));
    }

    // Single char: must be alphanumeric
    if name.len() == 1 {
        if !name.chars().next().unwrap().is_ascii_alphanumeric() {
            return Err(ApiError::BadRequest(
                "index name must start and end with an alphanumeric character".into(),
            ));
        }
        return Ok(());
    }

    // Multi-char: must start and end with alphanumeric, middle can include hyphens and underscores
    let chars: Vec<char> = name.chars().collect();
    if !chars[0].is_ascii_alphanumeric() || !chars[chars.len() - 1].is_ascii_alphanumeric() {
        return Err(ApiError::BadRequest(
            "index name must start and end with an alphanumeric character".into(),
        ));
    }

    for ch in &chars {
        if !ch.is_ascii_alphanumeric() && *ch != '-' && *ch != '_' {
            return Err(ApiError::BadRequest(
                "index name can only contain alphanumeric characters, hyphens, and underscores"
                    .into(),
            ));
        }
    }

    Ok(())
}

pub(crate) struct ResolvedFlapjackTarget {
    pub flapjack_url: String,
    pub node_id: String,
    pub region: String,
    /// Tenant-scoped index UID sent to flapjack. Different tenants with the same
    /// customer-facing index name get distinct flapjack UIDs so their data never
    /// bleeds across tenants on a shared VM.
    pub flapjack_uid: String,
}

/// Build the flapjack-side index UID that isolates same-name indexes across
/// tenants. Format: `{customer_id_hex}_{index_name}` — deterministic,
/// collision-free, and uses only characters valid in flapjack index UIDs.
pub(crate) fn flapjack_index_uid(customer_id: Uuid, index_name: &str) -> String {
    crate::services::flapjack_node::flapjack_index_uid(customer_id, index_name)
}

pub(crate) fn shared_vm_secret_id(vm: &VmInventory) -> &str {
    vm.node_secret_id()
}

pub(crate) fn is_missing_node_secret_error(error: &NodeSecretError) -> bool {
    crate::services::flapjack_node::is_missing_node_secret_error(error)
}

/// Determine the flapjack node ID to use when proxying through a shared VM.
///
/// Prefers the shared VM's own `node_secret_id` when its admin key exists in
/// the secret backend; falls back to the deployment's `node_id` when the key
/// is missing or the lookup fails, so requests still route through the
/// deployment-level credential.
pub(crate) async fn resolve_shared_vm_proxy_node_id(
    state: &AppState,
    vm: &VmInventory,
    deployment: &crate::models::Deployment,
) -> String {
    let shared_secret_id = shared_vm_secret_id(vm);
    match state
        .provisioning_service
        .node_secret_manager
        .get_node_api_key(shared_secret_id, &deployment.region)
        .await
    {
        Ok(_) => shared_secret_id.to_string(),
        Err(error) if is_missing_node_secret_error(&error) => deployment.node_id.clone(),
        Err(_) => deployment.node_id.clone(),
    }
}

/// Look up the per-index quota for rate-limit enforcement.
///
/// Returns a cached quota when available; otherwise loads the tenant's
/// `resource_quota` JSON from the database, resolves it through the
/// `tenant_quota_service`, and populates the cache for subsequent calls.
/// Indexes that have no tenant row yet receive the service-wide defaults.
pub(crate) async fn resolve_index_quota(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<ResolvedQuota, ApiError> {
    if let Some(cached) = state
        .tenant_quota_service
        .get_cached_quota(customer_id, index_name)
    {
        return Ok(cached);
    }

    let tenant = state.tenant_repo.find_raw(customer_id, index_name).await?;
    let resolved = match tenant {
        Some(tenant) => {
            let resolved = state
                .tenant_quota_service
                .resolve_quota(&tenant.resource_quota);
            state
                .tenant_quota_service
                .cache_quota(customer_id, index_name, resolved.clone());
            resolved
        }
        None => state
            .tenant_quota_service
            .resolve_quota(&serde_json::Value::Null),
    };

    Ok(resolved)
}

fn has_quota_override(quota: &serde_json::Value) -> bool {
    quota.as_object().is_some_and(|fields| !fields.is_empty())
}

/// Resolve the customer-level quota override currently represented by their
/// tenant rows.
///
/// Quota data is stored on individual tenant rows, but the admin quotas API
/// applies the same override across every index a customer owns. Create-index
/// needs that effective customer-wide value before the new tenant row exists,
/// so we reuse the first non-empty override we find and warn if the customer's
/// rows disagree.
pub(crate) async fn resolve_customer_quota_override(
    state: &AppState,
    customer_id: Uuid,
) -> Result<Option<serde_json::Value>, ApiError> {
    let tenants = state.tenant_repo.list_raw_by_customer(customer_id).await?;

    let mut non_empty_overrides = tenants
        .into_iter()
        .map(|tenant| tenant.resource_quota)
        .filter(has_quota_override)
        .collect::<Vec<_>>();

    let Some(first_override) = non_empty_overrides.pop() else {
        return Ok(None);
    };

    if non_empty_overrides
        .iter()
        .any(|override_quota| override_quota != &first_override)
    {
        tracing::warn!(
            customer_id = %customer_id,
            "customer has inconsistent per-index quota overrides; reusing one existing override for new index"
        );
    }

    Ok(Some(first_override))
}

/// Resolve the effective quota used for customer-wide index-count enforcement.
///
/// New indexes do not have a tenant row yet, so customer-wide create limits
/// must be derived from the override already applied to the customer's
/// existing indexes, falling back to service defaults when none exist.
pub(crate) async fn resolve_customer_quota(
    state: &AppState,
    customer_id: Uuid,
) -> Result<ResolvedQuota, ApiError> {
    let override_quota = resolve_customer_quota_override(state, customer_id).await?;
    Ok(state
        .tenant_quota_service
        .resolve_quota(&override_quota.unwrap_or(serde_json::Value::Null)))
}

/// Resolve the flapjack URL, node ID, region, and tenant-scoped UID needed
/// to proxy a request for a specific index.
///
/// Returns `None` when the index is not yet placed on a shared VM (still
/// provisioning) or references a missing `vm_inventory` / deployment row —
/// callers should treat `None` as "endpoint not ready".
pub(crate) async fn resolve_flapjack_target(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    deployment_id: Uuid,
) -> Result<Option<ResolvedFlapjackTarget>, ApiError> {
    let raw_tenant = state.tenant_repo.find_raw(customer_id, index_name).await?;
    let vm_id = match raw_tenant.and_then(|t| t.vm_id) {
        Some(id) => id,
        None => return Ok(None), // Not yet placed on a shared VM (still provisioning)
    };

    let vm = match state.vm_inventory_repo.get(vm_id).await? {
        Some(vm) => vm,
        None => {
            tracing::warn!(
                customer_id = %customer_id,
                index_name = %index_name,
                vm_id = %vm_id,
                "tenant references missing vm_inventory row; treating endpoint as not ready"
            );
            return Ok(None);
        }
    };

    let deployment = match state.deployment_repo.find_by_id(deployment_id).await? {
        Some(deployment) => deployment,
        None => {
            tracing::warn!(
                customer_id = %customer_id,
                index_name = %index_name,
                deployment_id = %deployment_id,
                "tenant references missing deployment row; treating endpoint as not ready"
            );
            return Ok(None);
        }
    };

    let node_id = resolve_shared_vm_proxy_node_id(state, &vm, &deployment).await;
    let flapjack_url = vm.flapjack_url;

    Ok(Some(ResolvedFlapjackTarget {
        flapjack_url,
        node_id,
        region: deployment.region,
        flapjack_uid: flapjack_index_uid(customer_id, index_name),
    }))
}

#[derive(Clone, Copy)]
pub(crate) enum IndexNotReadyBehavior {
    BadRequest,
    ServiceUnavailable,
}

impl IndexNotReadyBehavior {
    fn into_error(self, _index_name: &str) -> ApiError {
        match self {
            Self::BadRequest => ApiError::BadRequest("endpoint not ready yet".into()),
            Self::ServiceUnavailable => {
                ApiError::ServiceUnavailable("endpoint not ready yet".into())
            }
        }
    }
}

pub(crate) async fn find_active_index_summary(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<CustomerTenantSummary, ApiError> {
    let summary = state
        .tenant_repo
        .find_by_name(customer_id, index_name)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("index '{index_name}' not found")))?;

    reject_cold_tier(&summary.tier, index_name)?;

    Ok(summary)
}

pub(crate) async fn resolve_ready_index_target(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    not_ready_behavior: IndexNotReadyBehavior,
) -> Result<(CustomerTenantSummary, ResolvedFlapjackTarget), ApiError> {
    let summary = find_active_index_summary(state, customer_id, index_name).await?;
    let target = resolve_flapjack_target(state, customer_id, index_name, summary.deployment_id)
        .await?
        .ok_or_else(|| not_ready_behavior.into_error(index_name))?;

    Ok((summary, target))
}

pub(crate) fn reject_cold_tier(tier: &str, index_name: &str) -> Result<(), ApiError> {
    match tier {
        "cold" => Err(ApiError::Gone(format!(
            "Index '{index_name}' is in cold storage. Restore it before accessing settings or data."
        ))),
        "restoring" => Err(ApiError::ServiceUnavailable(format!(
            "Index '{index_name}' is being restored from cold storage."
        ))),
        _ => Ok(()),
    }
}

pub(crate) fn parse_query_pairs(raw_query: Option<&str>) -> Vec<(String, String)> {
    raw_query
        .unwrap_or("")
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let mut parts = pair.splitn(2, '=');
            let key = decode_query_component(parts.next().unwrap_or_default());
            let value = decode_query_component(parts.next().unwrap_or_default());
            (key, value)
        })
        .collect()
}

pub(crate) fn encode_query_pairs(params: &[(String, String)]) -> String {
    params
        .iter()
        .map(|(key, value)| {
            format!(
                "{}={}",
                encode_query_component(key),
                encode_query_component(value)
            )
        })
        .collect::<Vec<String>>()
        .join("&")
}

/// Percent-decode a single query-string component (`+` → space, `%XX` → byte).
///
/// Malformed `%` sequences are passed through literally. The result is
/// lossily converted to UTF-8 so callers never see decode panics.
fn decode_query_component(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                if let (Some(high), Some(low)) =
                    (hex_nibble(bytes[i + 1]), hex_nibble(bytes[i + 2]))
                {
                    out.push((high << 4) | low);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }

    String::from_utf8_lossy(&out).into_owned()
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// Percent-encode a single query-string component (RFC 3986 unreserved set).
///
/// Spaces are encoded as `+`; all other non-unreserved bytes become `%XX`.
fn encode_query_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            b' ' => out.push('+'),
            _ => {
                out.push('%');
                out.push_str(&format!("{byte:02X}"));
            }
        }
    }
    out
}

pub(crate) fn default_hits_per_page() -> usize {
    50
}

fn rate_limited_response(message: String, retry_after: u64) -> Response {
    (
        StatusCode::TOO_MANY_REQUESTS,
        [(header::RETRY_AFTER, retry_after.to_string())],
        Json(serde_json::json!({ "error": message })),
    )
        .into_response()
}

/// Check the per-index query rate limit and return a 429 response if exceeded.
///
/// Returns `Ok(Some(response))` with a `Retry-After` header when the limit
/// is hit, or `Ok(None)` when the request may proceed. The quota is resolved
/// via [`resolve_index_quota`], which caches per-index limits.
pub(crate) async fn enforce_query_rate_limit(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<Option<Response>, ApiError> {
    let quota = resolve_index_quota(state, customer_id, index_name).await?;
    if let Err(exceeded) =
        state
            .tenant_quota_service
            .check_query_rate(customer_id, index_name, &quota)
    {
        return Ok(Some(rate_limited_response(
            format!("query rate limit exceeded for index '{index_name}'"),
            exceeded.retry_after,
        )));
    }
    Ok(None)
}

/// Check the per-index write rate limit and return a 429 response if exceeded.
///
/// Mirrors [`enforce_query_rate_limit`] but checks the write window. Used by
/// document mutation, index creation/deletion, and key creation handlers.
pub(crate) async fn enforce_write_rate_limit(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
) -> Result<Option<Response>, ApiError> {
    let quota = resolve_index_quota(state, customer_id, index_name).await?;
    if let Err(exceeded) =
        state
            .tenant_quota_service
            .check_write_rate(customer_id, index_name, &quota)
    {
        return Ok(Some(rate_limited_response(
            format!("write rate limit exceeded for index '{index_name}'"),
            exceeded.retry_after,
        )));
    }
    Ok(None)
}

// ---------------------------------------------------------------------------
// Public re-exports
// ---------------------------------------------------------------------------

pub use analytics::{
    get_analytics_no_result_rate, get_analytics_no_results, get_analytics_searches,
    get_analytics_searches_count, get_analytics_status,
};
pub use chat::chat;
pub use debug::get_debug_events;
pub use dictionaries::{
    batch_dictionary_entries, get_dictionary_languages, get_dictionary_settings,
    save_dictionary_settings, search_dictionary_entries,
};
pub use documents::{
    batch_documents, browse_documents, delete_document, get_document, BatchDocumentOperation,
    BatchDocumentsRequest, BrowseDocumentsRequest,
};
pub use experiments::{
    conclude_experiment, create_experiment, delete_experiment, get_experiment,
    get_experiment_results, list_experiments, start_experiment, stop_experiment, update_experiment,
};
pub use lifecycle::{
    create_index, create_key, create_replica, delete_index, delete_replica, get_index,
    list_indexes, list_replicas, restore_index, restore_status,
};
pub use personalization::{
    delete_personalization_profile, delete_personalization_strategy, get_personalization_profile,
    get_personalization_strategy, save_personalization_strategy,
};
pub use recommendations::recommend;
pub use rules::{delete_rule, get_rule, save_rule, search_rules, RulesSearchRequest};
pub use search::test_search;
pub use security_sources::{append_security_source, delete_security_source, get_security_sources};
pub use settings::{get_settings, update_settings};
pub use suggestions::{delete_qs_config, get_qs_config, get_qs_status, save_qs_config};
pub use synonyms::{
    delete_synonym, get_synonym, save_synonym, search_synonyms, SynonymsSearchRequest,
};

#[cfg(test)]
mod tests {
    use super::*;

    fn is_ok(name: &str) -> bool {
        validate_index_name(name).is_ok()
    }

    fn is_err(name: &str) -> bool {
        validate_index_name(name).is_err()
    }

    #[test]
    fn valid_single_char() {
        assert!(is_ok("a"));
        assert!(is_ok("Z"));
        assert!(is_ok("0"));
    }

    #[test]
    fn valid_simple_names() {
        assert!(is_ok("products"));
        assert!(is_ok("my-index"));
        assert!(is_ok("user_data"));
        assert!(is_ok("a1"));
        assert!(is_ok("my-index-2"));
        assert!(is_ok("test_index_v3"));
    }

    #[test]
    fn valid_max_length() {
        // 64 alphanumeric chars
        let name = "a".repeat(64);
        assert!(is_ok(&name));
    }

    #[test]
    fn rejects_empty() {
        assert!(is_err(""));
    }

    #[test]
    fn rejects_too_long() {
        let name = "a".repeat(65);
        assert!(is_err(&name));
    }

    #[test]
    fn rejects_reserved_names() {
        assert!(is_err("_internal"));
        assert!(is_err("health"));
        assert!(is_err("metrics"));
    }

    #[test]
    fn rejects_leading_hyphen() {
        assert!(is_err("-bad"));
    }

    #[test]
    fn rejects_trailing_hyphen() {
        assert!(is_err("bad-"));
    }

    #[test]
    fn rejects_leading_underscore() {
        assert!(is_err("_bad"));
    }

    #[test]
    fn rejects_trailing_underscore() {
        assert!(is_err("bad_"));
    }

    #[test]
    fn rejects_special_characters() {
        assert!(is_err("my index"));
        assert!(is_err("my.index"));
        assert!(is_err("my/index"));
        assert!(is_err("my@index"));
    }

    #[test]
    fn rejects_single_non_alphanumeric() {
        assert!(is_err("-"));
        assert!(is_err("_"));
        assert!(is_err("."));
    }

    #[test]
    fn parse_query_pairs_decodes_percent_encoded_keys_and_values() {
        let params = parse_query_pairs(Some("ind%65x=tenant-a&query=hello%20world"));
        assert_eq!(
            params,
            vec![
                ("index".to_string(), "tenant-a".to_string()),
                ("query".to_string(), "hello world".to_string())
            ]
        );
    }

    #[test]
    fn encode_query_pairs_percent_encodes_reserved_chars() {
        let encoded = encode_query_pairs(&[
            ("indexPrefix".to_string(), "my index".to_string()),
            ("filter".to_string(), "name=a&b".to_string()),
        ]);
        assert_eq!(encoded, "indexPrefix=my+index&filter=name%3Da%26b");
    }
}

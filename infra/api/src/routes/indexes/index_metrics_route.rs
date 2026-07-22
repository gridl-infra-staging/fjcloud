use std::collections::HashMap;

use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::{ApiError, ErrorResponse};
use crate::services::engine_index_identity_observer::{
    record_physical_caller, PhysicalCallerObservation,
};
use crate::services::flapjack_node::FLAPJACK_APP_ID_VALUE;
use crate::services::prometheus_parser::{
    extract_label, parse_metrics, DOCUMENTS_COUNT, DOCUMENTS_INDEXED_TOTAL, SEARCH_REQUESTS_TOTAL,
    STORAGE_BYTES,
};
use crate::state::{AppState, CustomerIndexMetricsResponse};

/// Sum all samples for `metric_name` where the `index` label equals `target_uid`.
fn sum_metric_for_uid(
    metrics: &HashMap<String, HashMap<String, f64>>,
    metric_name: &str,
    target_uid: &str,
) -> f64 {
    let Some(series) = metrics.get(metric_name) else {
        return 0.0;
    };
    series
        .iter()
        .filter(|(labels, _)| extract_label(labels, "index").as_deref() == Some(target_uid))
        .map(|(_, value)| value)
        .sum()
}

fn safe_u64(value: f64) -> u64 {
    if !value.is_finite() || value <= 0.0 {
        return 0;
    }
    value.floor() as u64
}

fn customer_metrics_response_from_metrics(
    index_name: &str,
    target_uid: &str,
    metrics: &HashMap<String, HashMap<String, f64>>,
    fetched_at: DateTime<Utc>,
) -> CustomerIndexMetricsResponse {
    CustomerIndexMetricsResponse {
        index: index_name.to_string(),
        documents_count: safe_u64(sum_metric_for_uid(metrics, DOCUMENTS_COUNT, target_uid)),
        storage_bytes: safe_u64(sum_metric_for_uid(metrics, STORAGE_BYTES, target_uid)),
        search_requests_total: safe_u64(sum_metric_for_uid(
            metrics,
            SEARCH_REQUESTS_TOTAL,
            target_uid,
        )),
        write_operations_total: safe_u64(sum_metric_for_uid(
            metrics,
            DOCUMENTS_INDEXED_TOTAL,
            target_uid,
        )),
        fetched_at,
    }
}

pub(crate) async fn load_customer_index_metrics(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    target: &super::ResolvedFlapjackTarget,
    physical_caller_id: &str,
) -> Result<CustomerIndexMetricsResponse, ApiError> {
    if let Some(cached) = state.metrics_cache.get(customer_id, index_name) {
        return Ok(cached);
    }

    let (text, auth_header_value) = state
        .flapjack_proxy
        .fetch_metrics_text_with_auth_observation(
            &target.flapjack_url,
            &target.node_id,
            &target.region,
        )
        .await?;
    record_physical_caller(
        physical_caller_id,
        PhysicalCallerObservation {
            physical_uid: &target.flapjack_uid,
            logical_uid: index_name,
            node_secret_id: &target.node_id,
            auth_secret_id: &target.node_id,
            auth_header_value: &auth_header_value,
            upstream_path: "/metrics",
            application_id: FLAPJACK_APP_ID_VALUE,
            http_status: 200,
        },
    );

    let metrics = parse_metrics(&text);
    let response = customer_metrics_response_from_metrics(
        index_name,
        &target.flapjack_uid,
        &metrics,
        Utc::now(),
    );

    state
        .metrics_cache
        .insert(customer_id, index_name, response.clone());

    Ok(response)
}

/// `GET /indexes/{name}/metrics` — customer-facing index metrics.
///
/// Returns aggregated metrics for a single index, filtered to the
/// authenticated tenant's flapjack UID. Responses are cached per
/// `(customer_id, index_name)` with a configurable TTL.
#[utoipa::path(
    get,
    path = "/indexes/{name}/metrics",
    tag = "Index Metrics",
    params(("name" = String, Path, description = "Index name")),
    responses(
        (status = 200, description = "Index metrics", body = CustomerIndexMetricsResponse),
        (status = 401, description = "Authentication required", body = ErrorResponse),
        (status = 404, description = "Index not found", body = ErrorResponse),
        (status = 503, description = "Backend temporarily unavailable", body = ErrorResponse),
    )
)]
pub async fn get_index_metrics(
    auth: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, target) = super::resolve_ready_index_target(
        &state,
        auth.customer_id,
        &name,
        super::IndexNotReadyBehavior::ServiceUnavailable,
    )
    .await?;

    let response = load_customer_index_metrics(
        &state,
        auth.customer_id,
        &name,
        &target,
        "routes.indexes.index_metrics_route.get_index_metrics",
    )
    .await?;

    Ok(Json(response))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_with_uid(uid: &str) -> String {
        format!(
            "flapjack_documents_count{{index=\"{uid}\",shard=\"0\"}} 100\n\
             flapjack_documents_count{{index=\"{uid}\",shard=\"1\"}} 250\n\
             flapjack_documents_count{{index=\"other\"}} 9999\n\
             flapjack_storage_bytes{{index=\"{uid}\",tier=\"hot\"}} 500\n\
             flapjack_storage_bytes{{index=\"{uid}\",tier=\"warm\"}} 300\n\
             flapjack_documents_indexed_total{{index=\"{uid}\"}} 42\n\
             flapjack_search_requests_total{{index=\"{uid}\"}} 77\n"
        )
    }

    #[test]
    fn filter_keeps_only_target_uid() {
        let metrics = parse_metrics(&fixture_with_uid("my-uid"));
        let count = sum_metric_for_uid(&metrics, DOCUMENTS_COUNT, "my-uid");
        assert_eq!(count, 350.0);

        let other = sum_metric_for_uid(&metrics, DOCUMENTS_COUNT, "other");
        assert_eq!(other, 9999.0);
    }

    #[test]
    fn sums_across_label_dimensions() {
        let metrics = parse_metrics(&fixture_with_uid("my-uid"));
        let storage = sum_metric_for_uid(&metrics, STORAGE_BYTES, "my-uid");
        assert_eq!(storage, 800.0);
    }

    #[test]
    fn absent_metric_defaults_to_zero() {
        let metrics = parse_metrics(&fixture_with_uid("my-uid"));
        let missing = sum_metric_for_uid(&metrics, "flapjack_nonexistent", "my-uid");
        assert_eq!(missing, 0.0);

        let wrong_uid = sum_metric_for_uid(&metrics, DOCUMENTS_COUNT, "absent-uid");
        assert_eq!(wrong_uid, 0.0);
    }

    #[test]
    fn field_mapping_documents_indexed_to_write_operations() {
        let metrics = parse_metrics(&fixture_with_uid("my-uid"));
        let write_ops = sum_metric_for_uid(&metrics, DOCUMENTS_INDEXED_TOTAL, "my-uid");
        assert_eq!(write_ops, 42.0);
        assert_eq!(safe_u64(write_ops), 42);
    }

    #[test]
    fn customer_metrics_response_filters_target_uid_and_floors_invalid_values() {
        let metrics = parse_metrics(
            "flapjack_documents_count{index=\"my-uid\"} 12.9\n\
             flapjack_documents_count{index=\"other\"} 999\n\
             flapjack_storage_bytes{index=\"my-uid\"} -99\n\
             flapjack_search_requests_total{index=\"my-uid\"} NaN\n\
             flapjack_documents_indexed_total{index=\"my-uid\"} 4.8\n",
        );

        let fetched_at = Utc::now();
        let response =
            customer_metrics_response_from_metrics("products", "my-uid", &metrics, fetched_at);

        assert_eq!(response.index, "products");
        assert_eq!(response.documents_count, 12);
        assert_eq!(response.storage_bytes, 0);
        assert_eq!(response.search_requests_total, 0);
        assert_eq!(response.write_operations_total, 4);
        assert_eq!(response.fetched_at, fetched_at);
    }

    #[test]
    fn safe_u64_floors_invalid_non_positive_and_fractional_values() {
        assert_eq!(safe_u64(f64::NAN), 0);
        assert_eq!(safe_u64(f64::INFINITY), 0);
        assert_eq!(safe_u64(-1.0), 0);
        assert_eq!(safe_u64(0.0), 0);
        assert_eq!(safe_u64(9.99), 9);
    }
}

//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/prometheus_parser.rs.
use std::collections::HashMap;

use crate::models::resource_vector::ResourceVector;

const SEARCH_REQUESTS_TOTAL: &str = "flapjack_search_requests_total";
const DOCUMENTS_INDEXED_TOTAL: &str = "flapjack_documents_indexed_total";
const DOCUMENTS_COUNT: &str = "flapjack_documents_count";
const STORAGE_BYTES: &str = "flapjack_storage_bytes";
const MEMORY_HEAP_BYTES: &str = "flapjack_memory_heap_bytes";

/// Parse Prometheus exposition format text into a nested map:
/// metric_name → {label_set → value}
///
/// Label set is represented as a sorted comma-separated string of `key=value` pairs,
/// e.g. `index=products,method=search`. Metrics without labels use an empty string key.
///
/// Only handles GAUGE/COUNTER/UNTYPED lines. Ignores HELP, TYPE, and comment lines.
pub fn parse_metrics(text: &str) -> HashMap<String, HashMap<String, f64>> {
    let mut result: HashMap<String, HashMap<String, f64>> = HashMap::new();

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some((metric_name, labels, value)) = parse_line(line) {
            result.entry(metric_name).or_default().insert(labels, value);
        }
    }

    result
}

/// Parse a single metric line like:
/// `flapjack_search_requests_total{index="products"} 12345.0`
/// Returns (metric_name, label_string, value)
fn parse_line(line: &str) -> Option<(String, String, f64)> {
    // Prometheus samples are: `<metric>{labels} <value> [timestamp]`.
    // We parse the metric + value and ignore the optional timestamp.
    let mut parts = line.split_whitespace();
    let name_labels = parts.next()?.trim();
    let value: f64 = parts.next()?.trim().parse().ok()?;

    if let Some(brace_start) = name_labels.find('{') {
        let metric_name = name_labels[..brace_start].to_string();
        let brace_end = name_labels.rfind('}')?;
        let labels_str = &name_labels[brace_start + 1..brace_end];
        let labels = normalize_labels(labels_str);
        Some((metric_name, labels, value))
    } else {
        // No labels
        Some((name_labels.to_string(), String::new(), value))
    }
}

/// Normalize label pairs into a sorted, canonical string.
/// Input: `index="products",method="search"`
/// Output: `index=products,method=search`
fn normalize_labels(labels_str: &str) -> String {
    let mut pairs: Vec<(String, String)> = Vec::new();

    for pair in split_label_pairs(labels_str) {
        if let Some((key, value)) = pair.split_once('=') {
            let key = key.trim().to_string();
            let value = value.trim().trim_matches('"').to_string();
            pairs.push((key, value));
        }
    }

    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join(",")
}

/// Split label string by commas, respecting quoted values.
fn split_label_pairs(s: &str) -> Vec<String> {
    let mut pairs = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for ch in s.chars() {
        match ch {
            '"' => {
                in_quotes = !in_quotes;
                current.push(ch);
            }
            ',' if !in_quotes => {
                let trimmed = current.trim().to_string();
                if !trimmed.is_empty() {
                    pairs.push(trimmed);
                }
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    let trimmed = current.trim().to_string();
    if !trimmed.is_empty() {
        pairs.push(trimmed);
    }

    pairs
}

/// Extract a specific label value from the label string.
/// E.g., `extract_label("index=products,method=search", "index")` → Some("products")
pub fn extract_label(label_str: &str, key: &str) -> Option<String> {
    for pair in label_str.split(',') {
        if let Some((k, v)) = pair.split_once('=') {
            if k.trim() == key {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

pub type CounterSnapshot = HashMap<String, f64>;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ResourceVectorExtraction {
    pub vectors: HashMap<String, ResourceVector>,
    pub next_counters: CounterSnapshot,
}

pub fn counter_snapshot_key(metric_name: &str, index_name: &str) -> String {
    format!("{metric_name}:{index_name}")
}

/// Build per-index resource vectors from parsed Prometheus metrics.
///
/// - query/indexing RPS are derived from counter deltas against `previous_counters`
/// - memory is approximated by doc-count ratio from system-wide heap bytes
/// - disk bytes may be overridden by `/internal/storage` payload values
pub fn extract_resource_vectors(
    metrics: &HashMap<String, HashMap<String, f64>>,
    storage_bytes_override: Option<&HashMap<String, u64>>,
    previous_counters: &CounterSnapshot,
    scrape_interval_secs: f64,
) -> ResourceVectorExtraction {
    let search_totals = collect_metric_by_index(metrics, SEARCH_REQUESTS_TOTAL);
    let indexed_totals = collect_metric_by_index(metrics, DOCUMENTS_INDEXED_TOTAL);
    let doc_counts = collect_metric_by_index(metrics, DOCUMENTS_COUNT);
    let storage_bytes_metric = collect_metric_by_index(metrics, STORAGE_BYTES);
    let total_heap_bytes = metrics
        .get(MEMORY_HEAP_BYTES)
        .map(|series| series.values().copied().sum::<f64>().max(0.0))
        .unwrap_or(0.0);
    let total_docs = doc_counts.values().copied().sum::<f64>();

    let mut index_names: Vec<String> = search_totals
        .keys()
        .chain(indexed_totals.keys())
        .chain(doc_counts.keys())
        .chain(storage_bytes_metric.keys())
        .cloned()
        .collect();
    if let Some(override_map) = storage_bytes_override {
        index_names.extend(override_map.keys().cloned());
    }
    index_names.sort();
    index_names.dedup();

    let mut next_counters = CounterSnapshot::new();
    let mut vectors = HashMap::new();

    for index in index_names {
        let search_total = search_totals.get(&index).copied().unwrap_or(0.0);
        let indexed_total = indexed_totals.get(&index).copied().unwrap_or(0.0);
        if search_totals.contains_key(&index) {
            next_counters.insert(
                counter_snapshot_key(SEARCH_REQUESTS_TOTAL, &index),
                search_total,
            );
        }
        if indexed_totals.contains_key(&index) {
            next_counters.insert(
                counter_snapshot_key(DOCUMENTS_INDEXED_TOTAL, &index),
                indexed_total,
            );
        }

        let query_rps = derive_counter_rps(
            search_total,
            previous_counters.get(&counter_snapshot_key(SEARCH_REQUESTS_TOTAL, &index)),
            scrape_interval_secs,
        );
        let indexing_rps = derive_counter_rps(
            indexed_total,
            previous_counters.get(&counter_snapshot_key(DOCUMENTS_INDEXED_TOTAL, &index)),
            scrape_interval_secs,
        );

        let disk_bytes = storage_bytes_override
            .and_then(|m| m.get(&index).copied())
            .or_else(|| {
                storage_bytes_metric
                    .get(&index)
                    .copied()
                    .map(safe_nonnegative_u64_from_f64)
            })
            .unwrap_or(0);

        let index_docs = doc_counts.get(&index).copied().unwrap_or(0.0);
        let mem_rss_bytes = if total_heap_bytes > 0.0 && total_docs > 0.0 && index_docs > 0.0 {
            safe_nonnegative_u64_from_f64(total_heap_bytes * (index_docs / total_docs))
        } else {
            0
        };

        vectors.insert(
            index,
            ResourceVector {
                cpu_weight: 0.0,
                mem_rss_bytes,
                disk_bytes,
                query_rps,
                indexing_rps,
            },
        );
    }

    ResourceVectorExtraction {
        vectors,
        next_counters,
    }
}

/// Parse `/internal/storage` or `/internal/storage/:indexName` response JSON.
///
/// Supported formats:
/// - `{ "tenants": [{ "id": "products", "bytes": 123 }, ...] }`
/// - `{ "index": "products", "bytes": 123 }`
pub fn parse_internal_storage_bytes(body: &str) -> Result<HashMap<String, u64>, serde_json::Error> {
    let value: serde_json::Value = serde_json::from_str(body)?;
    let mut out = HashMap::new();

    if let Some(tenants) = value.get("tenants").and_then(|v| v.as_array()) {
        for tenant in tenants {
            let Some(index) = tenant.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let bytes = tenant.get("bytes").and_then(|v| v.as_u64()).unwrap_or(0);
            out.insert(index.to_string(), bytes);
        }
        return Ok(out);
    }

    if let Some(index) = value.get("index").and_then(|v| v.as_str()) {
        let bytes = value.get("bytes").and_then(|v| v.as_u64()).unwrap_or(0);
        out.insert(index.to_string(), bytes);
    }

    Ok(out)
}

fn collect_metric_by_index(
    metrics: &HashMap<String, HashMap<String, f64>>,
    metric_name: &str,
) -> HashMap<String, f64> {
    let Some(series) = metrics.get(metric_name) else {
        return HashMap::new();
    };

    series
        .iter()
        .filter_map(|(labels, value)| extract_label(labels, "index").map(|index| (index, *value)))
        .collect()
}

/// Computes requests-per-second from a counter delta divided by the scrape
/// interval in seconds.
///
/// Returns 0.0 on the first scrape (no previous value) or when the interval
/// is zero/negative. Handles Prometheus counter resets by falling back to
/// `current_value / interval` when the delta would be negative.
fn derive_counter_rps(current: f64, previous: Option<&f64>, scrape_interval_secs: f64) -> f64 {
    if !scrape_interval_secs.is_finite() || scrape_interval_secs <= 0.0 {
        return 0.0;
    }

    let Some(previous) = previous else {
        return 0.0;
    };

    if current >= *previous {
        ((current - previous) / scrape_interval_secs).max(0.0)
    } else {
        // Counter reset after process restart.
        (current / scrape_interval_secs).max(0.0)
    }
}

fn safe_nonnegative_u64_from_f64(value: f64) -> u64 {
    if !value.is_finite() || value <= 0.0 {
        return 0;
    }
    value.floor() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_metric() {
        let text = "flapjack_documents_total 42\n";
        let result = parse_metrics(text);
        assert_eq!(result["flapjack_documents_total"][""], 42.0);
    }

    #[test]
    fn parse_metric_with_labels() {
        let text = r#"flapjack_search_requests_total{index="products"} 1234"#;
        let result = parse_metrics(text);
        assert_eq!(
            result["flapjack_search_requests_total"]["index=products"],
            1234.0
        );
    }

    #[test]
    fn parse_multiple_labels() {
        let text = r#"flapjack_storage_bytes{index="products",tier="hot"} 1073741824"#;
        let result = parse_metrics(text);
        assert_eq!(
            result["flapjack_storage_bytes"]["index=products,tier=hot"],
            1073741824.0
        );
    }

    #[test]
    fn parse_ignores_comments_and_type_lines() {
        let text = "# HELP flapjack_search_requests_total Total search requests\n\
                     # TYPE flapjack_search_requests_total counter\n\
                     flapjack_search_requests_total{index=\"products\"} 500\n";
        let result = parse_metrics(text);
        assert_eq!(result.len(), 1);
        assert_eq!(
            result["flapjack_search_requests_total"]["index=products"],
            500.0
        );
    }

    #[test]
    fn parse_multiple_indexes() {
        let text = r#"flapjack_storage_bytes{index="products"} 1000
flapjack_storage_bytes{index="orders"} 2000
flapjack_storage_bytes{index="users"} 3000
"#;
        let result = parse_metrics(text);
        let storage = &result["flapjack_storage_bytes"];
        assert_eq!(storage["index=products"], 1000.0);
        assert_eq!(storage["index=orders"], 2000.0);
        assert_eq!(storage["index=users"], 3000.0);
    }

    #[test]
    fn extract_label_works() {
        assert_eq!(
            extract_label("index=products,tier=hot", "index"),
            Some("products".to_string())
        );
        assert_eq!(
            extract_label("index=products,tier=hot", "tier"),
            Some("hot".to_string())
        );
        assert_eq!(extract_label("index=products", "missing"), None);
    }

    /// Verifies that RPS is correctly derived from the difference between the
    /// current and previous counter values divided by the scrape interval.
    #[test]
    fn extract_resource_vectors_derives_rps_from_counter_delta() {
        let text = r#"
flapjack_search_requests_total{index="products"} 150
flapjack_documents_indexed_total{index="products"} 30
flapjack_documents_count{index="products"} 100
flapjack_memory_heap_bytes 1000
"#;
        let metrics = parse_metrics(text);
        let previous = HashMap::from([
            (
                counter_snapshot_key("flapjack_search_requests_total", "products"),
                100.0,
            ),
            (
                counter_snapshot_key("flapjack_documents_indexed_total", "products"),
                20.0,
            ),
        ]);

        let extracted = extract_resource_vectors(&metrics, None, &previous, 10.0);
        let products = extracted.vectors.get("products").expect("products vector");

        assert!((products.query_rps - 5.0).abs() < 1e-9);
        assert!((products.indexing_rps - 1.0).abs() < 1e-9);
        assert_eq!(products.mem_rss_bytes, 1000);
        assert_eq!(products.disk_bytes, 0);
        assert_eq!(products.cpu_weight, 0.0);
    }

    /// Verifies that the first scrape (no previous snapshot) yields 0.0 RPS
    /// but populates the `next_counters` map for subsequent delta calculations.
    #[test]
    fn extract_resource_vectors_first_scrape_sets_zero_rps_and_tracks_counters() {
        let text = r#"
flapjack_search_requests_total{index="products"} 150
flapjack_documents_indexed_total{index="products"} 30
flapjack_documents_count{index="products"} 100
flapjack_memory_heap_bytes 1000
"#;
        let metrics = parse_metrics(text);

        let extracted = extract_resource_vectors(&metrics, None, &HashMap::new(), 10.0);
        let products = extracted.vectors.get("products").expect("products vector");

        assert_eq!(products.query_rps, 0.0);
        assert_eq!(products.indexing_rps, 0.0);
        assert_eq!(
            extracted.next_counters.get(&counter_snapshot_key(
                "flapjack_search_requests_total",
                "products"
            )),
            Some(&150.0)
        );
        assert_eq!(
            extracted.next_counters.get(&counter_snapshot_key(
                "flapjack_documents_indexed_total",
                "products"
            )),
            Some(&30.0)
        );
    }

    #[test]
    fn extract_resource_vectors_approximates_memory_by_doc_count_ratio() {
        let text = r#"
flapjack_documents_count{index="products"} 75
flapjack_documents_count{index="orders"} 25
flapjack_memory_heap_bytes 1000
"#;
        let metrics = parse_metrics(text);

        let extracted = extract_resource_vectors(&metrics, None, &HashMap::new(), 60.0);
        let products = extracted.vectors.get("products").expect("products vector");
        let orders = extracted.vectors.get("orders").expect("orders vector");

        assert_eq!(products.mem_rss_bytes, 750);
        assert_eq!(orders.mem_rss_bytes, 250);
    }

    #[test]
    fn extract_resource_vectors_prefers_internal_storage_override() {
        let text = r#"
flapjack_storage_bytes{index="products"} 111
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 1000
"#;
        let metrics = parse_metrics(text);
        let storage = HashMap::from([("products".to_string(), 222_u64)]);

        let extracted = extract_resource_vectors(&metrics, Some(&storage), &HashMap::new(), 30.0);
        let products = extracted.vectors.get("products").expect("products vector");

        assert_eq!(products.disk_bytes, 222);
    }

    /// Verifies the counter-reset fallback: when the current value is less than
    /// the previous value (indicating a process restart), RPS is computed as
    /// `current_value / interval` instead of the negative delta.
    #[test]
    fn extract_resource_vectors_handles_counter_reset() {
        let text = r#"
flapjack_search_requests_total{index="products"} 15
flapjack_documents_count{index="products"} 1
flapjack_memory_heap_bytes 1000
"#;
        let metrics = parse_metrics(text);
        let previous = HashMap::from([(
            counter_snapshot_key("flapjack_search_requests_total", "products"),
            100.0,
        )]);

        let extracted = extract_resource_vectors(&metrics, None, &previous, 5.0);
        let products = extracted.vectors.get("products").expect("products vector");

        // Counter reset falls back to current/interval.
        assert!((products.query_rps - 3.0).abs() < 1e-9);
    }

    #[test]
    fn parse_internal_storage_payload() {
        let body = r#"{
  "tenants": [
    {"id":"products","bytes":1048576,"doc_count":52},
    {"id":"orders","bytes":2048,"doc_count":7}
  ]
}"#;

        let parsed = parse_internal_storage_bytes(body).expect("storage payload parses");
        assert_eq!(parsed.get("products"), Some(&1_048_576));
        assert_eq!(parsed.get("orders"), Some(&2_048));
    }

    #[test]
    fn parse_metric_with_optional_timestamp() {
        let text = r#"flapjack_search_requests_total{index="products"} 123 1700000000"#;
        let result = parse_metrics(text);
        assert_eq!(
            result["flapjack_search_requests_total"]["index=products"],
            123.0
        );
    }

    #[test]
    fn parse_empty_and_comment_only_input() {
        assert!(parse_metrics("").is_empty());
        assert!(parse_metrics("   \n  \n").is_empty());
        assert!(parse_metrics("# HELP nothing\n# TYPE nothing gauge\n").is_empty());
    }

    #[test]
    fn parse_skips_malformed_lines() {
        let text = "good_metric 42\nnot_a_number abc\ntrailing_garbage{foo=\"bar\"} nope\nanother_good 7\n";
        let result = parse_metrics(text);
        assert_eq!(result.len(), 2);
        assert_eq!(result["good_metric"][""], 42.0);
        assert_eq!(result["another_good"][""], 7.0);
    }

    #[test]
    fn parse_internal_storage_empty_tenants() {
        let body = r#"{"tenants":[]}"#;
        let parsed = parse_internal_storage_bytes(body).expect("empty tenants parses");
        assert!(parsed.is_empty());
    }
}

use std::collections::HashMap;
use thiserror::Error;

/// A single parsed line from Prometheus text exposition format.
#[derive(Debug, Clone, PartialEq)]
pub struct MetricSample {
    pub name: String,
    pub labels: HashMap<String, String>,
    pub value: f64,
}

#[derive(Debug, Error, PartialEq)]
pub enum ParseError {
    #[error("malformed metric line: {0:?}")]
    MalformedLine(String),
    #[error("invalid metric value in line: {0:?}")]
    InvalidValue(String),
    #[error("malformed label pair: {0:?}")]
    MalformedLabel(String),
}

/// Parse a Prometheus text exposition body into a flat list of valid samples.
///
/// Comment lines (`#`) and blank lines are skipped. Lines with `+Inf`, `-Inf`,
/// and `NaN` are parsed as their f64 representations. Malformed metric lines
/// are skipped after warning so one bad line does not discard the whole scrape.
pub fn parse_prometheus_text(body: &str) -> Vec<MetricSample> {
    let mut samples = Vec::new();

    for line in body.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        match parse_metric_line(line) {
            Ok(sample) => samples.push(sample),
            Err(error) => {
                tracing::warn!(
                    error = %error,
                    line = line,
                    "skipping malformed Prometheus metric line"
                );
            }
        }
    }

    samples
}

/// Parse a single non-comment, non-blank line from a Prometheus text body into
/// a [`MetricSample`].
///
/// Handles both labelled and bare formats:
/// - `name{k="v",...} value [timestamp]`
/// - `name value [timestamp]`
///
/// An optional trailing Unix-millisecond timestamp is silently ignored.
/// Returns [`ParseError::MalformedLine`] if the descriptor/value boundary
/// cannot be found, or [`ParseError::InvalidValue`] if the value is not a
/// valid f64.
fn parse_metric_line(line: &str) -> Result<MetricSample, ParseError> {
    // Split off the value (and optional timestamp) from the right.
    // Format: `name{labels} value [timestamp]`  or  `name value [timestamp]`
    // We split on the last space to skip any trailing timestamp.
    let trimmed = line.trim();

    // Find the boundary between the metric descriptor and the value.
    // The descriptor ends at '}' if labels are present, otherwise at the first
    // whitespace after the name.
    let (descriptor, rest) =
        split_descriptor(trimmed).ok_or_else(|| ParseError::MalformedLine(line.to_string()))?;

    // The rest starts with whitespace then the value (possibly a timestamp after).
    let value_str = rest.split_whitespace().next().unwrap_or("");
    let value: f64 = value_str
        .parse()
        .map_err(|_| ParseError::InvalidValue(line.to_string()))?;

    if let Some((name, labels_str)) = descriptor.split_once('{') {
        let labels_body = labels_str.trim_end_matches('}');
        let labels = parse_labels(labels_body, line)?;
        Ok(MetricSample {
            name: name.to_string(),
            labels,
            value,
        })
    } else {
        Ok(MetricSample {
            name: descriptor.to_string(),
            labels: HashMap::new(),
            value,
        })
    }
}

/// Split `"name{...} value"` or `"name value"` into `(descriptor, rest)`.
fn split_descriptor(s: &str) -> Option<(&str, &str)> {
    if let Some(brace_end) = s.find('}') {
        let descriptor = &s[..=brace_end];
        let rest = &s[brace_end + 1..];
        Some((descriptor, rest))
    } else {
        // No labels — split on first whitespace.
        s.split_once(|c: char| c.is_whitespace())
    }
}

/// Parse the label body from inside a Prometheus `{...}` block into a
/// `HashMap<String, String>`.
///
/// Expects a comma-separated list of `key="value"` pairs.  Surrounding
/// whitespace and enclosing double-quotes on values are stripped.  An empty
/// input returns an empty map.  Returns [`ParseError::MalformedLabel`]
/// (carrying the original source line for diagnostics) if any pair lacks an
/// `=` separator.
fn parse_labels(s: &str, source_line: &str) -> Result<HashMap<String, String>, ParseError> {
    let mut labels = HashMap::new();
    if s.is_empty() {
        return Ok(labels);
    }
    for pair in s.split(',') {
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }
        let (key, val) = pair
            .split_once('=')
            .ok_or_else(|| ParseError::MalformedLabel(source_line.to_string()))?;
        let val = val.trim().trim_matches('"');
        labels.insert(key.trim().to_string(), val.to_string());
    }
    Ok(labels)
}

/// Typed metrics extracted from a scrape. Only the fields flapjack exposes
/// that we care about for metering. Unknown/unrelated metrics are ignored.
#[derive(Debug, Default, Clone)]
pub struct FlapjackMetrics {
    /// Per-index: total search requests (monotonic counter)
    pub search_requests_total: HashMap<String, u64>,
    /// Per-index: total write operations (monotonic counter)
    pub write_operations_total: HashMap<String, u64>,
    /// Per-index: total documents indexed (monotonic counter)
    pub documents_indexed_total: HashMap<String, u64>,
    /// Per-index: total documents deleted (monotonic counter)
    pub documents_deleted_total: HashMap<String, u64>,
    /// Per-index: current document count (gauge)
    pub documents_count: HashMap<String, u64>,
    /// Per-index: bytes on disk (gauge — updated by background poller)
    pub storage_bytes: HashMap<String, u64>,
    /// System gauges
    pub active_writers: Option<u64>,
    pub tenants_loaded: Option<u64>,
}

/// Extract the subset of metrics relevant to metering from a parsed sample list.
pub fn extract_flapjack_metrics(samples: &[MetricSample]) -> FlapjackMetrics {
    let mut out = FlapjackMetrics::default();

    for sample in samples {
        let index = sample.labels.get("index").cloned();
        let Some(v) = metering_value_as_u64(sample) else {
            continue;
        };

        match sample.name.as_str() {
            "flapjack_search_requests_total" => {
                if let Some(idx) = index {
                    out.search_requests_total.insert(idx, v);
                }
            }
            "flapjack_write_operations_total" => {
                if let Some(idx) = index {
                    out.write_operations_total.insert(idx, v);
                }
            }
            "flapjack_documents_indexed_total" => {
                if let Some(idx) = index {
                    out.documents_indexed_total.insert(idx, v);
                }
            }
            "flapjack_documents_deleted_total" => {
                if let Some(idx) = index {
                    out.documents_deleted_total.insert(idx, v);
                }
            }
            "flapjack_documents_count" => {
                if let Some(idx) = index {
                    out.documents_count.insert(idx, v);
                }
            }
            "flapjack_storage_bytes" => {
                if let Some(idx) = index {
                    out.storage_bytes.insert(idx, v);
                }
            }
            "flapjack_active_writers" => {
                out.active_writers = Some(v);
            }
            "flapjack_tenants_loaded" => {
                out.tenants_loaded = Some(v);
            }
            _ => {} // ignore other metrics
        }
    }

    out
}

fn metering_value_as_u64(sample: &MetricSample) -> Option<u64> {
    if sample.value.is_finite()
        && sample.value >= 0.0
        && sample.value.fract() == 0.0
        && sample.value <= u64::MAX as f64
    {
        Some(sample.value as u64)
    } else {
        tracing::warn!(
            metric = sample.name.as_str(),
            value = sample.value,
            "skipping non-integer Prometheus metering value"
        );
        None
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE_BODY: &str = r#"
# HELP flapjack_search_requests_total Total search requests per index
# TYPE flapjack_search_requests_total counter
flapjack_search_requests_total{index="products"} 145023
flapjack_search_requests_total{index="orders"} 3412

# HELP flapjack_write_operations_total Total write operations per index
# TYPE flapjack_write_operations_total counter
flapjack_write_operations_total{index="products"} 8921
flapjack_write_operations_total{index="orders"} 221

# HELP flapjack_documents_indexed_total Total documents indexed per index
# TYPE flapjack_documents_indexed_total counter
flapjack_documents_indexed_total{index="products"} 12345
flapjack_documents_indexed_total{index="orders"} 89

# HELP flapjack_documents_deleted_total Total documents deleted per index
# TYPE flapjack_documents_deleted_total counter
flapjack_documents_deleted_total{index="products"} 501
flapjack_documents_deleted_total{index="orders"} 12

# HELP flapjack_documents_count Current document count
# TYPE flapjack_documents_count gauge
flapjack_documents_count{index="products"} 52000
flapjack_documents_count{index="orders"} 1800

# HELP flapjack_storage_bytes Bytes on disk per index
# TYPE flapjack_storage_bytes gauge
flapjack_storage_bytes{index="products"} 104857600
flapjack_storage_bytes{index="orders"} 2097152

# HELP flapjack_active_writers Current writer count
# TYPE flapjack_active_writers gauge
flapjack_active_writers 3

# HELP flapjack_tenants_loaded Number of loaded indices
# TYPE flapjack_tenants_loaded gauge
flapjack_tenants_loaded 2
"#;

    // -------------------------------------------------------------------------
    // parse_prometheus_text
    // -------------------------------------------------------------------------

    #[test]
    fn comment_and_blank_lines_skipped() {
        let body = "# HELP foo bar\n\nfoo 1.0\n";
        let samples = parse_prometheus_text(body);
        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].name, "foo");
    }

    #[test]
    fn parses_metric_with_labels() {
        let body = r#"flapjack_search_requests_total{index="products"} 145023"#;
        let samples = parse_prometheus_text(body);

        assert_eq!(samples.len(), 1);
        assert_eq!(samples[0].name, "flapjack_search_requests_total");
        assert_eq!(
            samples[0].labels.get("index").map(String::as_str),
            Some("products")
        );
        assert_eq!(samples[0].value, 145023.0);
    }

    #[test]
    fn parses_metric_without_labels() {
        let body = "flapjack_active_writers 3";
        let samples = parse_prometheus_text(body);

        assert_eq!(samples[0].name, "flapjack_active_writers");
        assert!(samples[0].labels.is_empty());
        assert_eq!(samples[0].value, 3.0);
    }

    #[test]
    fn parses_multiple_labels() {
        let body = r#"some_metric{region="us-east-1",index="products"} 42"#;
        let samples = parse_prometheus_text(body);

        assert_eq!(
            samples[0].labels.get("region").map(String::as_str),
            Some("us-east-1")
        );
        assert_eq!(
            samples[0].labels.get("index").map(String::as_str),
            Some("products")
        );
    }

    #[test]
    fn parses_full_example_body() {
        let samples = parse_prometheus_text(EXAMPLE_BODY);
        // 2 search + 2 write + 2 indexed + 2 deleted + 2 doc_count + 2 storage
        // + 1 active_writers + 1 tenants_loaded = 14
        assert_eq!(samples.len(), 14);
    }

    #[test]
    fn ignores_optional_timestamp() {
        // Prometheus format allows an optional Unix ms timestamp after the value.
        let body = r#"flapjack_search_requests_total{index="x"} 100 1706745600000"#;
        let samples = parse_prometheus_text(body);

        assert_eq!(samples[0].value, 100.0);
    }

    #[test]
    fn parse_metric_line_reports_malformed_line_with_source() {
        assert_eq!(
            parse_metric_line("justtoken"),
            Err(ParseError::MalformedLine("justtoken".to_string()))
        );
    }

    #[test]
    fn parse_metric_line_reports_invalid_value_with_source() {
        let line = r#"flapjack_search_requests_total{index="x"} not_a_number"#;

        assert_eq!(
            parse_metric_line(line),
            Err(ParseError::InvalidValue(line.to_string()))
        );
    }

    #[test]
    fn parse_metric_line_reports_malformed_label_with_source() {
        let line = "some_metric{badlabel} 5";

        assert_eq!(
            parse_metric_line(line),
            Err(ParseError::MalformedLabel(line.to_string()))
        );
    }

    #[test]
    fn parse_prometheus_text_keeps_valid_samples_after_malformed_line() {
        let body = r#"
flapjack_search_requests_total{index="products"} 50
justtoken
flapjack_write_operations_total{index="orders"} 25
"#;

        let samples = parse_prometheus_text(body);

        assert_eq!(samples.len(), 2);
        assert_eq!(samples[0].name, "flapjack_search_requests_total");
        assert_eq!(
            samples[0].labels.get("index").map(String::as_str),
            Some("products")
        );
        assert_eq!(samples[0].value, 50.0);
        assert_eq!(samples[1].name, "flapjack_write_operations_total");
        assert_eq!(
            samples[1].labels.get("index").map(String::as_str),
            Some("orders")
        );
        assert_eq!(samples[1].value, 25.0);
    }

    // -------------------------------------------------------------------------
    // extract_flapjack_metrics
    // -------------------------------------------------------------------------

    #[test]
    fn extracts_per_index_counters() {
        let samples = parse_prometheus_text(EXAMPLE_BODY);
        let m = extract_flapjack_metrics(&samples);

        assert_eq!(m.search_requests_total.get("products"), Some(&145023));
        assert_eq!(m.search_requests_total.get("orders"), Some(&3412));
        assert_eq!(m.write_operations_total.get("products"), Some(&8921));
        assert_eq!(m.write_operations_total.get("orders"), Some(&221));
    }

    #[test]
    fn extracts_documents_indexed_and_deleted_counters() {
        let samples = parse_prometheus_text(EXAMPLE_BODY);
        let m = extract_flapjack_metrics(&samples);

        assert_eq!(m.documents_indexed_total.get("products"), Some(&12345));
        assert_eq!(m.documents_indexed_total.get("orders"), Some(&89));
        assert_eq!(m.documents_deleted_total.get("products"), Some(&501));
        assert_eq!(m.documents_deleted_total.get("orders"), Some(&12));
    }

    #[test]
    fn extracts_storage_and_doc_count_gauges() {
        let samples = parse_prometheus_text(EXAMPLE_BODY);
        let m = extract_flapjack_metrics(&samples);

        assert_eq!(m.storage_bytes.get("products"), Some(&104_857_600));
        assert_eq!(m.documents_count.get("products"), Some(&52_000));
    }

    #[test]
    fn extracts_system_gauges() {
        let samples = parse_prometheus_text(EXAMPLE_BODY);
        let m = extract_flapjack_metrics(&samples);

        assert_eq!(m.active_writers, Some(3));
        assert_eq!(m.tenants_loaded, Some(2));
    }

    #[test]
    fn unknown_metrics_are_ignored() {
        let body = "some_unknown_metric{foo=\"bar\"} 99\n";
        let samples = parse_prometheus_text(body);
        let m = extract_flapjack_metrics(&samples);

        assert!(m.search_requests_total.is_empty());
        assert!(m.active_writers.is_none());
    }

    #[test]
    fn missing_index_label_does_not_panic() {
        // A labelled-looking metric with no `index` label should be ignored gracefully.
        let body = r#"flapjack_search_requests_total{peer_id="node-b"} 5"#;
        let samples = parse_prometheus_text(body);
        let m = extract_flapjack_metrics(&samples);

        assert!(m.search_requests_total.is_empty());
    }

    #[test]
    fn rejects_non_finite_and_fractional_metering_values() {
        let samples = vec![
            MetricSample {
                name: "flapjack_search_requests_total".to_string(),
                labels: HashMap::from([("index".to_string(), "inf".to_string())]),
                value: f64::INFINITY,
            },
            MetricSample {
                name: "flapjack_write_operations_total".to_string(),
                labels: HashMap::from([("index".to_string(), "nan".to_string())]),
                value: f64::NAN,
            },
            MetricSample {
                name: "flapjack_documents_count".to_string(),
                labels: HashMap::from([("index".to_string(), "negative".to_string())]),
                value: -1.0,
            },
            MetricSample {
                name: "flapjack_documents_deleted_total".to_string(),
                labels: HashMap::from([("index".to_string(), "fractional".to_string())]),
                value: 1.5,
            },
            MetricSample {
                name: "flapjack_documents_indexed_total".to_string(),
                labels: HashMap::from([("index".to_string(), "valid".to_string())]),
                value: 7.0,
            },
        ];

        let m = extract_flapjack_metrics(&samples);

        assert!(m.search_requests_total.is_empty());
        assert!(m.write_operations_total.is_empty());
        assert!(m.documents_count.is_empty());
        assert!(m.documents_deleted_total.is_empty());
        assert_eq!(m.documents_indexed_total.get("valid"), Some(&7));
    }
}

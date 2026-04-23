//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/metrics.rs.
use prometheus::{Encoder, GaugeVec, HistogramVec, IntCounterVec, Registry, TextEncoder};
use std::time::Duration;

/// Collects application-level Prometheus metrics.
///
/// Each instance owns its own `prometheus::Registry` so metrics are isolated
/// (important for test isolation — the global registry is never used).
#[derive(Clone)]
pub struct MetricsCollector {
    registry: Registry,
    http_requests_total: IntCounterVec,
    http_request_duration_seconds: HistogramVec,
    // Placeholders for periodic refresh in later stages
    #[allow(dead_code)]
    active_tenants: prometheus::Gauge,
    #[allow(dead_code)]
    vm_count: GaugeVec,
    #[allow(dead_code)]
    active_indexes: prometheus::Gauge,
}

impl MetricsCollector {
    /// Creates an isolated Prometheus registry and registers five metric families:
    /// an HTTP request counter, a request duration histogram, an active tenants
    /// gauge, a VM count gauge vec (labeled by status), and an active
    /// indexes gauge.
    pub fn new() -> Self {
        let registry = Registry::new();

        let http_requests_total = IntCounterVec::new(
            prometheus::Opts::new(
                "fjcloud_http_requests_total",
                "Total number of HTTP requests",
            ),
            &["method", "path", "status"],
        )
        .expect("metric can be created");

        let http_request_duration_seconds = HistogramVec::new(
            prometheus::HistogramOpts::new(
                "fjcloud_http_request_duration_seconds",
                "HTTP request duration in seconds",
            ),
            &["method", "path"],
        )
        .expect("metric can be created");

        let active_tenants = prometheus::Gauge::new(
            "fjcloud_active_tenants",
            "Number of active tenants (placeholder)",
        )
        .expect("metric can be created");

        let vm_count = GaugeVec::new(
            prometheus::Opts::new("fjcloud_vm_count", "Number of VMs by status"),
            &["status"],
        )
        .expect("metric can be created");

        let active_indexes = prometheus::Gauge::new(
            "fjcloud_active_indexes",
            "Number of active indexes (placeholder)",
        )
        .expect("metric can be created");

        registry
            .register(Box::new(http_requests_total.clone()))
            .expect("metric can be registered");
        registry
            .register(Box::new(http_request_duration_seconds.clone()))
            .expect("metric can be registered");
        registry
            .register(Box::new(active_tenants.clone()))
            .expect("metric can be registered");
        registry
            .register(Box::new(vm_count.clone()))
            .expect("metric can be registered");
        registry
            .register(Box::new(active_indexes.clone()))
            .expect("metric can be registered");

        // Pre-initialize GaugeVec labels so they appear in output immediately
        for status in &["running", "stopped", "failed", "provisioning"] {
            vm_count.with_label_values(&[status]);
        }

        Self {
            registry,
            http_requests_total,
            http_request_duration_seconds,
            active_tenants,
            vm_count,
            active_indexes,
        }
    }

    /// Record an HTTP request with the given labels and duration.
    pub fn record_request(&self, method: &str, path: &str, status: u16, duration: Duration) {
        self.http_requests_total
            .with_label_values(&[method, path, &status.to_string()])
            .inc();
        self.http_request_duration_seconds
            .with_label_values(&[method, path])
            .observe(duration.as_secs_f64());
    }

    /// Encode all registered metrics as Prometheus exposition text.
    pub fn render(&self) -> String {
        let encoder = TextEncoder::new();
        let metric_families = self.registry.gather();
        let mut buffer = Vec::new();
        if let Err(e) = encoder.encode(&metric_families, &mut buffer) {
            tracing::error!("failed to encode metrics: {e}");
            return String::new();
        }
        String::from_utf8(buffer).unwrap_or_else(|e| {
            tracing::error!("metrics output is not valid UTF-8: {e}");
            String::new()
        })
    }
}

impl Default for MetricsCollector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies that a freshly created [`MetricsCollector`] exposes all five
    /// expected metric families in its rendered Prometheus text output.
    #[test]
    fn new_creates_registry_with_all_metrics() {
        let collector = MetricsCollector::new();

        // Record one request so the vec metrics (counter, histogram) appear in output.
        // Gauge metrics always appear since they have a default value of 0.
        collector.record_request("GET", "/health", 200, Duration::from_millis(1));

        let text = collector.render();

        assert!(
            text.contains("fjcloud_http_requests_total"),
            "missing http_requests_total"
        );
        assert!(
            text.contains("fjcloud_http_request_duration_seconds"),
            "missing http_request_duration_seconds"
        );
        assert!(
            text.contains("fjcloud_active_tenants"),
            "missing active_tenants"
        );
        assert!(text.contains("fjcloud_vm_count"), "missing vm_count");
        assert!(
            text.contains("fjcloud_active_indexes"),
            "missing active_indexes"
        );
    }

    #[test]
    fn two_collectors_have_independent_registries() {
        let a = MetricsCollector::new();
        let b = MetricsCollector::new();

        a.record_request("GET", "/health", 200, Duration::from_millis(5));

        // b should have no observations
        let b_text = b.render();
        // Counter families are still gathered (with 0 value) but should not contain the label combo
        assert!(
            !b_text.contains(r#"method="GET""#),
            "collector b should not see collector a's request"
        );
    }

    /// Verifies that calling `record_request` increments the HTTP request
    /// counter and records an observation in the duration histogram.
    #[test]
    fn record_request_increments_counter_and_observes_histogram() {
        let collector = MetricsCollector::new();

        collector.record_request("POST", "/indexes", 201, Duration::from_millis(42));
        collector.record_request("POST", "/indexes", 201, Duration::from_millis(10));

        let counter = collector
            .http_requests_total
            .with_label_values(&["POST", "/indexes", "201"])
            .get();
        assert_eq!(counter, 2, "counter should be 2 after two requests");

        let histogram = collector
            .http_request_duration_seconds
            .with_label_values(&["POST", "/indexes"])
            .get_sample_count();
        assert_eq!(
            histogram, 2,
            "histogram should have 2 observations after two requests"
        );
    }

    /// Verifies that the rendered output contains valid Prometheus exposition
    /// format, including `# HELP` and `# TYPE` lines with correct metric names
    /// and labels.
    #[test]
    fn render_returns_valid_prometheus_text() {
        let collector = MetricsCollector::new();
        collector.record_request("GET", "/health", 200, Duration::from_millis(1));

        let text = collector.render();

        assert!(text.contains("# HELP"), "should contain HELP lines");
        assert!(text.contains("# TYPE"), "should contain TYPE lines");
        assert!(
            text.contains("fjcloud_http_requests_total"),
            "should contain request counter"
        );
        assert!(
            text.contains(r#"method="GET""#),
            "should contain method label"
        );
        assert!(
            text.contains(r#"path="/health""#),
            "should contain path label"
        );
        assert!(
            text.contains(r#"status="200""#),
            "should contain status label"
        );
    }
}

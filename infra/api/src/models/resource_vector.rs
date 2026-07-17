use serde::{Deserialize, Serialize};

/// Normalized resource vector for bin-packing placement.
/// Each dimension represents a resource that can be consumed by an index.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceVector {
    pub cpu_weight: f64,
    pub mem_rss_bytes: u64,
    pub disk_bytes: u64,
    pub query_rps: f64,
    pub indexing_rps: f64,
}

impl ResourceVector {
    pub fn zero() -> Self {
        Self {
            cpu_weight: 0.0,
            mem_rss_bytes: 0,
            disk_bytes: 0,
            query_rps: 0.0,
            indexing_rps: 0.0,
        }
    }

    /// Dot product with another vector. Both vectors should be normalized
    /// to the same scale (e.g., via `normalize_by()`) before calling this,
    /// otherwise byte-valued dimensions dominate float-valued ones.
    pub fn dot(&self, other: &ResourceVector) -> f64 {
        self.cpu_weight * other.cpu_weight
            + (self.mem_rss_bytes as f64) * (other.mem_rss_bytes as f64)
            + (self.disk_bytes as f64) * (other.disk_bytes as f64)
            + self.query_rps * other.query_rps
            + self.indexing_rps * other.indexing_rps
    }

    /// Normalized dot product: each dimension is divided by the corresponding
    /// capacity value before multiplying, so all dimensions are in [0,1] range
    /// and contribute equally to the score. This prevents byte-valued fields
    /// (mem ~1e9, disk ~1e11) from dominating float-valued fields (CPU ~4.0,
    /// RPS ~500.0) by ~15 orders of magnitude.
    pub fn dot_normalized(&self, other: &ResourceVector, capacity: &ResourceVector) -> f64 {
        let safe_div_f64 = |a: f64, b: f64| if b > 0.0 { a / b } else { 0.0 };
        let safe_div_u64 = |a: u64, b: u64| -> f64 {
            if b > 0 {
                a as f64 / b as f64
            } else {
                0.0
            }
        };

        safe_div_f64(self.cpu_weight, capacity.cpu_weight)
            * safe_div_f64(other.cpu_weight, capacity.cpu_weight)
            + safe_div_u64(self.mem_rss_bytes, capacity.mem_rss_bytes)
                * safe_div_u64(other.mem_rss_bytes, capacity.mem_rss_bytes)
            + safe_div_u64(self.disk_bytes, capacity.disk_bytes)
                * safe_div_u64(other.disk_bytes, capacity.disk_bytes)
            + safe_div_f64(self.query_rps, capacity.query_rps)
                * safe_div_f64(other.query_rps, capacity.query_rps)
            + safe_div_f64(self.indexing_rps, capacity.indexing_rps)
                * safe_div_f64(other.indexing_rps, capacity.indexing_rps)
    }

    /// Total weight for Decreasing sort order in batch placement.
    /// Normalizes each dimension to [0,1] range and sums.
    pub fn total_weight(&self) -> f64 {
        // Simple sum of normalized values. For sorting purposes,
        // absolute magnitude is fine — we just need a total ordering.
        self.cpu_weight
            + (self.mem_rss_bytes as f64 / 1_073_741_824.0) // normalize to GB
            + (self.disk_bytes as f64 / 1_073_741_824.0)     // normalize to GB
            + self.query_rps
            + self.indexing_rps
    }

    /// Returns true if any dimension exceeds the corresponding capacity dimension.
    pub fn exceeds_capacity(&self, capacity: &ResourceVector) -> bool {
        self.cpu_weight > capacity.cpu_weight
            || self.mem_rss_bytes > capacity.mem_rss_bytes
            || self.disk_bytes > capacity.disk_bytes
            || self.query_rps > capacity.query_rps
            || self.indexing_rps > capacity.indexing_rps
    }

    /// Add another vector to this one (for computing aggregate load).
    pub fn add(&self, other: &ResourceVector) -> ResourceVector {
        ResourceVector {
            cpu_weight: self.cpu_weight + other.cpu_weight,
            mem_rss_bytes: self.mem_rss_bytes + other.mem_rss_bytes,
            disk_bytes: self.disk_bytes + other.disk_bytes,
            query_rps: self.query_rps + other.query_rps,
            indexing_rps: self.indexing_rps + other.indexing_rps,
        }
    }
}

impl From<serde_json::Value> for ResourceVector {
    fn from(v: serde_json::Value) -> Self {
        Self {
            cpu_weight: v.get("cpu_weight").and_then(|v| v.as_f64()).unwrap_or(0.0),
            mem_rss_bytes: v.get("mem_rss_bytes").and_then(|v| v.as_u64()).unwrap_or(0),
            disk_bytes: v.get("disk_bytes").and_then(|v| v.as_u64()).unwrap_or(0),
            query_rps: v.get("query_rps").and_then(|v| v.as_f64()).unwrap_or(0.0),
            indexing_rps: v
                .get("indexing_rps")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0),
        }
    }
}

impl From<ResourceVector> for serde_json::Value {
    fn from(rv: ResourceVector) -> Self {
        serde_json::json!({
            "cpu_weight": rv.cpu_weight,
            "mem_rss_bytes": rv.mem_rss_bytes,
            "disk_bytes": rv.disk_bytes,
            "query_rps": rv.query_rps,
            "indexing_rps": rv.indexing_rps,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rv(cpu: f64, mem: u64, disk: u64, qrps: f64, irps: f64) -> ResourceVector {
        ResourceVector {
            cpu_weight: cpu,
            mem_rss_bytes: mem,
            disk_bytes: disk,
            query_rps: qrps,
            indexing_rps: irps,
        }
    }

    #[test]
    fn zero_is_all_zeroes() {
        let z = ResourceVector::zero();
        assert_eq!(z.cpu_weight, 0.0);
        assert_eq!(z.mem_rss_bytes, 0);
        assert_eq!(z.disk_bytes, 0);
        assert_eq!(z.query_rps, 0.0);
        assert_eq!(z.indexing_rps, 0.0);
    }

    #[test]
    fn add_sums_all_dimensions() {
        let a = rv(1.0, 100, 200, 10.0, 5.0);
        let b = rv(2.0, 300, 400, 20.0, 15.0);
        let c = a.add(&b);
        assert!((c.cpu_weight - 3.0).abs() < f64::EPSILON);
        assert_eq!(c.mem_rss_bytes, 400);
        assert_eq!(c.disk_bytes, 600);
        assert!((c.query_rps - 30.0).abs() < f64::EPSILON);
        assert!((c.indexing_rps - 20.0).abs() < f64::EPSILON);
    }

    #[test]
    fn exceeds_capacity_detects_any_overflow() {
        let cap = rv(4.0, 8_000, 50_000, 200.0, 100.0);
        // All within
        assert!(!rv(4.0, 8_000, 50_000, 200.0, 100.0).exceeds_capacity(&cap));
        // CPU over
        assert!(rv(4.1, 8_000, 50_000, 200.0, 100.0).exceeds_capacity(&cap));
        // Mem over
        assert!(rv(4.0, 8_001, 50_000, 200.0, 100.0).exceeds_capacity(&cap));
        // Disk over
        assert!(rv(4.0, 8_000, 50_001, 200.0, 100.0).exceeds_capacity(&cap));
        // Query RPS over
        assert!(rv(4.0, 8_000, 50_000, 200.1, 100.0).exceeds_capacity(&cap));
        // Indexing RPS over
        assert!(rv(4.0, 8_000, 50_000, 200.0, 100.1).exceeds_capacity(&cap));
    }

    #[test]
    fn dot_normalized_is_zero_when_zero_capacity() {
        let a = rv(1.0, 100, 200, 10.0, 5.0);
        let b = rv(1.0, 100, 200, 10.0, 5.0);
        let zero_cap = ResourceVector::zero();
        // All divisions by zero should produce 0.0, not NaN/Inf
        let score = a.dot_normalized(&b, &zero_cap);
        assert!(score.is_finite());
        assert_eq!(score, 0.0);
    }

    #[test]
    fn dot_normalized_equals_five_for_identical_full_vectors() {
        // When index == remaining == capacity, each normalized term is (1.0)*(1.0) = 1.0
        // Sum across 5 dimensions = 5.0
        let v = rv(4.0, 8_000, 50_000, 200.0, 100.0);
        let score = v.dot_normalized(&v, &v);
        assert!((score - 5.0).abs() < 1e-10);
    }

    #[test]
    fn total_weight_increases_with_resources() {
        let small = rv(1.0, 1_073_741_824, 1_073_741_824, 10.0, 5.0);
        let large = rv(4.0, 4_294_967_296, 4_294_967_296, 100.0, 50.0);
        assert!(large.total_weight() > small.total_weight());
    }

    #[test]
    fn json_roundtrip() {
        let original = rv(2.5, 4_000, 10_000, 50.0, 25.0);
        let json_val: serde_json::Value = original.clone().into();
        let restored: ResourceVector = json_val.into();
        assert_eq!(original, restored);
    }
}

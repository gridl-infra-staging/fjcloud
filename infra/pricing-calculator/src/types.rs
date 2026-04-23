//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/types.rs.
use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};

// ============================================================================
// Workload profile (input)
// ============================================================================

/// A user's search workload description. This is the input to the comparison
/// calculator — everything we need to estimate costs across providers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkloadProfile {
    /// Total number of documents/records in the dataset.
    pub document_count: i64,
    /// Average size of a single document in bytes.
    pub avg_document_size_bytes: i64,
    /// Search requests per month.
    pub search_requests_per_month: i64,
    /// Write operations per month (reserved — no current calculator bills per-write).
    pub write_operations_per_month: i64,
    /// Number of sort directions (0–10). Algolia standard replicas multiply record count.
    pub sort_directions: u8,
    /// Number of indexes (reserved — no current calculator uses this).
    pub num_indexes: i64,
    /// Whether high-availability (multi-node) deployment is required.
    pub high_availability: bool,
}

/// Errors returned when a [`WorkloadProfile`] fails validation.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ValidationError {
    #[error("document_count must be > 0, got {0}")]
    InvalidDocumentCount(i64),
    #[error("avg_document_size_bytes must be > 0, got {0}")]
    InvalidAvgDocumentSize(i64),
    #[error("search_requests_per_month must be >= 0, got {0}")]
    InvalidSearchRequests(i64),
    #[error("write_operations_per_month must be >= 0, got {0}")]
    InvalidWriteOperations(i64),
    #[error("sort_directions must be 0..=10, got {0}")]
    InvalidSortDirections(u8),
    #[error("num_indexes must be >= 0, got {0}")]
    InvalidNumIndexes(i64),
    #[error(
        "document_count * avg_document_size_bytes is too large for safe cost calculation, got {0}"
    )]
    StorageInputTooLarge(i128),
    #[error(
        "search_requests_per_month * avg_document_size_bytes is too large for safe cost calculation, got {0}"
    )]
    BandwidthInputTooLarge(i128),
}

/// 1 GiB in bytes (binary: 2^30).
const BYTES_PER_GIB: i64 = 1_073_741_824;

/// 1 MB in bytes (decimal: 10^6). Used for Flapjack Cloud hot-storage pricing.
pub const BYTES_PER_MB: i64 = 1_000_000;

// `document_count * avg_document_size_bytes` upper bound that keeps
// storage-based cent calculations inside `i64` across providers.
const MAX_STORAGE_INPUT_PRODUCT_BYTES: i128 = 600_213_352_380_790_436_249_651_634;

// `search_requests_per_month * avg_document_size_bytes` upper bound that keeps
// bandwidth-based cent calculations inside `i64` across providers.
const MAX_BANDWIDTH_INPUT_PRODUCT_BYTES: i128 = 30_744_573_456_182_586_023_333_333;

/// Hours per month (365.25 days/year × 24 hours/day / 12 months ≈ 730.5,
/// rounded to 730 — the industry-standard billing constant).
/// Single source of truth — provider modules must use this for hourly→monthly
/// conversions rather than declaring their own copy.
pub const HOURS_PER_MONTH: Decimal = dec!(730);

impl WorkloadProfile {
    /// Validates all fields. Calculators can assume valid input after this passes.
    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.document_count <= 0 {
            return Err(ValidationError::InvalidDocumentCount(self.document_count));
        }
        if self.avg_document_size_bytes <= 0 {
            return Err(ValidationError::InvalidAvgDocumentSize(
                self.avg_document_size_bytes,
            ));
        }
        if self.search_requests_per_month < 0 {
            return Err(ValidationError::InvalidSearchRequests(
                self.search_requests_per_month,
            ));
        }
        if self.write_operations_per_month < 0 {
            return Err(ValidationError::InvalidWriteOperations(
                self.write_operations_per_month,
            ));
        }
        if self.sort_directions > 10 {
            return Err(ValidationError::InvalidSortDirections(self.sort_directions));
        }
        if self.num_indexes < 0 {
            return Err(ValidationError::InvalidNumIndexes(self.num_indexes));
        }

        let storage_input_product =
            i128::from(self.document_count) * i128::from(self.avg_document_size_bytes);
        if storage_input_product > MAX_STORAGE_INPUT_PRODUCT_BYTES {
            return Err(ValidationError::StorageInputTooLarge(storage_input_product));
        }

        let bandwidth_input_product =
            i128::from(self.search_requests_per_month) * i128::from(self.avg_document_size_bytes);
        if bandwidth_input_product > MAX_BANDWIDTH_INPUT_PRODUCT_BYTES {
            return Err(ValidationError::BandwidthInputTooLarge(
                bandwidth_input_product,
            ));
        }

        Ok(())
    }

    /// Total raw storage in decimal MB: `document_count * avg_document_size_bytes / BYTES_PER_MB`.
    ///
    /// Flapjack Cloud prices hot storage per-MB (decimal megabyte, 1_000_000 bytes).
    /// Provider calculators that bill per-MB must call this rather than re-deriving.
    pub fn storage_mb(&self) -> Decimal {
        let total_bytes =
            Decimal::from(self.document_count) * Decimal::from(self.avg_document_size_bytes);
        total_bytes / Decimal::from(BYTES_PER_MB)
    }

    /// Total raw storage in GiB: `document_count * avg_document_size_bytes / BYTES_PER_GIB`.
    ///
    /// Single source of truth for storage derivation — provider calculators and
    /// RAM heuristics must call this rather than re-deriving.
    pub fn storage_gib(&self) -> Decimal {
        let bytes_per_document_gib =
            Decimal::from(self.avg_document_size_bytes) / Decimal::from(BYTES_PER_GIB);

        Decimal::from(self.document_count)
            .checked_mul(bytes_per_document_gib)
            .expect("GiB scaling keeps valid i64 workloads within Decimal range")
    }
}

// ============================================================================
// Provider identity
// ============================================================================

/// Identifies a search provider in the comparison catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProviderId {
    Algolia,
    #[serde(rename = "Flapjack Cloud", alias = "Griddle")]
    Griddle,
    MeilisearchUsageBased,
    MeilisearchResourceBased,
    TypesenseCloud,
    ElasticCloud,
    AwsOpenSearch,
}

// ============================================================================
// Provider metadata
// ============================================================================

/// Metadata about a search provider in the comparison catalog.
///
/// Each provider module owns its metadata inputs (name, verification date,
/// source URLs). The registry in `providers/mod.rs` composes them via each
/// module's `metadata()` function.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderMetadata {
    /// Which provider this metadata describes.
    pub id: ProviderId,
    /// Human-readable provider name (e.g. "Algolia", "Typesense Cloud").
    pub display_name: String,
    /// Date the pricing data was last manually verified against source URLs.
    ///
    /// `None` means the module still relies on modeled or training-data inputs
    /// and must not claim a verified pricing date yet.
    pub last_verified: Option<NaiveDate>,
    /// URLs where the pricing data was sourced/verified.
    pub source_urls: Vec<String>,
}

impl ProviderMetadata {
    /// Human-readable verification label for logs and UI surfaces.
    pub fn verification_label(&self) -> String {
        self.last_verified
            .map(|date| date.to_string())
            .unwrap_or_else(|| "unverified".to_string())
    }

    /// Returns whether this provider has a source-backed verification date.
    pub fn is_verified(&self) -> bool {
        self.last_verified.is_some()
    }
}

// ============================================================================
// Cost estimate (output)
// ============================================================================

/// One line on a cost estimate, corresponding to a single billing dimension.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CostLineItem {
    pub description: String,
    /// The quantity in the given `unit` (e.g. 100.0 for 100K searches).
    pub quantity: Decimal,
    /// Unit label: "records_1k", "searches_1k", "gb_months", "instance_hours", etc.
    pub unit: String,
    /// Price per unit in cents.
    pub unit_price_cents: Decimal,
    /// Total for this line item in cents, rounded to nearest cent.
    pub amount_cents: i64,
}

/// A cost estimate for one provider, given a workload profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EstimatedCost {
    pub provider: ProviderId,
    /// Total monthly cost in cents. Must equal `line_items.iter().map(|li| li.amount_cents).sum()`.
    pub monthly_total_cents: i64,
    pub line_items: Vec<CostLineItem>,
    /// Transparency notes explaining assumptions behind the estimate.
    pub assumptions: Vec<String>,
    /// Plan or tier name if applicable (e.g. "Grow", "Pro", "r6g.large.search").
    pub plan_name: Option<String>,
}

/// The result of comparing all providers for a given workload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ComparisonResult {
    pub workload: WorkloadProfile,
    /// Estimates sorted cheapest-first by `monthly_total_cents`.
    pub estimates: Vec<EstimatedCost>,
    pub generated_at: DateTime<Utc>,
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn valid_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2048,
            search_requests_per_month: 50_000,
            write_operations_per_month: 1_000,
            sort_directions: 3,
            num_indexes: 2,
            high_availability: false,
        }
    }

    // --- WorkloadProfile::validate() -----------------------------------------

    #[test]
    fn provider_id_serializes_flapjack_cloud_public_brand() {
        // Keep the internal enum variant stable while making API JSON use the
        // public brand that browser and docs surfaces assert.
        let serialized = serde_json::to_string(&ProviderId::Griddle).unwrap();

        assert_eq!(serialized, "\"Flapjack Cloud\"");
    }

    #[test]
    fn provider_id_accepts_legacy_griddle_alias() {
        let provider: ProviderId = serde_json::from_str("\"Griddle\"").unwrap();

        assert_eq!(provider, ProviderId::Griddle);
    }

    #[test]
    fn valid_workload_passes_validation() {
        assert!(valid_workload().validate().is_ok());
    }

    #[test]
    fn zero_document_count_rejected() {
        let w = WorkloadProfile {
            document_count: 0,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidDocumentCount(0))
        ));
    }

    #[test]
    fn negative_document_count_rejected() {
        let w = WorkloadProfile {
            document_count: -1,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidDocumentCount(-1))
        ));
    }

    #[test]
    fn zero_avg_document_size_rejected() {
        let w = WorkloadProfile {
            avg_document_size_bytes: 0,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidAvgDocumentSize(0))
        ));
    }

    #[test]
    fn negative_avg_document_size_rejected() {
        let w = WorkloadProfile {
            avg_document_size_bytes: -1,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidAvgDocumentSize(-1))
        ));
    }

    #[test]
    fn negative_search_requests_rejected() {
        let w = WorkloadProfile {
            search_requests_per_month: -1,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidSearchRequests(-1))
        ));
    }

    #[test]
    fn zero_search_requests_allowed() {
        let w = WorkloadProfile {
            search_requests_per_month: 0,
            ..valid_workload()
        };
        assert!(w.validate().is_ok());
    }

    #[test]
    fn negative_write_operations_rejected() {
        let w = WorkloadProfile {
            write_operations_per_month: -1,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidWriteOperations(-1))
        ));
    }

    #[test]
    fn sort_directions_above_10_rejected() {
        let w = WorkloadProfile {
            sort_directions: 11,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidSortDirections(11))
        ));
    }

    #[test]
    fn sort_directions_10_allowed() {
        let w = WorkloadProfile {
            sort_directions: 10,
            ..valid_workload()
        };
        assert!(w.validate().is_ok());
    }

    #[test]
    fn negative_num_indexes_rejected() {
        let w = WorkloadProfile {
            num_indexes: -1,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::InvalidNumIndexes(-1))
        ));
    }

    #[test]
    fn storage_input_product_too_large_rejected() {
        let w = WorkloadProfile {
            document_count: i64::MAX,
            avg_document_size_bytes: 100_000_000,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::StorageInputTooLarge(_))
        ));
    }

    #[test]
    fn bandwidth_input_product_too_large_rejected() {
        let w = WorkloadProfile {
            search_requests_per_month: i64::MAX,
            avg_document_size_bytes: 4_000_000,
            ..valid_workload()
        };
        assert!(matches!(
            w.validate(),
            Err(ValidationError::BandwidthInputTooLarge(_))
        ));
    }

    // --- WorkloadProfile::storage_gib() --------------------------------------

    #[test]
    fn storage_gib_small_dataset() {
        // 100K docs × 2KB = 200MB = 200,000,000 / 1,073,741,824 ≈ 0.186 GiB
        let w = WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2_000,
            ..valid_workload()
        };
        let gib = w.storage_gib();
        // 200_000_000 / 1_073_741_824 = 0.18626... GiB
        assert!(gib > dec!(0.186) && gib < dec!(0.187));
    }

    #[test]
    fn storage_gib_large_dataset() {
        // 10M docs × 5KB = 50GB = 50,000,000,000 / 1,073,741,824 ≈ 46.566 GiB
        let w = WorkloadProfile {
            document_count: 10_000_000,
            avg_document_size_bytes: 5_000,
            ..valid_workload()
        };
        let gib = w.storage_gib();
        assert!(gib > dec!(46.5) && gib < dec!(46.6));
    }

    #[test]
    fn storage_gib_exactly_one_gib() {
        // 1 doc × 1,073,741,824 bytes = exactly 1 GiB
        let w = WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 1_073_741_824,
            ..valid_workload()
        };
        assert_eq!(w.storage_gib(), dec!(1));
    }

    #[test]
    fn storage_gib_max_valid_inputs_do_not_panic() {
        let w = WorkloadProfile {
            document_count: i64::MAX,
            avg_document_size_bytes: i64::MAX,
            ..valid_workload()
        };

        let gib = w.storage_gib();

        assert!(gib > Decimal::ZERO);
    }

    // --- WorkloadProfile::storage_mb() (decimal MB) --------------------------

    #[test]
    fn storage_mb_one_megabyte() {
        // 1 doc × 1_000_000 bytes = exactly 1 MB (decimal)
        let w = WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 1_000_000,
            ..valid_workload()
        };
        assert_eq!(w.storage_mb(), dec!(1));
    }

    #[test]
    fn storage_mb_one_billion_bytes_equals_1000_mb() {
        // 1 doc × 1_000_000_000 bytes = 1000 MB (decimal, not 1024)
        let w = WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 1_000_000_000,
            ..valid_workload()
        };
        assert_eq!(w.storage_mb(), dec!(1000));
    }

    #[test]
    fn storage_mb_small_dataset() {
        // 100K docs × 2500 bytes = 250_000_000 bytes = 250 MB
        let w = WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2_500,
            ..valid_workload()
        };
        assert_eq!(w.storage_mb(), dec!(250));
    }

    #[test]
    fn storage_mb_does_not_use_gib_divisor() {
        // 1 GiB in bytes = 1_073_741_824. If storage_mb() accidentally used the
        // GiB constant (1_073_741_824) instead of the MB constant (1_000_000),
        // the result would be ~1024 MB instead of the correct ~1073.741824 MB.
        let w = WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 1_073_741_824,
            ..valid_workload()
        };
        let mb = w.storage_mb();
        // Correct: 1_073_741_824 / 1_000_000 = 1073.741824
        assert!(mb > dec!(1073) && mb < dec!(1074), "got {mb}");
    }

    // --- EstimatedCost line item sum invariant -------------------------------

    /// Enforces billing transparency: monthly_total_cents must always equal the exact sum of all emitted line-item amounts.
    #[test]
    fn estimated_cost_total_equals_line_item_sum() {
        let line_items = vec![
            CostLineItem {
                description: "Search requests".to_string(),
                quantity: dec!(50),
                unit: "searches_1k".to_string(),
                unit_price_cents: dec!(50),
                amount_cents: 2500,
            },
            CostLineItem {
                description: "Records".to_string(),
                quantity: dec!(100),
                unit: "records_1k".to_string(),
                unit_price_cents: dec!(40),
                amount_cents: 4000,
            },
        ];
        let total: i64 = line_items.iter().map(|li| li.amount_cents).sum();
        let estimate = EstimatedCost {
            provider: ProviderId::Algolia,
            monthly_total_cents: total,
            line_items,
            assumptions: vec!["Test assumption".to_string()],
            plan_name: Some("Grow".to_string()),
        };
        assert_eq!(
            estimate.monthly_total_cents,
            estimate
                .line_items
                .iter()
                .map(|li| li.amount_cents)
                .sum::<i64>()
        );
    }

    /// Documents the zero-usage edge case where an empty line-item vector serializes to a zero monthly total.
    #[test]
    fn estimated_cost_empty_line_items_sums_to_zero() {
        let estimate = EstimatedCost {
            provider: ProviderId::TypesenseCloud,
            monthly_total_cents: 0,
            line_items: vec![],
            assumptions: vec![],
            plan_name: None,
        };
        assert_eq!(
            estimate.monthly_total_cents,
            estimate
                .line_items
                .iter()
                .map(|li| li.amount_cents)
                .sum::<i64>()
        );
    }
}

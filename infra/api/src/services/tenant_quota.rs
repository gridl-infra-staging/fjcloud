//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/services/tenant_quota.rs.
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

// Launch default: 10 RPS. Plan to raise within a few months of public launch.
const DEFAULT_MAX_QUERY_RPS: u32 = 10;
const DEFAULT_MAX_WRITE_RPS: u32 = 10;
const DEFAULT_MAX_STORAGE_BYTES: u64 = 10_737_418_240; // 10 GB
const DEFAULT_MAX_INDEXES: u32 = 10;
const DEFAULT_FREE_TIER_MAX_INDEXES: u32 = 1;
const DEFAULT_FREE_TIER_MAX_SEARCHES_PER_MONTH: u64 = 50_000;
const DEFAULT_FREE_TIER_MAX_RECORDS: u64 = 100_000;
const DEFAULT_FREE_TIER_MAX_STORAGE_GB: u64 = 10;
const RATE_WINDOW: Duration = Duration::from_secs(1);

/// Resolved quota for a tenant-index pair, merging per-index overrides with global defaults.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolvedQuota {
    pub max_query_rps: u32,
    pub max_write_rps: u32,
    pub max_storage_bytes: u64,
    pub max_indexes: u32,
}

impl Default for ResolvedQuota {
    fn default() -> Self {
        Self {
            max_query_rps: DEFAULT_MAX_QUERY_RPS,
            max_write_rps: DEFAULT_MAX_WRITE_RPS,
            max_storage_bytes: DEFAULT_MAX_STORAGE_BYTES,
            max_indexes: DEFAULT_MAX_INDEXES,
        }
    }
}

/// Global default quotas, configurable via environment variables.
#[derive(Debug, Clone)]
pub struct QuotaDefaults {
    pub max_query_rps: u32,
    pub max_write_rps: u32,
    pub max_storage_bytes: u64,
    pub max_indexes: u32,
}

impl Default for QuotaDefaults {
    fn default() -> Self {
        Self {
            max_query_rps: DEFAULT_MAX_QUERY_RPS,
            max_write_rps: DEFAULT_MAX_WRITE_RPS,
            max_storage_bytes: DEFAULT_MAX_STORAGE_BYTES,
            max_indexes: DEFAULT_MAX_INDEXES,
        }
    }
}

impl QuotaDefaults {
    /// Reads global quota defaults from environment variables
    /// (`DEFAULT_MAX_QUERY_RPS`, `DEFAULT_MAX_WRITE_RPS`,
    /// `DEFAULT_MAX_STORAGE_BYTES`, `DEFAULT_MAX_INDEXES`).
    ///
    /// Parses each as a positive integer, filtering out zero and unparseable
    /// values, and falls back to the compiled constant for any missing or
    /// invalid entry.
    pub fn from_env() -> Self {
        Self {
            max_query_rps: std::env::var("DEFAULT_MAX_QUERY_RPS")
                .ok()
                .and_then(|v| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_MAX_QUERY_RPS),
            max_write_rps: std::env::var("DEFAULT_MAX_WRITE_RPS")
                .ok()
                .and_then(|v| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_MAX_WRITE_RPS),
            max_storage_bytes: std::env::var("DEFAULT_MAX_STORAGE_BYTES")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_MAX_STORAGE_BYTES),
            max_indexes: std::env::var("DEFAULT_MAX_INDEXES")
                .ok()
                .and_then(|v| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_MAX_INDEXES),
        }
    }
}

/// Limits enforced for customers on the free billing plan.
#[derive(Debug, Clone)]
pub struct FreeTierLimits {
    pub max_indexes: u32,
    pub max_searches_per_month: u64,
}

impl Default for FreeTierLimits {
    fn default() -> Self {
        Self {
            max_indexes: DEFAULT_FREE_TIER_MAX_INDEXES,
            max_searches_per_month: DEFAULT_FREE_TIER_MAX_SEARCHES_PER_MONTH,
        }
    }
}

impl FreeTierLimits {
    pub fn default_max_records() -> u64 {
        DEFAULT_FREE_TIER_MAX_RECORDS
    }

    pub fn default_max_storage_gb() -> u64 {
        DEFAULT_FREE_TIER_MAX_STORAGE_GB
    }

    pub fn from_env() -> Self {
        Self {
            max_indexes: std::env::var("FREE_TIER_MAX_INDEXES")
                .ok()
                .and_then(|v| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_FREE_TIER_MAX_INDEXES),
            max_searches_per_month: std::env::var("FREE_TIER_MAX_SEARCHES_PER_MONTH")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(DEFAULT_FREE_TIER_MAX_SEARCHES_PER_MONTH),
        }
    }
}

/// Error returned when a tenant exceeds their rate limit.
#[derive(Debug)]
pub struct QuotaExceeded {
    pub retry_after: u64,
}

/// Per-tenant per-index rate limiting with variable limits per key.
///
/// Uses a sliding-window approach (same pattern as the generic `RateLimiter` in `router.rs`)
/// but allows each key to have a different limit.
pub struct TenantQuotaService {
    defaults: QuotaDefaults,
    /// Sliding-window state: key -> (timestamps, limit_per_second)
    query_state: Mutex<SlidingWindowState>,
    write_state: Mutex<SlidingWindowState>,
    /// Cached per-index quotas: "{customer_id}:{index_name}" -> (quota, fetched_at)
    quota_cache: Mutex<HashMap<String, (ResolvedQuota, Instant)>>,
    cache_ttl: Duration,
}

struct SlidingWindowState {
    windows: HashMap<String, VecDeque<Instant>>,
    last_cleanup: Instant,
}

impl SlidingWindowState {
    fn new() -> Self {
        Self {
            windows: HashMap::new(),
            last_cleanup: Instant::now(),
        }
    }

    /// Check if a request for `key` is allowed under the given `limit` (per window).
    /// Returns `None` if allowed, or `Some(retry_after_secs)` if rate-limited.
    fn check(&mut self, key: &str, limit: u32) -> Option<u64> {
        let effective_limit = limit.max(1);
        let now = Instant::now();
        let window_start = now - RATE_WINDOW;

        // Periodic cleanup of stale entries
        if now.saturating_duration_since(self.last_cleanup) >= Duration::from_secs(30) {
            self.windows.retain(|_, requests| {
                while let Some(oldest) = requests.front() {
                    if *oldest <= window_start {
                        requests.pop_front();
                    } else {
                        break;
                    }
                }
                !requests.is_empty()
            });
            self.last_cleanup = now;
        }

        let requests = self.windows.entry(key.to_string()).or_default();

        // Evict expired entries
        while let Some(oldest) = requests.front() {
            if *oldest <= window_start {
                requests.pop_front();
            } else {
                break;
            }
        }

        if requests.len() >= effective_limit as usize {
            // Rate limited — compute retry-after
            let oldest = requests
                .front()
                .copied()
                .expect("request queue should not be empty when at limit");
            let elapsed = now.saturating_duration_since(oldest);
            let retry_after = RATE_WINDOW.saturating_sub(elapsed).as_secs().max(1);
            return Some(retry_after);
        }

        requests.push_back(now);
        None
    }
}

impl TenantQuotaService {
    pub fn new(defaults: QuotaDefaults) -> Self {
        Self {
            defaults,
            query_state: Mutex::new(SlidingWindowState::new()),
            write_state: Mutex::new(SlidingWindowState::new()),
            quota_cache: Mutex::new(HashMap::new()),
            cache_ttl: Duration::from_secs(60),
        }
    }

    fn quota_cache_key(customer_id: Uuid, index_name: &str) -> String {
        format!("{customer_id}:{index_name}")
    }

    fn check_rate_limit(
        state: &Mutex<SlidingWindowState>,
        key: &str,
        limit: u32,
    ) -> Result<(), QuotaExceeded> {
        let mut state = state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match state.check(key, limit) {
            None => Ok(()),
            Some(retry_after) => Err(QuotaExceeded { retry_after }),
        }
    }

    /// Resolve the effective quota for a tenant-index pair, merging per-index overrides
    /// with global defaults.
    pub fn resolve_quota(&self, resource_quota: &serde_json::Value) -> ResolvedQuota {
        ResolvedQuota {
            max_query_rps: parse_positive_u32(resource_quota, "max_query_rps")
                .unwrap_or(self.defaults.max_query_rps),
            max_write_rps: parse_positive_u32(resource_quota, "max_write_rps")
                .unwrap_or(self.defaults.max_write_rps),
            max_storage_bytes: parse_positive_u64(resource_quota, "max_storage_bytes")
                .unwrap_or(self.defaults.max_storage_bytes),
            max_indexes: parse_positive_u32(resource_quota, "max_indexes")
                .unwrap_or(self.defaults.max_indexes),
        }
    }

    /// Cache a resolved quota for a tenant-index pair.
    pub fn cache_quota(&self, customer_id: Uuid, index_name: &str, quota: ResolvedQuota) {
        let key = Self::quota_cache_key(customer_id, index_name);
        let mut cache = self.quota_cache.lock().unwrap();
        cache.insert(key, (quota, Instant::now()));
    }

    /// Get cached quota, or None if expired/missing.
    pub fn get_cached_quota(&self, customer_id: Uuid, index_name: &str) -> Option<ResolvedQuota> {
        let key = Self::quota_cache_key(customer_id, index_name);
        let cache = self.quota_cache.lock().unwrap();
        cache.get(&key).and_then(|(quota, fetched_at)| {
            if fetched_at.elapsed() < self.cache_ttl {
                Some(quota.clone())
            } else {
                None
            }
        })
    }

    /// Invalidate cached quota for a tenant-index pair (e.g., after admin updates).
    pub fn invalidate_quota(&self, customer_id: Uuid, index_name: &str) {
        let key = Self::quota_cache_key(customer_id, index_name);
        self.quota_cache.lock().unwrap().remove(&key);
    }

    /// Check the query rate limit for a tenant-index pair.
    /// Returns `Ok(())` if allowed, `Err(QuotaExceeded)` if rate-limited.
    pub fn check_query_rate(
        &self,
        customer_id: Uuid,
        index_name: &str,
        quota: &ResolvedQuota,
    ) -> Result<(), QuotaExceeded> {
        let key = Self::quota_cache_key(customer_id, index_name);
        Self::check_rate_limit(&self.query_state, &key, quota.max_query_rps)
    }

    /// Check the write rate limit for a tenant-index pair.
    /// Returns `Ok(())` if allowed, `Err(QuotaExceeded)` if rate-limited.
    pub fn check_write_rate(
        &self,
        customer_id: Uuid,
        index_name: &str,
        quota: &ResolvedQuota,
    ) -> Result<(), QuotaExceeded> {
        let key = Self::quota_cache_key(customer_id, index_name);
        Self::check_rate_limit(&self.write_state, &key, quota.max_write_rps)
    }

    /// Get the default quotas (for admin display when no per-index override exists).
    pub fn defaults(&self) -> &QuotaDefaults {
        &self.defaults
    }
}

fn parse_positive_u32(value: &serde_json::Value, key: &str) -> Option<u32> {
    value
        .get(key)
        .and_then(|v| v.as_u64())
        .and_then(|raw| u32::try_from(raw).ok())
        .filter(|v| *v > 0)
}

fn parse_positive_u64(value: &serde_json::Value, key: &str) -> Option<u64> {
    value.get(key).and_then(|v| v.as_u64()).filter(|v| *v > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn free_tier_limits_from_env_uses_defaults() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FREE_TIER_MAX_INDEXES");
        std::env::remove_var("FREE_TIER_MAX_SEARCHES_PER_MONTH");

        let limits = FreeTierLimits::from_env();
        assert_eq!(limits.max_indexes, 1);
        assert_eq!(limits.max_searches_per_month, 50_000);
    }

    #[test]
    fn free_tier_limits_from_env_reads_overrides() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::set_var("FREE_TIER_MAX_INDEXES", "3");
        std::env::set_var("FREE_TIER_MAX_SEARCHES_PER_MONTH", "75000");

        let limits = FreeTierLimits::from_env();
        assert_eq!(limits.max_indexes, 3);
        assert_eq!(limits.max_searches_per_month, 75_000);

        std::env::remove_var("FREE_TIER_MAX_INDEXES");
        std::env::remove_var("FREE_TIER_MAX_SEARCHES_PER_MONTH");
    }

    #[test]
    fn free_tier_limits_defaults_cover_records_and_storage() {
        assert_eq!(FreeTierLimits::default_max_records(), 100_000);
        assert_eq!(FreeTierLimits::default_max_storage_gb(), 10);
    }

    #[test]
    fn resolve_quota_uses_defaults_when_overrides_empty() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let empty = serde_json::json!({});
        let q = svc.resolve_quota(&empty);
        assert_eq!(q.max_query_rps, DEFAULT_MAX_QUERY_RPS);
        assert_eq!(q.max_write_rps, DEFAULT_MAX_WRITE_RPS);
        assert_eq!(q.max_storage_bytes, DEFAULT_MAX_STORAGE_BYTES);
        assert_eq!(q.max_indexes, DEFAULT_MAX_INDEXES);
    }

    #[test]
    fn resolve_quota_applies_per_index_overrides() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let overrides = serde_json::json!({
            "max_query_rps": 500,
            "max_storage_bytes": 1_073_741_824_u64, // 1 GB
        });
        let q = svc.resolve_quota(&overrides);
        assert_eq!(q.max_query_rps, 500);
        assert_eq!(q.max_storage_bytes, 1_073_741_824);
        // Unset fields fall back to defaults
        assert_eq!(q.max_write_rps, DEFAULT_MAX_WRITE_RPS);
        assert_eq!(q.max_indexes, DEFAULT_MAX_INDEXES);
    }

    /// Verifies that per-index quota overrides of zero or negative values are
    /// ignored, falling back to the global defaults rather than applying an
    /// invalid limit.
    #[test]
    fn resolve_quota_ignores_zero_and_negative_overrides() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let bad = serde_json::json!({
            "max_query_rps": 0,
            "max_write_rps": -5,
            "max_storage_bytes": 0,
        });
        let q = svc.resolve_quota(&bad);
        assert_eq!(
            q.max_query_rps, DEFAULT_MAX_QUERY_RPS,
            "zero should fall back to default"
        );
        assert_eq!(
            q.max_write_rps, DEFAULT_MAX_WRITE_RPS,
            "negative should fall back to default"
        );
        assert_eq!(
            q.max_storage_bytes, DEFAULT_MAX_STORAGE_BYTES,
            "zero bytes should fall back"
        );
    }

    #[test]
    fn check_query_rate_allows_within_limit() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let quota = ResolvedQuota {
            max_query_rps: 5,
            ..Default::default()
        };
        let cid = Uuid::new_v4();
        // 5 requests within 1-second window should all pass
        for _ in 0..5 {
            assert!(svc.check_query_rate(cid, "idx", &quota).is_ok());
        }
    }

    /// Verifies that the sliding-window rate limiter rejects requests once the
    /// per-second query limit is reached, returning a [`QuotaExceeded`] error
    /// with a positive `retry_after` value.
    #[test]
    fn check_query_rate_rejects_at_limit() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let quota = ResolvedQuota {
            max_query_rps: 3,
            ..Default::default()
        };
        let cid = Uuid::new_v4();
        // Fill the window
        for _ in 0..3 {
            assert!(svc.check_query_rate(cid, "idx", &quota).is_ok());
        }
        // 4th request should be rejected with retry_after > 0
        let err = svc.check_query_rate(cid, "idx", &quota).unwrap_err();
        assert!(
            err.retry_after >= 1,
            "retry_after should be at least 1 second"
        );
    }

    #[test]
    fn check_write_rate_independent_of_query_rate() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let quota = ResolvedQuota {
            max_query_rps: 1,
            max_write_rps: 1,
            ..Default::default()
        };
        let cid = Uuid::new_v4();
        // Exhaust query rate
        assert!(svc.check_query_rate(cid, "idx", &quota).is_ok());
        assert!(svc.check_query_rate(cid, "idx", &quota).is_err());
        // Write rate should still be available (separate window)
        assert!(svc.check_write_rate(cid, "idx", &quota).is_ok());
    }

    /// Verifies that a quota stored via `cache_quota` can be retrieved by
    /// `get_cached_quota` with the same customer ID and index name, and that
    /// the cache starts empty for unseen keys.
    #[test]
    fn cache_quota_round_trips() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let cid = Uuid::new_v4();
        let quota = ResolvedQuota {
            max_query_rps: 999,
            ..Default::default()
        };
        assert!(
            svc.get_cached_quota(cid, "my-index").is_none(),
            "cache starts empty"
        );
        svc.cache_quota(cid, "my-index", quota);
        let cached = svc
            .get_cached_quota(cid, "my-index")
            .expect("should be cached");
        assert_eq!(cached.max_query_rps, 999);
    }

    #[test]
    fn invalidate_quota_removes_from_cache() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let cid = Uuid::new_v4();
        svc.cache_quota(cid, "idx", ResolvedQuota::default());
        assert!(svc.get_cached_quota(cid, "idx").is_some());
        svc.invalidate_quota(cid, "idx");
        assert!(
            svc.get_cached_quota(cid, "idx").is_none(),
            "should be gone after invalidation"
        );
    }

    #[test]
    fn different_tenants_have_independent_rate_windows() {
        let svc = TenantQuotaService::new(QuotaDefaults::default());
        let quota = ResolvedQuota {
            max_query_rps: 1,
            ..Default::default()
        };
        let cid_a = Uuid::new_v4();
        let cid_b = Uuid::new_v4();
        // Exhaust tenant A
        assert!(svc.check_query_rate(cid_a, "idx", &quota).is_ok());
        assert!(svc.check_query_rate(cid_a, "idx", &quota).is_err());
        // Tenant B should still be fine
        assert!(svc.check_query_rate(cid_b, "idx", &quota).is_ok());
    }
}

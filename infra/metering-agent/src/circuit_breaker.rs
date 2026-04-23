//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/metering-agent/src/circuit_breaker.rs.
use std::time::Duration;

/// Circuit breaker for flapjack connectivity.
///
/// Tracks consecutive scrape failures. After `OPEN_THRESHOLD` failures,
/// switches to exponential backoff: 30s, 60s, 120s, 300s (capped).
/// On first success after backoff, resumes normal scrape interval.
pub struct CircuitBreaker {
    consecutive_failures: u32,
    normal_interval: Duration,
}

const OPEN_THRESHOLD: u32 = 5;

/// Backoff durations once the circuit is open: 30s, 60s, 120s, 300s.
const BACKOFF_SECS: [u64; 4] = [30, 60, 120, 300];

impl CircuitBreaker {
    /// Create a new circuit breaker with the given normal (healthy) interval.
    pub fn new(normal_interval: Duration) -> Self {
        Self {
            consecutive_failures: 0,
            normal_interval,
        }
    }

    /// Record a successful scrape. Resets failure count.
    /// Returns the normal scrape interval.
    pub fn record_success(&mut self) -> Duration {
        self.consecutive_failures = 0;
        self.normal_interval
    }

    /// Record a failed scrape. Increments failure count.
    /// Returns the next interval to wait before retrying:
    /// - Normal interval while below threshold
    /// - Exponential backoff once threshold is reached
    pub fn record_failure(&mut self) -> Duration {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);

        if self.consecutive_failures < OPEN_THRESHOLD {
            return self.normal_interval;
        }

        // Failures beyond threshold: index into backoff table (capped at last entry)
        let backoff_index = (self.consecutive_failures - OPEN_THRESHOLD) as usize;
        let capped_index = backoff_index.min(BACKOFF_SECS.len() - 1);
        Duration::from_secs(BACKOFF_SECS[capped_index])
    }

    /// Whether the circuit breaker is currently open (in backoff mode).
    pub fn is_open(&self) -> bool {
        self.consecutive_failures >= OPEN_THRESHOLD
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_interval_returned_below_threshold() {
        let mut cb = CircuitBreaker::new(Duration::from_secs(60));
        for _ in 0..4 {
            assert_eq!(cb.record_failure(), Duration::from_secs(60));
        }
        assert!(!cb.is_open());
    }

    #[test]
    fn opens_after_five_failures() {
        let mut cb = CircuitBreaker::new(Duration::from_secs(60));
        for _ in 0..4 {
            cb.record_failure();
        }
        assert!(!cb.is_open());

        // 5th failure triggers open
        let interval = cb.record_failure();
        assert!(cb.is_open());
        assert_eq!(interval, Duration::from_secs(30)); // first backoff step
    }

    #[test]
    fn exponential_backoff_sequence() {
        let mut cb = CircuitBreaker::new(Duration::from_secs(60));
        // Burn through threshold
        for _ in 0..5 {
            cb.record_failure();
        }
        // Now in backoff — subsequent failures escalate
        assert_eq!(cb.record_failure(), Duration::from_secs(60)); // 6th failure → 2nd backoff
        assert_eq!(cb.record_failure(), Duration::from_secs(120)); // 7th failure → 3rd backoff
        assert_eq!(cb.record_failure(), Duration::from_secs(300)); // 8th failure → 4th (max)
        assert_eq!(cb.record_failure(), Duration::from_secs(300)); // 9th failure → still max
    }

    #[test]
    fn success_closes_circuit() {
        let mut cb = CircuitBreaker::new(Duration::from_secs(60));
        for _ in 0..10 {
            cb.record_failure();
        }
        assert!(cb.is_open());

        let interval = cb.record_success();
        assert_eq!(interval, Duration::from_secs(60));
        assert!(!cb.is_open());
    }

    /// Guards that `record_success` performs a full reset of the failure
    /// counter, not just a decrement.
    ///
    /// After 7 failures (circuit open, in the middle of the backoff table),
    /// a single success must reset the count to zero so that the next 4
    /// failures remain below the open threshold.  Only the 5th subsequent
    /// failure should reopen the circuit.  A partial reset would leave the
    /// counter above zero and reopen too early.
    #[test]
    fn success_resets_failure_count_fully() {
        let mut cb = CircuitBreaker::new(Duration::from_secs(60));
        // Get into backoff
        for _ in 0..7 {
            cb.record_failure();
        }
        assert!(cb.is_open());

        // Recover
        cb.record_success();
        assert!(!cb.is_open());

        // 4 more failures should NOT open the circuit (count restarted from 0)
        for _ in 0..4 {
            assert_eq!(cb.record_failure(), Duration::from_secs(60));
        }
        assert!(!cb.is_open());

        // 5th failure opens again
        let interval = cb.record_failure();
        assert!(cb.is_open());
        assert_eq!(interval, Duration::from_secs(30));
    }
}

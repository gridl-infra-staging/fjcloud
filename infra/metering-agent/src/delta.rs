/// Computes the delta for a Prometheus-style monotonic counter that may reset.
///
/// Flapjack holds all counters in memory. They reset to 0 on process restart,
/// which is the standard `_total` counter pattern in Prometheus. The metering
/// agent MUST handle these resets so we never double-bill or under-bill.
///
/// Rules:
/// 1. `None` (first observation) → 0. We don't know usage before we started
///    watching, so we conservatively count nothing for the first scrape.
/// 2. `current >= previous` → `current - previous`. Normal monotonic increase.
/// 3. `current < previous` → `current`. A decrease means the counter was reset
///    to zero and has started counting again. The entire current value is new
///    usage accumulated since the restart.
pub fn counter_delta(previous: Option<u64>, current: u64) -> u64 {
    match previous {
        None => 0,
        Some(prev) if current >= prev => current - prev,
        Some(_) => current, // reset detected
    }
}

/// Per-metric state carried between scrapes.
#[derive(Debug, Default, Clone)]
pub struct CounterState {
    pub search_requests: Option<u64>,
    pub write_operations: Option<u64>,
    pub documents_indexed: Option<u64>,
    pub documents_deleted: Option<u64>,
}

impl CounterState {
    /// Compute deltas against a new set of raw counter values, then advance
    /// state to the new values.
    pub fn advance(
        &mut self,
        new_search: u64,
        new_writes: u64,
        new_indexed: u64,
        new_deleted: u64,
    ) -> CounterDeltas {
        let deltas = CounterDeltas {
            search_requests: counter_delta(self.search_requests, new_search),
            write_operations: counter_delta(self.write_operations, new_writes),
            documents_indexed: counter_delta(self.documents_indexed, new_indexed),
            documents_deleted: counter_delta(self.documents_deleted, new_deleted),
        };
        self.search_requests = Some(new_search);
        self.write_operations = Some(new_writes);
        self.documents_indexed = Some(new_indexed);
        self.documents_deleted = Some(new_deleted);
        deltas
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CounterDeltas {
    pub search_requests: u64,
    pub write_operations: u64,
    pub documents_indexed: u64,
    pub documents_deleted: u64,
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------------
    // counter_delta: primitive function
    // -------------------------------------------------------------------------

    #[test]
    fn first_observation_returns_zero() {
        // We don't know how long the counter was running before we started
        // watching. Billing nothing is safer than billing a potentially huge
        // number for historical activity.
        assert_eq!(counter_delta(None, 1_000), 0);
        assert_eq!(counter_delta(None, 0), 0);
    }

    #[test]
    fn normal_increment_returns_difference() {
        assert_eq!(counter_delta(Some(100), 150), 50);
        assert_eq!(counter_delta(Some(0), 1_000_000), 1_000_000);
    }

    #[test]
    fn no_change_returns_zero() {
        assert_eq!(counter_delta(Some(500), 500), 0);
    }

    #[test]
    fn reset_to_zero_returns_current_value() {
        // Process restarted; counter reset to 0 and some requests came in.
        assert_eq!(counter_delta(Some(9_999), 10), 10);
        assert_eq!(counter_delta(Some(1), 0), 0);
    }

    #[test]
    fn reset_and_large_new_value() {
        // Process restarted and immediately served a lot of traffic.
        assert_eq!(counter_delta(Some(50_000), 40_000), 40_000);
    }

    #[test]
    fn counter_at_u64_max_wraps_correctly_on_reset() {
        // Reset from near-max to small value
        assert_eq!(counter_delta(Some(u64::MAX - 5), 100), 100);
    }

    // -------------------------------------------------------------------------
    // CounterState: stateful multi-counter tracker
    // -------------------------------------------------------------------------

    #[test]
    fn first_advance_produces_zero_deltas() {
        let mut state = CounterState::default();
        let deltas = state.advance(1000, 200, 150, 50);

        assert_eq!(deltas.search_requests, 0);
        assert_eq!(deltas.write_operations, 0);
        assert_eq!(deltas.documents_indexed, 0);
        assert_eq!(deltas.documents_deleted, 0);
    }

    #[test]
    fn second_advance_returns_correct_deltas() {
        let mut state = CounterState::default();
        state.advance(1000, 200, 150, 50); // first scrape — establishes baseline

        let deltas = state.advance(1100, 250, 180, 55);

        assert_eq!(deltas.search_requests, 100);
        assert_eq!(deltas.write_operations, 50);
        assert_eq!(deltas.documents_indexed, 30);
        assert_eq!(deltas.documents_deleted, 5);
    }

    #[test]
    fn reset_detected_per_counter_independently() {
        let mut state = CounterState::default();
        state.advance(1000, 1000, 1000, 1000);

        // Only search counter reset; others kept going normally.
        let deltas = state.advance(10, 1200, 1100, 1050);

        assert_eq!(deltas.search_requests, 10); // reset: delta = current
        assert_eq!(deltas.write_operations, 200); // normal
        assert_eq!(deltas.documents_indexed, 100); // normal
        assert_eq!(deltas.documents_deleted, 50); // normal
    }

    #[test]
    fn state_advances_to_new_values_after_reset() {
        let mut state = CounterState::default();
        state.advance(5000, 0, 0, 0);
        state.advance(10, 0, 0, 0); // reset scrape — state now holds 10

        // Next scrape is a normal increment from 10
        let deltas = state.advance(60, 0, 0, 0);

        assert_eq!(deltas.search_requests, 50);
    }

    #[test]
    fn three_scrapes_accumulate_correctly() {
        let mut state = CounterState::default();
        state.advance(0, 0, 0, 0); // baseline
        state.advance(300, 0, 0, 0); // +300
        let d = state.advance(700, 0, 0, 0); // +400

        assert_eq!(d.search_requests, 400);
    }
}

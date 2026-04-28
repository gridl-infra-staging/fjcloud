
use std::future::Future;
use std::time::Duration;

/// Poll an async predicate until it returns `Some(value)`, then return the
/// value. Panics with a message that includes `name` if `timeout` elapses
/// first.
///
/// Parameters:
///   - `name`: short identifier embedded in the panic message so the test log
///     pinpoints which `poll_until` call timed out without reading the
///     predicate body. Required (no `&'static str` default) so callers must
///     name their wait points explicitly.
///   - `timeout`: total wall-clock budget. The predicate runs at least once;
///     if `timeout` is zero the predicate gets one shot and panic-or-return
///     happens immediately.
///   - `poll_interval`: sleep between predicate evaluations. CI minimum is
///     ~10 ms — going lower wastes CPU without changing correctness.
///   - `predicate`: `FnMut` so callers can mutate captured state across polls
///     (e.g., increment an attempt counter for diagnostic logging). The
///     `FnMut` bound is load-bearing — `Fn` would compile against simple
///     test cases but break the moment a real test wants to mutate.
///
/// Inline test design: see `mod tests` at the bottom — four tests covering
/// (1) immediate resolution, (2) resolution after N polls, (3) timeout panic
/// message, (4) `FnMut` mutability. Each test is constructed so it can fail
/// for a real defect, not just a false-positive smoke test.
pub async fn poll_until<T, F, Fut>(
    name: &'static str,
    timeout: Duration,
    poll_interval: Duration,
    mut predicate: F,
) -> T
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    // tokio::time::timeout wraps the inner loop so callers get a deterministic
    // upper bound even if the predicate itself blocks. The inner loop is the
    // simplest polling structure: call, check, sleep, repeat. The first call
    // happens BEFORE the first sleep — important for tests with timeout=0.
    tokio::time::timeout(timeout, async {
        loop {
            if let Some(v) = predicate().await {
                return v;
            }
            tokio::time::sleep(poll_interval).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("poll_until timed out: {name} (after {timeout:?})"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Instant;

    // -------------------------------------------------------------------
    // Test 1 — resolves immediately when predicate is true on first poll.
    //
    // Guards against a helper that ignores the predicate's return value
    // (e.g., always returns Default::default()). We assert on a non-default
    // sentinel value (42) and confirm the helper returns exactly that.
    // -------------------------------------------------------------------
    #[tokio::test]
    async fn resolves_immediately_with_predicate_value() {
        // Predicate returns Some(42) on the very first call — the helper
        // should return 42 without sleeping.
        let result = poll_until(
            "test1_immediate",
            Duration::from_secs(5),
            Duration::from_millis(10),
            || async { Some(42_u32) },
        )
        .await;
        assert_eq!(
            result, 42,
            "helper must return the value the predicate produced"
        );
    }

    // -------------------------------------------------------------------
    // Test 2 — resolves after N polls AND actually polled (not lucky timing).
    //
    // The predicate counts its own calls via an atomic. The helper should
    // call it 4 times (3 misses + 1 hit). We also assert wall-clock elapsed
    // is at least 3 * poll_interval — guards against a buggy helper that
    // returns Default on miss without sleeping (test 1 wouldn't catch this).
    // -------------------------------------------------------------------
    #[tokio::test]
    async fn resolves_after_multiple_polls_with_real_sleep() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_predicate = attempts.clone();
        let started = Instant::now();
        // poll_interval intentionally small enough to make the test fast
        // (~30ms total) but large enough that the elapsed-time assertion is
        // robust against scheduler jitter.
        let poll_interval = Duration::from_millis(10);

        let result = poll_until("test2_polls", Duration::from_secs(5), poll_interval, || {
            let n = attempts_for_predicate.fetch_add(1, Ordering::SeqCst) + 1;
            async move {
                if n >= 4 {
                    Some(format!("hit_after_{n}_attempts"))
                } else {
                    None
                }
            }
        })
        .await;

        let elapsed = started.elapsed();
        let final_attempts = attempts.load(Ordering::SeqCst);

        assert_eq!(result, "hit_after_4_attempts");
        assert_eq!(
            final_attempts, 4,
            "predicate must be called exactly 4 times"
        );
        // 3 sleeps of 10ms each between attempts 1-2, 2-3, 3-4 = ≥ 30ms.
        // Use a generous lower bound (25ms) to absorb scheduler jitter.
        assert!(
            elapsed >= Duration::from_millis(25),
            "helper must actually sleep between polls (elapsed = {elapsed:?})"
        );
    }

    // -------------------------------------------------------------------
    // Test 3 — times out and panics with the supplied name.
    //
    // The predicate always returns None. Helper must panic; panic message
    // must contain the `name` arg so test logs pinpoint which call timed out.
    // Without the name-in-message assertion, a bug that drops `name` would
    // pass — making timeout failures painful to debug.
    // -------------------------------------------------------------------
    #[tokio::test]
    #[should_panic(expected = "test3_must_appear_in_panic_message")]
    async fn times_out_and_panics_with_name() {
        // Use a tiny timeout (50ms) so the test is fast.
        // Use an even tinier poll_interval (5ms) so we know multiple polls
        // happened before the timeout fired.
        let _: u32 = poll_until(
            "test3_must_appear_in_panic_message",
            Duration::from_millis(50),
            Duration::from_millis(5),
            || async { None::<u32> },
        )
        .await;
    }

    // -------------------------------------------------------------------
    // Test 4 — FnMut bound is preserved (callers can mutate captured state).
    //
    // This is a compile-time check disguised as a runtime test. If the
    // helper's bound regresses to `F: Fn()` instead of `F: FnMut()`, this
    // test fails to compile because the closure mutates `counter` directly.
    //
    // Why this matters: real Stripe-webhook tests want to log per-attempt
    // diagnostics (e.g. "attempt 3: subscription not yet cancelled, status=trialing").
    // That requires mutable state across polls — Fn would force tests into
    // contortions like Arc<AtomicUsize> for trivial counters.
    // -------------------------------------------------------------------
    #[tokio::test]
    async fn predicate_can_be_fnmut() {
        let mut counter: u32 = 0;
        let result = poll_until(
            "test4_fnmut",
            Duration::from_secs(5),
            Duration::from_millis(5),
            || {
                counter += 1;
                let snapshot = counter;
                async move {
                    if snapshot >= 2 {
                        Some(snapshot)
                    } else {
                        None
                    }
                }
            },
        )
        .await;
        assert_eq!(result, 2);
    }
}

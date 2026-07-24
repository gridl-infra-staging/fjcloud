# Live owner summary

The predecessor source documents a real historical `rollup_stale` failure:
the rehearsal correctly refused mutation because `usage_daily` had zero rows
inside the 48-hour freshness window. Its Stage 3 required a durable root-owner
repair and an end-to-end green row, not a manual service start or weaker
classifier. Those old counts, currency, and credential claims are context only.

Current owner flow:

1. `infra/metering-agent/src/counter.rs::build_counter_usage_records` converts
   per-index Prometheus counter deltas and document-count snapshots into
   attributed records. New indexes seed at zero so their first observed burst
   is billed; pre-existing indexes establish a restart-safe baseline.
2. `infra/metering-agent/src/storage.rs::poll_storage` writes attributed hot
   and cold storage gauge records. A cold-storage endpoint failure is isolated
   so hot-storage records still persist.
3. `ops/systemd/fj-metering-agent.service` continuously runs and restarts the
   producer, gated by `/etc/fjcloud/metering-env`.
4. `infra/aggregation-job/src/main.rs::run` computes the target UTC day window
   and executes `infra/aggregation-job/src/rollup.rs::ROLLUP_SQL`.
5. `ROLLUP_SQL` sums counters, averages gauges, groups by customer and region,
   and idempotently upserts `usage_daily` with a fresh `aggregated_at`.
6. `ops/systemd/fjcloud-aggregation-job.timer` persistently invokes the
   oneshot service at 01:00 UTC.
7. `scripts/lib/metering_checks.sh` is the sole 48-hour SQL predicate owner;
   `scripts/probe_usage_rollup_freshness.sh` classifies its evidence and
   `scripts/probe_live_state.sh` renders separate staging and prod rows.

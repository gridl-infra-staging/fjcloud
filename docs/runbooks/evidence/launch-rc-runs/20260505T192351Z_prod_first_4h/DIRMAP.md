<!-- [scrai:start] -->
## 20260505T192351Z_prod_first_4h

| File | Summary |
| --- | --- |
| probe_rollup.sh | probe_rollup.sh — usage_daily rollup freshness probe.
Mirrors scripts/lib/metering_checks.sh::check_rollup_current (column
aggregated_at, 48h owner-window). |
| queries.sh | queries.sh — single 30-minute monitoring tick for the launch-window first-4h
bundle. |
| run_monitor.sh | run_monitor.sh — detached 4-hour monitor wrapper.
Runs queries.sh on a 30-minute cadence (8 ticks total). |
<!-- [scrai:end] -->

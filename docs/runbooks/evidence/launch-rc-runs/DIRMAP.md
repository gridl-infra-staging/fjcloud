<!-- [scrai:start] -->
## launch-rc-runs

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260505T192351Z_prod_first_4h | This directory contains a 4-hour production launch monitoring suite that runs metering and usage rollup freshness probes on a 30-minute cadence, with a wrapper script to manage the full 8-tick monitoring cycle. |
| 20260505T192351Z_prod_first_4h | A monitoring suite for the production launch's first 4-hour window, consisting of a rollup freshness probe (probe_rollup.sh), a 30-minute tick query script (queries.sh), and a detached wrapper (run_monitor.sh) that runs 8 consecutive monitoring cycles to ensure metering data aggregation health during the critical launch period. |
| 20260505T192351Z_prod_first_4h | This directory contains monitoring and probing tools for a 4-hour production launch window, including a metering rollup freshness probe and a detached monitor wrapper that runs 30-minute monitoring ticks eight times over the 4-hour period. |
| 20260505T192351Z_prod_first_4h | A 4-hour launch-window monitoring bundle that runs monitoring queries on a 30-minute cadence (8 ticks total), with each tick probing the freshness of the usage_daily rollup. |
| 20260505T192351Z_prod_first_4h | A 4-hour monitoring bundle for launch-window observation that runs usage freshness probes and system health queries on a 30-minute cadence (8 iterations total), tracking billing data freshness and system state during the critical first-4h post-launch period. |
<!-- [scrai:end] -->

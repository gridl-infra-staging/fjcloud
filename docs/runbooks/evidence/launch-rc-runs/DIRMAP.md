<!-- [scrai:start] -->
## launch-rc-runs

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| 20260505T192351Z_prod_first_4h | This directory contains monitoring and probing scripts for the first 4 hours of a production launch window, including a rollup freshness checker and a 30-minute ticker that runs monitoring queries 8 times over a 4-hour period via a detached wrapper. |
| 20260505T192351Z_prod_first_4h | This directory contains monitoring scripts for the first 4 hours after a production launch: probe_rollup.sh checks usage data freshness, queries.sh runs a single monitoring tick, and run_monitor.sh orchestrates repeated checks every 30 minutes for the full 4-hour window. |
<!-- [scrai:end] -->

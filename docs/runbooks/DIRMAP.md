<!-- [scrai:start] -->
## runbooks

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| evidence | The evidence directory contains production operations monitoring and cleanup orchestration: launch-rc-runs tracks system health and data freshness during release windows, while prod_db_leak_cleanup manages the final stages of database leak remediation including customer deployment termination and tenant data cleanup with consistency validation. |
| evidence | The evidence directory contains a 4-hour production launch monitoring bundle that validates metering data rollup freshness through periodic sampling, and database leak cleanup workflow stages that terminate customer deployments and perform soft-deletes with reproducibility and idempotency validation. |
<!-- [scrai:end] -->

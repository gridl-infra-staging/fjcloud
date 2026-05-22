<!-- [scrai:start] -->
## evidence

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| alert_emails | — |
| fleet-recovery | This directory contains a multi-stage fleet recovery workflow from May 20-21, 2026, with timestamped subdirectories for diagnosis and recovery stages 4-7, each including shell scripts and evidence files for diagnosing the incident, reconciling state, restoring capacity, verifying monitoring, and completing final validation checks. |
| launch-rc-runs | This directory contains a 4-hour production launch monitoring bundle that executes 30-minute health checks (8 total ticks) to verify usage_daily rollup freshness and system stability during the critical post-launch window on 2026-05-05. |
| may16_wave_deploy_verify | Evidence artifacts and stub scripts from a multi-stage validation workflow that captures authentication lockout behavior for stage 5 of a testing or deployment procedure, timestamped 2026-05-18. |
| monitoring-coverage | — |
| privacy_com_contract | This directory contains operational validation scripts for Privacy.com contract integration, with a timestamped live probe routine for monitoring and verifying the contract's health against live services. |
| prod_db_leak_cleanup | This directory contains stages 4 and 5 of a production database leak cleanup operation, where stage 4 terminates customer deployments and validates reproducibility through comparative testing, while stage 5 ensures tenant soft-deletion is idempotent and produces consistent results across multiple runs. |
| staging-isolation | — |
| staging-metering | — |
| stripe-pre-gut-snapshot | — |
<!-- [scrai:end] -->

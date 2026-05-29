<!-- [scrai:start] -->
## evidence

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| alert_emails | — |
| database-recovery | — |
| fleet-recovery | — |
| ha_coverage_a5 | — |
| launch-rc-runs | This directory contains launch-window monitoring bundles designed to track system health during production releases, specifically probing the freshness of usage_daily rollup data and executing monitoring queries at regular intervals. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory orchestrates the final two stages of a production database leak cleanup: Stage 4 terminates customer deployments via the admin API with reproducibility validation, and Stage 5 performs tenant soft-deletes with strict consistency checks to ensure customer sets remain stable across reruns. |
| launch-rc-runs | A monitoring bundle for the first 4 hours of production launch containing probes that verify metering data rollup freshness through 30-minute sampling queries run eight times across a 4-hour window. |
| may16_wave_deploy_verify | — |
| monitoring-coverage | — |
| privacy_com_contract | — |
| prod_db_leak_cleanup | This directory contains stages 4 and 5 of a production database leak cleanup workflow, where Stage 4 terminates customer deployments via admin APIs with reproducibility validation, and Stage 5 performs soft-deletes of those customers with idempotency checks and cross-run summary artifacts. |
| security-coverage-a3 | — |
| staging-isolation | — |
| staging-metering | — |
| stripe-pre-gut-snapshot | — |
<!-- [scrai:end] -->
